import { ensureDatabase, getD1 } from "../../../db/runtime";

export async function GET() {
  await ensureDatabase();
  const db = getD1();
  const results = await db.batch([
    db.prepare("SELECT COUNT(*) AS count FROM prospects"),
    db.prepare("SELECT COUNT(*) AS count FROM companies"),
    db.prepare("SELECT COUNT(*) AS count FROM clients"),
    db.prepare("SELECT COUNT(*) AS count FROM lists"),
    db.prepare("SELECT COALESCE(SUM(processed_rows), 0) AS count FROM imports"),
    db.prepare("SELECT COALESCE(SUM(duplicates_linked), 0) AS count FROM imports"),
    db.prepare(`SELECT i.id, i.file_name, i.status, i.processed_rows, i.unique_added,
      i.duplicates_linked, i.created_at, c.name AS client_name, l.name AS list_name
      FROM imports i JOIN clients c ON c.id = i.client_id JOIN lists l ON l.id = i.list_id
      ORDER BY i.created_at DESC LIMIT 6`),
  ]);
  const count = (index: number) => Number((results[index].results[0] as { count?: number } | undefined)?.count ?? 0);
  return Response.json({
    stats: {
      prospects: count(0), companies: count(1), clients: count(2), lists: count(3),
      rowsImported: count(4), duplicatesDetected: count(5),
    },
    recentImports: results[6].results,
  });
}
