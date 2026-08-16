import fs from 'node:fs';
import crypto from 'node:crypto';
import nacl from 'tweetnacl';
import { beginCell, storeStateInit } from '@ton/core';
import { WalletContractV4 } from '@ton/ton';
import { mnemonicNew, mnemonicToPrivateKey } from '@ton/crypto';

const GG = 'https://api.getgems.io/public-api';
const UA = 'BlackF1re-market-scan/1.0';

async function request(url, options = {}, retries = 5) {
  for (let attempt = 0; ; attempt++) {
    const r = await fetch(url, {
      ...options,
      headers: { 'user-agent': UA, accept: 'application/json', ...(options.headers || {}) },
      signal: AbortSignal.timeout(30000),
    });
    const text = await r.text();
    let body;
    try { body = JSON.parse(text); } catch { body = text; }
    if (r.status === 429 && attempt < retries) {
      await new Promise(res => setTimeout(res, 1500 * (attempt + 1)));
      continue;
    }
    return { status: r.status, ok: r.ok, body };
  }
}

async function ggRequest(url, token) {
  return request(url, { headers: { Authorization: token } });
}

function createTonProofDigest(address, domain, timestamp, payload) {
  const wc = Buffer.alloc(4);
  wc.writeInt32BE(address.workChain, 0);
  const domainBytes = Buffer.from(domain, 'utf8');
  const dl = Buffer.alloc(4);
  dl.writeUInt32LE(domainBytes.length, 0);
  const ts = Buffer.alloc(8);
  ts.writeBigUInt64LE(BigInt(timestamp), 0);
  const msg = Buffer.concat([
    Buffer.from('ton-proof-item-v2/'), wc, address.hash,
    dl, domainBytes, ts, Buffer.from(payload),
  ]);
  const msgHash = crypto.createHash('sha256').update(msg).digest();
  return crypto.createHash('sha256').update(Buffer.concat([
    Buffer.from([0xff, 0xff]), Buffer.from('ton-connect'), msgHash,
  ])).digest();
}

async function getAuthToken() {
  const kp = await mnemonicToPrivateKey(await mnemonicNew(24));
  const wallet = WalletContractV4.create({ workchain: 0, publicKey: kp.publicKey });
  const stateInit = beginCell().store(storeStateInit(wallet.init)).endCell().toBoc().toString('base64');
  const payload = 'getgems-llm';
  const domain = 'getgems.io';
  const timestamp = Math.floor(Date.now() / 1000);
  const signature = Buffer.from(nacl.sign.detached(
    new Uint8Array(createTonProofDigest(wallet.address, domain, timestamp, payload)),
    new Uint8Array(kp.secretKey),
  )).toString('base64');
  const body = {
    address: wallet.address.toRawString(),
    chain: '-239',
    walletStateInit: stateInit,
    publicKey: kp.publicKey.toString('hex'),
    timestamp,
    domainLengthBytes: Buffer.byteLength(domain),
    domainValue: domain,
    signature,
    payload,
    authApplication: 'GPT-5.6 Sol',
  };
  const r = await request(`${GG}/auth/ton-proof`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  const token = r.body?.token ?? r.body?.response?.token ?? null;
  if (!r.ok || !token) throw new Error(`TON Proof auth failed: ${r.status} ${JSON.stringify(r.body).slice(0, 300)}`);
  return { token, wallet: wallet.address.toRawString(), tokenPrefix: token.slice(0, 8) };
}

async function fetchGiftCollections(token) {
  const byAddress = new Map();
  let after = null;
  for (let page = 0; page < 10; page++) {
    const u = new URL(`${GG}/v1/gifts/collections/top`);
    u.searchParams.set('kind', 'all');
    u.searchParams.set('limit', '100');
    if (after) u.searchParams.set('after', after);
    const r = await ggRequest(u, token);
    if (!r.ok) throw new Error(`gift collections top failed: ${r.status} ${JSON.stringify(r.body).slice(0, 400)}`);
    const p = r.body?.response ?? r.body;
    for (const item of (p?.items ?? [])) {
      if (item?.collection?.address) byAddress.set(item.collection.address, item.collection);
    }
    after = p?.cursor ?? null;
    if (!after) break;
  }
  return [...byAddress.values()];
}

async function fetchCollectionOffers(address, token) {
  const items = [];
  let after = null;
  for (let page = 0; page < 30; page++) {
    const u = new URL(`${GG}/v1/offers/collection/${encodeURIComponent(address)}`);
    u.searchParams.set('limit', '100');
    if (after) u.searchParams.set('after', after);
    const r = await ggRequest(u, token);
    if (!r.ok) return { items, error: { status: r.status, body: r.body } };
    const p = r.body?.response ?? r.body;
    items.push(...(p?.items ?? []));
    after = p?.cursor ?? null;
    if (!after) break;
  }
  return { items, error: null };
}

function normalizeName(s) {
  return String(s ?? '').normalize('NFKD').toLowerCase()
    .replace(/[’']/g, '').replace(/[^a-z0-9]+/g, ' ').trim();
}
function variants(name) {
  const b = normalizeName(name);
  const v = new Set([b]);
  const words = b.split(' ');
  const last = words.at(-1) ?? '';
  const stem = words.slice(0, -1).join(' ');
  const addLast = x => v.add((stem ? stem + ' ' : '') + x);
  if (last.endsWith('ies')) addLast(last.slice(0, -3) + 'y');
  if (last.endsWith('ches') || last.endsWith('shes') || last.endsWith('xes') || last.endsWith('zes') || last.endsWith('ses')) addLast(last.slice(0, -2));
  if (last.endsWith('es')) addLast(last.slice(0, -2));
  if (last.endsWith('s')) addLast(last.slice(0, -1));
  else addLast(last + 's');
  return v;
}
function matchCollection(name, collections) {
  const gv = variants(name);
  let matches = collections.filter(c => [...variants(c.name)].some(x => gv.has(x)));
  if (matches.length === 1) return matches[0];
  const key = normalizeName(name).replace(/ /g, '');
  matches = collections.filter(c => {
    const ck = normalizeName(c.name).replace(/ /g, '');
    return ck === key || ck === key + 's' || key === ck + 's';
  });
  return matches.length === 1 ? matches[0] : null;
}

async function poolMap(arr, concurrency, fn) {
  const out = new Array(arr.length);
  let i = 0;
  async function worker() {
    while (true) {
      const index = i++;
      if (index >= arr.length) return;
      out[index] = await fn(arr[index], index);
      await new Promise(r => setTimeout(r, 80));
    }
  }
  await Promise.all(Array.from({ length: concurrency }, worker));
  return out;
}

function finishIsFuture(value) {
  if (value == null) return true;
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) return true;
  const ms = n < 1e12 ? n * 1000 : n;
  return ms > Date.now();
}

async function main() {
  const catalog = await request('https://gift-loot.com/api/catalog');
  const gifts = catalog.body?.gifts ?? [];
  if (!catalog.ok || !gifts.length) throw new Error(`Gift Loot failed: ${catalog.status}`);

  const auth = await getAuthToken();
  const collections = await fetchGiftCollections(auth.token);
  const matches = gifts.map(g => ({ gift: g, collection: matchCollection(g.name, collections) }));
  const matched = matches.filter(x => x.collection);

  console.log(`Gift Loot rows=${gifts.length}; Getgems gift collections=${collections.length}; matched=${matched.length}`);

  const offerResults = await poolMap(matched, 4, async ({ gift, collection }) => {
    const r = await fetchCollectionOffers(collection.address, auth.token);
    const active = r.items.filter(o =>
      o.isCollectionOffer !== false &&
      o.isCompleted !== true &&
      finishIsFuture(o.finishAt) &&
      (o.maxQuantity == null || o.purchasedQuantity == null || Number(o.purchasedQuantity) < Number(o.maxQuantity))
    );
    active.sort((a, b) => {
      const aa = BigInt(a.fullPrice ?? '0');
      const bb = BigInt(b.fullPrice ?? '0');
      return aa === bb ? 0 : aa > bb ? -1 : 1;
    });
    return {
      gift_name: gift.name,
      collection,
      offers_count: r.items.length,
      active_offers_count: active.length,
      best_offer: active[0] ?? null,
      error: r.error,
    };
  });
  const byGift = new Map(offerResults.map(x => [x.gift_name, x]));

  const rows = gifts.map(g => {
    const match = matches.find(x => x.gift === g);
    const result = byGift.get(g.name);
    const best = result?.best_offer ?? null;
    const ggFloor = g.getgems_floor_ton == null ? null : Number(g.getgems_floor_ton);
    const offerTon = best?.fullPrice != null ? Number(best.fullPrice) / 1e9 : null;
    return {
      id: g.id,
      gift: g.name,
      telegram_floor_stars: g.floor_price_stars == null ? null : Number(g.floor_price_stars),
      telegram_floor_ton: g.floor_price_ton == null ? null : Number(g.floor_price_ton),
      telegram_resale_count: g.total_resale_count ?? null,
      getgems_floor_ton: ggFloor,
      getgems_listed_count: g.getgems_listed_count ?? null,
      getgems_collection_address: match?.collection?.address ?? null,
      getgems_collection_name: match?.collection?.name ?? null,
      highest_getgems_offer_ton: offerTon,
      highest_offer_profit_ton: best?.profitPrice != null ? Number(best.profitPrice) / 1e9 : null,
      highest_offer_finish_at: best?.finishAt ?? null,
      highest_offer_max_quantity: best?.maxQuantity ?? null,
      highest_offer_purchased_quantity: best?.purchasedQuantity ?? null,
      highest_offer_address: best?.offerAddress ?? null,
      highest_offer_is_offchain: best?.isOffchain ?? null,
      offer_to_floor_pct: ggFloor && offerTon != null ? offerTon / ggFloor * 100 : null,
      active_collection_offers_count: result?.active_offers_count ?? null,
      total_collection_offers_fetched: result?.offers_count ?? null,
      collection_match: match?.collection ? 'matched' : 'unmatched',
      offer_error: result?.error ?? null,
    };
  }).sort((a, b) => a.gift.localeCompare(b.gift, 'en'));

  const result = {
    generated_at: new Date().toISOString(),
    source_notes: {
      telegram_and_getgems_floors: 'Gift Loot /api/catalog',
      getgems_collection_addresses: 'Getgems /public-api/v1/gifts/collections/top?kind=all',
      getgems_offers: 'Getgems /public-api/v1/offers/collection/{address}',
      authorization: 'ephemeral zero-balance Wallet V4 TON Proof, payload getgems-llm; token not persisted',
    },
    auth_probe: { wallet: auth.wallet, token_prefix: auth.tokenPrefix, token_persisted: false },
    gift_count: gifts.length,
    getgems_collection_count: collections.length,
    matched_count: rows.filter(r => r.collection_match === 'matched').length,
    unmatched_gifts: rows.filter(r => r.collection_match !== 'matched').map(r => r.gift),
    rows_with_active_offer: rows.filter(r => r.highest_getgems_offer_ton != null).length,
    rows_with_offer_errors: rows.filter(r => r.offer_error != null).length,
    rows,
  };
  fs.writeFileSync('market-scan-result.json', JSON.stringify(result, null, 2));

  const csvRows = [
    ['Gift', 'Telegram floor TON', 'Telegram floor Stars', 'Getgems floor TON', 'Highest Getgems collection offer TON', 'Offer/Floor %', 'Active collection offers', 'Getgems collection'],
    ...rows.map(r => [
      r.gift,
      r.telegram_floor_ton ?? '',
      r.telegram_floor_stars ?? '',
      r.getgems_floor_ton ?? '',
      r.highest_getgems_offer_ton ?? '',
      r.offer_to_floor_pct == null ? '' : r.offer_to_floor_pct.toFixed(2),
      r.active_collection_offers_count ?? '',
      r.getgems_collection_name ?? '',
    ]),
  ];
  const csv = csvRows.map(row => row.map(v => `"${String(v).replaceAll('"', '""')}"`).join(',')).join('\n');
  fs.writeFileSync('market-table.csv', csv);

  const md = [
    `# Telegram gifts market snapshot`,
    `Generated: ${result.generated_at}`,
    '',
    '| Gift | Telegram floor | Getgems floor | Highest Getgems offer | Offer/Floor |',
    '|---|---:|---:|---:|---:|',
    ...rows.map(r => {
      const tg = r.telegram_floor_stars != null ? `${r.telegram_floor_stars} ⭐` : r.telegram_floor_ton != null ? `${r.telegram_floor_ton} TON` : '—';
      const gf = r.getgems_floor_ton != null ? `${r.getgems_floor_ton} TON` : '—';
      const of = r.highest_getgems_offer_ton != null ? `${r.highest_getgems_offer_ton} TON` : '—';
      const pct = r.offer_to_floor_pct != null ? `${r.offer_to_floor_pct.toFixed(1)}%` : '—';
      return `| ${r.gift.replaceAll('|', '\\|')} | ${tg} | ${gf} | ${of} | ${pct} |`;
    }),
  ].join('\n');
  fs.writeFileSync('market-table.md', md);

  console.log(JSON.stringify({
    generated_at: result.generated_at,
    gift_count: result.gift_count,
    getgems_collection_count: result.getgems_collection_count,
    matched_count: result.matched_count,
    unmatched_gifts: result.unmatched_gifts,
    rows_with_active_offer: result.rows_with_active_offer,
    rows_with_offer_errors: result.rows_with_offer_errors,
  }, null, 2));
}

main().catch(e => { console.error(e); process.exit(1); });
