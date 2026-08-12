import { authorizeApi } from "../../../../lib/auth";
import { createAdminClient } from "../../../../lib/supabase/admin";

export async function POST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const payload = await request.json().catch(() => null) as { importId?: unknown } | null;
  const importId = String(payload?.importId ?? "").trim();
  if (!importId) return Response.json({ error: "Invalid company import." }, { status: 400 });
  const supabase = createAdminClient();
  const { data, error } = await supabase.rpc("complete_company_import_v1", { p_import_id: importId });
  if (error) return Response.json({ error: error.message }, { status: 500 });
  return Response.json({ summary: data?.[0] ?? null });
}
