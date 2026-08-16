import crypto from 'node:crypto';
import nacl from 'tweetnacl';
import { beginCell, storeStateInit } from '@ton/core';
import { WalletContractV4 } from '@ton/ton';
import { mnemonicNew, mnemonicToPrivateKey } from '@ton/crypto';

const UA='BlackF1re-auth-probe/1.0';
async function req(url,headers={},options={}){const r=await fetch(url,{...options,headers:{'user-agent':UA,accept:'application/json',...headers},signal:AbortSignal.timeout(20000)});const t=await r.text();let b;try{b=JSON.parse(t)}catch{b=t}return{status:r.status,body:b}}
function digest(address,domain,ts,payload){const wc=Buffer.alloc(4);wc.writeInt32BE(address.workChain);const db=Buffer.from(domain);const dl=Buffer.alloc(4);dl.writeUInt32LE(db.length);const tb=Buffer.alloc(8);tb.writeBigUInt64LE(BigInt(ts));const m=Buffer.concat([Buffer.from('ton-proof-item-v2/'),wc,address.hash,dl,db,tb,Buffer.from(payload)]);const h=crypto.createHash('sha256').update(m).digest();return crypto.createHash('sha256').update(Buffer.concat([Buffer.from([255,255]),Buffer.from('ton-connect'),h])).digest()}
async function token(){const kp=await mnemonicToPrivateKey(await mnemonicNew(24));const w=WalletContractV4.create({workchain:0,publicKey:kp.publicKey});const si=beginCell().store(storeStateInit(w.init)).endCell().toBoc().toString('base64');const domain='getgems.io',payload='getgems-llm',ts=Math.floor(Date.now()/1000);const sig=Buffer.from(nacl.sign.detached(new Uint8Array(digest(w.address,domain,ts,payload)),new Uint8Array(kp.secretKey))).toString('base64');const b={address:w.address.toRawString(),chain:'-239',walletStateInit:si,publicKey:kp.publicKey.toString('hex'),timestamp:ts,domainLengthBytes:domain.length,domainValue:domain,signature:sig,payload,authApplication:'GPT-5.6 Sol'};const r=await req('https://api.getgems.io/public-api/auth/ton-proof',{'content-type':'application/json'},{method:'POST',body:JSON.stringify(b)});return r.body?.token}
async function main(){const t=await token();if(!t)throw Error('no token');const H={Authorization:t};const urls=[
'https://api.getgems.io/public-api/v1/gifts/collections/top?kind=all&limit=100',
'https://api.getgems.io/public-api/v1/collections/top?kind=all&limit=100',
'https://api.getgems.io/public-api/v1/gifts/collections/top?kind=month&limit=100',
'https://api.getgems.io/public-api/v1/gifts/collections?limit=100',
'https://getgems.io/gifts',
'https://getgems.io/gifts-collection'
];for(const u of urls){const r=await req(u,u.includes('/public-api/')?H:{});const b=r.body;const summary=typeof b==='string'?{text:b.slice(0,1000),collectionAddresses:[...b.matchAll(/EQ[A-Za-z0-9_-]{46}/g)].slice(0,10).map(x=>x[0])}:{keys:b&&typeof b==='object'?Object.keys(b):[],body:b};console.log('\nURL',u,'STATUS',r.status,JSON.stringify(summary).slice(0,12000));}}
main().catch(e=>{console.error(e);process.exit(1)});
