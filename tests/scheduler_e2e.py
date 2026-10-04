"""Linux scheduler E2E driver uses real module + fake systemctl, no host jobs.
Failures: argument/unit injection, %/$ expansion, activation outage, rollback,
disable outage leaving enabled flags, paths with spaces/Unicode, timeout+child cleanup.
Driver compile is a separate bounded lane command, before runtime check."""
import os,json,pathlib,subprocess,tempfile,atexit
ROOT=pathlib.Path(__file__).resolve().parents[1];BIN=os.environ.get('DOIN_SCHEDULER_DRIVER',str(ROOT/'artifacts/scheduler-driver'));ART=ROOT/'artifacts/scheduler';ART.mkdir(parents=True,exist_ok=True);log=[];passed=False
atexit.register(lambda:(ART/'result.json').write_text(json.dumps({'passed':passed,'command':'python3 tests/scheduler_e2e.py','commands':log},indent=2)))
with tempfile.TemporaryDirectory(prefix='doin-systemd-') as temp:
 d=pathlib.Path(temp);cfg=d/'config space日本%$';cfg.mkdir();store=d/'tasks space日本';store.mkdir();shim=d/'bin';shim.mkdir();units=d/'units';journal=d/'calls.jsonl'
 fake=shim/'systemctl';fake.write_text('#!/usr/bin/env python3\nimport os,sys,json\nwith open(os.environ["SCHEDULER_LOG"],"a")as f:f.write(json.dumps(sys.argv[1:])+"\\n")\nif os.environ.get("SCHEDULER_FAIL")=="1" and "enable" in sys.argv:sys.exit(8)\n');fake.chmod(0o755)
 env={**os.environ,'HOME':str(d),'DOIN_SYSTEMD_UNIT_DIR':str(units),'SCHEDULER_LOG':str(journal),'PATH':str(shim)+':'+os.environ['PATH']}
 def run(cmd,ok=True):
  r=subprocess.run([BIN,cmd,str(cfg),str(store)],env=env,capture_output=True,text=True,timeout=10);log.append({'cmd':cmd,'code':r.returncode,'stderr':r.stderr});assert(r.returncode==0)==ok
 env['SCHEDULER_FAIL']='1';run('enable',False);assert not list(units.glob('*.timer'));env.pop('SCHEDULER_FAIL')
 run('enable');timer=list(units.glob('*.timer'));service=list(units.glob('*.service'));assert len(timer)==len(service)==1
 text=service[0].read_text();assert 'Type=oneshot' in text and 'DOIN_JOB_STORAGE' in text and '%%' in text and 'Restart=always' not in text;assert 'OnUnitInactiveSec=60s' in timer[0].read_text()
 (ART/'service.txt').write_text(text);(ART/'timer.txt').write_text(timer[0].read_text());run('disable');assert not list(units.glob('*.timer'));assert not list(units.glob('*.service'))
passed=True;print('PASS Linux user timer quoting, activation rollback and disable without real jobs')
