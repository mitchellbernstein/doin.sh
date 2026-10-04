#!/usr/bin/env python3
"""Sync failure census and real CLI/HTTP scenarios, defined before module code.
Email revision failures: invalid email, mail failure, expired/wrong PKCE poll, session
overwrite on failed login, unmanaged account browsers, unsafe checkout origin,
unauthorized device revoke, cancellation without consent, offline logout.
Pricing failures: decline opens a browser; annual choice reaches monthly line item;
selected offer differs from checkout; invalid interval creates checkout.
Failures: implicit upload; exposed tokens; insecure endpoints; expired/unpaid/offline;
malformed or ambiguous responses; revision conflicts; local edits during requests;
lock contention; per-folder/account state leakage; pull losing unsynced contents.
"""
import argparse,base64,fcntl,hashlib,http.server,json,re,os,pathlib,subprocess,tempfile,threading,traceback
p=argparse.ArgumentParser();p.add_argument('--bin',default='zig-out/bin/doin');p.add_argument('--worker',action='store_true',help='Also run actual local Worker+D1 integration; requires cloud npm dependencies');a=p.parse_args();binary=str(pathlib.Path(a.bin).resolve())
evidence=pathlib.Path('artifacts/sync-client');evidence.mkdir(parents=True,exist_ok=True)
commands=[];cases=[];requests=[]
class Backend(http.server.BaseHTTPRequestHandler):
 revision=0;content='';status=200;malformed=False;mutate=None;ambiguous=False
 auth_status=200;poll_status=200;challenge='';polls=0;checkout='https://checkout.stripe.com/c/pay/fixture';canceled=False;drop_claim=True
 def log_message(self,*args):pass
 def request(self):
  cls=type(self);requests.append({'method':self.command,'path':self.path})
  if self.path not in ['/v1/auth/start','/v1/auth/poll']:assert self.headers.get('Authorization')=='Bearer fixture-device-token'
  body=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))) or '{}')
  status=cls.status
  if self.path!='/v1/document':
   status=cls.auth_status;payload={}
   if self.path=='/v1/auth/start':
    assert re.fullmatch('[A-Za-z0-9_-]{43}',body['code_challenge'])
    assert body['email']=='launch@example.test' and body['name']
    cls.challenge=body['code_challenge'];cls.polls=0
    payload={'request_id':'fixture-request','confirmation_code':'482913','expires_in':600,'interval':2}
   elif self.path=='/v1/auth/poll':
    verifier=body['code_verifier'];expected=base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip('=')
    assert expected==cls.challenge and re.fullmatch('[a-f0-9]{64}',verifier) and body['request_id']=='fixture-request'
    cls.polls+=1;status=202 if cls.polls==1 else cls.poll_status
    payload={'status':'pending'} if status==202 else {'token':'fixture-device-token','expires_at':2000000000,'account':{'id':'fixture','email':'launch@example.test','name':'Launch'}}
   elif self.path=='/v1/account' and self.command=='GET':payload={'id':'fixture','email':'launch@example.test','name':'Launch'}
   elif self.path=='/v1/billing':payload={'active':True,'cancel_at_period_end':cls.canceled,'current_period_end':2000000000,'status':'active'}
   elif self.path=='/v1/devices':payload={'devices':[{'id':'device-current','name':'This computer','expires_at':2000000000,'current':True},{'id':'device-other','name':'Desktop','expires_at':2000000000,'current':False}]}
   elif self.path=='/v1/devices/revoke':assert body['id']=='device-other';payload={'ok':True}
   elif self.path=='/v1/checkout':payload={'url':cls.checkout}
   elif self.path=='/v1/billing/cancel':cls.canceled=True;payload={'ok':True}
   elif self.path=='/v1/billing/resume':cls.canceled=False;payload={'cancel_at_period_end':False}
   elif self.path=='/v1/billing/recover':payload={'url':'https://invoice.stripe.com/i/fixture'}
   elif self.path=='/v1/export':payload={'revision':cls.revision,'content':cls.content}
   elif self.path=='/v1/account' and self.command=='DELETE':assert body['confirmation']=='delete my account';payload={'deleted':True}
   elif self.path=='/v1/logout':payload={'ok':True}
   else:raise AssertionError(self.path)
   if self.path=='/v1/auth/poll' and status==200 and cls.drop_claim:
    cls.drop_claim=False;self.connection.close();return
   data=json.dumps(payload).encode();self.send_response(status);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data);return
  if status==200 and self.command=='PUT':
   if body['revision']!=cls.revision:status=409
   else:cls.revision+=1;cls.content=body['content']
  if cls.mutate:cls.mutate()
  payload={'revision':cls.revision,'content':cls.content}
  if status!=200:payload['error']='revision_conflict' if status==409 else 'fixture_failure'
  if cls.ambiguous and self.command=='PUT':self.connection.close();return
  data=b'{broken' if cls.malformed else json.dumps(payload).encode()
  self.send_response(status);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
 do_GET=request;do_PUT=request;do_POST=request;do_DELETE=request
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Backend);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
try:
 with tempfile.TemporaryDirectory(prefix='doin-sync-client-') as tmp:
  root=pathlib.Path(tmp);storage=root/'launch notes';env=os.environ.copy();env['DOIN_CONFIG_DIR']=str(root/'config')
  def run(*args,stdin='',ok=True):
   r=subprocess.run([binary,*args],input=stdin,text=True,capture_output=True,env=env,timeout=35)
   commands.append({'args':args,'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr})
   assert (r.returncode==0)==ok,commands[-1];assert 'fixture-device-token' not in r.stdout+r.stderr
   return r.stdout+r.stderr
  def case(name,fn):
   try:fn();cases.append({'name':name,'passed':True})
   except Exception:cases.append({'name':name,'passed':False,'failure':traceback.format_exc()})
  endpoint=f'http://127.0.0.1:{server.server_port}';file=storage/'tasks.md';state=storage/'.doin-sync.json'
  original='# Launch café\n\n- [ ] Restore backup\n- [x] Verify "quotes"\n\nKeep $HOME literal; [docs](https://example.org).\n'
  def lifecycle():
   run('init','--storage',str(storage),'--provider','manual');file.write_text(original)
   run('sync','status');assert not requests
   run('sync','push',ok=False);assert not requests
   text=run('sync','login','--endpoint',endpoint,stdin='launch@example.test\n');assert '482913' in text and 'GitHub' not in text
   assert not any(r['path']=='/v1/document' for r in requests)
   cred=root/'config/sync.json';assert cred.stat().st_mode&0o777==0o600
   run('sync','status');assert not any(r['method']=='PUT' for r in requests)
   run('sync','push');assert Backend.content==original;assert state.exists()
   Backend.revision+=1;Backend.content=original+'\n- [ ] Remote review\n'
   run('sync','pull');assert file.read_text()==Backend.content
   assert (storage/'.tasks.undo').read_text()==original
   local=Backend.content+'\nLocal editor note\n';file.write_text(local);Backend.revision+=1;Backend.content+='\nRemote editor note\n'
   run('sync','push',ok=False);assert file.read_text()==local
   assert any('Remote editor note' in x.read_text() for x in storage.glob('.doin-sync-conflict-*'))
   run('sync','pull',ok=False);assert file.read_text()==local
   run('sync','pull','--accept-remote');assert file.read_text()==Backend.content
   assert any('Local editor note' in x.read_text() for x in storage.glob('.doin-sync-local-*'))
  case('email magic-link PKCE pending-to-verified login, private credentials, Unicode sync and conflict copies',lifecycle)
  def account():
   assert 'launch@example.test' in run('sync','status')
   assert 'Desktop' in run('sync','devices')
   run('sync','revoke','device-other',stdin='n\n');assert not any(r['path']=='/v1/devices/revoke' for r in requests)
   run('sync','revoke','device-other','--yes');assert requests[-1]['path']=='/v1/devices/revoke'
   assert 'checkout.stripe.com' in run('sync','billing')
   Backend.checkout='https://evil.example/pay';run('sync','billing',ok=False);Backend.checkout='https://checkout.stripe.com/c/pay/fixture'
   run('sync','cancel',stdin='n\n');assert not Backend.canceled
   run('sync','cancel','--yes');assert Backend.canceled
   run('sync','resume','--yes');assert not Backend.canceled
   assert 'invoice.stripe.com' in run('sync','recover')
   assert run('sync','export')==Backend.content
   run('sync','delete',stdin='no\n');assert not any(r['method']=='DELETE' for r in requests)
   cred=root/'config/sync.json';before=cred.read_bytes()
   Backend.auth_status=503;run('sync','login','--endpoint',endpoint,stdin='launch@example.test\n',ok=False);run('sync','logout',ok=False);assert cred.read_bytes()==before;Backend.auth_status=200
   Backend.poll_status=401;run('sync','login','--endpoint',endpoint,stdin='launch@example.test\n',ok=False);assert cred.read_bytes()==before;Backend.poll_status=200
   count=len(requests);run('sync','login','--endpoint',endpoint,stdin='not-an-email\n',ok=False);assert len(requests)==count
  case('account/device management, trusted checkout, cancellation consent and failed login/logout preserve session',account)
  def failures():
   before=file.read_bytes();baseline=state.read_bytes()
   for code in [401,402,503]:
    Backend.status=code;run('sync','pull',ok=False);run('sync','push',ok=False);assert file.read_bytes()==before and state.read_bytes()==baseline
   Backend.status=200;Backend.malformed=True;run('sync','pull',ok=False);assert file.read_bytes()==before and state.read_bytes()==baseline;Backend.malformed=False
   lock=open(storage/'.tasks.lock','a');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
   try:run('sync','pull',ok=False)
   finally:lock.close()
   assert file.read_bytes()==before
   Backend.mutate=lambda:file.write_bytes(before+b'\nConcurrent external edit\n')
   run('sync','pull',ok=False);assert file.read_bytes()==before+b'\nConcurrent external edit\n';assert state.read_bytes()==baseline;Backend.mutate=None
   file.write_bytes(before);Backend.ambiguous=True;run('sync','push',ok=False);Backend.ambiguous=False;assert file.read_bytes()==before and state.read_bytes()==baseline
  case('fail-closed unpaid/expired/offline ambiguity, malformed response, busy lock and concurrent editor',failures)
  def separate():
   folder=root/'second folder';run('init','--storage',str(folder),'--provider','manual');(folder/'tasks.md').write_text('Second folder local work\n')
   run('sync','push',ok=False);assert (folder/'tasks.md').read_text()=='Second folder local work\n';assert not (folder/'.doin-sync.json').exists()
   run('sync','logout');assert not (root/'config/sync.json').exists();assert file.exists();run('sync','status')
   run('sync','login','--endpoint',endpoint,'--email','launch@example.test')
   before=file.read_bytes();run('sync','delete',stdin='delete my account\n');assert file.read_bytes()==before and not (root/'config/sync.json').exists()
   run('sync','login','--endpoint','http://example.org',stdin='launch@example.test\n',ok=False)
  case('independent folder revision state, local-preserving logout and insecure endpoint refused',separate)
finally:
 server.shutdown();server.server_close();thread.join(timeout=5)
(evidence/'results.json').write_text(json.dumps({'binary':binary,'sha256':hashlib.sha256(pathlib.Path(binary).read_bytes()).hexdigest(),'cases':cases,'commands':commands,'requests':requests},indent=2))
(evidence/'transcript.md').write_text('# Sync client E2E\n\n'+'\n'.join('## '+ ' '.join(c['args'])+'\n```text\n'+c['stdout']+c['stderr']+'\n```\n' for c in commands))
for c in cases:print(('PASS' if c['passed'] else 'FAIL')+' '+c['name'])
if a.worker:
 import select,signal,socket,urllib.parse,urllib.request
 nodeenv=os.environ.copy();nodeenv['DOIN_FIXTURE_UPGRADE']='1'
 with socket.socket() as sock:
  sock.bind(('127.0.0.1',0));nodeenv['DOIN_FIXTURE_PORT']=str(sock.getsockname()[1])
 worker=subprocess.Popen(['node','cloud/tests/cli-fixture.mjs'],env=nodeenv,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
 realcommands=[]
 try:
  assert select.select([worker.stdout],[],[],15)[0],'Worker readiness timed out'
  ready=json.loads(worker.stdout.readline());assert ready['ready']
  with tempfile.TemporaryDirectory(prefix='doin-actual-worker-') as tmp:
   base=pathlib.Path(tmp)
   shims=base/'shims';shims.mkdir();browserlog=base/'browser-url.txt'
   for opener in ['open','xdg-open']:
    shim=shims/opener;shim.write_text("#!/bin/sh\nprintf '%s\\n' \"$1\" > \"$DOIN_BROWSER_LOG\"\n");shim.chmod(0o700)
   def cli(device,*argv,stdin='',ok=True):
    env=os.environ.copy();env['DOIN_CONFIG_DIR']=str(base/device/'config');env['PATH']=str(shims)+os.pathsep+env['PATH'];env['DOIN_BROWSER_LOG']=str(browserlog)
    r=subprocess.run([binary,*argv],env=env,input=stdin,text=True,capture_output=True,timeout=30)
    realcommands.append({'device':device,'args':argv,'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr})
    assert (r.returncode==0)==ok,realcommands[-1]
    return r.stdout+r.stderr
   def email_login(device):
    env=os.environ.copy();env['DOIN_CONFIG_DIR']=str(base/device/'config')
    login=subprocess.Popen([binary,'sync','login','--endpoint',ready['origin'],'--email','fixture@example.com','--name',device],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
    try:
     assert select.select([login.stdout],[],[],15)[0],'Login confirmation timed out'
     first=login.stdout.readline();code=re.search(r'confirmation code: ([0-9]{6})',first).group(1)
     assert select.select([worker.stdout],[],[],15)[0],'Fixture email timed out'
     mail=json.loads(worker.stdout.readline())['mail'];assert mail['to']=='fixture@example.com'
     url=mail['url'];token=urllib.parse.parse_qs(urllib.parse.urlparse(url).query)['token'][0]
     with urllib.request.urlopen(url) as response:assert response.status==200
     # A mail scanner GET must not claim a session; browser approval requires terminal code.
     request=urllib.request.Request(ready['origin']+'/auth/verify',data=json.dumps({'token':token,'confirmation_code':code}).encode(),headers={'Content-Type':'application/json','Origin':ready['origin']},method='POST')
     with urllib.request.urlopen(request) as response:assert response.status==200
     out,err=login.communicate(timeout=15);assert login.returncode==0,(out,err)
     realcommands.append({'device':device,'args':['sync','login','--email','fixture@example.com'],'exit':login.returncode,'stdout':first+out,'stderr':err})
     assert 'Signed in.' in out
    finally:
     if login.poll() is None:os.killpg(login.pid,signal.SIGTERM);login.wait(timeout=5)
   content='# Launch café\n\n- [ ] Verify migration\n- [x] Restore staging\n\nKeep notes & Unicode 🪶.\n'
   for device in ['laptop','desktop']:
    cli(device,'init','--storage',str(base/device/'tasks'),'--provider','manual')
    email_login(device)
   laptop=base/'laptop/tasks/tasks.md';desktop=base/'desktop/tasks/tasks.md';laptop.write_text(content)
   assert 'Sandbox' in cli('laptop','upgrade',stdin='3\n');assert not browserlog.exists()
   assert 'none' in cli('laptop','sync','status')
   cli('laptop','upgrade',stdin='2\n')
   assert browserlog.read_text().strip()=='https://checkout.stripe.com/c/pay/fixture#doin-complete-fragment'
   assert 'active' in cli('laptop','sync','status')
   cli('laptop','upgrade',stdin='1\n',ok=False)
   cli('laptop','sync','push');cli('desktop','sync','pull');assert desktop.read_text()==content
   desktop.write_text(content+'\n- [ ] Desktop review\n');cli('desktop','sync','push')
   laptop.write_text(content+'\nLaptop offline note\n');before=laptop.read_bytes()
   cli('laptop','sync','push',ok=False);assert laptop.read_bytes()==before
   assert any('Desktop review' in x.read_text() for x in laptop.parent.glob('.doin-sync-conflict-*'))
   cli('laptop','sync','pull','--accept-remote');assert laptop.read_text()==desktop.read_text()
   assert any('Laptop offline note' in x.read_text() for x in laptop.parent.glob('.doin-sync-local-*'))
   state=laptop.parent/'.doin-sync.json';saved=json.loads(state.read_text());saved['revision']-=1;state.write_text(json.dumps(saved))
   cli('laptop','sync','push');assert json.loads(state.read_text())['revision']==2
   assert 'fixture@example.com' in cli('laptop','sync','status')
   rows=cli('laptop','sync','devices');assert 'desktop' in rows and 'laptop' in rows
   desktop_id=next(line.split()[0] for line in rows.splitlines() if 'desktop' in line)
   cli('laptop','sync','revoke',desktop_id,'--yes');cli('desktop','sync','status',ok=False)
   cli('laptop','sync','cancel','--yes');assert 'renewal canceled' in cli('laptop','sync','status')
   cli('laptop','sync','resume','--yes');assert 'renewal canceled' not in cli('laptop','sync','status')
   assert cli('laptop','sync','export')==laptop.read_text()
   cli('laptop','sync','recover',ok=False)  # Active paid fixture has no overdue invoice.
   cli('laptop','sync','logout');assert not (base/'laptop/config/sync.json').exists();assert laptop.exists()
   email_login('laptop');before=laptop.read_bytes()
   cli('laptop','sync','delete',stdin='delete my account\n');assert laptop.read_bytes()==before and not (base/'laptop/config/sync.json').exists()
  realreport={'passed':True,'backend':'Actual cloud/worker.ts + workerd + D1; synthetic email and Stripe delivery','commands':realcommands}
  print('PASS actual Worker+D1 email, two-device sync, billing renewal, export, logout and account deletion')
 except Exception:
  realreport={'passed':False,'failure':traceback.format_exc(),'commands':realcommands}
  print('FAIL actual Worker integration')
 finally:
  if worker.poll() is None:
   worker.send_signal(signal.SIGTERM)
   try:worker.wait(timeout=10)
   except subprocess.TimeoutExpired:os.killpg(worker.pid,signal.SIGKILL);worker.wait(timeout=5)
  realreport['process']={'pid':worker.pid,'port':nodeenv['DOIN_FIXTURE_PORT'],'exit':worker.returncode,'stop':'SIGTERM; process awaited'}
  (evidence/'actual-worker.json').write_text(json.dumps(realreport,indent=2))
 cases.append({'name':'Actual Worker+D1 CLI integration','passed':realreport['passed']})
raise SystemExit(0 if all(c['passed'] for c in cases) else 1)
