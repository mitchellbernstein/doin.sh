#!/usr/bin/env python3
"""CLI gateway E2E. Failure census: secret reflection, wrong routes or consent,
unpaid calls, malformed arguments, missing sign-in, terminal controls, task writes.
Only loopback HTTP fixtures run. No provider connection or hosted email request.
"""
import argparse,http.server,json,os,pathlib,subprocess,tempfile,threading,traceback
p=argparse.ArgumentParser();p.add_argument('--bin',default='zig-out/bin/doin');a=p.parse_args();binary=str(pathlib.Path(a.bin).resolve())
evidence=pathlib.Path('artifacts/mcp-cloud-client');evidence.mkdir(parents=True,exist_ok=True);calls=[];receipts=[];paid=True
class Server(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def request(self):
  assert self.headers.get('Authorization')=='Bearer fixture-device-token'
  value=json.loads(self.rfile.read(int(self.headers.get('Content-Length',0))) or '{}')
  calls.append({'method':self.command,'path':self.path,'body':{k:v for k,v in value.items() if k!='token'}})
  if self.command=='POST' and self.path=='/v1/mcp/connections':assert value['token']=='fixture-provider-token'
  if self.path.endswith('/call'):assert value=={'tool':'echo','arguments':{'text':'café'},'confirmation':True}
  payload=json.dumps({'result':'café\u001b[31m'} if self.path.endswith('/call') else {'connections':[]}).encode()
  self.send_response((201 if self.command=='POST' and self.path=='/v1/mcp/connections' else 200) if paid else 402);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(payload)));self.end_headers();self.wfile.write(payload)
 do_GET=request;do_POST=request;do_DELETE=request
server=http.server.HTTPServer(('127.0.0.1',0),Server);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
try:
 with tempfile.TemporaryDirectory(prefix='doin-mcp-gateway-') as folder:
  root=pathlib.Path(folder);config=root/'config';config.mkdir();tasks=root/'tasks';tasks.mkdir();taskfile=tasks/'tasks.md';taskfile.write_text('# Tasks\n- [ ] Keep me\n');before=taskfile.read_bytes()
  (config/'config.json').write_text(json.dumps({'storage':str(tasks),'provider':'manual'}));(config/'sync.json').write_text(json.dumps({'endpoint':f'http://127.0.0.1:{server.server_port}','token':'fixture-device-token'}));env=dict(os.environ,DOIN_CONFIG_DIR=str(config),DOIN_MCP_FIXTURE_TOKEN='fixture-provider-token')
  def run(*args,ok=True):
   r=subprocess.run([binary,'mcp','cloud',*args],env=env,capture_output=True,text=True,timeout=15);receipts.append({'args':[x for x in args],'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr});assert (r.returncode==0)==ok,receipts[-1];assert 'fixture-provider-token' not in r.stdout+r.stderr;return r
  run('list');run('list','--team','team');run('add','teamwork','https://mcp.example.com/mcp','--team','team','--token-env','DOIN_MCP_FIXTURE_TOKEN');assert calls[-1]['body']['team_id']=='team';run('add','work','https://mcp.example.com/mcp','--token-env','DOIN_MCP_FIXTURE_TOKEN');run('tools','work');r=run('call','work','echo',json.dumps({'text':'café'}));assert '\x1b' not in r.stdout
  count=len(calls);run('call','work','echo','[]',ok=False);run('tools','../work',ok=False);assert len(calls)==count
  paid=False;run('call','work','echo',json.dumps({'text':'café'}),ok=False);paid=True;run('remove','work')
  (config/'sync.json').unlink();count=len(calls);run('list',ok=False);assert len(calls)==count and taskfile.read_bytes()==before
 result={'passed':True,'calls':calls,'commands':receipts};print('PASS cloud CLI routes, explicit calls, private token input, unpaid/missing account and task preservation')
except Exception:
 result={'passed':False,'failure':traceback.format_exc(),'calls':calls,'commands':receipts};raise
finally:
 server.shutdown();server.server_close();thread.join(timeout=3);(evidence/'results.json').write_text(json.dumps(result,indent=2))
