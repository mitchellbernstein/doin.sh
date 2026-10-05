import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHmac, createHash } from 'node:crypto';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { build } from 'esbuild';

const root = new URL('../', import.meta.url);
const temp = await mkdtemp(join(tmpdir(), 'doin-sync-e2e-'));
const checks = [];
const billingFailureCoverage = [
  'wrong target interval and unauthenticated switch',
  'amount changes after the preview but before confirmation',
  'payment pending with existing entitlement and pending target period',
  'lost response after Stripe accepts an update and exact idempotent retry',
  'legacy monthly plan reports its actual Stripe price amount',
  'completed switch confirmation replays applied success without a second mutation',
  'expired or period-rolled ambiguous switch cannot issue a new Stripe mutation',
  'untrusted customer portal URL',
  'period switch while cancellation is pending',
  'expired quote and no-active-subscription account',
  'legacy monthly subscription reports the current Stripe price amount',
  'same-target preview reuses the live quote without another provider preview or database row',
  'completed quote confirmation replays success without duplicate Stripe mutation',
  'billing refresh reconciles settled pending quote after browser reload',
  'expired or period-rolled ambiguous update cannot be replayed as a new Stripe mutation',
  'unrelated provider pending update is not attributed to the quote',
  'per-account billing preview limit applies before provider invoice preview',
];
const pass = (name) => { checks.push(name); console.log(`PASS ${name}`); };
let entitlementPrice='price_sync';
let status = 'incomplete_expired', wrongPrice = false, providerDown = false, complete = false;
let clockOffset = 0;
const customers = new Map();
const mailbox = new Map();
let mailDown = false, cancelAtPeriodEnd = false;
const cancellations = [];
const deletedCustomers = new Set();
const checkouts = new Map();
const subscriptionsById = new Map(), stripeOperations = new Map(), portalSessions = [];
let pendingInterval = null, paymentRequired = false, previewDue = 1250, failAfterSwitch = false, portalUrl = null, previewCalls=0;
let checkoutBody,expireDown=false,failAfterExpire=false;
const outbound = async (request) => {
  const url = new URL(request.url);
  if (providerDown) return new Response('down', { status: 503 });
  if (url.hostname === 'mail.fixture') {
    if (mailDown) return new Response('unavailable', {status:503});
    const message = await request.json();
    assert.equal(message.from, 'signin@doin.sh');
    assert.equal(message.subject, 'Confirm your doin.sh sign-in');
    mailbox.set(message.to, message);
    return Response.json({messageId:'fixture-message'});
  }
  if(url.pathname==='/v1/billing_portal/sessions'){
    const fields=new URLSearchParams(await request.text());
    portalSessions.push(Object.fromEntries(fields));
    return Response.json({id:`bps_${portalSessions.length}`,customer:fields.get('customer'),return_url:fields.get('return_url'),url:portalUrl??`https://billing.stripe.com/p/session/test_${portalSessions.length}`});
  }
  if (url.pathname.startsWith('/v1/subscriptions/') && request.method === 'POST') {
    const fields = new URLSearchParams(await request.text());
    const id=url.pathname.split('/').pop();
    if(fields.has('cancel_at_period_end')){
      assert.ok(['true','false'].includes(fields.get('cancel_at_period_end')));
      cancellations.push(url.pathname);cancelAtPeriodEnd=fields.get('cancel_at_period_end')==='true';
      const existing=subscriptionsById.get(id);if(existing)existing.cancel_at_period_end=cancelAtPeriodEnd;
      return Response.json(existing??{id,cancel_at_period_end:cancelAtPeriodEnd});
    }
    assert.equal(fields.get('payment_behavior'),'pending_if_incomplete');
    assert.equal(fields.get('proration_behavior'),'always_invoice');
    const old=subscriptionsById.get(id);assert.ok(old);
    const key=request.headers.get('idempotency-key');
    if(!stripeOperations.has(key)){
      stripeOperations.set(key,Object.fromEntries(fields));
      if(paymentRequired)pendingInterval=fields.get('items[0][price]')==='price_year'?'year':'month';
      else {const id=fields.get('items[0][price]');old.items.data[0].price={id,unit_amount:id==='price_year'?4999:499,currency:'usd'};old.items.data[0].quantity=Number(fields.get('items[0][quantity]'));pendingInterval=null;}
    }
    old.pending_update=pendingInterval?{subscription_items:[{price:pendingInterval==='year'?'price_year':'price_month'}]}:null;
    if(failAfterSwitch){failAfterSwitch=false;return new Response('lost response after Stripe accepted update',{status:503});}
    return Response.json(structuredClone(old));
  }
  if (url.pathname.startsWith('/v1/subscriptions/') && request.method === 'DELETE') {
    deletedCustomers.add(url.pathname.split('/').pop().replace('sub_',''));
    return Response.json({status:'canceled'});
  }
  if (url.pathname.startsWith('/v1/invoices/')) {
    if(url.pathname==='/v1/invoices/create_preview'){
      previewCalls++;
      const fields=new URLSearchParams(await request.text());
      assert.ok(fields.get('subscription_details[proration_date]'));
      assert.equal(fields.get('subscription_details[proration_behavior]'),'always_invoice');
      return Response.json({currency:'usd',amount_due:previewDue});
    }
    const customer=url.pathname.split('/').pop().replace('in_','');
    return Response.json({customer,status:'open',hosted_invoice_url:`https://invoice.stripe.com/i/in_${customer}`});
  }
  if (url.pathname === '/v1/customers' && request.method === 'POST') {
    const key = request.headers.get('idempotency-key');
    if (!customers.has(key)) customers.set(key, `cus_${customers.size + 1}`);
    return Response.json({ id: customers.get(key) });
  }
  if (url.pathname.startsWith('/v1/prices/')) { const id=url.pathname.split('/').pop(); return Response.json({id,active:true,currency:'usd',unit_amount:id==='price_year'?4999:id==='price_legacy'?299:499,recurring:{interval:id==='price_year'?'year':'month',interval_count:1}}); }
  if (url.pathname === '/v1/checkout/sessions') {
    if(request.method==='GET') return Response.json({data:[...checkouts.values()].filter(c=>c.customer===url.searchParams.get('customer') && c.status==='open'),has_more:false});
    checkoutBody = new URLSearchParams(await request.text());
    const key = request.headers.get('idempotency-key');
    if (!checkouts.has(key)) checkouts.set(key, { id:`cs_fixture${checkouts.size+1}`,price_id:checkoutBody.get('line_items[0][price]'),customer:checkoutBody.get('customer'),status:'open',url: `https://checkout.stripe.com/c/pay/test${checkouts.size + 1}`, expires_at: Number(checkoutBody.get('expires_at')) });
    return Response.json(checkouts.get(key));
  }
  if (url.pathname.startsWith('/v1/checkout/sessions/')) {
    const id=url.pathname.split('/')[4],entry=[...checkouts.values()].find(c=>c.id===id);
    assert.ok(entry);
    if(url.pathname.endsWith('/expire')) {if(expireDown)return new Response('down',{status:503});entry.status='expired';if(failAfterExpire){providerDown=true;failAfterExpire=false;}}
    return Response.json(entry);
  }
  if (url.pathname === '/v1/subscriptions') {
    const customer=url.searchParams.get('customer');
    const existing=subscriptionsById.get(`sub_${customer}`);
    const sub=existing??{id:`sub_${customer}`,status:deletedCustomers.has(customer)?'canceled':status,latest_invoice:`in_${customer}`,cancel_at_period_end:cancelAtPeriodEnd,customer,items:{data:[{id:`si_${customer}`,price:{id:wrongPrice?'price_other':entitlementPrice},quantity:1,current_period_end:Math.floor((Date.now()+clockOffset)/1000)+3600}]},pending_update:null};
    sub.status=deletedCustomers.has(customer)?'canceled':status;
    subscriptionsById.set(sub.id,sub);
    return Response.json({ data: [structuredClone(sub)], has_more: false });
  }
  if(url.pathname.startsWith('/v1/subscriptions/sub_')&&request.method==='GET'){
    const id=url.pathname.split('/').pop(),customer=id.replace('sub_','');
    const existing=subscriptionsById.get(id);
    if(existing)return Response.json(structuredClone(existing));
    const sub={id,status:deletedCustomers.has(customer)?'canceled':status,latest_invoice:`in_${customer}`,cancel_at_period_end:cancelAtPeriodEnd,customer,items:{data:[{id:`si_${customer}`,price:{id:wrongPrice?'price_other':entitlementPrice},quantity:1,current_period_end:Math.floor((Date.now()+clockOffset)/1000)+3600}]},pending_update:null};
    subscriptionsById.set(id,sub);return Response.json(structuredClone(sub));
  }
  throw new Error(`unexpected outbound ${request.method} ${url}`);
};
let source = await readFile(process.env.WORKER_SOURCE || new URL('worker.ts', root), 'utf8');
source = source.replace('Date.now()', '(Date.now() + (globalThis.__e2eClock || 0))').replace('const url = new URL(request.url), path = url.pathname;', "const url = new URL(request.url), path = url.pathname; if(path === '/__e2e_clock'){globalThis.__e2eClock = Number(url.searchParams.get('offset')); return json({ok:true});}");
source = source.replace('const url = new URL(request.url), path = url.pathname;', "const url = new URL(request.url), path = url.pathname; if(path === '/__e2e_plan_config'){globalThis.__planConfig=await request.json(); return json({ok:true});} if(globalThis.__planConfig)Object.assign(env,globalThis.__planConfig);");
await build({ stdin: { contents: source, loader: 'ts', resolveDir: root.pathname }, outfile: join(temp, 'worker.mjs'), bundle: true, external:['cloudflare:workers'], format: 'esm', platform: 'browser' });
const mf = new Miniflare(convertV4MiniflareOptions({workers:[
  {name:'doin-sync',modules:true,script:await readFile(join(temp,'worker.mjs'),'utf8'),compatibilityDate:'2026-10-01',d1Databases:['DB'],kvNamespaces:['OAUTH_KV'],bindings:{ORIGIN:'https://sync.doin.sh',EMAIL_ENABLED:'true',EMAIL_FROM:'signin@doin.sh',STRIPE_SECRET_KEY:'sk_test_fixture',STRIPE_WEBHOOK_SECRET:'whsec_fixture',STRIPE_PRICE_ID:'price_sync',STRIPE_MONTHLY_PRICE_ID:'price_month',STRIPE_YEARLY_PRICE_ID:'price_year'},serviceBindings:{EMAIL:{name:'mail',entrypoint:'Mailer'}},outboundService:outbound},
  {name:'mail',modules:true,compatibilityDate:'2026-10-01',script:"import {WorkerEntrypoint} from 'cloudflare:workers'; export class Mailer extends WorkerEntrypoint {async send(message){const result=await fetch('https://mail.fixture/message',{method:'POST',body:JSON.stringify(message)});if(!result.ok)throw new Error('mail unavailable');return result.json();}} export default {fetch(){return new Response('not found',{status:404});}}",outboundService:outbound}
]}));
const base = 'https://sync.doin.sh';
const request = (path, options = {}) => mf.dispatchFetch(base + path, { redirect: 'manual', ...options });
const clock = async (offset) => { clockOffset = offset; return request(`/__e2e_clock?offset=${offset}`); };
const json = async (r, code = 200) => { assert.equal(r.status, code, await r.clone().text()); return r.json(); };
const signed = (event, offset = 0, secret = 'whsec_fixture') => {
  const raw = JSON.stringify(event), t = Math.floor(Date.now()/1000) + offset;
  const sig = createHmac('sha256', secret).update(`${t}.${raw}`).digest('hex');
  return { method: 'POST', body: raw, headers: { 'stripe-signature': `t=${t},v1=${sig}`, 'content-type': 'application/json' } };
};
const proof = () => 'f'.repeat(48) + Math.random().toString(16).slice(2).padEnd(16,'0');
async function start(email,name='E2E computer') {
  const verifier=proof(), challenge=createHash('sha256').update(verifier).digest('base64url');
  const result=await json(await request('/v1/auth/start',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({email,name,code_challenge:challenge})}));
  const link=new URL(mailbox.get(email).text.match(/https:\/\/[^\s]+/)[0]);
  return {...result,verifier,token:link.searchParams.get('token')};
}
const poll = (flow,verifier=flow.verifier) => request('/v1/auth/poll',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({request_id:flow.request_id,code_verifier:verifier})});
async function approve(flow,code=flow.confirmation_code,origin=base) {
  return request('/auth/verify',{method:'POST',headers:{origin,'content-type':'application/json'},body:JSON.stringify({token:flow.token,confirmation_code:code})});
}
async function login(email,name='E2E computer') {
  const flow=await start(email,name);
  assert.equal((await poll(flow)).status,202);
  assert.equal((await request(`/auth/verify?token=${flow.token}`)).status,200);
  assert.equal((await poll(flow)).status,202,'link scanner GET must not approve');
  assert.equal((await approve(flow)).status,200);
  const claims=await Promise.all([poll(flow),poll(flow)]);
  const one=await json(claims[0]),two=await json(claims[1]);
  assert.equal(one.token,two.token,'lost response retry must return the same session');
  return {...one,flow};
}
const bearer = (token) => ({ authorization: `Bearer ${token}` });
try {
  const planDefaults={STRIPE_SECRET_KEY:'sk_test_fixture',STRIPE_PRICE_ID:'price_sync',STRIPE_MONTHLY_PRICE_ID:'price_month',STRIPE_YEARLY_PRICE_ID:'price_year',EMAIL_ENABLED:'true'};
  for(const [key,price,email,mode,ready] of [
    ['sk_test_fixture','price_sync','true','test',true],
    ['rk_live_fixture','price_sync','true','live',true],
    ['pk_live_fixture','price_sync','true','unavailable',false],
    ['REPLACE_KEY','price_sync','false','unavailable',false],
    ['rk_test_fixture','REPLACE_PRICE','true','unavailable',false],
  ]) {
    await request('/__e2e_plan_config',{method:'POST',body:JSON.stringify({...planDefaults,STRIPE_SECRET_KEY:key,STRIPE_PRICE_ID:price,STRIPE_MONTHLY_PRICE_ID:price,STRIPE_YEARLY_PRICE_ID:price,EMAIL_ENABLED:email})});
    const plan=await json(await request('/v1/plan'));
    assert.deepEqual(plan,{name:'doinMORE',amount:499,currency:'usd',interval:'month',options:[{interval:'month',amount:499},{interval:'year',amount:4999}],billing_mode:mode,email_ready:email==='true',billing_ready:ready});
    assert.ok(!JSON.stringify(plan).includes(key),'public plan must never return server key');
  }
  await request('/__e2e_plan_config',{method:'POST',body:JSON.stringify(planDefaults)});
  providerDown=true;
  assert.equal((await request('/v1/plan')).status,200,'config discovery makes no provider request');
  providerDown=false;
  pass('logged-out plan discovery distinguishes sandbox, live and unavailable without secrets or provider mutations');
  const db = await mf.getD1Database('DB');
  for (const path of ['/account','/account.js','/account.css']) {
    const response=await request(path);
    assert.equal(response.status,200);
    assert.equal(response.headers.get('cache-control'),'no-store');
    assert.equal(response.headers.get('referrer-policy'),'no-referrer');
    assert.equal(response.headers.get('x-content-type-options'),'nosniff');
    assert.ok(response.headers.get('content-security-policy').includes("script-src 'self'"));
  }
  const accountPage=await (await request('/account')).text();
  assert.ok(accountPage.includes('id="login-form"'));
  assert.ok(accountPage.includes('id="billing"'));
  assert.ok(!accountPage.includes('<script>'));
  pass('web account assets are public, no-store, same-origin and script-isolated');
  await db.exec((await readFile(new URL('migrations/0001.sql', root), 'utf8')).replaceAll('\n', ' '));
  await db.exec((await readFile(new URL('migrations/0002.sql',root),'utf8')).replaceAll('\n',' '));
  await db.exec((await readFile(new URL('migrations/0003.sql',root),'utf8')).replaceAll('\n',' '));
  await db.exec((await readFile(new URL('migrations/0004.sql',root),'utf8')).replaceAll('\n',' '));
  await db.exec((await readFile(new URL('migrations/0005.sql',root),'utf8')).replaceAll('\n',' '));
  await db.exec((await readFile(new URL('migrations/0006.sql',root),'utf8')).replaceAll('\n',' '));
  await db.exec((await readFile(new URL('migrations/0007.sql',root),'utf8')).replaceAll('\n',' '));
  await db.exec((await readFile(new URL('migrations/0008.sql',root),'utf8')).replaceAll('\n',' '));
  await db.exec((await readFile(new URL('migrations/0009.sql',root),'utf8')).replaceAll('\n',' '));
  await db.exec((await readFile(new URL('migrations/0010.sql',root),'utf8')).replaceAll('\n',' '));
  const rejected=await start('reject@example.com');
  assert.equal((await poll(rejected,'a'.repeat(64))).status,401);
  assert.equal((await approve(rejected,rejected.confirmation_code,'https://evil.test')).status,403);
  assert.equal((await approve(rejected,rejected.confirmation_code,'null')).status,403,'opaque form origins must stay rejected');
  assert.equal((await approve(rejected,rejected.confirmation_code === '000000' ? '111111' : '000000')).status,400);
  await db.prepare('UPDATE auth_requests SET expires_at=0 WHERE id=?').bind(rejected.request_id).run();
  assert.equal((await approve(rejected)).status,401);
  assert.equal((await poll(rejected)).status,401);
  const guessing=await start('guess@example.com');
  for(let i=0;i<5;i++) assert.equal((await approve(guessing,guessing.confirmation_code==='000000'?'111111':'000000')).status,400);
  assert.equal((await approve(guessing)).status,429);
  const transactional=await start('transaction@example.com','Fail once');
  await approve(transactional);
  await db.exec("CREATE TRIGGER reject_login BEFORE INSERT ON sessions WHEN NEW.name='Fail once' BEGIN SELECT RAISE(ABORT,'fixture failure'); END");
  assert.equal((await poll(transactional)).status,503);
  assert.equal(await db.prepare('SELECT id FROM accounts WHERE email=?').bind('transaction@example.com').first(),null);
  assert.equal((await db.prepare('SELECT claimed_hash FROM auth_requests WHERE id=?').bind(transactional.request_id).first()).claimed_hash,null);
  await db.exec('DROP TRIGGER reject_login');
  await json(await poll(transactional));
  mailDown=true;
  assert.equal((await request('/v1/auth/start',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({email:'outage@example.com',name:'Laptop',code_challenge:createHash('sha256').update(proof()).digest('base64url')})})).status,503);
  mailDown=false;
  assert.equal((await request('/v1/auth/start',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({email:'bad@example.com\r\nBcc:evil@example.com',name:'Laptop',code_challenge:'a'.repeat(43)})})).status,400);
  const a=await login('alice@example.com','Laptop'), b=await login('alice@example.com','Desktop'), other=await login('bob@example.com');
  const alice=a.token,bob=other.token;
  assert.notEqual(a.token,b.token);
  assert.equal(a.account.id,b.account.id);
  assert.notEqual(a.account.id,other.account.id);
  const devices=await json(await request('/v1/devices',{headers:bearer(alice)}));
  assert.equal(devices.devices.length,2);
  const unused=await start('alice@example.com','Unused');
  assert.equal((await poll(unused)).status,202);
  const abusive=await request('/v1/auth/start',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({email:'alice@example.com',name:'Extra',code_challenge:createHash('sha256').update(proof()).digest('base64url')})});
  assert.equal(abusive.status,429);
  pass('email proof, scanner safety, bounded confirmation attempts, rate limits and transactional retry-safe claims');

  assert.equal((await request('/v1/document', { headers: bearer(a.token) })).status, 402);
  const account = await json(await request('/v1/account', { headers: bearer(alice) }));
  const hourBoundary = Math.ceil(Date.now() / 3600000) * 3600000;
  const offset = hourBoundary - Date.now() - 60000;
  await clock(offset);
  const checkout = await json(await request('/v1/checkout', { method: 'POST', headers: { ...bearer(alice) } }));
  assert.equal(checkout.url, 'https://checkout.stripe.com/c/pay/test1');
  assert.equal(checkoutBody.get('line_items[0][price]'), 'price_month');
  assert.equal(checkoutBody.get('mode'), 'subscription');
  await clock(offset + 120000);
  const repeated = await Promise.all(Array.from({length: 3}, () => request('/v1/checkout', { method: 'POST', headers: { ...bearer(alice) } })));
  for (const response of repeated) {
    if(response.status===409) assert.equal((await response.json()).error,'billing_busy');
    else assert.equal((await json(response)).url, checkout.url, 'an open checkout must survive the hour boundary');
  }
  assert.equal(checkouts.size, 1, 'one account must have one payable checkout');
  const oldCheckout = [...checkouts.values()][0];
  assert.ok(oldCheckout.expires_at > Math.floor((Date.now() + clockOffset) / 1000));
  await clock(offset + 3601000);
  const replacement = await json(await request('/v1/checkout', { method: 'POST', headers: { ...bearer(alice) } }));
  assert.notEqual(replacement.url, checkout.url);
  assert.equal((await request('/v1/checkout',{method:'POST',headers:{...bearer(alice),'content-type':'application/json'},body:JSON.stringify({interval:'week'})})).status,400);
  await db.prepare('UPDATE checkouts SET url=NULL,session_id=NULL WHERE account_id=?').bind(a.account.id).run();
  expireDown=true;
  assert.equal((await request('/v1/checkout',{method:'POST',headers:{...bearer(alice),'content-type':'application/json'},body:JSON.stringify({interval:'year'})})).status,503);
  assert.equal((await db.prepare('SELECT price_id FROM checkouts WHERE account_id=?').bind(a.account.id).first()).price_id,'price_month','failed expiry retains original intent');
  expireDown=false;
  const yearly=await json(await request('/v1/checkout',{method:'POST',headers:{...bearer(alice),'content-type':'application/json'},body:JSON.stringify({interval:'year'})}));
  assert.notEqual(yearly.url,replacement.url);
  assert.equal(checkoutBody.get('line_items[0][price]'),'price_year');
  assert.equal([...checkouts.values()].filter(c=>c.customer==='cus_1'&&c.status==='open'&&c.expires_at>Math.floor((Date.now()+clockOffset)/1000)).length,1,'interval switch expires old payable session');
  assert.equal((await json(await request('/v1/checkout',{method:'POST',headers:{...bearer(alice),'content-type':'application/json'},body:JSON.stringify({interval:'year'})}))).url,yearly.url);
  failAfterExpire=true;
  assert.equal((await request('/v1/checkout',{method:'POST',headers:bearer(alice)})).status,503);
  providerDown=false;
  const recoveredYear=await json(await request('/v1/checkout',{method:'POST',headers:{...bearer(alice),'content-type':'application/json'},body:JSON.stringify({interval:'year'})}));
  assert.notEqual(recoveredYear.url,yearly.url,'retry original interval cannot reuse remotely expired cached URL');
  const payable = [...checkouts.values()].filter(c => c.status==='open' && c.expires_at > Math.floor((Date.now() + clockOffset) / 1000));
  assert.equal(payable.length, 1, 'replacement must not leave two payable sessions');
  status = 'past_due';
  assert.equal((await request('/v1/checkout', { method: 'POST', headers: { ...bearer(alice) } })).status, 409);
  const recovery=await json(await request('/v1/billing/recover',{method:'POST',headers:bearer(alice)}));
  assert.equal(recovery.url,'https://invoice.stripe.com/i/in_cus_1');
  await clock(0);
  status = 'active';
  pass('free entitlement, reusable checkout across hour boundary, expiry replacement and invoice recovery');

  const put = (token, revision, content) => request('/v1/document', { method: 'PUT', headers: { ...bearer(token), 'content-type': 'application/json' }, body: JSON.stringify({ revision, content }) });
  for (const price of ['price_sync','price_month','price_year']) {entitlementPrice=price;assert.equal((await request('/v1/document',{headers:bearer(alice)})).status,200,'legacy and new intervals retain access');assert.equal((await json(await request('/v1/billing',{headers:bearer(alice)}))).active,true);}
  entitlementPrice='price_sync';
  const first = await json(await put(a.token, 0, '# Launch\n\n- [ ] ship\n'));
  assert.equal(first.revision, 1);
  const race = await Promise.all([put(a.token, 1, '# Laptop edit\n'), put(b.token, 1, '# Desktop edit\n')]);
  assert.deepEqual(race.map(r=>r.status).sort(), [200, 409]);
  const cloud = await json(await request('/v1/document', { headers: bearer(b.token) }));
  assert.equal(cloud.revision, 2);
  assert.ok(['# Laptop edit\n', '# Desktop edit\n'].includes(cloud.content));
  const conflict = await race.find(r => r.status === 409).json();
  assert.equal(conflict.content, cloud.content);
  const retry = await json(await put(a.token, 1, cloud.content));
  assert.equal(retry.revision, 2);
  assert.equal((await request('/v1/document', { headers: bearer(other.token) })).status, 402);
  const bobAccount = await json(await request('/v1/account', { headers: bearer(bob) }));
  status = 'incomplete_expired';
  await json(await request('/v1/checkout', { method: 'POST', headers: { ...bearer(bob) } }));
  status = 'active';
  assert.equal((await json(await request('/v1/document', { headers: bearer(other.token) }))).content, '');
  await json(await put(other.token, 0, '# Bob private\n'));
  assert.equal((await json(await request('/v1/document', { headers: bearer(b.token) }))).content, cloud.content);
  assert.equal((await put(a.token, 2, 'x'.repeat(1048577))).status, 413);
  assert.equal((await request('/v1/document', { method: 'PUT', headers: { ...bearer(a.token), 'content-type': 'application/json' }, body: 'null' })).status, 400);
  pass('two-device CAS race, lossless conflict, retry idempotence, account isolation and size limit');

  const aliceSub={id:'sub_cus_1',status:'active',latest_invoice:'in_cus_1',cancel_at_period_end:false,customer:'cus_1',pending_update:null,items:{data:[{id:'si_cus_1',price:{id:'price_month'},quantity:1,current_period_end:Math.floor(Date.now()/1000)+86400}]}};
  subscriptionsById.set(aliceSub.id,aliceSub);entitlementPrice='price_month';status='active';cancelAtPeriodEnd=false;
  const monthly=await json(await request('/v1/billing',{headers:bearer(alice)}));
  assert.deepEqual({interval:monthly.interval,amount:monthly.amount,currency:monthly.currency,pending_update:monthly.pending_update,pending_interval:monthly.pending_interval},{interval:'month',amount:499,currency:'usd',pending_update:false,pending_interval:null});
  const originalMonthlyPrice=aliceSub.items.data[0].price.id;
  await request('/__e2e_plan_config',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({STRIPE_PRICE_ID:'price_legacy',STRIPE_MONTHLY_PRICE_ID:'',STRIPE_YEARLY_PRICE_ID:'price_year'})});
  aliceSub.items.data[0].price={id:'price_legacy',unit_amount:299,currency:'usd'};
  const legacyBilling=await json(await request('/v1/billing',{headers:bearer(alice)}));
  assert.equal(legacyBilling.interval,'month');assert.equal(legacyBilling.amount,299,'legacy monthly subscriber sees actual current recurring price, not new monthly price');
  await request('/__e2e_plan_config',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({STRIPE_PRICE_ID:'price_sync',STRIPE_MONTHLY_PRICE_ID:'price_month',STRIPE_YEARLY_PRICE_ID:'price_year'})});
  aliceSub.items.data[0].price={id:originalMonthlyPrice,unit_amount:499,currency:'usd'};
  assert.equal((await request('/v1/billing/change',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({interval:'year'})})).status,401);
  const bobCustomer=(await db.prepare('SELECT customer_id FROM accounts WHERE email=?').bind('bob@example.com').first()).customer_id;
  await db.prepare('UPDATE accounts SET customer_id=NULL WHERE email=?').bind('bob@example.com').run();
  const unpaidBilling=await json(await request('/v1/billing',{headers:bearer(bob)}));assert.equal(unpaidBilling.active,false);assert.equal(unpaidBilling.interval,null);assert.equal(unpaidBilling.amount,null);
  await db.prepare('UPDATE accounts SET customer_id=? WHERE email=?').bind(bobCustomer,'bob@example.com').run();
  const portal=await json(await request('/v1/billing/portal',{method:'POST',headers:bearer(alice)}));
  assert.equal(portal.url,'https://billing.stripe.com/p/session/test_1');
  assert.equal(portalSessions[0].customer,'cus_1');assert.equal(new URL(portalSessions[0].return_url).origin,'https://sync.doin.sh');
  portalUrl='https://evil.example/steal';
  assert.equal((await request('/v1/billing/portal',{method:'POST',headers:bearer(alice)})).status,503);
  portalUrl=null;
  previewDue=1250;
  const annualPreview=await json(await request('/v1/billing/change',{method:'POST',headers:{...bearer(alice),'content-type':'application/json'},body:JSON.stringify({interval:'year'})}));
  assert.equal(annualPreview.confirmation_required,true);assert.equal(annualPreview.amount_due,1250);assert.ok(annualPreview.quote_id);assert.ok(annualPreview.expires_at>Math.floor(Date.now()/1000));
  const quoteRowsBeforeReuse=(await db.prepare('SELECT count(*) AS n FROM billing_change_quotes WHERE account_id=?').bind(a.account.id).first()).n,previewCallsBeforeReuse=previewCalls;
  const reusedAnnualPreview=await json(await request('/v1/billing/change',{method:'POST',headers:{...bearer(alice),'content-type':'application/json'},body:JSON.stringify({interval:'year'})}));
  assert.equal(reusedAnnualPreview.quote_id,annualPreview.quote_id,'repeated target preview reuses the live matching quote');
  assert.equal(previewCalls,previewCallsBeforeReuse,'reused preview does not call Stripe again');
  assert.equal((await db.prepare('SELECT count(*) AS n FROM billing_change_quotes WHERE account_id=?').bind(a.account.id).first()).n,quoteRowsBeforeReuse,'reused preview does not grow stored quote rows');
  const bobCustomerForChange=(await db.prepare('SELECT customer_id FROM accounts WHERE email=?').bind('bob@example.com').first()).customer_id;
  await db.prepare('UPDATE accounts SET customer_id=NULL WHERE email=?').bind('bob@example.com').run();
  assert.equal((await request('/v1/billing/change',{method:'POST',headers:{...bearer(bob),'content-type':'application/json'},body:JSON.stringify({interval:'year'})})).status,409);
  await db.prepare('UPDATE accounts SET customer_id=? WHERE email=?').bind(bobCustomerForChange,'bob@example.com').run();
  assert.equal((await request('/v1/billing/change',{method:'POST',headers:{...bearer(alice),'content-type':'application/json'},body:JSON.stringify({interval:'week'})})).status,400);
  previewDue=1750;
  const refreshedQuote=await json(await request('/v1/billing/change',{method:'POST',headers:{...bearer(alice),'content-type':'application/json'},body:JSON.stringify({interval:'year',quote_id:annualPreview.quote_id,confirm_amount:annualPreview.amount_due})}));
  assert.equal(refreshedQuote.confirmation_required,true);assert.equal(refreshedQuote.amount_due,1750,'changed proration must be requoted before mutation');
  assert.equal((await json(await request('/v1/billing',{headers:bearer(alice)}))).interval,'month','stale quote cannot change the subscription');
  paymentRequired=true;
  const pendingResult=await json(await request('/v1/billing/change',{method:'POST',headers:{...bearer(alice),'content-type':'application/json'},body:JSON.stringify({interval:'year',quote_id:refreshedQuote.quote_id,confirm_amount:1750})}));
  assert.deepEqual({changed:pendingResult.changed,payment_pending:pendingResult.payment_pending,interval:pendingResult.interval},{changed:false,payment_pending:true,interval:'month'});
  const pendingBilling=await json(await request('/v1/billing',{headers:bearer(alice)}));
  assert.equal(pendingBilling.interval,'month');assert.equal(pendingBilling.pending_update,true);assert.equal(pendingBilling.pending_interval,'year');
  assert.equal((await request('/v1/document',{headers:bearer(alice)})).status,200,'pending payment cannot switch the active entitlement');
  const pendingRecovery=await json(await request('/v1/billing/recover',{method:'POST',headers:bearer(alice)}));assert.equal(pendingRecovery.url,'https://invoice.stripe.com/i/in_cus_1','active pending update still exposes its open recovery invoice');
  const actualPendingTarget=aliceSub.pending_update.subscription_items[0].price;
  aliceSub.pending_update.subscription_items[0].price='price_month';
  assert.equal((await request('/v1/billing/change',{method:'POST',headers:{...bearer(alice),'content-type':'application/json'},body:JSON.stringify({interval:'year',quote_id:refreshedQuote.quote_id,confirm_amount:1750})})).status,409,'unrelated pending provider update cannot be attributed to this quote');
  aliceSub.pending_update.subscription_items[0].price=actualPendingTarget;
  assert.equal((await request('/v1/billing/change',{method:'POST',headers:{...bearer(alice),'content-type':'application/json'},body:JSON.stringify({interval:'month'})})).status,409,'pending provider update must be resolved before another switch');
  paymentRequired=false;aliceSub.items.data[0].price={id:'price_year',unit_amount:4999,currency:'usd'};aliceSub.pending_update=null;entitlementPrice='price_year';
  const appliedAnnual=await json(await request('/v1/billing/change',{method:'POST',headers:{...bearer(alice),'content-type':'application/json'},body:JSON.stringify({interval:'year',quote_id:refreshedQuote.quote_id,confirm_amount:1750})}));
  assert.deepEqual({changed:appliedAnnual.changed,payment_pending:appliedAnnual.payment_pending,interval:appliedAnnual.interval},{changed:true,payment_pending:false,interval:'year'});
  const operationsAfterAnnual=stripeOperations.size;
  const repeatedAnnual=await json(await request('/v1/billing/change',{method:'POST',headers:{...bearer(alice),'content-type':'application/json'},body:JSON.stringify({interval:'year',quote_id:refreshedQuote.quote_id,confirm_amount:1750})}));
  assert.deepEqual({changed:repeatedAnnual.changed,payment_pending:repeatedAnnual.payment_pending,interval:repeatedAnnual.interval},{changed:true,payment_pending:false,interval:'year'},'completed quote retry replays the applied result');
  assert.equal(stripeOperations.size,operationsAfterAnnual,'completed confirmation retry must not mutate Stripe again');
  const annualBilling=await json(await request('/v1/billing',{headers:bearer(alice)}));
  assert.equal(annualBilling.interval,'year');assert.equal(annualBilling.amount,4999);assert.equal(annualBilling.pending_interval,null);
  previewDue=0;
  const monthlyPreview=await json(await request('/v1/billing/change',{method:'POST',headers:{...bearer(alice),'content-type':'application/json'},body:JSON.stringify({interval:'month'})}));
  assert.equal(monthlyPreview.amount_due,0,'zero amount must remain a valid explicit confirmation');
  failAfterSwitch=true;
  assert.equal((await request('/v1/billing/change',{method:'POST',headers:{...bearer(alice),'content-type':'application/json'},body:JSON.stringify({interval:'month',quote_id:monthlyPreview.quote_id,confirm_amount:0})})).status,503,'network loss after accepted Stripe mutation is ambiguous');
  const retriedSwitch=await json(await request('/v1/billing/change',{method:'POST',headers:{...bearer(alice),'content-type':'application/json'},body:JSON.stringify({interval:'month',quote_id:monthlyPreview.quote_id,confirm_amount:0})}));
  assert.equal(retriedSwitch.interval,'month');assert.equal(retriedSwitch.payment_pending,false);assert.equal(stripeOperations.size,2,'ambiguous retry must reuse the persisted operation identity');
  const switchedBack=await json(await request('/v1/billing',{headers:bearer(alice)}));assert.equal(switchedBack.interval,'month');assert.equal(switchedBack.amount,499);
  assert.equal((await request('/v1/billing/change',{method:'POST',headers:{...bearer(alice),'content-type':'application/json'},body:JSON.stringify({interval:'month'})})).status,200,'same period is a no-op');
  const expiresQuote=await json(await request('/v1/billing/change',{method:'POST',headers:{...bearer(alice),'content-type':'application/json'},body:JSON.stringify({interval:'year'})}));
  await db.prepare("UPDATE billing_change_quotes SET expires_at=0,state='applying' WHERE quote_id=?").bind(expiresQuote.quote_id).run();
  const periodBeforeAmbiguousRetry=aliceSub.items.data[0].current_period_end;
  aliceSub.items.data[0].current_period_end=Math.floor((Date.now()+clockOffset)/1000)-1;
  const operationsBeforeAmbiguousRetry=stripeOperations.size;
  assert.equal((await request('/v1/billing/change',{method:'POST',headers:{...bearer(alice),'content-type':'application/json'},body:JSON.stringify({interval:'year',quote_id:expiresQuote.quote_id,confirm_amount:expiresQuote.amount_due})})).status,409,'expired uncertain quote cannot mutate after the subscription period rolls');
  assert.equal(stripeOperations.size,operationsBeforeAmbiguousRetry,'stale ambiguous quote cannot send a fresh Stripe update');
  aliceSub.items.data[0].current_period_end=periodBeforeAmbiguousRetry;
  assert.equal((await json(await request('/v1/billing',{headers:bearer(alice)}))).interval,'month');
  // A recovered invoice can settle without the browser retaining its quote ID.
  previewDue=750;
  const reloadQuote=await json(await request('/v1/billing/change',{method:'POST',headers:{...bearer(alice),'content-type':'application/json'},body:JSON.stringify({interval:'year'})}));
  paymentRequired=true;
  await json(await request('/v1/billing/change',{method:'POST',headers:{...bearer(alice),'content-type':'application/json'},body:JSON.stringify({interval:'year',quote_id:reloadQuote.quote_id,confirm_amount:reloadQuote.amount_due})}));
  paymentRequired=false;aliceSub.items.data[0].price.id='price_year';aliceSub.items.data[0].price.unit_amount=4999;aliceSub.pending_update=null;entitlementPrice='price_year';
  const afterRecoveredPayment=await json(await request('/v1/billing',{headers:bearer(alice)}));
  assert.equal(afterRecoveredPayment.interval,'year');assert.equal(afterRecoveredPayment.pending_update,false,'billing refresh reconciles invoice payment after browser reload');
  const newReversePreview=await json(await request('/v1/billing/change',{method:'POST',headers:{...bearer(alice),'content-type':'application/json'},body:JSON.stringify({interval:'month'})}));
  assert.equal(newReversePreview.confirmation_required,true,'reconciled completed quote does not block a later period switch without its original quote id');
  await db.prepare("UPDATE billing_change_quotes SET state='failed' WHERE quote_id=?").bind(newReversePreview.quote_id).run();
  const billingHour=Math.floor((Date.now()+clockOffset)/3600000),billingLimitKey=`billing:${a.account.id}:${billingHour}`;
  await db.prepare('INSERT INTO rate_limits(key,hits,expires_at) VALUES(?,?,?) ON CONFLICT(key) DO UPDATE SET hits=excluded.hits,expires_at=excluded.expires_at').bind(billingLimitKey,10,(billingHour+2)*3600).run();
  const previewsBeforeLimit=previewCalls;
  assert.equal((await request('/v1/billing/change',{method:'POST',headers:{...bearer(alice),'content-type':'application/json'},body:JSON.stringify({interval:'month'})})).status,429,'account-scoped limit blocks excess distinct billing previews');
  assert.equal(previewCalls,previewsBeforeLimit,'rate-limited request cannot invoke Stripe preview');
  aliceSub.items.data[0].price={id:'price_month',unit_amount:499,currency:'usd'};entitlementPrice='price_month';
  pass('explicit monthly/yearly switch quotes bind to proration, pending payment keeps current entitlement, retries are idempotent and portal URLs are validated');

  const cancellation=await json(await request('/v1/billing/cancel',{method:'POST',headers:bearer(alice)}));
  assert.equal(cancellation.cancel_at_period_end,true);
  assert.deepEqual(cancellations,['/v1/subscriptions/sub_cus_1']);
  const billing=await json(await request('/v1/billing',{headers:bearer(alice)}));
  assert.equal(billing.active,true);
  assert.equal(billing.cancel_at_period_end,true);
  assert.equal((await json(await request('/v1/billing/resume',{method:'POST',headers:bearer(alice)}))).cancel_at_period_end,false);
  assert.equal((await json(await request('/v1/billing',{headers:bearer(alice)}))).cancel_at_period_end,false);
  assert.equal((await json(await request('/v1/billing/cancel',{method:'POST',headers:bearer(alice)}))).cancel_at_period_end,true);
  assert.equal((await request('/v1/billing/change',{method:'POST',headers:{...bearer(alice),'content-type':'application/json'},body:JSON.stringify({interval:'year'})})).status,409,'require an explicit resume before changing periods');
  assert.equal((await request('/v1/document',{headers:bearer(alice)})).status,200);
  status = 'canceled';
  assert.equal((await request('/v1/document', { headers: bearer(a.token) })).status, 402);
  const exported = await request('/v1/export', { headers: bearer(alice) });
  assert.equal(exported.status, 200);
  assert.equal((await exported.json()).content, cloud.content);
  status = 'active'; wrongPrice = true;
  const aliceSubscription = subscriptionsById.get('sub_cus_1');
  aliceSubscription.items.data[0].price.id = 'price_other';
  assert.equal((await request('/v1/document', { headers: bearer(a.token) })).status, 402);
  wrongPrice = false; aliceSubscription.items.data[0].price.id = 'price_month'; providerDown = true;
  assert.equal((await put(a.token, 2, 'do not save')).status, 503);
  providerDown = false;
  assert.equal((await json(await request('/v1/document', { headers: bearer(a.token) }))).content, cloud.content);
  pass('cancellation, wrong product and Stripe outage fail closed; canceled account can export');

  const customer = (await db.prepare('SELECT customer_id FROM accounts WHERE email = ?').bind('alice@example.com').first()).customer_id;
  const event = { id: 'evt_1', type: 'customer.subscription.updated', data: { object: { customer } } };
  assert.equal((await request('/webhooks/stripe', signed(event, 0, 'wrong'))).status, 400);
  assert.equal((await request('/webhooks/stripe', signed(event, -1000))).status, 400);
  await json(await request('/webhooks/stripe', signed(event)));
  await json(await request('/webhooks/stripe', signed(event)));
  assert.equal((await db.prepare('SELECT count(*) AS n FROM webhook_events').first()).n, 1);
  const rotated = signed({ ...event, id: 'evt_rotation' });
  rotated.headers['stripe-signature'] += `,v1=${'0'.repeat(64)}`;
  await json(await request('/webhooks/stripe', rotated));
  status = 'canceled';
  await json(await request('/webhooks/stripe', signed({ ...event, id: 'evt_older', created: 1 })));
  assert.equal((await request('/v1/document', { headers: bearer(a.token) })).status, 402);
  pass('webhook signature/timestamp rejection, duplicate receipt and out-of-order cancellation');

  await json(await request('/v1/devices/revoke',{method:'POST',headers:{...bearer(alice),'content-type':'application/json'},body:JSON.stringify({id:createHash('sha256').update(other.token).digest('hex')})}));
  assert.equal((await request('/v1/account',{headers:bearer(other.token)})).status,200,'one account cannot revoke another account device');
  const revoke = await json(await request('/v1/devices/revoke', { method: 'POST', headers: { ...bearer(bob), 'content-type': 'application/json' }, body: JSON.stringify({ id: createHash('sha256').update(other.token).digest('hex') }) }));
  assert.equal(revoke.revoked, true);
  assert.equal((await request('/v1/account', { headers: bearer(other.token) })).status, 401);
  assert.equal((await poll(other.flow)).status,401,'login receipt must not restore a revoked token');
  const deletion=await login('bob@example.com','Delete test');
  status='active';
  assert.equal((await request('/v1/account',{method:'DELETE',headers:{...bearer(deletion.token),'content-type':'application/json'},body:JSON.stringify({confirmation:'yes'})})).status,400);
  providerDown=true;
  assert.equal((await request('/v1/account',{method:'DELETE',headers:{...bearer(deletion.token),'content-type':'application/json'},body:JSON.stringify({confirmation:'delete my account'})})).status,503);
  providerDown=false;
  assert.equal((await request('/v1/account',{headers:bearer(deletion.token)})).status,200);
  assert.equal((await request('/v1/checkout',{method:'POST',headers:bearer(deletion.token)})).status,409);
  await db.prepare('UPDATE checkouts SET url=NULL,session_id=NULL WHERE account_id=?').bind(deletion.account.id).run();
  await json(await request('/v1/account',{method:'DELETE',headers:{...bearer(deletion.token),'content-type':'application/json'},body:JSON.stringify({confirmation:'delete my account'})}));
  assert.equal([...checkouts.values()].filter(c=>c.customer==='cus_2' && c.status==='open').length,0);
  assert.equal((await request('/v1/account',{headers:bearer(deletion.token)})).status,401);
  assert.equal(await db.prepare('SELECT id FROM accounts WHERE email=?').bind('bob@example.com').first(),null);
  assert.equal((await json(await request('/v1/document',{headers:bearer(alice)}))).content,cloud.content);
  pass('cross-account revocation guard, revoked claim replay, deletion fencing and orphan-checkout recovery');
  await db.prepare('UPDATE sessions SET expires_at = 0 WHERE token_hash = ?').bind(createHash('sha256').update(a.token).digest('hex')).run();
  assert.equal((await request('/v1/account', { headers: bearer(a.token) })).status, 401);
  const beforeFailure = await db.prepare('SELECT content FROM documents WHERE account_id=?').bind(a.account.id).first();
  await db.exec('ALTER TABLE documents RENAME TO unavailable_documents');
  status = 'active';
  const failure = await request('/v1/document', { headers: bearer(b.token) });
  assert.equal(failure.status, 503);
  assert.deepEqual(await failure.json(), { error: 'service_unavailable' });
  assert.ok(beforeFailure.content);
  await db.exec('DROP TABLE webhook_events');
  assert.equal((await request('/webhooks/stripe', signed({ ...event, id: 'evt_database_failure' }))).status, 503);
  pass('expired sessions and database outage return bounded errors');
  complete = true;
} finally {
  await mf.dispose();
  await mkdir(new URL('artifacts/', root), { recursive: true });
  await writeFile(new URL(`artifacts/${process.env.TEST_ARTIFACT || 'e2e.json'}`, root), JSON.stringify({ command: 'cd cloud && node tests/e2e.mjs', date: new Date().toISOString(), node: process.version, complete, checks, billingFailureCoverage }, null, 2));
  await rm(temp, { recursive: true, force: true });
}
