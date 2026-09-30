// 450ms, with the claim's 22-per-10s guard: just under MailTester Ninja's
// documented Ultimate-plan limit of 23 per 10s / one per 430ms (~132/min,
// ~190k/day). 400ms / 25 per 10s exceeded it - see 20260930190000.
export const PROVIDER_START_SPACING_MS = 450;

export function claimDelayMilliseconds(lastClaimAt, now = Date.now(), spacingMs = PROVIDER_START_SPACING_MS) {
  if (!Number.isFinite(lastClaimAt) || lastClaimAt <= 0) return 0;
  return Math.max(0, spacingMs - Math.max(0, now - lastClaimAt));
}

// Bound starts per outer maintenance tick. A very fast provider can finish a
// request while slots are still being filled; without this budget the fill
// loop never returns to heartbeat, snapshot, allocation, or reconciliation.
export async function fillDispatchSlots({
  maxStarts,
  concurrency,
  inFlightSize,
  claim,
  start,
  wait,
  now = Date.now,
  spacingMs = PROVIDER_START_SPACING_MS,
  lastClaimAt = 0,
  canStart = () => true,
}) {
  let started = 0;
  while (started < maxStarts && canStart() && inFlightSize() < concurrency) {
    const delay = claimDelayMilliseconds(lastClaimAt, now(), spacingMs);
    if (delay) await wait(delay);
    const unit = await claim();
    if (!unit) break;
    if (!canStart()) break;
    lastClaimAt = now();
    started += 1;
    start(unit);
  }
  return { started, lastClaimAt };
}
