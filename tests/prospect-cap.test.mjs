import assert from "node:assert/strict";
import test from "node:test";
import { capSelectedRows } from "../lib/prospect-cap.ts";

test("explicit export cap keeps the newest deterministic rows per company", () => {
  const rows = [
    { id: "a", company_id: "one", created_at: "2026-01-01T00:00:00Z" },
    { id: "c", company_id: "one", created_at: "2026-01-02T00:00:00Z" },
    { id: "b", company_id: "one", created_at: "2026-01-02T00:00:00Z" },
    { id: "d", company_id: "two", created_at: "2026-01-01T00:00:00Z" },
    { id: "e", company_id: "two", created_at: "2026-01-03T00:00:00Z" },
    { id: "unlinked-1", company_id: null, created_at: "2025-01-01T00:00:00Z" },
    { id: "unlinked-2", company_id: "", created_at: "2025-01-01T00:00:00Z" },
  ];
  assert.deepEqual(capSelectedRows(rows, 2).map((row) => row.id), ["c", "b", "d", "e", "unlinked-1", "unlinked-2"]);
  assert.equal(capSelectedRows(rows, 0), rows);
});
