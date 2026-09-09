import { createClient } from "./supabase/server.ts";
import { isAdminEmail, isAllowedEmail } from "./supabase/env.ts";

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

// The Logs tab's guard: an allowed user is not automatically an admin, so this
// checks both allowlists rather than assuming ADMIN_USER_EMAILS is a subset.
export async function authorizeAdminApi() {
  try {
    const user = await getAuthorizedUser();
    if (!user || !isAdminEmail(user.email)) return Response.json({ error: "Unauthorized" }, { status: 401 });
    return null;
  } catch {
    return Response.json({ error: "Supabase is not configured." }, { status: 503 });
  }
}
