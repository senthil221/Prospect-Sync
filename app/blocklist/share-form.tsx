"use client";

import { FormEvent, useEffect, useRef, useState } from "react";

type ShareInfo = { clientName: string; label: string; reasons: string[] };
async function post(body: unknown) {
  const response = await fetch("/api/blocklist-share", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body), cache: "no-store", referrerPolicy: "no-referrer" });
  const decoded = await response.json();
  if (!response.ok) throw new Error(decoded.error || "Unable to use this link.");
  return decoded;
}

export default function BlocklistShareForm() {
  const [token, setToken] = useState("");
  const [info, setInfo] = useState<ShareInfo | null>(null);
  const [text, setText] = useState("");
  const [reason, setReason] = useState("");
  const requestId = useRef(crypto.randomUUID());
  const initialized = useRef(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (initialized.current) return;
    initialized.current = true;
    const fragment = new URLSearchParams(window.location.hash.slice(1));
    const candidate = fragment.get("token") ?? "";
    window.history.replaceState(null, "", window.location.pathname);
    void Promise.resolve().then(async () => {
      if (!candidate) { setError("This submission link is incomplete."); return; }
      setToken(candidate);
      try { setInfo(await post({ action: "info", token: candidate }) as ShareInfo); }
      catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to open this link."); }
    });
  }, []);

  async function submit(event: FormEvent) {
    event.preventDefault(); setBusy(true); setError(""); setNotice("");
    try {
      await post({ action: "submit", token, text, reason, requestId: requestId.current });
      setText(""); setReason(""); requestId.current = crypto.randomUUID();
      setNotice("Your entries were accepted and will be applied securely.");
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to submit the blocklist."); }
    finally { setBusy(false); }
  }

  return <main className="login-page"><section className="login-brand"><div className="brand login-logo"><span className="brand-mark">P</span><span>Prospect <span>Sync</span></span></div><div><p className="eyebrow">SECURE CLIENT BLOCKLIST</p><h1>Keep outreach respectful.</h1><p>Add companies or people that should never be contacted for this client. This link cannot view or manage existing records.</p></div></section><section className="login-panel"><form onSubmit={submit}><p className="eyebrow">{info?.label ?? "BLOCKLIST SUBMISSION"}</p><h2>{info ? `Submit for ${info.clientName}` : "Opening secure link…"}</h2><p>Paste one domain or email per line, or separate them with commas.</p><label htmlFor="share-blocklist-values">Domains and email addresses</label><textarea id="share-blocklist-values" required rows={9} value={text} onChange={(event) => setText(event.target.value)} placeholder={"example.com\nno-contact@example.com"}/><label htmlFor="share-blocklist-reason">Reason</label><select id="share-blocklist-reason" required value={reason} onChange={(event) => setReason(event.target.value)}><option value="" disabled>Choose a reason…</option>{info?.reasons.map((option) => <option key={option} value={option}>{option}</option>)}</select><button className="primary" disabled={busy || !info || !text.trim() || !reason}>{busy ? "Submitting…" : "Add to blocklist"}</button>{error ? <div className="login-message login-error" role="alert">{error}</div> : null}{notice ? <div className="login-message" role="status">{notice}</div> : null}<small>The link owner can revoke access at any time.</small></form></section></main>;
}
