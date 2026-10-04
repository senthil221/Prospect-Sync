export class ImportOwnershipLostError extends Error {
  constructor(message = "Import ownership was lost.", cause) {
    super(message, cause ? { cause } : undefined);
    this.name = "ImportOwnershipLostError";
  }
}

export function isDefinitiveClaimLoss(error) {
  if (error instanceof ImportOwnershipLostError) return true;
  const message = String(error?.message ?? error ?? "");
  return /IMPORT_(?:CLAIM_LOST|LEASE_EXPIRED)/u.test(message);
}

export class ImportClaimLease {
  #renew;
  #readState;
  #leaseMilliseconds;
  #renewEveryMilliseconds;
  #retryEveryMilliseconds;
  #safetyMilliseconds;
  #timer = null;
  #queue = Promise.resolve();
  #loopPromise = null;
  #stopping = false;
  #lastAcknowledgedDeadline = 0;
  #progress = { totalRows: null, processedBytes: null };
  #controller = new AbortController();
  #terminal = null;
  #monotonicNow;

  constructor({ renew, readState, leaseMilliseconds = 300_000, renewEveryMilliseconds = 60_000,
    retryEveryMilliseconds = 5_000, safetyMilliseconds = 15_000,
    monotonicNow = () => performance.now() }) {
    this.#renew = renew;
    this.#readState = readState;
    this.#leaseMilliseconds = leaseMilliseconds;
    this.#renewEveryMilliseconds = renewEveryMilliseconds;
    this.#retryEveryMilliseconds = retryEveryMilliseconds;
    this.#safetyMilliseconds = safetyMilliseconds;
    this.#monotonicNow = monotonicNow;
  }

  get signal() { return this.#controller.signal; }
  get terminal() { return this.#terminal; }
  get lastAcknowledgedDeadline() { return this.#lastAcknowledgedDeadline; }

  setProgress({ totalRows = this.#progress.totalRows, processedBytes = this.#progress.processedBytes } = {}) {
    this.#progress = { totalRows, processedBytes };
  }

  async start() {
    await this.#renewOnce();
    this.#schedule(this.#renewEveryMilliseconds);
  }

  async serialized(task) {
    const run = this.#queue.then(task, task);
    this.#queue = run.catch(() => undefined);
    return run;
  }

  async readAuthoritativeState() {
    return this.serialized(() => this.#readState());
  }

  markCompleted(result) {
    this.#terminal = result ?? { status: "completed" };
    this.#stopping = true;
    if (this.#timer) clearTimeout(this.#timer);
    this.#timer = null;
  }

  abort(reason = new Error("Import worker is shutting down.")) {
    this.#stopping = true;
    if (this.#timer) clearTimeout(this.#timer);
    this.#timer = null;
    if (!this.#controller.signal.aborted) this.#controller.abort(reason);
  }

  async stop() {
    this.#stopping = true;
    if (this.#timer) clearTimeout(this.#timer);
    this.#timer = null;
    await this.#loopPromise?.catch(() => undefined);
    await this.#queue.catch(() => undefined);
  }

  #schedule(delay) {
    if (this.#stopping || this.#terminal) return;
    if (this.#timer) clearTimeout(this.#timer);
    this.#timer = setTimeout(() => {
      this.#timer = null;
      this.#loopPromise = this.#renewLoop().finally(() => { this.#loopPromise = null; });
    }, delay);
    this.#timer.unref?.();
  }

  async #renewOnce() {
    const requestStartedAt = this.#monotonicNow();
    const result = await this.serialized(() => this.#renew(this.#progress));
    if (result?.status === "completed" && result?.completionReceipt) {
      this.markCompleted(result);
      return result;
    }
    if (result?.status !== "processing") {
      throw new ImportOwnershipLostError("The database returned an invalid lease acknowledgement.");
    }
    const providerDeadline = Date.parse(String(result?.leaseExpiresAt ?? ""));
    if (!Number.isFinite(providerDeadline)) {
      throw new ImportOwnershipLostError("The database omitted the acknowledged lease deadline.");
    }
    // The database grants the lease after the request begins. A monotonic local
    // request-start budget is therefore conservative and cannot be extended by
    // host/database clock skew or a delayed response.
    this.#lastAcknowledgedDeadline = requestStartedAt + this.#leaseMilliseconds;
    return result;
  }

  async #renewLoop() {
    if (this.#stopping || this.#terminal) return;
    try {
      await this.#renewOnce();
      this.#schedule(this.#renewEveryMilliseconds);
    } catch (error) {
      if (this.#stopping || this.#terminal) return;
      if (isDefinitiveClaimLoss(error)) {
        this.abort(new ImportOwnershipLostError("The database rejected this import claim.", error));
        return;
      }
      // A transport or lock timeout does not prove ownership was lost.  Keep
      // retrying inside the last lease that the database acknowledged.  A
      // batch may be holding the same import row lock while it commits.
      if (!this.#lastAcknowledgedDeadline
          || this.#monotonicNow() >= this.#lastAcknowledgedDeadline - this.#safetyMilliseconds) {
        this.abort(new ImportOwnershipLostError("The acknowledged import lease budget was exhausted.", error));
        return;
      }
      this.#schedule(this.#retryEveryMilliseconds);
    }
  }
}
