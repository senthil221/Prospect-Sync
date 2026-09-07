import { authorizeApi } from "../../../../lib/auth";
import { createAdminClient } from "../../../../lib/supabase/admin";

// The uploaded column names an export picker can offer beyond the typed ones.
//
// Companies have no equivalent of the prospect_fields registry, so this is a
// bounded sample rather than a list (see company_export_field_names_v1). That
// makes it advisory: it finds every column an import brought, because a CSV
// gives the same headers to every row it writes, but it is not a promise that
// nothing else exists anywhere in the table.
//
// Which is why every failure here answers with an empty list and a 200. The
// picker's typed fields are the point of it; the uploaded ones are extra, and
// an export dialog that refuses to open because a sampling scan was slow would
// be a worse trade than one that quietly offers five fewer checkboxes.
export async function GET() {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const supabase = createAdminClient();
  const { data, error } = await supabase.rpc("company_export_field_names_v1", { p_limit: 200 });
  if (error) return Response.json({ fields: [], sampled: false });
  const fields = (data ?? [])
    .map((row: { field_name?: unknown }) => String(row.field_name ?? "").trim())
    .filter(Boolean);
  return Response.json({ fields, sampled: true });
}
