#!/usr/bin/env python3
"""Black-box Copilot adapter contract; real Node executes a fixture SDK.

Failure matrix: missing SDK/runtime, login failure, forbidden tools/hooks,
provider failure, oversized output, cancellation, and task-file mutation.
Run after building: python3 tests/copilot_e2e.py --bin zig-out/bin/doin
"""
import argparse, json, os, pathlib, shutil, signal, subprocess, tempfile, time

p = argparse.ArgumentParser()
p.add_argument('--bin', default='zig-out/bin/doin')
p.add_argument('--artifacts', default='artifacts/copilot-e2e')
args = p.parse_args()
binary = pathlib.Path(args.bin).resolve()
artifacts = pathlib.Path(args.artifacts).resolve()
artifacts.mkdir(parents=True, exist_ok=True)
records = []
with tempfile.TemporaryDirectory(prefix='doin-copilot-e2e-') as tmp:
    root = pathlib.Path(tmp)
    config, storage = root / 'config', root / 'tasks'
    config.mkdir()
    shimdir=root/'bin'
    shimdir.mkdir()
    cli=shimdir/'copilot'
    cli.write_text('#!'+shutil.which('python3')+'\n'+'''import json,os,pathlib,sys
assert sys.argv[1:]==['login','--web-flow'],sys.argv
base=pathlib.Path(os.environ['COPILOT_HOME'])
assert base==pathlib.Path(os.environ['DOIN_CONFIG_DIR'])/'copilot'
assert os.environ['COPILOT_DISABLE_KEYTAR']=='1'
assert os.environ['COPILOT_ALLOW_ALL']=='false'
(base/'config.json').write_text(json.dumps({'logged_in_users':[{'oauth_token':'fixture-only'}]}))
(base/'config.json').chmod(0o600)
(base/'package.json').write_text('{}')
''')
    cli.chmod(0o755)
    global_home=root/'home'/'.copilot'
    global_home.mkdir(parents=True)
    (global_home/'config.json').write_text('global-credentials-untouched')
    sdk = root / 'sdk.cjs'
    sdk.write_text('''const fs = require('node:fs');
const cp = require('node:child_process');
let worker;
function record(value) { fs.appendFileSync(process.env.COPILOT_FIXTURE_LOG, JSON.stringify(value)+'\\n'); }
exports.CopilotClient = class {
  constructor(options) {
    if(options.mode !== 'empty' || !options.baseDirectory.startsWith(process.env.DOIN_CONFIG_DIR)) throw Error('unsafe client');
    record({event:'client',mode:options.mode,base:options.baseDirectory});
  }
  async start() {}
  async createSession(options) {
    if(options.availableTools.length || options.enableFileHooks !== false || options.enableSkills !== false || options.skipCustomInstructions !== true) throw Error('unsafe session');
    const decision = await options.onPermissionRequest({kind:'shell'},{});
    if(decision.kind !== 'deny-by-default') throw Error('tool permission allowed');
    record({event:'session',model:options.model,tools:options.availableTools,permission:decision.kind});
    return {sendAndWait: async ({prompt}) => {
      record({event:'prompt',prompt});
      if(process.env.COPILOT_FIXTURE_MODE==='fail') throw Error('fixture provider failure');
      if(process.env.COPILOT_FIXTURE_MODE==='large') return {data:{content:'x'.repeat(1100000)}};
      if(process.env.COPILOT_FIXTURE_MODE==='stall') {
        worker=cp.spawn(process.execPath,['-e','setInterval(()=>{},1000)']);
        fs.writeFileSync(process.env.COPILOT_FIXTURE_PID,String(worker.pid));
        return new Promise(()=>{});
      }
      return {data:{content:'Fixture Copilot answer. Tasks unchanged.'}};
    }, disconnect:async()=>record({event:'disconnect'})};
  }
  async stop() { if(worker) {worker.kill(); await new Promise(r=>worker.once('exit',r));} record({event:'stop'}); }
};
''')
    env = {**os.environ, 'HOME':str(root/'home'), 'PATH':str(shimdir)+os.pathsep+os.environ['PATH'], 'DOIN_CONFIG_DIR':str(config), 'DOIN_COPILOT_SDK':str(sdk), 'COPILOT_FIXTURE_LOG':str(root/'sdk.jsonl')}
    def run(*argv, ok=True):
        result = subprocess.run([str(binary), *argv], env=env, capture_output=True, text=True, timeout=20)
        records.append({'argv':argv,'exit':result.returncode,'stdout':result.stdout,'stderr':result.stderr})
        assert (result.returncode == 0) == ok, records[-1]
        return result.stdout + result.stderr
    run('init','--storage',str(storage),'--provider','copilot','--model','auto')
    run('login')
    assert (config/'copilot'/'config.json').exists()
    assert (config/'copilot'/'config.json').stat().st_mode & 0o777 == 0o600
    run('logout')
    assert not (config/'copilot'/'config.json').exists()
    assert (config/'copilot'/'package.json').exists()
    assert (global_home/'config.json').read_text()=='global-credentials-untouched'
    assert json.loads((config/'config.json').read_text())['provider']=='copilot'
    run('logout')
    taskfile = storage/'tasks.md'
    before = taskfile.read_bytes()
    assert 'Fixture Copilot answer' in run('ask','Plan launch across design, engineering, and QA. Do not change tasks.')
    assert taskfile.read_bytes() == before
    events = [json.loads(line) for line in (root/'sdk.jsonl').read_text().splitlines()]
    assert [e['event'] for e in events] == ['client','session','prompt','disconnect','stop'], events
    env['COPILOT_FIXTURE_MODE']='fail'
    run('ask','Handle provider failure.',ok=False)
    env['COPILOT_FIXTURE_MODE']='large'
    run('ask','Bound output.',ok=False)
    env['COPILOT_FIXTURE_MODE']='stall'
    env['COPILOT_FIXTURE_PID']=str(root/'worker.pid')
    proc = subprocess.Popen([str(binary),'ask','Cancel long request.'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    worker_pid = None
    try:
        deadline = time.monotonic()+10
        while not (root/'worker.pid').exists() and time.monotonic()<deadline: time.sleep(.05)
        assert (root/'worker.pid').exists(), 'SDK worker did not start'
        worker_pid = int((root/'worker.pid').read_text())
        proc.send_signal(signal.SIGTERM)
        stdout,stderr = proc.communicate(timeout=10)
        records.append({'argv':['ask','Cancel long request.'],'exit':proc.returncode,'stdout':stdout,'stderr':stderr})
        deadline = time.monotonic()+3
        while time.monotonic()<deadline:
            try: os.kill(worker_pid,0)
            except ProcessLookupError: break
            time.sleep(.05)
        else: raise AssertionError('Copilot SDK child survived cancellation')
    finally:
        if proc.poll() is None: proc.kill(); proc.wait()
        if worker_pid:
            try: os.kill(worker_pid,signal.SIGTERM)
            except ProcessLookupError: pass
    env.pop('COPILOT_FIXTURE_MODE')
    env['DOIN_COPILOT_SDK']=str(root/'missing.cjs')
    run('ask','Report missing dependency.',ok=False)
    assert taskfile.read_bytes() == before
    (artifacts/'sdk-events.json').write_text(json.dumps(events,indent=2))
(artifacts/'results.json').write_text(json.dumps(records,indent=2))
print('Copilot adapter E2E passed; evidence:',artifacts)
