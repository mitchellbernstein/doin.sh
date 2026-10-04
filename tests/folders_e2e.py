#!/usr/bin/env python3
import argparse,json,os,subprocess,tempfile
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--bin',default='zig-out/bin/doin');args=p.parse_args();binary=str(Path(args.bin).resolve());receipts=[]
failure=None
try:
    with tempfile.TemporaryDirectory(prefix='doin folders ') as tmp:
        base=Path(tmp).resolve();root=base/'library';config=base/'config';env={**os.environ,'DOIN_CONFIG_DIR':str(config)}
        def run(*cmd,ok=True):
            r=subprocess.run([binary,*cmd],env=env,text=True,capture_output=True,timeout=10)
            receipts.append({'args':cmd,'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr})
            assert (r.returncode==0)==ok,(cmd,r.stdout,r.stderr)
            return r.stdout
        run('init','--storage',str(root),'--provider','manual')
        run('folder','list');rootid=json.loads((root/'.doin-folder.json').read_text())['id']
        existing=root/'Existing';existing.mkdir();(existing/'tasks.md').write_text('# Keep existing notes\n')
        run('folder','create',rootid,'Existing');assert (existing/'tasks.md').read_text()=='# Keep existing notes\n'
        run('folder','create',rootid,'Launch café');child=root/'Launch café';childid=json.loads((child/'.doin-folder.json').read_text())['id']
        (child/'tasks.md').write_text('# Launch\n\n- [ ] Preserve 東京\n')
        run('folder','create',childid,'Checks');grand=json.loads((child/'Checks'/'.doin-folder.json').read_text())['id']
        run('folder','select',grand)
        run('add','Selected descendant survives rename')
        run('folder','rename',childid,'Release');child=root/'Release';assert json.loads((child/'.doin-folder.json').read_text())['id']==childid
        assert json.loads((config/'config.json').read_text())['storage']==str(child/'Checks')
        assert 'Selected descendant survives rename' in (child/'Checks'/'tasks.md').read_text()
        run('folder','move',childid,grand,ok=False)
        run('folder','create',rootid,'Other');other=json.loads((root/'Other'/'.doin-folder.json').read_text())['id']
        run('folder','move',childid,other);child=root/'Other'/'Release';assert '東京' in (child/'tasks.md').read_text()
        assert json.loads((config/'config.json').read_text())['storage']==str(child/'Checks')
        run('folder','select',childid);assert str(child)==json.loads((config/'config.json').read_text())['storage']
        run('add','Local project task');assert 'Local project task' in (child/'tasks.md').read_text();assert 'Local project task' not in (root/'tasks.md').read_text()
        deep_parent=grand
        deep_path=child/'Checks'
        for level in range(24):
            run('folder','create',deep_parent,f'Level{level}')
            deep_path=deep_path/f'Level{level}'
            deep_parent=json.loads((deep_path/'.doin-folder.json').read_text())['id']
        run('folder','select',deep_parent);run('add','Deep project task');assert 'Deep project task' in (deep_path/'tasks.md').read_text()
        run('folder','list','unexpected',ok=False)
        saved_root=root
        renamed=base/'original library';root.rename(renamed);root.symlink_to(base,target_is_directory=True)
        run('folder','list',ok=False)
        root.unlink();renamed.rename(root)
        for organization,inputs,expected in [
            ('simple','\n\n','home'),
            ('custom','2\nLaunch café\nFirst 東京 task\n','custom'),
            ('projects','3\n\n','projects'),
            ('areas','3\n2\n','areas')]:
            fresh=base/('onboarding '+organization);fresh.mkdir()
            prior=fresh/'tasks.md';prior.write_text('# Existing\n\n```markdown\n- [ ] Literal fence\n```\n')
            template_child=fresh/('Inbox' if expected=='projects' else 'Personal')
            if expected in ('projects','areas'):
                template_child.mkdir();(template_child/'tasks.md').write_text('# Keep template child café\n')
            subconfig=base/('config '+organization)
            response=subprocess.run([binary,'init'],input=str(fresh)+'\n'+inputs+'1\n',env={**env,'DOIN_CONFIG_DIR':str(subconfig)},text=True,capture_output=True,timeout=10)
            receipts.append({'organization':organization,'exit':response.returncode,'stdout':response.stdout,'stderr':response.stderr})
            assert response.returncode==0,receipts[-1]
            assert response.stdout.index('How would you like to organize your tasks?')<response.stdout.index('How would you like your AI?'),receipts[-1]
            cfg=json.loads((subconfig/'config.json').read_text());assert cfg['library_root']==str(fresh)
            assert prior.read_text()=='# Existing\n\n```markdown\n- [ ] Literal fence\n```\n'
            if expected=='custom':
                assert cfg['storage']==str(fresh/'Launch café')
                assert 'First 東京 task' in (fresh/'Launch café'/'tasks.md').read_text()
            if expected in ('projects','areas'):
                names=['Inbox','Projects','Archive'] if expected=='projects' else ['Personal','Work','Someday']
                assert all((fresh/name/'tasks.md').exists() for name in names)
                assert (template_child/'tasks.md').read_text()=='# Keep template child café\n'
            target=base/('new storage '+organization)
            response=subprocess.run([binary,'settings'],input='1\n'+str(target)+'\n',env={**env,'DOIN_CONFIG_DIR':str(subconfig)},text=True,capture_output=True,timeout=10)
            receipts.append({'settings_reset':organization,'exit':response.returncode,'stdout':response.stdout,'stderr':response.stderr})
            assert response.returncode==0,receipts[-1]
            cfg=json.loads((subconfig/'config.json').read_text());assert cfg['storage']==str(target) and cfg['library_root'] is None
        run('folder','create',rootid,'../escape',ok=False)
        (root/'escape').symlink_to(base,target_is_directory=True);run('folder','list');assert not (base/'.doin-folder.json').exists()
except BaseException as exc:
    failure=repr(exc)
    raise
finally:
    Path('artifacts/folders').mkdir(parents=True,exist_ok=True)
    Path('artifacts/folders/native.json').write_text(json.dumps({'command':'python3 tests/folders_e2e.py --bin '+binary,'failure':failure,'receipts':receipts},indent=2)+'\n')
print('Folder lifecycle and escape scenarios passed.')
