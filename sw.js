/* ═══════════════════════════════════════════════════
   eBerry Field — Service Worker v1.0
   Cache-first for app shell, network-first for APIs
   ═══════════════════════════════════════════════════ */

var CACHE_NAME = 'eberry-sw-v1';

// Recursos que forman el "app shell" — se pre-cachean al instalar
var APP_SHELL = [
  './',                        // la página principal (index.html)
  'https://fonts.googleapis.com/css2?family=Bebas+Neue&family=DM+Sans:wght@400;600;700&display=swap',
  'https://unpkg.com/html5-qrcode@2.3.8/html5-qrcode.min.js',
  'https://cdn.jsdelivr.net/npm/face-api.js@0.22.2/dist/face-api.min.js'
];

// Dominios que NUNCA se cachean (son datos dinámicos / APIs)
var API_DOMAINS = [
  'script.google.com',
  'script.googleusercontent.com'
];

// ─── INSTALL: pre-cachear app shell ───
self.addEventListener('install', function(e) {
  console.log('[SW] Instalando v1...');
  e.waitUntil(
    caches.open(CACHE_NAME).then(function(cache) {
      console.log('[SW] Cacheando app shell...');
      // addAll puede fallar si algún recurso CDN falla,
      // así que cacheamos uno por uno con tolerancia
      return Promise.all(
        APP_SHELL.map(function(url) {
          return cache.add(url).catch(function(err) {
            console.warn('[SW] No se pudo cachear:', url, err.message);
          });
        })
      );
    }).then(function() {
      // Activar inmediatamente sin esperar que cierren pestañas
      return self.skipWaiting();
    })
  );
});

// ─── ACTIVATE: limpiar caches viejos ───
self.addEventListener('activate', function(e) {
  console.log('[SW] Activado v1');
  e.waitUntil(
    caches.keys().then(function(names) {
      return Promise.all(
        names.filter(function(name) {
          return name !== CACHE_NAME;
        }).map(function(name) {
          console.log('[SW] Borrando cache viejo:', name);
          return caches.delete(name);
        })
      );
    }).then(function() {
      // Tomar control de todas las pestañas abiertas
      return self.clients.claim();
    })
  );
});

// ─── FETCH: interceptar peticiones de red ───
self.addEventListener('fetch', function(e) {
  var url = new URL(e.request.url);

  // 1) APIs de Google → SIEMPRE a la red (nunca cachear datos dinámicos)
  for (var i = 0; i < API_DOMAINS.length; i++) {
    if (url.hostname.indexOf(API_DOMAINS[i]) !== -1) {
      return; // dejar que el browser haga el fetch normal
    }
  }

  // 2) Solo cachear GET requests
  if (e.request.method !== 'GET') return;

  // 3) Para todo lo demás: Cache First, Network Fallback
  e.respondWith(
    caches.match(e.request).then(function(cached) {
      if (cached) {
        // Tenemos copia en cache → servir inmediatamente
        // Pero también actualizar en background (stale-while-revalidate)
        var fetchPromise = fetch(e.request).then(function(networkResp) {
          if (networkResp && networkResp.ok) {
            var clone = networkResp.clone();
            caches.open(CACHE_NAME).then(function(cache) {
              cache.put(e.request, clone);
            });
          }
          return networkResp;
        }).catch(function() {
          // Sin red, no pasa nada — ya servimos del cache
        });
        return cached;
      }

      // No está en cache → intentar la red
      return fetch(e.request).then(function(networkResp) {
        // Si la respuesta es válida, guardarla en cache para la próxima
        if (networkResp && networkResp.ok) {
          var clone = networkResp.clone();
          caches.open(CACHE_NAME).then(function(cache) {
            cache.put(e.request, clone);
          });
        }
        return networkResp;
      }).catch(function() {
        // Sin red Y sin cache → página offline de emergencia
        if (e.request.destination === 'document') {
          return new Response(
            '<!DOCTYPE html><html><head><meta charset="utf-8">' +
            '<meta name="viewport" content="width=device-width,initial-scale=1">' +
            '<title>eBerry - Sin conexión</title>' +
            '<style>body{font-family:sans-serif;display:flex;align-items:center;' +
            'justify-content:center;height:100vh;margin:0;background:#1a3a5c;color:#fff;' +
            'text-align:center}div{padding:2rem}.icon{font-size:4rem}h2{margin:.5rem 0}' +
            'p{opacity:.8}button{margin-top:1rem;padding:.8rem 2rem;border:none;' +
            'border-radius:8px;background:#4CAF50;color:#fff;font-size:1rem;cursor:pointer}' +
            '</style></head><body><div><div class="icon">🫐</div>' +
            '<h2>eBerry Field</h2>' +
            '<p>No hay conexión a internet.<br>Abre la app con señal al menos una vez ' +
            'para que funcione sin conexión.</p>' +
            '<button onclick="location.reload()">Reintentar</button>' +
            '</div></body></html>',
            { headers: { 'Content-Type': 'text/html; charset=utf-8' } }
          );
        }
      });
    })
  );
});

// ─── MESSAGE: comunicación con la app ───
self.addEventListener('message', function(e) {
  if (e.data && e.data.action === 'skipWaiting') {
    self.skipWaiting();
  }
  if (e.data && e.data.action === 'getCacheStatus') {
    caches.open(CACHE_NAME).then(function(cache) {
      return cache.keys();
    }).then(function(keys) {
      e.ports[0].postMessage({
        cached: keys.length,
        version: CACHE_NAME
      });
    });
  }
});
