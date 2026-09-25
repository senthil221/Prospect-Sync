export type CapCandidate = { id: string; company_id?: unknown; created_at?: unknown };

// Explicit selections live in the browser rather than the database result-set
// builder. Apply the database's deterministic newest-first company quota before
// writing them, so the Export override has identical membership semantics.
export function capSelectedRows<Row extends CapCandidate>(rows: Row[], cap: number): Row[] {
  if (!Number.isSafeInteger(cap) || cap <= 0) return rows;
  const ranked = [...rows].sort((left, right) => {
    const rightTime = Date.parse(String(right.created_at ?? ""));
    const leftTime = Date.parse(String(left.created_at ?? ""));
    if (Number.isFinite(rightTime) && Number.isFinite(leftTime) && rightTime !== leftTime) return rightTime - leftTime;
    return String(right.id).localeCompare(String(left.id));
  });
  const counts = new Map<string, number>();
  const kept = new Set<string>();
  for (const row of ranked) {
    const companyId = String(row.company_id ?? "").trim();
    const group = companyId || `__person__:${row.id}`;
    const count = counts.get(group) ?? 0;
    if (count < cap) { kept.add(row.id); counts.set(group, count + 1); }
  }
  return rows.filter((row) => kept.has(row.id));
}
