import { Cell } from '@ton/core';
import fs from 'node:fs';

const CODE_HASHES = [
  '0285e0ba8e03b38a80a5baf9198ad840510ac835af1e3bfe2ceac7eceba592c5',
  'f0449dca7dd58b13607508839087668196aaef2c7df9ef5fe5b73e0a9177255e',
];
const TONCENTER = 'https://toncenter.com/api/v3';
const now = Math.floor(Date.now() / 1000);

async function fetchJson(url) {
  const r = await fetch(url, { headers: { 'user-agent': 'BlackF1re-market-scan/1.0' } });
  const text = await r.text();
  if (!r.ok) throw new Error(`${r.status} ${url}: ${text.slice(0, 500)}`);
  return JSON.parse(text);
}

function parseOffer(account) {
  if (!account.data_boc) return null;
  const root = Cell.fromBase64(account.data_boc);
  const s = root.beginParse();
  s.loadUintBig(256);                    // publicKey
  const ownerAddress = s.loadAddress();
  const isComplete = s.loadBit();
  const nftPrice = s.loadCoins();
  const maxCount = Number(s.loadUintBig(20));
  const boughtCount = Number(s.loadUintBig(20));
  const finishAt = Number(s.loadUintBig(32));
  s.loadRef();                           // fees
  s.loadUintBig(64);                     // lastCleaned
  const hasQueryIds = s.loadBit();       // HashmapE 64
  if (hasQueryIds) s.loadRef();
  const staticData = s.loadRef().beginParse();
  const createdAt = Number(staticData.loadUintBig(32));
  const targetTag = Number(staticData.loadUintBig(8));
  let collectionAddress = null;
  let nftAddress = null;
  if (targetTag === 0) {
    const a = staticData.loadAddress();
    collectionAddress = a ? a.toRawString() : null;
  } else if (targetTag === 1) {
    const a = staticData.loadAddress();
    nftAddress = a ? a.toRawString() : null;
  }
  return {
    offer_address: account.address,
    code_hash: account.code_hash,
    owner_address: ownerAddress ? ownerAddress.toRawString() : null,
    is_complete: isComplete,
    nft_price_nano: nftPrice.toString(),
    nft_price_ton: Number(nftPrice) / 1e9,
    max_count: maxCount,
    bought_count: boughtCount,
    remaining_count: Math.max(0, maxCount - boughtCount),
    created_at: createdAt,
    finish_at: finishAt,
    target_tag: targetTag,
    collection_address: collectionAddress,
    nft_address: nftAddress,
  };
}

async function collectionMetadata(addresses) {
  const out = {};
  for (let i = 0; i < addresses.length; i += 100) {
    const chunk = addresses.slice(i, i + 100);
    const qs = new URLSearchParams();
    for (const a of chunk) qs.append('collection_address', a);
    qs.set('limit', '1000');
    const j = await fetchJson(`${TONCENTER}/nft/collections?${qs}`);
    for (const c of (j.nft_collections || [])) {
      out[c.address] = { ...c, metadata: j.metadata?.[c.address] ?? null };
    }
  }
  return out;
}

async function giftstatFloors(marketplace) {
  const url = `https://api.giftstat.app/current/collections/floor?marketplace=${encodeURIComponent(marketplace)}&limit=1000&offset=0`;
  try { return await fetchJson(url); } catch (e) { return { error: String(e) }; }
}

async function telegramAssets() {
  const url = 'https://raw.githubusercontent.com/ssamy2/TelegramGiftsAssests/main/Gifts_Details.json';
  try { return await fetchJson(url); } catch (e) { return { error: String(e) }; }
}

async function main() {
  const rawResponses = [];
  const parsed = [];
  for (const h of CODE_HASHES) {
    const url = `${TONCENTER}/accountStates?code_hash=${h}&include_boc=true`;
    const j = await fetchJson(url);
    rawResponses.push({ code_hash: h, count: j.accounts?.length ?? 0 });
    for (const a of (j.accounts || [])) {
      try {
        const p = parseOffer(a);
        if (p) parsed.push(p);
      } catch (e) {
        parsed.push({ offer_address: a.address, code_hash: h, parse_error: String(e) });
      }
    }
  }

  const activeCollectionOffers = parsed.filter(o =>
    !o.parse_error && o.target_tag === 0 && o.collection_address &&
    !o.is_complete && o.finish_at > now && o.remaining_count > 0
  );

  const best = new Map();
  for (const o of activeCollectionOffers) {
    const prev = best.get(o.collection_address);
    if (!prev || o.nft_price_ton > prev.nft_price_ton) best.set(o.collection_address, o);
  }

  const collectionAddresses = [...best.keys()];
  const metadata = await collectionMetadata(collectionAddresses);
  const bestOffers = collectionAddresses.map(addr => {
    const o = best.get(addr);
    const m = metadata[addr] || {};
    const md = m.metadata || {};
    return {
      collection_address: addr,
      collection_name: md.name ?? m.content?.name ?? m.name ?? null,
      collection_metadata: md,
      ...o,
    };
  }).sort((a,b) => b.nft_price_ton - a.nft_price_ton);

  const [getgemsFloor, fragmentFloor, assets] = await Promise.all([
    giftstatFloors('getgems'),
    giftstatFloors('fragment'),
    telegramAssets(),
  ]);

  const result = {
    generated_at: new Date().toISOString(),
    unix_now: now,
    code_hash_queries: rawResponses,
    parsed_contracts: parsed.length,
    parse_errors: parsed.filter(x => x.parse_error).length,
    active_collection_offers: activeCollectionOffers.length,
    unique_collections_with_active_offers: bestOffers.length,
    result_may_be_truncated: rawResponses.some(x => x.count >= 1000),
    best_offers: bestOffers,
    giftstat_getgems_floor: getgemsFloor,
    giftstat_fragment_floor: fragmentFloor,
    telegram_assets: assets,
  };
  fs.writeFileSync('market-scan-result.json', JSON.stringify(result, null, 2));
  console.log(JSON.stringify({
    generated_at: result.generated_at,
    code_hash_queries: result.code_hash_queries,
    parsed_contracts: result.parsed_contracts,
    parse_errors: result.parse_errors,
    active_collection_offers: result.active_collection_offers,
    unique_collections_with_active_offers: result.unique_collections_with_active_offers,
    result_may_be_truncated: result.result_may_be_truncated,
  }, null, 2));
}

main().catch(e => { console.error(e); process.exit(1); });
