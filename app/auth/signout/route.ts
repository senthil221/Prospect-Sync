import { NextResponse } from "next/server";
import { createClient } from "../../../lib/supabase/server";
import { publicAppOrigin } from "../../../lib/public-app-origin";

export async function GET(request: Request) {
  const supabase = await createClient();
  await supabase.auth.signOut();
  let origin: string;
  try {
    origin = publicAppOrigin(process.env.APP_PUBLIC_URL, request.url, process.env.NODE_ENV === "production");
  } catch (error) {
    console.error("Sign-out redirect is not configured safely.", error);
    return Response.json({ error: "Sign-out completed, but the login redirect is not configured." }, { status: 500 });
  }
  return NextResponse.redirect(new URL("/login", origin));
}
