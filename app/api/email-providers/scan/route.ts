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

  // The DNS lookups are the real cost and stay parallel. The writes that follow
  // them used to be one UPDATE per company - 44,185 of them in production, each
  // rewriting all 23 indexes on companies, because mx_checked_at sits in
  // idx_companies_pending_mx_scan's predicate and cannot take the cheap path.
  // One statement for the whole batch instead (migration 20260902000250).
  const results = await Promise.all(companies.map(async (company) => {
    const domain = company.normalized_domain || company.domain;
    return { companyId: company.id, detection: await lookupEmailProvider(domain) };
  }));

  const applied = await supabase.rpc("apply_email_provider_scan_v1", {
    p_rows: results.map((result) => ({
      id: result.companyId,
      esp: result.detection.esp,
      email_provider_type: result.detection.category,
      mx_records: result.detection.mxRecords,
      mx_status: result.detection.status,
      mx_checked_at: checkedAt,
    })),
  });
  if (applied.error) {
    const migrationMissing = applied.error.code === "PGRST202" || applied.error.code === "42883";
    return Response.json(
      { error: migrationMissing ? "Apply the latest database migration to enable MX scanning." : applied.error.message },
      { status: migrationMissing ? 503 : 500 },
    );
  }

  // The batch is one statement, so it either lands or the request already
  // returned above. A row can still go missing if its company was deleted
  // between the read and the write, which the returned count catches.
  const updated = Number(applied.data ?? 0);
  const failed = results.length - updated;

  // ESP fields live on companies, so refresh the flat index for their prospects.
  const reindexed = await reindexProspectsOfCompanies(supabase, results.map((result) => result.companyId));
  const indexWarning = indexNotice(reindexed);

  const segs = results.filter((result) => result.detection.category === "SEG").length;
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
