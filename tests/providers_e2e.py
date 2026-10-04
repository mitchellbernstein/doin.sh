#!/usr/bin/env python3
"""Provider switching against a real executable and loopback service."""
import argparse, hashlib, http.server, json, os, pathlib, subprocess, sys, tempfile, threading, time, traceback

p = argparse.ArgumentParser()
p.add_argument('--bin', default='zig-out/bin/doin')
p.add_argument('--artifacts', default='artifacts/providers-e2e')
args = p.parse_args()
binary = pathlib.Path(args.bin).resolve()
artifact = pathlib.Path(args.artifacts).resolve(); artifact.mkdir(parents=True, exist_ok=True)
cases, commands, requests = [], [], []

class Fixture(http.server.BaseHTTPRequestHandler):
    status = 200
    def log_message(self, *args): pass
    def do_GET(self):
        self.respond({'data': [{'id': 'fixture-reasoner'}, {'id': 'fixture-chat'}]})
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append({'path': self.path, 'body': body, 'custom_credential': self.headers.get('Authorization') == 'Bearer fixture-custom-secret', 'deepseek_credential': self.headers.get('Authorization') == 'Bearer fixture-deepseek-secret'})
        self.respond({'choices': [{'message': {'role': 'assistant', 'content': 'Review migration, then run restore rehearsal.'}, 'finish_reason': 'stop'}]})
    def respond(self, data):
        raw = json.dumps(data).encode()
        self.send_response(self.status); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw)

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
try:
    with tempfile.TemporaryDirectory(prefix='doin-providers-') as tmp:
        root = pathlib.Path(tmp); storage = root / 'tasks'; config = root / 'config'
        env = {k: v for k, v in os.environ.items() if not k.endswith('_API_KEY') and k not in ('GH_TOKEN', 'GITHUB_TOKEN', 'VERCEL_OIDC_TOKEN')}
        env.update(DOIN_CONFIG_DIR=str(config), DOIN_API_KEY='fixture-custom-secret', DEEPSEEK_API_KEY='fixture-deepseek-secret')
        def run(*argv, ok=True):
            r = subprocess.run([str(binary), *argv], env=env, input='', text=True, capture_output=True, timeout=20)
            commands.append({'argv': argv, 'exit': r.returncode, 'output': r.stdout + r.stderr})
            assert (r.returncode == 0) == ok, commands[-1]
            assert 'fixture-custom-secret' not in commands[-1]['output'] and 'fixture-deepseek-secret' not in commands[-1]['output']
            return commands[-1]['output']
        def case(name, fn):
            try: fn(); cases.append({'name': name, 'passed': True})
            except Exception: cases.append({'name': name, 'passed': False, 'failure': traceback.format_exc()})
        endpoint = f'http://127.0.0.1:{server.server_port}/v1'
        def workflow():
            run('init', '--storage', str(storage), '--provider', 'api', '--model', 'fixture-chat', '--endpoint', endpoint)
            taskfile = storage / 'tasks.md'
            taskfile.write_text('# Release café\n\n- [ ] Review migration\n- [ ] Restore rehearsal\n')
            before = taskfile.read_bytes()
            assert 'Review migration' in run('ask', 'What next?')
            assert requests[-1]['custom_credential'] and requests[-1]['path'] == '/v1/chat/completions'
            assert 'Restore rehearsal' in json.dumps(requests[-1]['body']) and taskfile.read_bytes() == before
            run('provider', 'deepseek', '--model', 'deepseek-chat')
            settings = json.loads((config / 'config.json').read_text())
            assert settings['provider'] == 'deepseek' and settings['endpoint'].startswith('https://api.deepseek.com')
            run('provider', 'deepseek', '--endpoint', endpoint)
            run('ask', 'Use this provider account')
            assert requests[-1]['deepseek_credential'] and not requests[-1]['custom_credential']
            env.pop('DEEPSEEK_API_KEY')
            count = len(requests)
            run('ask', 'Do not borrow custom credentials', ok=False)
            assert len(requests) == count
            run('provider', 'manual')
            run('provider', 'api')
            settings = json.loads((config / 'config.json').read_text())
            assert settings['endpoint'] == endpoint and settings['model'] == 'fixture-chat'
            run('ask', 'Continue'); assert requests[-1]['custom_credential']
            assert 'secret' not in (config / 'config.json').read_text()
            Fixture.status = 503
            run('ask', 'Unavailable', ok=False); assert taskfile.read_bytes() == before
            Fixture.status = 200
        case('custom API asks safely and provider profiles restore endpoint/model', workflow)
        def invalid():
            before = (config / 'config.json').read_bytes()
            run('provider', 'invented', ok=False)
            assert (config / 'config.json').read_bytes() == before
            run('provider', 'api', '--endpoint', 'http://example.org', '--model', 'bad', ok=False)
            assert (config / 'config.json').read_bytes() == before
            run('provider', 'grok', '--endpoint', endpoint, '--model', 'grok-fixture', ok=False)
            assert (config / 'config.json').read_bytes() == before
        case('invalid providers/endpoints preserve active configuration', invalid)
        def account_routes():
            shim = root / 'shim'; shim.mkdir()
            curl = shim / 'curl'
            curl.write_text('#!' + sys.executable + '''
import json,os,pathlib,sys
url=sys.argv[sys.argv.index('--url')+1]
setup=sys.stdin.read()
provider='grok' if url.startswith('https://cli-chat-proxy.grok.com/v1/') else 'vercel'
assert url in ('https://cli-chat-proxy.grok.com/v1/responses','https://ai-gateway.vercel.sh/v1/chat/completions'),url
assert 'Bearer route-'+provider in setup and 'fixture-custom-secret' not in setup
if provider=='grok':
 assert 'X-XAI-Token-Auth: xai-grok-cli' in setup and 'x-grok-user-id: fixture-account' in setup
 assert 'x-grok-client-version: 1.2.3' in setup and 'x-grok-model-override: fixture-grok' in setup
else: assert 'x-vercel-ai-gateway-team: team-fixture' in setup
with pathlib.Path(os.environ['ROUTE_LOG']).open('a') as f: f.write(json.dumps({'url':url,'headers_verified':True})+'\\n')
if provider=='grok':
 print('data: '+json.dumps({'type':'response.output_text.delta','delta':'Route answer.'})+'\\n')
 print('data: '+json.dumps({'type':'response.completed','response':{'status':'completed','output':[{'type':'message','role':'assistant','content':[{'type':'output_text','text':'Route answer.'}]}]}})+'\\n')
else: print(json.dumps({'choices':[{'message':{'role':'assistant','content':'Route answer.'},'finish_reason':'stop'}]}))
''')
            curl.chmod(0o700)
            previous = env['PATH']; env.update(PATH=str(shim)+os.pathsep+previous, DOIN_GROK_CLIENT_VERSION='1.2.3', DOIN_VERCEL_TEAM_ID='team-fixture', ROUTE_LOG=str(root/'routes.jsonl'))
            try:
                for provider, issuer in [('grok', 'https://auth.x.ai'), ('vercel', 'https://vercel.com')]:
                    record = {'provider':provider,'issuer':issuer,'access_token':'route-'+provider,'refresh_token':'fixture-refresh','client_id':'fixture-client','scope':'openid offline_access','subject':'fixture-account','expires_at':int(time.time())+3600}
                    credential = config / (provider+'.json'); credential.write_text(json.dumps(record)); credential.chmod(0o600)
                    run('provider', provider, '--model', 'fixture-'+provider)
                    assert 'Route answer.' in run('ask', 'Review the release safely')
                requests.extend(json.loads(line) for line in (root/'routes.jsonl').read_text().splitlines())
            finally: env['PATH'] = previous
        case('Grok Responses and Vercel team routing use isolated account credentials', account_routes)
finally:
    server.shutdown(); server.server_close(); thread.join(timeout=5)
report = {'binary': str(binary), 'sha256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'cases': cases, 'commands': commands, 'requests': requests}
(artifact / 'results.json').write_text(json.dumps(report, indent=2))
for c in cases: print(('PASS ' if c['passed'] else 'FAIL ') + c['name'])
print('Evidence:', artifact)
raise SystemExit(0 if all(c['passed'] for c in cases) else 1)
