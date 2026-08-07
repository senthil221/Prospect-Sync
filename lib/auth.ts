import { createClient } from "./supabase/server";
import { isAllowedEmail } from "./supabase/env";

export async function getAuthorizedUser() {
  const supabase = await createClient();
  const { data: { user }, error } = await supabase.auth.getUser();
  if (error || !user || !isAllowedEmail(user.email)) return null;
  return user;
}

export async function authorizeApi() {
  try {
    const user = await getAuthorizedUser();
    return user ? null : Response.json({ error: "Unauthorized" }, { status: 401 });
  } catch {
    return Response.json({ error: "Supabase is not configured." }, { status: 503 });
  }
}
