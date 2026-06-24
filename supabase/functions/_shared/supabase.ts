// _shared/supabase.ts — Supabase clients for edge functions.
import { createClient } from "npm:@supabase/supabase-js@2";

const URL = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

/**
 * Client bound to the CALLER's JWT — used only to identify the user.
 * RLS applies to this client.
 */
export function userClient(req: Request) {
  const authHeader = req.headers.get("Authorization") ?? "";
  return createClient(URL, ANON, {
    global: { headers: { Authorization: authHeader } },
  });
}

/**
 * Service-role client — bypasses RLS. Used to write threads/messages and
 * diagnostic results. NEVER expose this key or its data to the browser.
 */
export function adminClient() {
  return createClient(URL, SERVICE, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}

/** Returns the authenticated user's id, or throws 401. */
export async function requireUser(req: Request): Promise<string> {
  const { data, error } = await userClient(req).auth.getUser();
  if (error || !data.user) throw new Response("Unauthorized", { status: 401 });
  return data.user.id;
}
