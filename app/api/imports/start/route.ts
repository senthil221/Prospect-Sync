import { ensureDatabase, getD1 } from "../../../../db/runtime";
import { normalizeText } from "../../../../db/normalize";

export async function POST(request: Request) {
  await ensureDatabase();
  const payload = await request.json() as { clientId?: string; clientName?: string; listName?: string; fileName?: string; totalRows?: number };
  const db = getD1();
  let clientId = payload.clientId ?? "";
  if (!clientId) {
    const clientName = String(payload.clientName ?? "").trim();
    if (!clientName) return Response.json({ error: "Choose or create a client." }, { status: 400 });
    const normalized = normalizeText(clientName);
    const existing = await db.prepare("SELECT id FROM clients WHERE normalized_name = ?").bind(normalized).first<{ id: string }>();
    clientId = existing?.id ?? crypto.randomUUID();
    if (!existing) await db.prepare("INSERT INTO clients (id, name, normalized_name) VALUES (?, ?, ?)").bind(clientId, clientName, normalized).run();
  }
  const listName = String(payload.listName ?? "").trim();
  if (!listName) return Response.json({ error: "List name is required." }, { status: 400 });
  const listId = crypto.randomUUID();
  const importId = crypto.randomUUID();
  await db.batch([
    db.prepare("INSERT INTO lists (id, client_id, name, source_file_name, uploaded_rows) VALUES (?, ?, ?, ?, ?)").bind(listId, clientId, listName, payload.fileName ?? "", payload.totalRows ?? 0),
    db.prepare("INSERT INTO imports (id, client_id, list_id, file_name, total_rows) VALUES (?, ?, ?, ?, ?)").bind(importId, clientId, listId, payload.fileName ?? "", payload.totalRows ?? 0),
  ]);
  return Response.json({ importId, listId, clientId }, { status: 201 });
}
