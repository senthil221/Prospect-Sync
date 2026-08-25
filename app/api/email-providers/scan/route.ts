import { authorizeApi } from "../../../../lib/auth";
import { lookupEmailProvider } from "../../../../lib/email-provider";
import { indexNotice, reindexProspectsOfCompanies } from "../../../../lib/reindex.ts";
import { createAdminClient } from "../../../../lib/supabase/admin";

export const runtime = "nodejs";

type ScanRequest = { afterId?: unknown; limit?: unknown; force?: unknown };
type CompanyCandidate = { id: string; domain: string; normalized_domain: string };

export async function POST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;

  let payload: ScanRequest = {};
  try { payload = await request.json() as ScanRequest; } catch { /* Use safe defaults. */ }
  const afterId = String(payload.afterId ?? "").trim().slice(0, 400);
  const limit = Math.max(1, Math.min(25, Number(payload.limit ?? 20) || 20));
  const force = payload.force === true;
  const supabase = createAdminClient();

  let query = supabase
    .from("companies")
    .select("id,domain,normalized_domain")
    .neq("normalized_domain", "")
    .order("id", { ascending: true })
    .limit(limit);
  if (afterId) query = query.gt("id", afterId);
  if (!force) query = query.is("mx_checked_at", null);

  const candidates = await query;
  if (candidates.error) {
    const migrationMissing = candidates.error.code === "42703" || candidates.error.code === "PGRST204" || /mx_checked_at/i.test(candidates.error.message);
    return Response.json(
      { error: migrationMissing ? "Apply the ESP database migration before scanning MX records." : candidates.error.message },
      { status: migrationMissing ? 503 : 500 },
    );
  }

  const companies = (candidates.data ?? []) as CompanyCandidate[];
  const checkedAt = new Date().toISOString();
  const results = await Promise.all(companies.map(async (company) => {
    const domain = company.normalized_domain || company.domain;
    const detection = await lookupEmailProvider(domain);
    const update = await supabase.from("companies").update({
      esp: detection.esp,
      email_provider_type: detection.category,
      mx_records: detection.mxRecords,
      mx_status: detection.status,
      mx_checked_at: checkedAt,
    }).eq("id", company.id);
    return { companyId: company.id, detection, error: update.error?.message ?? "" };
  }));

  // ESP fields live on companies, so refresh the flat index for their prospects.
  const reindexed = await reindexProspectsOfCompanies(supabase, results.filter((result) => !result.error).map((result) => result.companyId));
  const indexWarning = indexNotice(reindexed);

  const updated = results.filter((result) => !result.error).length;
  const failed = results.length - updated;
  const segs = results.filter((result) => !result.error && result.detection.category === "SEG").length;
  const nextCursor = companies.at(-1)?.id ?? afterId;

  return Response.json({
    checked: companies.length,
    updated,
    failed,
    segs,
    nextCursor,
    hasMore: companies.length === limit,
    notice: indexWarning,
  });
}
