import crypto from 'node:crypto';
import nacl from 'tweetnacl';
import { beginCell, storeStateInit } from '@ton/core';
import { WalletContractV4 } from '@ton/ton';
import { mnemonicNew, mnemonicToPrivateKey } from '@ton/crypto';

const UA='BlackF1re-auth-probe/1.0';
async function req(url,headers={},options={}){const r=await fetch(url,{...options,headers:{'user-agent':UA,accept:'application/json',...headers},signal:AbortSignal.timeout(15000)});const t=await r.text();let b;try{b=JSON.parse(t)}catch{b=t}return{status:r.status,body:b}}
function digest(address,domain,ts,payload){const wc=Buffer.alloc(4);wc.writeInt32BE(address.workChain);const db=Buffer.from(domain);const dl=Buffer.alloc(4);dl.writeUInt32LE(db.length);const tb=Buffer.alloc(8);tb.writeBigUInt64LE(BigInt(ts));const m=Buffer.concat([Buffer.from('ton-proof-item-v2/'),wc,address.hash,dl,db,tb,Buffer.from(payload)]);const h=crypto.createHash('sha256').update(m).digest();return crypto.createHash('sha256').update(Buffer.concat([Buffer.from([255,255]),Buffer.from('ton-connect'),h])).digest()}
function decodeJwt(t){try{const p=t.split('.')[1];if(!p)return null;return JSON.parse(Buffer.from(p,'base64url').toString())}catch{return null}}
async function main(){const kp=await mnemonicToPrivateKey(await mnemonicNew(24));const wallet=WalletContractV4.create({workchain:0,publicKey:kp.publicKey});const stateInit=beginCell().store(storeStateInit(wallet.init)).endCell().toBoc().toString('base64');const domain='getgems.io',payload='getgems-llm',ts=Math.floor(Date.now()/1000);const sig=Buffer.from(nacl.sign.detached(new Uint8Array(digest(wallet.address,domain,ts,payload)),new Uint8Array(kp.secretKey))).toString('base64');const body={address:wallet.address.toRawString(),chain:'-239',walletStateInit:stateInit,publicKey:kp.publicKey.toString('hex'),timestamp:ts,domainLengthBytes:Buffer.byteLength(domain),domainValue:domain,signature:sig,payload,authApplication:'GPT-5.6 Sol'};const a=await req('https://api.getgems.io/public-api/auth/ton-proof',{'content-type':'application/json'},{method:'POST',body:JSON.stringify(body)});const token=a.body?.token??a.body?.response?.token;console.log('AUTH',JSON.stringify({status:a.status,bodyKeys:a.body&&typeof a.body==='object'?Object.keys(a.body):[],tokenType:typeof token,tokenLength:token?.length??null,tokenPrefix:token?.slice(0,8)??null,jwtClaims:token?decodeJwt(token):null},null,2));if(!token)return;
const tests=[
['api-raw','https://api.getgems.io/public-api/v1/gifts/collections?limit=1',{Authorization:token}],
['api-bearer','https://api.getgems.io/public-api/v1/gifts/collections?limit=1',{Authorization:`Bearer ${token}`}],
['api-llm','https://api.getgems.io/public-api/v1/gifts/collections?limit=1',{Authorization:`LLM ${token}`}],
['api-xkey','https://api.getgems.io/public-api/v1/gifts/collections?limit=1',{'X-Api-Key':token}],
['web-raw','https://getgems.io/public-api/v1/gifts/collections?limit=1',{Authorization:token}],
['web-bearer','https://getgems.io/public-api/v1/gifts/collections?limit=1',{Authorization:`Bearer ${token}`}],
['api-offer-raw','https://api.getgems.io/public-api/v1/offers/collection/EQBG-g6ahkAUGWpefWbx-D_9sQ8oWbvy6puuq78U2c4NUDFS?limit=1',{Authorization:token}],
['api-offer-bearer','https://api.getgems.io/public-api/v1/offers/collection/EQBG-g6ahkAUGWpefWbx-D_9sQ8oWbvy6puuq78U2c4NUDFS?limit=1',{Authorization:`Bearer ${token}`}]
];for(const[x,u,h]of tests){const r=await req(u,h);console.log(x,JSON.stringify({status:r.status,body:r.body}));}}
main().catch(e=>{console.error(e);process.exit(1)});
