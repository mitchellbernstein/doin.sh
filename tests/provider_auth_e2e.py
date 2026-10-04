#!/usr/bin/env python3
"""Black-box login and credential lifecycle fixture.
Failure modes (written before auth): absent registration, wrong/repeated state,
PKCE mismatch, denial/timeout, malformed token/expiry, reduced scope, account
changes, unsafe permissions, issuer substitution, refresh rotation/failure,
revocation failure, secret exposure in subprocess arguments.
"""
import argparse,base64,hashlib,json,os,pathlib,socket,subprocess,sys,tempfile,time,urllib.parse

def shim():
 root=pathlib.Path(os.environ['PROVIDER_FIXTURE']);name=pathlib.Path(sys.argv[0]).name
 if name in ('open','xdg-open'):(root/'browser').write_text(sys.argv[-1]);return
 body=sys.stdin.read() if '@-' in sys.argv or '--config' in sys.argv else ''
 url=sys.argv[-1];mode=(root/'mode').read_text();fields=urllib.parse.parse_qs(body)
 assert 'fixture-secret' not in ' '.join(sys.argv)
 if url.endswith('/auth/keys'):
  auth=urllib.parse.parse_qs(urllib.parse.urlparse((root/'browser').read_text()).query);data=json.loads(body)
  challenge=base64.urlsafe_b64encode(hashlib.sha256(data['code_verifier'].encode()).digest()).decode().rstrip('=')
  assert challenge==auth['code_challenge'][0] and data['code']=='fixture-code'
  print(json.dumps({'key':'fixture-secret-router'}));return
 if url.endswith('/device-authorization'):
  assert fields['client_id']==['fixture-client'];print(json.dumps({'device_code':'fixture-device','user_code':'ABCD-EFGH','verification_uri':'https://vercel.com/oauth/device','expires_in':30,'interval':1}));return
 if url.endswith('/userinfo'):
  assert 'Authorization: Bearer fixture-secret-fresh' in body
  print(json.dumps({'sub':'changed-account' if mode=='account' else 'fixture-account'}));return
 if url.endswith('/revoke'):(root/'revoked').write_text('yes');print('{}');return
 assert url.endswith('/token'),url
 if fields['grant_type']==['urn:ietf:params:oauth:grant-type:device_code']:
  assert fields['device_code']==['fixture-device']
  count=int((root/'polls').read_text()) if (root/'polls').exists() else 0;(root/'polls').write_text(str(count+1))
  if mode=='denial':print('{"error":"access_denied"}');return
  if count==0:print('{"error":"authorization_pending"}');return
 else:
  assert fields['grant_type']==['refresh_token'] and fields['refresh_token']==['fixture-refresh']
  if mode=='refresh_failure':raise SystemExit(22)
 print(json.dumps({'access_token':'fixture-secret-fresh','refresh_token':'fixture-rotated','token_type':'Bearer','expires_in':3600,'scope':'openid offline_access' if 'vercel' in url else 'openid profile email offline_access grok-cli:access api:access'}))

if pathlib.Path(sys.argv[0]).name in ('curl','open','xdg-open'):shim();sys.exit()
p=argparse.ArgumentParser();p.add_argument('--driver',required=True);p.add_argument('--out',required=True);args=p.parse_args();driver=str(pathlib.Path(args.driver).resolve());results=[]
with tempfile.TemporaryDirectory() as temp:
 root=pathlib.Path(temp);bin=root/'bin';bin.mkdir();store=root/'store';store.mkdir()
 for name in ['curl','open','xdg-open']:
  f=bin/name;f.write_text('#!'+sys.executable+'\n'+pathlib.Path(__file__).read_text());f.chmod(0o755)
 env=dict(os.environ,PATH=str(bin)+os.pathsep+os.environ['PATH'],PROVIDER_FIXTURE=str(root),DOIN_VERCEL_CLIENT_ID='fixture-client',DOIN_GROK_CLIENT_ID='fixture-client')
 (root/'mode').write_text('valid')
 def run(action,provider,ok=True):
  r=subprocess.run([driver,action,str(store),provider],capture_output=True,text=True,env=env,timeout=20)
  assert (r.returncode==0)==ok,(action,provider,r.stderr);return r
 def record(provider,expiry=None):
  data={'provider':provider,'issuer':{'grok':'https://auth.x.ai','vercel':'https://vercel.com','openrouter':'https://openrouter.ai'}[provider],'access_token':'fixture-secret-cached','refresh_token':'fixture-refresh','client_id':'fixture-client','scope':'openid profile email offline_access grok-cli:access api:access','subject':'fixture-account','expires_at':expiry or int(time.time())+3600}
  f=store/(provider+'.json');f.write_text(json.dumps(data));f.chmod(0o600);return f,data
 for provider in ['grok','vercel','openrouter']:
  f,data=record(provider);assert run('token',provider).stdout=='fixture-secret-cached'
  data['issuer']='https://untrusted.example';f.write_text(json.dumps(data));assert 'InvalidIssuer' in run('token',provider,False).stderr
  f.chmod(0o644);run('token',provider,False)
  results.append({'case':provider+' cached / issuer / permissions','pass':True})
 record('grok',int(time.time())-10);assert run('token','grok').stdout=='fixture-secret-fresh';assert json.loads((store/'grok.json').read_text())['refresh_token']=='fixture-rotated'
 results.append({'case':'refresh rotation','pass':True})
 for mode in ['account','refresh_failure']:
  f,_=record('grok',int(time.time())-10);before=f.read_bytes();(root/'mode').write_text(mode);run('token','grok',False);assert f.read_bytes()==before
  results.append({'case':mode+' preserves credential','pass':True})
 (root/'mode').write_text('valid');f,_=record('openrouter');before=f.read_bytes()
 proc=subprocess.Popen([driver,'login',str(store),'openrouter'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env)
 try:
  deadline=time.time()+5
  while not (root/'browser').exists() and time.time()<deadline:time.sleep(.02)
  q=urllib.parse.parse_qs(urllib.parse.urlparse((root/'browser').read_text()).query);callback=q['callback_url'][0];parsed=urllib.parse.urlparse(callback)
  def callback_request(state):
   with socket.create_connection((parsed.hostname,parsed.port),timeout=3) as s:
    s.sendall(('GET '+parsed.path+'?code=fixture-code&state='+state+' HTTP/1.1\r\nHost: localhost\r\n\r\n').encode());return s.recv(4096)
  assert b'400 Bad Request' in callback_request('wrong-state');assert f.read_bytes()==before and proc.poll() is None
  assert b'200 OK' in callback_request(q['state'][0]);out,err=proc.communicate(timeout=5);assert proc.returncode==0,err;assert 'fixture-secret' not in out+err
  assert json.loads(f.read_text())['access_token']=='fixture-secret-router'
 finally:
  if proc.poll() is None:proc.kill();proc.wait()
 results.append({'case':'OpenRouter actual loopback / wrong state / PKCE exchange','pass':True})
 (root/'browser').unlink();(root/'mode').write_text('valid');run('login','vercel');assert int((root/'polls').read_text())==2
 assert json.loads((store/'vercel.json').read_text())['access_token']=='fixture-secret-fresh'
 results.append({'case':'Vercel device pending then success','pass':True})
 before=(store/'vercel.json').read_bytes();(root/'mode').write_text('denial');run('login','vercel',False);assert (store/'vercel.json').read_bytes()==before
 results.append({'case':'Vercel denial preserves prior connection','pass':True})
 (root/'mode').write_text('valid');run('logout','vercel');assert not (store/'vercel.json').exists() and (root/'revoked').exists()
 results.append({'case':'logout revokes and removes','pass':True})
pathlib.Path(args.out).parent.mkdir(parents=True,exist_ok=True);pathlib.Path(args.out).write_text(json.dumps(results,indent=2)+'\n');print(str(len(results))+' provider auth E2E scenarios passed')
