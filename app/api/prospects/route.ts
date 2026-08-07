import { ensureDatabase, getD1 } from "../../../db/runtime";

export async function GET(request: Request) {
  await ensureDatabase();
  const url = new URL(request.url);
  const search = (url.searchParams.get("search") ?? "").trim();
  const page = Math.max(1, Number(url.searchParams.get("page") ?? 1));
  const limit = 30;
  const offset = (page - 1) * limit;
  const db = getD1();
  const pattern = `%${search}%`;
  const where = search ? `WHERE p.full_name LIKE ? OR p.work_email LIKE ? OR p.title LIKE ? OR c.name LIKE ? OR c.domain LIKE ?` : "";
  const bindings = search ? [pattern, pattern, pattern, pattern, pattern] : [];
  const rowsQuery = db.prepare(`SELECT p.id, p.full_name, p.first_name, p.last_name, p.work_email,
    p.personal_email, p.mobile_number, p.linkedin_url, p.title, p.seniority, p.department,
    p.city, p.state, p.country, p.all_data, p.created_at, c.name AS company_name, c.domain AS company_domain,
    COUNT(DISTINCT lm.list_id) AS list_count, COUNT(DISTINCT l.client_id) AS client_count
    FROM prospects p LEFT JOIN companies c ON c.id = p.company_id
    LEFT JOIN list_memberships lm ON lm.prospect_id = p.id LEFT JOIN lists l ON l.id = lm.list_id
    ${where} GROUP BY p.id ORDER BY p.created_at DESC LIMIT ? OFFSET ?`).bind(...bindings, limit, offset);
  const countQuery = db.prepare(`SELECT COUNT(*) AS count FROM prospects p LEFT JOIN companies c ON c.id = p.company_id ${where}`).bind(...bindings);
  const [rows, total] = await db.batch([rowsQuery, countQuery]);
  return Response.json({ prospects: rows.results, total: Number((total.results[0] as { count?: number })?.count ?? 0), page, limit });
}
