// NewsTrade service worker.
// The app itself opens instantly from the saved copy and quietly downloads the newest version for next time.
// Market data is fetched fresh (with a short timeout, falling back to the last saved data when offline or slow).
const CACHE = "newstrade-v4";
const SHELL = ["./", "./index.html", "./manifest.webmanifest", "./icons/icon-192.png", "./icons/icon-512.png"];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

function save(req, res) {
  if (res && (res.ok || res.type === "opaque")) {
    const copy = res.clone();
    caches.open(CACHE).then((c) => c.put(req, copy));
  }
  return res;
}

function withTimeout(promise, ms) {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error("timeout")), ms);
    promise.then((v) => { clearTimeout(t); resolve(v); }, (e) => { clearTimeout(t); reject(e); });
  });
}

self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);

  // Never cache accounts, payments, chat or database traffic.
  if (url.hostname.endsWith("supabase.co") || url.hostname.includes("dodopayments")) return;

  // Opening the app: show the saved copy straight away, update it in the background.
  if (req.mode === "navigate") {
    const key = new URL("./index.html", self.registration.scope).href;
    e.respondWith(
      caches.match(key).then((hit) => {
        const update = fetch(req).then((res) => { if (res.ok) caches.open(CACHE).then((c) => c.put(key, res.clone())); return res; });
        if (hit) { e.waitUntil(update.catch(() => {})); return hit; }
        return update.catch(() => caches.match("./"));
      })
    );
    return;
  }

  // Market data: try the network for up to 4 seconds, otherwise use the last saved copy.
  if (url.hostname === "raw.githubusercontent.com" || url.pathname.endsWith(".json")) {
    const key = url.origin + url.pathname; // ignore cache-busting ?t=…
    e.respondWith(
      withTimeout(fetch(req), 4000)
        .then((res) => { if (res.ok) { const copy = res.clone(); caches.open(CACHE).then((c) => c.put(key, copy)); } return res; })
        .catch(() => caches.match(key).then((r) => r || fetch(req)))
    );
    return;
  }

  // Icons, fonts and libraries: saved copy first.
  if (url.origin === location.origin || url.hostname.includes("fonts.g") || url.hostname === "cdn.jsdelivr.net") {
    e.respondWith(caches.match(req).then((hit) => hit || fetch(req).then((res) => save(req, res))));
  }
});

// Push notifications (event reminders and price alerts)
self.addEventListener("push", (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch { d = { title: "NewsTrade", body: e.data ? e.data.text() : "" }; }
  e.waitUntil(self.registration.showNotification(d.title || "NewsTrade", {
    body: d.body || "", tag: d.tag, icon: "icons/icon-192.png", badge: "icons/icon-192.png", data: { url: d.url || "./" },
  }));
});
self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || "./";
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((list) => {
    for (const c of list) if ("focus" in c) return c.focus();
    return self.clients.openWindow(url);
  }));
});
