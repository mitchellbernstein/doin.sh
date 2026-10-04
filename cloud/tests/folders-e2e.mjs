import assert from 'node:assert/strict';
import {readFile,mkdtemp,writeFile,mkdir,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {build} from 'esbuild';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
const root=new URL('../',import.meta.url),temp=await mkdtemp(join(tmpdir(),'doin-folder-e2e-')),checks=[],transcript=[];
const source=`import {foldersRoute} from '${root.pathname}folders.ts';export default{async fetch(r,env){try{return await foldersRoute(r,env,{id:r.headers.get('x-actor')},{body:r=>r.json(),paid:async()=>{}});}catch(e){if(e instanceof Response)return e;return Response.json({error:String(e)},{status:500});}}};`;
await build({stdin:{contents:source,loader:'ts',resolveDir:root.pathname},outfile:join(temp,'worker.mjs'),bundle:true,format:'esm',platform:'browser'});
const mf=new Miniflare(convertV4MiniflareOptions({workers:[{name:'doin-folders',modules:true,script:await readFile(join(temp,'worker.mjs'),'utf8'),compatibilityDate:'2026-10-01',d1Databases:['DB']}]}));
async function req(actor,path,method='GET',data,status=200){const r=await mf.dispatchFetch(`https://sync.doin.sh/v1/teams/${path}`,{method,headers:{'x-actor':actor,'content-type':'application/json'},body:data===undefined?undefined:JSON.stringify(data)});const value=await r.json();transcript.push({actor,path,method,status:r.status,value});assert.equal(r.status,status,JSON.stringify(value));return value;}
try{
 const db=await mf.getD1Database('DB');await db.exec('CREATE TABLE accounts(id TEXT PRIMARY KEY,closing_at INTEGER);');await db.exec((await readFile(new URL('migrations/0005.sql',root),'utf8')).replaceAll('\n',' '));
 for(const id of ['owner','reader','writer','stranger'])await db.prepare('INSERT INTO accounts(id) VALUES(?)').bind(id).run();
 for(const t of ['alpha','beta']){await db.prepare("INSERT INTO teams(id,name,legal_entity,terms_version,accepted_by,accepted_at,deployment,created_at,capacity,period_end,next_capacity) VALUES(?,?,?,'terms','owner',0,'hosted',0,10,9999999999,10)").bind(t,t,t).run();await db.prepare("INSERT INTO team_members VALUES(?,'owner','owner',0)").bind(t).run();await db.prepare("INSERT INTO team_documents VALUES(?,7,'# Existing root',0)").bind(t).run();}
 for(const account of ['reader','writer'])await db.prepare("INSERT INTO team_members VALUES('alpha',?,'member',0)").bind(account).run();
 await db.exec((await readFile(new URL('migrations/0007.sql',root),'utf8')).replaceAll('\n',' '));
 assert.equal((await req('reader','alpha/folders/root/document')).revision,7);assert.equal((await req('reader','alpha/folders/root/document')).content,'# Existing root');checks.push('migration preserves root documents and existing member access');
 await req('owner','alpha/folders/root/grants','DELETE',{account_id:'reader'});await req('owner','alpha/folders/root/grants','DELETE',{account_id:'writer'});
 const project=await req('owner','alpha/folders','POST',{parent_id:'root',name:'Launch café'},201),child=await req('owner','alpha/folders','POST',{parent_id:project.id,name:'Private checks'},201),other=await req('owner','alpha/folders','POST',{parent_id:'root',name:'Hidden'},201);
 await req('owner',`alpha/folders/${project.id}/grants`,'POST',{account_id:'reader',access:'read'});await req('owner',`alpha/folders/${project.id}/grants`,'POST',{account_id:'writer',access:'write'});
 const list=await req('reader','alpha/folders');assert.deepEqual(new Set(list.folders.map(f=>f.id)),new Set([project.id,child.id]));assert.equal(list.folders.find(f=>f.id===project.id).parent_id,null);
 await req('reader',`alpha/folders/${other.id}/document`,'GET',undefined,404);await req('reader','alpha/folders/root','GET',undefined,404);await req('reader',`alpha/folders/${child.id}/document`,'PUT',{revision:0,content:'denied'},404);await req('reader',`alpha/folders/${child.id}/grants`,'POST',{account_id:'reader',access:'write'},403);checks.push('inherited scoped read/write hides ancestors and denies privilege escalation');
 await req('writer',`alpha/folders/${child.id}/document`,'PUT',{revision:0,content:'- [ ] Ship'},200);await req('writer',`alpha/folders/${child.id}/document`,'PUT',{revision:0,content:'stale'},409);
 await req('owner',`alpha/folders/${project.id}`,'PATCH',{parent_id:child.id,confirm_access_change:true},409);const preview=await req('owner',`alpha/folders/${project.id}`,'PATCH',{parent_id:other.id});assert.equal(preview.confirmation_required,true);await req('owner',`alpha/folders/${project.id}`,'PATCH',{name:'Renamed'});assert.equal((await req('reader',`alpha/folders/${project.id}`)).name,'Renamed');checks.push('independent document CAS and cycle-safe explicit access-changing moves');
 await req('owner','beta/folders','POST',{parent_id:project.id,name:'Cross tenant'},404);await req('stranger',`alpha/folders/${project.id}/document`,'GET',undefined,404);
 await db.prepare("DELETE FROM team_members WHERE team_id='alpha' AND account_id='writer'").run();await req('writer',`alpha/folders/${child.id}/document`,'PUT',{revision:1,content:'after removal'},404);checks.push('cross-tenant forgery and removed membership cannot access descendants');
 let deep=child.id;for(let level=0;level<24;level++)deep=(await req('owner','alpha/folders','POST',{parent_id:deep,name:`Level${level}`},201)).id;
 await req('reader',`alpha/folders/${deep}/document`);checks.push('twenty-four-level hierarchy retains inherited access without an application depth ceiling');
 await mkdir(new URL('artifacts/folders-e2e/',root),{recursive:true});await writeFile(new URL('artifacts/folders-e2e/report.json',root),JSON.stringify({checks,transcript,reproduce:'cd cloud && node tests/folders-e2e.mjs'},null,2)+'\n');console.log(`Passed ${checks.length} folder service groups.`);
}finally{await mf.dispose();await rm(temp,{recursive:true,force:true});}
