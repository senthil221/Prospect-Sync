export const MAX_MANUAL_VERIFICATION_EMAILS = 200_000;

export function parseManualVerificationEmailLimit(value: unknown): number | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== "number" || !Number.isSafeInteger(value)
    || value < 1 || value > MAX_MANUAL_VERIFICATION_EMAILS) {
    throw new Error(`Maximum unique work emails must be a whole number from 1 to ${MAX_MANUAL_VERIFICATION_EMAILS.toLocaleString("en-IN")}.`);
  }
  return value;
}
