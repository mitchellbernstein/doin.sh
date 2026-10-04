import {assignmentChanges,assignmentGuard} from './assignees';
export type FolderEnv={DB:D1Database};
type Actor={id:string};
type Boundary={body:(r:Request,max?:number)=>Promise<any>;paid:()=>Promise<unknown>};
const fail=(status:number,error:string):never=>{throw Response.json({error},{status});};
const now=()=>Math.floor(Date.now()/1000);
const id=(v:unknown):string=>{if(typeof v!=='string'||!/^([a-zA-Z0-9-]{1,80})$/.test(v))fail(400,'invalid_folder_id');return v;};
const name=(v:unknown):string=>{if(typeof v!=='string'||!v.trim()||v.length>120||/[\x00-\x1f\x7f/\\]/.test(v)||['.','..'].includes(v.trim()))fail(400,'invalid_folder_name');return v.trim();};
const ancestors=`WITH RECURSIVE ancestors(id,parent_id) AS (SELECT id,parent_id FROM team_folders WHERE team_id=? AND id=? UNION SELECT f.id,f.parent_id FROM team_folders f JOIN ancestors a ON f.id=a.parent_id WHERE f.team_id=?)`;
const allowed=`EXISTS(SELECT 1 FROM team_members m JOIN teams t ON t.id=m.team_id WHERE m.team_id=? AND m.account_id=? AND t.closing_at IS NULL AND (m.role IN ('owner','admin') OR EXISTS(SELECT 1 FROM team_folder_grants g JOIN ancestors a ON a.id=g.folder_id WHERE g.team_id=m.team_id AND g.account_id=m.account_id AND (?=0 OR g.access='write'))))`;
const managing=`EXISTS(SELECT 1 FROM team_members m JOIN teams t ON t.id=m.team_id WHERE m.team_id=? AND m.account_id=? AND m.role IN ('owner','admin') AND t.closing_at IS NULL)`;
export async function folderAccess(env:FolderEnv,teamId:string,accountId:string,folderId:string,write=false){
 const row=await env.DB.prepare(`${ancestors} SELECT f.*,m.role FROM team_folders f JOIN team_members m ON m.team_id=f.team_id AND m.account_id=? WHERE f.team_id=? AND f.id=? AND ${allowed}`).bind(teamId,folderId,teamId,accountId,teamId,folderId,teamId,accountId,write?1:0).first<any>();
 if(!row)fail(404,'folder_not_found');return row;
}
export async function documentRead(env:FolderEnv,teamId:string,accountId:string,folderId='root'){
 const row=await folderAccess(env,teamId,accountId,folderId);return {revision:row.revision,content:row.content,updated_at:row.updated_at};
}
export async function documentWrite(env:FolderEnv,teamId:string,accountId:string,folderId:string,revision:number,content:string,oauthGrantId?:string){
 if(!Number.isSafeInteger(revision)||revision<0||typeof content!=='string'||new TextEncoder().encode(content).length>524288||content.includes('\0'))fail(400,'invalid_document');
 const previous=await env.DB.prepare('SELECT content,revision FROM team_folders WHERE team_id=? AND id=?').bind(teamId,folderId).first<{content:string;revision:number}>();
 if(!previous||previous.revision!==revision)fail(409,'revision_conflict_or_access_revoked');
 const changes=assignmentChanges(previous.content,content);
 const grantGuard=oauthGrantId===undefined?'':` AND EXISTS(SELECT 1 FROM mcp_auth_grants g WHERE g.id=? AND g.account_id=? AND g.revoked_at IS NULL AND g.team_id=? AND g.folder_id=? AND EXISTS(SELECT 1 FROM json_each(g.scopes) WHERE value='tasks:write'))`;
 const bindings:(string|number)[]=[teamId,folderId,teamId,content,now(),teamId,folderId,revision,teamId,accountId,1,teamId,now()];if(oauthGrantId!==undefined)bindings.push(oauthGrantId,accountId,teamId,folderId);bindings.push(JSON.stringify(changes),teamId);
 const row=await env.DB.prepare(`${ancestors} UPDATE team_folders SET content=?,revision=revision+1,updated_at=? WHERE team_id=? AND id=? AND revision=? AND ${allowed} AND EXISTS(SELECT 1 FROM teams WHERE id=? AND closing_at IS NULL AND period_end>? AND capacity>0)${grantGuard}${assignmentGuard} RETURNING revision,content,updated_at`).bind(...bindings).first();
 if(!row)fail(409,'revision_conflict_or_access_revoked');return row;
}
export async function foldersRoute(request:Request,env:FolderEnv,actor:Actor,b:Boundary):Promise<Response>{
 const m=/^\/v1\/teams\/([a-zA-Z0-9-]{1,80})\/folders(?:\/([a-zA-Z0-9-]{1,80})(?:\/(document|grants))?)?$/.exec(new URL(request.url).pathname);if(!m)fail(404,'not_found');
 const teamId=m[1],folderId=m[2]??'root',action=m[3]??'',method=request.method;if(method!=='GET')await b.paid();
 const role=await env.DB.prepare('SELECT m.role FROM team_members m JOIN teams t ON t.id=m.team_id WHERE m.team_id=? AND m.account_id=? AND t.closing_at IS NULL').bind(teamId,actor.id).first<{role:string}>();if(!role)fail(404,'team_not_found');
 if(!m[2]&&method==='GET'){
  const visible=(await env.DB.prepare(`WITH RECURSIVE visible(id) AS (SELECT f.id FROM team_folders f JOIN team_members m ON m.team_id=f.team_id WHERE f.team_id=? AND m.account_id=? AND (m.role IN ('owner','admin') OR EXISTS(SELECT 1 FROM team_folder_grants g WHERE g.team_id=f.team_id AND g.folder_id=f.id AND g.account_id=m.account_id)) UNION SELECT f.id FROM team_folders f JOIN visible v ON f.parent_id=v.id WHERE f.team_id=?) SELECT id,parent_id,name,revision FROM team_folders WHERE team_id=? AND id IN (SELECT id FROM visible) AND EXISTS(SELECT 1 FROM team_members m JOIN teams t ON t.id=m.team_id WHERE m.team_id=? AND m.account_id=? AND t.closing_at IS NULL) ORDER BY name,id LIMIT 4097`).bind(teamId,actor.id,teamId,teamId,teamId,actor.id).all<any>()).results;if(visible.length>4096)fail(503,'folder_limit');
  const ids=new Set(visible.map(f=>f.id));return Response.json({folders:visible.map(f=>({...f,parent_id:ids.has(f.parent_id)?f.parent_id:null}))});
 }
 if(action==='document'){
  if(method==='GET')return Response.json(await documentRead(env,teamId,actor.id,folderId));
  if(method==='PUT'){await folderAccess(env,teamId,actor.id,folderId,true);const d=await b.body(request,1048576);return Response.json(await documentWrite(env,teamId,actor.id,folderId,d.revision,d.content));}
  fail(405,'method_not_allowed');
 }
 if(m[2]&&!action&&method==='GET'){const f=await folderAccess(env,teamId,actor.id,folderId);let parent_id=f.parent_id;if(parent_id){try{await folderAccess(env,teamId,actor.id,parent_id);}catch(e){if(!(e instanceof Response)||e.status!==404)throw e;parent_id=null;}}return Response.json({id:f.id,parent_id,name:f.name,revision:f.revision});}
 if(!['owner','admin'].includes(role.role))fail(403,'team_admin_required');
 if(!m[2]&&method==='POST'){
  const d=await b.body(request),parent=id(d.parent_id??'root'),label=name(d.name);await folderAccess(env,teamId,actor.id,parent);
  const folder=crypto.randomUUID();const row=await env.DB.prepare(`INSERT INTO team_folders(team_id,id,parent_id,name,updated_at) SELECT ?,?,?,?,? WHERE (SELECT count(*) FROM team_folders WHERE team_id=?)<4096 AND EXISTS(SELECT 1 FROM team_folders WHERE team_id=? AND id=?) AND ${managing} RETURNING id,parent_id,name,revision`).bind(teamId,folder,parent,label,now(),teamId,teamId,parent,teamId,actor.id).first();if(!row)fail(409,'folder_limit_or_access_revoked');return Response.json(row,{status:201});
 }
 await folderAccess(env,teamId,actor.id,folderId);
 if(action==='grants'){
  if(method==='GET')return Response.json({grants:(await env.DB.prepare('SELECT account_id,access FROM team_folder_grants WHERE team_id=? AND folder_id=?').bind(teamId,folderId).all()).results});
  const d=await b.body(request),account=id(d.account_id);
  if(method==='POST'){
   if(!['read','write'].includes(d.access))fail(400,'invalid_folder_access');
   const row=await env.DB.prepare(`INSERT INTO team_folder_grants(team_id,folder_id,account_id,access) SELECT ?,?,?,? WHERE EXISTS(SELECT 1 FROM team_members WHERE team_id=? AND account_id=?) AND ${managing} ON CONFLICT(team_id,folder_id,account_id) DO UPDATE SET access=excluded.access RETURNING account_id,access`).bind(teamId,folderId,account,d.access,teamId,account,teamId,actor.id).first();if(!row)fail(404,'member_not_found');return Response.json(row);
  }
  if(method==='DELETE'){await env.DB.prepare(`DELETE FROM team_folder_grants WHERE team_id=? AND folder_id=? AND account_id=? AND ${managing}`).bind(teamId,folderId,account,teamId,actor.id).run();return Response.json({removed:true});}
  fail(405,'method_not_allowed');
 }
 if(method==='PATCH'){
  if(folderId==='root')fail(400,'root_folder_fixed');const d=await b.body(request),current=await folderAccess(env,teamId,actor.id,folderId),parent=d.parent_id===undefined?current.parent_id:id(d.parent_id),label=d.name===undefined?current.name:name(d.name);
  await folderAccess(env,teamId,actor.id,parent);
  if(parent!==current.parent_id&&d.confirm_access_change!==true)return Response.json({confirmation_required:true,inherited_access_may_change:true,parent_id:parent});
  const row=await env.DB.prepare(`WITH RECURSIVE descendants(id) AS (SELECT id FROM team_folders WHERE team_id=? AND id=? UNION SELECT f.id FROM team_folders f JOIN descendants d ON f.parent_id=d.id WHERE f.team_id=?) UPDATE team_folders SET name=?,parent_id=?,updated_at=? WHERE team_id=? AND id=? AND parent_id IS ? AND name=? AND NOT EXISTS(SELECT 1 FROM descendants WHERE id=?) AND EXISTS(SELECT 1 FROM team_folders WHERE team_id=? AND id=?) AND ${managing} RETURNING id,parent_id,name,revision`).bind(teamId,folderId,teamId,label,parent,now(),teamId,folderId,current.parent_id,current.name,parent,teamId,parent,teamId,actor.id).first();if(!row)fail(409,'folder_cycle_or_access_revoked');return Response.json(row);
 }
 fail(405,'method_not_allowed');
}
