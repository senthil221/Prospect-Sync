// Read a streamed CSV response without ever holding all of it.
//
// The export endpoints answer with text/csv now rather than with JSON pages, so
// the browser gets bytes as the database produces them. Two things still have
// to be true on this side, and neither is free:
//
// 1. IT HAS TO CUT ON RECORD BOUNDARIES. A network chunk lands wherever TCP
//    decided, which is usually in the middle of a row and sometimes in the
//    middle of a quoted cell containing a newline. Writing chunks straight to a
//    file is fine; splitting a multi-file export at one is not, and neither is
//    counting rows by counting newlines.
//
// 2. IT HAS TO COUNT. The old endpoint reported the row count in a header. A
//    streamed response cannot: the count is not known when the headers are
//    sent. So the count is taken here, from the records as they go past.
//
// The scan is quote-aware and runs on indexOf rather than character by
// character, because a 25 MB export is 25 million characters and a per-character
// loop is the difference between an imperceptible pause and a visible one. An
// escaped "" inside a quoted cell closes and reopens the quote, which lands in
// the same state it started in, so it needs no special case.

export type CsvStreamHandlers = {
  // The header record, without its line terminator. Includes the byte-order
  // mark, because the server put it there and every part file needs it.
  onHeader?: (header: string) => void | Promise<void>;
  // One or more complete data records, joined by CRLF, with no terminator at
  // either end. Safe to cut a file before or after this text.
  onRows: (text: string, rows: number) => void | Promise<void>;
};

export async function readCsvStream(response: Response, handlers: CsvStreamHandlers): Promise<number> {
  const body = response.body;
  if (!body) throw new Error("This browser cannot read a streamed export.");
  const reader = body.getReader();
  // ignoreBOM keeps the byte-order mark as a character instead of eating it as a
  // marker, which is the default. The server puts it there on purpose: without
  // it Excel opens a UTF-8 CSV as the local code page and mangles every accented
  // name in the file, and a decoder that quietly removes it here would put the
  // bug back while the endpoint still looked correct.
  const decoder = new TextDecoder("utf-8", { ignoreBOM: true });

  let buffer = "";
  let position = 0;      // how far into buffer the quote scan has reached
  let inQuotes = false;
  let headerSeen = false;
  let rows = 0;

  // Ends of complete records inside the current buffer, as offsets just past
  // each line terminator.
  let ends: number[] = [];

  const drain = async (done: boolean) => {
    if (done && position >= buffer.length && buffer.length && !buffer.endsWith("\n")) {
      // A final record with no terminator: still a record.
      ends.push(buffer.length);
    }
    if (!ends.length) return;
    const cut = ends[ends.length - 1];
    let text = buffer.slice(0, cut);
    let count = ends.length;

    if (!headerSeen) {
      const headerEnd = ends[0];
      const header = text.slice(0, headerEnd).replace(/\r?\n$/, "");
      await handlers.onHeader?.(header);
      text = text.slice(headerEnd);
      count -= 1;
      headerSeen = true;
    }

    buffer = buffer.slice(cut);
    position -= cut;
    if (position < 0) position = 0;
    ends = [];

    text = text.replace(/\r?\n$/, "");
    if (count > 0 && text.length) {
      rows += count;
      await handlers.onRows(text, count);
    }
  };

  for (;;) {
    const { value, done } = await reader.read();
    if (value) buffer += decoder.decode(value, { stream: true });
    else if (done) buffer += decoder.decode();

    while (position < buffer.length) {
      if (inQuotes) {
        const quote = buffer.indexOf('"', position);
        if (quote < 0) { position = buffer.length; break; }
        inQuotes = false;
        position = quote + 1;
        continue;
      }
      const quote = buffer.indexOf('"', position);
      const newline = buffer.indexOf("\n", position);
      if (newline >= 0 && (quote < 0 || newline < quote)) {
        ends.push(newline + 1);
        position = newline + 1;
      } else if (quote >= 0) {
        inQuotes = true;
        position = quote + 1;
      } else {
        position = buffer.length;
        break;
      }
    }

    await drain(done);
    if (done) break;
  }

  return rows;
}

// Collect a streamed CSV into a file the browser saves, counting the rows on
// the way past.
//
// The pieces are kept as an array and handed to Blob() rather than concatenated,
// so a 15 MB company export never exists as one 15 MB string. This is still the
// browser holding the whole file, which is why it is only used where the file is
// known to be small - two narrow columns - and why the prospect export writes
// straight to disk instead wherever the File System Access API exists.
export async function downloadCsvStream(response: Response, fileName: string): Promise<number> {
  const pieces: string[] = [];
  const rows = await readCsvStream(response, {
    onHeader: (header) => { pieces.push(header, "\r\n"); },
    onRows: (text) => { pieces.push(pieces.length > 2 ? "\r\n" : "", text); },
  });
  const url = URL.createObjectURL(new Blob(pieces, { type: "text/csv;charset=utf-8" }));
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = fileName;
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();
  setTimeout(() => URL.revokeObjectURL(url), 2000);
  return rows;
}

// A CSV response that failed carries JSON, because the error is decided before
// the first byte of the file is written. Turning that back into a message is the
// same three lines everywhere, so it lives here.
export async function csvStreamError(response: Response, fallback: string) {
  const body = await response.json().catch(() => null) as { error?: string } | null;
  return new Error(body?.error || fallback);
}
