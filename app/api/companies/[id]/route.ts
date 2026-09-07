import { authorizeApi } from "../../../../lib/auth";
import { withInteractiveSlot } from "../../../../lib/admission";
import { createAdminClient } from "../../../../lib/supabase/admin";

// Everything stored about one company.
//
// The listing reads company_summaries, which is six columns - id, name, domain,
// created_at and the two denormalized counts - because a page of fifty rows has
// no use for a kilobyte of description each. So the drawer had six columns to
// show and showed the prospects instead, while the industry, keywords,
// technologies, founded year, employee range and location the import had
// already stored sat unreachable in the table.
//
// One row by primary key is the cheapest query in the database, and it only
// runs when somebody opens a company, so this fetches the whole profile rather
// than widening the listing. The columns are named rather than selected with *
// so that a new column on companies does not silently start being sent to the
// browser.
const detailColumns = [
  "id", "name", "domain", "industry", "keywords", "short_description", "founded_year",
  "technologies", "total_funding", "employee_count_min", "employee_count_max",
  "location", "city", "state", "country",
  "esp", "email_provider_type", "mx_records", "mx_status", "mx_checked_at",
  "prospect_count", "client_count", "created_at", "updated_at", "all_data",
].join(", ");

export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const companyId = String(id ?? "").trim();
  if (!companyId) return Response.json({ error: "That company id is not valid." }, { status: 400 });

  return withInteractiveSlot(request, async () => {
    const supabase = createAdminClient();
    const { data, error } = await supabase.from("companies").select(detailColumns).eq("id", companyId).maybeSingle();
    if (error) return Response.json({ error: error.message }, { status: 500 });
    if (!data) return Response.json({ error: "That company is no longer in the database." }, { status: 404 });
    return Response.json({ company: data });
  });
}
