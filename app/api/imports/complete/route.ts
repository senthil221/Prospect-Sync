import { ensureDatabase, getD1 } from "../../../../db/runtime";

export async function POST(request: Request) {
  await ensureDatabase();
  const { importId, listId } = await request.json() as { importId?: string; listId?: string };
  if (!importId || !listId) return Response.json({ error: "Invalid import." }, { status: 400 });
  const db = getD1();
  await db.batch([
    db.prepare("UPDATE imports SET status = 'completed', completed_at = CURRENT_TIMESTAMP WHERE id = ?").bind(importId),
    db.prepare(`UPDATE lists SET unique_added = (SELECT unique_added FROM imports WHERE id = ?),
      duplicates_linked = (SELECT duplicates_linked FROM imports WHERE id = ?),
      uploaded_rows = (SELECT processed_rows FROM imports WHERE id = ?) WHERE id = ?`).bind(importId, importId, importId, listId),
  ]);
  const summary = await db.prepare("SELECT processed_rows, unique_added, duplicates_linked FROM imports WHERE id = ?").bind(importId).first();
  return Response.json({ summary });
}
