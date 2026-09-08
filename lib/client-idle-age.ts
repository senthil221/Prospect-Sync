const millisecondsPerDay = 86_400_000;

export type ClientIdleAge = {
  days: number;
  label: string;
  tone: "fresh" | "waiting" | "idle" | "stale";
  eligible: boolean;
  daysRemaining: number;
  nextEligibleDate: string;
};

export function clientIdleAge(value: unknown, cooldownDaysOrNow: number | Date = 90, currentDate = new Date()): ClientIdleAge | null {
  // Keep the original `(date, now)` caller form working while allowing the
  // client-specific cooldown to be supplied as `(date, days, now)`.
  const cooldownDays = cooldownDaysOrNow instanceof Date ? 90 : cooldownDaysOrNow;
  const now = cooldownDaysOrNow instanceof Date ? cooldownDaysOrNow : currentDate;
  const date = String(value ?? "");
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || Number.isNaN(now.getTime())) return null;
  const [year, month, day] = date.split("-").map(Number);
  const contactedAt = Date.UTC(year, month - 1, day);
  if (new Date(contactedAt).toISOString().slice(0, 10) !== date) return null;
  const today = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
  const days = Math.max(0, Math.floor((today - contactedAt) / millisecondsPerDay));
  const cooldown = Number.isFinite(cooldownDays) ? Math.max(0, Math.min(730, Math.round(cooldownDays))) : 90;
  const daysRemaining = Math.max(0, Math.ceil((contactedAt + cooldown * millisecondsPerDay - today) / millisecondsPerDay));
  const eligible = daysRemaining === 0;
  const next = new Date(contactedAt + cooldown * millisecondsPerDay).toISOString().slice(0, 10);
  const tone = eligible ? "stale" : daysRemaining <= 7 ? "idle" : days >= 7 ? "waiting" : "fresh";
  return {
    days,
    eligible,
    daysRemaining,
    nextEligibleDate: next,
    label: eligible ? "Eligible now" : daysRemaining === 1 ? "Eligible in 1 day" : `Eligible in ${daysRemaining} days`,
    tone,
  };
}
