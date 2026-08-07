import { authorizeApi } from "../../../lib/auth";
import { createAdminClient } from "../../../lib/supabase/admin";

export async function GET() {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { data, error } = await createAdminClient().rpc("data_quality_overview");
  if (error) return Response.json({ error: error.message }, { status: 500 });
  return Response.json({ quality: data ?? {} });
}
