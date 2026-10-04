"""Regression census: SIGTERM during notifier forks must preserve claim, reap own children.
Real CLI, fake notifier, no OS notification. Artifact lists process receipts."""
import os,sys,json,pathlib,subprocess,tempfile,time,signal,atexit
ROOT=pathlib.Path(__file__).resolve().parents[1];ART=ROOT/'artifacts/reminder-interrupt';ART.mkdir(parents=True,exist_ok=True);result={'passed':False};cli=None;owned=None
atexit.register(lambda:(ART/'result.json').write_text(json.dumps(result,indent=2)))
with tempfile.TemporaryDirectory(prefix='doin-interrupt-') as tmp:
 d=pathlib.Path(tmp);cfg=d/'config';storage=d/'tasks';shim=d/'shim';shim.mkdir();receipt=d/'receipt.json'
 script='#!'+sys.executable+'\n'+'''import os,signal,subprocess,json,time
child=subprocess.Popen(['sleep','30'])
with open(os.environ['RECEIPT'],'w')as f:json.dump({'pid':os.getpid(),'child':child.pid,'group':os.getpgrp()},f)
signal.signal(signal.SIGTERM,signal.SIG_IGN)
time.sleep(30)
'''
 for name in ['osascript','notify-send']:
  f=shim/name;f.write_text(script);f.chmod(0o755)
 env={**os.environ,'DOIN_CONFIG_DIR':str(cfg),'DOIN_REMINDER_NOW':'1791043200','RECEIPT':str(receipt),'PATH':str(shim)+':'+os.environ['PATH']}
 binary=str(ROOT/'zig-out/bin/doin')
 def run(*args):subprocess.run([binary,*args],env=env,capture_output=True,text=True,timeout=10,check=True)
 run('init','--storage',str(storage),'--provider','manual');(storage/'tasks.md').write_text('- [ ] Interrupted reminder\n');run('remind','1','in','1m');run('remind','enable','--manual');env['DOIN_REMINDER_NOW']='1791043261'
 try:
  cli=subprocess.Popen([binary,'remind','check'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
  until=time.monotonic()+3
  while not receipt.exists() and time.monotonic()<until:time.sleep(.02)
  assert receipt.exists(),'notifier never started';owned=json.loads(receipt.read_text());cli.send_signal(signal.SIGTERM);out,err=cli.communicate(timeout=3)
  assert cli.returncode!=0
  for pid in [owned['pid'],owned['child']]:
   stat=subprocess.run(['ps','-o','stat=','-p',str(pid)],capture_output=True,text=True,timeout=2).stdout.strip();assert not stat or stat.startswith('Z'),(pid,stat)
  state=json.loads(next(cfg.glob('reminders-*.json')).read_text());assert state['records'][0]['status'] in ['claimed','failed']
  result.update(passed=True,receipt=owned,code=cli.returncode,stderr=err,claim=state['records'][0]['status']);print('PASS interrupted native reminder cleans notifier descendants and preserves claim')
 finally:
  if cli and cli.poll()is None:os.killpg(cli.pid,signal.SIGKILL);cli.wait(timeout=3)
  if owned:
   try:os.killpg(owned['group'],signal.SIGKILL)
   except ProcessLookupError:pass
