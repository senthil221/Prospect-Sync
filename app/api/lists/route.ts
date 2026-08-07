import { ensureDatabase, getD1 } from "../../../db/runtime";

export async function GET(request: Request) {
  await ensureDatabase();
  const clientId = new URL(request.url).searchParams.get("clientId");
  if (!clientId) return Response.json({ lists: [] });
  const result = await getD1().prepare(`SELECT l.id, l.name, l.source_file_name, l.uploaded_rows,
    l.unique_added, l.duplicates_linked, l.created_at, COUNT(lm.prospect_id) AS prospect_count
    FROM lists l LEFT JOIN list_memberships lm ON lm.list_id = l.id
    WHERE l.client_id = ? GROUP BY l.id ORDER BY l.created_at DESC`).bind(clientId).all();
  return Response.json({ lists: result.results });
}
