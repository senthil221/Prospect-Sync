export const prospectImportBucket = "prospect-imports";
export const maximumProspectImportBytes = 1024 * 1024 * 1024;

export function validProspectImportObjectPath(value: unknown): value is string {
  return typeof value === "string" && /^pending\/[0-9a-f]{64}\.csv$/i.test(value);
}
