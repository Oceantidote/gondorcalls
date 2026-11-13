// gondorcalls.com: serves the site page stored in Supabase (public.site_files, path '/')
// and keeps the free Supabase project awake with a daily cron (which also opens birthday gift plans).
const SB = 'https://vhlalqnxkasijbspyrrp.supabase.co';
const KEY = 'sb_publishable_g2Oe_3tlYEittwgGjF94AQ_vvhB5wDf';
const CANONICAL = 'gondorcalls.com';
const rpc = (fn, args = {}) => fetch(SB + '/rest/v1/rpc/' + fn, { method: 'POST', headers: { apikey: KEY, 'Content-Type': 'application/json' }, body: JSON.stringify(args) });
export default {
  async fetch(req, env, ctx) {
    const url = new URL(req.url);
    if (url.hostname !== CANONICAL) return Response.redirect('https://' + CANONICAL + url.pathname + url.search, 301);
    if (url.pathname !== '/' && url.pathname !== '/index.html') return new Response('Not found', { status: 404 });
    const cache = caches.default, key = new Request(url.origin + '/__page');
    let res = await cache.match(key);
    if (!res) {
      const r = await rpc('get_page', { p_path: '/' });
      if (!r.ok) return new Response('Gondor is not answering. Try again in a minute.', { status: 503 });
      res = new Response(await r.json(), { headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'public, max-age=30', 'x-frame-options': 'DENY', 'referrer-policy': 'no-referrer', 'x-content-type-options': 'nosniff', 'strict-transport-security': 'max-age=31536000' } });
      ctx.waitUntil(cache.put(key, res.clone()));
    }
    return res;
  },
  async scheduled(event, env, ctx) { ctx.waitUntil(rpc('ping')); },
};
