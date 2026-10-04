#!/usr/bin/env python3
"""Real CLI and bounded incremental curl fixture; saves temporal and file evidence."""
import argparse, json, os, pathlib, select, signal, subprocess, sys, tempfile, time, traceback

def shim():
 root=pathlib.Path(os.environ['DOIN_STREAM_FIXTURE']);mode=(root/'mode').read_text();body=sys.stdin.read()
 assert 'fixture-access'in body and 'fixture-access'not in' '.join(sys.argv)
 (root/'curl-pid').write_text(str(os.getpid()))
 def event(v):
  encoded=json.dumps(v,ensure_ascii=False,indent=2)
  data=(': fixture comment\r\n'+'\r\n'.join('data: '+line for line in encoded.splitlines())+'\r\n\r\n').encode()
  for offset in range(0,len(data),7):os.write(1,data[offset:offset+7])
 text='Live café 東京 ready.'
 if mode=='controls':
  event({'type':'response.output_text.delta','delta':'Live café \x1b'});event({'type':'response.output_text.delta','delta':'[2J東京 ready.'});text='Live café \x1b[2J東京 ready.'
 else:event({'type':'response.output_text.delta','delta':text})
 (root/'delta-sent').write_text('yes')
 if mode=='cancel':time.sleep(15);return
 time.sleep(1.2)
 if mode=='partial':return
 if mode=='malformed':os.write(1,b'data: {bad json}\n\n');return
 if mode=='oversize':os.write(1,b'data: '+b'x'*1100000+b'\n\n');return
 if mode=='refusal':event({'type':'response.refusal.delta','delta':'Cannot comply'});return
 if mode=='failed':event({'type':'response.failed','response':{'status':'failed'}});return
 if mode=='incomplete':event({'type':'response.incomplete','response':{'status':'incomplete'}});return
 final='DIFFERENT'if mode=='mismatch'else text
 event({'type':'response.completed','response':{'id':'resp_fixture','status':'completed','output':[{'type':'message','role':'assistant','content':[{'type':'output_text','text':final}]}]}})
 (root/'completion-sent').write_text('yes')
 if mode=='httpfail':raise SystemExit(22)

def main():
 p=argparse.ArgumentParser();p.add_argument('--bin',default='zig-out/bin/doin');p.add_argument('--artifacts',default='artifacts/streaming-e2e');args=p.parse_args()
 binary=pathlib.Path(args.bin).resolve();artifacts=pathlib.Path(args.artifacts).resolve();artifacts.mkdir(parents=True,exist_ok=True);checks=[];receipts=[]
 with tempfile.TemporaryDirectory(prefix='doin-stream-e2e-')as tmp:
  root=pathlib.Path(tmp);config=root/'config';storage=root/'tasks';bindir=root/'bin';bindir.mkdir();curl=bindir/'curl'
  curl.write_text('#!'+sys.executable+'\n'+pathlib.Path(__file__).read_text());curl.chmod(0o755)
  env=dict(os.environ,DOIN_CONFIG_DIR=str(config),DOIN_STREAM_FIXTURE=str(root),PATH=str(bindir)+os.pathsep+os.environ['PATH'],NO_COLOR='1')
  subprocess.run([binary,'init','--storage',str(storage),'--provider','manual'],env=env,check=True,capture_output=True)
  path=config/'config.json';setting=json.loads(path.read_text());setting.update(provider='chatgpt',model='fixture-model',endpoint='https://api.openai.com/v1');path.write_text(json.dumps(setting))
  token=config/'chatgpt.json';token.write_text(json.dumps({'access_token':'fixture-access','scope':'openid profile email offline_access resource.invoke chatgpt.tokens.use.direct','expires_at':int(time.time())+3600}));token.chmod(0o600)
  taskfile=storage/'tasks.md';taskfile.write_text('# Café launch\n\n- [ ] Keep the existing task\n');baseline=taskfile.read_bytes()
  def case(name,fn):
   try:fn();checks.append({'name':name,'passed':True})
   except Exception:checks.append({'name':name,'passed':False,'failure':traceback.format_exc()})
  def run(mode,generate=False,cancel=False):
   for marker in('delta-sent','completion-sent','curl-pid'):(root/marker).unlink(missing_ok=True)
   (root/'mode').write_text(mode)
   argv=[str(binary),'generate'if generate else'ask','Review the launch']+(['--yes']if generate else[])
   process=subprocess.Popen(argv,env=env,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
   output=bytearray();early=False;deadline=time.monotonic()+8
   try:
    while process.poll()is None and time.monotonic()<deadline:
     ready,_,_=select.select([process.stdout],[],[],0.05)
     if ready:
      chunk=os.read(process.stdout.fileno(),65536);output.extend(chunk)
      if b'Live caf'in output and not(root/'completion-sent').exists():early=True
     if cancel and(root/'delta-sent').exists():process.send_signal(signal.SIGTERM);cancel=False
    if process.poll()is None:
     receipts.append({'mode':mode,'argv':argv[1:],'exit':None,'stdout':output.decode(errors='replace'),'failure':'stream exceeded 8s deadline','text_before_completion':early,'markdown':taskfile.read_text()})
     raise AssertionError('stream process exceeded bounded test deadline')
    rest,stderr=process.communicate(timeout=2);output.extend(rest);text=output.decode(errors='replace')
    receipts.append({'mode':mode,'argv':argv[1:],'exit':process.returncode,'stdout':text,'stderr':stderr.decode(errors='replace'),'text_before_completion':early,'markdown':taskfile.read_text()})
    if mode in('success','controls'):
     assert process.returncode==0,receipts[-1]
     assert early,'text was buffered until completion'
     if mode=='controls':assert '\x1b'not in text and'[2J'not in text
     if generate:assert'Live café'in taskfile.read_text();subprocess.run([binary,'undo'],env=env,check=True,capture_output=True)
    else:assert process.returncode!=0,receipts[-1]
    assert taskfile.read_bytes()==baseline
    assert'fixture-access'not in text+stderr.decode(errors='replace')
    if(root/'curl-pid').exists():
     pid=int((root/'curl-pid').read_text())
     try:os.kill(pid,0)
     except ProcessLookupError:pass
     else:raise AssertionError('owned curl fixture survives '+str(pid))
   finally:
    if process.poll()is None:os.killpg(process.pid,signal.SIGKILL)
    if(root/'curl-pid').exists():
     owned_pid=int((root/'curl-pid').read_text())
     command=subprocess.run(['ps','-p',str(owned_pid),'-o','command='],capture_output=True,text=True).stdout
     if str(curl)in command:
      try:os.killpg(owned_pid,signal.SIGKILL)
      except ProcessLookupError:pass
    process.communicate(timeout=2)
  case('fragmented CRLF multiline SSE and UTF-8 arrive before completion',lambda:run('success'))
  case('validated complete generation saves once and undo restores original',lambda:run('success',True))
  case('ANSI sequences split across deltas cannot control terminal',lambda:run('controls'))
  for mode in('partial','malformed','refusal','failed','incomplete','mismatch','oversize','httpfail'):
   case(mode+' never commits partial generated text',lambda mode=mode:run(mode,True))
  case('SIGTERM during live stream kills exact provider child without document write',lambda:run('cancel',True,True))
 (artifacts/'results.json').write_text(json.dumps({'checks':checks,'commands':receipts,'network':'no network; incremental curl shim','command':'python3 tests/streaming_e2e.py --bin '+str(binary)},ensure_ascii=False,indent=2))
 for check in checks:print(('PASS 'if check['passed']else'FAIL ')+check['name'])
 assert all(check['passed']for check in checks)

if pathlib.Path(sys.argv[0]).name=='curl':shim()
elif __name__=='__main__':main()
