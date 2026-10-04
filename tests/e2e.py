#!/usr/bin/env python3
"""Behavior tests against a real executable and loopback HTTP server; stdlib only."""
import argparse, hashlib, http.server, json, os, pathlib, subprocess, tempfile, threading, time, traceback

parser = argparse.ArgumentParser()
parser.add_argument('--bin', default='zig-out/bin/doin')
parser.add_argument('--artifacts', default='artifacts/e2e')
args = parser.parse_args()
binary = pathlib.Path(args.bin).resolve()
artifacts = pathlib.Path(args.artifacts).resolve(); artifacts.mkdir(parents=True, exist_ok=True)
records, cases, requests = [], [], []

class Fixture(http.server.BaseHTTPRequestHandler):
    response = 'Three tasks remain; first review the migration.'
    status = 200
    mutate = None
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append({'path': self.path, 'body': body})
        if Fixture.mutate: Fixture.mutate()
        if self.path == '/api/chat': payload = {'message': {'role': 'assistant', 'content': Fixture.response}, 'done': True}
        else: payload = {'choices': [{'message': {'role': 'assistant', 'content': Fixture.response}, 'finish_reason': 'stop'}]}
        if Fixture.status != 200: payload = {'error': {'message': 'fixture failure'}}
        data = json.dumps(payload).encode()
        self.send_response(Fixture.status); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()

with tempfile.TemporaryDirectory(prefix='doin-e2e-') as tmp:
    root = pathlib.Path(tmp); storage = root / 'tasks space'; env = os.environ.copy()
    env['DOIN_CONFIG_DIR'] = str(root / 'config'); env['DOIN_API_KEY'] = 'fixture-secret-only'
    def run(*argv, stdin='', ok=True):
        result = subprocess.run([str(binary), *argv], input=stdin, text=True, capture_output=True, env=env, timeout=20)
        records.append({'argv': list(argv), 'stdin': stdin, 'exit': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr})
        assert (result.returncode == 0) == ok, records[-1]
        return result.stdout + result.stderr
    def case(name, fn):
        try: fn(); cases.append({'name': name, 'passed': True})
        except Exception: cases.append({'name': name, 'passed': False, 'failure': traceback.format_exc()})
    taskfile = storage / 'tasks.md'
    def manual():
        run('init', '--storage', str(storage), '--provider', 'manual')
        assert str(taskfile) in run('path')
        original = '# Launch café\n\nBudget: $300. Keep `code`, [links](https://example.org), and notes.\n\n- [ ] Review migration\n- [ ] Dry run restore\n- [x] Capture baseline\n'
        taskfile.write_text(original)
        run('add', 'Ship "café" safely \\ tomorrow')
        assert taskfile.read_text().startswith(original)
        run('done', '2'); assert '- [x] Dry run restore' in taskfile.read_text()
        run('reopen', '2'); assert '- [ ] Dry run restore' in taskfile.read_text()
        before = taskfile.read_bytes(); run('done', '999', ok=False); assert taskfile.read_bytes() == before
        run('note', 'Release note: preserve $HOME and $(whoami) literally.')
        assert '$(whoami)' in taskfile.read_text()
        run('undo'); assert taskfile.read_bytes() == before
        assert 'Review migration' in run('list')
        assert 'fixture-secret-only' not in run('config')
    case('manual workflow preserves realistic externally edited Markdown', manual)
    def ai():
        endpoint = f'http://127.0.0.1:{server.server_port}/v1'
        run('init', '--storage', str(storage), '--provider', 'api', '--model', 'fixture-model', '--endpoint', endpoint)
        before = taskfile.read_bytes(); answer = run('ask', 'Which launch task comes first?')
        assert 'review the migration' in answer and taskfile.read_bytes() == before
        assert 'Review migration' in json.dumps(requests[-1]['body'])
        assert requests[-1]['path'] == '/v1/chat/completions'
        Fixture.response = '## Launch plan\n\n- [ ] Verify café restore\n- [ ] Publish release notes\n'
        run('generate', 'Plan launch', stdin='n\n'); assert taskfile.read_bytes() == before
        run('generate', 'Plan launch', '--yes'); assert 'Verify café restore' in taskfile.read_text()
        run('undo'); assert taskfile.read_bytes() == before
        Fixture.status = 503
        run('generate', 'Plan launch', '--yes', ok=False); assert taskfile.read_bytes() == before
        Fixture.status = 200
        Fixture.mutate = lambda: taskfile.write_bytes(before + b'\nExternal editor added this while AI ran.\n')
        run('generate', 'Plan launch', '--yes', ok=False)
        assert taskfile.read_bytes() == before + b'\nExternal editor added this while AI ran.\n'
        Fixture.mutate = None
        run('init', '--storage', str(storage), '--provider', 'ollama', '--model', 'fixture-local', '--endpoint', f'http://127.0.0.1:{server.server_port}')
        run('ask', 'Summarize'); assert requests[-1]['path'] == '/api/chat'
    case('AI context, read-only questions, preview, failures, concurrent edit, Ollama', ai)
    def validation():
        run('init', '--storage', 'relative-path', '--provider', 'manual', ok=False)
        run('init', '--storage', str(storage), '--provider', 'invented', ok=False)
    case('invalid onboarding settings refused', validation)
    def onboarding():
        isolated = root / 'onboarding-config'; old = env['DOIN_CONFIG_DIR']; env['DOIN_CONFIG_DIR'] = str(isolated)
        try:
            chosen = root / 'onboarding folder'
            output = run(stdin=str(chosen) + '\n\ninvalid\n1\n')
            assert output.index('Where should') < output.index('How would you like to organize your tasks?') < output.index('How would you like your AI?')
            assert '1  Simple' in output
            assert 'Choose a number from 1 to 15' in output
            settings = json.loads((isolated / 'config.json').read_text())
            assert settings['storage'] == str(chosen.resolve()) and settings['provider'] == 'manual'
            assert settings['library_root'] == str(chosen.resolve())
            assert (chosen / '.doin-folder.json').exists()
            run('add', 'Manual onboarding succeeds without AI'); assert 'Manual onboarding succeeds' in run('list')
        finally: env['DOIN_CONFIG_DIR'] = old
    case('first-run storage, default Simple organization, invalid model choice and skip AI', onboarding)
    def markdown_edges():
        run('init', '--storage', str(storage), '--provider', 'manual')
        document = '# Example\n\n```md\n- [ ] Example only\n```\n\n* [ ] Real task\n  - [x] Nested real task\n'
        taskfile.write_text(document)
        output = run('list'); assert 'Example only' not in output and 'Real task' in output
        run('done', '1'); assert '- [ ] Example only' in taskfile.read_text() and '* [x] Real task' in taskfile.read_text()
        external = taskfile.read_text() + '\nOutside edit\n'; taskfile.write_text(external)
        run('undo', ok=False); assert taskfile.read_text() == external
        run('add', 'two\nlines', ok=False); assert taskfile.read_text() == external
        run('init', '--storage', str(storage), '--provider', 'ollama', '--model', 'x', '--endpoint', 'https://example.org', ok=False)
        run('init', '--storage', str(storage), '--provider', 'api', '--model', 'x', '--endpoint', 'http://example.org', ok=False)
    case('Markdown fences, nested tasks, stale undo, local-only endpoint', markdown_edges)
server.shutdown(); server.server_close(); thread.join(timeout=5)
report = {'binary': str(binary), 'sha256': hashlib.sha256(binary.read_bytes()).hexdigest() if binary.exists() else None, 'cases': cases, 'requests': requests, 'commands': records}
(artifacts / 'results.json').write_text(json.dumps(report, indent=2))
(artifacts / 'transcript.md').write_text('# E2E transcript\n\n' + '\n'.join(f"## doin {' '.join(r['argv'])}\n\nExit: {r['exit']}\n\n```text\n{r['stdout']}{r['stderr']}\n```\n" for r in records))
for case in cases: print(('PASS' if case['passed'] else 'FAIL') + ' ' + case['name'])
print(f'Evidence: {artifacts}')
raise SystemExit(0 if all(c['passed'] for c in cases) else 1)
