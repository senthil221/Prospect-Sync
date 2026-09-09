import { authorizeAdminApi } from "../../../../lib/auth";
import { createAdminClient } from "../../../../lib/supabase/admin";

const pageSize = 50;
const levels = new Set(["info", "warn", "error"]);

export async function GET(request: Request) {
  const unauthorized = await authorizeAdminApi();
  if (unauthorized) return unauthorized;

  const params = new URL(request.url).searchParams;
  const level = params.get("level") ?? "";
  const source = params.get("source") ?? "";
  const search = params.get("search")?.trim() ?? "";
  const page = Math.max(1, Number(params.get("page") ?? "1") || 1);
  const from = (page - 1) * pageSize;

  let query = createAdminClient()
    .from("system_event_log")
    .select("id, created_at, level, source, route, status_code, duration_ms, request_id, message, detail", { count: "exact" })
    .order("created_at", { ascending: false })
    .range(from, from + pageSize - 1);

  if (levels.has(level)) query = query.eq("level", level);
  if (source) query = query.eq("source", source);
  if (search) query = query.ilike("message", `%${search}%`);

  const { data, error, count } = await query;
  if (error) return Response.json({ error: error.message }, { status: 500 });
  return Response.json({ entries: data ?? [], total: count ?? 0, page, pageSize }, { headers: { "Cache-Control": "no-store" } });
}
