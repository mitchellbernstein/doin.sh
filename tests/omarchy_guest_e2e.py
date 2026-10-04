import os,subprocess,json,pathlib,pty,select,time,fcntl,termios,struct,hashlib
root=pathlib.Path('/home/doin-test/doin-e2e-final');root.mkdir(exist_ok=True)
env=os.environ.copy();env.update(DOIN_CONFIG_DIR=str(root/'config'),TERM='xterm-256color',DOIN_NO_ANIMATION='1')
binary='/mnt/mac/doin';records=[]
def run(*args,input=None):
 p=subprocess.run([binary,*args],input=input,text=True,env=env,capture_output=True,timeout=15)
 records.append({'args':args,'returncode':p.returncode,'stdout':p.stdout,'stderr':p.stderr});assert p.returncode==0,p.stderr;return p.stdout
# Failure census: native ABI/load, Unicode and spaces, private config, undo,
# real stdio child interop, raw terminal editing/resize/cancellation/restoration.
run('init','--storage',str(root/'Tasks with spaces'),'--provider','manual')
run('add','Omarchy café 東京');run('add','MCP native interop');run('done','1');run('undo')
assert 'café 東京' in run('list')
run('mcp','add','self','--',binary,'mcp','serve');assert 'doin_read' in run('mcp','tools','self')
assert 'café 東京' in run('mcp','call','self','doin_read','{}')
run('properties','add','Estimate','number');run('set','1','Estimate','3.5')
assert 'Omarchy café' in run('filter','property','Estimate','3.5')
run('properties','add','Stage','single_select','Build,Ship');run('set','1','Stage','Ship')
run('folder','list');rootid=json.loads((root/'Tasks with spaces'/'.doin-folder.json').read_text())['id']
run('folder','create',rootid,'Launch café');child=root/'Tasks with spaces'/'Launch café';childid=json.loads((child/'.doin-folder.json').read_text())['id']
run('folder','select',childid);run('add','Nested project 東京');assert 'Nested project 東京' in (child/'tasks.md').read_text()
run('folder','rename',childid,'Release café');assert json.loads((root/'config'/'config.json').read_text())['storage']==str(root/'Tasks with spaces'/'Release café')
run('folder','select',rootid)
master,slave=pty.openpty();fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',30,90,0,0));before=termios.tcgetattr(slave)
p=subprocess.Popen([binary],stdin=slave,stdout=slave,stderr=slave,env=env);raw=bytearray()
def wait(needle,seconds=8,offset=0):
 end=time.monotonic()+seconds
 while time.monotonic()<end:
  if select.select([master],[],[],.1)[0]:
   try:raw.extend(os.read(master,65536))
   except OSError:break
  if needle in raw[offset:]:return
 raise AssertionError(needle)
try:
 wait(b'Enter submit');os.write(master,'add terminal cafX'.encode());os.write(master,b'\x7f');os.write(master,'é'.encode());wait(b'terminal caf')
 offset=len(raw);fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',22,62,0,0));wait(b'terminal caf',offset=offset)
 offset=len(raw);fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',36,110,0,0));wait(b'terminal caf',offset=offset)
 os.write(master,b'\r');time.sleep(.2);os.write(master,b'/help\r');time.sleep(.3);os.write(master,b'\x03');p.wait(timeout=8)
 while select.select([master],[],[],.1)[0]:raw.extend(os.read(master,65536))
 assert p.returncode==0 and termios.tcgetattr(slave)==before
 assert b'\x1b[r' in raw and b'\x1b[?2004l' in raw
 assert 'terminal café' in run('list')
finally:
 if p.poll() is None:p.terminate();p.wait(timeout=5)
 os.close(master);os.close(slave)
(root/'terminal.ansi').write_bytes(raw)
(root/'results.json').write_text(json.dumps({'version':run('--version').strip(),'sha256':hashlib.sha256(pathlib.Path(binary).read_bytes()).hexdigest(),'kernel':run('list') and os.uname().release,'commands':records,'terminal_restored':True,'active_draft_shrink_grow':True},indent=2))
print('Omarchy native CLI, MCP interop, PTY edit/resize/cancel PASS')
