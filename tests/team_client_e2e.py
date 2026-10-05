#!/usr/bin/env python3
"""Real CLI/HTTP E2E. Failure census predates feature in docs/team-failure-census.md.
Risk scenarios: accidental browser/checkout on decline; credentials in stdout;
changed personal-folder mapping or symlink uploads; external edit during pull;
stale team revisions; private receipt permissions; plan changes without a matching quote;
payment-pending state hidden from the user; unvalidated portal URLs; personal renewal
canceled before an active team subscription or without explicit confirmation. Fixture outbound is loopback.
"""
import argparse,http.server,json,os,pathlib,subprocess,tempfile,threading,traceback,shutil
p=argparse.ArgumentParser();p.add_argument('--bin',default='zig-out/bin/doin');args=p.parse_args();binary=str(pathlib.Path(args.bin).resolve())
checks=[];commands=[];requests=[];evidence=pathlib.Path('artifacts/team-client');evidence.mkdir(parents=True,exist_ok=True)
class Backend(http.server.BaseHTTPRequestHandler):
 revision=0;content='# Shared\n- [ ] Team task\n';mutate=None
 personal_cancelled=False;team_active=False;change_calls=[];portal_calls=[];personal_pending=False;stale_change=False;reprice_change=False;portal_url='https://billing.stripe.com/p/session/test_fixture'
 def log_message(self,*args):pass
 def request(self):
  assert self.headers.get('Authorization')=='Bearer fixture-team-device-token'
  body=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))) or '{}');requests.append({'method':self.command,'path':self.path,'body':body})
  status=200;payload={};base='/v1/teams/team-fixture'
  if self.path=='/v1/teams/terms':payload={'version':'doin-commercial-1.0','text':'Test commercial terms: internal business self-hosting; no resale.','amount':9900,'interval':'year','billing_mode':'test'}
  elif self.path=='/v1/teams' and self.command=='POST':assert body['accepted_terms']=='doin-commercial-1.0' and body['legal_entity']=='Example LLC';status=201;payload={'id':'team-fixture','name':body['name'],'legal_entity':body['legal_entity']}
  elif self.path=='/v1/teams':payload={'teams':[{'id':'team-fixture','name':'Test team','role':'owner'}]}
  elif self.path==base+'/folders':payload={'folders':[{'id':'root','name':'Home','parent_id':None}]}
  elif self.path==base+'/folders/root':payload={'id':'root','name':'Home','parent_id':None}
  elif self.path==base+'/folders/root/members':payload={'team_id':'team-fixture','folder_id':'root','members':[{'account_id':'owner','name':'Team Owner','email':'owner@example.test'},{'account_id':'member','name':'Team Member','email':'member@example.test'}]}
  elif self.path==base+'/members':payload={'members':[{'account_id':'owner','role':'owner'}]}
  elif self.path==base+'/checkout':assert body['seats']==3;payload={'url':'https://checkout.stripe.com/c/pay/teamfixture'}
  elif self.path==base+'/billing':payload={'paid_seats':3,'next_renewal_seats':3,'occupied_seats':1,'active':type(self).team_active}
  elif self.path=='/v1/account':payload={'email':'owner@example.test','id':'owner'}
  elif self.path=='/v1/billing' and self.command=='GET':payload={'status':'past_due' if type(self).personal_pending else 'active','cancel_at_period_end':type(self).personal_cancelled,'interval':'month','amount':1200,'currency':'usd','pending_update':type(self).personal_pending,'pending_interval':'year' if type(self).personal_pending else None}
  elif self.path=='/v1/billing/change':
   type(self).change_calls.append(body)
   if 'quote_id' not in body and body['interval']=='month':payload={'changed':False,'payment_pending':False,'interval':'month','pending_interval':None}
   elif 'quote_id' not in body:payload={'confirmation_required':True,'quote_id':'quote-fixture','amount_due':4800,'currency':'usd','interval':body['interval'],'expires_at':2000000000,'proration_date':1791111111}
   elif type(self).stale_change:type(self).stale_change=False;status=409;payload={'error':'stale_quote'}
   elif type(self).reprice_change:type(self).reprice_change=False;payload={'confirmation_required':True,'quote_id':'replacement-quote','amount_due':9900,'currency':'usd','interval':body['interval'],'expires_at':2000000000,'proration_date':1791111111}
   else:type(self).personal_pending=True;payload={'changed':False,'payment_pending':True,'interval':'month','pending_interval':body['interval']}
  elif self.path=='/v1/billing/portal' or self.path==base+'/portal':
   type(self).portal_calls.append(self.path);payload={'url':type(self).portal_url}
  elif self.path==base+'/personal-renewal/cancel':
   assert body=={'confirmation':'cancel personal renewal'} and type(self).team_active
   type(self).personal_cancelled=True;payload={'cancel_at_period_end':True}
  elif self.path==base+'/receipt':payload={'receipt':'doin-license-v1.fixture.signature','environment':'test','expires_at':2000000000}
  elif self.path in [base+'/document',base+'/folders/root/document',base+'/export']:
   if self.command=='PUT':
    if body['revision']!=type(self).revision:status=409;payload={'error':'revision_conflict'}
    else:type(self).revision+=1;type(self).content=body['content']
   if status==200:payload={'revision':type(self).revision,'content':type(self).content}
   if type(self).mutate:type(self).mutate();type(self).mutate=None
  else:raise AssertionError(self.path)
  raw=json.dumps(payload).encode();self.send_response(status);self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
 do_GET=request;do_POST=request;do_PUT=request;do_DELETE=request
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Backend);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
try:
 with tempfile.TemporaryDirectory(prefix='doin-team-cli-') as tmp:
  root=pathlib.Path(tmp);config=root/'config';storage=root/'personal';team=root/'team';wrappers=root/'bin';config.mkdir();wrappers.mkdir();env=os.environ.copy();env['DOIN_CONFIG_DIR']=str(config);env['DOIN_NO_ANIMATION']='1';env['PATH']=str(wrappers)+os.pathsep+env['PATH']
  actual_curl=shutil.which('curl');assert actual_curl
  (wrappers/'curl').write_text('#!/usr/bin/env python3\nimport os,sys,urllib.parse\na=sys.argv[1:]\nu=next((x for x in reversed(a) if x.startswith(("http://","https://"))),"")\np=urllib.parse.urlsplit(u)\nif p.hostname not in ("127.0.0.1","localhost","::1"):sys.exit(91)\nos.execv('+repr(actual_curl)+', ['+repr(actual_curl)+']+a)\n');(wrappers/'curl').chmod(0o755)
  browser=root/'browser.log'
  for name in ['open','xdg-open']:(wrappers/name).write_text('#!/bin/sh\nprintf "%s\\n" "$1" >> '+str(browser)+'\n');(wrappers/name).chmod(0o755)
  def run(*a,stdin='',ok=True):
   r=subprocess.run([binary,*a],input=stdin,text=True,capture_output=True,env=env,timeout=20);record={'args':a,'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr};commands.append(record);assert (r.returncode==0)==ok,record;assert 'fixture-team-device-token' not in r.stdout+r.stderr;return r.stdout+r.stderr
  def check(name,fn):
   try:fn();checks.append({'name':name,'passed':True})
   except Exception:checks.append({'name':name,'passed':False,'error':traceback.format_exc()})
  run('init','--storage',str(storage),'--provider','manual')
  (config/'sync.json').write_text(json.dumps({'endpoint':f'http://127.0.0.1:{server.server_port}','token':'fixture-team-device-token'}));(config/'sync.json').chmod(0o600)
  def lifecycle():
   Backend.personal_pending=False
   before=len(requests);run('team','create',stdin='Test team\nExample LLC\nhosted\nno\n');assert not any(r['path']=='/v1/teams' and r['method']=='POST' for r in requests[before:]);assert not (config/'team.json').exists()
   run('team','create',stdin='Test team\nExample LLC\nhosted\nyes\n');assert (config/'team.json').stat().st_mode&0o777==0o600
   before=len(requests);opened=browser.read_text().splitlines() if browser.exists() else [];run('team','subscribe','3',stdin='no\n');assert not any(r['path'].endswith('/checkout') for r in requests[before:]);assert (browser.read_text().splitlines() if browser.exists() else [])==opened
   run('team','subscribe','3',stdin='yes\n');assert 'checkout.stripe.com' in browser.read_text()
   Backend.team_active=False
   before=len(requests);run('team','replace-personal',stdin='yes\n',ok=False);assert not any(r['path'].endswith('/personal-renewal/cancel') for r in requests[before:])
   Backend.team_active=True # Simulate verified Stripe payment completion after checkout.
   before=len(requests);run('team','replace-personal',stdin='no\n');assert not any(r['path'].endswith('/personal-renewal/cancel') for r in requests[before:])
   run('team','replace-personal',stdin='yes\n');assert Backend.personal_cancelled
   Backend.portal_url='https://billing.stripe.com/p/session/test_fixture'
   opened=browser.read_text().splitlines();run('team','portal',stdin='yes\n');assert Backend.portal_calls[-1]=='/v1/teams/team-fixture/portal';assert browser.read_text().splitlines()==opened+['https://billing.stripe.com/p/session/test_fixture']
   run('team','folder',str(team));run('team','pull',stdin='yes\n');assert 'Team task' in (team/'tasks.md').read_text();personal_before=(storage/'tasks.md').read_text();run('add','Actual CLI team edit');assert 'Actual CLI team edit' in (team/'tasks.md').read_text();assert (storage/'tasks.md').read_text()==personal_before;run('assign','1','member');assigned=(team/'tasks.md').read_text();assert 'doin:task=' in assigned and 'member' in assigned and 'Team Member' in assigned;run('assign','1','outsider',ok=False);assert (team/'tasks.md').read_text()==assigned;run('team','push',stdin='yes\n');assert 'Actual CLI team edit' in Backend.content;run('team','personal');before=len(requests);run('assign','1','member',ok=False);assert len(requests)==before;run('add','Private CLI task');assert 'Private CLI task' in (storage/'tasks.md').read_text();assert 'Private CLI task' not in (team/'tasks.md').read_text();run('team','switch','team-fixture');assert json.loads((config/'config.json').read_text())['storage']==str(team.resolve())
   receipt=root/'receipt.txt';run('team','receipt',str(receipt));assert receipt.stat().st_mode&0o777==0o600
  def personal_billing():
   status=run('account','status');assert 'month' in status and 'active' in status and '$12.00 USD' in status
   before=len(Backend.change_calls);same=run('account','change','month');assert 'already on the month interval' in same.lower() and len(Backend.change_calls)==before
   before=len(Backend.change_calls);run('account','change','year',stdin='no\n');assert len(Backend.change_calls)==before+1 and 'quote_id' not in Backend.change_calls[-1]
   before=len(Backend.change_calls);Backend.stale_change=True;run('account','change','year',stdin='yes\n',ok=False);assert len(Backend.change_calls)==before+2 and Backend.change_calls[-1]['quote_id']=='quote-fixture'
   before=len(Backend.change_calls);Backend.reprice_change=True;repriced=run('account','change','year',stdin='yes\n');assert 'Charge changed. No subscription change made. Run account change again to review a fresh quote.' in repriced and len(Backend.change_calls)==before+2 and Backend.change_calls[-1]['quote_id']=='quote-fixture'
   run('account','change','year',stdin='yes\n');assert Backend.change_calls[-1]=={'interval':'year','quote_id':'quote-fixture','confirm_amount':4800};assert 'payment pending for year interval' in run('account','status').lower()
   before=len(Backend.portal_calls);run('account','portal',stdin='yes\n');assert len(Backend.portal_calls)==before+1 and Backend.portal_calls[-1]=='/v1/billing/portal';assert 'billing.stripe.com' in browser.read_text()
   opened=browser.read_text().splitlines();Backend.portal_url='https://user:pass@billing.stripe.com/p/session/unsafe';run('account','portal',stdin='yes\n',ok=False);assert browser.read_text().splitlines()==opened
  check('MORE interval preview confirmation, pending payment state, and payment portal',personal_billing)
  check('terms/entity acceptance, checkout decline/accept, private receipt and explicit Markdown exchange',lifecycle)
  def conflict():
   local=(team/'tasks.md').read_text();Backend.revision+=1;run('team','push',stdin='yes\n',ok=False);assert (team/'tasks.md').read_text()==local
   Backend.mutate=lambda:(team/'tasks.md').write_text('External editor during remote GET\n');result=run('team','pull',stdin='yes\n',ok=False);assert 'TeamLocalEditsChanged' in result;assert (team/'tasks.md').read_text()=='External editor during remote GET\n'
  check('stale push and edit during pull preserve local content',conflict)
  def isolation():
   raw=json.loads((config/'config.json').read_text());original=raw['personal_storage'];raw['personal_storage']=str(team);(config/'config.json').write_text(json.dumps(raw));before=len(requests);run('team','push',stdin='yes\n',ok=False);assert len(requests)==before;raw['personal_storage']=original;(config/'config.json').write_text(json.dumps(raw))
   library=root/'library';projects=library/'Projects';personal=library/'Personal';projects.mkdir(parents=True);personal.mkdir();(personal/'tasks.md').write_text('PRIVATE LIBRARY TASK');raw['personal_storage']=str(projects);raw['library_root']=str(library);(config/'config.json').write_text(json.dumps(raw));before=len(requests);run('team','folder',str(personal),ok=False);assert len(requests)==before;raw['personal_storage']=original;raw['library_root']=original;(config/'config.json').write_text(json.dumps(raw))
   saved=root/'team-original';team.rename(saved);alias=root/'alternate';alias.mkdir();(alias/'tasks.md').write_text('OTHER FOLDER CONTENT');team.symlink_to(alias,target_is_directory=True);before=len(requests);run('team','push',stdin='yes\n',ok=False);assert len(requests)==before;team.unlink();saved.rename(team)
   original_config=config/'config.saved';(config/'config.json').rename(original_config);(config/'config.json').mkdir();before=len(requests);run('team','push',stdin='yes\n',ok=False);assert len(requests)==before;(config/'config.json').rmdir();original_config.rename(config/'config.json')
   (team/'tasks.md').unlink();(team/'tasks.md').symlink_to(storage/'tasks.md');before=len(requests);run('team','push',stdin='yes\n',ok=False);assert len(requests)==before
  check('personal storage remapping and task symlink cannot upload personal files',isolation)
finally:
 server.shutdown();server.server_close();thread.join();(evidence/'report.json').write_text(json.dumps({'checks':checks,'commands':commands,'requests':requests,'reproduce':'python3 tests/team_client_e2e.py --bin zig-out/bin/doin'},indent=2)+'\n')
for check in checks:print(('PASS ' if check['passed'] else 'FAIL ')+check['name'])
if not checks or not all(c['passed'] for c in checks):raise SystemExit(1)
