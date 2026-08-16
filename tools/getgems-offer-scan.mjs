import fs from 'node:fs';

const UA = 'BlackF1re-market-scan/1.0';

async function request(url, options = {}) {
  const r = await fetch(url, {
    ...options,
    headers: { 'user-agent': UA, accept: 'application/json', ...(options.headers || {}) },
  });
  const text = await r.text();
  let body;
  try { body = JSON.parse(text); } catch { body = text; }
  return { status: r.status, ok: r.ok, body };
}

async function gql(query, variables = {}) {
  const endpoints = ['https://getgems.io/graphql/', 'https://api.getgems.io/graphql'];
  const attempts = [];
  for (const endpoint of endpoints) {
    const res = await request(endpoint, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-gg-client': 'v:1 l:en' },
      body: JSON.stringify({ query, variables }),
    });
    attempts.push({ endpoint, status: res.status, body: res.body });
    if (res.ok && res.body?.data) return { endpoint, data: res.body.data, errors: res.body.errors ?? null, attempts };
  }
  return { endpoint: null, data: null, errors: attempts.at(-1)?.body?.errors ?? null, attempts };
}

async function mainPageTopGift() {
  const items = [];
  let cursor = '0:0';
  const hash = '324c5f4ed0d134f9ae7af434174cd2655f09b70999d9a265b2f63d17c1e38df4';
  for (let page = 0; page < 5 && cursor !== null; page++) {
    const variables = { kind: 'all', count: 100, cursor };
    const extensions = { persistedQuery: { version: 1, sha256Hash: hash } };
    const u = new URL('https://getgems.io/graphql/');
    u.searchParams.set('operationName', 'mainPageTopGift');
    u.searchParams.set('variables', JSON.stringify(variables));
    u.searchParams.set('extensions', JSON.stringify(extensions));
    const r = await request(u, { headers: { 'content-type': 'application/json', 'x-gg-client': 'v:1 l:en' } });
    if (!r.ok || !r.body?.data?.mainPageTopGift) return { items, error: r };
    const p = r.body.data.mainPageTopGift;
    items.push(...(p.items || []));
    cursor = p.cursor ?? null;
  }
  return { items, cursor };
}

async function main() {
  const schemaQuery = `query OfferSchemaProbe {
    queryType: __type(name: "Query") {
      fields {
        name
        args { name type { kind name ofType { kind name ofType { kind name } } } }
        type { kind name ofType { kind name ofType { kind name } } }
      }
    }
    nftOffer: __type(name: "NftOffer") {
      fields { name type { kind name ofType { kind name ofType { kind name } } } }
    }
    nftOfferList: __type(name: "NftOfferList") {
      fields { name type { kind name ofType { kind name ofType { kind name } } } }
    }
  }`;

  const schema = await gql(schemaQuery);
  const offerFields = schema.data?.queryType?.fields?.filter(f => /offer/i.test(f.name)) ?? [];
  const gifts = await mainPageTopGift();
  const first = gifts.items?.[0] ?? null;
  const collection = first?.collection ?? null;

  let restProbe = null;
  if (collection?.address) {
    restProbe = await request(`https://api.getgems.io/public-api/v1/offers/collection/${encodeURIComponent(collection.address)}?limit=5`);
  }

  let giftAssetProbe = null;
  if (collection?.name) {
    giftAssetProbe = await request('https://giftasset.gifts/api/v1/gifts/get_collection_offers', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ collection_name: collection.name }),
    });
  }

  const result = {
    generated_at: new Date().toISOString(),
    gql_endpoint: schema.endpoint,
    gql_errors: schema.errors,
    offer_query_fields: offerFields,
    nft_offer_type: schema.data?.nftOffer ?? null,
    nft_offer_list_type: schema.data?.nftOfferList ?? null,
    gift_items_count: gifts.items?.length ?? 0,
    gift_first_item: first,
    gift_first_collection: collection,
    gift_page_error: gifts.error ?? null,
    rest_collection_offer_probe: restProbe,
    giftasset_collection_offer_probe: giftAssetProbe,
  };

  fs.writeFileSync('market-scan-result.json', JSON.stringify(result, null, 2));
  console.log(JSON.stringify({
    generated_at: result.generated_at,
    gql_endpoint: result.gql_endpoint,
    offer_query_fields: offerFields.map(x => x.name),
    gift_items_count: result.gift_items_count,
    gift_first_collection: result.gift_first_collection,
    rest_status: restProbe?.status,
    giftasset_status: giftAssetProbe?.status,
  }, null, 2));
}

main().catch(e => { console.error(e); process.exit(1); });
