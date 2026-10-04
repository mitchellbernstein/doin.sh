import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { build } from 'esbuild';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';

const port = Number(process.env.DOIN_FIXTURE_PORT || 8792);
const origin = `http://127.0.0.1:${port}`;
const token = 'a'.repeat(64);
let selectedPrice='price_sync';
const fixtureCheckouts=new Map();
let cancelAtPeriodEnd=false,deleted=false,active=process.env.DOIN_FIXTURE_UPGRADE!=='1';
const root = new URL('../', import.meta.url);
const { outputFiles } = await build({ entryPoints: [new URL('worker.ts', root).pathname], bundle: true, external:['cloudflare:workers'], format: 'esm', platform: 'browser', write: false });
const outbound = async (request) => {
    const url = new URL(request.url);
    if (url.hostname === 'mail.fixture') {
      const message = await request.json();
      console.log(JSON.stringify({mail:{to:message.to,url:message.text.match(/https?:\/\/[^\s]+/)[0]}}));
      return Response.json({messageId:'fixture-mail'});
    }
    if(url.hostname!=='api.stripe.com') throw new Error('unexpected provider request');
    if(url.pathname.startsWith('/v1/prices/')) {const id=url.pathname.split('/').pop();if(!['price_month','price_year'].includes(id))throw new Error('invalid fixture price');return Response.json({id,active:true,currency:'usd',unit_amount:id==='price_year'?4999:499,recurring:{interval:id==='price_year'?'year':'month',interval_count:1}});}
    if(url.pathname==='/v1/checkout/sessions') {
      if(request.method==='GET') return Response.json({data:[...fixtureCheckouts.values()].filter(c=>c.status==='open'),has_more:false});
      const fields=new URLSearchParams(await request.text()),key=request.headers.get('idempotency-key');selectedPrice=fields.get('line_items[0][price]');
      if(!['price_month','price_year'].includes(selectedPrice))throw new Error('invalid fixture line item');
      if(!fixtureCheckouts.has(key))fixtureCheckouts.set(key,{id:`cs_fixture${fixtureCheckouts.size}`,customer:'cus_fixture',status:'open',url:'https://checkout.stripe.com/c/pay/fixture#doin-complete-fragment',expires_at:Number(fields.get('expires_at'))});
      active=true;
      return Response.json(fixtureCheckouts.get(key));
    }
    if(url.pathname.startsWith('/v1/checkout/sessions/')) {const item=[...fixtureCheckouts.values()].find(c=>c.id===url.pathname.split('/')[4]);if(!item)throw new Error('unknown fixture checkout');if(url.pathname.endsWith('/expire'))item.status='expired';return Response.json(item);}
    if(url.pathname==='/v1/subscriptions/sub_fixture' && request.method==='POST') {
      cancelAtPeriodEnd=new URLSearchParams(await request.text()).get('cancel_at_period_end')==='true';
      return Response.json({cancel_at_period_end:cancelAtPeriodEnd});
    }
    if(url.pathname==='/v1/subscriptions/sub_fixture' && request.method==='DELETE') {deleted=true;return Response.json({status:'canceled'});}
    if(url.pathname==='/v1/subscriptions') return Response.json({ data: active ? [{ id: 'sub_fixture', customer: 'cus_fixture', status:deleted?'canceled':'active',cancel_at_period_end:cancelAtPeriodEnd,items: { data: [{ price: { id: selectedPrice }, current_period_end: Math.floor(Date.now() / 1000) + 3600 }] } }] : [], has_more: false });
    throw new Error('unexpected provider request');
};
const mf = new Miniflare(convertV4MiniflareOptions({host:'127.0.0.1',port,workers:[
  {name:'doin-cli-fixture',modules:true,script:outputFiles[0].text,compatibilityDate:'2026-10-01',d1Databases:['DB'],kvNamespaces:['OAUTH_KV'],bindings:{ORIGIN:origin,EMAIL_ENABLED:'true',EMAIL_FROM:'signin@doin.sh',STRIPE_SECRET_KEY:'sk_test_fixture',STRIPE_PRICE_ID:'price_sync',STRIPE_MONTHLY_PRICE_ID:'price_month',STRIPE_YEARLY_PRICE_ID:'price_year'},serviceBindings:{EMAIL:{name:'mail',entrypoint:'Mailer'}},outboundService:outbound},
  {name:'mail',modules:true,compatibilityDate:'2026-10-01',script:"import {WorkerEntrypoint} from 'cloudflare:workers'; export class Mailer extends WorkerEntrypoint {async send(message){return (await fetch('https://mail.fixture/message',{method:'POST',body:JSON.stringify(message)})).json();}} export default {fetch(){return new Response('not found',{status:404});}}",outboundService:outbound}
]}));
let stopping = false;
async function stop() {
  if (stopping) return;
  stopping = true;
  await mf.dispose();
  process.exit(0);
}
process.on('SIGINT', stop);
process.on('SIGTERM', stop);
try {
  const db = await mf.getD1Database('DB');
  await db.exec((await readFile(new URL('migrations/0001.sql', root), 'utf8')).replaceAll('\n', ' '));
  await db.exec((await readFile(new URL('migrations/0002.sql', root), 'utf8')).replaceAll('\n', ' '));
  await db.exec((await readFile(new URL('migrations/0003.sql', root), 'utf8')).replaceAll('\n', ' '));
  await db.exec((await readFile(new URL('migrations/0004.sql', root), 'utf8')).replaceAll('\n', ' '));
  await db.exec((await readFile(new URL('migrations/0005.sql', root), 'utf8')).replaceAll('\n', ' '));
  await db.exec((await readFile(new URL('migrations/0006.sql', root), 'utf8')).replaceAll('\n', ' '));
  await db.exec((await readFile(new URL('migrations/0007.sql', root), 'utf8')).replaceAll('\n', ' '));
  await db.exec((await readFile(new URL('migrations/0008.sql', root), 'utf8')).replaceAll('\n', ' '));
  await db.exec((await readFile(new URL('migrations/0009.sql', root), 'utf8')).replaceAll('\n', ' '));
  const now = Math.floor(Date.now() / 1000);
  await db.batch([
    db.prepare('INSERT INTO accounts(id,identity_key,email,name,customer_id,created_at) VALUES(?,?,?,?,?,?)').bind('fixture-account', '101', 'fixture@example.com', 'E2E', 'cus_fixture', now),
    db.prepare('INSERT INTO sessions(token_hash,account_id,kind,name,csrf,expires_at) VALUES(?,?,?,?,?,?)').bind(createHash('sha256').update(token).digest('hex'), 'fixture-account', 'device', 'Terminal E2E', '', now + 3600),
    db.prepare('INSERT INTO documents(account_id,updated_at) VALUES(?,?)').bind('fixture-account', now),
  ]);
  console.log(JSON.stringify({ ready: true, origin, token, pid: process.pid }));
} catch (error) {
  await mf.dispose();
  throw error;
}
