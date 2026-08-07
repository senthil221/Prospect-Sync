"use client";

import { FormEvent, useState } from "react";
import { createClient } from "../../lib/supabase/client";

export default function LoginPage() {
  const [email, setEmail] = useState("");
  const [message, setMessage] = useState("");
  const [loading, setLoading] = useState(false);

  async function signIn(event: FormEvent) {
    event.preventDefault();
    setLoading(true); setMessage("");
    try {
      const supabase = createClient();
      const { error } = await supabase.auth.signInWithOtp({
        email: email.trim(),
        options: { emailRedirectTo: `${window.location.origin}/auth/callback` },
      });
      if (error) throw error;
      setMessage("Check your inbox. We sent you a secure sign-in link.");
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "Unable to send the sign-in link.");
    } finally { setLoading(false); }
  }

  return <main className="login-page"><section className="login-brand"><div className="brand login-logo"><span className="brand-mark">P</span><span>Prospect<span>Hub</span></span></div><div><p className="eyebrow">PRIVATE DATABASE WORKSPACE</p><h1>One clean source for every prospect.</h1><p>Import client lists, prevent duplicate scraping, and keep every data point connected to one master record.</p></div><div className="login-flow"><span>CSV lists</span><i>→</i><span>Unique master database</span><i>→</i><span>Client workspaces</span></div></section><section className="login-panel"><form onSubmit={signIn}><span className="login-lock">●</span><p className="eyebrow">AUTHORIZED ACCESS</p><h2>Sign in to ProspectHub</h2><p>Use an approved agency email. No password is required.</p><label htmlFor="login-email">Email address</label><input id="login-email" type="email" required autoComplete="email" value={email} onChange={(event) => setEmail(event.target.value)} placeholder="you@agency.com"/><button className="primary" disabled={loading}>{loading ? "Sending secure link…" : "Email me a sign-in link"}</button>{message && <div className="login-message">{message}</div>}<small>Access is restricted to approved team members.</small></form></section></main>;
}
