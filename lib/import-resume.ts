export function importHeaderSignature(headers: string[]) {
  return JSON.stringify(headers.map((header) => String(header).trim()));
}

export function importHeadersMatch(headers: string[], expectedSignature: string) {
  return importHeaderSignature(headers) === expectedSignature;
}
