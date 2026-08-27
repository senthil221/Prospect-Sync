import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const departments = new Set([
  "Sales", "Marketing", "Engineering", "IT", "Product", "Design", "Data & Analytics",
  "HR", "Finance", "Legal", "Operations", "Supply Chain", "Manufacturing", "Quality",
  "Support", "Admin", "Strategy", "R&D",
]);
const tiers = new Set(["owner", "c_suite", "vp", "director", "manager", "senior_ic", "entry", "none"]);
const rank = new Map(["owner", "c_suite", "vp", "director", "manager", "senior_ic", "entry"].map((tier, index) => [tier, index + 1]));
const maxKeywordTokens = 8;

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
  const header = rows.shift().map((cell) => cell.trim());
  return rows
    .filter((cells) => cells.some((cell) => cell.trim()) && !cells[0].trim().startsWith("#"))
    .map((cells) => Object.fromEntries(header.map((name, index) => [name, (cells[index] ?? "").trim()])));
}

function normalizeTitle(value) {
  return String(value ?? "")
    .toLocaleLowerCase()
    .normalize("NFKD")
    .replace(/\p{M}/gu, "")
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

function phraseMatches(tokens, keywordTokens, start) {
  return keywordTokens.every((token, offset) => tokens[start + offset] === token);
}

function allMatches(tokens, rows) {
  const matches = [];
  for (const row of rows) {
    const keywordTokens = row.keyword.split(" ");
    for (let start = 0; start <= tokens.length - keywordTokens.length; start += 1) {
      if (phraseMatches(tokens, keywordTokens, start)) matches.push({ ...row, start, length: keywordTokens.length });
    }
  }
  return matches.sort((left, right) => right.length - left.length || left.start - right.start);
}

function consumeMatches(tokens, rows, skipped = () => false) {
  const consumed = Array(tokens.length).fill(false);
  const fired = [];
  for (const match of allMatches(tokens, rows)) {
    if (skipped(match) || consumed.slice(match.start, match.start + match.length).some(Boolean)) continue;
    consumed.fill(true, match.start, match.start + match.length);
    fired.push(match);
  }
  return fired;
}

function buildClassifier(seniorityRows, departmentRows) {
  return (title, company = "") => {
    const normalizedTitle = normalizeTitle(title);
    const tokens = normalizedTitle ? normalizedTitle.split(" ") : [];
    const healthcare = /(hospital|clinic|medical|healthcare|health care|diagnostic|patholog|labs\b|laborator)/i.test(company);
    const seniorityMatches = consumeMatches(tokens, seniorityRows, (match) => healthcare && match.keyword === "md");
    const former = ["former", "ex", "retired", "past"].includes(tokens[0])
      || seniorityMatches.some((match) => match.start > 0 && ["former", "ex", "retired", "past"].includes(tokens[match.start - 1]));
    const ranked = seniorityMatches.filter((match) => match.tier !== "none").sort((left, right) => rank.get(left.tier) - rank.get(right.tier));

    const departmentMatches = consumeMatches(tokens, departmentRows);
    const primary = [...departmentMatches].sort((left, right) => left.start - right.start)[0];
    const specific = primary
      ? allMatches(tokens, departmentRows)
        .filter((match) => match.department === primary.department && match.sub_department)
        .sort((left, right) => left.start - right.start || right.length - left.length)[0]
      : null;
    const secondaryDepartments = [...new Set(departmentMatches
      .filter((match) => primary && match.department !== primary.department)
      .map((match) => match.department))];

    return {
      normalizedTitle,
      seniority: former ? "" : ranked[0]?.tier ?? "",
      department: primary?.department ?? "",
      subDepartment: specific?.sub_department ?? "",
      secondaryDepartments,
      isFormer: former,
    };
  };
}

const [seniorityText, departmentText] = await Promise.all([
  readFile(new URL("../data/seniority_map.csv", import.meta.url), "utf8"),
  readFile(new URL("../data/department_map.csv", import.meta.url), "utf8"),
]);
const seniorityRows = parseCsv(seniorityText);
const departmentRows = parseCsv(departmentText);
const classify = buildClassifier(seniorityRows, departmentRows);

test("keyword maps are normalized, unique, bounded and use the supported taxonomy", () => {
  for (const [name, rows, valueKey, allowed] of [
    ["seniority", seniorityRows, "tier", tiers],
    ["department", departmentRows, "department", departments],
  ]) {
    const seen = new Set();
    for (const row of rows) {
      assert.equal(row.keyword, normalizeTitle(row.keyword), `${name} keyword must already be normalized: ${row.keyword}`);
      assert.ok(row.keyword.split(" ").length <= maxKeywordTokens, `${name} keyword exceeds scan window: ${row.keyword}`);
      assert.ok(!seen.has(row.keyword), `duplicate ${name} keyword: ${row.keyword}`);
      assert.ok(allowed.has(row[valueKey]), `unsupported ${name} mapping for ${row.keyword}: ${row[valueKey]}`);
      seen.add(row.keyword);
    }
  }
  assert.equal(new Set(departmentRows.map((row) => row.department)).size, 18);
});

test("normalization follows the supplied deterministic specification", () => {
  assert.equal(normalizeTitle("  V.P. - Sales / FP&A  "), "vp sales fpna");
  assert.equal(normalizeTitle("Founder's Office"), "founder s office");
  assert.equal(normalizeTitle("Directeur Général"), "directeur general");
});

test("spec examples classify with phrase precedence and independent scans", () => {
  assert.deepEqual(classify("AVP Sales"), {
    normalizedTitle: "avp sales", seniority: "vp", department: "Sales", subDepartment: "", secondaryDepartments: [], isFormer: false,
  });
  assert.equal(classify("Assistant Manager - Accounts").seniority, "entry");
  assert.equal(classify("Assistant Manager - Accounts").department, "Finance");
  assert.equal(classify("Founder & CEO").seniority, "owner");
  assert.equal(classify("Manager - FP&A").subDepartment, "FP&A");
  assert.equal(classify("Headhunter").seniority, "");
});

test("executive-assistant phrases cannot be promoted by MD or CEO tokens", () => {
  for (const title of [
    "Executive Assistant to MD",
    "Executive Assistant to the MD",
    "Executive Assistant to CEO",
    "Executive Assistant to the Chairman",
  ]) {
    const result = classify(title);
    assert.equal(result.seniority, "entry", title);
    assert.equal(result.department, "Admin", title);
  }
});

test("former-role and healthcare safeguards prefer undefined over a false positive", () => {
  assert.deepEqual(classify("Former CEO | Advisor"), {
    normalizedTitle: "former ceo advisor", seniority: "", department: "", subDepartment: "", secondaryDepartments: [], isFormer: true,
  });
  assert.equal(classify("MD", "Apollo Hospitals Ltd").seniority, "");
  assert.equal(classify("Founder's Office").seniority, "");
  assert.equal(classify("Founder's Office").department, "Strategy");
});

test("department specificity and earliest-mentioned precedence stay deterministic", () => {
  const customerSuccess = classify("Customer Success Manager");
  assert.equal(customerSuccess.department, "Support");
  assert.equal(customerSuccess.subDepartment, "Customer Success");

  const multi = classify("Sales and Marketing Director");
  assert.equal(multi.department, "Sales");
  assert.deepEqual(multi.secondaryDepartments, ["Marketing"]);
});

test("the forward migration expands the immutable original scan window", async () => {
  const [base, followUp] = await Promise.all([
    readFile(new URL("../supabase/migrations/20260826050000_title_classifier.sql", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260826070000_title_classifier_accuracy.sql", import.meta.url), "utf8"),
  ]);
  assert.equal(base.match(/generate_series\(1, 4\)/g)?.length, 3);
  assert.match(followUp, /old_window constant text := 'generate_series\(1, 4\)'/);
  assert.match(followUp, /new_window constant text := 'generate_series\(1, least\(v_count, 8\)\)'/);
});
