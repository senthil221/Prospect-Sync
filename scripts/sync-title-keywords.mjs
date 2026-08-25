#!/usr/bin/env node
// Push data/seniority_map.csv and data/department_map.csv into the classifier's
// keyword tables.
//
// The CSVs are the source of truth. This reconciles the tables to match them
// exactly -- upsert every row in the file, delete every row that is no longer in
// it -- so running it twice is the same as running it once, and a keyword deleted
// from the file actually stops firing.
//
// Every write bumps title_classifier_state.keywords_updated_at (a table trigger),
// which is what marks already-classified prospects as stale. Re-classify them with
//   POST /api/prospects/classify   {"mode":"stale"}
//
// Usage:
//   node scripts/sync-title-keywords.mjs           # apply
//   node scripts/sync-title-keywords.mjs --dry-run # report the diff only
//
// Reads NEXT_PUBLIC_SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY from .env.local.

import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createClient } from "@supabase/supabase-js";

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const dryRun = process.argv.includes("--dry-run");

function loadEnv() {
  const env = { ...process.env };
  try {
    for (const line of readFileSync(resolve(projectRoot, ".env.local"), "utf8").split(/\r?\n/)) {
      const match = /^([A-Z0-9_]+)=(.*)$/.exec(line.trim());
      if (match && !env[match[1]]) env[match[1]] = match[2];
    }
  } catch {
    // .env.local is optional when the variables are already exported.
  }
  return env;
}

// Minimal RFC-4180 reader: enough for these files (quoted fields, embedded commas),
// and it drops the `#` comment lines the maps use for section headers.
function parseCsv(text) {
  const rows = [];
  let row = [];
  let field = "";
  let quoted = false;
  for (let index = 0; index < text.length; index += 1) {
    const character = text[index];
    if (quoted) {
      if (character === '"' && text[index + 1] === '"') { field += '"'; index += 1; continue; }
      if (character === '"') { quoted = false; continue; }
      field += character;
      continue;
    }
    if (character === '"') { quoted = true; continue; }
    if (character === ",") { row.push(field); field = ""; continue; }
    if (character === "\r") continue;
    if (character === "\n") { row.push(field); rows.push(row); row = []; field = ""; continue; }
    field += character;
  }
  row.push(field);
  if (row.some((cell) => cell.trim())) rows.push(row);

  const header = rows.shift()?.map((cell) => cell.trim()) ?? [];
  return rows
    .filter((cells) => cells.some((cell) => cell.trim()) && !cells[0].trim().startsWith("#"))
    .map((cells) => Object.fromEntries(header.map((name, position) => [name, (cells[position] ?? "").trim()])));
}

// Must match normalize_job_title_v1 for the single-token cases the maps use. A
// keyword that does not survive normalization can never match a normalized title,
// so it is reported rather than silently loaded.
function normalizeKeyword(value) {
  return value
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/['`]/g, " ")
    .replace(/\b([a-z])\./g, "$1")
    .replace(/\bfp\s*&\s*a\b/g, "fpna")
    .replace(/\br\s*&\s*d\b/g, "rnd")
    .replace(/\bl\s*&\s*d\b/g, "lnd")
    .replace(/\bm\s*&\s*a\b/g, "mna")
    .replace(/[^a-z0-9]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

const departments = new Set([
  "Sales", "Marketing", "Engineering", "IT", "Product", "Design", "Data & Analytics",
  "HR", "Finance", "Legal", "Operations", "Supply Chain", "Manufacturing", "Quality",
  "Support", "Admin", "Strategy", "R&D",
]);
const tiers = new Set(["owner", "c_suite", "vp", "director", "manager", "senior_ic", "entry", "none"]);

function readMap(fileName, build) {
  const parsed = parseCsv(readFileSync(resolve(projectRoot, "data", fileName), "utf8"));
  const problems = [];
  const seen = new Map();
  const rows = [];
  for (const [position, raw] of parsed.entries()) {
    // Comment and blank lines are already gone, so this is an approximate line
    // number -- close enough to find the row in an editor.
    const line = position + 2;
    const keyword = normalizeKeyword(raw.keyword ?? "");
    if (!keyword) { problems.push(`${fileName}:${line} keyword is empty after normalization ("${raw.keyword}")`); continue; }
    if (keyword !== (raw.keyword ?? "").trim()) problems.push(`${fileName}:${line} keyword normalized "${raw.keyword}" -> "${keyword}"`);
    if (keyword.split(" ").length > 4) { problems.push(`${fileName}:${line} "${keyword}" is longer than the 4-token scan window and can never match`); continue; }
    if (seen.has(keyword)) { problems.push(`${fileName}:${line} duplicate keyword "${keyword}" (first seen at row ${seen.get(keyword)})`); continue; }
    const built = build(keyword, raw, line, problems);
    if (!built) continue;
    seen.set(keyword, line);
    rows.push(built);
  }
  return { rows, problems };
}

async function reconcile(supabase, table, rows, keyColumn) {
  const existing = await supabase.from(table).select(keyColumn);
  if (existing.error) throw new Error(`${table}: ${existing.error.message}`);
  const wanted = new Set(rows.map((row) => row[keyColumn]));
  const stale = (existing.data ?? []).map((row) => row[keyColumn]).filter((key) => !wanted.has(key));

  if (dryRun) return { upserted: rows.length, deleted: stale.length };

  for (let index = 0; index < rows.length; index += 500) {
    const { error } = await supabase.from(table).upsert(rows.slice(index, index + 500), { onConflict: keyColumn });
    if (error) throw new Error(`${table} upsert: ${error.message}`);
  }
  for (let index = 0; index < stale.length; index += 500) {
    const { error } = await supabase.from(table).delete().in(keyColumn, stale.slice(index, index + 500));
    if (error) throw new Error(`${table} delete: ${error.message}`);
  }
  return { upserted: rows.length, deleted: stale.length };
}

async function main() {
  const env = loadEnv();
  const url = env.NEXT_PUBLIC_SUPABASE_URL;
  const key = env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) {
    console.error("NEXT_PUBLIC_SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set (.env.local or the environment).");
    process.exit(1);
  }

  const seniority = readMap("seniority_map.csv", (keyword, raw, line, problems) => {
    if (!tiers.has(raw.tier)) { problems.push(`seniority_map.csv:${line} unknown tier "${raw.tier}"`); return null; }
    return { keyword, tier: raw.tier, notes: raw.notes ?? "" };
  });
  const department = readMap("department_map.csv", (keyword, raw, line, problems) => {
    if (!departments.has(raw.department)) { problems.push(`department_map.csv:${line} unknown department "${raw.department}"`); return null; }
    return { keyword, department: raw.department, sub_department: raw.sub_department ?? "", notes: raw.notes ?? "" };
  });

  const problems = [...seniority.problems, ...department.problems];
  for (const problem of problems) console.warn(`warn: ${problem}`);

  const supabase = createClient(url, key, { auth: { persistSession: false } });
  const seniorityResult = await reconcile(supabase, "title_seniority_keywords", seniority.rows, "keyword");
  const departmentResult = await reconcile(supabase, "title_department_keywords", department.rows, "keyword");

  console.log(`${dryRun ? "[dry run] " : ""}seniority: ${seniorityResult.upserted} upserted, ${seniorityResult.deleted} removed`);
  console.log(`${dryRun ? "[dry run] " : ""}department: ${departmentResult.upserted} upserted, ${departmentResult.deleted} removed`);
  if (!dryRun) console.log("Keyword lists changed -- run POST /api/prospects/classify {\"mode\":\"stale\"} to re-classify affected prospects.");
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
