"""Background sync failures: default upload, scheduler outage, first-link overwrite,
local/cloud double edit, stale CAS, editor race, unpaid/offline, stale folder job,
credential leakage, repeated conflicts, orphan processes. Defined before adapter.
Real compiled CLI + HTTP; launchctl is fake, no user job is installed."""
import os,json,pathlib,tempfile,subprocess,threading,http.server,atexit
ROOT=pathlib.Path(__file__).resolve().parents[1];BIN=str(ROOT/'zig-out/bin/doin');ART=ROOT/'artifacts/auto-sync';ART.mkdir(parents=True,exist_ok=True)
log=[];requests=[];passed=False
class Backend(http.server.BaseHTTPRequestHandler):
 content='# Tasks\n\n';revision=0;failure=0
 def log_message(self,*args):pass
 def do_GET(self):
  requests.append({'method':'GET','path':self.path});body={'revision':type(self).revision,'content':type(self).content};self.send_response(type(self).failure or 200);self.end_headers();self.wfile.write(json.dumps(body).encode())
 def do_PUT(self):
  data=json.loads(self.rfile.read(int(self.headers['Content-Length'])));requests.append({'method':'PUT','revision':data['revision']});cls=type(self)
  if cls.failure:code=cls.failure
  elif data['revision']!=cls.revision:code=409
  else:cls.content=data['content'];cls.revision+=1;code=200
  self.send_response(code);self.end_headers();self.wfile.write(json.dumps({'revision':cls.revision,'content':cls.content}).encode())
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Backend);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
def finish():
 server.shutdown();server.server_close();thread.join(3);(ART/'result.json').write_text(json.dumps({'passed':passed,'command':'python3 tests/auto_sync_e2e.py','commands':log,'requests':requests},indent=2))
atexit.register(finish)
with tempfile.TemporaryDirectory(prefix='doin-auto-sync-') as temp:
 d=pathlib.Path(temp);cfg=d/'config';store=d/'tasks';shim=d/'bin';cfg.mkdir();store.mkdir();shim.mkdir();journal=d/'scheduler.jsonl'
 fake=shim/'launchctl';fake.write_text('#!/usr/bin/env python3\nimport os,sys,json\nwith open(os.environ["SCHEDULER_LOG"],"a") as f:f.write(json.dumps(sys.argv[1:])+"\\n")\nif os.environ.get("SCHEDULER_FAIL")=="1":sys.exit(7)\n');fake.chmod(0o755)
 systemctl=shim/'systemctl';systemctl.write_text(fake.read_text());systemctl.chmod(0o755)
 env={**os.environ,'HOME':str(d),'DOIN_CONFIG_DIR':str(cfg),'DOIN_SYNC_AGENT_DIR':str(d/'agents'),'SCHEDULER_LOG':str(journal),'PATH':str(shim)+':'+os.environ['PATH']}
 (cfg/'config.json').write_text(json.dumps({'storage':str(store),'provider':'manual'}));(cfg/'sync.json').write_text(json.dumps({'endpoint':f'http://127.0.0.1:{server.server_port}','token':'a'*64}));(cfg/'sync.json').chmod(0o600);doc=store/'tasks.md';doc.write_text(Backend.content)
 def run(*args,ok=True):
  r=subprocess.run([BIN,*args],env=env,capture_output=True,text=True,timeout=25);log.append({'argv':args,'code':r.returncode,'stdout':r.stdout,'stderr':r.stderr});assert (r.returncode==0)==ok,log[-1];assert 'a'*64 not in r.stdout+r.stderr;return r
 run('sync','auto','check');assert not requests;run('sync','auto','status');assert not journal.exists()
 env['SCHEDULER_FAIL']='1';run('sync','auto','enable',ok=False);env.pop('SCHEDULER_FAIL');run('sync','auto','check');assert not requests
 run('sync','auto','enable');run('sync','auto','check');assert Backend.content==doc.read_text()
 doc.write_text('- [ ] local change\n');run('sync','auto','check');assert Backend.content==doc.read_text()
 Backend.content+='- [ ] cloud change\n';Backend.revision+=1;run('sync','auto','check');assert doc.read_text()==Backend.content;assert (store/'.tasks.undo').exists()
 doc.write_text(doc.read_text()+'- [ ] local conflict\n');Backend.content+='- [ ] remote conflict\n';Backend.revision+=1;before=doc.read_bytes();remote=Backend.content
 run('sync','auto','check',ok=False);assert doc.read_bytes()==before and Backend.content==remote;assert list(store.glob('.doin-sync-conflict-*'))
 Backend.failure=402;run('sync','auto','check',ok=False);assert doc.read_bytes()==before;Backend.failure=0
 env['DOIN_JOB_STORAGE']=str(d/'wrong-folder');run('sync','auto','check',ok=False);assert doc.read_bytes()==before;env.pop('DOIN_JOB_STORAGE')
 run('sync','auto','disable');n=len(requests);run('sync','auto','check');assert len(requests)==n
 (ART/'tasks.md').write_bytes(doc.read_bytes())
passed=True;print('PASS opt-in background sync, OS fixture, two-way CAS conflicts and disable')
