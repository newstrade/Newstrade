// NewsTrade data updater. Runs hourly in GitHub Actions and writes data.json.
// Each section falls back to the previous data.json values if its source fails, so the site never goes blank.
import { readFile, writeFile } from "node:fs/promises";

const UA = { "User-Agent": "Mozilla/5.0 (NewsTrade data updater; +https://newstrade.github.io/Newstrade/)" };
const log = (...a) => console.log(...a);

async function get(url, type = "json") {
  const r = await fetch(url, { headers: UA, signal: AbortSignal.timeout(20000) });
  if (!r.ok) throw new Error(`${r.status} ${url}`);
  return type === "json" ? r.json() : r.text();
}

let prev = { events: [], instruments: [], news: [] };
try { prev = JSON.parse(await readFile("data.json", "utf8")); } catch { /* first run */ }

// ---------- 1. Economic calendar (Forex Factory weekly feed, New York times) ----------
async function calendar() {
  const feed = await get("https://nfs.faireconomy.media/ff_calendar_thisweek.json");
  const imp = { High: "high", Medium: "med" };
  const out = feed
    .filter((e) => imp[e.impact] && e.date && e.title && e.country)
    .map((e) => ({
      iso: String(e.date).slice(0, 19) + String(e.date).slice(-6), // e.g. 2026-10-14T08:30:00-04:00
      tag: e.country,
      imp: imp[e.impact],
      name: e.title,
      fc: e.forecast ?? "",
      prev: e.previous ?? "",
      act: e.actual ?? "",
    }));
  if (!out.length) throw new Error("calendar feed empty");
  // Keep actual values we already had if the feed doesn't carry them.
  const old = new Map((prev.events || []).map((e) => [e.iso + e.tag + e.name, e]));
  for (const e of out) if (!e.act && old.get(e.iso + e.tag + e.name)?.act) e.act = old.get(e.iso + e.tag + e.name).act;
  return out;
}

// ---------- 2. Prices ----------
const LIST = [
  ["EUR/USD", "Forex", "EURUSD=X", 4], ["GBP/USD", "Forex", "GBPUSD=X", 4], ["USD/JPY", "Forex", "JPY=X", 2],
  ["AUD/USD", "Forex", "AUDUSD=X", 4], ["USD/CAD", "Forex", "CAD=X", 4], ["USD/CHF", "Forex", "CHF=X", 4],
  ["Bitcoin", "Crypto", "BTC-USD", 0], ["Ethereum", "Crypto", "ETH-USD", 2],
  ["S&P 500", "Stocks", "^GSPC", 2], ["Nasdaq", "Stocks", "^IXIC", 2], ["Dow Jones", "Stocks", "^DJI", 2],
  ["Gold", "Commodities", "GC=F", 2], ["WTI Oil", "Commodities", "CL=F", 2],
];

async function yahoo(sym) {
  const j = await get(`https://query1.finance.yahoo.com/v8/finance/chart/${encodeURIComponent(sym)}?range=1d&interval=1d`);
  const m = j?.chart?.result?.[0]?.meta;
  if (!m || typeof m.regularMarketPrice !== "number") throw new Error("no price " + sym);
  const base = m.previousClose ?? m.chartPreviousClose;
  return {
    p: m.regularMarketPrice,
    ch: typeof base === "number" && base ? +(((m.regularMarketPrice / base) - 1) * 100).toFixed(2) : null,
    asof: new Date((m.regularMarketTime || Date.now() / 1000) * 1000).toISOString(),
  };
}

async function prices() {
  const before = new Map((prev.instruments || []).map((x) => [x.s, x]));
  const out = [];
  let fx = null, cg = null;
  for (const [s, m, sym, d] of LIST) {
    try {
      out.push({ s, m, d, ...(await yahoo(sym)) });
      continue;
    } catch (e) { log("yahoo failed", sym, e.message); }
    try {
      if (m === "Forex") {
        fx ??= await get("https://api.frankfurter.dev/v1/latest?from=USD&to=EUR,GBP,JPY,CHF,CAD,AUD");
        const r = fx.rates, inv = (k) => 1 / r[k];
        const p = { "EUR/USD": inv("EUR"), "GBP/USD": inv("GBP"), "USD/JPY": r.JPY, "AUD/USD": inv("AUD"), "USD/CAD": r.CAD, "USD/CHF": r.CHF }[s];
        out.push({ s, m, d, p, ch: null, asof: "ECB, " + fx.date });
        continue;
      }
      if (m === "Crypto") {
        cg ??= await get("https://api.coingecko.com/api/v3/simple/price?ids=bitcoin,ethereum&vs_currencies=usd&include_24hr_change=true&include_last_updated_at=true");
        const c = cg[s === "Bitcoin" ? "bitcoin" : "ethereum"];
        out.push({ s, m, d, p: c.usd, ch: +(+c.usd_24h_change).toFixed(2), asof: new Date(c.last_updated_at * 1000).toISOString() });
        continue;
      }
    } catch (e) { log("fallback failed", s, e.message); }
    if (before.has(s)) { out.push(before.get(s)); log("kept old", s); }
  }
  if (!out.length) throw new Error("no prices");
  return out;
}

// ---------- 3. News (Google News RSS per market; headlines link to the original publisher) ----------
const FEEDS = [
  ["Forex", "forex OR \"US dollar\" OR euro OR \"central bank\" when:1d"],
  ["Crypto", "bitcoin OR ethereum OR crypto when:1d"],
  ["Stocks", "\"stock market\" OR \"S&P 500\" OR Nasdaq when:1d"],
  ["Commodities", "\"gold price\" OR \"oil price\" OR crude when:1d"],
];
const HIGH = /\b(fed|fomc|cpi|inflation|rate (cut|hike)|interest rate|jobs report|payrolls?|ecb|boe|boj|recession|crash|surge|plunge)\b/i;
const decode = (s) => s.replace(/<!\[CDATA\[|\]\]>/g, "").replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#39;|&apos;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">").trim();
const tag = (x, t) => { const m = x.match(new RegExp(`<${t}[^>]*>([\\s\\S]*?)</${t}>`)); return m ? decode(m[1]) : ""; };

async function news() {
  const out = [];
  for (const [market, q] of FEEDS) {
    try {
      const xml = await get(`https://news.google.com/rss/search?q=${encodeURIComponent(q)}&hl=en-US&gl=US&ceid=US:en`, "text");
      const items = [...xml.matchAll(/<item>([\s\S]*?)<\/item>/g)].map((m) => m[1]).slice(0, 2);
      for (const it of items) {
        const source = tag(it, "source") || "News";
        let title = tag(it, "title");
        if (title.endsWith(" - " + source)) title = title.slice(0, -(source.length + 3));
        const link = tag(it, "link");
        if (title && /^https:\/\//.test(link)) out.push([market, HIGH.test(title) ? "high" : "med", title, source, link]);
      }
    } catch (e) { log("news failed", market, e.message); }
  }
  if (!out.length) throw new Error("no news");
  return out;
}

const data = { updated: new Date().toISOString(), events: prev.events, instruments: prev.instruments, news: prev.news };
for (const [key, fn] of [["events", calendar], ["instruments", prices], ["news", news]]) {
  try { data[key] = await fn(); log(key, "ok", data[key].length); }
  catch (e) { log(key, "FAILED, keeping previous:", e.message); }
}
await writeFile("data.json", JSON.stringify(data, null, 1) + "\n");
log("data.json written", data.updated);
