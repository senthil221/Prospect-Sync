import { authorizeAdminApi } from '../../../../lib/auth';
import { readBoundedJson } from '../../../../lib/bounded-json';
import { integrationWriteAllowed } from '../../../../lib/integrations/credentials';
import { createAdminClient } from '../../../../lib/supabase/admin';
import { observed } from "../../../../lib/observability";

async function handlePOST(request: Request) {
  const unauthorized = await authorizeAdminApi();
  if (unauthorized) return unauthorized;
  const publicUrl = process.env.APP_PUBLIC_URL || (process.env.NODE_ENV !== 'production' ? new URL(request.url).origin : undefined);
  if (!integrationWriteAllowed(request, publicUrl)) return Response.json({ error: 'Same-origin JSON requests are required.' }, { status: 403 });
  const decoded = await readBoundedJson(request, { bytes: 2048, depth: 2, timeoutMs: 3000 });
  if (decoded.response) return decoded.response;
  const payload = decoded.value as { action?: unknown; reason?: unknown } | null;
  const action = String(payload?.action ?? '');
  if (!['start', 'pause', 'continue', 'stop'].includes(action)) return Response.json({ error: 'Invalid provider control.' }, { status: 400 });
  const { data, error } = await createAdminClient().rpc('control_email_verification_provider_v1', {
    p_action: action, p_reason: typeof payload?.reason === 'string' ? payload.reason.slice(0, 300) : null,
  });
  return error ? Response.json({ error: 'Unable to update provider dispatch.' }, { status: 409 })
    : Response.json({ provider: data }, { headers: { 'Cache-Control': 'no-store' } });
}

export const POST = observed("/api/verifications/provider", handlePOST);
