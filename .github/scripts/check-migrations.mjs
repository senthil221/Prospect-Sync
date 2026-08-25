import { execFileSync } from "node:child_process";
import { readFile, readdir } from "node:fs/promises";
import path from "node:path";

const migrationsDirectory = path.resolve("supabase/migrations");
const migrationNamePattern = /^(\d{14})_[a-z0-9][a-z0-9_]*\.sql$/;
const functionStartPattern = /create\s+(?:or\s+replace\s+)?function\s+((?:"[^"]+"|[a-z_][\w$]*)(?:\s*\.\s*(?:"[^"]+"|[a-z_][\w$]*))?)\s*\(/gi;
const revokePattern = /revoke\s+execute\s+on\s+function\s+((?:"[^"]+"|[a-z_][\w$]*)(?:\s*\.\s*(?:"[^"]+"|[a-z_][\w$]*))?)(?:\s*\([^;]*\))?\s+from\s+([^;]+);/gi;
const requiredRevokedRoles = ["public", "anon", "authenticated"];

function normalizeIdentifier(identifier) {
  return identifier.replaceAll('"', "").replace(/\s+/g, "").toLowerCase();
}

function findClosingParenthesis(sql, openingIndex) {
  let depth = 0;
  let quote = null;

  for (let index = openingIndex; index < sql.length; index += 1) {
    const character = sql[index];
    if (quote) {
      if (character === quote && sql[index - 1] !== "\\") quote = null;
      continue;
    }
    if (character === "'" || character === '"') {
      quote = character;
    } else if (character === "(") {
      depth += 1;
    } else if (character === ")") {
      depth -= 1;
      if (depth === 0) return index;
    }
  }

  return -1;
}

function securityDefinerFunctions(sql) {
  const functions = [];

  for (const match of sql.matchAll(functionStartPattern)) {
    const openingIndex = match.index + match[0].lastIndexOf("(");
    const closingIndex = findClosingParenthesis(sql, openingIndex);
    if (closingIndex === -1) continue;

    const remainingSql = sql.slice(closingIndex + 1);
    const bodyDelimiterIndex = remainingSql.search(/\$(?:[a-z_][\w]*)?\$/i);
    if (bodyDelimiterIndex === -1) continue;

    const functionHeader = remainingSql.slice(0, bodyDelimiterIndex);
    if (/\bsecurity\s+definer\b/i.test(functionHeader)) {
      functions.push(normalizeIdentifier(match[1]));
    }
  }

  return functions;
}

function revokedRolesByFunction(sql) {
  const revocations = new Map();

  for (const match of sql.matchAll(revokePattern)) {
    const functionName = normalizeIdentifier(match[1]);
    const roles = revocations.get(functionName) ?? new Set();
    for (const role of match[2].toLowerCase().match(/[a-z_][\w$]*/g) ?? []) {
      roles.add(role);
    }
    revocations.set(functionName, roles);
  }

  return revocations;
}

const migrationNames = (await readdir(migrationsDirectory))
  .filter((name) => name.endsWith(".sql"))
  .sort((left, right) => left.localeCompare(right));
const failures = [];
let previousTimestamp = null;

for (const migrationName of migrationNames) {
  const nameMatch = migrationName.match(migrationNamePattern);
  if (!nameMatch) {
    failures.push(`${migrationName}: expected <14-digit timestamp>_<name>.sql`);
    continue;
  }

  const timestamp = nameMatch[1];
  if (previousTimestamp !== null && timestamp <= previousTimestamp) {
    failures.push(`${migrationName}: timestamp ${timestamp} is not strictly after ${previousTimestamp}`);
  }
  previousTimestamp = timestamp;
}

const baseArgumentIndex = process.argv.indexOf("--base");
let securityMigrationNames = migrationNames;
if (baseArgumentIndex !== -1) {
  const baseRevision = process.argv[baseArgumentIndex + 1];
  if (!baseRevision) throw new Error("--base requires a Git revision");

  const changedEntries = execFileSync(
    "git",
    ["diff", "--name-status", "--find-renames", baseRevision, "HEAD", "--", "supabase/migrations"],
    { encoding: "utf8" },
  );
  securityMigrationNames = [];

  for (const entry of changedEntries.split(/\r?\n/).filter(Boolean)) {
    const [status, ...changedPaths] = entry.split("\t");
    if (status === "A") {
      const migrationPath = changedPaths[0];
      if (migrationPath?.endsWith(".sql")) securityMigrationNames.push(path.basename(migrationPath));
      continue;
    }

    const migrationPath = changedPaths.at(-1) ?? changedPaths[0] ?? "unknown migration";
    failures.push(
      `${migrationPath}: applied migration files are immutable (${status}); add a new timestamped forward migration instead`,
    );
  }
}

for (const migrationName of securityMigrationNames) {
  const sql = await readFile(path.join(migrationsDirectory, migrationName), "utf8");
  const revocations = revokedRolesByFunction(sql);
  for (const functionName of securityDefinerFunctions(sql)) {
    const revokedRoles = revocations.get(functionName) ?? new Set();
    const missingRoles = requiredRevokedRoles.filter((role) => !revokedRoles.has(role));
    if (missingRoles.length > 0) {
      failures.push(
        `${migrationName}: ${functionName} is SECURITY DEFINER without same-file EXECUTE revokes for ${missingRoles.join(", ")}`,
      );
    }
  }
}

if (failures.length > 0) {
  console.error(failures.join("\n"));
  process.exitCode = 1;
} else {
  console.log(
    `Validated ${migrationNames.length} migration timestamps and SECURITY DEFINER revokes in ${securityMigrationNames.length} changed migrations.`,
  );
}
