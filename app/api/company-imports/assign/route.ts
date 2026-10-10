import { authorizeApi, getAuthorizedUser } from "../../../../lib/auth";
import { createAdminClient } from "../../../../lib/supabase/admin";
import { observed } from "../../../../lib/observability";

// Adds a finished company import's companies to the client it was imported for,
// tagged with the chosen ICP (apply_company_import_to_client_v1,
// 20261010140000). One page per call; the import keeps its place, so the
// browser repeats the call until `done` and can pick up again after a reload.
const missingCodes = new Set(["PGRST202", "42883", "42703"]);

async function handlePOST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const payload = await request.json().catch(() => null) as { importId?: unknown } | null;
  const importId = String(payload?.importId ?? "").trim();
  if (!importId) return Response.json({ error: "Invalid company import." }, { status: 400 });
  const user = await getAuthorizedUser();
  const { data, error } = await createAdminClient().rpc("apply_company_import_to_client_v1", {
    p_import_id: importId, p_limit: 2000, p_actor: user?.email ?? "",
  });
  if (error) {
    if (error.code && missingCodes.has(error.code)) return Response.json({ error: "Apply the latest database migration to add imported companies to a client." }, { status: 503 });
    return Response.json({ error: error.message }, { status: error.code === "P0002" ? 404 : error.code === "22023" ? 400 : 500 });
  }
  return Response.json(data);
}

export const POST = observed("/api/company-imports/assign", handlePOST);
