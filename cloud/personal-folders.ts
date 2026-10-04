export type PersonalFolderEnv={DB:D1Database};
type Boundary={body:(r:Request,max?:number)=>Promise<any>;paid:()=>Promise<unknown>};
const fail=(status:number,error:string):never=>{throw Response.json({error},{status});};
const live=`EXISTS(SELECT 1 FROM accounts WHERE id=? AND closing_at IS NULL)`;
const enc=new TextEncoder();
const validId=(v:unknown):v is string=>typeof v==='string'&&/^[a-zA-Z0-9-]{1,80}$/.test(v);
const revision=(v:unknown)=>Number.isSafeInteger(v)&&Number(v)>=0;
function tree(input:unknown){
 if(!Array.isArray(input)||input.length<1||input.length>4096)fail(400,'invalid_tree');
 const nodes=input.map(f=>{if(!f||!validId(f.id)||(f.parent_id!==null&&!validId(f.parent_id))||typeof f.name!=='string'||!f.name.trim()||enc.encode(f.name).length>120||/[\x00-\x1f\x7f/\\]/.test(f.name)||f.name.startsWith('.')||f.name!==f.name.trim())fail(400,'invalid_folder');return {id:f.id as string,parent_id:f.parent_id as string|null,name:f.name as string};});
 const map=new Map(nodes.map(f=>[f.id,f]));if(map.size!==nodes.length||map.get('root')?.parent_id!==null)fail(400,'invalid_root_or_duplicate_id');
 const siblings=new Set<string>(),children=new Map<string,string[]>();for(const f of nodes){if(f.id==='root')continue;if(f.parent_id===null||!map.has(f.parent_id))fail(400,'missing_parent');const key=JSON.stringify([f.parent_id,f.name]);if(siblings.has(key))fail(400,'duplicate_sibling_name');siblings.add(key);const group=children.get(f.parent_id)??[];group.push(f.id);children.set(f.parent_id,group);}
 const queue=['root'];for(let n=0;n<queue.length;n++)queue.push(...(children.get(queue[n])??[]));if(queue.length!==nodes.length)fail(400,'folder_cycle');return nodes;
}
export async function personalSnapshot(env:PersonalFolderEnv,accountId:string){
 const rows=(await env.DB.prepare(`SELECT l.tree_revision,f.id,f.parent_id,f.name,CASE WHEN f.id='root' THEN COALESCE(d.revision,0) ELSE f.revision END AS revision,f.deleted FROM personal_libraries l JOIN personal_folders f ON f.account_id=l.account_id LEFT JOIN documents d ON d.account_id=f.account_id WHERE l.account_id=? AND ${live} ORDER BY f.id LIMIT 8193`).bind(accountId,accountId).all<any>()).results;if(!rows.length)fail(404,'account_not_found');if(rows.length>8192)fail(503,'folder_history_limit');
 return {tree_revision:rows[0].tree_revision,folders:rows.filter(f=>!f.deleted).map(({deleted,tree_revision,...f})=>f),tombstones:rows.filter(f=>f.deleted).map(({deleted,tree_revision,...f})=>f)};
}
export async function personalDocumentRead(env:PersonalFolderEnv,accountId:string,folderId='root'){
 const row=folderId==='root'?await env.DB.prepare(`SELECT revision,content,updated_at FROM documents WHERE account_id=? AND ${live}`).bind(accountId,accountId).first():await env.DB.prepare(`SELECT revision,content,updated_at FROM personal_folders WHERE account_id=? AND id=? AND ${live}`).bind(accountId,folderId,accountId).first();if(!row)fail(404,'folder_not_found');return row;
}
export async function personalDocumentWrite(env:PersonalFolderEnv,accountId:string,folderId:string,rev:number,content:string){
 if(!revision(rev)||typeof content!=='string'||content.includes('\0'))fail(400,'invalid_document');if(enc.encode(content).length>1048576)fail(413,'too_large');
 const time=Math.floor(Date.now()/1000);const row=folderId==='root'?await env.DB.prepare(`UPDATE documents SET revision=revision+1,content=?,updated_at=? WHERE account_id=? AND revision=? AND ${live} RETURNING revision,content,updated_at`).bind(content,time,accountId,rev,accountId).first():await env.DB.prepare(`UPDATE personal_folders SET revision=revision+1,content=?,updated_at=? WHERE account_id=? AND id=? AND revision=? AND deleted=0 AND ${live} RETURNING revision,content,updated_at`).bind(content,time,accountId,folderId,rev,accountId).first();
 if(row)return row;const current=await personalDocumentRead(env,accountId,folderId);if(folderId==='root'&&(current as any).content===content)return current;throw Response.json({error:'revision_conflict',...current as object},{status:409});
}
export async function personalFoldersRoute(request:Request,env:PersonalFolderEnv,actor:{id:string},b:Boundary):Promise<Response>{
 const m=/^\/v1\/folders(?:\/([a-zA-Z0-9-]{1,80})\/document)?$/.exec(new URL(request.url).pathname);if(!m)fail(404,'not_found');
 if(m[1]){if(request.method==='GET')return Response.json(await personalDocumentRead(env,actor.id,m[1]));if(request.method==='PUT'){await b.paid();const d=await b.body(request,6*1048576+1024);return Response.json(await personalDocumentWrite(env,actor.id,m[1],d.revision,d.content));}fail(405,'method_not_allowed');}
 if(request.method==='GET')return Response.json(await personalSnapshot(env,actor.id));if(request.method!=='PUT')fail(405,'method_not_allowed');await b.paid();const d=await b.body(request,1048576);if(!revision(d.tree_revision))fail(400,'tree_revision_required');const nodes=tree(d.folders),current=await personalSnapshot(env,actor.id);
 if(current.tree_revision!==d.tree_revision)throw Response.json({error:'tree_revision_conflict',...current},{status:409});
 const ids=new Set(nodes.map(f=>f.id)),removed=current.folders.filter(f=>!ids.has(f.id)).map(f=>f.id),deletions=d.tombstone_ids??[];if(!Array.isArray(deletions)||deletions.some(v=>!validId(v)||v==='root')||new Set(deletions).size!==deletions.length||removed.length!==deletions.length||removed.some(v=>!deletions.includes(v)))fail(409,'explicit_tombstones_required');
 const all=new Set([...current.folders,...current.tombstones,...nodes].map(f=>f.id));if(all.size>8192)fail(409,'folder_history_limit');
 const saved=await env.DB.prepare(`UPDATE personal_libraries SET tree_revision=tree_revision+1,tree_json=? WHERE account_id=? AND tree_revision=? AND ${live} RETURNING tree_revision`).bind(JSON.stringify(nodes),actor.id,d.tree_revision,actor.id).first();if(!saved)fail(409,'tree_revision_conflict_or_account_closed');return Response.json(await personalSnapshot(env,actor.id));
}
