"use client";

import { useEffect } from "react";

// error.tsx cannot catch a throw from the root layout itself, because the
// boundary lives inside it. This one replaces the whole document, so it has to
// render its own <html> and <body> and cannot rely on the app stylesheets
// having loaded -- hence the inline styles. It should effectively never appear;
// it exists so that "effectively never" is not a blank white page.
export default function GlobalError({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  useEffect(() => {
    console.error("Root layout error boundary caught:", error);
  }, [error]);

  return <html lang="en">
    <body style={{ margin: 0, minHeight: "100vh", display: "grid", placeItems: "center", background: "#f6f7f9", color: "#2b3445", fontFamily: "system-ui, -apple-system, Segoe UI, sans-serif" }}>
      <main style={{ maxWidth: "34rem", padding: "2rem", textAlign: "center" }}>
        <h1 style={{ fontSize: "1.25rem", margin: "0 0 .5rem" }}>Prospect Sync could not start.</h1>
        <p style={{ margin: "0 0 1.25rem", color: "#5a6472", fontSize: ".9rem", lineHeight: 1.6 }}>
          This is the application shell failing, not your data. Nothing has been changed or lost.
        </p>
        {error.digest ? <p style={{ margin: "0 0 1.25rem", color: "#8a93a1", fontSize: ".75rem" }}>Reference: {error.digest}</p> : null}
        <button
          onClick={reset}
          style={{ minHeight: "38px", padding: "0 1rem", border: 0, borderRadius: "8px", background: "#5b5bd6", color: "#fff", fontSize: ".85rem", fontWeight: 650, cursor: "pointer" }}
        >
          Reload the workspace
        </button>
      </main>
    </body>
  </html>;
}
