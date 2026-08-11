// Utopian CRM service worker
// - Network-first for the app shell, so a new deploy is picked up right away —
//   the cache only kicks in as a fallback when there's no network (offline use).
// - Never caches Supabase API calls (always go to network for live data)
// - Listens for messages from the page to show local notifications (task/deadline reminders)

const CACHE_NAME = 'utopian-crm-v2';
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
