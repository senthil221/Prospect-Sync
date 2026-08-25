import { createBrowserClient } from "@supabase/ssr";
import { getPublicSupabaseEnv } from "./env.ts";

export function createClient() {
  const { url, key } = getPublicSupabaseEnv();
  return createBrowserClient(url, key);
}
