// node-postgres destroys the socket when Client.end() is called with an active
// query. PostgreSQL then rolls the session's open transaction back. Binding
// that behaviour to worker shutdown keeps Docker's 30-second grace period
// authoritative even when a batch has a much larger normal query timeout.
export function bindAbortToPgSession(client, signal, waitMilliseconds = 5_000) {
  let termination = null;

  const terminate = () => {
    if (!termination) {
      termination = Promise.resolve()
        .then(() => client.end())
        .catch(() => undefined);
    }
    return termination;
  };

  if (signal.aborted) terminate();
  else signal.addEventListener("abort", terminate, { once: true });

  return async function detachAndWait() {
    signal.removeEventListener("abort", terminate);
    if (!termination) return;
    let timer;
    try {
      await Promise.race([
        termination,
        new Promise(resolve => {
          timer = setTimeout(resolve, waitMilliseconds);
        }),
      ]);
    } finally {
      if (timer) clearTimeout(timer);
    }
  };
}
