import { createAdminClient } from "../../../lib/supabase/admin";

const timeoutMs = 5_000;
const noStoreHeaders = { "Cache-Control": "no-store, max-age=0" };

async function checkAuth() {
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  if (!supabaseUrl) throw new Error("Supabase URL is not configured");

  const response = await fetch(`${supabaseUrl.replace(/\/$/, "")}/auth/v1/health`, {
    cache: "no-store",
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!response.ok) throw new Error(`Auth health returned HTTP ${response.status}`);
}

async function checkDataApi() {
  const { error } = await createAdminClient()
    .from("clients")
    .select("id")
    .limit(1)
    .abortSignal(AbortSignal.timeout(timeoutMs));
  if (error) throw error;
}

export async function GET() {
  try {
    await Promise.all([checkAuth(), checkDataApi()]);
    return Response.json({ status: "ok" }, { headers: noStoreHeaders });
  } catch (error) {
    console.error("Readiness check failed", error);
    return Response.json({ status: "unhealthy" }, { status: 503, headers: noStoreHeaders });
  }
}
