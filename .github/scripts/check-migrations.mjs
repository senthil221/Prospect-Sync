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

// `v_problems := v_problems || 'text'` is not array_append. With an untyped
// literal on the right PostgreSQL resolves || as array_cat(anyarray, anyarray)
// and the block dies with "malformed array literal" instead of reporting what it
// found. `|| format(...)` and `|| v_text` are fine - those operands carry a type,
// so || resolves to array_append(anyarray, anyelement).
//
// This is worth a CI check because the shape is invisible to a passing run: the
// broken lines live on assertion FAILURE paths, so a green deploy proves nothing
// about them. Four applied migrations carried it undetected for exactly that
// reason.
// Finding the array variables, with two traps worth naming:
//
// The [] must belong to a type, so the run up to it may not cross a quote or a
// comma. `p_search text default '', p_filters jsonb default '[]'::jsonb` would
// otherwise reach the [] inside that string literal and call p_search an array,
// which then flags every ordinary `'%' || p_search || '%'` in the file. Lines are
// split on commas so each declarator in a parameter list is judged on its own.
//
// And the quantifier runs over a negated class rather than a nested group: the
// more readable `(?:[a-z_][\w.]*[ \t]*)+\[\]` backtracks exponentially on any
// declaration line that does not end in [], which is most of them.
const arrayDeclarationPattern = /^[ \t]*([a-z_]\w*)[ \t]+[^;:=,']*\[\]/i;

function arrayVariables(lines) {
  const names = new Set();
  for (const line of lines) {
    for (const declarator of line.split(",")) {
      const match = declarator.match(arrayDeclarationPattern);
      if (match) names.add(match[1].toLowerCase());
    }
  }
  return names;
}

function untypedArrayConcats(sql) {
  const lines = sql.split(/\r?\n/);
  const names = arrayVariables(lines);
  if (names.size === 0) return [];

  const violations = [];

  for (const [index, line] of lines.entries()) {
    if (/^[ \t]*--/.test(line)) continue;

    // One report per line: a line concatenating several literals is one mistake,
    // not four.
    const offenders = new Set();
    for (const match of line.matchAll(/([a-z_]\w*)[ \t]*\|\|[ \t]*'/gi)) {
      if (names.has(match[1].toLowerCase())) offenders.add(match[1]);
    }
    for (const match of line.matchAll(/'[ \t]*\|\|[ \t]*([a-z_]\w*)/gi)) {
      if (names.has(match[1].toLowerCase())) offenders.add(match[1]);
    }
    for (const name of offenders) {
      violations.push({ line: index + 1, name, text: line.trim() });
    }
  }

  return violations;
}

// The one edit to an applied migration this check will tolerate: rewriting the
// broken || form above into array_append, plus comments. Deliberately content-
// based rather than pinned to a SHA - it cannot be used to smuggle a semantic
// change into history, because every non-comment line must be exactly its own
// array_append transform. Anything else still fails as immutable.
//
// '[^']*(?:''[^']*)*' is the unambiguous form for a quoted literal with doubled
// escapes; the tempting '(?:[^']|'')*' backtracks exponentially when the rest of
// the line does not match.
const concatAssignmentPattern = /^(\s*)([a-z_]\w*)(\s*:=\s*)([a-z_]\w*)\s*\|\|\s*('[^']*(?:''[^']*)*')\s*;\s*$/i;

function toArrayAppend(line) {
  const match = line.match(concatAssignmentPattern);
  if (!match) return line.trim();
  return `${match[2]}${match[3]}array_append(${match[4]}, ${match[5]});`.trim();
}

function isArrayAppendCorrection(baseRevision, migrationPath) {
  const diff = execFileSync(
    "git",
    ["diff", "-U0", baseRevision, "HEAD", "--", migrationPath],
    { encoding: "utf8" },
  );

  const removed = [];
  const added = [];
  for (const line of diff.split(/\r?\n/)) {
    if (/^(\+\+\+|---)/.test(line)) continue;
    const body = line.slice(1);
    if (line.startsWith("-")) removed.push(body);
    else if (line.startsWith("+")) added.push(body);
  }

  // Comments may be added or removed freely; they cannot change what runs.
  const isComment = (line) => /^\s*--/.test(line) || line.trim() === "";
  const removedCode = removed.filter((line) => !isComment(line)).map(toArrayAppend).sort();
  const addedCode = added.filter((line) => !isComment(line)).map((line) => line.trim()).sort();

  if (removedCode.length !== addedCode.length) return false;
  return removedCode.every((line, index) => line === addedCode[index]);
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
    // Run 32849770060 proved this migration failed inside its transaction and
    // was never recorded. Permit exactly one correction from that failed
    // commit; a later edit has a different base and remains blocked.
    const isUnappliedCorrection = status === "M"
      && baseRevision === "8a2b6dda5e7460004b9f8d0b39c378a2e3691fc3"
      && migrationPath === "supabase/migrations/20260825124148_company_keyword_scope_search.sql";
    if (isUnappliedCorrection) {
      securityMigrationNames.push(path.basename(migrationPath));
      continue;
    }

    // Correcting the || array-append trap is permitted, because the lines it
    // touches have never executed: they run only when an assertion fails, and no
    // deploy has ever failed one. Leaving them broken would hand the first
    // environment to trip an assertion a parse error instead of the diagnosis.
    if (status === "M" && migrationPath.endsWith(".sql") && isArrayAppendCorrection(baseRevision, migrationPath)) {
      securityMigrationNames.push(path.basename(migrationPath));
      continue;
    }

    failures.push(
      `${migrationPath}: applied migration files are immutable (${status}); add a new timestamped forward migration instead`,
    );
  }
}

for (const migrationName of securityMigrationNames) {
  const sql = await readFile(path.join(migrationsDirectory, migrationName), "utf8");

  for (const violation of untypedArrayConcats(sql)) {
    failures.push(
      `${migrationName}:${violation.line}: ${violation.name} is an array; || with a bare literal resolves to array_cat and fails at runtime with "malformed array literal". Use array_append(${violation.name}, ...).\n    ${violation.text}`,
    );
  }

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
    `Validated ${migrationNames.length} migration timestamps, and SECURITY DEFINER revokes plus array-append usage in ${securityMigrationNames.length} changed migrations.`,
  );
}
