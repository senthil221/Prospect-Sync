export async function* csvRows(stream) {
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  let row = [];
  let value = "";
  let quoted = false;
  let pendingQuote = false;
  let skipLf = false;
  let firstCell = true;
  const emitCell = () => {
    if (firstCell) { value = value.replace(/^\uFEFF/, ""); firstCell = false; }
    row.push(value);
    value = "";
  };
  while (true) {
    const { value: bytes, done } = await reader.read();
    const text = decoder.decode(bytes, { stream: !done });
    for (const char of text) {
      if (skipLf) { skipLf = false; if (char === "\n") continue; }
      if (pendingQuote) {
        pendingQuote = false;
        if (char === '"') { value += '"'; continue; }
        quoted = false;
      }
      if (char === '"') {
        if (quoted) pendingQuote = true;
        else quoted = true;
      } else if (char === "," && !quoted) {
        emitCell();
      } else if ((char === "\r" || char === "\n") && !quoted) {
        if (char === "\r") skipLf = true;
        emitCell();
        if (row.some((cell) => cell.trim())) yield row;
        row = [];
      } else value += char;
    }
    if (done) break;
  }
  if (pendingQuote) quoted = false;
  if (quoted) throw new Error("CSV has an unterminated quoted field.");
  emitCell();
  if (row.some((cell) => cell.trim())) yield row;
}
export function uniqueHeaders(headers) {
  const used = new Map();
  return headers.map((header, index) => {
    const base = String(header).trim() || `Column ${index + 1}`;
    const normalized = base.toLowerCase();
    const count = (used.get(normalized) ?? 0) + 1;
    used.set(normalized, count);
    return count === 1 ? base : `${base} (${count})`;
  });
}
