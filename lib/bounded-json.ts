// Read before JSON.parse: Content-Length is only an early rejection hint, not
// evidence that chunked or incorrectly declared bodies fit. No partial payload
// is returned on overflow, interruption, excessive depth or malformed JSON.
export const queryBodyLimits = { bytes: 4 * 1024 * 1024, depth: 64, timeoutMs: 5000 };

export async function readBoundedJson(request: Request, limits = queryBodyLimits): Promise<
  { value: unknown; response?: never } | { value?: never; response: Response }
> {
  const reject = (status: number, code: string, error: string) => ({
    response: Response.json({ code, error, retryable: false }, { status, headers: { 'Cache-Control': 'no-store' } }),
  });
  const tooLarge = () => reject(413, 'request_too_large', 'This request exceeds the supported size. Use a saved filter set or reduce the selection.');
  if (Number(request.headers.get('content-length')) > limits.bytes) return tooLarge();
  if (!request.body) return reject(400, 'invalid_json', 'A JSON request body is required.');
  const reader = request.body.getReader();
  let timer: ReturnType<typeof setTimeout> | undefined;
  let onAbort = () => {};
  const interrupted = new Promise<never>((_, rejectRead) => {
    onAbort = () => rejectRead(new Error('aborted'));
    if (request.signal.aborted) onAbort();
    else request.signal.addEventListener('abort', onAbort, { once: true });
    timer = setTimeout(() => rejectRead(new Error('deadline')), limits.timeoutMs);
  });
  const chunks: Uint8Array[] = [];
  let bytes = 0;
  try {
    for (;;) {
      const { done, value } = await Promise.race([reader.read(), interrupted]);
      if (done) break;
      bytes += value.byteLength;
      if (bytes > limits.bytes) return tooLarge();
      chunks.push(value);
    }
    const body = new Uint8Array(bytes);
    let offset = 0;
    for (const chunk of chunks) { body.set(chunk, offset); offset += chunk.byteLength; }
    const text = new TextDecoder('utf-8', { fatal: true }).decode(body);
    let depth = 0, quoted = false, escaped = false;
    for (const char of text) {
      if (quoted) {
        if (escaped) escaped = false;
        else if (char === '\\') escaped = true;
        else if (char === '"') quoted = false;
      } else if (char === '"') quoted = true;
      else if (char === '{' || char === '[') {
        if (++depth > limits.depth) return reject(413, 'request_too_deep', 'This request has too many nested conditions.');
      } else if (char === '}' || char === ']') depth--;
    }
    return { value: JSON.parse(text) };
  } catch (error) {
    if (error instanceof Error && (error.message === 'deadline' || error.message === 'aborted')) {
      return reject(408, 'request_interrupted', 'The request body was interrupted or took too long.');
    }
    return reject(400, 'invalid_json', 'The request body is not valid JSON.');
  } finally {
    clearTimeout(timer);
    request.signal.removeEventListener('abort', onAbort);
    // Don't wait for a client-controlled stream's cancellation to finish.
    void reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}
