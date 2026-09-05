// Browser cache budget measured as serialized UTF-16 payload/key bytes. This
// is an admission estimate, not a claim about exact JavaScript heap usage.
export class BoundedCache<T> {
  private entries = new Map<string, { value: T; bytes: number }>();
  private bytes = 0;
  private maxEntries: number;
  private maxBytes: number;
  constructor(maxEntries = 40, maxBytes = 1024 * 1024) {
    if (!Number.isSafeInteger(maxEntries) || maxEntries < 1 || !Number.isSafeInteger(maxBytes) || maxBytes < 1) throw new RangeError('Invalid cache budget');
    this.maxEntries = maxEntries; this.maxBytes = maxBytes;
  }
  get size() { return this.entries.size; }
  get estimatedBytes() { return this.bytes; }
  get(key: string): T | undefined {
    const entry = this.entries.get(key);
    if (!entry) return undefined;
    this.entries.delete(key); this.entries.set(key, entry);
    return entry.value;
  }
  set(key: string, value: T) {
    this.delete(key);
    const bytes = 2 * (key.length + (JSON.stringify(value)?.length ?? 0));
    if (bytes > this.maxBytes) return this; // Serve it, but don't retain it.
    while (this.entries.size >= this.maxEntries || this.bytes + bytes > this.maxBytes) {
      this.delete(this.entries.keys().next().value!);
    }
    this.entries.set(key, { value, bytes }); this.bytes += bytes;
    return this;
  }
  delete(key: string) {
    const entry = this.entries.get(key);
    if (!entry) return false;
    this.bytes -= entry.bytes;
    return this.entries.delete(key);
  }
  clear() { this.entries.clear(); this.bytes = 0; }
}
