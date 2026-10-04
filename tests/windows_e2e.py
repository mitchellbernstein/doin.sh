#!/usr/bin/env python3
"""Windows E2E census: Unicode/spaced paths, locks/undo, private ACL inheritance,
stdio MCP framing/cleanup, native console keyboard/resize/restore, browser argv,
unsupported notification boundary, installer integrity/preservation. Actual Win32
ConPTY hosts the production executable; no renderer or console mocks.
"""
import argparse,shutil,ctypes as C,hashlib,json,os,pathlib,subprocess,sys,tempfile,threading,time,traceback
from ctypes import wintypes as W
if os.name!='nt':raise SystemExit('Run this evidence harness on Windows.')
p=argparse.ArgumentParser();p.add_argument('--bin',default='zig-out/bin/doin.exe');a=p.parse_args();binary=str(pathlib.Path(a.bin).resolve())
artifacts=pathlib.Path('artifacts/windows-e2e');artifacts.mkdir(parents=True,exist_ok=True);receipts=[];cases=[]
k=C.WinDLL('kernel32',use_last_error=True)
class COORD(C.Structure):_fields_=[('X',C.c_short),('Y',C.c_short)]
class STARTUPINFO(C.Structure):
 _fields_=[('cb',W.DWORD),('reserved',W.LPWSTR),('desktop',W.LPWSTR),('title',W.LPWSTR),('x',W.DWORD),('y',W.DWORD),('xs',W.DWORD),('ys',W.DWORD),('xc',W.DWORD),('yc',W.DWORD),('fill',W.DWORD),('flags',W.DWORD),('show',W.WORD),('reserved2',W.WORD),('reservedp',C.POINTER(C.c_byte)),('stdin',W.HANDLE),('stdout',W.HANDLE),('stderr',W.HANDLE)]
class STARTUPINFOEX(C.Structure):_fields_=[('info',STARTUPINFO),('attributes',C.c_void_p)]
class PROCESSINFO(C.Structure):_fields_=[('process',W.HANDLE),('thread',W.HANDLE),('pid',W.DWORD),('tid',W.DWORD)]
k.CreatePipe.argtypes=[C.POINTER(W.HANDLE),C.POINTER(W.HANDLE),C.c_void_p,W.DWORD];k.CloseHandle.argtypes=[W.HANDLE]
k.CreatePseudoConsole.argtypes=[COORD,W.HANDLE,W.HANDLE,W.DWORD,C.POINTER(W.HANDLE)];k.CreatePseudoConsole.restype=C.c_long
k.ResizePseudoConsole.argtypes=[W.HANDLE,COORD];k.ClosePseudoConsole.argtypes=[W.HANDLE]
k.InitializeProcThreadAttributeList.argtypes=[C.c_void_p,W.DWORD,W.DWORD,C.POINTER(C.c_size_t)]
k.UpdateProcThreadAttribute.argtypes=[C.c_void_p,W.DWORD,C.c_size_t,C.c_void_p,C.c_size_t,C.c_void_p,C.c_void_p]
k.CreateProcessW.argtypes=[W.LPCWSTR,W.LPWSTR,C.c_void_p,C.c_void_p,W.BOOL,W.DWORD,C.c_void_p,W.LPCWSTR,C.POINTER(STARTUPINFOEX),C.POINTER(PROCESSINFO)]
k.OpenProcess.argtypes=[W.DWORD,W.BOOL,W.DWORD];k.OpenProcess.restype=W.HANDLE;k.GetExitCodeProcess.argtypes=[W.HANDLE,C.POINTER(W.DWORD)]
k.ReadFile.argtypes=[W.HANDLE,C.c_void_p,W.DWORD,C.POINTER(W.DWORD),C.c_void_p];k.WriteFile.argtypes=k.ReadFile.argtypes
k.WaitForSingleObject.argtypes=[W.HANDLE,W.DWORD];k.TerminateProcess.argtypes=[W.HANDLE,W.UINT];k.DeleteProcThreadAttributeList.argtypes=[C.c_void_p]
def checked(value):
 if not value:raise C.WinError(C.get_last_error())
 return value
class Console:
 def __init__(self,env,cols=80,rows=30,command=None):
  self.raw=bytearray();self.process=PROCESSINFO();self.input=W.HANDLE();self.output=W.HANDLE();rd=W.HANDLE();wr=W.HANDLE();self.console=W.HANDLE()
  checked(k.CreatePipe(C.byref(rd),C.byref(self.input),None,0));checked(k.CreatePipe(C.byref(self.output),C.byref(wr),None,0))
  assert k.CreatePseudoConsole(COORD(cols,rows),rd,wr,0,C.byref(self.console))==0
  self.reader=threading.Thread(target=self.drain,daemon=True);self.reader.start()
  size=C.c_size_t();k.InitializeProcThreadAttributeList(None,1,0,C.byref(size));self.attrs=C.create_string_buffer(size.value);checked(k.InitializeProcThreadAttributeList(self.attrs,1,0,C.byref(size)))
  checked(k.UpdateProcThreadAttribute(self.attrs,0,0x20016,self.console,C.sizeof(W.HANDLE),None,None));startup=STARTUPINFOEX();startup.info.cb=C.sizeof(startup);startup.info.flags=0x00000100;startup.attributes=C.cast(self.attrs,C.c_void_p)
  self.env=env
  self.start(command or [binary])
  k.CloseHandle(rd);k.CloseHandle(wr)
 def start(self,command):
  if self.process.process:k.CloseHandle(self.process.process)
  self.process=PROCESSINFO();startup=STARTUPINFOEX();startup.info.cb=C.sizeof(startup);startup.info.flags=0x100;startup.attributes=C.cast(self.attrs,C.c_void_p)
  block=C.create_unicode_buffer('\0'.join(f'{key}={value}'for key,value in sorted(self.env.items(),key=lambda pair:pair[0].upper()))+'\0\0');cmd=C.create_unicode_buffer(subprocess.list2cmdline(command))
  checked(k.CreateProcessW(None,cmd,None,None,False,0x00080000|0x00000400,block,None,C.byref(startup),C.byref(self.process)))
  k.CloseHandle(self.process.thread)
 def drain(self):
  buffer=C.create_string_buffer(8192);count=W.DWORD()
  while k.ReadFile(self.output,buffer,len(buffer),C.byref(count),None):
   if not count.value:break
   self.raw.extend(buffer.raw[:count.value])
 def send(self,text):
  encoded=text.encode('utf-8')if isinstance(text,str)else text;count=W.DWORD();checked(k.WriteFile(self.input,encoded,len(encoded),C.byref(count),None));assert count.value==len(encoded)
 def until(self,needle,seconds=8):
  deadline=time.monotonic()+seconds
  while needle not in self.raw:
   if time.monotonic()>deadline:
    code=W.DWORD();checked(k.GetExitCodeProcess(self.process.process,C.byref(code)))
    raise AssertionError(('missing console output',needle,'process exit',code.value,self.raw[-1500:]))
   time.sleep(.02)
 def resize(self,cols,rows):assert k.ResizePseudoConsole(self.console,COORD(cols,rows))==0
 def close(self):
  if k.WaitForSingleObject(self.process.process,1500)!=0:k.TerminateProcess(self.process.process,1);k.WaitForSingleObject(self.process.process,2000)
  k.CloseHandle(self.input);k.ClosePseudoConsole(self.console);self.reader.join(timeout=3);k.CloseHandle(self.output);k.CloseHandle(self.process.process);k.DeleteProcThreadAttributeList(self.attrs);assert not self.reader.is_alive()
with tempfile.TemporaryDirectory(prefix='doin-windows-')as folder:
 root=pathlib.Path(folder);config=root/'profile';storage=root/'Tasks with spaces café';env=dict(os.environ,DOIN_CONFIG_DIR=str(config),DOIN_NO_ANIMATION='1');env.pop('NO_COLOR',None);env['TERM']='xterm-256color'
 def run(*args,ok=True,stdin=None):
  r=subprocess.run([binary,*args],env=env,input=stdin,capture_output=True,text=True,encoding='utf-8',timeout=15);receipts.append({'args':args,'code':r.returncode,'stdout':r.stdout,'stderr':r.stderr});assert (r.returncode==0)==ok,receipts[-1];return r
 def case(name,fn):
  try:fn();cases.append({'name':name,'passed':True})
  except Exception:cases.append({'name':name,'passed':False,'error':traceback.format_exc()})
  finally:
   log=root/'owned-pids.json'
   if log.exists():
    for role,pid in json.loads(log.read_text(encoding="utf-8")).items():
     if role not in ('parent','child'):continue
     handle=k.OpenProcess(0x1000|1,False,pid)
     if handle:
      try:
       code=W.DWORD();checked(k.GetExitCodeProcess(handle,C.byref(code)))
       if code.value==259:k.TerminateProcess(handle,1);k.WaitForSingleObject(handle,2000)
      finally:k.CloseHandle(handle)
 def core():
  run('init','--storage',str(storage),'--provider','manual');run('add','café 東京 "quoted"');run('done','1');assert '[x]'in run('list').stdout;run('undo');assert '[ ]'in run('list').stdout;assert '\x1b'not in run('list').stdout
 case('actual native core Unicode/spaced storage, completion, undo and redirected plain output',core)
 def guidance():
  # Census: first-run missing-only creation; cancellation and managed updates
  # preserve user prose, literal Unicode and task bytes; no profile paths leak.
  agents=storage/'AGENTS.md';assert agents.exists();tasks=(storage/'tasks.md').read_bytes()
  original=agents.read_text(encoding='utf-8');assert str(root) not in original
  user='User rules café 東京.\n'+original+'\nKeep my extension.\n';agents.write_text(user,encoding='utf-8');before=agents.read_bytes()
  run('agents','init');assert agents.read_bytes()==before
  run('agents','update',stdin='n\n');assert agents.read_bytes()==before
  run('agents','update',stdin='y\n');updated=agents.read_text(encoding='utf-8');assert 'User rules café 東京.' in updated and 'Keep my extension.' in updated and str(root) not in updated
  assert (storage/'tasks.md').read_bytes()==tasks
 case('Windows guidance missing-only initialization and reviewed update/cancel preserve user content',guidance)

 def mcp():
  before=(storage/'tasks.md').read_bytes();run('mcp','add','self','--',binary,'mcp','serve');assert 'doin_read'in run('mcp','tools','self').stdout;assert 'café'in run('mcp','call','self','doin_read','{}').stdout;assert before==(storage/'tasks.md').read_bytes()
  acl=subprocess.run(['pwsh','-NoProfile','-Command',f"$a=Get-Acl -LiteralPath '{config/'mcp-servers.json'}' -ErrorAction Stop; $a | Select-Object AreAccessRulesProtected,Owner,@{{Name='RuleCount';Expression={{@($_.Access).Count}}}} | ConvertTo-Json -Compress; if(-not $a.AreAccessRulesProtected -or @($a.Access).Count -ne 1){{exit 1}}"],capture_output=True,text=True, encoding="utf-8");receipts.append({'acl_code':acl.returncode,'acl_stdout':acl.stdout,'acl_stderr':acl.stderr});assert acl.returncode==0,(acl.stdout,acl.stderr)
  run('mcp','remove','self')
 case('actual native client-server interoperability, protected Windows ACL and no implicit task writes',mcp)
 def process_cleanup():
  script=root/'hanging server.py';log=root/'owned-pids.json'
  script.write_text("import json,os,pathlib,subprocess,sys,time\nchild=subprocess.Popen([sys.executable,'-c','import time;time.sleep(90)'])\nfor line in sys.stdin:\n pathlib.Path(sys.argv[1]).write_text(json.dumps({'parent':os.getpid(),'child':child.pid,'request':json.loads(line)}))\n time.sleep(90)\n", encoding="utf-8")
  run('mcp','add','hung','--',sys.executable,str(script),str(log));env['DOIN_MCP_TIMEOUT_MS']='700'
  try:run('mcp','tools','hung',ok=False)
  finally:env.pop('DOIN_MCP_TIMEOUT_MS',None)
  assert log.exists();owned=json.loads(log.read_text(encoding="utf-8"));assert owned['request']['method']=='initialize'
  k.OpenProcess.argtypes=[W.DWORD,W.BOOL,W.DWORD];k.OpenProcess.restype=W.HANDLE;k.GetExitCodeProcess.argtypes=[W.HANDLE,C.POINTER(W.DWORD)]
  for role in ('parent','child'):
   handle=k.OpenProcess(0x1000,False,owned[role])
   if handle:
    try:code=W.DWORD();checked(k.GetExitCodeProcess(handle,C.byref(code)));assert code.value!=259,('owned child remains active',role)
    finally:k.CloseHandle(handle)
  receipts.append({'job_cleanup':owned})
 case('actual Windows MCP deadline terminates its private job including descendant',process_cleanup)
 def console():
  # Failure census: prove real host bootstrap independently before app startup.
  probe=Console(env,command=[os.environ['COMSPEC'],'/d','/c','echo DOIN_CONPTY_BOOTSTRAP'])
  try:probe.until(b'DOIN_CONPTY_BOOTSTRAP')
  finally:probe.close();(artifacts/'console-bootstrap.ansi').write_bytes(probe.raw)
  driver=str(pathlib.Path('artifacts/windows-e2e/platform-driver.exe').resolve());baseline=root/'console-before.json';after=root/'console-after.json'
  t=Console(env,command=[driver,'console-state',str(baseline)])
  try:
   assert k.WaitForSingleObject(t.process.process,3000)==0;before=json.loads(baseline.read_text(encoding='utf-8'));t.start([binary])
   t.until(b'Enter submit');t.send('add Windows draft caf\xc3\xa9'.encode('latin1'));t.send(b'\x1b[D\x7f');t.send('f');t.send('\r');t.until(b'Windows draft');t.resize(62,22);time.sleep(.2);t.send('/help\r');t.until(b'mcp serve');t.send(b'\x03');assert k.WaitForSingleObject(t.process.process,3000)==0
   # ConPTY renders console state; it need not forward the app's DECSTBM bytes.
   t.start([driver,'console-state',str(after)]);assert k.WaitForSingleObject(t.process.process,3000)==0
   restored=json.loads(after.read_text(encoding='utf-8'));receipts.append({'console_before':before,'console_after':restored})
   assert all(restored[key]==before[key] for key in ('input','output','codepage')),restored
   assert restored['visible'] and restored['scroll_row']==restored['bottom'],restored
   # Passthrough input-mode state must also end disabled in the rendered stream.
   time.sleep(.15);assert t.raw.rfind(b'\x1b[?2004l')>t.raw.rfind(b'\x1b[?2004h')
  finally:t.close();(artifacts/'console.ansi').write_bytes(t.raw)
 case('real Windows ConPTY keyboard Unicode edit, resize, help, Ctrl+C and terminal cleanup',console)
 def browser():
  driver=pathlib.Path('artifacts/windows-e2e/platform-driver.exe').resolve();helper=root/'Browser helper & spaces.exe';shutil.copyfile(driver,helper);log=root/'browser.json'
  local=dict(env,DOIN_BROWSER_COMMAND=str(helper),DOIN_TEST_CAPTURE=str(log));url='https://checkout.stripe.com/c/test_fixture#keep=this&literal=$(noop)'
  # The caller cannot also be capture mode; wrapper receives fixture capture env.
  # Parent driver reads capture variable only when called with the URL directly.
  r=subprocess.run([str(driver),'open',url],env=local,capture_output=True,text=True,timeout=10, encoding="utf-8");assert r.returncode==0,(r.stdout,r.stderr)
  assert json.loads(log.read_text(encoding="utf-8"))['arguments']==[url]
 case('native browser adapter passes exact trusted URL fragment as one argv without a shell',browser)
 def notification():
  # No reminder is due. Actual isolated Task Scheduler registration is cleaned
  # in finally even if query/status assertions fail; no toast is requested.
  proxy=root/'scheduler proxy';proxy.mkdir();shutil.copyfile(pathlib.Path('artifacts/windows-e2e/platform-driver.exe').resolve(),proxy/'schtasks.exe')
  saved_path=env['PATH'];env['PATH']=str(proxy)+os.pathsep+saved_path
  env['DOIN_TEST_REAL_SCHTASKS']=str(pathlib.Path(os.environ['SystemRoot'])/'System32'/'schtasks.exe');env['DOIN_TEST_SCHEDULER_XML']=str((artifacts/'scheduler.xml').resolve())
  try:
   run('remind','enable');assert 'Reminders on' in run('remind','status').stdout
   files=list(config.glob('com.studioyeehaw.doin.reminders.*.xml'));assert files
   assert files[0].read_bytes().startswith(b'\xff\xfe');xml=files[0].read_text(encoding='utf-16');assert 'InteractiveToken' in xml and 'LeastPrivilege' in xml and 'TimeTrigger' in xml and 'PT1M' in xml and 'background-check' in xml and 'Password' not in xml and 'HighestAvailable' not in xml
   acl=subprocess.run(['pwsh','-NoProfile','-Command',f"$a=Get-Acl -LiteralPath '{files[0]}'; $sid=[System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value; if(-not $a.AreAccessRulesProtected -or @($a.Access).Count -ne 1 -or -not (Get-Content -Raw -LiteralPath '{files[0]}').Contains($sid)){{exit 1}}"],capture_output=True,text=True, encoding="utf-8");receipts.append({'acl_code':acl.returncode,'acl_stdout':acl.stdout,'acl_stderr':acl.stderr});assert acl.returncode==0,(acl.stdout,acl.stderr)
  finally:
   try:run('remind','disable')
   finally:env['PATH']=saved_path;env.pop('DOIN_TEST_REAL_SCHTASKS',None);env.pop('DOIN_TEST_SCHEDULER_XML',None)
 def notifier():
  driver=pathlib.Path('artifacts/windows-e2e/platform-driver.exe').resolve();log=root/'notifier.json';env['DOIN_REMINDER_NOTIFIER']=str(driver);env['DOIN_TEST_CAPTURE']=str(log);env['DOIN_REMINDER_NOW']='2000000000'
  try:
   literal='literal ";$(Write-Output DOIN_LITERAL);& café 東京';run('add',literal);number=sum(1 for line in (storage/'tasks.md').read_text(encoding='utf-8').splitlines() if line.startswith('- ['));run('remind','enable','--manual');run('remind',str(number),'in 15m');env['DOIN_REMINDER_NOW']='2000000900';run('remind','check')
   capture=json.loads(log.read_text(encoding="utf-8"));assert json.loads(capture['payload'])['text']==literal and 'ShowBalloonTip' in capture['script'];assert not pathlib.Path(capture['arguments'][0]).exists()
  finally:
   run('remind','disable');env.pop('DOIN_REMINDER_NOTIFIER',None);env.pop('DOIN_TEST_CAPTURE',None);env.pop('DOIN_REMINDER_NOW',None)
 case('real isolated Windows scheduler registration/status/deletion without due notifications',notification)
 case('Windows notification text travels through private JSON to bounded adapter, fixture sends no toast',notifier)
(artifacts/'results.json').write_text(json.dumps({'platform':sys.platform,'version':subprocess.check_output([binary,'--version'],text=True, encoding="utf-8").strip(),'binary_sha256':hashlib.sha256(pathlib.Path(binary).read_bytes()).hexdigest(),'cases':cases,'commands':receipts},indent=2,ensure_ascii=False), encoding="utf-8")
for item in cases:print(('PASS 'if item['passed']else'FAIL ')+item['name'])
sys.exit(0 if all(item['passed']for item in cases)else 1)
