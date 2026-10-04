"""Compiled CLI MCP stdio E2E; no model/account/network. Artifacts are replayable."""
import json, os, pathlib, subprocess, tempfile, select, hashlib, time, atexit, fcntl
ROOT=pathlib.Path(__file__).resolve().parents[1]
BIN=pathlib.Path(os.environ.get('DOIN_BINARY',ROOT/'zig-out/bin/doin'))
ART=ROOT/'artifacts/mcp-e2e';ART.mkdir(parents=True,exist_ok=True)
log=[]
passed=False
processes=[]
def finalize():
 for proc in processes:
  if proc.poll() is None:
   proc.terminate()
   try: proc.wait(timeout=3)
   except subprocess.TimeoutExpired: proc.kill();proc.wait(timeout=3)
 (ART/'transcript.json').write_text(json.dumps(log,ensure_ascii=False,indent=2))
 (ART/'result.json').write_text(json.dumps({'passed':passed,'command':'python3 tests/mcp_e2e.py','binary':str(BIN),'binary_sha256':hashlib.sha256(BIN.read_bytes()).hexdigest() if BIN.exists() else None,'groups':['protocol/errors/bounds','readonly','Unicode/fences','typed writes/revision/undo','external edit conflict','folder isolation/EOF']},indent=2))
atexit.register(finalize)
class Client:
 def __init__(self,env,write=False):
  self.p=subprocess.Popen([str(BIN),'mcp','serve']+(['--allow-write'] if write else []),env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  processes.append(self.p)
 def send(self,v):
  raw=v if isinstance(v,bytes) else json.dumps(v,ensure_ascii=False).encode()
  self.p.stdin.write(raw+b'\n');self.p.stdin.flush();log.append({'send':raw.decode(errors='replace')[:70000]})
 def receive(self):
  assert select.select([self.p.stdout],[],[],5)[0], 'MCP reply timed out'
  line=self.p.stdout.readline();assert line, 'MCP closed unexpectedly'
  reply=json.loads(line);log.append({'receive':reply});return reply
 def call(self,name,args):
  self.send({'jsonrpc':'2.0','id':7,'method':'tools/call','params':{'name':name,'arguments':args}});return self.receive()
 def init(self,version='2025-11-25'):
  self.send({'jsonrpc':'2.0','id':'init','method':'initialize','params':{'protocolVersion':version,'capabilities':{},'clientInfo':{'name':'e2e','version':'1'}}})
  r=self.receive();assert r['result']['protocolVersion']=='2025-11-25';assert r['id']=='init';assert 'AGENTS.md' in r['result']['instructions'];assert 'Server authorization is authoritative' in r['result']['instructions'];assert 'selected folder' in r['result']['instructions']
  self.send({'jsonrpc':'2.0','method':'notifications/initialized'})
 def close(self):
  self.p.stdin.close();assert self.p.wait(timeout=5)==0
  assert self.p.stdout.read()==b'', 'unexpected protocol output after EOF'
  stderr=self.p.stderr.read().decode();log.append({'stderr':stderr,'exit':self.p.returncode});assert not stderr
with tempfile.TemporaryDirectory(prefix='doin-mcp-e2e-') as tmp:
 folder=pathlib.Path(tmp);store=folder/'store';cfg=folder/'config';store.mkdir();cfg.mkdir()
 env={**os.environ,'DOIN_CONFIG_DIR':str(cfg),'HOME':str(folder),'NO_COLOR':'1'}
 doc=store/'tasks.md';original='# Work\n\n- [ ] Café 日本語\n```md\n- [ ] fake fenced task\n```\n- [x] Already done\n';doc.write_text(original)
 missing=subprocess.run([str(BIN),'mcp','serve'],env={**env,'DOIN_CONFIG_DIR':str(folder/'missing')},input=b'',capture_output=True,timeout=5);assert missing.returncode!=0;assert missing.stdout==b'';assert not (folder/'missing').exists();log.append({'missing_config_exit':missing.returncode,'stderr':missing.stderr.decode()})
 (cfg/'config.json').write_text(json.dumps({'storage':str(store),'provider':'manual'}))
 c=Client(env)
 c.send(b'{broken');assert c.receive()['error']['code']==-32700
 c.send(b'\xff');assert c.receive()['error']['code']==-32700
 c.send({'jsonrpc':'2.0','id':1,'method':'tools/list'});assert 'error' in c.receive()
 c.init('future-version')
 c.send({'jsonrpc':'2.0','id':2,'method':'ping'});assert c.receive()['result']=={}
 c.send({'jsonrpc':'2.0','id':3,'method':'tools/list','params':{'_meta':{'progressToken':'list-e2e'}}});tools=c.receive()['result']['tools'];assert {t['name'] for t in tools}=={'doin_read','doin_list'}
 c.send({'jsonrpc':'2.0','id':4,'method':'unknown'});assert c.receive()['error']['code']==-32601
 c.send(b' '*(65537));assert c.receive()['error']['code']==-32600
 c.send({'jsonrpc':'2.0','id':5,'method':'tools/call','params':{'name':'doin_read','_meta':{'progressToken':'read-e2e'}}});assert c.receive()['result']['structuredContent']['markdown']==original
 r=c.call('doin_read',{})['result']['structuredContent'];assert r['markdown']==original;assert len(r['tasks'])==2;rev=r['revision'];assert rev==hashlib.sha256(original.encode()).hexdigest()
 assert c.call('doin_add',{'text':'denied','revision':rev})['result']['isError'];assert doc.read_text()==original
 assert len(c.call('doin_list',{'completed':False})['result']['structuredContent']['tasks'])==1
 c.close()
 c=Client(env,True);c.init()
 assert c.call('doin_add',{'text':'hidden\u2028line','revision':rev})['result']['isError'];assert doc.read_text()==original
 assert c.call('doin_add',{'text':'bad\n- [ ] injection','revision':rev})['result']['isError'];assert doc.read_text()==original
 assert c.call('doin_add',{'text':'good','revision':rev,'path':'/tmp/outside'})['result']['isError']
 with (store/'.tasks.lock').open('a') as held:
  fcntl.flock(held,fcntl.LOCK_EX|fcntl.LOCK_NB)
  assert c.call('doin_add',{'text':'Blocked lock','revision':rev})['result']['isError'];assert doc.read_text()==original
  fcntl.flock(held,fcntl.LOCK_UN)
 result=c.call('doin_add',{'text':'Ship 🚀','revision':rev})['result'];assert not result.get('isError',False);rev=result['structuredContent']['revision'];assert '- [ ] Ship 🚀' in doc.read_text();assert (store/'.tasks.undo').read_text()==original
 assert c.call('doin_complete',{'number':1,'completed':True,'revision':r['revision']})['result']['isError'];assert '[ ] Café' in doc.read_text()
 # External editor races a stale task reference; neither file nor undo can change.
 doc.write_text('- [ ] External first\n'+doc.read_text());external=doc.read_text();undo=(store/'.tasks.undo').read_bytes()
 assert c.call('doin_complete',{'number':1,'completed':True,'revision':rev})['result']['isError'];assert doc.read_text()==external;assert (store/'.tasks.undo').read_bytes()==undo
 rev=c.call('doin_read',{})['result']['structuredContent']['revision']
 changed=c.call('doin_complete',{'number':2,'completed':True,'revision':rev})['result']['structuredContent'];assert '[x] Café' in doc.read_text();assert '- [ ] fake fenced task' in doc.read_text()
 rev=changed['revision'];assert c.call('doin_status',{'number':1,'status':'nonsense','revision':rev})['result']['isError']
 result=c.call('doin_status',{'number':1,'status':'done','revision':rev})['result']['structuredContent'];assert result['tasks'][0]['completed']
 result=c.call('doin_reminder',{'number':4,'time':'in 15m','revision':result['revision']})['result'];assert not result.get('isError',False);assert 'remind=' in doc.read_text()
 c.close()
 restored=subprocess.run([str(BIN),'undo'],env=env,capture_output=True);assert restored.returncode==0;assert 'remind=' not in doc.read_text()
 # Another configured folder must never observe first folder contents.
 other=folder/'other';other.mkdir();(other/'tasks.md').write_text('- [ ] isolated\n');(cfg/'config.json').write_text(json.dumps({'storage':str(other),'provider':'manual'}))
 c=Client(env);c.init();assert c.call('doin_read',{})['result']['structuredContent']['markdown']=='- [ ] isolated\n';c.close()
 (other/'tasks.md').write_text('- [ ] isolated\n```md\n')
 c=Client(env,True);c.init();fence_revision=c.call('doin_read',{})['result']['structuredContent']['revision'];assert c.call('doin_add',{'text':'Cannot hide in fence','revision':fence_revision})['result']['isError'];assert (other/'tasks.md').read_text()=='- [ ] isolated\n```md\n';c.close()
 (other/'tasks.md').write_text('- [ ] isolated\n')
 c=Client(env,True);c.init();c.p.stdin.write(b'{"jsonrpc":"2.0","id":99,"method":"tools/call"');c.p.stdin.flush();c.close();assert (other/'tasks.md').read_text()=='- [ ] isolated\n'
 (ART/'tasks.md').write_text(doc.read_text());(ART/'undo.md').write_bytes((store/'.tasks.undo').read_bytes())
passed=True
print('PASS native MCP stdio lifecycle, guarded tasks, conflicts, undo, isolation and EOF cleanup')
