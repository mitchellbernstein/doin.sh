import {foldersRoute,folderAccess,documentRead,documentWrite} from './folders';
import {COMMERCIAL_TERMS,COMMERCIAL_TERMS_VERSION,issueLicense,selfHostLicense,type LicenseEnv} from './license';
export type TeamEnv=LicenseEnv&{DB:D1Database;ORIGIN:string;STRIPE_TEAM_PRICE_ID?:string;EMAIL_FROM:string;EMAIL:{send(message:{to:string;from:string;subject:string;text:string}):Promise<unknown>}};
type Actor={id:string;email:string;closing_at:number|null};
export type Team={id:string;name:string;legal_entity:string;terms_version:string;deployment:string;customer_id:string|null;subscription_id:string|null;capacity:number;period_end:number;next_capacity:number;closing_at:number|null};
type Boundary={body:(r:Request,max?:number)=>Promise<any>;stripe?:(path:string,fields?:Record<string,string>,key?:string,method?:'DELETE')=>Promise<any>;emailAddress?:(value:unknown)=>string};
const now=()=>Math.floor(Date.now()/1000),json=(data:unknown,status=200)=>Response.json(data,{status}),fail=(status:number,error:string):never=>{throw json({error},status);};
const random=()=>crypto.randomUUID(),enc=new TextEncoder();
const hash=async(value:string)=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',enc.encode(value))),v=>v.toString(16).padStart(2,'0')).join('');
const text=(value:unknown,name:string,max=120):string=>{if(typeof value!=='string'||!value.trim()||value.length>max||/[\x00-\x1f\x7f]/.test(value))fail(400,`valid_${name}_required`);return value.trim();};
const count=(value:unknown):number=>{if(!Number.isSafeInteger(value)||Number(value)<1||Number(value)>10000)fail(400,'invalid_seats');return Number(value);};
const configured=(v:string|undefined)=>!!v&&!v.startsWith('REPLACE_');
function client(env:TeamEnv,b?:Boundary){return b?.stripe??(async(path:string,fields?:Record<string,string>,key?:string,method?:'DELETE')=>{
 if(!configured(env.STRIPE_SECRET_KEY)||!configured(env.STRIPE_TEAM_PRICE_ID))fail(503,'team_billing_not_configured');
 const r=await fetch(`https://api.stripe.com/v1/${path}`,{method:method||(fields?'POST':'GET'),signal:AbortSignal.timeout(10000),headers:{authorization:`Bearer ${env.STRIPE_SECRET_KEY}`,'Stripe-Version':'2025-03-31.basil',...(fields?{'content-type':'application/x-www-form-urlencoded'}:{}),...(key?{'idempotency-key':key}:{})},body:fields?new URLSearchParams(fields):undefined});
 if(!r.ok)fail(503,'team_billing_unavailable');return r.json();
 });}
async function member(env:TeamEnv,accountId:string,id:string){
 const row=await env.DB.prepare('SELECT t.*,m.role FROM teams t JOIN team_members m ON m.team_id=t.id WHERE t.id=? AND m.account_id=? AND t.closing_at IS NULL').bind(id,accountId).first<Team&{role:string}>();
 if(!row)fail(404,'team_not_found');return row;
}
async function provider(env:TeamEnv,t:Team,b?:Boundary){
 if(env.SELF_HOST_MODE==='personal')fail(402,'commercial_license_required');
 if(env.SELF_HOST_MODE==='commercial'){
  const c=await selfHostLicense(env);if(c.team_id!==t.id||c.legal_entity!==t.legal_entity)fail(402,'commercial_license_scope_mismatch');
  await env.DB.prepare('UPDATE teams SET capacity=?,period_end=?,next_capacity=? WHERE id=? AND closing_at IS NULL').bind(c.seats,c.expires_at,c.seats,t.id).run();
  return {active:true,capacity:c.seats,period_end:c.expires_at,subscription:null};
 }
 if(!t.customer_id)return {active:false,capacity:0,period_end:0,subscription:null};
 const data=await client(env,b)(`subscriptions?customer=${encodeURIComponent(t.customer_id)}&status=all&limit=100`);
 if(!Array.isArray(data.data)||data.has_more!==false)fail(503,'team_billing_unavailable');
 const owned=data.data.filter((s:any)=>s.customer===t.customer_id&&s.items?.data?.some((i:any)=>i.price?.id===env.STRIPE_TEAM_PRICE_ID));
 if(owned.length>1&&owned.filter((s:any)=>!['canceled','incomplete_expired'].includes(s.status)).length>1)fail(503,'multiple_team_subscriptions');
 const s=owned.find((s:any)=>!['canceled','incomplete_expired'].includes(s.status))??null;
 if(!s)return {active:false,capacity:0,period_end:0,subscription:null};
 const items=s.items.data.filter((i:any)=>i.price?.id===env.STRIPE_TEAM_PRICE_ID);
 if(items.length!==1||typeof s.id!=='string'||!/^sub_/.test(s.id)||typeof items[0].id!=='string'||!Number.isSafeInteger(items[0].quantity)||items[0].quantity<1||items[0].quantity>10000||!Number.isSafeInteger(items[0].current_period_end))fail(503,'team_billing_unavailable');
 const end=items[0].current_period_end,active=s.status==='active'&&end>now();
 // A midterm reduction changes renewal quantity; already paid capacity remains reusable.
 const capacity=active?(t.period_end===end?Math.max(t.capacity,items[0].quantity):items[0].quantity):0;
 await env.DB.prepare('UPDATE teams SET subscription_id=?,capacity=?,period_end=?,next_capacity=? WHERE id=? AND closing_at IS NULL').bind(s.id,active?capacity:(t.period_end===end?t.capacity:0),end,items[0].quantity,t.id).run();
 if(active&&!s.pending_update)await env.DB.prepare('UPDATE team_seat_operations SET completed=1 WHERE team_id=? AND seats=?').bind(t.id,items[0].quantity).run();
 return {active,capacity,period_end:end,subscription:s};
}
export async function teamAccess(env:TeamEnv,accountId:string,teamId:string,requirePaid=true,b?:Boundary){
 if(env.SELF_HOST_MODE==='personal')fail(402,'commercial_license_required');
 const team=await member(env,accountId,teamId),paid=await provider(env,team,b);
 if(requirePaid&&!paid.active)fail(402,'team_subscription_required');
 // Recheck membership after provider I/O; callers must repeat this predicate in write SQL.
 const current=await member(env,accountId,teamId);
 return {team:current,role:current.role,capacity:paid.capacity,period_end:paid.period_end,active:paid.active};
}
export async function teamAccountDeletionGuard(env:{DB:D1Database},accountId:string){if(await env.DB.prepare("SELECT team_id FROM team_members WHERE account_id=? AND role='owner' LIMIT 1").bind(accountId).first())fail(409,'transfer_or_delete_team');}
async function lease<T>(env:TeamEnv,t:Team,actor:string,operation:(lock:string)=>Promise<T>){
 const lock=random();const row=await env.DB.prepare("UPDATE teams SET billing_lock=?,billing_lock_until=? WHERE id=? AND closing_at IS NULL AND (billing_lock_until IS NULL OR billing_lock_until<=?) AND EXISTS(SELECT 1 FROM team_members WHERE team_id=teams.id AND account_id=? AND role='owner') RETURNING id").bind(lock,now()+120,t.id,now(),actor).first();
 if(!row)fail(409,'team_billing_busy');try{return await operation(lock);}finally{await env.DB.prepare('UPDATE teams SET billing_lock=NULL,billing_lock_until=NULL WHERE id=? AND billing_lock=?').bind(t.id,lock).run();}
}
async function lockValid(env:TeamEnv,id:string,lock:string){if(!await env.DB.prepare('UPDATE teams SET billing_lock_until=? WHERE id=? AND billing_lock=? AND billing_lock_until>? RETURNING id').bind(now()+120,id,lock,now()).first())fail(409,'team_billing_busy');}
async function audit(env:TeamEnv,id:string,actor:string,action:string,target=''){await env.DB.prepare('INSERT INTO team_audit VALUES(?,?,?,?,?,?)').bind(random(),id,actor,action,target,now()).run();}
const owner=(role:string)=>{if(role!=='owner')fail(403,'team_owner_required');},admin=(role:string)=>{if(!['owner','admin'].includes(role))fail(403,'team_admin_required');};
function paymentUrl(value:unknown){if(typeof value!=='string'||value.length>4096)fail(503,'team_billing_unavailable');let u:URL;try{u=new URL(value);}catch{fail(503,'team_billing_unavailable');}if(u.protocol!=='https:'||u.hostname!=='checkout.stripe.com'||u.username||u.password||u.port)fail(503,'team_billing_unavailable');return value;}
async function price(env:TeamEnv,b:Boundary){if(!configured(env.STRIPE_TEAM_PRICE_ID))fail(503,'team_billing_not_configured');const p=await client(env,b)(`prices/${encodeURIComponent(env.STRIPE_TEAM_PRICE_ID!)}`);if(p.id!==env.STRIPE_TEAM_PRICE_ID||p.active!==true||p.unit_amount!==9900||p.currency!=='usd'||p.recurring?.interval!=='year'||p.recurring.interval_count!==1||p.recurring.usage_type!=='licensed')fail(503,'team_price_mismatch');}
function checkoutFields(env:TeamEnv,t:Team,c:any){return {customer:t.customer_id!,mode:'subscription','line_items[0][price]':c.price_id,'line_items[0][quantity]':String(c.seats),'subscription_data[metadata][team_id]':t.id,'subscription_data[metadata][terms_version]':t.terms_version,success_url:`${env.ORIGIN}/team/payment?status=success`,cancel_url:`${env.ORIGIN}/team/payment?status=canceled`,expires_at:String(c.expires_at)};}
async function restoreCheckout(env:TeamEnv,t:Team,c:any,b:Boundary){const api=client(env,b);return c.session_id?api(`checkout/sessions/${encodeURIComponent(c.session_id)}`):api('checkout/sessions',checkoutFields(env,t,c),c.idempotency_key);}
export async function teamRoute(request:Request,env:TeamEnv,actor:Actor,b:Boundary):Promise<Response>{
 const path=new URL(request.url).pathname,method=request.method;
 if(actor.closing_at!==null)fail(409,'account_deletion_pending');if(env.SELF_HOST_MODE==='personal')fail(402,'commercial_license_required');
 if(path==='/v1/teams/terms'&&method==='GET'){const mode=/^(sk|rk)_test_/.test(env.STRIPE_SECRET_KEY||'')?'test':/^(sk|rk)_live_/.test(env.STRIPE_SECRET_KEY||'')?'live':'unavailable';return json({name:'doinWITH',version:COMMERCIAL_TERMS_VERSION,text:COMMERCIAL_TERMS,amount:9900,currency:'usd',interval:'year',self_hosting:true,billing_mode:configured(env.STRIPE_TEAM_PRICE_ID)?mode:'unavailable',billing_ready:mode!=='unavailable'&&configured(env.STRIPE_TEAM_PRICE_ID),license_ready:!!env.LICENSE_SIGNING_KEY&&!!env.LICENSE_PUBLIC_KEY&&!!env.LICENSE_KEY_ID});}
 if(path==='/v1/teams'&&method==='GET')return json({teams:(await env.DB.prepare('SELECT t.id,t.name,t.deployment,m.role FROM teams t JOIN team_members m ON m.team_id=t.id WHERE m.account_id=? AND t.closing_at IS NULL').bind(actor.id).all()).results});
 if(path==='/v1/teams'&&method==='POST'){
  const d=await b.body(request);if(d.accepted_terms!==COMMERCIAL_TERMS_VERSION)fail(400,'commercial_terms_acceptance_required');
  let id=random();const name=text(d.name,'team_name'),entity=text(d.legal_entity,'legal_entity',200);let deployment=d.deployment??'hosted';if(env.SELF_HOST_MODE==='commercial'){const c=await selfHostLicense(env);if(!env.SELF_HOST_OWNER_EMAIL||actor.email!==env.SELF_HOST_OWNER_EMAIL.trim().toLowerCase())fail(403,'self_host_owner_required');if(entity!==c.legal_entity)fail(400,'licensed_entity_required');id=c.team_id;deployment='self_hosted';if(await env.DB.prepare('SELECT id FROM teams WHERE id=?').bind(id).first())fail(409,'licensed_team_already_created');}if(!['hosted','self_hosted'].includes(deployment))fail(400,'invalid_deployment');
  if((await env.DB.prepare('SELECT count(*) AS n FROM team_members WHERE account_id=?').bind(actor.id).first<{n:number}>())!.n>=100)fail(409,'team_limit');
  await env.DB.batch([env.DB.prepare('INSERT INTO teams(id,name,legal_entity,terms_version,accepted_by,accepted_at,deployment,created_at) VALUES(?,?,?,?,?,?,?,?)').bind(id,name,entity,COMMERCIAL_TERMS_VERSION,actor.id,now(),deployment,now()),env.DB.prepare("INSERT INTO team_members VALUES(?,?,'owner',?)").bind(id,actor.id,now()),env.DB.prepare('INSERT INTO team_documents(team_id,updated_at) VALUES(?,?)').bind(id,now()),env.DB.prepare("INSERT INTO team_folders(team_id,id,parent_id,name,updated_at) VALUES(?,'root',NULL,'Home',?)").bind(id,now())]);
  return json({id,name,legal_entity:entity,deployment,role:'owner',accepted_terms:COMMERCIAL_TERMS_VERSION},201);
 }
 if(path==='/v1/teams/accept'&&method==='POST'){
  const d=await b.body(request);if(typeof d.token!=='string'||!/^[0-9a-f]{64}$/.test(d.token))fail(400,'invalid_invitation');
  const invitation=await env.DB.prepare('SELECT * FROM team_invites WHERE token_hash=? AND email=? AND expires_at>? AND consumed_at IS NULL').bind(await hash(d.token),actor.email,now()).first<any>();if(!invitation)fail(404,'invitation_not_found');
  const t=await env.DB.prepare('SELECT * FROM teams WHERE id=? AND closing_at IS NULL').bind(invitation.team_id).first<Team>();if(!t)fail(404,'invitation_not_found');const paid=await provider(env,t,b);if(!paid.active)fail(402,'team_subscription_required');
  const claim=random();await env.DB.batch([
   env.DB.prepare("UPDATE team_invites SET claim=? WHERE id=? AND consumed_at IS NULL AND expires_at>? AND email=? AND EXISTS(SELECT 1 FROM team_members WHERE team_id=team_invites.team_id AND account_id=team_invites.inviter AND role IN ('owner','admin') AND (team_invites.role='member' OR role='owner')) AND EXISTS(SELECT 1 FROM team_folders WHERE team_id=team_invites.team_id AND id=team_invites.folder_id)").bind(claim,invitation.id,now(),actor.email),
   env.DB.prepare('INSERT INTO team_members(team_id,account_id,role,joined_at) SELECT i.team_id,?,i.role,? FROM team_invites i JOIN teams t ON t.id=i.team_id WHERE i.id=? AND i.claim=? AND i.consumed_at IS NULL AND t.closing_at IS NULL AND t.period_end>? AND t.billing_lock IS NULL AND ((SELECT count(*) FROM team_members WHERE team_id=t.id)<MIN(t.capacity,t.next_capacity) OR EXISTS(SELECT 1 FROM team_members WHERE team_id=t.id AND account_id=?)) ON CONFLICT(team_id,account_id) DO NOTHING').bind(actor.id,now(),invitation.id,claim,now(),actor.id),
   env.DB.prepare("INSERT INTO team_folder_grants(team_id,folder_id,account_id,access) SELECT i.team_id,i.folder_id,?,i.folder_access FROM team_invites i WHERE i.id=? AND i.claim=? AND i.consumed_at IS NULL AND EXISTS(SELECT 1 FROM team_members WHERE team_id=i.team_id AND account_id=?) AND EXISTS(SELECT 1 FROM team_members WHERE team_id=i.team_id AND account_id=i.inviter AND role IN ('owner','admin') AND (i.role='member' OR role='owner')) ON CONFLICT(team_id,folder_id,account_id) DO UPDATE SET access=excluded.access").bind(actor.id,invitation.id,claim,actor.id),
   env.DB.prepare('UPDATE team_invites SET consumed_at=? WHERE id=? AND claim=? AND EXISTS(SELECT 1 FROM team_members WHERE team_id=team_invites.team_id AND account_id=?)').bind(now(),invitation.id,claim,actor.id)
  ]);
  if(!await env.DB.prepare('SELECT id FROM team_invites WHERE id=? AND claim=? AND consumed_at IS NOT NULL').bind(invitation.id,claim).first())fail(409,'team_seats_full');
  return json({joined:true,team_id:t.id});
 }
 const roster=/^\/v1\/teams\/([a-zA-Z0-9-]{1,80})\/folders\/([a-zA-Z0-9-]{1,80})\/members$/.exec(path);
 if(roster&&method==='GET'){
  const teamId=roster[1],folderId=roster[2];await folderAccess(env,teamId,actor.id,folderId);
  const rows=(await env.DB.prepare(`WITH RECURSIVE ancestors(id,parent_id) AS (SELECT id,parent_id FROM team_folders WHERE team_id=? AND id=? UNION SELECT f.id,f.parent_id FROM team_folders f JOIN ancestors p ON f.id=p.parent_id WHERE f.team_id=?) SELECT m.account_id,m.role,a.email,a.name FROM team_members m JOIN accounts a ON a.id=m.account_id WHERE m.team_id=? AND a.closing_at IS NULL AND (m.role IN ('owner','admin') OR EXISTS(SELECT 1 FROM team_folder_grants g JOIN ancestors p ON p.id=g.folder_id WHERE g.team_id=m.team_id AND g.account_id=m.account_id)) AND EXISTS(SELECT 1 FROM team_members caller JOIN teams t ON t.id=caller.team_id WHERE caller.team_id=? AND caller.account_id=? AND t.closing_at IS NULL AND (caller.role IN ('owner','admin') OR EXISTS(SELECT 1 FROM team_folder_grants cg JOIN ancestors cp ON cp.id=cg.folder_id WHERE cg.team_id=caller.team_id AND cg.account_id=caller.account_id))) ORDER BY a.email LIMIT 10001`).bind(teamId,folderId,teamId,teamId,teamId,actor.id).all()).results;
  if(rows.length>10000)fail(503,'team_member_limit');return json({team_id:teamId,folder_id:folderId,members:rows});
 }
 if(/^\/v1\/teams\/[a-zA-Z0-9-]{1,80}\/folders(?:\/|$)/.test(path)){const teamId=path.split('/')[3];return foldersRoute(request,env,actor,{body:b.body,paid:()=>teamAccess(env,actor.id,teamId,true,b)});}
 const match=/^\/v1\/teams\/([a-zA-Z0-9-]{1,80})(?:\/(.*))?$/.exec(path);if(!match)fail(404,'not_found');const id=match[1],action=match[2]??'',m=await member(env,actor.id,id),api=client(env,b);
 if(env.SELF_HOST_MODE==='commercial'&&['checkout','seats','seats/reset','recover','cancel','resume'].includes(action))fail(409,'manage_license_on_official_service');
 if(action==='members'&&method==='GET')return json({members:(await env.DB.prepare('SELECT m.account_id,m.role,a.email,a.name FROM team_members m JOIN accounts a ON a.id=m.account_id WHERE team_id=?').bind(id).all()).results});
 if(action==='audit'&&method==='GET'){admin(m.role);return json({events:(await env.DB.prepare('SELECT actor,action,target,created_at FROM team_audit WHERE team_id=? ORDER BY created_at DESC LIMIT 200').bind(id).all()).results});}
 if(action==='invites'&&method==='GET'){admin(m.role);return json({invitations:(await env.DB.prepare('SELECT id,email,role,expires_at,consumed_at FROM team_invites WHERE team_id=? ORDER BY expires_at DESC LIMIT 200').bind(id).all()).results});}
 if(action==='invites/revoke'&&method==='POST'){admin(m.role);const d=await b.body(request);const invite=text(d.invitation_id,'invitation_id',80);await env.DB.prepare("DELETE FROM team_invites WHERE team_id=? AND id=? AND EXISTS(SELECT 1 FROM team_members WHERE team_id=? AND account_id=? AND role IN ('owner','admin'))").bind(id,invite,id,actor.id).run();return json({revoked:true});}
 if(action==='invites'&&method==='POST'){
  admin(m.role);const d=await b.body(request),email=b.emailAddress?b.emailAddress(d.email):text(d.email,'email',254).toLowerCase(),role=d.role??'member';if(!['admin','member'].includes(role)||(role==='admin'&&m.role!=='owner'))fail(403,'invalid_invite_role');
  const paid=await provider(env,m,b);if(!paid.active)fail(402,'team_subscription_required');const folderId=d.folder_id??'root',folderAccessMode=d.folder_access??'read';if(typeof folderId!=='string'||!['read','write'].includes(folderAccessMode))fail(400,'invalid_folder_scope');await folderAccess(env,id,actor.id,folderId,folderAccessMode==='write');if(role==='admin'&&d.ack_admin_global!==true)fail(400,'admin_global_access_acknowledgement_required');
  const hour=Math.floor(now()/3600);const rate=await env.DB.prepare('INSERT INTO rate_limits(key,hits,expires_at) VALUES(?,1,?) ON CONFLICT(key) DO UPDATE SET hits=hits+1 RETURNING hits').bind(`team-invite:${id}:${hour}`,now()+3600).first<{hits:number}>();if(!rate||rate.hits>30)fail(429,'team_invitation_rate_limit');
  const pending=(await env.DB.prepare('SELECT count(*) AS n FROM team_invites WHERE team_id=? AND consumed_at IS NULL AND expires_at>?').bind(id,now()).first<{n:number}>())!.n;if(pending>=100)fail(409,'team_invitation_limit');
  const token=Array.from(crypto.getRandomValues(new Uint8Array(32)),v=>v.toString(16).padStart(2,'0')).join(''),invite=random();
  const inserted=await env.DB.prepare("INSERT INTO team_invites(id,team_id,email,role,token_hash,inviter,expires_at,folder_id,folder_access) SELECT ?,?,?,?,?,?,?,?,? WHERE EXISTS(SELECT 1 FROM team_members WHERE team_id=? AND account_id=? AND role IN ('owner','admin') AND (?='member' OR role='owner')) RETURNING id").bind(invite,id,email,role,await hash(token),actor.id,now()+86400,folderId,folderAccessMode,id,actor.id,role).first();if(!inserted)fail(409,'team_access_revoked');
  try{await env.EMAIL.send({to:email,from:env.EMAIL_FROM,subject:`Invitation to doin team ${m.name}`,text:`${actor.email} invited you to ${m.name}. Sign in to doin using this email, then run doin team accept and paste this token when prompted:\n${token}\nThis invitation expires in 24 hours. It grants no access until accepted and a paid seat is available. Ignore it if unexpected.`});}catch{await env.DB.prepare('DELETE FROM team_invites WHERE id=? AND consumed_at IS NULL').bind(invite).run();fail(503,'email_unavailable');}
  return json({invitation_id:invite,expires_in:86400});
 }
 if(action==='members/remove'&&method==='POST'){
  admin(m.role);const d=await b.body(request),target=text(d.account_id,'account_id',80);
  const removed=await env.DB.batch([
   env.DB.prepare("DELETE FROM team_invites WHERE team_id=? AND (email=(SELECT email FROM accounts WHERE id=?) OR inviter=?) AND EXISTS(SELECT 1 FROM team_members WHERE team_id=? AND account_id=? AND role!='owner' AND (role='member' OR EXISTS(SELECT 1 FROM team_members WHERE team_id=? AND account_id=? AND role='owner'))) AND EXISTS(SELECT 1 FROM team_members WHERE team_id=? AND account_id=? AND role IN ('owner','admin'))").bind(id,target,target,id,target,id,actor.id,id,actor.id),
   env.DB.prepare("UPDATE mcp_auth_grants SET revoked_at=COALESCE(revoked_at,?) WHERE team_id=? AND account_id=? AND EXISTS(SELECT 1 FROM team_members WHERE team_id=? AND account_id=? AND role!='owner' AND (role='member' OR EXISTS(SELECT 1 FROM team_members WHERE team_id=? AND account_id=? AND role='owner'))) AND EXISTS(SELECT 1 FROM team_members WHERE team_id=? AND account_id=? AND role IN ('owner','admin'))").bind(now(),id,target,id,target,id,actor.id,id,actor.id),
   env.DB.prepare("DELETE FROM team_members WHERE team_id=? AND account_id=? AND role!='owner' AND (role='member' OR EXISTS(SELECT 1 FROM team_members WHERE team_id=? AND account_id=? AND role='owner')) AND EXISTS(SELECT 1 FROM team_members WHERE team_id=? AND account_id=? AND role IN ('owner','admin')) RETURNING account_id").bind(id,target,id,actor.id,id,actor.id)
  ]);if(!removed[2].results.length)fail(409,'owner_or_member_unavailable');await audit(env,id,actor.id,'remove_member',target);return json({removed:true});
 }
 if(action==='leave'&&method==='POST'){if(m.role==='owner')fail(409,'transfer_or_delete_team');const left=await env.DB.batch([env.DB.prepare("DELETE FROM team_invites WHERE team_id=? AND (email=? OR inviter=?) AND EXISTS(SELECT 1 FROM team_members WHERE team_id=? AND account_id=? AND role!='owner')").bind(id,actor.email,actor.id,id,actor.id),env.DB.prepare("UPDATE mcp_auth_grants SET revoked_at=COALESCE(revoked_at,?) WHERE team_id=? AND account_id=? AND EXISTS(SELECT 1 FROM team_members WHERE team_id=? AND account_id=? AND role!='owner')").bind(now(),id,actor.id,id,actor.id),env.DB.prepare("DELETE FROM team_members WHERE team_id=? AND account_id=? AND role!='owner' RETURNING account_id").bind(id,actor.id)]);if(!left[2].results.length)fail(409,'transfer_or_delete_team');return json({left:true});}
 if(action==='transfer'&&method==='POST'){
  owner(m.role);const d=await b.body(request),target=text(d.account_id,'account_id',80);if(target===actor.id)fail(400,'different_owner_required');
  // The owner change and target-existence predicate run in one D1 transaction.
  return lease(env,m,actor.id,async()=>{if(!await member(env,target,id))fail(404,'member_not_found');await env.DB.batch([env.DB.prepare("UPDATE team_members SET role='admin' WHERE team_id=? AND account_id=? AND role='owner' AND EXISTS(SELECT 1 FROM team_members m JOIN accounts a ON a.id=m.account_id WHERE m.team_id=? AND m.account_id=? AND a.closing_at IS NULL)").bind(id,actor.id,id,target),env.DB.prepare("UPDATE team_members SET role='owner' WHERE team_id=? AND account_id=? AND NOT EXISTS(SELECT 1 FROM team_members WHERE team_id=? AND role='owner') AND EXISTS(SELECT 1 FROM accounts WHERE id=? AND closing_at IS NULL)").bind(id,target,id,target)]);await audit(env,id,actor.id,'transfer_owner',target);return json({owner:target});});
 }
 if((action==='document'||action==='export')&&method==='GET')return json(await documentRead(env,id,actor.id,'root'));
 if(action==='document'&&method==='PUT'){await teamAccess(env,actor.id,id,true,b);await folderAccess(env,id,actor.id,'root',true);const d=await b.body(request,1048576);return json(await documentWrite(env,id,actor.id,'root',d.revision,d.content));}
 if(action==='billing'&&method==='GET'){owner(m.role);const p=await provider(env,m,b);return json({active:p.active,paid_seats:p.capacity,next_renewal_seats:p.subscription?.items.data[0].quantity??p.capacity,current_period_end:p.period_end,status:env.SELF_HOST_MODE==='commercial'?'licensed':p.subscription?.status??'none',cancel_at_period_end:p.subscription?.cancel_at_period_end??false,occupied_seats:(await env.DB.prepare('SELECT count(*) AS n FROM team_members WHERE team_id=?').bind(id).first<{n:number}>())!.n,pending_update:!!p.subscription?.pending_update});}
 if(action==='recover'&&method==='POST'){owner(m.role);const p=await provider(env,m,b);const invoiceId=p.subscription?.latest_invoice;if(typeof invoiceId!=='string'||!/^in_/.test(invoiceId))fail(409,'no_team_payment_to_recover');const invoice=await api(`invoices/${encodeURIComponent(invoiceId)}`);if(invoice.customer!==m.customer_id||invoice.status!=='open'||typeof invoice.hosted_invoice_url!=='string')fail(409,'no_team_payment_to_recover');let u:URL;try{u=new URL(invoice.hosted_invoice_url);}catch{fail(503,'team_billing_unavailable');}if(u.protocol!=='https:'||u.hostname!=='invoice.stripe.com'||u.username||u.password||u.port)fail(503,'team_billing_unavailable');return json({url:invoice.hosted_invoice_url});}
 if(action==='receipt'&&method==='GET'){owner(m.role);const p=await provider(env,m,b);if(!p.active)fail(402,'team_subscription_required');if(env.SELF_HOST_MODE==='commercial')return json({receipt:env.COMMERCIAL_LICENSE_RECEIPT,environment:'live',expires_at:p.period_end});return json(await issueLicense(env,{team_id:id,legal_entity:m.legal_entity,seats:p.capacity,expires_at:p.period_end}));}
 if(action==='checkout'&&method==='POST'){
  owner(m.role);const d=await b.body(request),seats=count(d.seats);if(d.accepted_terms!==COMMERCIAL_TERMS_VERSION)fail(400,'commercial_terms_acceptance_required');
  return lease(env,m,actor.id,async lock=>{
   await price(env,b);const p=await provider(env,m,b);if(p.subscription)fail(409,'manage_existing_team_subscription');
   if(!m.customer_id){const customer=await api('customers',{email:actor.email,name:m.legal_entity,'metadata[team_id]':id},`doin-team-customer-${id}`);if(typeof customer.id!=='string'||!/^cus_/.test(customer.id))fail(503,'team_billing_unavailable');await lockValid(env,id,lock);await env.DB.prepare('UPDATE teams SET customer_id=? WHERE id=? AND billing_lock=?').bind(customer.id,id,lock).run();m.customer_id=customer.id;}
   let c=await env.DB.prepare('SELECT * FROM team_checkouts WHERE team_id=?').bind(id).first<any>();
   if(c&&c.expires_at<=now()&&!c.session_id){await env.DB.prepare('DELETE FROM team_checkouts WHERE team_id=? AND idempotency_key=?').bind(id,c.idempotency_key).run();c=null;}
   if(c){const previous=await restoreCheckout(env,m,c,b);if(previous.customer!==m.customer_id||!['open','expired','complete'].includes(previous.status))fail(503,'team_billing_unavailable');if(previous.status==='complete')fail(409,'manage_existing_team_subscription');if(previous.status==='open'&&c.seats===seats&&c.price_id===env.STRIPE_TEAM_PRICE_ID)return json({url:paymentUrl(previous.url),seats});if(previous.status==='open'){const expired=await api(`checkout/sessions/${encodeURIComponent(previous.id)}/expire`,{},`doin-team-expire-${c.idempotency_key}`);if(expired.status!=='expired')fail(409,'checkout_not_expired');}await lockValid(env,id,lock);await env.DB.prepare('DELETE FROM team_checkouts WHERE team_id=? AND idempotency_key=?').bind(id,c.idempotency_key).run();}
   c={idempotency_key:`doin-team-checkout-${random()}`,price_id:env.STRIPE_TEAM_PRICE_ID,seats,expires_at:now()+3600};await env.DB.prepare('INSERT INTO team_checkouts(team_id,idempotency_key,price_id,seats,expires_at) VALUES(?,?,?,?,?)').bind(id,c.idempotency_key,c.price_id,c.seats,c.expires_at).run();
   const session=await api('checkout/sessions',checkoutFields(env,m,c),c.idempotency_key);if(typeof session.id!=='string'||!/^cs_/.test(session.id)||session.customer!==m.customer_id||session.status!=='open')fail(503,'team_billing_unavailable');await lockValid(env,id,lock);await env.DB.prepare('UPDATE team_checkouts SET session_id=?,url=? WHERE team_id=? AND idempotency_key=?').bind(session.id,paymentUrl(session.url),id,c.idempotency_key).run();return json({url:session.url,seats});
  });
 }
 if(action==='seats'&&method==='POST'){
  owner(m.role);const d=await b.body(request),seats=count(d.seats);
  return lease(env,m,actor.id,async lock=>{
   const p=await provider(env,m,b);if(!p.active||!p.subscription)fail(402,'team_subscription_required');const s=p.subscription,item=s.items.data.find((i:any)=>i.price.id===env.STRIPE_TEAM_PRICE_ID);
   const occupied=(await env.DB.prepare('SELECT count(*) AS n FROM team_members WHERE team_id=?').bind(id).first<{n:number}>())!.n;if(seats<occupied)fail(409,'remove_members_before_seat_reduction');
   if(s.pending_update)fail(409,'seat_payment_pending');if(seats>p.capacity&&item.quantity<p.capacity)fail(409,'restore_paid_capacity_before_adding_seats');
   let op=await env.DB.prepare('SELECT * FROM team_seat_operations WHERE team_id=? AND completed=0').bind(id).first<any>();if(op&&op.seats!==seats)fail(409,'seat_change_pending');
   if(seats===item.quantity){if(op)await env.DB.prepare('UPDATE team_seat_operations SET completed=1 WHERE team_id=?').bind(id).run();return json({paid_seats:p.capacity,next_renewal_seats:seats,changed:false});}
   const date=op?.proration_date??(Number.isSafeInteger(d.proration_date)&&Math.abs(now()-d.proration_date)<300?d.proration_date:now());
   if(seats>p.capacity){const preview=await api('invoices/create_preview',{customer:m.customer_id!,subscription:s.id,'subscription_details[items][0][id]':item.id,'subscription_details[items][0][quantity]':String(seats),'subscription_details[proration_date]':String(date),'subscription_details[proration_behavior]':'always_invoice'});if(!Number.isSafeInteger(preview.amount_due)||preview.amount_due<0||preview.currency!=='usd')fail(503,'invalid_seat_preview');if(d.confirm_amount!==preview.amount_due||d.proration_date!==date)return json({confirmation_required:true,amount_due:preview.amount_due,currency:'usd',proration_date:date,seats});}
   else if(d.confirm_renewal_reduction!==true)return json({confirmation_required:true,renewal_only:true,no_refund:true,restoring_paid_capacity:seats>item.quantity,seats,current_period_end:p.period_end});
   if(!op){op={idempotency_key:`doin-team-seats-${random()}`,seats,proration_date:date};await env.DB.prepare('INSERT INTO team_seat_operations(team_id,idempotency_key,seats,proration_date,completed) VALUES(?,?,?,?,0) ON CONFLICT(team_id) DO UPDATE SET idempotency_key=excluded.idempotency_key,seats=excluded.seats,proration_date=excluded.proration_date,completed=0 WHERE team_seat_operations.completed=1').bind(id,op.idempotency_key,seats,date).run();}
   const fields:Record<string,string>={'items[0][id]':item.id,'items[0][quantity]':String(seats),proration_behavior:seats>p.capacity?'always_invoice':'none',payment_behavior:'pending_if_incomplete',...(seats>p.capacity?{proration_date:String(op.proration_date)}:{})};
   await lockValid(env,id,lock);await api(`subscriptions/${encodeURIComponent(s.id)}`,fields,op.idempotency_key);await lockValid(env,id,lock);const refreshed=await provider(env,m,b);if(refreshed.subscription?.items.data.find((i:any)=>i.price.id===env.STRIPE_TEAM_PRICE_ID)?.quantity===seats&&!refreshed.subscription.pending_update)await env.DB.prepare('UPDATE team_seat_operations SET completed=1 WHERE team_id=? AND idempotency_key=?').bind(id,op.idempotency_key).run();return json({paid_seats:refreshed.capacity,next_renewal_seats:refreshed.subscription?.items.data[0].quantity,payment_pending:!!refreshed.subscription?.pending_update});
  });
 }
 if(action==='seats/reset'&&method==='POST'){owner(m.role);return lease(env,m,actor.id,async()=>{const p=await provider(env,m,b);if(!p.subscription)fail(409,'no_team_subscription');const item=p.subscription.items.data.find((i:any)=>i.price.id===env.STRIPE_TEAM_PRICE_ID);await api(`subscriptions/${encodeURIComponent(p.subscription.id)}`,{'items[0][id]':item.id,'items[0][quantity]':String(item.quantity),proration_behavior:'none',payment_behavior:'pending_if_incomplete'},`doin-team-seat-reset-${id}-${random()}`);const fresh=await provider(env,m,b);if(fresh.subscription?.pending_update)fail(409,'seat_payment_pending');await env.DB.prepare('UPDATE team_seat_operations SET completed=1 WHERE team_id=?').bind(id).run();return json({reset:true});});}
 if(['cancel','resume'].includes(action)&&method==='POST'){owner(m.role);return lease(env,m,actor.id,async()=>{const p=await provider(env,m,b);if(!p.subscription)fail(409,'no_team_subscription');await api(`subscriptions/${encodeURIComponent(p.subscription.id)}`,{cancel_at_period_end:String(action==='cancel')},`doin-team-${action}-${id}-${random()}`);return json({cancel_at_period_end:action==='cancel'});});}
 if(action===''&&method==='DELETE'){
  owner(m.role);return lease(env,m,actor.id,async lock=>{
   const c=await env.DB.prepare('SELECT * FROM team_checkouts WHERE team_id=?').bind(id).first<any>();if(env.SELF_HOST_MODE!=='commercial'&&c&&(c.session_id||c.expires_at>now())){const s=await restoreCheckout(env,m,c,b);if(s.customer!==m.customer_id)fail(503,'team_billing_unavailable');if(s.status==='open'){const e=await api(`checkout/sessions/${encodeURIComponent(s.id)}/expire`,{},`doin-team-delete-expire-${id}`);if(e.status!=='expired')fail(409,'checkout_not_expired');}}
   const p=await provider(env,m,b);if(p.subscription)await api(`subscriptions/${encodeURIComponent(p.subscription.id)}`,undefined,`doin-team-delete-${id}`,'DELETE');await lockValid(env,id,lock);await env.DB.prepare('DELETE FROM teams WHERE id=? AND billing_lock=?').bind(id,lock).run();return json({deleted:true});
  });
 }
 fail(404,'not_found');
}
