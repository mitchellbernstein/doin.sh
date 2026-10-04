#!/usr/bin/env python3
"""Uninstall real executable copies in isolated homes; retain before/after receipts."""
import argparse, hashlib, json, os, pathlib, shutil, subprocess, tempfile, traceback, sys

p = argparse.ArgumentParser()
p.add_argument('--bin', default='zig-out/bin/doin')
p.add_argument('--artifacts', default='artifacts/uninstall-e2e')
args = p.parse_args()
source = pathlib.Path(args.bin).resolve()
artifacts = pathlib.Path(args.artifacts).resolve(); artifacts.mkdir(parents=True, exist_ok=True)
cases, commands = [], []

def snapshot(root):
    return {str(f.relative_to(root)): hashlib.sha256(f.read_bytes()).hexdigest() for f in root.rglob('*') if f.is_file() and not f.is_symlink()}

with tempfile.TemporaryDirectory(prefix='doin-uninstall-') as tmp:
    suite = pathlib.Path(tmp)
    def fixture(name, configured=True):
        root = suite / name; root.mkdir()
        home = root / 'home'; (home / 'Documents').mkdir(parents=True)
        config = root / 'config'; config.mkdir()
        storage = home / 'Documents' / 'doin'; storage.mkdir()
        (storage / 'tasks.md').write_text('# Launch café\n\n- [ ] Review migration\n')
        (storage / 'notes').mkdir(); (storage / 'notes' / 'context.txt').write_text('Preserve this too.')
        executable = root / 'bin' / 'doin'; executable.parent.mkdir(); shutil.copy2(source, executable)
        (executable.parent / 'other-tool').write_text('Unrelated executable.')
        if configured: (config / 'config.json').write_text(json.dumps({'storage':str(storage),'provider':'manual'}))
        (config / 'provider-api.key').write_text('fixture-private-key'); (config / 'provider-api.key').chmod(0o600)
        (config / 'unrelated.txt').write_text('Unrelated config file.')
        env = {**os.environ, 'DOIN_CONFIG_DIR':str(config), 'HOME':str(home), 'USERPROFILE':str(home), 'TERM':'dumb'}
        return root, config, storage, executable, env
    def run(f, stdin, ok=True):
        root, config, storage, executable, env = f
        before = snapshot(root)
        r = subprocess.run([str(executable), 'uninstall'], input=stdin, capture_output=True, text=True, env=env, timeout=20)
        command = {'case':root.name,'stdin':stdin,'exit':r.returncode,'output':r.stdout+r.stderr,'before':before,'after':snapshot(root)}
        commands.append(command)
        assert (r.returncode == 0) == ok, command
        assert 'fixture-private-key' not in command['output'] and 'NotInitialized' not in command['output']
        return command
    def case(name, fn):
        try: fn(); cases.append({'name':name,'passed':True})
        except Exception: cases.append({'name':name,'passed':False,'failure':traceback.format_exc()})
    def keep():
        f = fixture('keep'); root, config, storage, executable, env = f
        tasks = snapshot(storage)
        focus_state = config/'focus-0123456789abcdef.json'; focus_state.write_text('{"date":"2026-10-04","task_id":"'+('a'*32)+'"}')
        run(f, '1\ny\n')
        assert not focus_state.exists()
        assert not executable.exists() and snapshot(storage) == tasks
        assert not (config/'config.json').exists() and not (config/'provider-api.key').exists()
        assert (config/'unrelated.txt').read_text() == 'Unrelated config file.'
        assert (executable.parent/'other-tool').exists()
    case('uninstall keeps entire Markdown folder and removes only CLI/settings', keep)
    def credentials():
        f = fixture('credentials'); config = f[1]
        (config/'copilot').mkdir()
        (config/'copilot'/'config.json').write_text('{"token":"fixture-copilot-secret"}')
        (config/'copilot'/'unrelated.txt').write_text('Keep this')
        (config/'host-id').write_text('fixture-host')
        (config/'.auth.lock').write_text('')
        run(f, '1\ny\n')
        assert not (config/'copilot'/'config.json').exists()
        assert not (config/'host-id').exists() and not (config/'.auth.lock').exists()
        assert (config/'copilot'/'unrelated.txt').read_text() == 'Keep this'
    case('uninstall clears nested provider credentials while preserving unrelated files', credentials)
    def fresh():
        f = fixture('uninitialized', configured=False)
        run(f, '1\ny\n')
        assert not f[3].exists() and f[2].exists()
    case('uninstall works before first setup', fresh)
    def erase():
        f = fixture('erase')
        run(f, '2\nDELETE\ny\n')
        assert not f[2].exists() and not f[3].exists()
        assert (f[1]/'unrelated.txt').exists()
    case('explicit folder deletion removes nested contents after typed confirmation', erase)
    def cancel():
        for index, response in enumerate(['1\nn\n', '2\nNO\n', '', '2\nDELETE\nn\n']):
            f = fixture('cancel-'+str(index)); r = run(f, response)
            assert r['before'] == r['after'], r
    case('decline, missing destructive phrase, and EOF leave every file unchanged', cancel)
    def corrupt():
        f = fixture('corrupt'); (f[1]/'config.json').write_text('{broken')
        run(f, '1\ny\n')
        assert not f[3].exists() and f[2].exists()
    case('corrupt configuration still allows CLI-only removal', corrupt)
    def schedules():
        if sys.platform != 'darwin': return
        for configured, active in [(True,True),(False,False)]:
            f = fixture('scheduled-'+str(configured),configured=configured)
            root, config, storage, executable, env = f
            agents=root/'agents'; agents.mkdir(); shim=root/'shim'; shim.mkdir()
            digest=hashlib.sha256(str(config).encode()).hexdigest()[:16]
            paths=[]
            for kind in ['reminders','sync']:
                file=agents/f'com.studioyeehaw.doin.{kind}.{digest}.plist'
                file.write_text('Fixture scheduled job'); paths.append(file)
            (agents/'unrelated.plist').write_text('Keep scheduled service')
            log=root/'scheduler.log'
            command=shim/'launchctl'
            command.write_text('#!'+sys.executable+'\nimport sys,pathlib\np=pathlib.Path('+repr(str(log))+')\nwith p.open("a") as f:f.write(" ".join(sys.argv[1:])+"\\n")\nif sys.argv[1]=="print":sys.exit('+str(0 if active else 113)+')\nif sys.argv[1]=="bootout":sys.exit('+str(0 if active else 5)+')\n')
            command.chmod(0o755)
            env.update(PATH=str(shim)+':'+env['PATH'],DOIN_REMINDER_AGENT_DIR=str(agents),DOIN_SYNC_AGENT_DIR=str(agents))
            run(f,'1\ny\n')
            assert not executable.exists() and not any(p.exists() for p in paths)
            assert (agents/'unrelated.plist').exists() and snapshot(storage)
            assert ('bootout' in log.read_text()) == active
    case('active and unloaded schedules are removed even without setup; unrelated jobs survive',schedules)
    def root_guard():
        f = fixture('protected'); home = pathlib.Path(f[4]['HOME'])
        (f[1]/'config.json').write_text(json.dumps({'storage':str(home),'provider':'manual'}))
        r = run(f, '2\nDELETE\ny\n', ok=False)
        assert r['before'] == r['after'] and f[3].exists()
    case('broad home folder is refused before any removal', root_guard)
    def symlink():
        f = fixture('symlink'); link = f[0]/'linked-tasks'; link.symlink_to(f[2], target_is_directory=True)
        (f[1]/'config.json').write_text(json.dumps({'storage':str(link),'provider':'manual'}))
        r = run(f, '2\nDELETE\ny\n', ok=False)
        assert f[2].exists() and f[3].exists() and r['before'] == r['after']
    case('symlink task root cannot redirect recursive deletion', symlink)
report = {'binary':str(source),'sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'cases':cases,'commands':commands}
(artifacts/'results.json').write_text(json.dumps(report,indent=2))
for c in cases: print(('PASS ' if c['passed'] else 'FAIL ') + c['name'])
print('Evidence:', artifacts)
raise SystemExit(0 if all(c['passed'] for c in cases) else 1)
