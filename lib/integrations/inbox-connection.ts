export function inboxConnectionCurrent(
  connected: boolean,
  generation: string | null,
  verifiedGeneration: string | null,
  verifiedAt: string | null,
): boolean {
  return connected && !!generation && !!verifiedGeneration && !!verifiedAt && generation === verifiedGeneration;
}
