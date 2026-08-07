import { authorizeApi } from "../../../lib/auth";
import { createAdminClient } from "../../../lib/supabase/admin";

export async function GET(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const clientId = new URL(request.url).searchParams.get("clientId");
  if (!clientId) return Response.json({ lists: [] });
  const { data, error } = await createAdminClient().from("list_summaries").select("*").eq("client_id", clientId).order("created_at", { ascending: false });
  if (error) return Response.json({ error: error.message }, { status: 500 });
  return Response.json({ lists: data ?? [] });
}
