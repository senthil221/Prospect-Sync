import { authorizeApi } from '../../../../lib/auth';
import { readBoundedJson } from '../../../../lib/bounded-json';
import { integrationWriteAllowed } from '../../../../lib/integrations/credentials';
import { createAdminClient } from '../../../../lib/supabase/admin';
import { observed } from "../../../../lib/observability";

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
async function handlePOST(request: Request, context: RouteContext<'/api/verifications/[id]'>) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const publicUrl = process.env.APP_PUBLIC_URL || (process.env.NODE_ENV !== 'production' ? new URL(request.url).origin : undefined);
  if (!integrationWriteAllowed(request, publicUrl)) return Response.json({ error: 'Same-origin JSON requests are required.' }, { status: 403 });
  const { id } = await context.params;
  const decoded = await readBoundedJson(request, { bytes: 1024, depth: 2, timeoutMs: 3000 });
  if (decoded.response) return decoded.response;
  const action = String((decoded.value as { action?: unknown } | null)?.action ?? '');
  if (!uuid.test(id) || !['pause', 'continue', 'cancel'].includes(action)) return Response.json({ error: 'Invalid verification control.' }, { status: 400 });
  const { data, error } = await createAdminClient().rpc('control_email_verification_run_v1', { p_run_id: id, p_action: action });
  return error ? Response.json({ error: error.code === 'P0002' ? 'Verification run not found.' : 'Unable to update the run.' }, { status: error.code === 'P0002' ? 404 : 409 })
    : Response.json({ run: data }, { headers: { 'Cache-Control': 'no-store' } });
}

export const POST = observed("/api/verifications/[id]", handlePOST);
