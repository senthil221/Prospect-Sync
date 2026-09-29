import type { Campaign } from '../../lib/integrations/provider-api';
import type { Provider } from '../../lib/integrations/credentials';

type Connection = { provider: Provider; connected: boolean; checked_at: string | null };
type Destination = { client_id: string; campaign_id: number; campaign_name: string; connection_current: boolean };

export type IntegrationStatus = { connections: Connection[]; canManage: boolean; encryptionReady: boolean; dispatchEnabled: boolean;
  campaigns?: Campaign[]; clients?: { id: string; name: string }[]; destinations?: Destination[];
  jobs?: { id: string; client_id: string; campaign_id: number; status: string; total: number; created_at: string }[];
  progress?: { creations: { id: string; name: string; status: string; campaign_id: number | null; error_code: string | null }[];
    deliveries: { id: string; status: string; added: number; skipped: number; suppressed: number; error_code: string | null }[] };
  inbox?: { settings: { enabled: boolean; verified_at: string | null; verified_contract: string | null; initial_backfill_complete: boolean;
      scan_offset: number; status: string; pages_scanned: number; rows_observed: number; last_synced_at: string | null; last_error_code: string | null };
    counts: { observed: number; unmatched: number; pending: number; applied: number; manualRemoved: number };
    unmatched: { campaign_name: string; mapping_status: string; replies: number }[];
    mappings: { prefix: string; client_id: string; client_name: string }[] } };

export async function readIntegrationStatus(signal?: AbortSignal): Promise<IntegrationStatus> {
  const response = await fetch('/api/integrations', { cache: 'no-store', signal });
  const body = await response.json();
  if (!response.ok) throw new Error(body.error ?? 'Unable to load connections.');
  return body;
}
