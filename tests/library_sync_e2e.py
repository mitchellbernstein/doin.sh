"""Failure-first whole-library native E2E: two devices, structural changes, per-doc
CAS, deep content, invalid remote trees, external editors, root alias replacement,
partial writes, missing nodes/tombstones and legacy document isolation.
Real CLI + local HTTP; no paid calls or installed background jobs."""
import os,sys,json,pathlib,subprocess,tempfile,threading,http.server,atexit
ROOT=pathlib.Path(__file__).resolve().parents[1];BIN=str(ROOT/'zig-out/bin/doin');ART=ROOT/'artifacts/library-sync';ART.mkdir(parents=True,exist_ok=True);events=[];commands=[];passed=False
class Service(http.server.BaseHTTPRequestHandler):
 tree_revision=0;nodes={'root':{'id':'root','parent_id':None,'name':'Home','revision':0,'content':''}};on_get=None;on_put=None;fault=0;fail_after=None
 def log_message(self,*args):pass
 def response(self,status,data):self.send_response(status);self.end_headers();self.wfile.write(json.dumps(data).encode())
 def snapshot(self):return {'tree_revision':Service.tree_revision,'folders':[{k:n[k] for k in ('id','parent_id','name','revision')} for n in Service.nodes.values()],'tombstones':[]}
 def do_GET(self):
  events.append({'method':'GET','path':self.path});(ART/'http-live.json').write_text(json.dumps(events,indent=2))
  if Service.fault:return self.response(Service.fault,{'error':'fixture_outage'})
  if self.path=='/v1/folders':return self.response(200,self.snapshot())
  if self.path.startswith('/v1/folders/')and self.path.endswith('/document'):
   n=Service.nodes.get(self.path.split('/')[3]);data={'revision':n['revision'],'content':n['content'],'updated_at':0}if n else {'error':'not_found'}
   if Service.on_get:callback=Service.on_get;Service.on_get=None;callback()
   return self.response(200 if n else 404,data)
  return self.response(200,{'revision':999,'content':'LEGACY ROOT MUST NOT BE TOUCHED','updated_at':0})
 def do_PUT(self):
  d=json.loads(self.rfile.read(int(self.headers['Content-Length'])));events.append({'method':'PUT','path':self.path});(ART/'http-live.json').write_text(json.dumps(events,indent=2))
  if Service.fault:return self.response(Service.fault,{'error':'fixture_outage'})
  if self.path=='/v1/folders':
   if d['tree_revision']!=Service.tree_revision:return self.response(409,{'error':'tree_revision_conflict',**self.snapshot()})
   if set(Service.nodes)-{f['id']for f in d['folders']}:return self.response(409,{'error':'explicit_tombstones_required'})
   for f in d['folders']:
    n=Service.nodes.get(f['id'],{'revision':0,'content':''});n.update(f);Service.nodes[f['id']]=n
   Service.tree_revision+=1;return self.response(200,self.snapshot())
  if self.path.startswith('/v1/folders/')and self.path.endswith('/document'):
   n=Service.nodes[self.path.split('/')[3]]
   if Service.on_put:callback=Service.on_put;Service.on_put=None;callback(n)
   if Service.fail_after is not None:
    if Service.fail_after==0:return self.response(503,{'error':'partial_outage'})
    Service.fail_after-=1
   if d['revision']!=n['revision']:return self.response(409,{'revision':n['revision'],'content':n['content'],'updated_at':0})
   n['content']=d['content'];n['revision']+=1;return self.response(200,{'revision':n['revision'],'content':n['content'],'updated_at':0})
  return self.response(500,{'error':'legacy_route_forbidden'})
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Service);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
def finish():server.shutdown();server.server_close();thread.join();(ART/'result.json').write_text(json.dumps({'passed':passed,'commands':commands,'http':events},indent=2))
atexit.register(finish)
with tempfile.TemporaryDirectory(prefix='doin-library-')as temp:
 base=pathlib.Path(temp).resolve()
 def device(label):
  cfg=base/(label+'config');root=base/(label+'library');env={**os.environ,'DOIN_CONFIG_DIR':str(cfg),'DOIN_NO_ANIMATION':'1'}
  def run(*args,ok=True):
   r=subprocess.run([BIN,*args],env=env,capture_output=True,text=True,timeout=30);commands.append({'device':label,'argv':args,'code':r.returncode,'stdout':r.stdout,'stderr':r.stderr});assert(r.returncode==0)==ok,commands[-1];return r
  run('init','--storage',str(root),'--provider','manual','--template','simple');(cfg/'sync.json').write_text(json.dumps({'endpoint':f'http://127.0.0.1:{server.server_port}','token':'a'*64}));(cfg/'sync.json').chmod(0o600)
  return cfg,root,run
 ac,a,ar=device('A');bc,b,br=device('B');aid=json.loads((a/'.doin-folder.json').read_text())['id'];ar('folder','create',aid,'Projects');project=a/'Projects';pid=json.loads((project/'.doin-folder.json').read_text())['id'];(project/'tasks.md').write_text('# Unicode 東京\n- [ ] Ship\n```md\n- [ ] fenced example\n```\n');ar('sync','push');br('sync','pull');assert (b/'Projects'/'tasks.md').read_bytes()==(project/'tasks.md').read_bytes()
 (a/'Projects'/'AGENTS.md').write_text('A custom local guidance\n');(b/'Projects'/'AGENTS.md').write_text('B custom local guidance\n');(a/'Projects'/'custom-reference.txt').write_text('LOCAL EXTRA BYTES\n')
 br('folder','select',pid);ar('folder','rename',pid,'Work');ar('sync','push');br('sync','pull');assert (b/'Work'/'tasks.md').exists()and not(b/'Projects').exists();assert json.loads((bc/'config.json').read_text())['storage']==str(b/'Work');project=a/'Work';assert(project/'AGENTS.md').read_text()=='A custom local guidance\n';assert(b/'Work'/'AGENTS.md').read_text()=='B custom local guidance\n';assert(project/'custom-reference.txt').read_text()=='LOCAL EXTRA BYTES\n';assert not(b/'Work'/'custom-reference.txt').exists()
 (project/'tasks.md').write_text('- [ ] Device A\n');(b/'Work'/'tasks.md').write_text('- [ ] Device B\n');ar('sync','push');before=(b/'Work'/'tasks.md').read_bytes();br('sync','push',ok=False);assert (b/'Work'/'tasks.md').read_bytes()==before;assert Service.nodes[pid]['content']=='- [ ] Device A\n';assert list(b.glob('.doin-library-conflict-*'));assert all(p.stat().st_mode&0o777==0o700 for p in b.glob('.doin-library-conflict-*'))
 # Add a third unchanged document alongside the two conflicting ones.
 br('sync','pull','--accept-remote');ar('folder','create',aid,'Stable');stable=a/'Stable';(stable/'tasks.md').write_text('UNCHANGED THIRD DOCUMENT\n');ar('sync','push');br('sync','pull')
 stable_id=json.loads((stable/'.doin-folder.json').read_text())['id'];stable_revision=Service.nodes[stable_id]['revision']
 # Explicit resolution: two conflicting docs, current CAS, full backup, unchanged folder preserved.
 br('sync','pull','--accept-remote');assert(b/'Work'/'tasks.md').read_text()==Service.nodes[pid]['content']
 for rootpath in (a,b): (rootpath/'tasks.md').write_text('Root '+rootpath.name+' conflict\n');(rootpath/'Work'/'tasks.md').write_text('Work '+rootpath.name+' conflict\n')
 ar('sync','push');br('sync','push','--force');assert Service.nodes['root']['content']==(b/'tasks.md').read_text();assert Service.nodes[pid]['content']==(b/'Work'/'tasks.md').read_text();ar('sync','pull','--accept-remote');assert Service.nodes[stable_id]['revision']==stable_revision;assert(b/'Stable'/'tasks.md').read_text()=='UNCHANGED THIRD DOCUMENT\n'
 (b/'Work'/'tasks.md').write_text('Explicit CAS loser\n');Service.nodes[pid]['content']='Remote before force\n';Service.nodes[pid]['revision']+=1
 def resolution_race(n): n['revision']+=1;n['content']='Remote after force race\n'
 Service.on_put=resolution_race;br('sync','push','--force',ok=False);assert(b/'Work'/'tasks.md').read_text()=='Explicit CAS loser\n';assert Service.nodes[pid]['content']=='Remote after force race\n';assert any('Remote before force' in f.read_text()for f in b.glob('.doin-library-conflict-*/*-cloud.md'));br('sync','pull','--accept-remote');ar('sync','pull')
 # A new device materializes arbitrary depth and multiple independent documents.
 parent=pid;deep=project
 for n in range(24):
  ar('folder','create',parent,f'Level{n}');deep/=f'Level{n}';parent=json.loads((deep/'.doin-folder.json').read_text())['id']
 (deep/'tasks.md').write_text('- [ ] Deep leaf\n');ar('sync','push');cc,c,cr=device('C');cr('sync','pull');assert (c/'Work'/pathlib.Path(*[f'Level{n}'for n in range(24)])/'tasks.md').read_text()=='- [ ] Deep leaf\n'
 # External editor and provider writer races preserve both current documents.
 Service.nodes[pid]['content']+='Remote edit\n';Service.nodes[pid]['revision']+=1;Service.on_get=lambda:(c/'Work'/'tasks.md').write_text('External editor edit\n');cr('sync','pull',ok=False);assert(c/'Work'/'tasks.md').read_text()=='External editor edit\n';assert list(c.glob('.doin-library-conflict-*'));(c/'Work'/'tasks.md').write_text(Service.nodes[pid]['content']);cr('sync','pull')
 (c/'Work'/'tasks.md').write_text('Local CAS writer\n')
 def race(n):n['revision']+=1;n['content']='Provider competing writer\n'
 Service.on_put=race;cr('sync','push',ok=False);assert(c/'Work'/'tasks.md').read_text()=='Local CAS writer\n';assert Service.nodes[pid]['content']=='Provider competing writer\n';(c/'Work'/'tasks.md').write_text(Service.nodes[pid]['content']);cr('sync','pull')
 # Case/normalization aliases must fail before touching managed data on Mac/Windows.
 if sys.platform in ('darwin','win32'):
  alias='f'*32;Service.nodes[alias]={'id':alias,'parent_id':'root','name':'work','revision':0,'content':'ALIAS MUST NOT REPLACE'};Service.tree_revision+=1;before_alias=(c/'Work'/'tasks.md').read_bytes();before_id=(c/'Work'/'.doin-folder.json').read_bytes();cr('sync','pull',ok=False);assert(c/'Work'/'tasks.md').read_bytes()==before_alias and(c/'Work'/'.doin-folder.json').read_bytes()==before_id;del Service.nodes[alias];Service.tree_revision+=1
 # A partial upload can be retried without losing the first committed document.
 (c/'tasks.md').write_text('# Root partial edit\n');(c/'Work'/'tasks.md').write_text('Second partial edit\n');Service.fail_after=1;cr('sync','push',ok=False);assert Service.nodes['root']['content']=='# Root partial edit\n';Service.fail_after=None;cr('sync','push');assert Service.nodes[pid]['content']=='Second partial edit\n'
 export=base/'library-export.json';cr('sync','export',str(export));bundle=json.loads(export.read_text());assert bundle['format']=='doin-library-v1';assert {d['id']for d in bundle['documents']}==set(Service.nodes);assert export.stat().st_mode&0o777==0o600
 snapshot=json.loads(json.dumps(Service.nodes));Service.nodes[pid]['parent_id']=parent;Service.tree_revision+=1;before=(c/'Work'/'tasks.md').read_bytes();cr('sync','pull',ok=False);assert(c/'Work'/'tasks.md').read_bytes()==before;Service.nodes=snapshot;Service.tree_revision+=1
 # Outage never authorizes local mutation.
 Service.fault=402;cr('sync','pull',ok=False);assert(c/'Work'/'tasks.md').read_bytes()==before;Service.fault=0
 # A replaced persisted root must not write into its new alias target.
 moved=base/'Cmoved';c.rename(moved);outside=base/'outside';outside.mkdir();(outside/'tasks.md').write_text('KEEP OUTSIDE\n');c.symlink_to(outside,target_is_directory=True);cr('sync','pull',ok=False);assert(outside/'tasks.md').read_text()=='KEEP OUTSIDE\n'
 assert all(e['path']!='/v1/document'for e in events);(ART/'server-tree.json').write_text(json.dumps(Service.nodes,indent=2));passed=True
print('PASS whole-library two-device folder IDs/rename/depth/CAS/invalid trees/root identity')
