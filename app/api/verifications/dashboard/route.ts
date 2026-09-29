import { getAuthorizedUser } from '../../../../lib/auth';
import { createAdminClient } from '../../../../lib/supabase/admin';

// The Email verification page's one read: provider state, queue, result mix,
// throughput and the latest runs (email_verification_dashboard_v1). Controls
// stay on the existing routes: /api/verifications/[id] for a run,
// /api/verifications/provider (admins) for dispatch.

export const runtime = 'nodejs';
const reply = (body: unknown, status = 200) => Response.json(body, { status, headers: { 'Cache-Control': 'no-store' } });

export async function GET() {
  const user = await getAuthorizedUser().catch(() => null);
  if (!user) return reply({ error: 'Unauthorized' }, 401);
  const { data, error } = await createAdminClient().rpc('email_verification_dashboard_v1', { p_runs: 15 }).abortSignal(AbortSignal.timeout(15000));
  if (error) {
    const missing = ['PGRST202', '42883'].includes(error.code ?? '');
    return reply({ error: missing ? 'Apply the latest database migration to see verification progress.' : 'Verification status is unavailable right now.' }, missing ? 503 : 500);
  }
  return reply(data);
}
