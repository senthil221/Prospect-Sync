import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { strToU8, zipSync } from "fflate";
import nextConfig from "../next.config.ts";
import { readXlsxRows } from "../lib/spreadsheet.ts";

function createWorkbook() {
  const files = {
    "[Content_Types].xml": `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
      </Types>`,
    "_rels/.rels": `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
      </Relationships>`,
    "xl/workbook.xml": `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets><sheet name="Prospects" sheetId="1" r:id="rId1"/></sheets>
      </workbook>`,
    "xl/_rels/workbook.xml.rels": `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
      </Relationships>`,
    "xl/worksheets/sheet1.xml": `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        <row r="1"><c r="A1" t="inlineStr"><is><t>Name</t></is></c><c r="B1" t="inlineStr"><is><t>Work Email</t></is></c><c r="C1" t="inlineStr"><is><t>Company</t></is></c></row>
        <row r="2"><c r="A2" t="inlineStr"><is><t>Ada Lovelace</t></is></c><c r="B2" t="inlineStr"><is><t>ada@example.com</t></is></c><c r="C2" t="inlineStr"><is><t>Analytical Engines</t></is></c></row>
      </sheetData></worksheet>`,
  };
  return zipSync(Object.fromEntries(Object.entries(files).map(([path, contents]) => [path, strToU8(contents)])));
}

test("reads XLSX headers and rows through the shared spreadsheet parser", async () => {
  const bytes = createWorkbook();
  const file = new File([bytes], "prospect_list.xlsx", { type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" });
  const rows = await readXlsxRows(file);

  assert.deepEqual(rows, [
    ["Name", "Work Email", "Company"],
    ["Ada Lovelace", "ada@example.com", "Analytical Engines"],
  ]);
  const helpers = await readFile(new URL("../lib/dashboard-helpers.ts", import.meta.url), "utf8");
  assert.match(helpers, /replace\(\/\\\.\(\?:csv\|xlsx\)\$\/i, ""\)/);
});

test("CSP permits the Blob workers used for larger XLSX archives", async () => {
  const headerGroups = await nextConfig.headers?.();
  const csp = headerGroups?.flatMap((group) => group.headers).find((header) => header.key === "Content-Security-Policy")?.value ?? "";
  assert.match(csp, /worker-src 'self' blob:/);
});
