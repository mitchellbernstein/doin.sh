#!/usr/bin/env python3
"""Real CLI reminder scenarios, written before reminder implementation.
Failure census: DST fold/gap and bad dates; malformed duration; numbering/fences;
duplicate IDs; title edits/deletion/reopen; concurrent checks and doc edits; history
write failure; disabled settings; notifier errors/injection; scheduler failure;
late reminders; no real OS notifications or persistent agents are used.
"""
import argparse,datetime,fcntl,hashlib,json,os,pathlib,re,subprocess,sys,tempfile,traceback,zoneinfo,time
p=argparse.ArgumentParser();p.add_argument('--bin',default='zig-out/bin/doin');a=p.parse_args();binary=str(pathlib.Path(a.bin).resolve())
artifacts=pathlib.Path('artifacts/reminders');artifacts.mkdir(parents=True,exist_ok=True)
commands=[];cases=[];notifications=[];scheduler=[]
with tempfile.TemporaryDirectory(prefix='doin-reminder-e2e-') as tmp:
 root=pathlib.Path(tmp);storage=root/'tasks & notes';config=root/'config space';shim=root/'shim';shim.mkdir()
 notify=root/'notifications.jsonl';launch=root/'launchctl.jsonl'
 script='#!'+sys.executable+'\n'+'''import json,os,pathlib,sys,signal,subprocess,time
kind=pathlib.Path(sys.argv[0]).name
log=os.environ['DOIN_REMINDER_LAUNCH_LOG' if kind in ('launchctl','systemctl') else 'DOIN_REMINDER_NOTIFY_LOG']
with open(log,'a') as f:f.write(json.dumps({'command':kind,'args':sys.argv[1:]})+'\\n')
if os.environ.get('DOIN_REMINDER_HANG')==kind:
 child=subprocess.Popen(['sleep','30'])
 with open(log,'a') as f:f.write(json.dumps({'hang_pid':os.getpid(),'child_pid':child.pid,'pgid':os.getpgrp()})+'\\n')
 signal.signal(signal.SIGTERM,signal.SIG_IGN)
 time.sleep(30)
if os.environ.get('DOIN_REMINDER_FAIL')==kind:raise SystemExit(7)
'''
 for name in ['osascript','notify-send','launchctl','systemctl']:
  file=shim/name;file.write_text(script);file.chmod(0o755)
 env=os.environ.copy();env.update(DOIN_CONFIG_DIR=str(config),DOIN_REMINDER_AGENT_DIR=str(root/'agents'),DOIN_SYSTEMD_UNIT_DIR=str(root/'units'),DOIN_REMINDER_NOTIFY_LOG=str(notify),DOIN_REMINDER_LAUNCH_LOG=str(launch),DOIN_REMINDER_NOW='1791043200',TZ='America/Chicago',PATH=str(shim)+':'+env['PATH'])
 start=int(env['DOIN_REMINDER_NOW']);taskfile=storage/'tasks.md'
 def run(*args,stdin='',ok=True):
  result=subprocess.run([binary,*args],env=env,input=stdin,text=True,capture_output=True,timeout=15)
  commands.append({'args':args,'exit':result.returncode,'stdout':result.stdout,'stderr':result.stderr})
  assert (result.returncode==0)==ok,commands[-1]
  return result.stdout+result.stderr
 def journal(file):return [json.loads(line) for line in file.read_text().splitlines()] if file.exists() else []
 def due(index=0):return int(re.findall(r'doin:id=[0-9a-f]{32} remind=([0-9]+)',taskfile.read_text())[index])
 def case(name,fn):
  try:fn();cases.append({'name':name,'passed':True})
  except Exception:cases.append({'name':name,'passed':False,'failure':traceback.format_exc()})
 original='# Launch café\n\nBudget $300. Preserve prose and [links](https://example.org).\n\n- [ ] Review migration\n- [ ] Ship "quotes" & $(touch NEVER) safely\n  * [ ] Restore staged backup\n\n````text\n```\n- [ ] Fenced example must not count\n```\n````\n'
 def portable():
  run('init','--storage',str(storage),'--provider','manual');taskfile.write_text(original)
  assert 'off' in run('remind','status').lower()
  run('remind','2','in','15m');assert due()==start+900
  assert '2026-10-03 11:15 CDT' in run('remind','list')
  assert 'doin:id=' not in run('list') and 'Ship "quotes"' in run('list')
  assert original.split('- [ ] Ship')[0] in taskfile.read_text()
  run('remind','check');assert not journal(notify) and not journal(launch)
  state=list(config.glob('reminders-*.json'));assert len(state)==1 and state[0].stat().st_mode&0o777==0o600
  run('undo');assert taskfile.read_text()==original
  run('remind','2','in','15m');assert due()==start+900
  # A synced folder on another device keeps the portable due but defaults off.
  remote_config=root/'other device';second=env.copy();second['DOIN_CONFIG_DIR']=str(remote_config)
  r=subprocess.run([binary,'init','--storage',str(storage),'--provider','manual'],env=second,capture_output=True,text=True);assert r.returncode==0
  r=subprocess.run([binary,'remind','status'],env=second,capture_output=True,text=True);assert 'off' in (r.stdout+r.stderr).lower()
  assert not journal(notify)
 case('explicit opt-in, portable Markdown due, clean titles, undo, and private per-device state',portable)
 # Failure census: property JSON containing status syntax must stay hidden, and setting/off must preserve both property and assignment identity comments byte-for-byte.
 def metadata():
  before_metadata=taskfile.read_text()
  comments=' <!-- doin:values={"'+'a'*32+'":"@status(blocked)"} --> <!-- doin:task='+'b'*32+' -->'
  taskfile.write_text('- [ ] Metadata title'+comments+'\n');run('remind','1','in','15m');assert comments in taskfile.read_text();shown=run('list');assert 'Metadata title' in shown and 'doin:values' not in shown and 'doin:task' not in shown
  run('remind','1','off');assert comments in taskfile.read_text();assert 'remind=' not in taskfile.read_text();taskfile.write_text(before_metadata)
 case('property and assignment comments remain private and survive reminder edits',metadata)
 def completion_metadata():
  before_metadata=taskfile.read_text();identity='0123456789abcdef0123456789abcdef'
  valid='- [x] Completed label <!-- doin:completed=2026-10-04 --> <!-- doin:values={"portable":true} --> <!-- doin:task=11111111111111111111111111111111 --> <!-- doin:id='+identity+' remind=1893456000 -->\n'
  malformed='- [ ] Keep malformed <!-- doin:completed=2026-99-99 --> visible\n'
  quoted='- [ ] Keep quoted <!-- opaque:{"quoted":" <!-- doin:completed=2026-10-04 -->"} --> visible\n'
  taskfile.write_text(valid+malformed+quoted)
  shown=run('list');completed_line=next(line for line in shown.splitlines() if 'Completed label' in line);assert 'doin:completed=' not in completed_line
  assert 'doin:completed=2026-99-99' in shown and 'opaque:' in shown and 'visible' in shown
  listed=run('remind','list');assert 'Completed label' in listed and 'doin:completed=' not in listed
  run('remind','1','off');after=taskfile.read_text();assert '<!-- doin:completed=2026-10-04 -->' in after and 'remind=' not in after and '<!-- doin:id='+identity+' -->' in after
  taskfile.write_text(before_metadata)
 case('valid completion metadata stays private before final reminders while malformed and quoted lookalikes remain content',completion_metadata)
 def delivery():
  run('remind','enable','--manual');assert not journal(launch)
  # Renumber and edit title without touching metadata identity.
  data=taskfile.read_text();taskfile.write_text('- [ ] Urgent new task\n'+data.replace('Ship "quotes"','Ship revised "quotes"'))
  env['DOIN_REMINDER_NOW']=str(start+901)
  one=subprocess.Popen([binary,'remind','check'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
  two=subprocess.Popen([binary,'remind','check'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
  first=one.communicate(timeout=15);second=two.communicate(timeout=15)
  assert one.returncode==0 or two.returncode==0,(first,second)
  assert len(journal(notify))==1
  args=journal(notify)[0]['args'];assert args[-1]=='Ship revised "quotes" & $(touch NEVER) safely'
  assert 'Ship revised' not in args[args.index('-e')+1] if '-e' in args else True
  run('remind','check');assert len(journal(notify))==1
  assert not (root/'NEVER').exists()
  run('done','3');run('remind','check');run('reopen','3');run('remind','check');assert len(journal(notify))==1
  # Explicit reschedule is needed for another attempt.
  run('remind','3','in','1m');env['DOIN_REMINDER_NOW']=str(start+962)
  env['DOIN_REMINDER_FAIL']='osascript' if sys.platform=='darwin' else 'notify-send'
  run('remind','check',ok=False);count=len(journal(notify));assert count==2
  env.pop('DOIN_REMINDER_FAIL');run('remind','check');assert len(journal(notify))==count
  assert 'failed' in run('remind','list').lower()
  run('remind','retry','3');run('remind','check');assert len(journal(notify))==count+1
 case('renumbered edited tasks, concurrent checks, safe notification argv, reopen, and failed-delivery retry',delivery)
 def dates():
  env['DOIN_REMINDER_NOW']=str(start);before=taskfile.read_bytes()
  for text in ['in 0m','in 999999999999999999999h','2027-02-30 09:00','2027-03-14 02:30','2027-11-07 01:30']:
   run('remind','1',text,ok=False);assert taskfile.read_bytes()==before
  run('remind','1','2027-11-07T01:30:00-05:00');first=due(0)
  run('remind','1','2027-11-07T01:30:00-06:00');assert due(0)-first==3600
  run('remind','1','tomorrow','09:00')
  local=datetime.datetime.fromtimestamp(start,zoneinfo.ZoneInfo('America/Chicago'));next_day=local.date()+datetime.timedelta(days=1)
  expected=int(datetime.datetime.combine(next_day,datetime.time(9),tzinfo=zoneinfo.ZoneInfo('America/Chicago')).timestamp());assert due(0)==expected
  run('remind','1','off');assert '- [ ] Urgent new task <!-- doin:id=' in taskfile.read_text()
 case('relative/local times, calendar validation, DST gaps/folds, explicit offsets and tomorrow',dates)
 def safety():
  env['DOIN_REMINDER_NOW']=str(start+2000);run('remind','1','in','1m')
  data=taskfile.read_text();marked=next(line for line in data.splitlines() if 'Urgent new task <!-- doin:id=' in line)
  taskfile.write_text(data+'\n'+marked+'\n');env['DOIN_REMINDER_NOW']=str(start+2061);count=len(journal(notify))
  run('remind','check',ok=False);assert len(journal(notify))==count
  taskfile.write_text(data)
  lock=open(storage/'.tasks.lock','a');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
  try:run('remind','1','in','5m',ok=False)
  finally:lock.close()
  assert taskfile.read_text()==data
  # Completed/deleted task never delivers; stale reminders remain visible as missed.
  run('done','1');run('remind','check');assert len(journal(notify))==count
  run('reopen','1');run('remind','check');assert len(journal(notify))==count
  run('remind','1','in','1m');env['DOIN_REMINDER_NOW']=str(start+2061+60+86401)
  run('remind','check');assert len(journal(notify))==count and 'missed' in run('remind','list').lower()
  run('remind','retry','1');run('remind','check');assert len(journal(notify))==count+1
  run('remind','disable');assert 'off' in run('remind','status').lower()
 case('duplicate IDs, lock contention, completion/reopen, and visible missed reminders',safety)
 def scheduling():
  if sys.platform=='linux':
   env['DOIN_REMINDER_FAIL']='systemctl';run('remind','enable',ok=False);env.pop('DOIN_REMINDER_FAIL');assert 'off' in run('remind','status').lower()
   assert not list((root/'units').glob('*.timer')) and not list((root/'units').glob('*.service'))
   run('remind','enable');timers=list((root/'units').glob('*.timer'));services=list((root/'units').glob('*.service'));assert len(timers)==len(services)==1
   timer=timers[0].read_text();service=services[0].read_text();assert 'OnUnitInactiveSec=60s' in timer and 'Type=oneshot' in service and 'KillMode=control-group' in service and 'TimeoutStartSec=50s' in service
   assert 'remind' in service and 'check' in service and 'DOIN_CONFIG_DIR=' in service
   run('remind','disable');assert not timers[0].exists() and not services[0].exists() and 'off' in run('remind','status').lower()
   calls=journal(launch);assert any(x['command']=='systemctl' and x['args'][1:3]==['enable','--now']for x in calls);assert any(x['command']=='systemctl' and x['args'][1:3]==['disable','--now']for x in calls)
   return
  if sys.platform!='darwin':return
  env['DOIN_REMINDER_FAIL']='launchctl';run('remind','enable',ok=False);env.pop('DOIN_REMINDER_FAIL')
  assert 'off' in run('remind','status').lower()
  run('remind','enable');agents=list((root/'agents').glob('*.plist'));assert len(agents)==1
  import plistlib
  plist=plistlib.loads(agents[0].read_bytes());assert plist['StartInterval']==60 and 'KeepAlive' not in plist
  assert plist['ProgramArguments'][0]==binary and plist['ProgramArguments'][1:]==['remind','check']
  assert plist['EnvironmentVariables']['DOIN_CONFIG_DIR']==str(config)
  run('remind','disable');assert not agents[0].exists() and 'off' in run('remind','status').lower()
 case('explicit scheduler opt-in, failed registration stays off, escaped paths and bounded user scheduler',scheduling)
 def hanging():
  run('remind','enable','--manual');taskfile.write_text('- [ ] --danger "quote" $(touch NEVER)\n')
  env['DOIN_REMINDER_NOW']=str(start);run('remind','1','in','1m');env['DOIN_REMINDER_NOW']=str(start+61)
  env['DOIN_REMINDER_HANG']='osascript' if sys.platform=='darwin' else 'notify-send'
  run('remind','check',ok=False);env.pop('DOIN_REMINDER_HANG')
  event=next(x for x in reversed(journal(notify)) if 'hang_pid' in x)
  for key in ['hang_pid','child_pid']:
   live=True
   for _ in range(20):
    stat=subprocess.run(['ps','-o','stat=','-p',str(event[key])],capture_output=True,text=True).stdout.strip()
    live=bool(stat) and not stat.startswith('Z')
    if not live:break
    time.sleep(.1)
   assert not live,event
  event['verified_no_live_processes']=True
  notifications.append(event)
  captured=next(x for x in reversed(journal(notify)) if 'args' in x)['args']
  assert captured[-1]=='--danger "quote" $(touch NEVER)' and '--' in captured
  assert not (root/'NEVER').exists()
 case('hanging notifier group cleaned, leading-option task stays literal argv',hanging)
 notifications=journal(notify)+notifications;scheduler=journal(launch)
report={'binary':binary,'sha256':hashlib.sha256(pathlib.Path(binary).read_bytes()).hexdigest(),'cases':cases,'commands':commands,'notifications':notifications,'scheduler':scheduler,'real_os_effects':False}
(artifacts/'results.json').write_text(json.dumps(report,indent=2))
(artifacts/'transcript.md').write_text('# Reminder E2E\n\n'+'\n'.join('## '+ ' '.join(c['args'])+'\n```text\n'+c['stdout']+c['stderr']+'\n```\n' for c in commands))
for c in cases:print(('PASS' if c['passed'] else 'FAIL')+' '+c['name'])
raise SystemExit(0 if all(c['passed'] for c in cases) else 1)
