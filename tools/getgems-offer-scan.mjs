import fs from 'node:fs';

const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/151.0 Safari/537.36';

async function request(url, options = {}) {
  try {
    const r = await fetch(url, {
      redirect: 'follow',
      ...options,
      headers: { 'user-agent': UA, accept: '*/*', ...(options.headers || {}) },
    });
    const text = await r.text();
    let body;
    try { body = JSON.parse(text); } catch { body = text; }
    return { url: r.url, status: r.status, ok: r.ok, headers: Object.fromEntries(r.headers), body };
  } catch (e) {
    return { url, status: 0, ok: false, error: String(e) };
  }
}

function scriptUrls(html, base) {
  if (typeof html !== 'string') return [];
  const out = [];
  for (const m of html.matchAll(/<script[^>]+src=["']([^"']+)["']/gi)) {
    try { out.push(new URL(m[1], base).href); } catch {}
  }
  return [...new Set(out)];
}

function interesting(text) {
  if (typeof text !== 'string') return [];
  const hits = new Set();
  const patterns = [
    /https?:\\?\/\\?\/[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+/g,
    /["'`]\/(?:api|v1|v2|graphql|prices?|floors?|offers?)[A-Za-z0-9_./?=&:%{}-]*["'`]/gi,
    /.{0,120}(?:getgems|telegram|resale|marketplace|floor|offer).{0,220}/gi,
  ];
  for (const p of patterns) {
    for (const m of text.matchAll(p)) {
      const s = m[0].replace(/\\u0026/g, '&').replace(/\\\//g, '/');
      if (s.length < 1000) hits.add(s);
      if (hits.size > 250) return [...hits];
    }
  }
  return [...hits];
}

async function inspectSite(url, maxScripts = 40) {
  const page = await request(url);
  const scripts = scriptUrls(page.body, page.url || url).slice(0, maxScripts);
  const inspected = [];
  for (const src of scripts) {
    const r = await request(src);
    const hits = interesting(r.body);
    if (hits.length) inspected.push({ src, status: r.status, hits });
  }
  return { page: { url: page.url, status: page.status, hits: interesting(page.body) }, scripts: inspected };
}

async function postJson(url, body, headers = {}) {
  return request(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...headers },
    body: JSON.stringify(body),
  });
}

async function main() {
  const [gaEvil, gaPepe, gaPrices, giftLoot, ggInfo, giftstat, assets] = await Promise.all([
    postJson('https://giftasset.gifts/api/v1/gifts/get_collection_offers', { collection_name: 'Evil Eye' }),
    postJson('https://giftasset.gifts/api/v1/gifts/get_collection_offers', { collection_name: 'Plush Pepe' }),
    request('https://giftasset.gifts/api/v1/gifts/get_gifts_price_list'),
    inspectSite('https://gift-loot.com/gift/en/xmas-stocking/'),
    inspectSite('https://getgems.info/'),
    request('https://api.giftstat.app/current/collections/floor?marketplace=getgems&limit=1000&offset=0'),
    request('https://raw.githubusercontent.com/ssamy2/TelegramGiftsAssests/main/Gifts_Details.json'),
  ]);

  const result = {
    generated_at: new Date().toISOString(),
    giftasset_evil_eye: gaEvil,
    giftasset_plush_pepe: gaPepe,
    giftasset_price_list: gaPrices,
    gift_loot_inspection: giftLoot,
    getgems_info_inspection: ggInfo,
    giftstat_getgems: giftstat,
    telegram_assets: assets,
  };
  fs.writeFileSync('market-scan-result.json', JSON.stringify(result, null, 2));
  console.log(JSON.stringify({
    generated_at: result.generated_at,
    giftasset_evil_eye: { status: gaEvil.status, body: gaEvil.body },
    giftasset_plush_pepe: { status: gaPepe.status, body: gaPepe.body },
    giftasset_price_list_status: gaPrices.status,
    gift_loot_page_status: giftLoot.page.status,
    gift_loot_script_bundles_with_hits: giftLoot.scripts.length,
    getgems_info_page_status: ggInfo.page.status,
    getgems_info_script_bundles_with_hits: ggInfo.scripts.length,
    giftstat_status: giftstat.status,
    assets_status: assets.status,
  }, null, 2));
}

main().catch(e => { console.error(e); process.exit(1); });
