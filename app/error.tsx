"use client";

import { useEffect } from "react";

// Without this file the App Router has nowhere to put a render-time throw, so
// any one of them blanks the whole workspace and a refresh blanks it again --
// which is what a timed-out search looked like from the outside. Fetch failures
// were already caught and surfaced inline; this covers everything that is not a
// fetch, most obviously compileBooleanSearch rejecting a malformed Boolean that
// was restored from a saved view or from localStorage on load.
//
// reset() re-renders the segment without a full reload, so a transient failure
// (a statement timeout under load) recovers without losing the rest of the
// session. "Start fresh" is the escape hatch for a bad persisted filter, which
// no amount of retrying will fix.
export default function WorkspaceError({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  useEffect(() => {
    console.error("Workspace error boundary caught:", error);
  }, [error]);

  function startFresh() {
    try {
      localStorage.removeItem("prospecthub-visible-columns");
      localStorage.removeItem("prospecthub-row-density");
    } catch {
      // A blocked localStorage is not a reason to fail the recovery path.
    }
    window.location.href = "/";
  }

  return <main className="boundary-shell">
    <section className="boundary-card panel">
      <span className="warning-mark">!</span>
      <p className="eyebrow">SOMETHING BROKE</p>
      <h1>This view could not be rendered.</h1>
      <p>
        The rest of the database is unaffected — nothing has been changed or lost.
        If a search or filter had just timed out, retrying usually works.
      </p>
      {error.message ? <pre className="boundary-detail">{error.message}</pre> : null}
      {error.digest ? <small className="boundary-digest">Reference: {error.digest}</small> : null}
      <div className="boundary-actions">
        <button className="primary" onClick={reset}>Try again</button>
        <button className="secondary" onClick={startFresh}>Start fresh</button>
      </div>
    </section>
  </main>;
}
