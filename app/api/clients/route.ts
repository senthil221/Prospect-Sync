import { ensureDatabase, getD1 } from "../../../db/runtime";
import { normalizeText } from "../../../db/normalize";

export async function GET() {
  await ensureDatabase();
  const result = await getD1().prepare(`SELECT c.id, c.name, c.created_at,
    COUNT(DISTINCT l.id) AS list_count, COUNT(DISTINCT lm.prospect_id) AS prospect_count
    FROM clients c LEFT JOIN lists l ON l.client_id = c.id
    LEFT JOIN list_memberships lm ON lm.list_id = l.id
    GROUP BY c.id ORDER BY c.name`).all();
  return Response.json({ clients: result.results });
}

export async function POST(request: Request) {
  await ensureDatabase();
  const { name } = await request.json() as { name?: string };
  const cleaned = String(name ?? "").trim();
  if (!cleaned) return Response.json({ error: "Client name is required." }, { status: 400 });
  const db = getD1();
  const normalized = normalizeText(cleaned);
  const existing = await db.prepare("SELECT id, name FROM clients WHERE normalized_name = ?").bind(normalized).first();
  if (existing) return Response.json({ client: existing });
  const id = crypto.randomUUID();
  await db.prepare("INSERT INTO clients (id, name, normalized_name) VALUES (?, ?, ?)").bind(id, cleaned, normalized).run();
  return Response.json({ client: { id, name: cleaned } }, { status: 201 });
}
