export function csvCell(value: unknown) {
  const text = String(value ?? "");
  const safe = /^[=+\-@\t\r]/.test(text) ? `'${text}` : text;
  return `"${safe.replace(/"/g, '""')}"`;
}

export function csvDocument(headers: string[], rows: unknown[][]) {
  return `\uFEFF${[
    headers.map(csvCell).join(","),
    ...rows.map((row) => row.map(csvCell).join(",")),
  ].join("\r\n")}`;
}

// A Content-Disposition for a download named after what it holds
// ("ICP check - Balanced - Acme - Growers - 2026-09-30.csv"). Characters a
// file system rejects are dropped; the plain filename is an ASCII fallback and
// filename* carries the exact UTF-8 name for browsers that read it.
export function attachmentDisposition(name: string) {
  const clean = [...name].map((char) => char.charCodeAt(0) < 32 || '\\/:*?"<>|'.includes(char) ? " " : char).join("")
    .replace(/\s+/g, " ").trim().slice(0, 180) || "download.csv";
  const ascii = clean.replace(/[^\x20-\x7e]/g, "_");
  return `attachment; filename="${ascii}"; filename*=UTF-8''${encodeURIComponent(clean)}`;
}
