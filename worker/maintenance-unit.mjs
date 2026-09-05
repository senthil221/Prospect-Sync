// SET LOCAL applies the deadline before the cleanup statement starts and is
// reverted on commit/rollback. Do not leave the next search under a 3s deadline.
export async function runMaintenanceUnit(client, kind) {
  if (!['search', 'filter', 'operation', 'export', 'metrics'].includes(kind)) throw new Error('Invalid maintenance class');
  await client.query('BEGIN');
  try {
    await client.query("SET LOCAL statement_timeout = '3s'");
    await client.query("SET LOCAL lock_timeout = '250ms'");
    const result = kind === 'metrics'
      ? await client.query('select prospect_operations.prune_metrics_v1() as items_removed')
      : await client.query('select * from prospect_operations.reclaim_unit_v1($1,5000)', [kind]);
    await client.query('COMMIT');
    return result.rows[0] ?? {};
  } catch (error) {
    try { await client.query('ROLLBACK'); } catch { /* The caller handles a dead connection. */ }
    throw error;
  }
}
