// NewsTrade push sender. Runs every 5 minutes (pg_cron) and sends:
//   1. a reminder ~30 minutes before each event a Premium member starred
//   2. a price alert when a market crosses the level a Premium member set
// Deploy as a Supabase Edge Function named "push-sender" with "Verify JWT" turned OFF.
// Secrets: VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (mailto:you@example.com), CRON_SECRET.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "jsr:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
webpush.setVapidDetails(
  Deno.env.get("VAPID_SUBJECT") ?? "mailto:admin@example.com",
  Deno.env.get("VAPID_PUBLIC_KEY")!,
  Deno.env.get("VAPID_PRIVATE_KEY")!,
);
const DATA_URL = "https://raw.githubusercontent.com/newstrade/Newstrade/main/data.json";
const APP_URL = "https://newstrade.github.io/Newstrade/";

type Sub = { endpoint: string; p256dh: string; auth_key: string };

async function sendTo(userId: string, payload: Record<string, string>): Promise<number> {
  const { data: subs } = await db.from("push_subscriptions").select("endpoint,p256dh,auth_key").eq("user_id", userId);
  let ok = 0;
  for (const s of (subs ?? []) as Sub[]) {
    try {
      await webpush.sendNotification(
        { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth_key } },
        JSON.stringify(payload),
        { TTL: 1800, urgency: "high" },
      );
      ok++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) await db.from("push_subscriptions").delete().eq("endpoint", s.endpoint); // phone unsubscribed
    }
  }
  return ok;
}

Deno.serve(async (req) => {
  if (req.headers.get("x-cron-secret") !== Deno.env.get("CRON_SECRET")) return new Response("Forbidden", { status: 403 });
  const result = { events: 0, prices: 0 };

  // 1. Event reminders
  const { data: due } = await db.rpc("due_event_pushes");
  for (const a of due ?? []) {
    const mins = Math.max(1, Math.round((Date.parse(a.at) - Date.now()) / 60000));
    await sendTo(a.user_id, { title: `${a.title} in ${mins} min`, body: "Starting soon. Tap to see the forecast and previous result.", url: APP_URL, tag: `ev-${a.event_id}` });
    await db.from("event_alerts").update({ push_sent_at: new Date().toISOString() }).eq("user_id", a.user_id).eq("event_id", a.event_id);
    result.events++;
  }

  // 2. Price alerts (prices refresh hourly)
  const { data: alerts } = await db.rpc("active_price_alerts");
  if (alerts?.length) {
    const prices = new Map<string, number>();
    try {
      const d = await (await fetch(DATA_URL + "?t=" + Date.now())).json();
      for (const i of d.instruments ?? []) if (typeof i.p === "number") prices.set(i.s, i.p);
    } catch { /* try again next run */ }
    for (const a of alerts) {
      const p = prices.get(a.market);
      if (p === undefined) continue;
      const hit = a.direction === "above" ? p >= Number(a.price) : p <= Number(a.price);
      if (!hit) continue;
      await sendTo(a.user_id, { title: `${a.market} is ${a.direction} ${a.price}`, body: `Now ${p.toLocaleString("en-US")}. Prices refresh hourly, so check your broker.`, url: APP_URL, tag: `px-${a.id}` });
      await db.from("price_alerts").update({ triggered_at: new Date().toISOString() }).eq("id", a.id);
      result.prices++;
    }
  }
  return new Response(JSON.stringify(result), { headers: { "Content-Type": "application/json" } });
});
