#!/usr/bin/env python3
"""Real executable MCP stdio fixtures, no unit tests or external services."""
import argparse,json,os,pathlib,signal,subprocess,sys,tempfile,time,traceback
p=argparse.ArgumentParser();p.add_argument('--bin',default='zig-out/bin/doin');args=p.parse_args();binary=str(pathlib.Path(args.bin).resolve())
out=pathlib.Path('artifacts/mcp-client-e2e');out.mkdir(parents=True,exist_ok=True);cases=[];receipts=[]
fixture=r'''import json,os,signal,subprocess,sys,time
from pathlib import Path
mode=sys.argv[1];log=Path(sys.argv[2]);log.parent.mkdir(parents=True,exist_ok=True)
with log.open('a') as f:f.write(json.dumps({'pid':os.getpid(),'argv':sys.argv[3:]})+'\n')
if mode=='hang':
 child=subprocess.Popen([sys.executable,'-c','import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(90)'])
 with log.open('a')as f:f.write(json.dumps({'child':child.pid})+'\n')
 signal.signal(signal.SIGTERM,signal.SIG_IGN)
def send(value):
 data=json.dumps(value)+'\n'
 if mode=='fragment':
  for part in (data[:8],data[8:]):sys.stdout.write(part);sys.stdout.flush();time.sleep(.01)
 else:print(data,end='',flush=True)
for line in sys.stdin:
 request=json.loads(line)
 with log.open('a')as f:f.write(json.dumps(request)+'\n')
 if mode=='hang':continue
 if 'id'not in request:continue
 ident=request['id'];method=request.get('method')
 if mode=='malformed':print('server banner',flush=True);continue
 if mode=='eof':sys.exit(7)
 if mode=='oversize':print('x'*1100000,flush=True);continue
 if method=='initialize':
  assert isinstance(request['params']['capabilities'],dict)
  send({'jsonrpc':'2.0','id':ident+1 if mode=='wrongid' else ident,'result':{'protocolVersion':'2024-11-05'if mode=='old'else'2025-11-25','capabilities':{}if mode=='nocap'else{'tools':{}},'serverInfo':{'name':'fixture','version':'1'}}})
 elif method=='tools/list':
  if mode=='stderr':sys.stderr.write('\x1b[2Junsafe-title\x07'+'z'*80000);sys.stderr.flush()
  send({'jsonrpc':'2.0','method':'notifications/tools/list_changed'})
  first=not request.get('params',{}).get('cursor')
  send({'jsonrpc':'2.0','id':ident,'result':{'tools':[{'name':'echo'if first else'other','description':'local \x1b[2J safe','inputSchema':{'type':'object','properties':{'message':{'type':'string'}}}}],**({'nextCursor':'page2'}if first else{})}})
 elif method=='tools/call':
  if mode=='callhang':continue
  send({'jsonrpc':'2.0','id':ident,'result':{'content':[{'type':'text','text':request['params']['arguments'].get('message','called')+'\x1b[2J'}],'isError':mode=='toolerror'}})
if mode=='nonzero':sys.exit(9)
'''
with tempfile.TemporaryDirectory(prefix='doin-mcp-e2e-')as tmp:
 root=pathlib.Path(tmp);config=root/'config';env=dict(os.environ,DOIN_CONFIG_DIR=str(config),DOIN_MCP_TIMEOUT_MS='700',NO_COLOR='1');server=root/'fixture with spaces.py';server.write_text(fixture)
 subprocess.run([binary,'init','--storage',str(root/'tasks'),'--provider','manual'],env=env,check=True,capture_output=True)
 def run(*argv,ok=True):
  r=subprocess.run([binary,'mcp',*argv],env=env,capture_output=True,text=True,timeout=8);receipts.append({'args':list(argv),'code':r.returncode,'stdout':r.stdout,'stderr':r.stderr})
  assert (r.returncode==0)==ok,(argv,r.stdout,r.stderr);return r
 def add(name,mode):
  log=root/(name+'.jsonl');run('add',name,'--',sys.executable,str(server),mode,str(log),'space arg','$(touch NEVER)','quote"arg');return log
 def logs(path):return [json.loads(v)for v in path.read_text().splitlines()]if path.exists()else[]
 def alive(pid):
  try:os.kill(pid,0)
  except ProcessLookupError:return False
  state=subprocess.run(['ps','-o','stat=','-p',str(pid)],capture_output=True,text=True).stdout.strip();return bool(state)and not state.startswith('Z')
 def cleaned(log):
  for entry in logs(log):
   for key in ('pid','child'):
    if key in entry:assert not alive(entry[key]),('orphan',entry[key])
 def case(name,fn):
  try:fn();cases.append({'name':name,'passed':True})
  except Exception:cases.append({'name':name,'passed':False,'failure':traceback.format_exc()})
  finally:
   for log in root.glob('*.jsonl'):
    for entry in logs(log):
     for key in ('pid','child'):
      if key in entry and alive(entry[key]):
       try:os.kill(entry[key],signal.SIGKILL)
       except ProcessLookupError:pass
 def happy():
  log=add('alpha','fragment');beta=add('beta','fragment');assert not log.exists() and not beta.exists();r=run('list');assert 'alpha'in r.stdout and not log.exists()
  private=config/'mcp-servers.json';assert private.stat().st_mode&0o777==0o600
  before=private.read_bytes();private.chmod(0o644);run('list',ok=False);assert private.read_bytes()==before;private.chmod(0o600)
  r=run('tools','alpha');assert 'echo'in r.stdout and 'other'in r.stdout and '\x1b'not in r.stdout
  run('call','alpha','echo',json.dumps({'message':'Unicode café 東京 and quotes "'}));events=logs(log)
  assert all(e['argv']==['space arg','$(touch NEVER)','quote"arg']for e in events if'argv'in e)
  calls=[e for e in events if e.get('method')=='tools/call'];assert len(calls)==1 and calls[0]['params']['arguments']['message'].startswith('Unicode')
  methods=[e.get('method')for e in events];assert 'notifications/initialized'in methods
  cleaned(log);assert not beta.exists();run('add','alpha','--','no-such-executable',ok=False);run('tools','missing',ok=False)
  run('call','alpha','echo','[]',ok=False);run('call','alpha','missing','{}',ok=False);assert len([e for e in logs(log)if e.get('method')=='tools/call'])==1
  run('remove','alpha');assert 'alpha'not in run('list').stdout;assert not list(config.glob('*.tmp-*'))
 case('private named config; exact argv; versioned fragmented paginated discovery; one manual tool call; invalid requests never execute',happy)
 # Interoperability failure census: inherited isolated configuration, wrong stdio
 # dispatch, protocol/version mismatch, escaping, hidden writes, and cleanup.
 def interoperability():
  taskfile=root/'tasks'/'tasks.md';taskfile.write_text('# Tasks\n- [ ] Actual client to server café 東京\n');before=taskfile.read_bytes()
  run('add','self','--',binary,'mcp','serve')
  discovered=run('tools','self');assert 'doin_read' in discovered.stdout and 'doin_list' in discovered.stdout
  result=run('call','self','doin_read','{}');assert 'Actual client to server' in result.stdout and 'café' in result.stdout
  assert taskfile.read_bytes()==before
  receipts.append({'interoperability':True,'task_document_unchanged':True,'server_executable':binary})
 case('actual native client to native MCP server discovery and explicit read in isolated config',interoperability)
 def failures():
  for mode in ('malformed','wrongid','old','nocap','eof','oversize','nonzero','toolerror','stderr'):
   log=add(mode,mode);r=run('call',mode,'echo','{"message":"safe"}',ok=mode=='stderr');assert '\x1b'not in r.stdout+r.stderr;cleaned(log)
   if mode=='stderr':assert len(r.stderr)<6000
 case('malformed framing IDs versions capability EOF nonzero/tool failures oversized output and stderr flood bounded',failures)
 def timeout_cancel():
  log=add('hung','hang');run('tools','hung',ok=False);cleaned(log)
  log=add('cancel','callhang');process=subprocess.Popen([binary,'mcp','call','cancel','echo','{}'],env=dict(env,DOIN_MCP_TIMEOUT_MS='30000'),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
  deadline=time.monotonic()+4
  while not any(e.get('method')=='tools/call'for e in logs(log)):
   assert time.monotonic()<deadline;time.sleep(.02)
  os.kill(process.pid,signal.SIGTERM);stdout,stderr=process.communicate(timeout=4);assert process.returncode!=0;cleaned(log)
  receipts.append({'cancel_code':process.returncode,'stdout':stdout,'stderr':stderr})
 case('timeout and SIGTERM during actual tool call close stdin then reap exact owned server and stubborn descendant',timeout_cancel)
 for path in root.glob('*.jsonl'):
  (out/path.name).write_text(path.read_text())
(out/'results.json').write_text(json.dumps({'cases':cases,'commands':receipts},indent=2))
for c in cases:print(('PASS 'if c['passed']else'FAIL ')+c['name'])
sys.exit(0 if all(c['passed']for c in cases)else 1)
