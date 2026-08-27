export const prospectImportBucket = "prospect-imports";
export const maximumProspectImportBytes = 1024 * 1024 * 1024;

const userIdPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const fingerprintPattern = /^[0-9a-f]{64}$/i;

export function prospectImportObjectPath(userId: string, fingerprint: string) {
  if (!userIdPattern.test(userId) || !fingerprintPattern.test(fingerprint)) {
    throw new Error("Invalid prospect import storage identity.");
  }
  return `pending/${userId.toLowerCase()}/${fingerprint.toLowerCase()}.csv`;
}

export function validProspectImportObjectPath(value: unknown, userId?: string): value is string {
  if (typeof value !== "string") return false;
  const match = value.match(/^pending\/([0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})\/[0-9a-f]{64}\.csv$/i);
  return Boolean(match && (!userId || match[1].toLowerCase() === userId.toLowerCase()));
}
