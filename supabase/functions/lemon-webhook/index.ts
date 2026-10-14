// NewsTrade: receives Lemon Squeezy subscription events and records who is Premium.
// Deploy as a Supabase Edge Function named "lemon-webhook" with JWT verification OFF.
// Needs one secret: LEMON_SIGNING_SECRET (the signing secret you set on the Lemon Squeezy webhook).
import { createClient } from "jsr:@supabase/supabase-js@2";

const SECRET = Deno.env.get("LEMON_SIGNING_SECRET") ?? "";
const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

async function hmacHex(secret: string, body: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function sameText(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("NewsTrade webhook is running");

  const body = await req.text();
  const signature = req.headers.get("x-signature") ?? "";
  if (!SECRET || !sameText(await hmacHex(SECRET, body), signature)) {
    return new Response("Invalid signature", { status: 401 });
  }

  let payload: any;
  try { payload = JSON.parse(body); } catch { return new Response("Bad JSON", { status: 400 }); }

  const event: string = payload?.meta?.event_name ?? "";
  if (!event.startsWith("subscription_")) return new Response("Ignored");

  const userId: string | undefined = payload?.meta?.custom_data?.user_id;
  if (!userId || !/^[0-9a-f-]{36}$/i.test(userId)) return new Response("No NewsTrade user on this order");

  const a = payload?.data?.attributes ?? {};
  const { error } = await db.from("subscriptions").upsert({
    user_id: userId,
    ls_subscription_id: String(payload?.data?.id ?? ""),
    status: String(a.status ?? "expired"),
    renews_at: a.renews_at ?? null,
    ends_at: a.ends_at ?? null,
    portal_url: a.urls?.customer_portal ?? null,
    updated_at: new Date().toISOString(),
  }, { onConflict: "user_id" });

  if (error) return new Response("Database error: " + error.message, { status: 500 });
  return new Response("OK");
});
