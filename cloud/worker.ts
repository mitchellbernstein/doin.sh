import {personalFoldersRoute,personalDocumentWrite} from './personal-folders';
import {teamRoute,teamAccountDeletionGuard,teamAccess} from './team';
import {providerOAuthPublic,providerOAuthRoute} from './mcp-oauth';
import {taskOAuthPublic,grantRoute,remoteTaskMcp,cleanupMcpAccount} from './mcp-server';
import {mcpRoute} from './mcp';
interface Env {
  DB: D1Database;
  OAUTH_KV: KVNamespace;
  SELF_HOST_MODE?: 'personal' | 'commercial';
  SELF_HOST_OWNER_EMAIL?: string;
  COMMERCIAL_LICENSE_RECEIPT?: string;
  MCP_ENCRYPTION_KEY?: string;
  STRIPE_TEAM_PRICE_ID?: string;
  LICENSE_SIGNING_KEY?: string;
  LICENSE_PUBLIC_KEY?: string;
  LICENSE_KEY_ID?: string;
  ORIGIN: string;
  EMAIL: { send(message: {to: string; from: string; subject: string; text: string}): Promise<{messageId: string}> };
  EMAIL_ENABLED: string;
  EMAIL_FROM: string;
  STRIPE_SECRET_KEY: string;
  STRIPE_WEBHOOK_SECRET: string;
  STRIPE_PRICE_ID: string;
  STRIPE_MONTHLY_PRICE_ID: string;
  STRIPE_YEARLY_PRICE_ID: string;
}
type Account = { id: string; email: string; name: string; customer_id: string | null; closing_at: number | null };
type Session = Account & { token_hash: string };
type DocumentRevision = { revision: number; content: string; updated_at: number };
type Subscription = { id: string; status: string; customer: string; latest_invoice: string | null; cancel_at_period_end: boolean; items: { data: { price: { id: string }; current_period_end: number }[] } };
const encoder = new TextEncoder();
const configured = (value: string | undefined) => !!value && !value.startsWith('REPLACE_');
const now = () => Math.floor(Date.now() / 1000);
const random = () => Array.from(crypto.getRandomValues(new Uint8Array(32)), b => b.toString(16).padStart(2, '0')).join('');
const hex = (bytes: ArrayBuffer) => Array.from(new Uint8Array(bytes), b => b.toString(16).padStart(2, '0')).join('');
const hash = async (value: string) => hex(await crypto.subtle.digest('SHA-256', encoder.encode(value)));
const json = (body: unknown, status = 200) => Response.json(body, { status });
const fail = (status: number, error: string): never => { throw json({ error }, status); };
const escape = (value: string) => value.replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
function page(body: string) {
  return new Response(`<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Confirm doin.sh sign-in</title><link rel="stylesheet" href="/verify.css"><main><a href="https://doin.sh">doin.sh</a>${body}</main></html>`, {headers:{'content-type':'text/html; charset=utf-8'}});
}
async function boundedText(request: Request, max: number) {
  const reader = request.body?.getReader();
  if (!reader) return '';
  let size = 0;
  const parts = [];
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > max) { await reader.cancel(); fail(413, 'too_large'); }
    parts.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const part of parts) { bytes.set(part, offset); offset += part.length; }
  try { return new TextDecoder('utf-8', { fatal: true }).decode(bytes); } catch { fail(400, 'invalid_utf8'); }
}
async function body(request: Request, max = 8192, allowEmpty=false) {
  const raw = await boundedText(request, max);
  if (allowEmpty && raw==='') return {};
  if (request.headers.get('content-type')?.startsWith('application/x-www-form-urlencoded')) return Object.fromEntries(new URLSearchParams(raw));
  if (!request.headers.get('content-type')?.startsWith('application/json')) fail(415, 'json_required');
  try {
    const data = JSON.parse(raw);
    if (!data || typeof data !== 'object' || Array.isArray(data)) fail(400, 'invalid_json');
    return data;
  } catch { fail(400, 'invalid_json'); }
}
async function rateLimit(request: Request, env: Env, email: string) {
  const time=now(), hour=Math.floor(time/3600);
  const counts=await env.DB.batch([
    env.DB.prepare('INSERT INTO rate_limits(key,hits,expires_at) VALUES(?,1,?) ON CONFLICT(key) DO UPDATE SET hits=hits+1 RETURNING hits').bind(`ip:${request.headers.get('cf-connecting-ip') || 'local'}:${hour}`,time+3600),
    env.DB.prepare('INSERT INTO rate_limits(key,hits,expires_at) VALUES(?,1,?) ON CONFLICT(key) DO UPDATE SET hits=hits+1 RETURNING hits').bind(`email:${await hash(email)}:${hour}`,time+3600),
    env.DB.prepare('DELETE FROM rate_limits WHERE expires_at < ?').bind(time),
    env.DB.prepare('DELETE FROM auth_requests WHERE expires_at < ?').bind(time),
    env.DB.prepare('DELETE FROM sessions WHERE expires_at < ?').bind(time),
  ]);
  if ((counts[0].results[0] as {hits:number}).hits>30 || (counts[1].results[0] as {hits:number}).hits>3) fail(429,'try_later');
}
async function session(request: Request, env: Env): Promise<Session> {
  const auth=request.headers.get('authorization'),token=auth?.startsWith('Bearer ') ? auth.slice(7) : '';
  if (!/^[0-9a-f]{64}$/.test(token)) fail(401,'sign_in_required');
  const result=await env.DB.prepare("SELECT a.*,s.token_hash FROM sessions s JOIN accounts a ON a.id=s.account_id WHERE s.token_hash=? AND s.kind='device' AND s.expires_at>?").bind(await hash(token),now()).first<Session>();
  if (!result) fail(401,'sign_in_required');
  return result;
}
function emailAddress(value: unknown): string {
  if (typeof value !== 'string' || value.length>254 || !/^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,63}$/.test(value) || value.startsWith('.') || value.includes('..') || value.includes('.@') || value.split('@')[0].length>64) fail(400,'valid_email_required');
  return value.toLowerCase();
}
type AuthRequest={id:string;email:string;device_name:string;challenge:string;link_hash:string;confirmation_hash:string;expires_at:number;approved_at:number|null;claimed_hash:string|null;verification_attempts:number};
async function startLogin(request: Request,env: Env) {
  if (env.EMAIL_ENABLED!=='true' || !env.EMAIL || !configured(env.EMAIL_FROM)) fail(503,'email_not_configured');
  const data=await body(request),email=emailAddress(data.email);
  if (typeof data.name!=='string' || !data.name.trim() || data.name.length>80 || /[\x00-\x1f\x7f]/.test(data.name) || typeof data.code_challenge!=='string' || !/^[A-Za-z0-9_-]{43}$/.test(data.code_challenge)) fail(400,'device_name_and_challenge_required');
  if (env.SELF_HOST_MODE === 'personal' && (!configured(env.SELF_HOST_OWNER_EMAIL) || email !== emailAddress(env.SELF_HOST_OWNER_EMAIL))) fail(403, 'personal_host_owner_only');
  await rateLimit(request,env,email);
  const id=random(),token=random(),code=String(crypto.getRandomValues(new Uint32Array(1))[0]%1000000).padStart(6,'0');
  await env.DB.prepare('INSERT INTO auth_requests(id,email,device_name,challenge,link_hash,confirmation_hash,expires_at) VALUES(?,?,?,?,?,?,?)').bind(id,email,data.name.trim(),data.code_challenge,await hash(token),await hash(`${id}\n${code}`),now()+600).run();
  try {
    await env.EMAIL.send({to:email,from:env.EMAIL_FROM,subject:'Confirm your doin.sh sign-in',text:`You requested sign-in on ${data.name.trim()}.\n\nOpen this link and enter the six-digit confirmation code shown in your doin terminal. The link expires in ten minutes.\n${env.ORIGIN}/auth/verify?token=${token}\n\nIf you did not request this, ignore this email. Never approve a sign-in code someone else gave you.`});
  } catch {
    await env.DB.prepare('DELETE FROM auth_requests WHERE id=?').bind(id).run();
    fail(503,'email_unavailable');
  }
  return json({request_id:id,confirmation_code:code,expires_in:600,interval:2});
}
async function verifyLogin(request: Request,env: Env,url: URL) {
  const data=request.method==='POST' ? await body(request) : {token:url.searchParams.get('token')};
  if (typeof data.token!=='string' || !/^[0-9a-f]{64}$/.test(data.token)) fail(401,'invalid_login');
  const saved=await env.DB.prepare('SELECT * FROM auth_requests WHERE link_hash=? AND expires_at>? AND claimed_hash IS NULL').bind(await hash(data.token),now()).first<AuthRequest>();
  if (!saved) fail(401,'invalid_login');
  if (request.method==='GET') return page(`<h1>Confirm sign-in.</h1><p>Only continue if you requested sign-in from doin on ${escape(saved.device_name)}.</p><p>Enter the six-digit code shown in your terminal. Do not use a code someone else gave you.</p><form method="post" action="/auth/verify"><input type="hidden" name="token" value="${data.token}"><label>Terminal code <input name="confirmation_code" inputmode="numeric" autocomplete="off" pattern="[0-9]{6}" minlength="6" maxlength="6" required></label><button>Confirm sign-in</button></form>`);
  if (request.headers.get('origin')!==env.ORIGIN) fail(403,'forbidden');
  const attempt=await env.DB.prepare('UPDATE auth_requests SET verification_attempts=verification_attempts+1 WHERE id=? AND verification_attempts<5 AND expires_at>? AND claimed_hash IS NULL RETURNING verification_attempts').bind(saved.id,now()).first();
  if (!attempt) fail(429,'try_later');
  if (typeof data.confirmation_code!=='string' || !/^[0-9]{6}$/.test(data.confirmation_code) || await hash(`${saved.id}\n${data.confirmation_code}`)!==saved.confirmation_hash) fail(400,'incorrect_confirmation_code');
  await env.DB.prepare('UPDATE auth_requests SET approved_at=COALESCE(approved_at,?) WHERE id=? AND expires_at>? AND claimed_hash IS NULL').bind(now(),saved.id,now()).run();
  return page('<h1>Sign-in confirmed.</h1><p>Return to your doin terminal. You can close this tab.</p>');
}
async function pollLogin(request: Request,env: Env) {
  const data=await body(request);
  if (typeof data.request_id!=='string' || !/^[0-9a-f]{64}$/.test(data.request_id) || typeof data.code_verifier!=='string' || !/^[A-Za-z0-9._~-]{43,128}$/.test(data.code_verifier)) fail(401,'invalid_login');
  const saved=await env.DB.prepare('SELECT * FROM auth_requests WHERE id=? AND expires_at>?').bind(data.request_id,now()).first<AuthRequest>();
  const digest=await crypto.subtle.digest('SHA-256',encoder.encode(data.code_verifier));
  const challenge=btoa(String.fromCharCode(...new Uint8Array(digest))).replaceAll('+','-').replaceAll('/','_').replaceAll('=','');
  if (!saved || challenge!==saved.challenge) fail(401,'invalid_login');
  if (!saved.approved_at) return json({status:'pending'},202);
  const token=await hash(`doin-device\n${data.code_verifier}`),tokenHash=await hash(token),time=now(),expires=time+90*86400;
  if (saved.claimed_hash && saved.claimed_hash!==tokenHash) fail(401,'invalid_login');
  if (!saved.claimed_hash) await env.DB.batch([
    env.DB.prepare('INSERT INTO accounts(id,identity_key,email,name,created_at) SELECT ?,?,email,?,? FROM auth_requests WHERE id=? AND approved_at IS NOT NULL AND expires_at>? AND claimed_hash IS NULL ON CONFLICT(email) DO NOTHING').bind(crypto.randomUUID(),crypto.randomUUID(),saved.email.split('@')[0],time,saved.id,time),
    env.DB.prepare('INSERT INTO documents(account_id,updated_at) SELECT a.id,? FROM accounts a JOIN auth_requests r ON a.email=r.email WHERE r.id=? AND r.approved_at IS NOT NULL AND r.expires_at>? AND r.claimed_hash IS NULL ON CONFLICT(account_id) DO NOTHING').bind(time,saved.id,time),
    env.DB.prepare("INSERT INTO sessions(token_hash,account_id,kind,name,csrf,expires_at) SELECT ?,a.id,'device',r.device_name,'',? FROM accounts a JOIN auth_requests r ON a.email=r.email WHERE r.id=? AND r.approved_at IS NOT NULL AND r.expires_at>? AND r.claimed_hash IS NULL AND (SELECT count(*) FROM sessions WHERE account_id=a.id AND kind='device' AND expires_at>?)<20 ON CONFLICT(token_hash) DO NOTHING").bind(tokenHash,expires,saved.id,time,time),
    env.DB.prepare('UPDATE auth_requests SET claimed_hash=?,claimed_at=? WHERE id=? AND approved_at IS NOT NULL AND expires_at>? AND claimed_hash IS NULL AND EXISTS(SELECT 1 FROM sessions s JOIN accounts a ON a.id=s.account_id WHERE s.token_hash=? AND s.expires_at>? AND a.email=auth_requests.email)').bind(tokenHash,time,saved.id,time,tokenHash,time),
  ]);
  const result=await env.DB.prepare("SELECT a.id,a.email,a.name,s.expires_at FROM sessions s JOIN accounts a ON a.id=s.account_id JOIN auth_requests r ON r.email=a.email WHERE r.id=? AND r.claimed_hash=s.token_hash AND s.token_hash=? AND s.kind='device' AND s.expires_at>? AND r.expires_at>?").bind(saved.id,tokenHash,now(),now()).first<{id:string;email:string;name:string;expires_at:number}>();
  if (!result) fail(saved.claimed_hash ? 401 : 409,saved.claimed_hash ? 'invalid_login' : 'device_limit');
  return json({token,expires_at:result.expires_at,account:{id:result.id,email:result.email,name:result.name}});
}
async function stripe(env: Env, path: string, fields?: Record<string, string>, idempotencyKey?: string, method?: 'DELETE') {
  if (!configured(env.STRIPE_SECRET_KEY) || !configured(env.STRIPE_PRICE_ID)) fail(503, 'billing_not_configured');
  const response = await fetch(`https://api.stripe.com/v1/${path}`, {
    method: method || (fields ? 'POST' : 'GET'), signal: AbortSignal.timeout(10000),
    headers: { authorization: `Bearer ${env.STRIPE_SECRET_KEY}`, 'Stripe-Version': '2025-03-31.basil', ...(fields ? { 'content-type': 'application/x-www-form-urlencoded' } : {}), ...(idempotencyKey ? { 'idempotency-key': idempotencyKey } : {}) },
    body: fields ? new URLSearchParams(fields) : undefined,
  });
  if (!response.ok) fail(503, 'billing_unavailable');
  return response.json() as Promise<any>;
}
async function billingMutation(account: Account,env: Env,operation: (lock: string)=>Promise<Response>,closing=false) {
  const lock=random();
  const claimed=await env.DB.prepare('UPDATE accounts SET billing_lock=?,billing_lock_until=?,closing_at=CASE WHEN ? THEN COALESCE(closing_at,?) ELSE closing_at END WHERE id=? AND (billing_lock_until IS NULL OR billing_lock_until<=?) AND (? OR closing_at IS NULL) RETURNING id').bind(lock,now()+60,closing,now(),account.id,now(),closing).first();
  if (!claimed) fail(409,'billing_busy');
  try { return await operation(lock); }
  finally { await env.DB.prepare('UPDATE accounts SET billing_lock=NULL,billing_lock_until=NULL WHERE id=? AND billing_lock=?').bind(account.id,lock).run(); }
}
async function renewBilling(account: Account,env: Env,lock: string) {
  const renewed=await env.DB.prepare('UPDATE accounts SET billing_lock_until=? WHERE id=? AND billing_lock=? RETURNING id').bind(now()+60,account.id,lock).first();
  if (!renewed) fail(409,'billing_busy');
}
async function subscriptions(account: Account, env: Env): Promise<Subscription[]> {
  if (!account.customer_id) return [];
  const result = await stripe(env, `subscriptions?customer=${encodeURIComponent(account.customer_id)}&status=all&limit=100`);
  if (!Array.isArray(result.data) || result.has_more !== false) fail(503, 'billing_unavailable');
  for (const subscription of result.data) {
    if (typeof subscription.id!=='string' || !subscription.id.startsWith('sub_') || subscription.customer!==account.customer_id || typeof subscription.status!=='string' || !Array.isArray(subscription.items?.data)) fail(503,'billing_unavailable');
    if (subscription.items.data.some((item: {price?:{id?:unknown};current_period_end?:unknown})=>typeof item.price?.id!=='string' || !Number.isSafeInteger(item.current_period_end))) fail(503,'billing_unavailable');
  }
  return result.data;
}
const acceptedPrice = (env: Env,id: string) => [env.STRIPE_PRICE_ID,env.STRIPE_MONTHLY_PRICE_ID,env.STRIPE_YEARLY_PRICE_ID].some(p=>configured(p)&&p===id);
function checkoutFields(account: Account,env: Env,expires: number,price=env.STRIPE_PRICE_ID) {
  return {customer:account.customer_id!,mode:'subscription','line_items[0][price]':price,'line_items[0][quantity]':'1','subscription_data[metadata][account_id]':account.id,success_url:'https://doin.sh/?checkout=success',cancel_url:'https://doin.sh/?checkout=canceled',expires_at:String(expires)};
}
async function subscribed(account: Account, env: Env) {
  if (env.SELF_HOST_MODE === 'personal') return account.closing_at === null && configured(env.SELF_HOST_OWNER_EMAIL) && account.email === emailAddress(env.SELF_HOST_OWNER_EMAIL);
  return (await subscriptions(account, env)).some(s => s.customer === account.customer_id && s.status === 'active' && s.items?.data?.some(i => acceptedPrice(env,i.price?.id) && i.current_period_end > now()));
}
async function document(account: Account, env: Env): Promise<DocumentRevision> {
  return (await env.DB.prepare('SELECT revision,content,updated_at FROM documents WHERE account_id=?').bind(account.id).first<DocumentRevision>())!;
}
async function webhook(request: Request, env: Env) {
  if (!configured(env.STRIPE_WEBHOOK_SECRET)) fail(503, 'billing_not_configured');
  const raw = await boundedText(request, 262144);
  const fields = (request.headers.get('stripe-signature') || '').split(',').map(p => p.split('='));
  const time = fields.find(([k]) => k === 't')?.[1];
  if (!time || !/^\d+$/.test(time) || Math.abs(now() - Number(time)) > 300) fail(400, 'invalid_signature');
  const key = await crypto.subtle.importKey('raw', encoder.encode(env.STRIPE_WEBHOOK_SECRET), { name: 'HMAC', hash: 'SHA-256' }, false, ['verify']);
  let verified = false;
  for (const [name, signature] of fields) {
    if (name !== 'v1' || !/^[0-9a-f]{64}$/.test(signature)) continue;
    const bytes = new Uint8Array(signature.match(/../g)!.map(x => parseInt(x, 16)));
    if (await crypto.subtle.verify('HMAC', key, bytes, encoder.encode(`${time}.${raw}`))) verified = true;
  }
  if (!verified) fail(400, 'invalid_signature');
  let event: any;
  try { event = JSON.parse(raw); } catch { fail(400, 'invalid_json'); }
  if (typeof event.id !== 'string' || event.id.length > 200 || typeof event.type !== 'string') fail(400, 'invalid_event');
  if (await env.DB.prepare('SELECT id FROM webhook_events WHERE id=?').bind(event.id).first()) return json({ received: true });
  const relevant = ['checkout.session.completed', 'customer.subscription.created', 'customer.subscription.updated', 'customer.subscription.deleted'];
  if (!relevant.includes(event.type)) return json({ received: true });
  const customer = event.data?.object?.customer;
  if (typeof customer !== 'string') fail(400, 'invalid_event');
  const account = await env.DB.prepare('SELECT * FROM accounts WHERE customer_id=?').bind(customer).first<Account>();
  if (!account) return json({ received: true });
  const active = await subscribed(account, env);
  await env.DB.batch([
    env.DB.prepare('INSERT INTO subscriptions(account_id,status,checked_at) VALUES(?,?,?) ON CONFLICT(account_id) DO UPDATE SET status=excluded.status,checked_at=excluded.checked_at').bind(account.id, active ? 'active' : 'inactive', now()),
    env.DB.prepare('INSERT INTO webhook_events(id,received_at) VALUES(?,?) ON CONFLICT(id) DO NOTHING').bind(event.id, now()),
  ]);
  return json({ received: true });
}
async function paidAccount(id:string,env:Env,teamId?:string):Promise<boolean> {
  if(teamId) return (await teamAccess(env,id,teamId,true)).active;
  const account=await env.DB.prepare('SELECT id,email,name,customer_id,closing_at FROM accounts WHERE id=? AND closing_at IS NULL').bind(id).first<Account>();
  return !!account && await subscribed(account,env);
}
async function route(request: Request, env: Env,ctx:ExecutionContext): Promise<Response> {
  const url = new URL(request.url), path = url.pathname;
  if (url.origin !== env.ORIGIN) fail(400, 'wrong_origin');
  const paid=(id:string,teamId?:string)=>paidAccount(id,env,teamId);
  if(path==='/mcp') return remoteTaskMcp(request,env,{paid});
  if(path.startsWith('/oauth/') || path.startsWith('/.well-known/oauth-')) {
    const handled=await taskOAuthPublic(request,env,ctx,{paid});
    if(handled) return handled;
  }
  if(path==='/mcp/provider/callback'||path==='/mcp/client-metadata.json') {
    const handled=await providerOAuthPublic(request,env,{paid});
    if(handled) return handled;
  }
  if (path === '/health' && request.method === 'GET') return json({ service: 'doin-sync' });
  if (path === '/v1/plan' && request.method === 'GET') {
    const mode = /^(sk|rk)_test_/.test(env.STRIPE_SECRET_KEY || '') ? 'test' : /^(sk|rk)_live_/.test(env.STRIPE_SECRET_KEY || '') ? 'live' : 'unavailable';
    const billing_ready = mode !== 'unavailable' && configured(env.STRIPE_MONTHLY_PRICE_ID) && configured(env.STRIPE_YEARLY_PRICE_ID);
    const email_ready = env.EMAIL_ENABLED === 'true' && !!env.EMAIL && configured(env.EMAIL_FROM);
    return json({name:'doinMORE',amount:499,currency:'usd',interval:'month',options:[{interval:'month',amount:499},{interval:'year',amount:4999}],billing_mode:billing_ready ? mode : 'unavailable',email_ready,billing_ready});
  }
  if (path === '/verify.css' && request.method==='GET') return new Response('html{color-scheme:dark;font:16px system-ui;background:#080808;color:#ededed}main{max-width:600px;margin:60px auto;padding:24px}a{color:inherit}button,input{font:inherit;padding:12px;background:#171717;color:inherit;border:1px solid #444;border-radius:4px}form{margin:24px 0}button:focus-visible,a:focus-visible{outline:2px solid white;outline-offset:4px}',{headers:{'content-type':'text/css; charset=utf-8'}});
  if (path === '/webhooks/stripe' && request.method === 'POST') return webhook(request, env);
  if (path === '/v1/auth/start' && request.method==='POST') return startLogin(request,env);
  if (path === '/v1/auth/poll' && request.method==='POST') return pollLogin(request,env);
  if (path === '/auth/verify' && ['GET','POST'].includes(request.method)) return verifyLogin(request,env,url);
  if (path === '/' || path === '/account' || path.startsWith('/auth/') || path === '/v1/portal') fail(404,'account_management_in_terminal');
  const who=await session(request,env);
  if (path === '/v1/folders' || path.startsWith('/v1/folders/')) return personalFoldersRoute(request,env,who,{body,paid:async()=>{if(!await subscribed(who,env))fail(402,'subscription_required');}});
  if (path === '/v1/teams' || path.startsWith('/v1/teams/')) return teamRoute(request,env,who,{body,stripe:(path,fields,key,method)=>stripe(env,path,fields,key,method),emailAddress});
  if(path==='/v1/mcp/grants'||path.startsWith('/v1/mcp/grants/')) return grantRoute(request,env,who,{body,subscribed:(teamId?:string)=>teamId?paidAccount(who.id,env,teamId):subscribed(who,env),teamPaid:async id=>(await teamAccess(env,who.id,id,true)).active});
  if(/^\/v1\/mcp\/connections\/[^/]+\/oauth$/.test(path)) return providerOAuthRoute(request,env,who,{body,subscribed:(teamId?:string)=>teamId?paidAccount(who.id,env,teamId):subscribed(who,env)});
  if (path === '/v1/mcp/connections' || path.startsWith('/v1/mcp/connections/')) return mcpRoute(request,env,who,{body,subscribed:(teamId?:string)=>teamId?paidAccount(who.id,env,teamId):subscribed(who,env)});
  if (path === '/v1/account' && request.method==='GET') return json({id:who.id,email:who.email,name:who.name,deletion_pending:who.closing_at!==null});
  if (path === '/v1/account' && request.method==='DELETE') {
    await teamAccountDeletionGuard(env,who.id);
    if ((await body(request)).confirmation!=='delete my account') fail(400,'deletion_confirmation_required');
    return billingMutation(who,env,async lock=>{
      const checkout=await env.DB.prepare('SELECT * FROM checkouts WHERE account_id=?').bind(who.id).first<{session_id:string|null;expires_at:number;idempotency_key:string;price_id:string|null}>();
      if (checkout && !checkout.session_id && checkout.expires_at>now()) {
        await stripe(env,'checkout/sessions',checkoutFields(who,env,checkout.expires_at,checkout.price_id || env.STRIPE_PRICE_ID),checkout.idempotency_key);
      }
      if (who.customer_id) {
        const open=await stripe(env,`checkout/sessions?customer=${encodeURIComponent(who.customer_id)}&status=open&limit=100`);
        if (!Array.isArray(open.data) || open.has_more!==false) fail(503,'billing_unavailable');
        for (const entry of open.data) {
          if (entry.customer!==who.customer_id || typeof entry.id!=='string' || !entry.id.startsWith('cs_')) fail(503,'billing_unavailable');
          await renewBilling(who,env,lock);
          await stripe(env,`checkout/sessions/${encodeURIComponent(entry.id)}/expire`,{});
        }
      }
      for (const subscription of await subscriptions(who,env)) {
        if (subscription.customer!==who.customer_id || ['canceled','incomplete_expired'].includes(subscription.status)) continue;
        await renewBilling(who,env,lock);
        await stripe(env,`subscriptions/${encodeURIComponent(subscription.id)}`,undefined,undefined,'DELETE');
      }
      await renewBilling(who,env,lock);
      await cleanupMcpAccount(env,who.id);
      const removed=await env.DB.batch([
        env.DB.prepare('DELETE FROM auth_requests WHERE email=?').bind(who.email),
        env.DB.prepare('DELETE FROM accounts WHERE id=? AND billing_lock=? RETURNING id').bind(who.id,lock),
      ]);
      if (!removed[1].results.length) fail(409,'billing_busy');
      return json({deleted:true});
    },true);
  }
  if (path === '/v1/export' && request.method==='GET') return json(await document(who,env));
  if (path === '/v1/devices' && request.method==='GET') {
    const devices=await env.DB.prepare("SELECT token_hash AS id,name,expires_at FROM sessions WHERE account_id=? AND kind='device' AND expires_at>?").bind(who.id,now()).all<{id:string;name:string;expires_at:number}>();
    return json({devices:devices.results.map(d=>({...d,current:d.id===who.token_hash}))});
  }
  if (path === '/v1/devices/revoke' && request.method==='POST') {
    const data=await body(request);
    if (typeof data.id!=='string' || !/^[0-9a-f]{64}$/.test(data.id)) fail(400,'device_required');
    await env.DB.prepare("DELETE FROM sessions WHERE account_id=? AND token_hash=? AND kind='device'").bind(who.id,data.id).run();
    return json({revoked:true});
  }
  if (path === '/v1/logout' && request.method==='POST') {
    await env.DB.prepare('DELETE FROM sessions WHERE token_hash=?').bind(who.token_hash).run();
    return json({signed_out:true});
  }
  if (path === '/v1/billing' && request.method==='GET') {
    if (env.SELF_HOST_MODE === 'personal') return json({active:await subscribed(who,env),status:'personal_self_hosted',cancel_at_period_end:false,current_period_end:0});
    const list=await subscriptions(who,env),active=list.filter(s=>s.status==='active' && s.items?.data?.some(i=>acceptedPrice(env,i.price?.id) && i.current_period_end>now()));
    return json({active:active.length>0,status:active.length ? 'active' : list[0]?.status || 'none',cancel_at_period_end:active.length>0 && active.every(s=>s.cancel_at_period_end),current_period_end:Math.max(0,...active.flatMap(s=>s.items.data.filter(i=>acceptedPrice(env,i.price?.id)).map(i=>i.current_period_end)))});
  }
  if (['/v1/billing/cancel','/v1/billing/resume'].includes(path) && request.method==='POST') {
    return billingMutation(who,env,async lock=>{
      const cancel=path.endsWith('/cancel');
      const list=(await subscriptions(who,env)).filter(s=>s.customer===who.customer_id && (cancel ? !['canceled','incomplete_expired'].includes(s.status) : s.status==='active') && s.items?.data?.some(i=>acceptedPrice(env,i.price?.id)));
      if (!list.length) fail(409,'no_subscription');
      for (const subscription of list) {
        await renewBilling(who,env,lock);
        await stripe(env,`subscriptions/${encodeURIComponent(subscription.id)}`,{cancel_at_period_end:String(cancel)});
      }
      return json({cancel_at_period_end:cancel});
    });
  }
  if (path === '/v1/billing/recover' && request.method==='POST') {
    const list=(await subscriptions(who,env)).filter(s=>s.customer===who.customer_id && ['past_due','incomplete','unpaid'].includes(s.status) && s.items?.data?.some(i=>acceptedPrice(env,i.price?.id)));
    for (const subscription of list) {
      if (typeof subscription.latest_invoice!=='string') continue;
      const invoice=await stripe(env,`invoices/${encodeURIComponent(subscription.latest_invoice)}`);
      if (invoice.customer!==who.customer_id || invoice.status!=='open' || typeof invoice.hosted_invoice_url!=='string') continue;
      const link=new URL(invoice.hosted_invoice_url);
      if (link.protocol!=='https:' || link.hostname!=='invoice.stripe.com') fail(503,'billing_unavailable');
      return json({url:link.href});
    }
    fail(409,'no_recoverable_invoice');
  }
  if (path === '/v1/checkout' && request.method === 'POST') {
    const data=await body(request,8192,true);
    const interval=data.interval ?? 'month';
    if (!['month','year'].includes(interval) || Object.keys(data).some(k=>k!=='interval')) fail(400,'valid_interval_required');
    const selected=interval==='year' ? env.STRIPE_YEARLY_PRICE_ID : env.STRIPE_MONTHLY_PRICE_ID;
    if (!configured(selected)) fail(503,'billing_not_configured');
    return billingMutation(who,env,async lock=>{
    const existing = await subscriptions(who, env);
    if (existing.some(s => !['canceled', 'incomplete_expired'].includes(s.status))) fail(409, 'manage_existing_subscription');
    const price = await stripe(env, `prices/${encodeURIComponent(selected)}`);
    if (!price.active || price.unit_amount !== (interval==='year'?4999:499) || price.currency !== 'usd' || price.recurring?.interval !== interval || price.recurring?.interval_count !== 1) fail(503, 'invalid_sync_price');
    if (!who.customer_id) {
      const customer = await stripe(env, 'customers', { 'metadata[account_id]': who.id }, `doin-customer-${who.id}`);
      if (typeof customer.id !== 'string' || !customer.id.startsWith('cus_')) fail(503, 'billing_unavailable');
      await env.DB.prepare('UPDATE accounts SET customer_id=? WHERE id=? AND customer_id IS NULL').bind(customer.id, who.id).run();
      who.customer_id = customer.id;
    }
    type Checkout = { idempotency_key: string; expires_at: number; url: string | null; session_id: string | null; price_id: string | null };
    let checkout=await env.DB.prepare('SELECT * FROM checkouts WHERE account_id=?').bind(who.id).first<Checkout>();
    if (checkout && checkout.expires_at>now()) {
      // Replay original creation exactly before retiring an uncertain remote session.
      let remote=checkout.session_id ? await stripe(env,`checkout/sessions/${encodeURIComponent(checkout.session_id)}`) : await stripe(env,'checkout/sessions',checkoutFields(who,env,checkout.expires_at,checkout.price_id || env.STRIPE_PRICE_ID),checkout.idempotency_key);
      if (remote.customer!==who.customer_id || !['open','expired','complete'].includes(remote.status) || typeof remote.id!=='string' || !remote.id.startsWith('cs_')) fail(503,'billing_unavailable');
      if (remote.status==='complete') fail(409,'manage_existing_subscription');
      if (remote.status==='open' && checkout.price_id===selected) {
        if (checkout.url) return json({url:checkout.url});
      } else {
      await renewBilling(who,env,lock);
      if (remote.status==='open') {
        remote=await stripe(env,`checkout/sessions/${encodeURIComponent(remote.id)}/expire`,{});
        if (remote.status!=='expired') fail(503,'billing_unavailable');
      }
      if ((await subscriptions(who,env)).some(s=>!['canceled','incomplete_expired'].includes(s.status))) fail(409,'manage_existing_subscription');
      await env.DB.prepare('DELETE FROM checkouts WHERE account_id=? AND idempotency_key=?').bind(who.id,checkout.idempotency_key).run();
      checkout=null;
      }
    }
    const claimed = await env.DB.prepare('INSERT INTO checkouts(account_id,idempotency_key,expires_at,price_id) VALUES(?,?,?,?) ON CONFLICT(account_id) DO UPDATE SET idempotency_key=excluded.idempotency_key,expires_at=excluded.expires_at,price_id=excluded.price_id,url=NULL,session_id=NULL WHERE checkouts.expires_at<=? RETURNING *').bind(who.id, `doin-checkout-${random()}`, now() + 3600,selected, now()).first<Checkout>();
    checkout = claimed || (await env.DB.prepare('SELECT * FROM checkouts WHERE account_id=?').bind(who.id).first<Checkout>())!;
    if (checkout.url) return json({url:checkout.url});
    const result = await stripe(env, 'checkout/sessions', checkoutFields(who,env,checkout.expires_at,checkout.price_id || env.STRIPE_PRICE_ID), checkout.idempotency_key);
    if (typeof result.url !== 'string' || new URL(result.url).protocol!=='https:' || new URL(result.url).hostname !== 'checkout.stripe.com' || typeof result.id!=='string' || !result.id.startsWith('cs_')) fail(503, 'billing_unavailable');
    await env.DB.prepare('UPDATE checkouts SET url=?,session_id=? WHERE account_id=? AND idempotency_key=?').bind(result.url,result.id,who.id,checkout.idempotency_key).run();
    return json({url:result.url});
    });
  }
  if (path === '/v1/document' && (request.method === 'GET' || request.method === 'PUT')) {
    if (!await subscribed(who, env)) fail(402, 'subscription_required');
    if (request.method === 'GET') return json(await document(who, env));
    const data = await body(request, 6 * 1048576 + 1024);
    if (!Number.isSafeInteger(data.revision) || data.revision < 0 || typeof data.content !== 'string') fail(400, 'revision_and_content_required');
    if (encoder.encode(data.content).length > 1048576) fail(413, 'too_large');
    return json(await personalDocumentWrite(env,who.id,'root',data.revision,data.content));
  }
  fail(404, 'not_found');
}
export default {
  async fetch(request: Request, env: Env,ctx:ExecutionContext) {
    let response: Response;
    try { response = await route(request, env,ctx); }
    catch (error) { response = error instanceof Response ? error : json({ error: 'service_unavailable' }, 503); }
    const headers = new Headers(response.headers);
    headers.set('cache-control', 'no-store');
    headers.set('x-content-type-options', 'nosniff');
    // Native form navigation needs its real Origin; omit path/query from Referer.
    headers.set('referrer-policy', 'strict-origin');
    headers.set('content-security-policy', "default-src 'none'; style-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'");
    headers.set('strict-transport-security', 'max-age=31536000');
    return new Response(response.body, { status: response.status, headers });
  },
};
