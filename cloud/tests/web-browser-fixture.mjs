import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { build } from 'esbuild';
import { readFile, writeFile, rm } from 'node:fs/promises';
import { createHash, generateKeyPairSync } from 'node:crypto';

const port = Number(process.env.DOIN_FIXTURE_PORT || 8792);
if(!Number.isSafeInteger(port)||port<1024||port>65535)throw new Error('DOIN_FIXTURE_PORT must be an unused loopback port from 1024 through 65535');
const origin = `http://127.0.0.1:${port}`;
const token = 'a'.repeat(64);
const mailFile = process.env.DOIN_FIXTURE_MAIL_FILE || `/tmp/doin-web-account-mail-${process.pid}.json`;
let selectedPrice='price_month';
const fixtureCheckouts=new Map();
let active=process.env.DOIN_FIXTURE_UPGRADE!=='1',holdPayments=false,providerDown=false,invalidRedirect=false,previewDue=1250;
const customerPlans=new Map(),customers=new Map(),teamCustomers=new Map(),invoiceCustomers=new Map();
customerPlans.set('cus_fixture',{id:'sub_fixture',priceId:selectedPrice,quantity:1,status:active?'active':'canceled',cancelAtPeriodEnd:false,pending:null,latestInvoice:'in_fixture',periodEnd:Math.floor(Date.now()/1000)+86400});
invoiceCustomers.set('in_fixture','cus_fixture');
let lastCheckout=null;
const root = new URL('../', import.meta.url);
const {privateKey:licensePrivateKey,publicKey:licensePublicKey}=generateKeyPairSync('ed25519');
const licenseSigningKey=JSON.stringify(licensePrivateKey.export({format:'jwk'})),licensePublic=JSON.stringify(licensePublicKey.export({format:'jwk'}));
const wrapperSource = String.raw`
import worker from './worker';
export default {async fetch(request,env,ctx){
 const url=new URL(request.url);
 if(url.pathname.startsWith('/__fixture/')){
  if(url.pathname==='/__fixture/role'&&request.method==='POST'){
   let data;try{data=await request.json()}catch{return Response.json({error:'invalid_body'},{status:400})}
   if(Object.keys(data).length!==2||typeof data.team_id!=='string'||!/^[a-zA-Z0-9-]{1,80}$/.test(data.team_id)||!['owner','member'].includes(data.role))return Response.json({error:'invalid_role'},{status:400});
   const result=await env.DB.prepare('UPDATE team_members SET role=? WHERE team_id=? AND account_id=?').bind(data.role,data.team_id,'fixture-account').run();
   if(!result.meta?.changes)return Response.json({error:'team_member_not_found'},{status:404});
   return Response.json({changed:true});
  }
  if(!['GET','POST'].includes(request.method))return Response.json({error:'method_not_allowed'},{status:405});
  let body;try{body=request.method==='GET'?undefined:await request.text()}catch{return Response.json({error:'invalid_body'},{status:400})}
  if(body&&body.length>4096)return Response.json({error:'too_large'},{status:413});
  return fetch('https://fixture.control'+url.pathname+url.search,{method:request.method,headers:body?{'content-type':'application/json'}:{},body});
 }
 const response=await worker.fetch(request,env,ctx);
 console.log(JSON.stringify({request:url.pathname,method:request.method,status:response.status}));
 if(url.pathname==='/account.js'){
  let script=await response.text();
  script=script.replaceAll("location.assign(validDestination(result.url,'checkout.stripe.com'));","const destination=validDestination(result.url,'checkout.stripe.com');await fetch('/__fixture/captured-redirect',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({url:destination})});message('Fixture checkout captured. No purchase.');");
  return new Response(script,{status:response.status,headers:response.headers});
 }
 return response;
}};
`;
const {outputFiles}=await build({stdin:{contents:wrapperSource,resolveDir:new URL('../',import.meta.url).pathname,sourcefile:'web-browser-fixture-entry.ts'},bundle:true,external:['cloudflare:workers'],format:'esm',platform:'browser',write:false});
function subscription(entry){const customer=[...customerPlans.entries()].find(([,value])=>value===entry)?.[0],price=(id)=>({id,unit_amount:id==='price_team'?9900:id==='price_year'?4999:499,currency:'usd',recurring:{interval:id==='price_year'||id==='price_team'?'year':'month',interval_count:1}});return {id:entry.id,customer,status:entry.status,latest_invoice:entry.latestInvoice,cancel_at_period_end:entry.cancelAtPeriodEnd,pending_update:entry.pending?{expires_at:Math.floor(Date.now()/1000)+3600,subscription_items:[{id:'si_'+entry.id,price:price(entry.pending.priceId),quantity:entry.pending.quantity}]}:null,items:{data:[{id:'si_'+entry.id,price:price(entry.priceId),quantity:entry.quantity,current_period_end:entry.periodEnd}]}};}
const outbound = async (request) => {
    const url = new URL(request.url);
    if(url.hostname==='fixture.control') {
      if(url.pathname==='/__fixture/state'&&request.method==='GET')return Response.json({last_checkout_status:lastCheckout?.status??'none',personal_status:customerPlans.get('cus_fixture')?.status??'none',payment_hold:holdPayments,pending_updates:[...customerPlans.values()].filter(p=>p.pending).length,provider_down:providerDown,invalid_redirects:invalidRedirect,preview_amount_due:previewDue});
      if(url.pathname==='/__fixture/captured-redirect'&&request.method==='POST') {const d=await request.json().catch(()=>({}));if(Object.keys(d).length!==1||typeof d.url!=='string')return Response.json({error:'invalid_control'},{status:400});let target;try{target=new URL(d.url);}catch{return Response.json({error:'invalid_destination'},{status:400});}if(target.protocol!=='https:'||target.hostname!=='checkout.stripe.com'||target.username||target.password||target.port)return Response.json({error:'invalid_destination'},{status:400});console.log(JSON.stringify({checkout_destination_host:target.hostname}));return Response.json({captured:true});}
      if(url.pathname==='/__fixture/complete-checkout'&&request.method==='POST') {const d=await request.json().catch(()=>({}));if(Object.keys(d).length||!lastCheckout||lastCheckout.status!=='open'||lastCheckout.expires_at<=Math.floor(Date.now()/1000))return Response.json({error:'no_open_checkout'},{status:409});const checkout=lastCheckout;checkout.status='complete';const plan={id:`sub_${checkout.customer}`,priceId:checkout.priceId,quantity:checkout.quantity,status:'active',cancelAtPeriodEnd:false,pending:null,latestInvoice:`in_${checkout.customer}`,periodEnd:Math.floor(Date.now()/1000)+86400};customerPlans.set(checkout.customer,plan);invoiceCustomers.set(plan.latestInvoice,checkout.customer);if(checkout.teamId)teamCustomers.set(checkout.customer,checkout.teamId);return Response.json({completed:true,kind:checkout.priceId==='price_team'?'team':'personal'});}
      if(url.pathname==='/__fixture/hold-payments'&&request.method==='POST') {const d=await request.json().catch(()=>({}));if(Object.keys(d).length!==1||typeof d.hold!=='boolean')return Response.json({error:'invalid_control'},{status:400});holdPayments=d.hold;return Response.json({payment_hold:holdPayments});}
      if(url.pathname==='/__fixture/provider'&&request.method==='POST') {const d=await request.json().catch(()=>({}));if(Object.keys(d).length!==1||typeof d.down!=='boolean')return Response.json({error:'invalid_control'},{status:400});providerDown=d.down;return Response.json({provider_down:providerDown});}
      if(url.pathname==='/__fixture/redirects'&&request.method==='POST') {const d=await request.json().catch(()=>({}));if(Object.keys(d).length!==1||typeof d.invalid!=='boolean')return Response.json({error:'invalid_control'},{status:400});invalidRedirect=d.invalid;return Response.json({invalid_redirects:invalidRedirect});}
      if(url.pathname==='/__fixture/preview-amount'&&request.method==='POST') {const d=await request.json().catch(()=>({}));if(Object.keys(d).length!==1||!Number.isSafeInteger(d.amount_due)||d.amount_due<0||d.amount_due>10000000)return Response.json({error:'invalid_control'},{status:400});previewDue=d.amount_due;return Response.json({amount_due:previewDue});}
      if(url.pathname==='/__fixture/settle-payment'&&request.method==='POST') {const d=await request.json().catch(()=>({}));if(Object.keys(d).length)return Response.json({error:'invalid_control'},{status:400});let settled=0;for(const plan of customerPlans.values())if(plan.pending){plan.priceId=plan.pending.priceId;plan.quantity=plan.pending.quantity;plan.pending=null;plan.status='active';settled++;}return Response.json({settled});}
      if(url.pathname==='/__fixture/personal-status'&&request.method==='POST') {const d=await request.json().catch(()=>({}));if(Object.keys(d).length!==1||!['active','past_due','incomplete','unpaid','canceled'].includes(d.status))return Response.json({error:'invalid_control'},{status:400});const plan=customerPlans.get('cus_fixture');if(!plan)return Response.json({error:'personal_subscription_missing'},{status:404});plan.status=d.status;if(['past_due','incomplete','unpaid'].includes(d.status))invoiceCustomers.set(plan.latestInvoice,'cus_fixture');return Response.json({status:plan.status});}
      return Response.json({error:'not_found'},{status:404});
    }
    if (url.hostname === 'mail.fixture') {
      const message = await request.json();
      await writeFile(mailFile,JSON.stringify({url:message.text.match(/https?:\/\/[^\s]+/)[0]})); console.log('fixture email captured');
      return Response.json({messageId:'fixture-mail'});
    }
    if(url.hostname!=='api.stripe.com') throw new Error('unexpected provider request');
    if(providerDown)return Response.json({error:{message:'fixture provider unavailable'}},{status:503});
    if(url.pathname.startsWith('/v1/prices/')) {const id=url.pathname.split('/').pop();if(!['price_sync','price_month','price_year','price_team'].includes(id))throw new Error('invalid fixture price');const team=id==='price_team';return Response.json({id,active:true,currency:'usd',unit_amount:team?9900:id==='price_year'?4999:499,recurring:{interval:team||id==='price_year'?'year':'month',interval_count:1,usage_type:'licensed'}});}
    if(url.pathname==='/v1/checkout/sessions') {
      if(request.method==='GET') return Response.json({data:[...fixtureCheckouts.values()].filter(c=>c.status==='open'&&c.customer===new URL(request.url).searchParams.get('customer')),has_more:false});
      const fields=new URLSearchParams(await request.text()),key=request.headers.get('idempotency-key'),priceId=fields.get('line_items[0][price]'),customer=fields.get('customer'),teamId=fields.get('subscription_data[metadata][team_id]');
      if(!['price_month','price_year','price_team'].includes(priceId)||typeof customer!=='string')throw new Error('invalid fixture line item');
      if(!fixtureCheckouts.has(key)){const entry={id:`cs_fixture${fixtureCheckouts.size}`,customer,priceId,teamId,quantity:Number(fields.get('line_items[0][quantity]')||1),status:'open',url:invalidRedirect?'https://evil.example/pay':'https://checkout.stripe.com/c/pay/fixture#doin-complete-fragment',expires_at:Number(fields.get('expires_at'))};fixtureCheckouts.set(key,entry);lastCheckout=entry;}
      return Response.json(fixtureCheckouts.get(key));
    }
    if(url.pathname.startsWith('/v1/checkout/sessions/')) {const item=[...fixtureCheckouts.values()].find(c=>c.id===url.pathname.split('/')[4]);if(!item)throw new Error('unknown fixture checkout');if(url.pathname.endsWith('/expire'))item.status='expired';return Response.json(item);}
    if(url.pathname==='/v1/customers'&&request.method==='POST') {const fields=new URLSearchParams(await request.text()),key=request.headers.get('idempotency-key');if(!key)throw new Error('missing customer idempotency key');if(!customers.has(key)){const id=`cus_browser_${customers.size+1}`,teamId=fields.get('metadata[team_id]');customers.set(key,id);if(teamId)teamCustomers.set(id,teamId);}return Response.json({id:customers.get(key)});}
    if(url.pathname==='/v1/invoices/create_preview'&&request.method==='POST')return Response.json({amount_due:previewDue,currency:'usd'});
    if(url.pathname==='/v1/billing_portal/sessions'&&request.method==='POST') {const fields=new URLSearchParams(await request.text()),customer=fields.get('customer');return Response.json({customer,url:invalidRedirect?'https://evil.example/portal':'https://billing.stripe.com/p/session/fixture'});}
    if(url.pathname.startsWith('/v1/invoices/')) {const id=url.pathname.split('/').pop(),customer=invoiceCustomers.get(id);if(!customer)return Response.json({error:'invoice unavailable'},{status:404});return Response.json({id,customer,status:'open',hosted_invoice_url:invalidRedirect?'https://evil.example/invoice':`https://invoice.stripe.com/i/${id}`});}
    if(url.pathname.startsWith('/v1/subscriptions/')&&request.method==='POST') {const subId=url.pathname.split('/').pop(),entry=[...customerPlans.values()].find(p=>p.id===subId);if(!entry)throw new Error('unknown fixture subscription');const fields=new URLSearchParams(await request.text());if(fields.has('cancel_at_period_end'))entry.cancelAtPeriodEnd=fields.get('cancel_at_period_end')==='true';if(fields.has('items[0][price]')||fields.has('items[0][quantity]')){const change={priceId:fields.get('items[0][price]')||entry.priceId,quantity:Number(fields.get('items[0][quantity]')||entry.quantity)};if(holdPayments)entry.pending={...change,expiresAt:Math.floor(Date.now()/1000)+3600};else{entry.priceId=change.priceId;entry.quantity=change.quantity;entry.pending=null;}}return Response.json(subscription(entry));}
    if(url.pathname.startsWith('/v1/subscriptions/')&&request.method==='DELETE') {const subId=url.pathname.split('/').pop(),entry=[...customerPlans.values()].find(p=>p.id===subId);if(entry)entry.status='canceled';return Response.json({status:'canceled'});}
    if(url.pathname.startsWith('/v1/subscriptions/')) {const subId=url.pathname.split('/').pop(),entry=[...customerPlans.values()].find(p=>p.id===subId);return entry?Response.json(subscription(entry)):Response.json({error:'subscription unavailable'},{status:404});}
    if(url.pathname==='/v1/subscriptions') {const customer=url.searchParams.get('customer'),entry=customerPlans.get(customer);return Response.json({data:entry&&entry.status!=='canceled'?[subscription(entry)]:[],has_more:false});}
    throw new Error('unexpected provider request');
};
const mf = new Miniflare(convertV4MiniflareOptions({host:'127.0.0.1',port,workers:[
  {name:'doin-web-browser-fixture',modules:true,script:outputFiles[0].text,compatibilityDate:'2026-10-01',d1Databases:['DB'],kvNamespaces:['OAUTH_KV'],bindings:{ORIGIN:origin,EMAIL_ENABLED:'true',EMAIL_FROM:'signin@doin.sh',STRIPE_SECRET_KEY:'sk_test_fixture',STRIPE_PRICE_ID:'price_sync',STRIPE_MONTHLY_PRICE_ID:'price_month',STRIPE_YEARLY_PRICE_ID:'price_year',STRIPE_TEAM_PRICE_ID:'price_team',LICENSE_SIGNING_KEY:licenseSigningKey,LICENSE_PUBLIC_KEY:licensePublic,LICENSE_KEY_ID:'web-browser-fixture'},serviceBindings:{EMAIL:{name:'mail',entrypoint:'Mailer'}},outboundService:outbound},
  {name:'mail',modules:true,compatibilityDate:'2026-10-01',script:"import {WorkerEntrypoint} from 'cloudflare:workers'; export class Mailer extends WorkerEntrypoint {async send(message){return (await fetch('https://mail.fixture/message',{method:'POST',body:JSON.stringify(message)})).json();}} export default {fetch(){return new Response('not found',{status:404});}}",outboundService:outbound}
]}));
let stopping = false;
async function stop() {
  if (stopping) return;
  stopping = true;
  await mf.dispose();
  await rm(mailFile,{force:true});
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
  await db.exec((await readFile(new URL('migrations/0010.sql', root), 'utf8')).replaceAll('\n', ' '));
  const now = Math.floor(Date.now() / 1000);
  await db.batch([
    db.prepare('INSERT INTO accounts(id,identity_key,email,name,customer_id,created_at) VALUES(?,?,?,?,?,?)').bind('fixture-account', '101', 'fixture@example.com', 'E2E', 'cus_fixture', now),
    db.prepare('INSERT INTO sessions(token_hash,account_id,kind,name,csrf,expires_at) VALUES(?,?,?,?,?,?)').bind(createHash('sha256').update(token).digest('hex'), 'fixture-account', 'device', 'Terminal E2E', '', now + 3600),
    db.prepare('INSERT INTO documents(account_id,updated_at) VALUES(?,?)').bind('fixture-account', now),
  ]);
  console.log(JSON.stringify({ ready: true, origin, pid: process.pid, mail_file: mailFile }));
} catch (error) {
  await mf.dispose();
  await rm(mailFile,{force:true});
  throw error;
}
