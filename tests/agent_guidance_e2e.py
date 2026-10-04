#!/usr/bin/env python3
"""Real CLI guidance lifecycle, existing-user-content and path/CAS boundaries."""
import json,os,pathlib,subprocess,sys,tempfile,time,select
binary=str(pathlib.Path(sys.argv[1] if len(sys.argv)>1 else 'zig-out/bin/doin').resolve());artifact=pathlib.Path('artifacts/agent-guidance-e2e');artifact.mkdir(parents=True,exist_ok=True)
receipt={'reproduce':'python3 tests/agent_guidance_e2e.py zig-out/bin/doin','commands':[],'checks':[],'passed':False};active=None
with tempfile.TemporaryDirectory(prefix='doin-agent-guidance-') as tmp:
 root=pathlib.Path(tmp);library=root/'My library';library.mkdir();env={**os.environ,'DOIN_CONFIG_DIR':str(root/'config'),'NO_COLOR':'1'}
 def run(*args,ok=True,input='y\n'):
  p=subprocess.run([binary,*args],input=input,text=True,capture_output=True,env=env,timeout=15);receipt['commands'].append({'args':args,'code':p.returncode,'stdout':p.stdout,'stderr':p.stderr});assert (p.returncode==0)==ok,(args,p.stdout,p.stderr);return p
 try:
  run('init','--storage',str(library),'--provider','manual');assert (library/'AGENTS.md').exists();document=(library/'tasks.md').read_bytes();run('agents','init');text=(library/'AGENTS.md').read_text();assert not (library/'CLAUDE.md').exists();run('agents','update','--claude');bridge=(library/'CLAUDE.md').read_text();assert '@AGENTS.md' in bridge and 'doin:properties=' in text and 'doin:values=' in text and 'server' in text and 'revision' in text;assert str(root) not in text and (library/'tasks.md').read_bytes()==document
  receipt['checks'].append('default new-library guidance and Claude bridge explain real portable metadata without changing tasks')
  (library/'AGENTS.md').write_text('User root rules.\n```md\n<!-- doin:guidance:begin -->\nFenced example stays.\n<!-- doin:guidance:end -->\n```\n'+text+'\nLasting user extension.\n');(library/'CLAUDE.md').write_text('Existing Claude rules.\n');before=(library/'AGENTS.md').read_bytes();run('agents','init');assert (library/'AGENTS.md').read_bytes()==before and (library/'CLAUDE.md').read_text()=='Existing Claude rules.\n'
  run('agents','update','--claude',input='n\n');assert (library/'AGENTS.md').read_bytes()==before;run('agents','update','--claude');assert 'User root rules.' in (library/'AGENTS.md').read_text() and 'Fenced example stays.' in (library/'AGENTS.md').read_text() and 'Lasting user extension.' in (library/'AGENTS.md').read_text() and 'Existing Claude rules.' in (library/'CLAUDE.md').read_text() and '@AGENTS.md' in (library/'CLAUDE.md').read_text()
  receipt['checks'].append('init preserves existing files; reviewed managed updates preserve user rules and support cancellation')
  run('folder','list');root_id=json.loads((library/'.doin-folder.json').read_text())['id'];run('folder','create',root_id,'Launch café');child=library/'Launch café';assert (child/'AGENTS.md').exists() and not (child/'CLAUDE.md').exists();child_id=json.loads((child/'.doin-folder.json').read_text())['id'];run('folder','select',child_id);run('agents','update','--claude');assert '@AGENTS.md' in (child/'CLAUDE.md').read_text();assert 'tasks.md' in (child/'AGENTS.md').read_text();assert str(root) not in (child/'AGENTS.md').read_text();receipt['checks'].append('enabled created folder gets self-contained portable guidance')
  config=root/'config'/'config.json';legacy=json.loads(config.read_text());legacy.pop('guidance_enabled',None);config.write_text(json.dumps(legacy));run('folder','create',root_id,'Legacy config');legacy_folder=library/'Legacy config';assert not (legacy_folder/'AGENTS.md').exists();legacy_id=json.loads((legacy_folder/'.doin-folder.json').read_text())['id'];run('folder','select',legacy_id);run('agents','status');run('agents','init');assert (legacy_folder/'AGENTS.md').exists();run('folder','select',child_id);receipt['checks'].append('existing config missing guidance flag stays opt-in until agents init')

  # A preview cannot overwrite an external editor, even when it changes only user prose.
  active=subprocess.Popen([binary,'agents','update','--claude'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env);prefix=b'';deadline=time.monotonic()+5
  while b'[y/N]' not in prefix and b'[y/n]' not in prefix:
   assert time.monotonic()<deadline,'confirmation never arrived';ready,_,_=select.select([active.stdout],[],[],.1)
   if ready:chunk=os.read(active.stdout.fileno(),4096);assert chunk;prefix+=chunk
  external=(library/'AGENTS.md').read_text()+'External editor rule.\n';(library/'AGENTS.md').write_text(external);stdout,stderr=active.communicate('y\n',timeout=15);receipt['commands'].append({'args':['agents','update','--claude'],'code':active.returncode,'stdout':prefix.decode()+stdout,'stderr':stderr,'external_edit':True});assert active.returncode!=0 and (library/'AGENTS.md').read_text()==external
  receipt['checks'].append('fresh-byte CAS rejects external edits during guidance preview')
  outside=root/'outside.md';outside.write_text('Do not touch.\n');saved=(library/'AGENTS.md').read_bytes();(library/'AGENTS.md').unlink();(library/'AGENTS.md').symlink_to(outside);run('agents','update',ok=False);assert outside.read_text()=='Do not touch.\n';(library/'AGENTS.md').unlink();(library/'AGENTS.md').write_bytes(saved)
  malformed=saved.decode().replace('<!-- doin:guidance:end -->','');(library/'AGENTS.md').write_text(malformed);run('agents','update',ok=False);assert (library/'AGENTS.md').read_text()==malformed;(library/'AGENTS.md').write_bytes(saved);receipt['checks'].append('symlink files and malformed managed markers refuse without damaging user content')
  receipt['passed']=True
 finally:
  if active and active.poll() is None:active.terminate();active.wait(timeout=2)
  if sys.exc_info()[1] is not None:receipt['failure']=str(sys.exc_info()[1])
  for name in ['AGENTS.md','CLAUDE.md']:
   path=library/name
   if path.exists() and not path.is_symlink():(artifact/name).write_bytes(path.read_bytes())
  data=json.dumps(receipt,indent=2)+'\n';(artifact/'report.json').write_text(data);(artifact/f'report-{time.time_ns()}.json').write_text(data)
print(f"Passed {len(receipt['checks'])} guidance CLI groups.")
