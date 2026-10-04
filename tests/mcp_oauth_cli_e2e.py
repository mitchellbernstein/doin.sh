#!/usr/bin/env python3
"""OAuth/grants CLI E2E failure census before implementation: secrets in args/output,
untrusted browser URL, silent approval, invalid/superset scopes, wrong client/redirect,
account absence, declined consent, folder selection lost, revocation needs paid access.
Only isolated HTTP fixture; browser command stub records URLs; no provider data transfer.
"""
import argparse,http.server,json,os,pathlib,subprocess,tempfile,threading,traceback
p=argparse.ArgumentParser();p.add_argument('--bin',default='zig-out/bin/doin');a=p.parse_args();binary=str(pathlib.Path(a.bin).resolve());calls=[];commands=[];evidence=pathlib.Path('artifacts/mcp-oauth-cli');evidence.mkdir(parents=True,exist_ok=True);rid='c'*64;evil=False
class Server(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def request(self):
  assert self.headers.get('Authorization')=='Bearer fixture-device-token'
  data=json.loads(self.rfile.read(int(self.headers.get('Content-Length',0))) or '{}');calls.append({'method':self.command,'path':self.path,'body':{k:v for k,v in data.items() if k!='client_secret'}})
  if self.path.endswith('/oauth') and self.command=='POST':
   assert data=={'scope':'read','client_id':'fixture-client','client_secret':'fixture-oauth-secret'};reply={'authorization_url':'http://127.0.0.1/stolen' if evil else 'https://provider.example.com/authorize?state=fixture'}
  elif self.path.endswith('/requests/'+rid):reply={'request_id':rid,'client_id':'https://client.example.com/metadata.json','client_name':'Fixture\u001b[31m','client_domain':'client.example.com','redirect_is_loopback':True,'redirect_uri':'http://127.0.0.1:9876/callback','scopes':['tasks:read','tasks:write'],'status':'pending','expires_at':9999999999}
  elif self.path.endswith('/approve'):
   assert data['client_id']=='https://client.example.com/metadata.json' and data['redirect_uri']=='http://127.0.0.1:9876/callback';assert data['confirmation'] is True and data['scopes']==['tasks:read'];reply={'approved':True}
  elif self.path.endswith('/deny'):assert data=={'request_id':rid,'confirmation':True};reply={'denied':True}
  else:reply={'grants':[]} if self.command=='GET' else {'revoked':True}
  payload=json.dumps(reply).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(payload)));self.end_headers();self.wfile.write(payload)
 do_GET=request;do_POST=request;do_DELETE=request
server=http.server.HTTPServer(('127.0.0.1',0),Server);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start();result={}
try:
 with tempfile.TemporaryDirectory(prefix='doin-oauth-cli-') as folder:
  root=pathlib.Path(folder);config=root/'config';config.mkdir();tasks=root/'tasks';tasks.mkdir();taskfile=tasks/'tasks.md';taskfile.write_text('- [ ] Keep\n');before=taskfile.read_bytes();(config/'config.json').write_text(json.dumps({'storage':str(tasks),'provider':'manual'}));(config/'sync.json').write_text(json.dumps({'endpoint':f'http://127.0.0.1:{server.server_port}','token':'fixture-device-token'}));browser=root/'browser';browserlog=root/'browser.log';browser.write_text('#!/bin/sh\nprintf "%s\\n" "$1" >> "$DOIN_BROWSER_LOG"\n');browser.chmod(0o700)
  env=dict(os.environ,DOIN_CONFIG_DIR=str(config),DOIN_BROWSER_COMMAND=str(browser),DOIN_BROWSER_LOG=str(browserlog),DOIN_FIXTURE_SECRET='fixture-oauth-secret',TERM='dumb')
  def run(*args,stdin='',ok=True):
   r=subprocess.run([binary,'mcp','cloud',*args],input=stdin,env=env,capture_output=True,text=True,timeout=15);commands.append({'args':args,'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr});assert (r.returncode==0)==ok,commands[-1];assert 'fixture-oauth-secret' not in r.stdout+r.stderr;return r
  run('oauth','provider','--scope','read','--client-id','fixture-client','--client-secret-env','DOIN_FIXTURE_SECRET');assert 'https://provider.example.com/authorize' in browserlog.read_text();size=browserlog.stat().st_size;evil=True;run('oauth','provider','--scope','read','--client-id','fixture-client','--client-secret-env','DOIN_FIXTURE_SECRET',ok=False);assert browserlog.stat().st_size==size;evil=False
  run('oauth-revoke','provider');run('grants','list');r=run('grants','review',rid,stdin='cancel\n');assert 'client.example.com' in r.stdout and 'local' in r.stdout.lower() and '\x1b' not in r.stdout;assert not any(c['path'].endswith('/approve') for c in calls)
  run('grants','review',rid,stdin='approve\ntasks:read\n');approved=[c for c in calls if c['path'].endswith('/approve')];assert len(approved)==1 and 'team_id' not in approved[0]['body']
  run('grants','review',rid,'--folder','child',stdin='approve\ntasks:read\n');assert calls[-1]['body']['folder_id']=='child' and 'team_id' not in calls[-1]['body'];run('grants','review',rid,'--team','team','--folder','folder',stdin='approve\ntasks:read\n');assert calls[-1]['body']['team_id']=='team' and calls[-1]['body']['folder_id']=='folder'
  count=len([c for c in calls if c['path'].endswith('/approve')]);run('grants','review',rid,stdin='approve\nadmin:all\n',ok=False);assert len([c for c in calls if c['path'].endswith('/approve')])==count
  run('grants','review',rid,stdin='deny\n');run('grants','revoke',rid);(config/'sync.json').unlink();count=len(calls);run('grants','list',ok=False);assert len(calls)==count and before==taskfile.read_bytes()
 result={'passed':True,'calls':calls,'commands':commands};print('PASS OAuth/grants CLI secrets, HTTPS browser, explicit scopes, canceled/denied consent, folder scope and account gating')
except Exception:result={'passed':False,'failure':traceback.format_exc(),'calls':calls,'commands':commands};raise
finally:server.shutdown();server.server_close();thread.join(timeout=3);(evidence/'results.json').write_text(json.dumps(result,indent=2))
