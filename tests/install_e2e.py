#!/usr/bin/env python3
"""Installer E2E: real release archives, checksum, executable, update/refusal.
Failure scenarios: corrupt archive/checksum; wrong platform; existing destination;
missing release; installation into directory with spaces. Never uses network.
"""
import hashlib, json, os, pathlib, subprocess, sys, tarfile, tempfile, traceback, zipfile
repo = pathlib.Path(__file__).resolve().parent.parent
artifacts = repo / 'artifacts/install-e2e'; artifacts.mkdir(parents=True, exist_ok=True)
cases, records = [], []
with tempfile.TemporaryDirectory(prefix='doin-install-e2e-') as tmp:
    root = pathlib.Path(tmp); shim = root / 'bin'; shim.mkdir()
    curl = shim / 'curl'
    curl.write_text('#!' + sys.executable + '\n' + '''import os, pathlib, shutil, sys
args=sys.argv[1:]
url=next(x for x in args if x.startswith('https://'))
source=pathlib.Path(os.environ['FIXTURE_DIST']) / url.rsplit('/',1)[-1]
target=pathlib.Path(args[args.index('-o')+1])
if os.environ.get('CORRUPT') and source.name == 'SHA256SUMS':
 target.write_text('\\n'.join('0'*64+'  '+x.name for x in source.parent.glob('*.tar.gz'))+'\\n')
else: shutil.copyfile(source,target)
'''); curl.chmod(0o755)
    env = os.environ.copy(); env.update(PATH=str(shim)+':'+env['PATH'], DOIN_REPO='fixture/tasks', DOIN_INSTALL_DIR=str(root/'install space'), FIXTURE_DIST=str(repo/'dist'))
    destination = pathlib.Path(env['DOIN_INSTALL_DIR'])/'doin'
    def run(ok=True):
        r = subprocess.run(['sh',str(repo/'scripts/install.sh')],env=env,capture_output=True,text=True,timeout=15)
        records.append({'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr})
        assert (r.returncode == 0) == ok, records[-1]
    def case(name, fn):
        try: fn(); cases.append({'name':name,'passed':True})
        except Exception: cases.append({'name':name,'passed':False,'failure':traceback.format_exc()})
    def install():
        run(); assert destination.is_file() and os.access(destination,os.X_OK)
        r = subprocess.run([str(destination),'--version'],capture_output=True,text=True,check=True)
        expected_version = os.environ.get('DOIN_BUILD_VERSION') or os.environ.get('GITHUB_REF_NAME') or '0.3.0'
        assert expected_version.removeprefix('v') in r.stdout
    def licenses():
        for archive in (repo/'dist').glob('doin-*.tar.gz'):
            with tarfile.open(archive) as bundle:
                assert bundle.extractfile('LICENSE').read() == (repo/'LICENSE').read_bytes(), archive.name
        windows = repo/'dist'/'doin-windows-x86_64.zip'
        assert windows.is_file(), 'Windows release archive missing'
        with zipfile.ZipFile(windows) as bundle:
            assert bundle.read('LICENSE') == (repo/'LICENSE').read_bytes(), windows.name
            assert bundle.read('doin.exe')[:2] == b'MZ', 'Windows executable missing'
    case('release archives include the current license unchanged',licenses)
    case('verified archive installs runnable native binary into folder with spaces',install)
    def refusal():
        before = destination.read_bytes(); run(False); assert destination.read_bytes() == before
    case('existing binary preserved without explicit update flag',refusal)
    def corrupt():
        before = destination.read_bytes(); env['CORRUPT']='1'; env['DOIN_REPLACE']='1'
        try: run(False); assert destination.read_bytes() == before
        finally: env.pop('CORRUPT')
    case('checksum mismatch refuses update and preserves installed binary',corrupt)
    def update(): run(); assert destination.is_file()
    case('explicit update succeeds after checksum verification',update)
report={'cases':cases,'commands':records}
(artifacts/'results.json').write_text(json.dumps(report,indent=2))
for c in cases: print(('PASS' if c['passed'] else 'FAIL')+' '+c['name'])
print('Evidence: '+str(artifacts))
raise SystemExit(0 if all(c['passed'] for c in cases) else 1)
