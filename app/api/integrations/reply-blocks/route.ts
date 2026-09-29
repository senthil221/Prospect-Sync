import { getAuthorizedUser } from '../../../../lib/auth';
import { csvCell } from '../../../../lib/csv';
import { integrationAdmin } from '../../../../lib/integrations/credentials';
import { createAdminClient } from '../../../../lib/supabase/admin';

// What the Smartlead reply sync added to which client's blocklist, and why
// (the Smartlead category). Same audience as the Reply blocklist page: an
// integration administrator.
//
// GET ?client=&category=&kind=email|domain&search=&page=   summary + one page
// GET … &format=csv                                          the filtered log

export const runtime = 'nodejs';
const reply = (body: unknown, status = 200) => Response.json(body, { status, headers: { 'Cache-Control': 'no-store' } });
const pageSize = 50;
const csvLimit = 5000;

type BlockRow = {
  value: string; kind: string; client_name: string; reason: string; campaign_name: string | null;
  reply_email: string | null; reply_time: string | null; applied_at: string | null; created_at: string; status: string;
};

export async function GET(request: Request) {
  const user = await getAuthorizedUser();
  if (!user) return reply({ error: 'Unauthorized' }, 401);
  if (!integrationAdmin(user.email, process.env.INTEGRATION_ADMIN_EMAILS)) return reply({ error: 'Only an integration administrator can view reply blocks.' }, 403);

  const url = new URL(request.url);
  const category = Number(url.searchParams.get('category'));
  const kind = url.searchParams.get('kind');
  const csv = url.searchParams.get('format') === 'csv';
  const page = Math.max(1, Math.min(Number(url.searchParams.get('page') ?? 1) || 1, 10_000));
  const { data, error } = await createAdminClient().rpc('smartlead_reply_blocks_v1', {
    p_client_id: url.searchParams.get('client') || null,
    p_category_id: Number.isInteger(category) && category > 0 ? category : null,
    p_kind: kind === 'email' || kind === 'domain' ? kind : null,
    p_search: (url.searchParams.get('search') ?? '').trim().slice(0, 200),
    p_limit: csv ? csvLimit : pageSize,
    p_offset: csv ? 0 : (page - 1) * pageSize,
  }).abortSignal(AbortSignal.timeout(15000));
  if (error) {
    const missing = ['PGRST202', '42883'].includes(error.code ?? '');
    return reply({ error: missing ? 'Apply the latest database migration to see reply blocks.' : error.message }, missing ? 503 : 500);
  }

  if (!csv) return reply({ ...(data as object), page, pageSize });

  const rows = ((data as { rows?: BlockRow[] }).rows ?? []);
  const lines = [['Blocked value', 'Type', 'Client', 'Reason', 'Campaign', 'Reply from', 'Replied at', 'Added at', 'Status'].map(csvCell).join(',')];
  for (const row of rows) {
    lines.push([row.value, row.kind, row.client_name, row.reason, row.campaign_name ?? '', row.reply_email ?? '', row.reply_time ?? '',
      row.applied_at ?? row.created_at, row.status].map(csvCell).join(','));
  }
  return new Response(String.fromCharCode(0xfeff) + `${lines.join('\r\n')}\r\n`, {
    headers: {
      'Content-Type': 'text/csv; charset=utf-8',
      'Content-Disposition': `attachment; filename="reply-blocks-${new Date().toISOString().slice(0, 10)}.csv"`,
      'Cache-Control': 'no-store',
    },
  });
}
