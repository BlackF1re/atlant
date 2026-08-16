import fs from 'node:fs';

const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/151.0 Safari/537.36';
async function req(url) {
  try {
    const r = await fetch(url, { redirect: 'follow', headers: { 'user-agent': UA, accept: '*/*' }, signal: AbortSignal.timeout(15000) });
    const text = await r.text();
    let body; try { body = JSON.parse(text); } catch { body = text; }
    return { final_url: r.url, status: r.status, ok: r.ok, body };
  } catch (e) { return { status: 0, ok: false, error: String(e) }; }
}

function ggGet(query, variables = {}) {
  const u = new URL('https://getgems.io/graphql/');
  u.searchParams.set('query', query);
  u.searchParams.set('variables', JSON.stringify(variables));
  return u.href;
}

async function main() {
  const q = `query Probe { __type(name: "Query") { fields { name args { name } } } __typeOffer: __type(name: "NftOffer") { fields { name } } }`;
  const target = ggGet(q);
  const proxies = {
    direct: target,
    allorigins: 'https://api.allorigins.win/raw?url=' + encodeURIComponent(target),
    codetabs: 'https://api.codetabs.com/v1/proxy?quest=' + encodeURIComponent(target),
    corsproxy: 'https://corsproxy.io/?url=' + encodeURIComponent(target),
    jina: 'https://r.jina.ai/' + target,
  };
  const results = {};
  for (const [name,url] of Object.entries(proxies)) results[name] = await req(url);

  const catalog = await req('https://gift-loot.com/api/catalog');
  const gifts = catalog.body?.gifts ?? [];

  fs.writeFileSync('market-scan-result.json', JSON.stringify({ generated_at: new Date().toISOString(), target, proxy_results: results, gift_loot: { status: catalog.status, count: gifts.length, gifts } }, null, 2));
  console.log(JSON.stringify({ generated_at: new Date().toISOString(), proxies: Object.fromEntries(Object.entries(results).map(([k,v]) => [k,{status:v.status, ok:v.ok, sample: typeof v.body==='string'?v.body.slice(0,180):v.body}])), gift_count: gifts.length }, null, 2));
}

main().catch(e => { console.error(e); process.exit(1); });
