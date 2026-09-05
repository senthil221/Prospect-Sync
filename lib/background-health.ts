// Aggregate alerts only: no job IDs, owners, search terms or customer rows.
export function backgroundAlerts(snapshot: unknown) {
  if (!snapshot || typeof snapshot !== 'object') return ['telemetry_unavailable'];
  const value = snapshot as Record<string, unknown>;
  const alerts: string[] = [];
  if (Array.isArray(value.queues) && value.queues.some(q => q && typeof q === 'object' && Number(q.oldest_seconds) > 60)) alerts.push('background_queue_delayed');
  if (Number(value.searchBytes) >= 4 * 1024 ** 3) alerts.push('search_storage_hard_threshold');
  else if (Number(value.searchBytes) >= 2 * 1024 ** 3) alerts.push('search_storage_soft_threshold');
  if (Array.isArray(value.recentJobs)) {
    let jobs = 0, failures = 0;
    for (const row of value.recentJobs) {
      if (!row || typeof row !== 'object') continue;
      const count = Number(row.jobs);
      if (!Number.isFinite(count) || count < 0) continue;
      jobs += count;
      if (row.outcome === 'failed') failures += count;
    }
    if (jobs >= 100 && failures / jobs > 0.01) alerts.push('background_failure_rate');
    else if (failures > 0) alerts.push('background_failures_present');
  }
  return alerts;
}
