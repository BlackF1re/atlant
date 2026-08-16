import fs from 'node:fs';

const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/151.0 Safari/537.36';

async function req(url) {
  const r = await fetch(url, { redirect: 'follow', headers: { 'user-agent': UA, accept: '*/*' } });
  const text = await r.text();
  let body;
  try { body = JSON.parse(text); } catch { body = text; }
  return { url: r.url, status: r.status, ok: r.ok, body };
}

async function main() {
  const catalog = await req('https://gift-loot.com/api/catalog');
  const liveJs = await req('https://gift-loot.com/gift/gift-live.js');
  const data = catalog.body;
  const gifts = Array.isArray(data) ? data : (data?.gifts ?? data?.items ?? data?.data ?? []);
  const sample = gifts[0] ?? null;
  const keys = sample && typeof sample === 'object' ? Object.keys(sample) : [];
  const offerishKeys = keys.filter(k => /offer|bid|buy|floor|resale|getgems|market|listed/i.test(k));
  const offerishJs = typeof liveJs.body === 'string'
    ? liveJs.body.split('\n').filter(x => /offer|bid|buy|floor|resale|getgems|api\//i.test(x)).slice(0, 300)
    : [];

  const compact = gifts.map(g => Object.fromEntries(Object.entries(g).filter(([k]) =>
    /^(id|gift_id|regular_id|name|title|slug|short_name|floor_price_stars|floor_price_ton|total_resale_count|portals_floor_ton|portals_count|tonnel_floor_ton|tonnel_count|mrkt_floor_ton|mrkt_count|getgems_floor_ton|getgems_count|.*offer.*|.*bid.*)$/i.test(k)
  )));

  const result = {
    generated_at: new Date().toISOString(),
    catalog_status: catalog.status,
    catalog_top_level_keys: data && typeof data === 'object' && !Array.isArray(data) ? Object.keys(data) : [],
    gift_count: gifts.length,
    sample,
    sample_keys: keys,
    offerish_keys: offerishKeys,
    live_js_offerish_lines: offerishJs,
    gifts: compact,
  };
  fs.writeFileSync('market-scan-result.json', JSON.stringify(result, null, 2));
  console.log(JSON.stringify({
    generated_at: result.generated_at,
    catalog_status: result.catalog_status,
    gift_count: result.gift_count,
    sample_keys: result.sample_keys,
    offerish_keys: result.offerish_keys,
    js_lines: result.live_js_offerish_lines,
  }, null, 2));
}

main().catch(e => { console.error(e); process.exit(1); });
