/* ═══════════════════════════════════════════════════════════════
   eBerry Field — Service Worker v3.0 (2026-04-23)
   Estrategia: Network-First para HTML, Cache-First para CDN
   ---------------------------------------------------------------
   V3 FIX CRÍTICO: version.txt ya no se cachea (Network-only).
   El SW v2 interceptaba version.txt y servía cache viejo → clientes
   quedaban atorados en versiones viejas sin detectar nueva. Backup
   del v2 está en sw_v2_backup.js. CACHE_NAME bumpeado a v3 para que
   activate() borre el cache v2 automáticamente al activarse.
   ═══════════════════════════════════════════════════════════════ */

var CACHE_NAME = 'eberry-v5';

// Dominios de API → NUNCA cachear (datos dinámicos)
var API_DOMAINS = [
  'script.google.com',
  'script.googleusercontent.com'
];

// Dominios CDN → Cache-First (no cambian con deploys de Serafín)
var CDN_DOMAINS = [
  'fonts.googleapis.com',
  'fonts.gstatic.com',
  'unpkg.com',
  'cdn.jsdelivr.net'
];

// ─────────────────────────────────────────────────────────────
// INSTALL: cachear lo mínimo necesario para offline
// NO llamamos skipWaiting() aquí — lo llamamos solo cuando el
// usuario acepta la actualización desde el toast.
// ─────────────────────────────────────────────────────────────
self.addEventListener('install', function(e) {
  console.log('[SW] Instalando v4...');
  // Pre-cachear solo el root. Los CDN se cachean on-demand.
  e.waitUntil(
    caches.open(CACHE_NAME).then(function(cache) {
      return cache.add('./').catch(function(err) {
        console.warn('[SW] No se pudo pre-cachear root:', err.message);
      });
    })
    // Sin skipWaiting() aquí — el SW espera en estado "waiting"
    // hasta que el usuario confirme la actualización.
  );
});

// ─────────────────────────────────────────────────────────────
// ACTIVATE: limpiar caches de versiones anteriores
// ─────────────────────────────────────────────────────────────
self.addEventListener('activate', function(e) {
  console.log('[SW] Activado v4 — fix clone bug');
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
      return self.clients.claim();
    })
  );
});

// ─────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────

function isApiUrl(url) {
  for (var i = 0; i < API_DOMAINS.length; i++) {
    if (url.hostname.indexOf(API_DOMAINS[i]) !== -1) return true;
  }
  return false;
}

function isCdnUrl(url) {
  for (var i = 0; i < CDN_DOMAINS.length; i++) {
    if (url.hostname.indexOf(CDN_DOMAINS[i]) !== -1) return true;
  }
  return false;
}

function isHtmlRequest(request, url) {
  // Petición de documento HTML: navegación o extensión .html
  return (
    request.destination === 'document' ||
    request.mode === 'navigate' ||
    url.pathname === '/' ||
    url.pathname.endsWith('.html') ||
    url.pathname.endsWith('/')
  );
}

// Genera un hash simple (djb2) de un string.
// Se usa para detectar si el HTML cambió sin guardar dos copias enteras.
function hashString(str) {
  var hash = 5381;
  for (var i = 0; i < str.length; i++) {
    hash = ((hash << 5) + hash) ^ str.charCodeAt(i);
    hash = hash & hash; // forzar 32-bit
  }
  return hash >>> 0; // sin signo
}

// Notifica a TODAS las pestañas abiertas que hay actualización disponible.
function notifyClients(type, payload) {
  self.clients.matchAll({ type: 'window' }).then(function(clients) {
    clients.forEach(function(client) {
      client.postMessage(Object.assign({ type: type }, payload || {}));
    });
  });
}

// ─────────────────────────────────────────────────────────────
// ESTRATEGIA 1 — HTML: Network-First con detección de cambio
//
// Flujo:
//   1. Pedir a la red (timeout 5s para no congelar en 2G lento)
//   2a. Si red responde: comparar hash con cache
//       - Si es diferente → guardar en cache + notificar toast
//       - Si es igual     → guardar en cache (actualiza ETag/fecha)
//   2b. Si red falla (offline): servir del cache
//   2c. Sin red Y sin cache: página offline de emergencia
// ─────────────────────────────────────────────────────────────
function strategyNetworkFirstHtml(request) {
  // Clave canónica: siempre usamos './' para el root
  var cacheKey = request;

  var networkPromise = fetchWithTimeout(request, 5000).then(function(networkResp) {
    if (!networkResp || !networkResp.ok) {
      // Respuesta inválida → tratar como fallo de red
      return caches.match(cacheKey).then(function(cached) {
        return cached || networkResp;
      });
    }

    // Clonar para poder leer el body Y guardarlo en cache
    var respForCache = networkResp.clone();
    var respForHash  = networkResp.clone();

    return respForHash.text().then(function(newText) {
      var newHash = hashString(newText);

      return caches.open(CACHE_NAME).then(function(cache) {
        return cache.match(cacheKey).then(function(oldCached) {

          if (!oldCached) {
            // Primera vez → solo guardar, sin toast
            console.log('[SW] HTML cacheado por primera vez.');
            cache.put(cacheKey, respForCache);
            return new Response(newText, {
              status: networkResp.status,
              headers: networkResp.headers
            });
          }

          // Comparar con lo que había en cache
          return oldCached.clone().text().then(function(oldText) {
            var oldHash = hashString(oldText);

            if (newHash !== oldHash) {
              console.log('[SW] HTML nuevo detectado (hash cambió). Notificando...');
              // Guardar el HTML nuevo en cache
              cache.put(cacheKey, respForCache);
              // Avisar a la app: "hay versión nueva lista"
              notifyClients('SW_UPDATE_READY');
            } else {
              // Mismo contenido — actualizar silenciosamente (refresca headers HTTP)
              cache.put(cacheKey, respForCache);
            }

            return new Response(newText, {
              status: networkResp.status,
              headers: networkResp.headers
            });
          });
        });
      });
    });

  }).catch(function() {
    // Sin red → servir cache o página de emergencia
    return caches.match(cacheKey).then(function(cached) {
      if (cached) {
        console.log('[SW] Offline — sirviendo HTML del cache.');
        return cached;
      }
      return offlinePage();
    });
  });

  return networkPromise;
}

// ─────────────────────────────────────────────────────────────
// ESTRATEGIA 2 — CDN: Cache-First con revalidación en background
//
// Las librerías CDN (face-api, html5-qrcode, fonts) son inmutables
// en la práctica (versión fijada en la URL). Cache-First es lo
// correcto: respuesta instantánea, actualización silenciosa.
// ─────────────────────────────────────────────────────────────
function strategyCacheFirstCdn(request) {
  return caches.match(request).then(function(cached) {
    var fetchPromise = fetch(request).then(function(networkResp) {
      if (networkResp && networkResp.ok) {
        // FIX v4: clonar ANTES de devolver el original — evita "Response body is already used"
        var respClone = networkResp.clone();
        caches.open(CACHE_NAME).then(function(cache) {
          cache.put(request, respClone);
        });
      }
      return networkResp;
    }).catch(function() {
      // Sin red — si ya teníamos cache, no importa
    });

    return cached || fetchPromise;
  });
}

// ─────────────────────────────────────────────────────────────
// ESTRATEGIA 3 — Assets locales (imágenes, manifesto, iconos)
// Cache-First simple sin revalidación agresiva
// ─────────────────────────────────────────────────────────────
function strategyCacheFirstLocal(request) {
  return caches.match(request).then(function(cached) {
    if (cached) return cached;
    return fetch(request).then(function(networkResp) {
      if (networkResp && networkResp.ok) {
        // FIX v4: clonar ANTES de devolver original — evita "Response body is already used"
        var respClone = networkResp.clone();
        caches.open(CACHE_NAME).then(function(cache) {
          cache.put(request, respClone);
        });
      }
      return networkResp;
    }).catch(function() {
      return new Response('', { status: 503 });
    });
  });
}

// ─────────────────────────────────────────────────────────────
// Fetch con timeout — evita que peticiones lentas en 2G
// paralicen la app. Después del timeout, cae al cache.
// ─────────────────────────────────────────────────────────────
function fetchWithTimeout(request, ms) {
  var controller = new AbortController();
  var timer = setTimeout(function() { controller.abort(); }, ms);

  // Crear nueva Request con signal de abort
  var req = new Request(request, { signal: controller.signal });

  return fetch(req).then(function(resp) {
    clearTimeout(timer);
    return resp;
  }).catch(function(err) {
    clearTimeout(timer);
    throw err;
  });
}

// ─────────────────────────────────────────────────────────────
// Página offline de emergencia
// ─────────────────────────────────────────────────────────────
function offlinePage() {
  return new Response(
    '<!DOCTYPE html><html lang="es"><head>' +
    '<meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width,initial-scale=1">' +
    '<title>eBerry - Sin conexión</title>' +
    '<style>' +
    'body{font-family:sans-serif;display:flex;align-items:center;' +
    'justify-content:center;height:100vh;margin:0;background:#1a3a5c;color:#fff;text-align:center}' +
    'div{padding:2rem}.icon{font-size:4rem}h2{margin:.5rem 0}p{opacity:.8;line-height:1.5}' +
    'button{margin-top:1.5rem;padding:.8rem 2rem;border:none;border-radius:8px;' +
    'background:#4CAF50;color:#fff;font-size:1rem;cursor:pointer;font-weight:bold}' +
    '</style></head><body>' +
    '<div>' +
    '<div class="icon">🫐</div>' +
    '<h2>eBerry Field</h2>' +
    '<p>Sin conexión a internet.<br>' +
    'Abre la app con señal al menos una vez<br>para que funcione sin conexión.</p>' +
    '<button onclick="location.reload()">Reintentar</button>' +
    '</div>' +
    '</body></html>',
    { headers: { 'Content-Type': 'text/html; charset=utf-8' } }
  );
}

// ─────────────────────────────────────────────────────────────
// FETCH: enrutador principal
// ─────────────────────────────────────────────────────────────
self.addEventListener('fetch', function(e) {
  var url;
  try {
    url = new URL(e.request.url);
  } catch(err) {
    return; // URL inválida, ignorar
  }

  // Solo GET
  if (e.request.method !== 'GET') return;

  // 0) V3 FIX CRÍTICO: version.txt → Network-only, NUNCA cachear.
  //    El SW v2 interceptaba y devolvía cache viejo → checkVersion nunca detectaba
  //    nuevas versiones → clientes atorados en versiones viejas. Ahora bypass total.
  if (url.origin === self.location.origin && url.pathname.endsWith('/version.txt')) {
    e.respondWith(
      fetch(e.request, { cache: 'no-store' }).catch(function(){
        return new Response('', { status: 503, statusText: 'Offline' });
      })
    );
    return;
  }

  // 1) APIs de Google → pasar directo a la red, sin tocar
  if (isApiUrl(url)) return;

  // 2) HTML (navegación principal) → Network-First con detección de cambio
  if (isHtmlRequest(e.request, url)) {
    e.respondWith(strategyNetworkFirstHtml(e.request));
    return;
  }

  // 3) CDN (librerías, fonts) → Cache-First con SWR background
  if (isCdnUrl(url)) {
    e.respondWith(strategyCacheFirstCdn(e.request));
    return;
  }

  // 4) Todo lo demás del mismo origen (iconos, manifest, etc.) → Cache-First local
  if (url.origin === self.location.origin) {
    e.respondWith(strategyCacheFirstLocal(e.request));
    return;
  }

  // 5) Cualquier otro origen desconocido → red directa
});

// ─────────────────────────────────────────────────────────────
// MESSAGE: comunicación con la app
//
// Mensajes que puede enviar la app:
//   { action: 'skipWaiting' }  — usuario aceptó actualizar
//   { action: 'getCacheStatus' } — diagnóstico
// ─────────────────────────────────────────────────────────────
self.addEventListener('message', function(e) {
  if (!e.data) return;

  if (e.data.action === 'skipWaiting') {
    // El usuario tocó "Actualizar ahora" en el toast
    console.log('[SW] skipWaiting solicitado por la app.');
    self.skipWaiting();
  }

  if (e.data.action === 'getCacheStatus') {
    caches.open(CACHE_NAME).then(function(cache) {
      return cache.keys();
    }).then(function(keys) {
      if (e.ports && e.ports[0]) {
        e.ports[0].postMessage({
          cached: keys.length,
          version: CACHE_NAME
        });
      }
    });
  }
});
