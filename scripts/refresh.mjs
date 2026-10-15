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
  // Added Oct 2026: African currencies, more coins, popular stocks, silver
  ["USD/KES", "Forex", "KES=X", 2], ["USD/ZAR", "Forex", "ZAR=X", 3], ["USD/NGN", "Forex", "NGN=X", 2],
  ["Solana", "Crypto", "SOL-USD", 2], ["XRP", "Crypto", "XRP-USD", 4],
  ["Apple", "Stocks", "AAPL", 2], ["Tesla", "Stocks", "TSLA", 2], ["Nvidia", "Stocks", "NVDA", 2],
  ["Silver", "Commodities", "SI=F", 3],
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
        cg ??= await get("https://api.coingecko.com/api/v3/simple/price?ids=bitcoin,ethereum,solana,ripple&vs_currencies=usd&include_24hr_change=true&include_last_updated_at=true");
        const c = cg[{ Bitcoin: "bitcoin", Ethereum: "ethereum", Solana: "solana", XRP: "ripple" }[s]];
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
  ["Forex", "(forex OR \"exchange rate\" OR \"US dollar\" OR \"euro dollar\" OR sterling OR yen OR \"central bank\") when:1d"],
  ["Crypto", "(bitcoin OR ethereum OR crypto) when:1d"],
  ["Stocks", "(\"stock market\" OR \"S&P 500\" OR Nasdaq OR \"Dow Jones\" OR \"Wall Street\") when:1d"],
  ["Commodities", "(\"gold price\" OR \"oil price\" OR \"crude oil\" OR Brent OR OPEC) when:1d"],
];
// Only reputable financial and news outlets; anything else is skipped.
const TRUSTED = /^(reuters|bloomberg|cnbc|yahoo finance|financial times|ft\.com|the wall street journal|wsj|barron's|marketwatch|fortune|forbes|business insider|associated press|ap news|bbc|the guardian|nikkei asia|the economist|investing\.com|fxstreet|forexlive|investinglive|kitco|oilprice\.com|crude oil prices today \| oilprice\.com|coindesk|cointelegraph|the block|decrypt|axios|cnn|the motley fool|morningstar|seeking alpha|business daily|the star|nation|the east african|bnn bloomberg|euronews|dw|al jazeera)/i;
const SPAM = /free!!|live stream|watch live|\bvs\.?\b|livestream|prediction:.*\bvs\b|odds|betting/i;
const HIGH = /\b(fed|fomc|cpi|inflation|rate (cut|hike)|interest rate|jobs report|payrolls?|ecb|boe|boj|recession|crash|surge|plunge)\b/i;
const decode = (s) => s.replace(/<!\[CDATA\[|\]\]>/g, "").replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#39;|&apos;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">").trim();
const tag = (x, t) => { const m = x.match(new RegExp(`<${t}[^>]*>([\\s\\S]*?)</${t}>`)); return m ? decode(m[1]) : ""; };

async function news() {
  const out = [];
  for (const [market, q] of FEEDS) {
    try {
      const xml = await get(`https://news.google.com/rss/search?q=${encodeURIComponent(q)}&hl=en-US&gl=US&ceid=US:en`, "text");
      const items = [...xml.matchAll(/<item>([\s\S]*?)<\/item>/g)].map((m) => m[1]).slice(0, 25);
      let n = 0;
      for (const it of items) {
        if (n >= 2) break;
        const source = tag(it, "source") || "";
        let title = tag(it, "title");
        if (source && title.endsWith(" - " + source)) title = title.slice(0, -(source.length + 3));
        const link = tag(it, "link");
        if (!title || !/^https:\/\//.test(link) || !TRUSTED.test(source) || SPAM.test(title)) continue;
        if (out.some((o) => o[2] === title)) continue;
        out.push([market, HIGH.test(title) ? "high" : "med", title, source, link]); n++;
      }
    } catch (e) { log("news failed", market, e.message); }
  }
  if (!out.length) throw new Error("no news");
  return out;
}


// ---------- 4. Price history for charts (history.json): 1 day, 1 week, 1 month ----------
const RANGES = { "1D": ["1d", "15m"], "1W": ["5d", "60m"], "1M": ["1mo", "1d"] };
async function series(sym, range, interval) {
  const j = await get(`https://query1.finance.yahoo.com/v8/finance/chart/${encodeURIComponent(sym)}?range=${range}&interval=${interval}`);
  const r = j?.chart?.result?.[0];
  const t = r?.timestamp || [], c = r?.indicators?.quote?.[0]?.close || [];
  const pts = [];
  for (let i = 0; i < t.length; i++) if (typeof c[i] === "number") pts.push([t[i], +c[i].toPrecision(7)]);
  if (pts.length < 2) throw new Error("too few points");
  return pts;
}
async function history(prevHist) {
  const out = {};
  for (const [s, , sym] of LIST) {
    out[s] = {};
    for (const [k, [range, interval]] of Object.entries(RANGES)) {
      try { out[s][k] = await series(sym, range, interval); }
      catch (e) { log("history failed", s, k, e.message); if (prevHist?.[s]?.[k]) out[s][k] = prevHist[s][k]; }
    }
  }
  return out;
}

const data = { updated: new Date().toISOString(), events: prev.events, instruments: prev.instruments, news: prev.news };
for (const [key, fn] of [["events", calendar], ["instruments", prices], ["news", news]]) {
  try { data[key] = await fn(); log(key, "ok", data[key].length); }
  catch (e) { log(key, "FAILED, keeping previous:", e.message); }
}
await writeFile("data.json", JSON.stringify(data, null, 1) + "\n");
log("data.json written", data.updated);

// ---------- 5. Event results history (events-history.json) ----------
// The free calendar feed has no "actual" values, but each release's "previous" IS the actual of the
// release before it. So we record every release (date + forecast) and fill in its actual when the next
// release of the same event shows up. History builds up from Oct 2026 onwards; 12 results kept per event.
let evHist = {};
try { evHist = JSON.parse(await readFile("events-history.json", "utf8")).events || {}; } catch { /* first run */ }
for (const e of data.events || []) {
  if (!e.fc && !e.prev) continue; // speeches etc.
  const key = e.tag + "|" + e.name, day = e.iso.slice(0, 10);
  const list = (evHist[key] ||= []);
  let row = list.find((r) => r.date === day);
  if (!row) { row = { date: day, fc: e.fc || "", act: e.act || "" }; list.push(row); }
  else { if (e.fc) row.fc = e.fc; if (e.act) row.act = e.act; }
  if (e.prev) {
    const earlier = list.filter((r) => r.date < day && (Date.parse(day) - Date.parse(r.date)) > 4 * 864e5).sort((a, b) => b.date.localeCompare(a.date))[0];
    if (earlier && !earlier.act) earlier.act = e.prev;
    if (!earlier) { // first time we see this event: keep the previous result as an undated entry
      if (!list.some((r) => r.date === "prior")) list.push({ date: "prior", fc: "", act: e.prev });
    }
  }
  list.sort((a, b) => (a.date === "prior" ? -1 : b.date === "prior" ? 1 : a.date.localeCompare(b.date)));
  if (list.length > 12) list.splice(0, list.length - 12);
}
await writeFile("events-history.json", JSON.stringify({ updated: new Date().toISOString(), events: evHist }) + "\n");
log("events-history.json written", Object.keys(evHist).length, "events");

let prevHist = {};
try { prevHist = JSON.parse(await readFile("history.json", "utf8")).series || {}; } catch { /* first run */ }
const hist = await history(prevHist);
await writeFile("history.json", JSON.stringify({ updated: new Date().toISOString(), series: hist }) + "\n");
log("history.json written");
