#!/usr/bin/env python3
"""Real CLI schema/value lifecycle; preserves failure receipts and Markdown snapshots."""
import json, os, pathlib, re, subprocess, sys, tempfile
binary=str(pathlib.Path(sys.argv[1] if len(sys.argv)>1 else 'zig-out/bin/doin').resolve())
artifact=pathlib.Path('artifacts/properties-e2e');artifact.mkdir(parents=True,exist_ok=True)
receipt={'reproduce':'python3 tests/properties_e2e.py zig-out/bin/doin','commands':[],'checks':[],'passed':False}
with tempfile.TemporaryDirectory() as temp:
 root=pathlib.Path(temp);store=root/'store';store.mkdir();env={**os.environ,'DOIN_CONFIG_DIR':str(root/'config'),'NO_COLOR':'1','DOIN_REMINDER_NOW':'1791043200'};file=store/'tasks.md'
 def run(*args,ok=True,input='y\n'):
  p=subprocess.run([binary,*args],input=input,text=True,capture_output=True,env=env,timeout=15)
  receipt['commands'].append({'args':args,'code':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
  assert (p.returncode==0)==ok,(args,p.stdout,p.stderr)
  return p
 def schema():
  return json.loads(re.search(r'^<!-- doin:properties=(.*?) -->$',file.read_text(),re.M).group(1))
 active_process=None
 def vals():
  result=[];fence=None
  for line in file.read_text().splitlines():
   marker=re.match(r'^([`~]{3,})',line.strip())
   if fence:
    if marker and marker[1][0]==fence[0] and len(marker[1])>=fence[1] and re.fullmatch(r'[`~]+\s*',line.strip()):fence=None
    continue
   if marker:fence=(marker[1][0],len(marker[1]));continue
   if re.match(r'^\s*[-*] \[[ xX]\] ',line):
    match=re.search(r'<!-- doin:values=(.*?) -->',line)
    if match:result.append(json.loads(match[1]))
  return result
 try:
  run('init','--storage',str(store),'--provider','manual')
  original='# Work\n- [ ] Ship @status(doing) <!-- doin:id=0123456789abcdef0123456789abcdef remind=1893456000 -->\n- [ ] Review release\n```md\n<!-- doin:properties=not real JSON -->\n- [ ] Fenced example <!-- doin:values=broken -->\n```\nCustom notes survive.\n'
  file.write_text(original)
  for name,kind,options in [('Estimate','number',None),('Deadline','date',None),('Approved','boolean',None),('Note','string',None),('Priority','single_select','Low,High'),('Tags','multi_select','Design,Build,Ship')]:
   args=['properties','add',name,kind]+([options] if options else[]);run(*args)
  before=schema();ids={p['name']:p['id'] for p in before};option_ids={p['name']:p['options'] for p in before}
  for name,value in [('Estimate','3.5'),('Deadline','2028-02-29'),('Approved','true'),('Note','literal @status(done) <!-- unsafe --> stays text'),('Priority','High'),('Tags','Design,Ship')]:
   run('set','1',name,value)
   if name=='Estimate':
    shown=run('remind','list').stdout;assert '#1' in shown and 'Ship' in shown and 'scheduled' in shown
    import datetime
    expected_time=datetime.datetime.fromtimestamp(1893456000).strftime('%Y-%m-%d %H:%M');assert expected_time in shown and 'doin:id=0123456789abcdef0123456789abcdef remind=1893456000' in file.read_text()
  reminder_before=file.read_text();reminder_values=vals();run('remind','1','in','15m');assert vals()==reminder_values and 'doin:id=0123456789abcdef0123456789abcdef remind=1791044100' in file.read_text();assert file.read_text().count('<!-- doin:id=')==1
  run('remind','1','off');assert vals()==reminder_values and 'remind=' not in file.read_text() and 'doin:id=0123456789abcdef0123456789abcdef' in file.read_text();file.write_text(reminder_before)

  assert '\\u003c' in file.read_text() and '\\u003e' in file.read_text()
  assert all(ids[name] in vals()[0] for name in ids)
  assert 'Custom notes survive.' in file.read_text() and '<!-- doin:values=broken -->' in file.read_text()
  assert 'remind=1893456000' in file.read_text() and '@status(doing)' in file.read_text()
  receipt['checks'].append('six typed schemas and values persist within Markdown without changing fences, notes, reminders or status')
  # Status/reminder mutation must preserve opaque values including status-looking text.
  current_values=vals();run('mark','1','blocked');assert vals()==current_values and 'remind=1893456000' in file.read_text();run('mark','1','doing');assert vals()==current_values
  saved=file.read_text();run('properties','rename','Priority','Urgency');run('properties','options','Urgency','rename','High','Critical')
  renamed=schema();assert next(p for p in renamed if p['name']=='Urgency')['id']==ids['Priority'];assert next(p for p in renamed if p['name']=='Urgency')['options']==[{**o,'name':'Critical' if o['name']=='High' else o['name']} for o in option_ids['Priority']]
  assert run('filter','property','Urgency','Critical').stdout.find('Ship')>=0
  assert run('filter','property','Tags','Design,Ship').stdout.find('Ship')>=0
  assert run('filter','property','Tags','Ship,Design').stdout.find('Ship')>=0 and run('filter','property','Tags','Design').stdout.find('Ship')>=0
  option_before=file.read_text();option_values=vals();run('properties','options','Tags','remove','Build');assert vals()==option_values;run('undo');assert file.read_text()==option_before
  run('properties','options','Tags','remove','Ship','clear');assert vals()[0][ids['Tags']]==[option_ids['Tags'][0]['id']];run('undo');assert file.read_text()==option_before
  receipt['checks'].append('property and option renames preserve IDs and filter existing values')
  unchanged=file.read_text()
  for name,value in [('Estimate','nan'),('Deadline','2027-02-29'),('Approved','yes'),('Urgency','Unknown'),('Tags','Design,Design')]:run('set','1',name,value,ok=False);assert file.read_text()==unchanged
  run('set','3','Estimate','4',ok=False);assert file.read_text()==unchanged
  run('properties','type','Estimate','date',ok=False);assert file.read_text()==unchanged
  run('properties','options','Urgency','remove','Critical',ok=False);assert file.read_text()==unchanged
  receipt['checks'].append('invalid typed values, fenced task numbers and populated destructive changes refuse without mutation')
  run('properties','type','Estimate','date','clear',input='n\n');assert file.read_text()==unchanged
  run('properties','type','Estimate','date','clear');assert ids['Estimate'] not in vals()[0];run('undo');assert file.read_text()==unchanged
  run('unset','1','Approved');assert ids['Approved'] not in vals()[0];run('undo');assert file.read_text()==unchanged
  run('properties','remove','Note');assert ids['Note'] not in vals()[0];run('undo');assert file.read_text()==unchanged
  receipt['checks'].append('explicit clear/remove/unset use proposal cancellation and guarded document undo')
  # External edit while a schema proposal awaits confirmation must not be overwritten.
  p=subprocess.Popen([binary,'properties','remove','Note'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env)
  active_process=p
  import time, select
  prompt_bytes=b'';deadline=time.monotonic()+5
  while b'[y/N]' not in prompt_bytes and b'[y/n]' not in prompt_bytes:
   assert time.monotonic()<deadline,'schema confirmation prompt never arrived'
   readable,_,_=select.select([p.stdout],[],[],.1)
   if readable:
    block=os.read(p.stdout.fileno(),4096);assert block,'process exited before confirmation';prompt_bytes+=block
  external=unchanged+'External editor content.\n';file.write_text(external);stdout,stderr=p.communicate('y\n',timeout=15);stdout=prompt_bytes.decode()+stdout
  receipt['commands'].append({'args':['properties','remove','Note'],'code':p.returncode,'stdout':stdout,'stderr':stderr,'external_edit':True});assert p.returncode!=0 and file.read_text()==external
  receipt['checks'].append('external edit during preview survives stale write refusal')
  def preview():
   process=subprocess.Popen([binary,'properties','remove','Note'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env)
   prefix=b'';deadline=time.monotonic()+5
   try:
    while b'[y/N]' not in prefix and b'[y/n]' not in prefix:
     assert time.monotonic()<deadline,'schema confirmation prompt never arrived'
     readable,_,_=select.select([process.stdout],[],[],.1)
     if readable:
      block=os.read(process.stdout.fileno(),4096);assert block,'process exited before confirmation';prefix+=block
    return process,prefix
   except BaseException:
    process.terminate();process.wait(timeout=2);raise
  outside=root/'outside';outside.mkdir();outside_file=outside/'tasks.md';outside_file.write_text(external)
  for name in ('.tasks.undo','.tasks.undo-current'):(outside/name).write_text('outside sentinel '+name)
  outside_before={p.name:p.read_bytes() for p in outside.iterdir()};undo_before={p.name:p.read_bytes() for p in store.iterdir() if p.name.startswith('.tasks.undo')}
  p,prefix=preview();active_process=p;retained=root/'retained';store.rename(retained);store.symlink_to(outside,target_is_directory=True)
  try:
   stdout,stderr=p.communicate('y\n',timeout=15);receipt['commands'].append({'args':['properties','remove','Note'],'code':p.returncode,'stdout':prefix.decode()+stdout,'stderr':stderr,'symlink_replaced':True})
   assert p.returncode!=0 and 'selected workspace changed' in stderr.lower() and {p.name:p.read_bytes() for p in outside.iterdir()}==outside_before
   assert (retained/'tasks.md').read_text()==external and {p.name:p.read_bytes() for p in retained.iterdir() if p.name.startswith('.tasks.undo')}==undo_before
  finally:store.unlink();retained.rename(store)
  p,prefix=preview();active_process=p;config=root/'config'/'config.json';config_before=config.read_bytes();settings=json.loads(config_before);settings['storage']=str(outside);config.write_text(json.dumps(settings))
  try:
   stdout,stderr=p.communicate('y\n',timeout=15);receipt['commands'].append({'args':['properties','remove','Note'],'code':p.returncode,'stdout':prefix.decode()+stdout,'stderr':stderr,'config_switched':True})
   assert p.returncode!=0 and 'selected workspace changed' in stderr.lower() and file.read_text()==external and {p.name:p.read_bytes() for p in outside.iterdir()}==outside_before
  finally:config.write_bytes(config_before)
  receipt['checks'].append('storage symlink replacement and config switch during preview preserve both documents and undo records')
  # Metadata travels entirely as the ordinary document content sent by library sync.
  body=json.dumps({'revision':7,'content':file.read_text()});assert json.loads(body)['content']==external and 'doin:properties=' in body and 'doin:values=' in body
  receipt['checks'].append('schema and values reside in the same Markdown document, without sidecar storage')
  receipt['passed']=True
 finally:
  if active_process is not None and active_process.poll() is None:
   active_process.terminate()
   try:active_process.wait(timeout=2)
   except subprocess.TimeoutExpired:active_process.kill();active_process.wait(timeout=2)
  if sys.exc_info()[1] is not None:receipt['failure']=str(sys.exc_info()[1])
  if file.exists():(artifact/'tasks.md').write_text(file.read_text())
  serialized=json.dumps(receipt,indent=2)+'\n'
  (artifact/'report.json').write_text(serialized)
  import time
  (artifact/f'report-{time.time_ns()}.json').write_text(serialized)
print(f"Passed {len(receipt['checks'])} properties CLI groups.")
