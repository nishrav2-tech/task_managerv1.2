// Utopian CRM service worker
// - Network-first for the app shell, so a new deploy is picked up right away —
//   the cache only kicks in as a fallback when there's no network (offline use).
// - Never caches Supabase API calls (always go to network for live data)
// - Receives real web push from the server (task assigned / due soon / due today)
// - Listens for messages from the page to show local notifications

const CACHE_NAME = 'utopian-crm-v3';
const APP_SHELL = [
  './',
  './index.html',
  './manifest.json',
  './icon-192.png',
  './icon-512.png',
  './logo.png',
  './logo.svg',
  './favicon.svg'
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(APP_SHELL))
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((names) =>
      Promise.all(names.filter((n) => n !== CACHE_NAME).map((n) => caches.delete(n)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);

  // Never intercept/cache Supabase (or any non-GET) requests — always hit the network.
  if (url.hostname.endsWith('.supabase.co') || event.request.method !== 'GET') {
    return;
  }

  // Same-origin app shell: try the network first (so new deploys show up
  // immediately), and only fall back to the cached copy if there's no network.
  if (url.origin === self.location.origin) {
    event.respondWith(
      fetch(event.request).then((res) => {
        if (res && res.status === 200) {
          const copy = res.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copy));
        }
        return res;
      }).catch(() => caches.match(event.request))
    );
  }
});

// ---------------------------------------------------------------------------
// Real push from the server (2026-09-12). This is what makes a notification
// arrive on a phone with the app closed — the browser wakes this worker up and
// hands it the payload, with no page running anywhere.
//
// The payload is JSON built by supabase/functions/send-push: {title, body,
// tag, url}. `tag` is per task+kind, so a phone that has been off for two days
// shows the current state of a reminder rather than a stack of identical ones;
// renotify makes that replacement still buzz, which is rather the point of a
// reminder.
//
// showNotification is not optional here: the subscription is made with
// userVisibleOnly:true, and a push that displays nothing eventually costs us
// the subscription altogether.
// ---------------------------------------------------------------------------
self.addEventListener('push', (event) => {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch (e) {
    data = { body: event.data ? event.data.text() : '' };
  }
  event.waitUntil(
    self.registration.showNotification(data.title || 'Utopian CRM', {
      body: data.body || '',
      tag: data.tag || undefined,
      renotify: !!data.tag,
      icon: './icon-192.png',
      badge: './icon-192.png',
      data: { url: data.url || './index.html' }
    })
  );
});

// A push service can rotate a subscription without being asked. Tell any open
// page so it re-registers; if nothing is open, the page picks it up on next
// launch (refreshPushState). Worst case is one missed notification rather than
// a device that quietly stops receiving them forever.
self.addEventListener('pushsubscriptionchange', (event) => {
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clients) => {
      clients.forEach((c) => c.postMessage({ type: 'PUSH_SUBSCRIPTION_CHANGED' }));
    })
  );
});

// The page posts a message here (via navigator.serviceWorker.controller.postMessage)
// whenever it wants to surface a local reminder notification.
self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'SHOW_NOTIFICATION') {
    const { title, body, tag, url } = event.data.payload || {};
    self.registration.showNotification(title || 'Utopian CRM', {
      body: body || '',
      tag: tag || undefined,
      icon: './icon-192.png',
      badge: './icon-192.png',
      data: { url: url || './index.html' }
    });
  }
});

// Clicking a notification focuses an existing tab or opens a new one.
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const targetUrl = (event.notification.data && event.notification.data.url) || './index.html';
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clients) => {
      for (const client of clients) {
        if ('focus' in client) return client.focus();
      }
      if (self.clients.openWindow) return self.clients.openWindow(targetUrl);
    })
  );
});
