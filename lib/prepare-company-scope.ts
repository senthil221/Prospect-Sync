import type { createAdminClient } from './supabase/admin';
import type { CompanyScope } from './workspace-scopes';

export function preparationResponse(status: string, matchedCompanies = 0) {
  return Response.json({ preparation: {
    status, matchedCompanies,
    message: status === 'pending' ? 'Your company search is queued. You can keep using other tabs.'
      : status === 'refreshing' ? 'Company data changed. Refreshing the matching companies…'
      : 'Finding the matching companies. This search will be reused for pages and People filters…',
  } }, { status: 202, headers: { 'Cache-Control': 'no-store', 'Retry-After': '2' } });
}

export async function prepareCompanyScope(supabase: ReturnType<typeof createAdminClient>, owner: string, scope: CompanyScope, signal?: AbortSignal) {
  const prepared = await supabase.rpc('prepare_company_scope_v1', { p_owner_id: owner, p_scope: scope })
    .abortSignal(signal ?? AbortSignal.timeout(10_000));
  if (prepared.error) return { response: Response.json({ error:
    ['PGRST202','42883'].includes(prepared.error.code) ? 'Apply the latest database migration to enable prepared company searches.' : prepared.error.message,
  }, { status: 503, headers: { 'Retry-After': '3' } }) };
  const row = Array.isArray(prepared.data) ? prepared.data[0] : prepared.data;
  if (!row?.set_id) return { response: Response.json({ error: 'Unable to prepare this company search.' }, { status: 500 }) };
  if (row.status === 'failed') return { response: Response.json({ error: 'The company search could not finish. Please retry in a moment or adjust the search.' }, { status: 500 }) };
  if (row.status !== 'ready') return { response: preparationResponse(row.status, Number(row.row_count ?? 0)) };
  return { scope: { ...scope, _prepared_set_id: String(row.set_id), _prepared_owner: owner } };
}
