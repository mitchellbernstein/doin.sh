#!/usr/bin/env python3
"""Reproducible real CLI scenario; run after native build, not unit tests."""
import datetime, json, os, pathlib, subprocess, tempfile, sys
binary = str(pathlib.Path(sys.argv[1] if len(sys.argv)>1 else 'zig-out/bin/doin').resolve())
artifact = pathlib.Path('artifacts/productivity-e2e'); artifact.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory() as temp:
    root=pathlib.Path(temp); store=root/'store'; store.mkdir()
    env={**os.environ,'DOIN_CONFIG_DIR':str(root/'config'),'NO_COLOR':'1'}
    def run(*args,input=''):
        p=subprocess.run([binary,*args],input=input,text=True,capture_output=True,env=env,timeout=10)
        return p
    p=run('init','--storage',str(store),'--provider','manual'); assert p.returncode==0,p.stderr
    marker='<!-- doin:id=0123456789abcdef0123456789abcdef remind=1893456000 -->'
    original='# Work\n- [ ] Late @due(2020-01-01) @priority(high) '+marker+'\n- [x] Shipped\n# Home\n- [ ] Buy milk\n```md\n- [x] Example\n```\nNotes survive.\n````md\n```\n- [x] Nested example\n```` not a closer\n- [ ] Still example\n````\n- [ ] Valid leap @due(2024-02-29)\n- [ ] Invalid leap @due(2023-02-29)\n- [ ] Invalid month @due(0000-00-01)\n'
    file=store/'tasks.md'; file.write_text(original)
    receipts=[]
    for args in [('review',),('prioritize',),('visualize',)]:
        p=run(*args); assert p.returncode==0,(args,p.stderr); receipts.append({'args':args,'stdout':p.stdout})
        assert file.read_text()==original
        assert 'doin:id=' not in p.stdout
        assert 'Nested example' not in p.stdout and 'Still example' not in p.stdout
        if args[0]=='prioritize':
            assert p.stdout.index('Valid leap') < p.stdout.index('Invalid leap') < p.stdout.index('Invalid month')
    p=run('delete','1',input='n\n'); assert file.read_text()==original and 'doin:id=' not in p.stdout
    p=run('clear',input='n\n'); assert file.read_text()==original
    p=run('clear',input='y\n'); assert p.returncode==0,p.stderr
    after=file.read_text(); assert marker in after
    assert '- [x] Shipped' not in after and '- [x] Example' in after and 'Notes survive.' in after and 'Nested example' in after and 'Still example' in after
    p=run('undo'); assert p.returncode==0 and file.read_text()==original
    p=run('delete','99',input='y\n'); assert p.returncode!=0 and file.read_text()==original
    p=run('delete','group:Home',input='y\n'); assert p.returncode==0,p.stderr
    assert 'Buy milk' not in file.read_text() and 'Late' in file.read_text() and marker in file.read_text()
    today=datetime.date.today(); endweek=today+datetime.timedelta(days=6-today.weekday())
    nextmonth=(today.replace(day=28)+datetime.timedelta(days=4)).replace(day=1)
    calendar=f"# Work\n- [ ] Overdue @due(2020-01-01) {marker}\n- [ ] Today @due({today}) @status(doing)\n- [ ] Sunday @due({endweek}) @status(blocked)\n- [ ] Next month @due({nextmonth})\n- [ ] Undated @status(done)\n- [x] Completed @due({today}) @status(blocked)\n"
    file.write_text(calendar)
    for view in ('today','week','month'):
        p=run(view); assert p.returncode==0,p.stderr
        assert 'Overdue' in p.stdout and 'Today' in p.stdout and 'Undated' not in p.stdout and 'Completed' not in p.stdout
        assert 'Next month' not in p.stdout
        if view=='week': assert 'Sunday' in p.stdout
        receipts.append({'args':[view],'stdout':p.stdout})
    for prop,value,name in [('status','doing','Today'),('status','blocked','Sunday'),('status','done','Completed'),('status','todo','Undated'),('group','Work','Overdue'),('text','Undated','Undated')]:
        p=run('filter',prop,value); assert p.returncode==0 and name in p.stdout,(prop,p.stderr)
        if prop=='status' and value=='done': assert 'Undated' not in p.stdout
    p=run('mark','1','blocked',input='y\n'); assert p.returncode==0,p.stderr
    assert marker in file.read_text() and '@status(blocked)' in file.read_text().splitlines()[1]
    p=run('mark','1','done',input='y\n'); assert p.returncode==0 and '- [x] Overdue' in file.read_text() and marker in file.read_text()
    p=run('mark','1','todo',input='y\n'); assert p.returncode==0 and '- [ ] Overdue' in file.read_text() and '@status(' not in file.read_text().splitlines()[1]
    before=file.read_text(); p=run('mark','1','garbage',input='y\n'); assert p.returncode!=0 and file.read_text()==before
    p=run('statuses','add','waiting',input='y\n'); assert p.returncode==0,p.stderr
    assert 'doin:statuses=' in file.read_text()
    p=run('mark','1','waiting',input='y\n'); assert p.returncode==0 and '@status(waiting)' in file.read_text()
    p=run('status','waiting'); assert p.returncode==0 and 'Overdue' in p.stdout
    file.write_text(file.read_text().replace('@status(waiting)', '@status(waiting) @status(waiting)'))
    p=run('statuses','rename','waiting','review',input='y\n'); assert p.returncode==0 and '@status(review)' in file.read_text() and marker in file.read_text()
    before=file.read_text(); p=run('statuses','remove','review',input='y\n'); assert p.returncode!=0 and file.read_text()==before
    p=run('statuses','remove','review','todo',input='y\n'); assert p.returncode==0 and '@status(review)' not in file.read_text() and '@status(waiting)' not in file.read_text() and marker in file.read_text()
    before=file.read_text(); p=run('statuses','remove','done',input='y\n'); assert p.returncode!=0 and file.read_text()==before
    p=run('mark','1','unknown',input='y\n'); assert p.returncode!=0 and file.read_text()==before
    near_limit='- [ ] Keep me\n'+'z'*(1024*1024-len('- [ ] Keep me\n'))
    file.write_text(near_limit)
    undo=store/'.tasks.undo'; undo_before=undo.read_bytes()
    undo_current=store/'.tasks.undo-current'; undo_current_before=undo_current.read_bytes()
    p=run('statuses','add','waiting',input='y\n')
    assert p.returncode!=0 and file.read_text()==near_limit
    assert undo.read_bytes()==undo_before and undo_current.read_bytes()==undo_current_before
    receipts.append({'args':['statuses','add','waiting'],'near_limit_size':len(near_limit),'returncode':p.returncode,'stderr':p.stderr,'tasks_unchanged':True,'undo_unchanged':True})
    (artifact/'scenario.json').write_text(json.dumps({'commands':receipts,'before':original,'clear_after':after,'group_after':file.read_text()},indent=2))
print('Productivity CLI E2E passed; artifacts/productivity-e2e/scenario.json')
