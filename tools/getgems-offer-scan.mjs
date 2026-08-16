import fs from 'node:fs';
import crypto from 'node:crypto';
import nacl from 'tweetnacl';
import { beginCell, storeStateInit } from '@ton/core';
import { WalletContractV4 } from '@ton/ton';
import { mnemonicNew, mnemonicToPrivateKey } from '@ton/crypto';

const GG = 'https://api.getgems.io/public-api';
const UA = 'BlackF1re-market-scan/1.0';

async function request(url, options = {}, retries = 3) {
  for (let attempt = 0; ; attempt++) {
    const r = await fetch(url, {
      ...options,
      headers: { 'user-agent': UA, accept: 'application/json', ...(options.headers || {}) },
      signal: AbortSignal.timeout(30000),
    });
    const text = await r.text();
    let body; try { body = JSON.parse(text); } catch { body = text; }
    if (r.status === 429 && attempt < retries) {
      await new Promise(res => setTimeout(res, 1500 * (attempt + 1)));
      continue;
    }
    return { status: r.status, ok: r.ok, body };
  }
}

function createTonProofDigest(address, domain, timestamp, payload) {
  const wc = Buffer.alloc(4);
  wc.writeInt32BE(address.workChain, 0);
  const dl = Buffer.alloc(4);
  const domainBytes = Buffer.from(domain, 'utf8');
  dl.writeUInt32LE(domainBytes.length, 0);
  const ts = Buffer.alloc(8);
  ts.writeBigUInt64LE(BigInt(timestamp), 0);
  const msg = Buffer.concat([
    Buffer.from('ton-proof-item-v2/', 'utf8'),
    wc,
    address.hash,
    dl,
    domainBytes,
    ts,
    Buffer.from(payload, 'utf8'),
  ]);
  const msgHash = crypto.createHash('sha256').update(msg).digest();
  return crypto.createHash('sha256').update(Buffer.concat([
    Buffer.from([0xff, 0xff]),
    Buffer.from('ton-connect', 'utf8'),
    msgHash,
  ])).digest();
}

async function getAuthToken() {
  const words = await mnemonicNew(24);
  const kp = await mnemonicToPrivateKey(words);
  const wallet = WalletContractV4.create({ workchain: 0, publicKey: kp.publicKey });
  const stateInit = beginCell().store(storeStateInit(wallet.init)).endCell().toBoc().toString('base64');
  const payload = 'getgems-llm';
  const domains = ['getgems.io', 'api.getgems.io'];
  const attempts = [];

  for (const domain of domains) {
    const timestamp = Math.floor(Date.now() / 1000);
    const digest = createTonProofDigest(wallet.address, domain, timestamp, payload);
    const signature = Buffer.from(nacl.sign.detached(new Uint8Array(digest), new Uint8Array(kp.secretKey))).toString('base64');
    const body = {
      address: wallet.address.toRawString(),
      chain: '-239',
      walletStateInit: stateInit,
      publicKey: kp.publicKey.toString('hex'),
      timestamp,
      domainLengthBytes: Buffer.byteLength(domain, 'utf8'),
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
    attempts.push({ domain, status: r.status, body: r.body });
    if (r.ok && r.body?.token) return { token: r.body.token, domain, wallet: wallet.address.toRawString(), attempts };
    if (r.ok && r.body?.response?.token) return { token: r.body.response.token, domain, wallet: wallet.address.toRawString(), attempts };
  }
  return { token: null, attempts };
}

async function ggGet(path, token) {
  return request(`${GG}${path}`, { headers: { Authorization: token } });
}

async function fetchGiftCollections(token) {
  const items = [];
  let after = null;
  for (let page = 0; page < 10; page++) {
    const u = new URL(`${GG}/v1/gifts/collections`);
    u.searchParams.set('limit', '100');
    if (after) u.searchParams.set('after', after);
    const r = await request(u, { headers: { Authorization: token } });
    if (!r.ok) return { items, error: r };
    const p = r.body?.response ?? r.body;
    items.push(...(p?.items ?? []));
    after = p?.cursor ?? null;
    if (!after) break;
  }
  return { items };
}

async function fetchCollectionOffers(address, token) {
  const items = [];
  let after = null;
  for (let page = 0; page < 20; page++) {
    const u = new URL(`${GG}/v1/offers/collection/${encodeURIComponent(address)}`);
    u.searchParams.set('limit', '100');
    if (after) u.searchParams.set('after', after);
    const r = await request(u, { headers: { Authorization: token } });
    if (!r.ok) return { items, error: r };
    const p = r.body?.response ?? r.body;
    items.push(...(p?.items ?? []));
    after = p?.cursor ?? null;
    if (!after) break;
  }
  return { items };
}

function n(s) { return String(s ?? '').normalize('NFKD').toLowerCase().replace(/[’']/g, '').replace(/[^a-z0-9]+/g, ' ').trim(); }
function variants(name) {
  const base = n(name);
  const v = new Set([base]);
  if (base.endsWith('s')) v.add(base.slice(0, -1)); else v.add(base + 's');
  if (base.endsWith('es')) v.add(base.slice(0, -2));
  return v;
}
function matchCollection(giftName, collections) {
  const gv = variants(giftName);
  let exact = collections.filter(c => [...variants(c.name)].some(x => gv.has(x)));
  if (exact.length === 1) return exact[0];
  const key = n(giftName).replace(/ /g, '');
  exact = collections.filter(c => n(c.name).replace(/ /g, '').includes(key) || key.includes(n(c.name).replace(/ /g, '')));
  return exact.length === 1 ? exact[0] : null;
}

async function poolMap(arr, concurrency, fn) {
  const out = new Array(arr.length);
  let i = 0;
  async function worker() {
    while (true) {
      const idx = i++;
      if (idx >= arr.length) return;
      out[idx] = await fn(arr[idx], idx);
    }
  }
  await Promise.all(Array.from({ length: concurrency }, worker));
  return out;
}

async function main() {
  const catalogResp = await request('https://gift-loot.com/api/catalog');
  const gifts = catalogResp.body?.gifts ?? [];
  if (!gifts.length) throw new Error(`Gift Loot catalog failed: ${catalogResp.status}`);

  const auth = await getAuthToken();
  const safeAuth = { domain: auth.domain ?? null, wallet: auth.wallet ?? null, attempts: auth.attempts.map(a => ({ domain: a.domain, status: a.status, body: a.body })) };
  if (!auth.token) {
    fs.writeFileSync('market-scan-result.json', JSON.stringify({ generated_at: new Date().toISOString(), gift_loot: gifts, auth: safeAuth }, null, 2));
    throw new Error('Getgems TON Proof authentication failed');
  }

  const gc = await fetchGiftCollections(auth.token);
  if (gc.error) throw new Error(`Gift collections failed: ${JSON.stringify(gc.error).slice(0,500)}`);
  const collections = gc.items;

  const matches = gifts.map(g => ({ gift: g, collection: matchCollection(g.name, collections) }));
  const matched = matches.filter(x => x.collection);
  const offerResults = await poolMap(matched, 5, async ({ gift, collection }) => {
    const r = await fetchCollectionOffers(collection.address, auth.token);
    const now = Math.floor(Date.now() / 1000);
    const active = r.items.filter(o =>
      o.isCollectionOffer !== false &&
      o.isCompleted !== true &&
      Number(o.finishAt ?? 0) > now &&
      (o.maxQuantity == null || o.purchasedQuantity == null || Number(o.purchasedQuantity) < Number(o.maxQuantity))
    );
    active.sort((a,b) => Number(BigInt(b.fullPrice ?? '0') - BigInt(a.fullPrice ?? '0')));
    const best = active[0] ?? null;
    return { gift_name: gift.name, collection, offers_count: r.items.length, active_offers_count: active.length, best_offer: best, error: r.error ?? null };
  });
  const byGift = new Map(offerResults.map(x => [x.gift_name, x]));

  const rows = gifts.map(g => {
    const mr = matches.find(x => x.gift === g);
    const or = byGift.get(g.name);
    const bo = or?.best_offer ?? null;
    const floor = g.getgems_floor_ton == null ? null : Number(g.getgems_floor_ton);
    const offerTon = bo?.fullPrice ? Number(bo.fullPrice) / 1e9 : null;
    return {
      id: g.id,
      gift: g.name,
      telegram_floor_stars: g.floor_price_stars == null ? null : Number(g.floor_price_stars),
      telegram_floor_ton: g.floor_price_ton == null ? null : Number(g.floor_price_ton),
      telegram_resale_count: g.total_resale_count ?? null,
      getgems_floor_ton: floor,
      getgems_listed_count: g.getgems_listed_count ?? null,
      getgems_collection_address: mr?.collection?.address ?? null,
      getgems_collection_name: mr?.collection?.name ?? null,
      highest_getgems_offer_ton: offerTon,
      highest_offer_full_price_nano: bo?.fullPrice ?? null,
      highest_offer_profit_ton: bo?.profitPrice ? Number(bo.profitPrice) / 1e9 : null,
      highest_offer_finish_at: bo?.finishAt ?? null,
      highest_offer_max_quantity: bo?.maxQuantity ?? null,
      highest_offer_purchased_quantity: bo?.purchasedQuantity ?? null,
      highest_offer_is_offchain: bo?.isOffchain ?? null,
      offer_to_floor_pct: floor && offerTon != null ? offerTon / floor * 100 : null,
      active_collection_offers_count: or?.active_offers_count ?? null,
      collection_match: mr?.collection ? 'matched' : 'unmatched',
      offer_error: or?.error ?? null,
    };
  });

  const result = {
    generated_at: new Date().toISOString(),
    auth: safeAuth,
    gift_count: gifts.length,
    getgems_collection_count: collections.length,
    matched_count: rows.filter(r => r.collection_match === 'matched').length,
    unmatched_gifts: rows.filter(r => r.collection_match !== 'matched').map(r => r.gift),
    rows,
  };
  fs.writeFileSync('market-scan-result.json', JSON.stringify(result, null, 2));
  fs.writeFileSync('market-table.csv', [
    ['Gift','Telegram floor (TON)','Telegram floor (Stars)','Getgems floor (TON)','Highest Getgems collection offer (TON)','Offer/Floor %','Active collection offers'].join(','),
    ...rows.map(r => [r.gift, r.telegram_floor_ton ?? '', r.telegram_floor_stars ?? '', r.getgems_floor_ton ?? '', r.highest_getgems_offer_ton ?? '', r.offer_to_floor_pct == null ? '' : r.offer_to_floor_pct.toFixed(2), r.active_collection_offers_count ?? ''].map(v => `"${String(v).replaceAll('"','""')}"`).join(','))
  ].join('\n'));
  console.log(JSON.stringify({ generated_at: result.generated_at, gift_count: result.gift_count, getgems_collection_count: result.getgems_collection_count, matched_count: result.matched_count, unmatched_gifts: result.unmatched_gifts, rows_with_offer: rows.filter(r => r.highest_getgems_offer_ton != null).length }, null, 2));
}

main().catch(e => { console.error(e); process.exit(1); });
