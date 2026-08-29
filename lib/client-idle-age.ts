const millisecondsPerDay = 86_400_000;

export type ClientIdleAge = {
  days: number;
  label: string;
  tone: "fresh" | "waiting" | "idle" | "stale";
};

export function clientIdleAge(value: unknown, now = new Date()): ClientIdleAge | null {
  const date = String(value ?? "");
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || Number.isNaN(now.getTime())) return null;
  const [year, month, day] = date.split("-").map(Number);
  const contactedAt = Date.UTC(year, month - 1, day);
  const today = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
  const days = Math.max(0, Math.floor((today - contactedAt) / millisecondsPerDay));
  const tone = days >= 90 ? "stale" : days >= 30 ? "idle" : days >= 7 ? "waiting" : "fresh";
  return { days, label: days === 0 ? "Contacted today" : days === 1 ? "1 day ago" : `${days} days ago`, tone };
}
