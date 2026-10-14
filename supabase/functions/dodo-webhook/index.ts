// NewsTrade: receives Dodo Payments subscription events and records who is Premium.
// Deploy as a Supabase Edge Function named "dodo-webhook" with "Verify JWT" turned OFF.
// Needs one secret: DODO_WEBHOOK_SECRET (the "whsec_..." signing secret from Dodo → Developer → Webhooks).
import { createClient } from "jsr:@supabase/supabase-js@2";

const SECRET = Deno.env.get("DODO_WEBHOOK_SECRET") ?? "";
const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

function b64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function sameText(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// Standard Webhooks: base64(HMAC-SHA256(key, "{id}.{timestamp}.{body}")), header "v1,<sig> v1,<sig2>"
async function validSignature(id: string, ts: string, body: string, header: string): Promise<boolean> {
  if (!SECRET || !id || !ts || !header) return false;
  const now = Math.floor(Date.now() / 1000);
  if (Math.abs(now - Number(ts)) > 300) return false; // older than 5 minutes: possible replay
  const key = await crypto.subtle.importKey(
    "raw", b64ToBytes(SECRET.replace(/^whsec_/, "")),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${id}.${ts}.${body}`));
  const expected = btoa(String.fromCharCode(...new Uint8Array(mac)));
  return header.split(" ").some((part) => {
    const [ver, sig] = part.split(",");
    return ver === "v1" && !!sig && sameText(sig, expected);
  });
}

// Map Dodo events to the statuses the site understands.
function statusFor(event: string, dodoStatus: string): string {
  switch (event) {
    case "subscription.active":
    case "subscription.renewed":
    case "subscription.plan_changed":
    case "subscription.unpaused":
      return "active";
    case "subscription.cancelled":
      return "cancelled"; // keeps access until the paid period ends
    case "subscription.on_hold":
    case "subscription.past_due":
      return "on_hold";
    case "subscription.expired":
    case "subscription.failed":
      return "expired";
    default:
      return dodoStatus || "expired";
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("NewsTrade payment webhook is running");

  const body = await req.text();
  const ok = await validSignature(
    req.headers.get("webhook-id") ?? "",
    req.headers.get("webhook-timestamp") ?? "",
    body,
    req.headers.get("webhook-signature") ?? "",
  );
  if (!ok) return new Response("Invalid signature", { status: 401 });

  let evt: any;
  try { evt = JSON.parse(body); } catch { return new Response("Bad JSON", { status: 400 }); }

  const type: string = evt?.type ?? "";
  if (!type.startsWith("subscription.")) return new Response("Ignored");

  const d = evt?.data ?? {};
  let userId: string | null = d?.metadata?.userId ?? null;
  if (!userId || !/^[0-9a-f-]{36}$/i.test(userId)) {
    // Fallback: match the buyer's email to a NewsTrade account.
    const email = d?.customer?.email;
    if (email) {
      const { data } = await db.rpc("user_id_by_email", { p_email: email });
      userId = data ?? null;
    }
  }
  if (!userId) return new Response("No NewsTrade account for this subscription");

  const status = statusFor(type, String(d?.status ?? ""));
  const { error } = await db.from("subscriptions").upsert({
    user_id: userId,
    ls_subscription_id: String(d?.subscription_id ?? ""),
    status,
    renews_at: status === "active" ? (d?.next_billing_date ?? null) : null,
    ends_at: status === "cancelled" ? (d?.next_billing_date ?? new Date().toISOString()) : null,
    portal_url: null,
    updated_at: new Date().toISOString(),
  }, { onConflict: "user_id" });

  if (error) return new Response("Database error: " + error.message, { status: 500 });
  return new Response("OK");
});
