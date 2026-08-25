import { authorizeApi, getAuthorizedUser } from "../../../lib/auth.ts";
import { createAdminClient } from "../../../lib/supabase/admin";

const missingFunctionCodes = new Set(["PGRST202", "42883", "42P01"]);

function failure(error: { code?: string; message: string }) {
  const missing = Boolean(error.code && missingFunctionCodes.has(error.code));
  return Response.json(
    { error: missing ? "Apply the latest database migration to enable gap filling." : error.message },
    { status: missing ? 503 : 500 },
  );
}

// What would be filled, without filling anything. The apply step is only ever
// reached after the user has seen these numbers.
export async function GET() {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { data, error } = await createAdminClient().rpc("enrichment_preview_v1", { p_limit: 25 });
  if (error) return failure(error);
  return Response.json({ preview: data ?? { companies: 0, fields: 0, sample: [] } });
}

export async function POST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const user = await getAuthorizedUser();
  const payload = await request.json().catch(() => null) as { companyIds?: unknown } | null;
  const companyIds = Array.isArray(payload?.companyIds)
    ? [...new Set(payload.companyIds.map((value) => String(value ?? "").trim()).filter(Boolean))].slice(0, 50000)
    : null;

  const { data, error } = await createAdminClient().rpc("enrich_from_company_v1", {
    p_company_ids: companyIds,
    p_actor: user?.email ?? "",
  });
  if (error) return failure(error);
  return Response.json({ result: data });
}
