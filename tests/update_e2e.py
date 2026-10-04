#!/usr/bin/env python3
"""Drive real CLI copies against pinned offline release archives; save receipts.
Failures: no setup, corrupt settings, current/newer installed, checksum tampering,
missing/duplicate checksum, symlink payload, mismatched/hanging executable,
network failure, malformed release, interruption and changed destination.
"""
import argparse, hashlib, io, json, os, pathlib, shutil, signal, subprocess, sys, tarfile, tempfile, time, traceback, pty, select, fcntl, termios, struct
p=argparse.ArgumentParser();p.add_argument('--bin',default='zig-out/bin/doin');p.add_argument('--artifacts',default='artifacts/update-e2e');p.add_argument('--candidate',default='');args=p.parse_args()
binary=pathlib.Path(args.bin).resolve();artifacts=pathlib.Path(args.artifacts).resolve();artifacts.mkdir(parents=True,exist_ok=True)
cases=[];commands=[]
def snapshot(root):
 return {str(f.relative_to(root)):hashlib.sha256(f.read_bytes()).hexdigest() for f in root.rglob('*') if f.is_file() and not f.is_symlink()}
with tempfile.TemporaryDirectory(prefix='doin-update-') as tmp:
 suite=pathlib.Path(tmp)
 def fixture(name,mode='valid',version='0.4.0'):
  root=suite/name;root.mkdir();install=root/'bin space';install.mkdir();exe=install/'doin';shutil.copy2(binary,exe)
  home=root/'home';storage=home/'Documents/doin';storage.mkdir(parents=True);(storage/'tasks.md').write_text('# Migration café\n\n- [ ] Keep my notes\n');(storage/'nested').mkdir();(storage/'nested/context.md').write_text('Nested content')
  config=root/'config';config.mkdir();(config/'config.json').write_text('{broken');(config/'provider-api.key').write_text('private-fixture-secret');(config/'provider-api.key').chmod(0o600)
  dist=root/'dist';dist.mkdir();shim=root/'shim';shim.mkdir();log=root/'requests.jsonl'
  arch='aarch64' if os.uname().machine in ('arm64','aarch64') else 'x86_64';platform='macos' if sys.platform=='darwin' else 'linux';archive=f'doin-{platform}-{arch}.tar.gz'
  payload=pathlib.Path(args.candidate).read_bytes() if args.candidate and mode in ('valid','changed') and version=='0.4.0' else b'#!/bin/sh\nprintf "doin '+version.encode()+b'\\n"\n'
  if mode=='descendant':payload=b'#!/bin/sh\nsleep 30 >/dev/null 2>&1 &\necho $! > "$UPDATE_FIXTURE/descendant.pid"\nprintf "doin 0.4.0\\n"\n'
  if mode=='large':payload+=b'#'+b'x'*(4*1024*1024)+b'\n'
  if mode=='version':payload=b'#!/bin/sh\nprintf "doin 9.9.9\\n"\n'
  if mode=='candidate-hang':payload=b'#!/bin/sh\nsleep 30\n'
  if mode=='candidate-eof-hang':payload=b'#!/bin/sh\nexec 1>&- 2>&-\nsleep 30\n'
  with tarfile.open(dist/archive,'w:gz') as bundle:
   info=tarfile.TarInfo('doin');info.mode=0o755
   if mode=='symlink':info.type=tarfile.SYMTYPE;info.linkname=str(exe);bundle.addfile(info)
   else:info.size=len(payload);bundle.addfile(info,io.BytesIO(payload))
   info=tarfile.TarInfo('LICENSE');info.size=7;bundle.addfile(info,io.BytesIO(b'license'))
  digest=hashlib.sha256((dist/archive).read_bytes()).hexdigest()
  checksum=('0'*64 if mode=='checksum' else digest)+'  '+archive+'\n'
  if mode=='missing':checksum=digest+'  another-platform.tar.gz\n'
  if mode=='duplicate':checksum+=checksum
  (dist/'SHA256SUMS').write_text(checksum)
  metadata={'tag_name':'v'+version,'draft':False,'prerelease':False,'assets':[{'name':archive,'browser_download_url':f'https://github.com/fixture/tasks/releases/download/v{version}/{archive}'},{'name':'SHA256SUMS','browser_download_url':f'https://github.com/fixture/tasks/releases/download/v{version}/SHA256SUMS'}]}
  (dist/'release.json').write_text('{invalid' if mode=='metadata' else json.dumps(metadata))
  curl=shim/'curl';curl.write_text('#!'+sys.executable+'\n'+'''import json,os,pathlib,shutil,sys,time
args=sys.argv[1:];url=next(x for x in args if x.startswith('https://'))
root=pathlib.Path(os.environ['UPDATE_FIXTURE']);mode=os.environ['UPDATE_MODE']
with (root/'requests.jsonl').open('a') as f:f.write(json.dumps({'url':url,'args':args,'pid':os.getpid()})+'\\n')
if mode=='download-fail':sys.exit(22)
if mode=='interrupt':time.sleep(30)
assert url.startswith('https://api.github.com/repos/fixture/tasks/') or url.startswith('https://github.com/fixture/tasks/releases/download/'),url
source=root/'dist'/('release.json' if url.endswith('/releases/latest') else url.rsplit('/',1)[-1])
if '-o' in args:shutil.copyfile(source,args[args.index('-o')+1])
elif '--output' in args:shutil.copyfile(source,args[args.index('--output')+1])
else:sys.stdout.write(source.read_text())
if mode=='changed' and url.endswith('.tar.gz'):
 target=root/'bin space'/'external-update';target.write_bytes(b'external-newer-install');os.replace(target,root/'bin space'/'doin')
if '-w' in args or '--write-out' in args:sys.stdout.write('200')
''');curl.chmod(0o755)
  env={**os.environ,'HOME':str(home),'USERPROFILE':str(home),'DOIN_CONFIG_DIR':str(config),'DOIN_REPO':'fixture/tasks','UPDATE_FIXTURE':str(root),'UPDATE_MODE':mode,'PATH':str(shim)+':'+os.environ['PATH'],'TERM':'dumb'}
  return root,exe,env
 def run(f,ok=True):
  root,exe,env=f;before=snapshot(root);started=time.monotonic();r=subprocess.run([str(exe),'update'],env=env,text=True,capture_output=True,timeout=40)
  record={'case':root.name,'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr,'elapsed':time.monotonic()-started,'before':before,'after':snapshot(root),'requests':(root/'requests.jsonl').read_text() if (root/'requests.jsonl').exists() else ''};commands.append(record)
  assert (r.returncode==0)==ok,record
  assert 'NotInitialized' not in r.stdout+r.stderr and 'private-fixture-secret' not in r.stdout+r.stderr
  return record
 def retained(record):
  for name,digest in record['before'].items():assert record['after'].get(name)==digest,(name,record)
  assert sorted(k for k in record['after'] if k.startswith('bin space/'))==['bin space/doin'],record
 def case(name,fn):
  try:fn();cases.append({'name':name,'passed':True})
  except Exception:cases.append({'name':name,'passed':False,'failure':traceback.format_exc()})
 def success():
  f=fixture('valid');r=run(f);assert r['before']['bin space/doin']!=r['after']['bin space/doin']
  for name,digest in r['before'].items():
   if name!='bin space/doin':assert r['after'].get(name)==digest,name
  assert subprocess.check_output([str(f[1]),'--version'],text=True).strip()=='doin 0.4.0'
  assert sorted(k for k in r['after'] if k.startswith('bin space/'))==['bin space/doin']
 case('pre-setup update verifies pinned archive and replaces executable while retaining corrupt settings and task folders',success)
 def large():
  f=fixture('large','large');r=run(f)
  assert f[1].stat().st_size>4*1024*1024
  assert subprocess.check_output([str(f[1]),'--version'],text=True,timeout=10).strip()=='doin 0.4.0'
  assert r['elapsed']<20,r
 case('multi-megabyte release payload drains within deadline and installs correctly',large)
 def descendant():
  f=fixture('descendant','descendant');root,exe,env=f;pid=None
  try:
   run(f);pid=int((root/'descendant.pid').read_text())
   try:os.kill(pid,0)
   except ProcessLookupError:pass
   else:
    status=subprocess.run(['ps','-o','stat=','-p',str(pid)],capture_output=True,text=True).stdout.strip()
    assert status.startswith('Z'),('owned descendant alive',pid,status)
  finally:
   if pid is not None:
    try:os.kill(pid,signal.SIGKILL)
    except ProcessLookupError:pass
 case('successful candidate validation leaves no running background descendants',descendant)
 def current():
  for version in ['0.3.0','0.2.0']:
   r=run(fixture('current-'+version,version=version));retained(r);assert '.tar.gz' not in ''.join(json.loads(line)['url'] for line in r['requests'].splitlines())
 case('current and newer installed versions do not download or downgrade',current)
 def failures():
  for mode in ['checksum','missing','duplicate','symlink','version','download-fail','metadata','candidate-hang','candidate-eof-hang']:
   r=run(fixture(mode,mode),ok=False);retained(r);assert r['requests'],r
 case('tampering, malformed release, bad archives, failed network and bad or hanging executable preserve installation',failures)
 def changed():
  f=fixture('changed','changed');r=run(f,ok=False)
  assert f[1].read_bytes()==b'external-newer-install'
  assert sorted(k for k in r['after'] if k.startswith('bin space/'))==['bin space/doin']
 case('concurrent replacement is retained and stale updater cannot overwrite it',changed)
 def interactive():
  f=fixture('interactive',version='0.3.0');root,exe,env=f
  storage=root/'home/Documents/doin'
  (root/'config/config.json').write_text(json.dumps({'storage':str(storage),'provider':'manual'}))
  before=snapshot(root);env['TERM']='xterm-256color';master,slave=pty.openpty()
  fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',28,84,0,0));original=termios.tcgetattr(slave)
  process=subprocess.Popen([str(exe)],env=env,stdin=slave,stdout=slave,stderr=slave,start_new_session=True);raw=bytearray()
  def wait(marker):
   deadline=time.monotonic()+12
   while marker not in raw:
    assert process.poll() is None and time.monotonic()<deadline,bytes(raw[-2000:])
    if select.select([master],[],[],.05)[0]:raw.extend(os.read(master,65536))
  try:
   wait(b'Tasks');time.sleep(.2);os.write(master,b'/update\r');wait(b'is up to date')
   time.sleep(.2);os.write(master,b'/quit\r');process.wait(timeout=8)
   assert termios.tcgetattr(slave)==original
   assert (root/'home/Documents/doin/tasks.md').read_text()=='# Migration café\n\n- [ ] Keep my notes\n'
   assert hashlib.sha256(exe.read_bytes()).hexdigest()==before['bin space/doin']
   assert snapshot(root)['config/config.json']==before['config/config.json']
   (artifacts/'interactive-update.ansi').write_bytes(raw)
   commands.append({'case':'interactive','exit':process.returncode,'transcript':str(artifacts/'interactive-update.ansi'),'requests':(root/'requests.jsonl').read_text()})
  finally:
   if process.poll() is None:os.killpg(process.pid,signal.SIGTERM);process.wait(timeout=5)
   os.close(master);os.close(slave)
 case('slash update checks release inside composer without saving a task or changing settings',interactive)
 def interrupted():
  f=fixture('interrupt','interrupt');root,exe,env=f;before=snapshot(root);process=subprocess.Popen([str(exe),'update'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
  try:
   deadline=time.monotonic()+8
   while not (root/'requests.jsonl').exists():
    assert time.monotonic()<deadline;time.sleep(.03)
   process.send_signal(signal.SIGINT);out,err=process.communicate(timeout=8)
   after=snapshot(root);record={'case':'interrupt','exit':process.returncode,'stdout':out,'stderr':err,'before':before,'after':after};commands.append(record);retained(record)
   request=json.loads((root/'requests.jsonl').read_text().splitlines()[0])
   try:os.kill(request['pid'],0)
   except ProcessLookupError:pass
   else:raise AssertionError('update curl survived interruption')
  finally:
   if process.poll() is None:os.killpg(process.pid,signal.SIGTERM);process.wait(timeout=5)
 case('Ctrl+C stops download child and retains executable, private settings and nested task folders',interrupted)
report={'binary':str(binary),'sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'cases':cases,'commands':commands}
(artifacts/'results.json').write_text(json.dumps(report,indent=2))
for c in cases:print(('PASS ' if c['passed'] else 'FAIL ')+c['name'])
print('Evidence:',artifacts)
raise SystemExit(0 if all(c['passed'] for c in cases) else 1)
