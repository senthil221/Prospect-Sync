export function getPublicSupabaseEnv() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !key) throw new Error("Supabase environment variables are not configured.");
  return { url, key };
}

export function isAllowedEmail(email: string | null | undefined) {
  if (!email) return false;
  const configured = (process.env.ALLOWED_USER_EMAILS ?? "")
    .split(",")
    .map((value) => value.trim().toLowerCase())
    .filter(Boolean);
  // Server routes use a Supabase service-role client after this check, so a
  // missing allowlist must never broaden access in a deployed environment.
  return configured.length > 0 && configured.includes(email.toLowerCase());
}
