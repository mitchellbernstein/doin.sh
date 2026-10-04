import {Client,StreamableHTTPClientTransport} from '@modelcontextprotocol/client';
import {providerBearer} from './mcp-oauth';
import {CfWorkerJsonSchemaValidator} from '@modelcontextprotocol/client/validators/cf-worker';

export type Env={DB:D1Database;ORIGIN:string;MCP_ENCRYPTION_KEY?:string};
export type Owner={id:string;token_hash:string;closing_at:number|null};
export type Connection={account_id:string;name:string;id:string;url:string;token_ciphertext:string|null;created_at:number;auth_type?:string;team_id?:string|null};
export type Boundary={body:(request:Request,max?:number)=>Promise<any>;subscribed:(teamId?:string)=>Promise<boolean>};
const encoder=new TextEncoder(),decoder=new TextDecoder('utf-8',{fatal:true});
const json=(value:unknown,status=200)=>Response.json(value,{status});
const fail=(status:number,error:string):never=>{throw json({error},status);};
const now=()=>Math.floor(Date.now()/1000);
const validName=(name:unknown):name is string=>typeof name==='string'&&/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(name);
function safeHost(host:string){
 if(!/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/.test(host)||host==='doin.sh'||host.endsWith('.doin.sh')||/(^|\.)(localhost|local|internal|lan|home|invalid|test)$/.test(host))fail(400,'public_https_endpoint_required');
}
export function endpoint(value:unknown):URL{
 if(typeof value!=='string'||value.length>2048)fail(400,'public_https_endpoint_required');
 let url:URL;try{url=new URL(value);}catch{fail(400,'public_https_endpoint_required');}
 if(url.protocol!=='https:'||url.port||url.username||url.password||url.search||url.hash)fail(400,'public_https_endpoint_required');
 safeHost(url.hostname);return url;
}
function publicAddress(value:string):boolean{
 if(/^\d+\.\d+\.\d+\.\d+$/.test(value)){
  const p=value.split('.').map(Number);if(p.some(v=>v>255))return false;const[a,b,c]=p;
  return !(a===0||a===10||a===127||a>=224||(a===100&&b>=64&&b<=127)||(a===169&&b===254)||(a===172&&b>=16&&b<=31)||(a===192&&(b===168||(b===0&&(c===0||c===2))||(b===88&&c===99)))||(a===198&&(b===18||b===19||(b===51&&c===100)))||(a===203&&b===0&&c===113));
 }
 if(!/^[0-9a-f:]+$/i.test(value))return false;
 try{const normalized=new URL(`https://[${value}]/`).hostname.slice(1,-1);const first=parseInt(normalized.split(':')[0],16),second=parseInt(normalized.split(':')[1]||'0',16);
  return first>=0x2000&&first<=0x3ffe&&first!==0x2002&&!(first===0x2001&&(second<0x200||second===0xdb8));
 }catch{return false;}
}
export async function bytes(response:Pick<Response,'body'>,max:number,signal:AbortSignal):Promise<Uint8Array>{
 const reader=response.body?.getReader();if(!reader)return new Uint8Array();let size=0;const parts:Uint8Array[]=[];
 const abort=()=>{void reader.cancel().catch(()=>{});};signal.addEventListener('abort',abort,{once:true});
 try{while(true){if(signal.aborted)throw signal.reason;const {done,value}=await reader.read();if(done)break;size+=value.byteLength;if(size>max)fail(502,'integration_response_too_large');parts.push(value);}}
 finally{signal.removeEventListener('abort',abort);if(signal.aborted||size>max)await reader.cancel().catch(()=>{});reader.releaseLock();}
 const output=new Uint8Array(size);let offset=0;for(const part of parts){output.set(part,offset);offset+=part.length;}return output;
}
function boundedStream(body:ReadableStream<Uint8Array>,max:number,signal:AbortSignal){
 const reader=body.getReader();let size=0,closed=false;let abort:()=>void;
 const finish=()=>{if(closed)return;closed=true;signal.removeEventListener('abort',abort);};
 return new ReadableStream<Uint8Array>({
  start(controller){abort=()=>{if(closed)return;finish();controller.error(new Error('integration_deadline'));void reader.cancel().catch(()=>{});};signal.addEventListener('abort',abort,{once:true});if(signal.aborted)abort();},
  async pull(controller){try{const {done,value}=await reader.read();if(closed)return;if(done){finish();controller.close();return;}size+=value.byteLength;if(size>max){finish();controller.error(new Error('integration_response_too_large'));await reader.cancel();return;}controller.enqueue(value);}catch{if(!closed){finish();controller.error(new Error('integration_stream_failed'));}}},
  async cancel(){finish();await reader.cancel().catch(()=>{});}
 });
}
export async function publicDns(url:URL,signal:AbortSignal){
 const records=await Promise.all(['A','AAAA'].map(async type=>{
  const query=new URL('https://cloudflare-dns.com/dns-query');query.searchParams.set('name',url.hostname);query.searchParams.set('type',type);
  const response=await fetch(query,{headers:{accept:'application/dns-json'},redirect:'manual',signal});if(!response.ok){await response.body?.cancel();fail(503,'integration_dns_unavailable');}
  let data:any;try{data=JSON.parse(decoder.decode(await bytes(response,32768,signal)));}catch(error){if(error instanceof Response)throw error;fail(503,'integration_dns_unavailable');}
  if(data.Status!==0||!Array.isArray(data.Answer??[]))fail(503,'integration_dns_unavailable');return data.Answer??[];
 }));
 const addresses:string[]=[];
 for(const record of records.flat()){
  if(record.type===5){if(typeof record.data!=='string')fail(400,'public_https_endpoint_required');safeHost(record.data.replace(/\.$/,''));}
  if(record.type===1||record.type===28){if(typeof record.data!=='string'||!publicAddress(record.data))fail(400,'public_https_endpoint_required');addresses.push(record.data);}
 }
 if(!addresses.length)fail(503,'integration_dns_unavailable');
}
export async function key(env:Env){
 if(!/^[0-9a-f]{64}$/.test(env.MCP_ENCRYPTION_KEY||''))fail(503,'integration_credentials_unavailable');
 return crypto.subtle.importKey('raw',Uint8Array.from(env.MCP_ENCRYPTION_KEY!.match(/../g)!,v=>parseInt(v,16)),{name:'AES-GCM'},false,['encrypt','decrypt']);
}
const aad=(c:Connection)=>encoder.encode(JSON.stringify([c.account_id,c.name,c.id,c.url,...(c.team_id?[c.team_id]:[])]));
const hex=(bytes:Uint8Array)=>Array.from(bytes,v=>v.toString(16).padStart(2,'0')).join('');
async function seal(env:Env,c:Connection,token:string){const iv=crypto.getRandomValues(new Uint8Array(12));const encrypted=await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:aad(c)},await key(env),encoder.encode(token));return hex(iv)+hex(new Uint8Array(encrypted));}
async function open(env:Env,c:Connection){
 if(!c.token_ciphertext)return undefined;
 try{if(!/^[0-9a-f]{58,8250}$/.test(c.token_ciphertext)||c.token_ciphertext.length%2)fail(503,'integration_credentials_unavailable');const b=Uint8Array.from(c.token_ciphertext.match(/../g)!,v=>parseInt(v,16));return decoder.decode(await crypto.subtle.decrypt({name:'AES-GCM',iv:b.slice(0,12),additionalData:aad(c)},await key(env),b.slice(12)));}
 catch{fail(503,'integration_credentials_unavailable');}
}
function safeSchema(schema:unknown){
 let nodes=0;
 const visit=(value:unknown,depth:number)=>{if(++nodes>512||depth>20)fail(502,'integration_schema_too_complex');if(!value||typeof value!=='object')return;
  for(const [key,child] of Object.entries(value)){if(key==='pattern'||key==='patternProperties')fail(502,'integration_schema_regex_unsupported');if(key==='$ref'&&typeof child==='string'&&!child.startsWith('#'))fail(502,'integration_schema_reference_unsupported');visit(child,depth+1);}
 };visit(schema,0);
}
const metadata=(c:Connection)=>({name:c.name,url:c.url,authenticated:!!c.token_ciphertext||c.auth_type==='oauth',authentication:c.auth_type==='oauth'?'oauth':c.token_ciphertext?'bearer':'none',created_at:c.created_at,license:c.team_id?'team':'personal',team_id:c.team_id??null});
async function exists(env:Env,who:Owner,c:Connection){
 const active=await env.DB.prepare("SELECT c.id FROM mcp_connections c JOIN accounts a ON a.id=c.account_id JOIN sessions s ON s.account_id=a.id WHERE c.account_id=? AND c.id=? AND a.closing_at IS NULL AND s.token_hash=? AND s.kind='device' AND s.expires_at>? AND (c.team_id IS NULL OR EXISTS(SELECT 1 FROM team_members m JOIN teams t ON t.id=m.team_id WHERE t.id=c.team_id AND m.account_id=a.id AND t.closing_at IS NULL AND t.capacity>0 AND t.period_end>?))").bind(who.id,c.id,who.token_hash,now(),now()).first();
 if(!active)fail(409,'integration_revoked');
}
async function remote(env:Env,who:Owner,c:Connection,deadline:AbortSignal,call?:{tool:string;arguments:Record<string,unknown>}){
 const url=endpoint(c.url),credential=c.auth_type==='oauth'?await providerBearer(env,c):await open(env,c),requests=new Map<string,number>();
 const securedFetch=async(input:RequestInfo|URL,init?:RequestInit)=>{
  const request=new Request(input,init);if(request.url!==url.href||!['POST','GET','DELETE'].includes(request.method))fail(502,'integration_endpoint_changed');
  if(request.method!=='DELETE')await exists(env,who,c);const signal=AbortSignal.any([deadline,request.signal,AbortSignal.timeout(8000)]);await publicDns(url,signal);
  // Mutation POSTs are never retried, even if a provider redirects or authentication fails.
  if(request.method==='POST'){
   const message=await request.clone().json() as any;const signature=JSON.stringify([message.method,message.id]);const count=(requests.get(signature)||0)+1;requests.set(signature,count);if(count>1)fail(502,'integration_retry_denied');
  }
  const headers=new Headers();for(const name of ['content-type','accept','mcp-session-id','mcp-protocol-version']){const value=request.headers.get(name);if(value)headers.set(name,value);}
  if(credential)headers.set('authorization',`Bearer ${credential}`);
  const response=await fetch(url,{method:request.method,headers,body:request.body,redirect:'manual',signal});
  if(response.status>=300&&response.status<400){await response.body?.cancel();fail(502,'integration_redirect_denied');}
  if(response.status===401||response.status===403){await response.body?.cancel();fail(502,'integration_authentication_required');}
  if(!response.ok&&response.status!==405){await response.body?.cancel();fail(502,'integration_unavailable');}
  if(!response.body||[202,204,405].includes(response.status)){await response.body?.cancel();return new Response(null,{status:response.status,headers:response.headers});}
  const contentType=response.headers.get('content-type')||'';
  if(!contentType.startsWith('application/json')&&!contentType.startsWith('text/event-stream')){await response.body.cancel();fail(502,'integration_invalid_response');}
  return new Response(boundedStream(response.body,524288,signal),{status:response.status,headers:response.headers});
 };
 const transport=new StreamableHTTPClientTransport(url,{fetch:securedFetch,requestInit:{redirect:'manual'},redirectPolicy:'follow',onInsufficientScope:'throw',maxStepUpRetries:0,reconnectionOptions:{maxRetries:0,initialReconnectionDelay:1000,maxReconnectionDelay:1000,reconnectionDelayGrowFactor:1}});
 const client=new Client({name:'doin-hosted',version:'0.2.4'},{capabilities:{},versionNegotiation:{mode:'legacy'},jsonSchemaValidator:new CfWorkerJsonSchemaValidator()});
 try{
  await client.connect(transport,{timeout:8000,signal:deadline});
  if(!client.getServerCapabilities()?.tools)fail(502,'integration_tools_unavailable');
  const tools:any[]=[],cursors=new Set<string>();let cursor:string|undefined;
  for(let page=0;page<8;page++){
   const result=await client.request({method:'tools/list',params:cursor===undefined?{}:{cursor}},{timeout:8000,signal:deadline});tools.push(...result.tools);if(tools.length>128||encoder.encode(JSON.stringify(tools)).length>524288)fail(502,'integration_catalog_too_large');
   cursor=result.nextCursor;if(cursor===undefined)break;if(cursors.has(cursor)||page===7)fail(502,'integration_catalog_too_large');cursors.add(cursor);
  }
  if(!call)return json({connection:metadata(c),tools});
  const tool=tools.find(t=>t.name===call.tool);if(!tool)fail(400,'integration_tool_not_found');safeSchema(tool.inputSchema);if(tool.outputSchema)safeSchema(tool.outputSchema);
  const validate=new CfWorkerJsonSchemaValidator().getValidator(tool.inputSchema);if(!validate(call.arguments).valid)fail(400,'integration_arguments_invalid');
  const result=await client.callTool({name:call.tool,arguments:call.arguments},{timeout:8000,signal:deadline,toolDefinition:tool});
  return json({connection:metadata(c),result});
 }catch(error){if(error instanceof Response)throw error;fail(502,'integration_unavailable');}
 finally{
  try{await transport.terminateSession();}catch{/* provider may be offline or connection revoked */}
  await client.close().catch(()=>{});
 }
}
export async function mcpRoute(request:Request,env:Env,who:Owner,boundary:Boundary):Promise<Response>{
 const deadline=AbortSignal.timeout(15000);
 const path=new URL(request.url).pathname.slice('/v1/mcp/connections'.length),parts=path.split('/').filter(Boolean);
 // Credential revocation remains available after expiry or a billing outage.
 if(parts.length===1&&validName(parts[0])&&request.method==='DELETE'){const deleted=await env.DB.prepare('DELETE FROM mcp_connections WHERE account_id=? AND name=? RETURNING id').bind(who.id,parts[0]).first();if(!deleted)fail(404,'integration_not_found');return json({removed:true});}
 if(who.closing_at!==null)fail(409,'account_deletion_pending');
 if(!parts.length&&request.method==='GET'){
  const team=new URL(request.url).searchParams.get('team_id')??undefined;if(team!==undefined&&!/^[a-zA-Z0-9-]{1,80}$/.test(team))fail(400,'integration_team_invalid');if(!await boundary.subscribed(team))fail(402,'subscription_required');
  const list=await env.DB.prepare('SELECT * FROM mcp_connections WHERE account_id=? AND (? IS NULL OR team_id=?) ORDER BY name').bind(who.id,team??null,team??null).all<Connection>();return json({connections:list.results.map(metadata)});
 }
 if(!parts.length&&request.method==='POST'){
  const data=await boundary.body(request,8192);if(data.team_id!==undefined&&(typeof data.team_id!=='string'||!/^[a-zA-Z0-9-]{1,80}$/.test(data.team_id)))fail(400,'integration_team_invalid');if(!await boundary.subscribed(data.team_id))fail(402,'subscription_required');if(!validName(data.name))fail(400,'integration_name_required');const url=endpoint(data.url);
  if(data.token!==undefined&&(typeof data.token!=='string'||!data.token||data.token.length>4096||!/^[A-Za-z0-9._~+\/-]+=*$/.test(data.token)||data.token===request.headers.get('authorization')?.slice(7)))fail(400,'integration_credential_invalid');
  await publicDns(url,AbortSignal.any([deadline,AbortSignal.timeout(8000)]));
  const c:Connection={account_id:who.id,name:data.name,id:crypto.randomUUID(),url:url.href,token_ciphertext:null,created_at:now(),team_id:data.team_id??null};if(data.token)c.token_ciphertext=await seal(env,c,data.token);
  const saved=await env.DB.prepare("INSERT INTO mcp_connections(account_id,name,id,url,token_ciphertext,created_at,team_id) SELECT ?,?,?,?,?,?,? WHERE (SELECT COUNT(*) FROM mcp_connections WHERE account_id=?)<20 AND EXISTS(SELECT 1 FROM accounts a JOIN sessions s ON s.account_id=a.id WHERE a.id=? AND a.closing_at IS NULL AND s.token_hash=? AND s.kind='device' AND s.expires_at>?) AND (? IS NULL OR EXISTS(SELECT 1 FROM teams t JOIN team_members m ON m.team_id=t.id WHERE t.id=? AND m.account_id=? AND t.closing_at IS NULL AND t.capacity>0 AND t.period_end>?)) ON CONFLICT(account_id,name) DO NOTHING RETURNING id").bind(c.account_id,c.name,c.id,c.url,c.token_ciphertext,c.created_at,c.team_id,who.id,who.id,who.token_hash,now(),c.team_id,c.team_id,who.id,now()).first();
  if(!saved)fail(409,'integration_exists_or_limit');return json({connection:metadata(c)},201);
 }
 if(parts.length<1||parts.length>2||!validName(parts[0]))fail(404,'not_found');
 const c=await env.DB.prepare('SELECT * FROM mcp_connections WHERE account_id=? AND name=?').bind(who.id,parts[0]).first<Connection>();if(!c)fail(404,'integration_not_found');if(!await boundary.subscribed(c.team_id??undefined))fail(402,'subscription_required');
 if(parts[1]==='tools'&&request.method==='GET')return remote(env,who,c,deadline);
 if(parts[1]==='call'&&request.method==='POST'){
  const data=await boundary.body(request,65536);if(data.confirmation!==true)fail(400,'integration_confirmation_required');if(typeof data.tool!=='string'||!data.tool||data.tool.length>128||!data.arguments||typeof data.arguments!=='object'||Array.isArray(data.arguments))fail(400,'integration_tool_and_arguments_required');
  return remote(env,who,c,deadline,{tool:data.tool,arguments:data.arguments});
 }
 fail(404,'not_found');
}
