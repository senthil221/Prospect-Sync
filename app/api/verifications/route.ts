import { getAuthorizedUser } from '../../../lib/auth';
import { readBoundedJson } from '../../../lib/bounded-json';
import { authorizeFilterSets } from '../../../lib/filter-sets';
import { filterErrorResponse, parseFilters } from '../../../lib/prospect-filters';
import { createAdminClient } from '../../../lib/supabase/admin';
import { integrationWriteAllowed } from '../../../lib/integrations/credentials';
import { parseCompanyScope } from '../../../lib/workspace-scopes';
import { scopeRestricts } from '../../../lib/workspace-scopes';
import { prepareCompanyScope } from '../../../lib/prepare-company-scope';
import { ownerIdentity } from '../../../lib/result-sets';

export const runtime = 'nodejs';
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const reply = (body: unknown, status = 200) => Response.json(body, { status, headers: { 'Cache-Control': 'no-store' } });

export async function GET() {
  const user = await getAuthorizedUser().catch(() => null);
  if (!user) return reply({ error: 'Unauthorized' }, 401);
  const { data, error } = await createAdminClient().rpc('email_verification_runs_v1', { p_limit: 30 }).abortSignal(AbortSignal.timeout(5000));
  return error ? reply({ error: 'Verification status is unavailable. Apply the latest database migration.' }, 503) : reply(data);
}

export async function POST(request: Request) {
  const user = await getAuthorizedUser().catch(() => null);
  if (!user) return reply({ error: 'Unauthorized' }, 401);
  const publicUrl = process.env.APP_PUBLIC_URL || (process.env.NODE_ENV !== 'production' ? new URL(request.url).origin : undefined);
  if (!integrationWriteAllowed(request, publicUrl)) return reply({ error: 'Same-origin JSON requests are required.' }, 403);
  const decoded = await readBoundedJson(request, { bytes: 1_100_000, depth: 64, timeoutMs: 5000 });
  if (decoded.response) return decoded.response;
  const raw = decoded.value as Record<string, unknown> | null;
  if (!raw || Array.isArray(raw) || !uuid.test(String(raw.requestId ?? '')) || !['all', 'filtered'].includes(String(raw.scope))) {
    return reply({ error: 'Choose a valid verification scope and request ID.' }, 400);
  }
  const scope = String(raw.scope) as 'all' | 'filtered';
  let filters = [];
  let companyScope = null;
  try {
    filters = scope === 'filtered' ? parseFilters(JSON.stringify(raw.filters ?? [])) : [];
    companyScope = scope === 'filtered' && raw.companyScope
      ? parseCompanyScope(JSON.stringify(raw.companyScope)) : null;
  } catch (error) { return filterErrorResponse(error, 'Invalid verification filters.'); }
  const search = scope === 'filtered' ? String(raw.search ?? '').trim() : '';
  if (search.length > 300 || typeof raw.forceReverify !== 'boolean') return reply({ error: 'Invalid verification request.' }, 400);
  const db = createAdminClient();
  const denial = await authorizeFilterSets(db, filters, user.id, 'prospect', '', companyScope
    ? [{ entityType: 'company', clientScope: '', filters: companyScope.filters }] : []);
  if (denial) return denial;
  let resolvedCompanyScope: Record<string, unknown> = companyScope ?? {};
  if (scope === 'filtered' && scopeRestricts(companyScope)) {
    const prepared = await prepareCompanyScope(db, ownerIdentity(user), companyScope!);
    if (prepared.response) return prepared.response;
    if ((prepared.matchedCompanies ?? 0) > companyScope!.limit) {
      return reply({ error: `This company scope matches more than its ${companyScope!.limit.toLocaleString('en-IN')} company safety limit. Narrow the company filters before verifying so no matches are silently omitted.` }, 409);
    }
    resolvedCompanyScope = prepared.scope ?? companyScope!;
  }
  const payload = { scope, search, filters, companyScope: resolvedCompanyScope,
    intentCompanyScope: companyScope ?? {}, forceReverify: raw.forceReverify };
  const { data, error } = await db.rpc('request_email_verification_v1', {
    p_request_id: String(raw.requestId), p_payload: payload, p_actor_id: user.id,
  }).abortSignal(AbortSignal.timeout(5000));
  if (error?.code === '23505') return reply({ error: 'This request ID was already used with different options.' }, 409);
  if (error) return reply({ error: 'Unable to create the verification run.' }, 503);
  return reply({ run: data }, 202);
}
