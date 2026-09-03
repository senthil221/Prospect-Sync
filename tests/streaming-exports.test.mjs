import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { directByteLimit, directRowLimit, estimatedBytesPerRow, planExport } from "../lib/export-plan.ts";
import { exportRowKeys, buildExportColumns, csvHeaderLine, csvRowsBody } from "../lib/prospect-export.ts";
import { companyExportColumns } from "../lib/company-export.ts";
import { readCsvStream } from "../lib/csv-download.ts";

// Release 2 item 6, section 9.4: direct streaming versus background chosen by
// estimated bytes as well as rows, requested columns only, keyset pagination, no
// whole-CSV accumulation in Next.js, and a company export with its own keyset
// function.

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
// Assertions about what the code does NOT do would match prose explaining why
// just as happily as they match code, so the comments come out first.
const codeOnly = (source) => source.split("\n").filter((line) => !line.trimStart().startsWith("//") && !line.trimStart().startsWith("--")).join("\n");

// A response whose body streams the given chunks, split at awkward places on
// purpose: the reader must not care where a chunk boundary lands.
function streamedResponse(text, chunkSize) {
  const encoder = new TextEncoder();
  const bytes = encoder.encode(text);
  let offset = 0;
  return new Response(new ReadableStream({
    pull(controller) {
      if (offset >= bytes.length) { controller.close(); return; }
      controller.enqueue(bytes.slice(offset, offset + chunkSize));
      offset += chunkSize;
    },
  }));
}

test("the projection is derived from the renderer, so it cannot name the wrong columns", () => {
  // Every key the export reads, discovered by running the columns rather than by
  // listing them a second time somewhere.
  const keys = exportRowKeys(["Persona"], ["__name", "__person_location", "__employee_count", "custom:persona"]);
  assert.deepEqual(keys, [
    "all_data", "city", "country", "created_at", "employee_count_max",
    "employee_count_min", "full_name", "id", "location", "state",
  ]);
  // id and created_at are the keyset cursor and the identity excluded ids are
  // matched on. Neither is a column, and an export without them cannot page.
  assert.ok(keys.includes("id") && keys.includes("created_at"));

  // A narrow export must actually be narrow - that is the whole point of asking
  // the database for fewer columns.
  const everything = exportRowKeys(["Persona"]);
  assert.ok(everything.length > keys.length * 2, "asking for four columns should read far fewer keys than asking for all of them");

  // And the projection has to cover the renderer: rendering a row that carries
  // only those keys must produce the same cells as rendering the whole row.
  const row = {
    id: "p1", created_at: "2026-01-01", full_name: "Ada Lovelace", city: "London", state: "",
    country: "UK", location: "", employee_count_min: 10, employee_count_max: 50,
    all_data: { Persona: "Engineer" }, title: "Analyst", keywords: ["ignored"],
  };
  const columns = buildExportColumns(["Persona"], ["__name", "__person_location", "__employee_count", "custom:persona"]);
  const projected = Object.fromEntries(Object.entries(row).filter(([key]) => keys.includes(key)));
  assert.equal(csvRowsBody([projected], columns), csvRowsBody([row], columns));
});

test("the direct-versus-background choice is made on bytes as well as rows", () => {
  // Two exports of the same size in rows, one of which is an order of magnitude
  // bigger as a file. A row count alone cannot tell them apart.
  const narrow = estimatedBytesPerRow([], ["__name", "__work_email"]);
  const wide = estimatedBytesPerRow(Array.from({ length: 30 }, (_, index) => `Field ${index}`));
  assert.ok(wide > narrow * 10, "a wide export must estimate far more per row than a narrow one");

  assert.equal(planExport({ customFieldNames: [], requestedFields: ["__name"], rows: 1000 }).mode, "direct");
  // Past the row limit, whatever the columns.
  assert.equal(planExport({ customFieldNames: [], requestedFields: ["__name"], rows: directRowLimit + 1 }).mode, "background");
  // Under the row limit and past the byte limit: this is the case a row-only
  // rule gets wrong.
  const rows = Math.ceil(directByteLimit / wide) + 1;
  assert.ok(rows < directRowLimit, "the byte limit should bind before the row limit for a wide export");
  assert.equal(planExport({ customFieldNames: Array.from({ length: 30 }, (_, index) => `Field ${index}`), rows }).mode, "background");

  // A capped count is not a count. Treating "50,000+" as 50,000 is how a
  // 600,000-row export gets attempted in one download.
  const unknown = planExport({ customFieldNames: [], requestedFields: ["__name"], rows: null });
  assert.equal(unknown.mode, "background");
  assert.equal(unknown.bytes, null);
});

test("the stream reader cuts on record boundaries, not on chunk boundaries", async () => {
  const columns = buildExportColumns([], ["__name", "__title"]);
  const rows = [
    { full_name: "Ada Lovelace", title: "Analyst" },
    // A quoted cell containing the record separator: splitting on newlines would
    // cut this row in half and count it twice.
    { full_name: "Grace\r\nHopper", title: "Rear Admiral" },
    { full_name: 'Quote "inside"', title: "Engineer" },
  ];
  const csv = "﻿" + csvHeaderLine(columns) + "\r\n" + csvRowsBody(rows, columns);

  for (const chunkSize of [1, 3, 7, 64, 4096]) {
    let header = "";
    const pieces = [];
    const counted = await readCsvStream(streamedResponse(csv, chunkSize), {
      onHeader: (value) => { header = value; },
      onRows: (text) => { pieces.push(text); },
    });
    assert.equal(counted, rows.length, `wrong row count at chunk size ${chunkSize}`);
    assert.equal(header, "﻿" + csvHeaderLine(columns), `wrong header at chunk size ${chunkSize}`);
    // Reassembled, it is the file that went in - byte for byte.
    assert.equal(header + "\r\n" + pieces.join("\r\n"), csv, `reassembly failed at chunk size ${chunkSize}`);
  }
});

test("the company CSV has one definition, used by both paths", async () => {
  assert.deepEqual(companyExportColumns.map((column) => column.header), ["Company Name", "Website"]);
  // A bare domain becomes a URL, a full one is left alone, and a company with
  // neither name nor domain still gets a cell.
  const rendered = csvRowsBody([
    { name: "Acme", domain: "acme.com" },
    { name: "", domain: "https://beta.example" },
    { name: "", domain: "" },
  ], companyExportColumns).split("\r\n");
  assert.equal(rendered[0], '"Acme","https://acme.com"');
  // A domain that already carries a scheme is left exactly as it is, in both cells.
  assert.equal(rendered[1], String.raw`"https://beta.example","https://beta.example"`);
  assert.equal(rendered[2], '"Unnamed company",""');

  const [route, download] = await Promise.all([
    read("../app/api/companies/route.ts"),
    read("../app/api/exports/[id]/download/route.ts"),
  ]);
  for (const source of [route, download]) {
    assert.match(source, /companyExportColumns/, "both company export paths must render through the shared columns");
  }
  // Neither may keep a private copy of the two headers.
  assert.doesNotMatch(codeOnly(route), /"Company Name"/);
  assert.doesNotMatch(codeOnly(download), /"Company Name"/);
});

test("nothing accumulates the whole file", async () => {
  const sources = await Promise.all([
    read("../app/api/prospects/export/route.ts"),
    read("../app/api/companies/route.ts"),
    read("../app/api/exports/[id]/download/route.ts"),
  ]);
  for (const source of sources) {
    const code = codeOnly(source);
    // Each page is enqueued and dropped. A growing string, or one array holding
    // every row, is the thing section 9.4 rules out.
    assert.match(code, /new ReadableStream<Uint8Array>/);
    assert.match(code, /controller\.enqueue\(encoder\.encode\(head \+ body\)\)/);
    assert.doesNotMatch(code, /rows\.push\(\.\.\./);
  }
});

test("a background export is defined by a frozen result set, and authorized by it", async () => {
  const migration = await read("../supabase/migrations/20260902000170_export_without_holding_it_all.sql");
  const code = codeOnly(migration);

  // The file is built by walking result_set_items, not by re-running the search.
  // Re-running it would rebuild the whole match set for every page, because the
  // export function's `matched` CTE is MATERIALIZED.
  assert.match(code, /from prospect_results\.result_set_items i/);
  assert.doesNotMatch(code.slice(code.indexOf("prospect_exports.build_batch_v1")), /prospect_filter_sql_v1/);

  // A job may only be built from a set its own owner asked for.
  assert.match(code, /if v_set\.owner_id is distinct from p_owner_id then/);
  assert.match(code, /errcode = '42501'/);

  // The cursor advances on ids scanned, not on rows kept, or a batch that is
  // entirely excluded would stall the job forever.
  assert.match(code, /next_ordinal = v_last_ordinal/);
  assert.match(code, /\(select max\(batch\.ordinal\) from batch\)/);

  // Idempotency is per actor and request id, never per content hash.
  assert.match(code, /create unique index if not exists uq_export_jobs_request\s+on prospect_exports\.jobs \(owner_id, request_id\)/);
});

test("the export worker may build a file and may not read one", async () => {
  const migration = await read("../supabase/migrations/20260902000170_export_without_holding_it_all.sql");
  const code = codeOnly(migration);

  for (const granted of ["claim_next_v1(text, integer)", "build_batch_v1(uuid, integer, integer)", "fail_v1(uuid, text)", "expire_jobs_v1()"]) {
    assert.match(code, new RegExp(`grant execute on function prospect_exports\\.${granted.replace(/[()[\]]/g, (char) => `\\${char}`)} to prospect_operator`));
  }
  // The negative half, asserted by the migration itself rather than only here.
  assert.match(code, /prospect_operator can read job_parts directly/);
  assert.match(code, /prospect_operator can request an export, which it must not/);
  assert.match(code, /prospect_operator can read an export part, which it must not/);

  // build_batch_v1 answers with counts. A row in that return type would be a row
  // the worker is not allowed to see.
  const build = code.slice(code.indexOf("function prospect_exports.build_batch_v1"));
  assert.match(build, /returns table\(appended integer, total_rows bigint, total_parts integer, done boolean\)/);

  const worker = await read("../worker/operations-worker.mjs");
  assert.match(worker, /prospect_exports\.claim_next_v1/);
  assert.match(worker, /prospect_exports\.build_batch_v1/);
  assert.match(worker, /prospect_exports\.expire_jobs_v1/);
  // Three queues, each drained to empty before the next is checked.
  assert.equal(codeOnly(worker).match(/^\s+continue;$/gm)?.length >= 3, true);
});

test("a background export carries the pivot rather than refusing it", async () => {
  const route = await read("../app/api/exports/route.ts");
  // This used to answer 400 under a Company DB pivot, because result_sets had
  // nowhere to put one and the file would have contained every person matching
  // the filters. 20260902000180 gave it somewhere, so the scope is passed into
  // both the set's identity and the set itself.
  assert.match(route, /const scopePayload = scopeRestricts\(companyScope\) \? companyScope : null;/);
  assert.match(route, /p_company_scope: scopePayload \?\? \{\}/);
  assert.match(route, /companyScope: scopePayload/);
  assert.doesNotMatch(route, /pivotRefusal/);
  // A company set is scoped BY companies; a company scope on one is a confusion,
  // and the database refuses it too.
  assert.match(route, /A company export cannot carry a company scope/);
});

test("an unfinished or emptied export is refused rather than served with holes", async () => {
  const download = await read("../app/api/exports/[id]/download/route.ts");
  assert.match(download, /if \(job\.status !== "ready"\)/);
  // job_parts is UNLOGGED, so a crash empties it while the job still says ready.
  assert.match(download, /export_parts_present_v1/);
  assert.match(download, /status: 410/);
  // The token is checked before the stream starts; a refusal from inside it
  // could only be a truncated file.
  assert.match(download, /if \(job\.download_token !== token\)/);
});
