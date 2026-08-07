import { ensureDatabase, getD1 } from "../../../db/runtime";

export async function GET(request: Request) {
  await ensureDatabase();
  const url = new URL(request.url);
  const search = (url.searchParams.get("search") ?? "").trim();
  const pattern = `%${search}%`;
  const where = search ? "WHERE c.name LIKE ? OR c.domain LIKE ?" : "";
  const bindings = search ? [pattern, pattern] : [];
  const result = await getD1().prepare(`SELECT c.id, c.name, c.domain, c.created_at,
    COUNT(DISTINCT p.id) AS prospect_count, COUNT(DISTINCT l.client_id) AS client_count
    FROM companies c LEFT JOIN prospects p ON p.company_id = c.id
    LEFT JOIN list_memberships lm ON lm.prospect_id = p.id LEFT JOIN lists l ON l.id = lm.list_id
    ${where} GROUP BY c.id ORDER BY prospect_count DESC, c.name LIMIT 100`).bind(...bindings).all();
  return Response.json({ companies: result.results });
}
