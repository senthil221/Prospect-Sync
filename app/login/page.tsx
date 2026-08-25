"use client";

import { FormEvent, useState } from "react";
import { createClient } from "../../lib/supabase/client";
import { AppIcon } from "../components/DashboardUi";

export default function LoginPage() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [message, setMessage] = useState("");
  const [loading, setLoading] = useState(false);

  async function signIn(event: FormEvent) {
    event.preventDefault();
    setLoading(true); setMessage("");
    try {
      const supabase = createClient();
      const { error } = await supabase.auth.signInWithPassword({
        email: email.trim(),
        password,
      });
      if (error) throw error;
      window.location.assign("/");
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "Unable to sign in.");
    } finally { setLoading(false); }
  }

  return <main className="login-page"><section className="login-brand"><div className="brand login-logo"><span className="brand-mark">P</span><span>Prospect <span>Sync</span></span></div><div><p className="eyebrow">PRIVATE DATABASE WORKSPACE</p><h1>One clean source for every prospect.</h1><p>Import client lists, prevent duplicate scraping, and keep every data point connected to one master record.</p></div><div className="login-flow"><span>CSV lists</span><i><AppIcon name="arrow" size={14}/></i><span>Unique master database</span><i><AppIcon name="arrow" size={14}/></i><span>Client workspaces</span></div></section><section className="login-panel"><form onSubmit={signIn}><span className="login-lock"><AppIcon name="arrow" size={14}/></span><p className="eyebrow">AUTHORIZED ACCESS</p><h2>Sign in to Prospect Sync</h2><p>Enter your approved agency email and password.</p><label htmlFor="login-email">Email address</label><input id="login-email" type="email" required autoComplete="email" value={email} onChange={(event) => setEmail(event.target.value)} placeholder="you@agency.com"/><label htmlFor="login-password">Password</label><input id="login-password" type="password" required minLength={8} autoComplete="current-password" value={password} onChange={(event) => setPassword(event.target.value)} placeholder="Enter your password"/><button className="primary" disabled={loading}>{loading ? "Signing in…" : "Sign in securely"}</button>{message && <div className="login-message login-error" role="alert">{message}</div>}<small>Access is restricted to approved team members.</small></form></section></main>;
}
