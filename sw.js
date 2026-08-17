// ═══════════════════════════════════════════════════════════
//  RHoo! · Service Worker
//
//  ESTRATEGIA, y el porque:
//  El codigo (navegacion, html, js, css) va SIEMPRE por red y
//  la cache es solo respaldo sin conexion. Los assets que no
//  cambian (iconos, fuentes) van por cache.
//
//  La decision NO se toma con una lista de rutas. Ese fue
//  exactamente el bug que nos costo una tarde en el proyecto
//  anterior: una ruta que no estaba en la lista quedo congelada
//  en cache para siempre, sirviendo una version vieja sin que
//  nada lo delatara. Una lista escrita a mano siempre se queda
//  corta.
// ═══════════════════════════════════════════════════════════

const VERSION = 'rhoo-v1';
const CACHE_CODIGO = VERSION + '-codigo';
const CACHE_ASSETS = VERSION + '-assets';

// Minimo para que la app abra sin conexion
const ESENCIALES = [
  '/',
  '/index.html',
  '/manifest.json',
  '/img/logo-completo.svg',
  '/img/logo-isotipo.svg'
];

self.addEventListener('install', ev => {
  ev.waitUntil(
    caches.open(CACHE_CODIGO)
      // addAll falla completo si UN archivo falta. Se agregan de
      // uno en uno para que un icono ausente no impida instalar
      // el service worker.
      .then(c => Promise.allSettled(ESENCIALES.map(u => c.add(u))))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', ev => {
  ev.waitUntil(
    caches.keys()
      .then(ks => Promise.all(
        ks.filter(k => !k.startsWith(VERSION)).map(k => caches.delete(k))
      ))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', ev => {
  const req = ev.request;
  const url = new URL(req.url);

  if (req.method !== 'GET') return;

  // ── Supabase NO se toca ──
  // Datos, Storage y Edge Functions siempre en vivo. Cachear una
  // consulta de asistencia mostraria checadas de ayer como si
  // fueran de hoy: funcionar con datos falsos es peor que no
  // funcionar.
  if (url.hostname.endsWith('.supabase.co') ||
      url.hostname.endsWith('.supabase.in')) return;

  // ── CODIGO: red primero ──
  const esCodigo =
    req.mode === 'navigate' ||
    url.pathname === '/' ||
    url.pathname.endsWith('.html') ||
    url.pathname.endsWith('.js') ||
    url.pathname.endsWith('.css') ||
    url.pathname.endsWith('.json');

  if (esCodigo) {
    ev.respondWith(
      fetch(req, { cache: 'no-store' })
        .then(res => {
          if (res && res.status === 200 && url.origin === self.location.origin) {
            const copia = res.clone();
            caches.open(CACHE_CODIGO).then(c => c.put(req, copia));
          }
          return res;
        })
        .catch(() =>
          caches.match(req).then(hit => hit || caches.match('/index.html'))
            .then(hit => hit || new Response(
              '<!doctype html><meta charset="utf-8">'
              + '<div style="font:600 15px system-ui;padding:40px;text-align:center">'
              + 'Sin conexion. Revisa tu red e intenta de nuevo.</div>',
              { status: 503, headers: { 'Content-Type': 'text/html; charset=utf-8' } }
            ))
        )
    );
    return;
  }

  // ── ASSETS: cache primero, y se actualiza en segundo plano ──
  ev.respondWith(
    caches.match(req).then(hit => {
      if (hit) {
        // Revalidacion silenciosa: la proxima visita ya trae lo
        // nuevo sin que nadie espere.
        fetch(req).then(res => {
          if (res && res.status === 200) {
            caches.open(CACHE_ASSETS).then(c => c.put(req, res.clone()));
          }
        }).catch(() => {});
        return hit;
      }
      return fetch(req).then(res => {
        if (res && res.status === 200) {
          const copia = res.clone();
          caches.open(CACHE_ASSETS).then(c => c.put(req, copia));
        }
        return res;
      });
    })
  );
});

self.addEventListener('message', ev => {
  if (ev.data === 'SKIP_WAITING') self.skipWaiting();
});