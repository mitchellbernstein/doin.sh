#!/usr/bin/env python3
"""Black-box OAuth/loopback/real RSA verification. Provider dependencies are fixture shims."""
import argparse, base64, fcntl, hashlib, json, os, pathlib, pty, re, select, shutil, socket, struct, subprocess, sys, tempfile, termios, time, traceback, urllib.parse


def b64(data):
    return base64.urlsafe_b64encode(data).decode().rstrip('=')


def shim():
    root = pathlib.Path(os.environ['AUTH_FIXTURE'])
    name = pathlib.Path(sys.argv[0]).name
    with (root / 'calls.jsonl').open('a') as f:
        f.write(json.dumps({'tool': name, 'argv': sys.argv[1:]}) + '\n')
    if name in ('open', 'xdg-open'):
        (root / 'browser-url.tmp').write_text(sys.argv[-1]); (root / 'browser-url.tmp').replace(root / 'browser-url'); return
    if name == 'openssl':
        os.execv(os.environ['AUTH_REAL_OPENSSL'], [os.environ['AUTH_REAL_OPENSSL'], *sys.argv[1:]])
    assert name == 'curl'
    url = sys.argv[-1]
    if '--url' in sys.argv:
        url = sys.argv[sys.argv.index('--url') + 1]
    body = sys.stdin.read() if '@-' in sys.argv or '--config' in sys.argv else ''
    state = json.loads((root / 'fixture.json').read_text())
    if url.endswith('/jwks.json'):
        print(json.dumps({'keys': [state['jwk']]})); return
    if url.endswith('/oauth/revoke'):
        fields = urllib.parse.parse_qs(body)
        assert fields['token_type_hint'] == ['refresh_token']
        (root / 'revoked').write_text('yes'); return
    if url.endswith('/models'):
        if state.get('mode') == 'catalog_control':
            print(json.dumps({'models': [{'visibility': 'list', 'slug': '\x1b[2Jfixture-model\x1b]0;catalog-title\x07'}]})); return
        if state.get('mode') == 'model_order':
            print(json.dumps({'models': [
                {'visibility': 'list', 'slug': 'gpt-6-astra'},
                {'visibility': 'list', 'slug': 'vendor-custom'},
                {'visibility': 'list', 'slug': 'gpt-6-luna'},
                {'visibility': 'list', 'slug': 'gpt-5.6-sol'},
                {'visibility': 'list', 'slug': 'gpt-5.6-luna'},
                {'visibility': 'list', 'slug': 'gpt-5.6-terra'},
                {'visibility': 'hidden', 'slug': 'hidden-luna', 'display_name': 'Hidden',},
            ]})); return
        if state.get('mode') == 'model_astra_only':
            print(json.dumps({'models': [{'visibility': 'list', 'slug': 'gpt-6-astra'}]})); return
        raise SystemExit(22)  # Transient catalog failure after successful consent.
    if url.endswith('/responses'):
        assert 'Bearer fixture-access-rotated' in body or 'Bearer fixture-access-original' in body
        print('data: ' + json.dumps({'type': 'response.output_text.delta', 'delta': 'Fixture answer.'}) + '\n')
        print('data: ' + json.dumps({'type': 'response.completed', 'response': {'status': 'completed', 'output': [{'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'Fixture answer.'}]}]}}) + '\n'); return
    assert url.endswith('/oauth/token'), url
    fields = urllib.parse.parse_qs(body)
    if fields['grant_type'] == ['refresh_token']:
        if state.get('mode') == 'refresh_failure': raise SystemExit(22)
        if state.get('mode') == 'refresh_scope':
            print(json.dumps({'access_token': 'fixture-access-reduced', 'refresh_token': 'fixture-refresh-reduced', 'token_type': 'Bearer', 'expires_in': 3600, 'scope': 'openid profile'})); return
        assert fields['refresh_token'] == ['fixture-refresh-original']
        assert fields['client_id'] == ['oaiapp_fixture']
        assert fields['resource'] == ['https://api.openai.com/v1']
        state['refresh_seen'] = True
        (root / 'fixture.json').write_text(json.dumps(state))
        print(json.dumps({'access_token': 'fixture-access-rotated', 'refresh_token': 'fixture-refresh-rotated', 'token_type': 'Bearer', 'expires_in': 3600})); return
    auth = urllib.parse.parse_qs(urllib.parse.urlparse((root / 'browser-url').read_text()).query)
    assert fields['redirect_uri'] == auth['redirect_uri']
    assert fields['client_id'] == ['oaiapp_fixture']
    assert b64(hashlib.sha256(fields['code_verifier'][0].encode()).digest()) == auth['code_challenge'][0]
    assert fields['code'] == ['fixture-code']
    payload = {'iss': 'https://auth.openai.com', 'aud': 'oaiapp_fixture', 'sub': 'fixture-account', 'email': 'fixture@example.test', 'exp': int(time.time()) + 3600, 'nonce': auth['nonce'][0]}
    mode = state.get('mode', 'valid')
    if mode == 'account': payload['sub'] = 'different-account'
    if mode == 'nonce': payload['nonce'] = 'different-nonce'
    if mode == 'issuer': payload['iss'] = 'https://untrusted.example'
    if mode == 'expired': payload['exp'] = int(time.time()) - 60
    signed = b64(json.dumps({'alg': 'RS256', 'kid': 'fixture-key'}).encode()) + '.' + b64(json.dumps(payload).encode())
    signature = subprocess.run([os.environ['AUTH_REAL_OPENSSL'], 'dgst', '-sha256', '-sign', str(root / 'private.pem')], input=signed.encode(), capture_output=True, check=True).stdout
    if mode == 'signature': signature = bytes([signature[0] ^ 1]) + signature[1:]
    jwt = signed + '.' + b64(signature)
    print(json.dumps({'id_token': jwt, 'access_token': 'fixture-access-original', 'refresh_token': 'fixture-refresh-original', 'scope': 'openid profile email offline_access resource.invoke' + ('' if mode == 'scope' else ' chatgpt.tokens.use.direct'), 'token_type': 'Bearer', 'expires_in': 3600}))


if pathlib.Path(sys.argv[0]).name in ('curl', 'open', 'xdg-open', 'openssl'):
    shim(); raise SystemExit(0)

parser = argparse.ArgumentParser()
parser.add_argument('--bin', default='zig-out/bin/doin')
parser.add_argument('--artifacts', default='artifacts/auth-e2e')
parser.add_argument('--case', help='Run only cases whose name contains this text')
args = parser.parse_args()
binary = pathlib.Path(args.bin).resolve()
artifacts = pathlib.Path(args.artifacts).resolve(); artifacts.mkdir(parents=True, exist_ok=True)
cases, records = [], []
real_openssl = shutil.which('openssl'); assert real_openssl
with tempfile.TemporaryDirectory(prefix='doin-auth-e2e-') as temp:
    root = pathlib.Path(temp).resolve(); bindir = root / 'bin'; bindir.mkdir()
    script = '#!' + sys.executable + '\n' + pathlib.Path(__file__).read_text().split('\n', 1)[1]
    for tool in ('curl', 'open', 'xdg-open', 'openssl'):
        p = bindir / tool; p.write_text(script); p.chmod(0o700)
    env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ['PATH'], DOIN_CONFIG_DIR=str(root / 'config'), AUTH_FIXTURE=str(root), AUTH_REAL_OPENSSL=real_openssl)
    subprocess.run([real_openssl, 'genrsa', '-out', str(root / 'private.pem'), '2048'], check=True, capture_output=True)
    modulus = subprocess.run([real_openssl, 'rsa', '-in', str(root / 'private.pem'), '-noout', '-modulus'], check=True, capture_output=True, text=True).stdout.strip().split('=')[1]
    jwk = {'kty': 'RSA', 'kid': 'fixture-key', 'alg': 'RS256', 'use': 'sig', 'n': b64(bytes.fromhex(modulus)), 'e': 'AQAB'}
    statefile = root / 'fixture.json'; statefile.write_text(json.dumps({'jwk': jwk, 'mode': 'valid'}))
    credentials = root / 'config' / 'chatgpt.json'

    def redact(text):
        for secret in ('fixture-access-original', 'fixture-access-rotated', 'fixture-refresh-original', 'fixture-refresh-rotated'):
            text = text.replace(secret, '[redacted]')
        # Auth URL contains only fresh flow parameters, no retained ID-token hints.
        return re.sub(r"https://auth\.openai\.com/api/accounts/authorize\?[^\s]+", "[authorization URL redacted]", text)

    def run(*argv, ok=True):
        r = subprocess.run([str(binary), *argv], env=env, input='', capture_output=True, text=True, timeout=20)
        records.append({'argv': argv, 'exit': r.returncode, 'output': redact(r.stdout + r.stderr)})
        assert (r.returncode == 0) == ok, records[-1]
        return r

    def case(name, fn):
        if args.case and args.case not in name: return
        try: fn(); cases.append({'name': name, 'passed': True})
        except Exception: cases.append({'name': name, 'passed': False, 'failure': traceback.format_exc()})

    def login(mode='valid', ok=True, wrong_first=False, client_mismatch=False, argv=('login',), stdin=None, deny=False):
        statefile.write_text(json.dumps({'jwk': jwk, 'mode': mode}))
        urlfile = root / 'browser-url'; urlfile.unlink(missing_ok=True)
        stdout_path = root / 'auth-login-stdout.log'; stderr_path = root / 'auth-login-stderr.log'
        with stdout_path.open('w+', encoding='utf-8') as stdout_log, stderr_path.open('w+', encoding='utf-8') as stderr_log:
            process = subprocess.Popen([str(binary), *argv], env=env, stdin=subprocess.PIPE if stdin is not None else None, stdout=stdout_log, stderr=stderr_log, text=True)
            recorded = False

            def captured_output():
                stdout_log.flush(); stderr_log.flush()
                stdout_log.seek(0); stderr_log.seek(0)
                return stdout_log.read(), stderr_log.read()

            if stdin is not None:
                process.stdin.write(stdin); process.stdin.flush(); process.stdin.close(); process.stdin = None
            try:
                limit = time.monotonic() + 10
                while not urlfile.exists():
                    if process.poll() is not None: raise AssertionError(captured_output())
                    if time.monotonic() > limit: raise TimeoutError('Browser URL not captured')
                    time.sleep(.02)
                auth = urllib.parse.parse_qs(urllib.parse.urlparse(urlfile.read_text()).query)
                assert 'id_token_hint' not in auth
                host_id = auth['ext_agent_host_id'][0]
                assert re.fullmatch(r'urn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}', host_id)
                redirect = urllib.parse.urlparse(auth['redirect_uri'][0])
                assert redirect.hostname == '127.0.0.1' and redirect.path == '/auth/callback'
                def callback(state, fragmented=False):
                    query = urllib.parse.urlencode({'state': state, **({'error': 'access_denied'} if deny else {'code': 'fixture-code', 'client_id': 'wrong-client' if client_mismatch else 'oaiapp_fixture'})})
                    data = f'GET /auth/callback?{query} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n'.encode()
                    with socket.create_connection(('127.0.0.1', redirect.port), timeout=5) as sock:
                        if fragmented:
                            sock.sendall(data[:15]); time.sleep(.05); sock.sendall(data[15:])
                        else: sock.sendall(data)
                        return sock.recv(4096)
                if wrong_first:
                    busy = run('logout', ok=False)
                    assert 'Another account sign-in or refresh is active' in busy.stdout + busy.stderr
                    assert b'400 Bad Request' in callback('wrong-state')
                callback(auth['state'][0], fragmented=True)
                process.wait(timeout=15)
                stdout, stderr = captured_output()
                records.append({'argv': [*argv, mode], 'exit': process.returncode, 'output': redact(stdout + stderr)})
                recorded = True
                assert (process.returncode == 0) == ok, records[-1]
            finally:
                if process.poll() is None:
                    process.terminate(); process.wait(timeout=5)
                if not recorded:
                    stdout, stderr = captured_output()
                    records.append({'argv': [*argv, mode], 'exit': process.returncode, 'output': redact(stdout + stderr)})

    run('init', '--storage', str(root / 'tasks'), '--provider', 'manual')

    def successful_login():
        login(wrong_first=True)
        record = json.loads(credentials.read_text())
        assert record['subject'] == 'fixture-account' and record['client_id'] == 'oaiapp_fixture'
        assert re.fullmatch(r'urn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}', record['ext_agent_host_id'])
        assert record['scope'].split().count('chatgpt.tokens.use.direct') == 1
        assert credentials.stat().st_mode & 0o777 == 0o600
        assert (root / 'config' / 'host-id').stat().st_mode & 0o777 == 0o600
        host_file = root / 'config' / 'host-id'
        initial_host = record['ext_agent_host_id']
        assert host_file.read_text() == initial_host
        legacy_host = 'a' * 43
        host_file.write_text(legacy_host)
        record['ext_agent_host_id'] = legacy_host
        credentials.write_text(json.dumps(record))
        login()
        migrated = json.loads(credentials.read_text())
        assert migrated['client_id'] == 'oaiapp_fixture' and migrated['subject'] == 'fixture-account'
        migrated_host = migrated['ext_agent_host_id']
        assert migrated_host != initial_host and host_file.read_text() == migrated_host
        login()
        assert json.loads(credentials.read_text())['ext_agent_host_id'] == migrated_host
    case('supported stable UUID host ID; legacy host migration retains registration; wrong state rejected; fragmented callback and RSA JWT accepted', successful_login)

    def rejected_identity():
        original = credentials.read_bytes()
        for mode in ('account', 'nonce', 'issuer', 'expired', 'signature', 'scope'):
            login(mode, ok=False)
            assert credentials.read_bytes() == original
        login(ok=False, client_mismatch=True)
        assert credentials.read_bytes() == original
        login(ok=False, deny=True)
        assert credentials.read_bytes() == original
    case('account nonce issuer expiry signature scope and client failures preserve credentials', rejected_identity)

    def failed_refresh():
        run('init', '--storage', str(root / 'tasks'), '--provider', 'chatgpt', '--model', 'fixture-model')
        record = json.loads(credentials.read_text()); record['expires_at'] = 0
        credentials.write_text(json.dumps(record)); original = credentials.read_bytes()
        markdown = (root / 'tasks' / 'tasks.md').read_bytes()
        for mode, message in (('refresh_failure', 'Could not renew ChatGPT access'), ('refresh_scope', 'ChatGPT plan permission is missing')):
            statefile.write_text(json.dumps({'jwk': jwk, 'mode': mode}))
            result = run('ask', 'What should I do?', ok=False)
            assert message in result.stderr
            assert credentials.read_bytes() == original
            assert (root / 'tasks' / 'tasks.md').read_bytes() == markdown
        statefile.write_text(json.dumps({'jwk': jwk, 'mode': 'valid'}))
    case('failed refresh and reduced permissions explain recovery and preserve credentials/document', failed_refresh)

    def refresh():
        record = json.loads(credentials.read_text()); record['expires_at'] = 0
        credentials.write_text(json.dumps(record))
        run('init', '--storage', str(root / 'tasks'), '--provider', 'chatgpt', '--model', 'fixture-model')
        answer = run('ask', 'What should I do?')
        assert 'Fixture answer.' in answer.stdout
        record = json.loads(credentials.read_text())
        assert record['access_token'] == 'fixture-access-rotated' and record['refresh_token'] == 'fixture-refresh-rotated'
        assert json.loads(statefile.read_text())['refresh_seen']
        assert credentials.stat().st_mode & 0o777 == 0o600
    case('expired access token refresh rotates credentials then real CLI consumes Responses SSE', refresh)

    def logout():
        host = (root / 'config' / 'host-id').read_bytes()
        run('logout')
        assert not credentials.exists() and (root / 'revoked').exists()
        missing = run('ask', 'What next?', ok=False)
        assert 'ChatGPT is signed out. Run login' in missing.stderr
        assert (root / 'config' / 'host-id').read_bytes() == host
        mapping = json.loads((root / 'config' / 'chatgpt-registration.json').read_text())
        assert mapping['client_id'] == 'oaiapp_fixture' and 'id_token' not in mapping
        login()
        assert credentials.exists()
    case('logout revokes renewable session and reauthorization retains registration host identity', logout)

    def onboarding():
        saved = env['DOIN_CONFIG_DIR']
        env['DOIN_CONFIG_DIR'] = str(root / 'onboarding-config')
        try:
            login(argv=('init',), stdin=str(root / 'onboarding-tasks') + '\n\n\n1\nfixture-model\n')
            config = json.loads((root / 'onboarding-config' / 'config.json').read_text())
            assert config['provider'] == 'chatgpt' and config['model'] == 'fixture-model'
            assert config['storage'] == str(root / 'onboarding-tasks')
            assert 'Could not list provider models' in records[-1]['output']
            assert (root / 'onboarding-tasks' / 'tasks.md').exists()
            env['DOIN_CONFIG_DIR'] = str(root / 'denied-onboarding-config')
            login(argv=('init',), stdin=str(root / 'denied-onboarding-tasks') + '\n\n\n1\n4\n1\n', deny=True)
            denied_config = json.loads((root / 'denied-onboarding-config' / 'config.json').read_text())
            assert denied_config['provider'] == 'manual'
            assert denied_config['storage'] == str(root / 'denied-onboarding-tasks')
            assert 'Account sign-in was cancelled' in records[-1]['output']
            assert not (root / 'denied-onboarding-config' / 'chatgpt.json').exists()
        finally: env['DOIN_CONFIG_DIR'] = saved
    case('onboarding survives catalog outage and cancelled consent with manual fallback', onboarding)

    def lighter_default():
        saved = env['DOIN_CONFIG_DIR']; env['DOIN_CONFIG_DIR'] = str(root / 'lighter-config')
        try:
            login(mode='model_order', argv=('init',), stdin=str(root / 'lighter-tasks') + '\n\n\n1\n\n')
            config = json.loads((root / 'lighter-config' / 'config.json').read_text())
            assert config['provider'] == 'chatgpt' and config['model'] == 'gpt-6-luna'
            output = records[-1]['output']
            ordered = ['gpt-6-luna', 'gpt-5.6-luna', 'gpt-5.6-terra', 'gpt-5.6-sol', 'gpt-6-astra', 'vendor-custom']
            assert [output.index(model) for model in ordered] == sorted(output.index(model) for model in ordered)
            assert 'hidden-luna' not in output
        finally: env['DOIN_CONFIG_DIR'] = saved
    case('new ChatGPT setup defaults to an advertised Luna and excludes hidden catalog models', lighter_default)

    def onboarding_model_picker():
        saved = env['DOIN_CONFIG_DIR']; config_dir = root / 'model-picker-config'; env['DOIN_CONFIG_DIR'] = str(config_dir)
        try:
            subprocess.run([str(binary), 'init', '--storage', str(root / 'model-picker-tasks'), '--provider', 'manual'], env=env, check=True, capture_output=True, text=True)
            login(mode='model_order')
            before = (config_dir / 'config.json').read_bytes()
            pty_env = dict(env, TERM='xterm-256color', COLORTERM='truecolor')
            pty_env.pop('NO_COLOR', None)
            master, slave = pty.openpty(); fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 28, 88, 0, 0))
            process = subprocess.Popen([str(binary), 'provider'], env=pty_env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
            os.close(slave); raw = bytearray(); phases = []

            def pump(duration=.08):
                deadline = time.monotonic() + duration
                while time.monotonic() < deadline:
                    if select.select([master], [], [], min(.02, max(0, deadline - time.monotonic())))[0]:
                        try: chunk = os.read(master, 65536)
                        except OSError: break
                        if not chunk: break
                        raw.extend(chunk)

            def wait_for(marker, offset=0, timeout=8):
                deadline = time.monotonic() + timeout
                while marker.encode() not in raw[offset:]:
                    pump()
                    if process.poll() is not None or time.monotonic() >= deadline:
                        raise AssertionError(f'Missing {marker!r}; exit={process.poll()}; tail={bytes(raw[-1800:])!r}')

            try:
                wait_for('AI provider')
                model_screen = len(raw)
                os.write(master, b'\r')
                wait_for('Choose a model', model_screen)
                wait_for('gpt-6-luna', model_screen)
                wait_for('Esc back', model_screen)
                pump(.1)
                excerpt = bytes(raw[model_screen:]).decode('utf-8', 'replace')
                plain_excerpt = re.sub(r'\x1b\].*?(?:\x07|\x1b\\)', '', excerpt, flags=re.S)
                plain_excerpt = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', plain_excerpt)
                assert 'hidden-luna' not in plain_excerpt and 'gpt-6-luna' in plain_excerpt
                assert '╭' in plain_excerpt and '╰' in plain_excerpt and '› 1  gpt-6-luna' in plain_excerpt, 'Model picker frame or weakest-model selection missing'
                pump(.1)
                phases.append({'name': 'model-picker', 'startOffset': model_screen, 'endOffset': len(raw), 'expectedSelected': 'gpt-6-luna'})
                os.write(master, b'\x1b'); offset = len(raw)
                wait_for('AI provider', offset)
                assert (config_dir / 'config.json').read_bytes() == before, 'Escape committed provider/model before selection'
                phases.append({'name': 'escape-returned-to-provider', 'offset': offset})
                os.write(master, b'\r')
                wait_for('Choose a model', offset)
                os.write(master, b'\r')
                process.wait(timeout=10); pump(.1)
                assert process.returncode == 0, bytes(raw[-1800:])
                config = json.loads((config_dir / 'config.json').read_text())
                assert config['provider'] == 'chatgpt' and config['model'] == 'gpt-6-luna', config
                phases.append({'name': 'accepted', 'provider': config['provider'], 'model': config['model']})
            finally:
                if process.poll() is None: process.terminate(); process.wait(timeout=5)
                os.close(master)
                (artifacts / 'onboarding-model-picker.ansi').write_bytes(raw)
                (artifacts / 'onboarding-model-picker.json').write_text(json.dumps({'cols': 88, 'rows': 28, 'phases': phases, 'ansiArtifact': 'onboarding-model-picker.ansi'}, indent=2) + '\n')
        finally: env['DOIN_CONFIG_DIR'] = saved
    case('ChatGPT onboarding model picker is framed, Escape returns without saving, and weakest listed Luna is accepted', onboarding_model_picker)

    def no_luna_default():
        saved = env['DOIN_CONFIG_DIR']; env['DOIN_CONFIG_DIR'] = str(root / 'astra-only-config')
        try:
            login(mode='model_astra_only', argv=('init',), stdin=str(root / 'astra-only-tasks') + '\n\n\n1\ngpt-6-astra\n')
            config = json.loads((root / 'astra-only-config' / 'config.json').read_text())
            assert config['model'] == 'gpt-6-astra'
            assert 'Model []:' in records[-1]['output']
            run('provider', 'chatgpt', '--model', 'gpt-6-astra')
            statefile.write_text(json.dumps({'jwk': jwk, 'mode': 'model_astra_only'}))
            repeated = subprocess.run([str(binary), 'provider'], env=env, input='1\n\n', capture_output=True, text=True, timeout=20)
            assert repeated.returncode == 0, repeated.stdout + repeated.stderr
            assert 'Model [gpt-6-astra]:' in repeated.stdout + repeated.stderr
            assert json.loads((root / 'astra-only-config' / 'config.json').read_text())['model'] == 'gpt-6-astra'
        finally: env['DOIN_CONFIG_DIR'] = saved
    case('Astra-only ChatGPT catalog leaves the model prompt blank and accepts explicit Astra', no_luna_default)

    def catalog_controls():
        saved = env['DOIN_CONFIG_DIR']; env['DOIN_CONFIG_DIR'] = str(root / 'catalog-config')
        try:
            login(mode='catalog_control', argv=('init',), stdin=str(root / 'catalog-tasks') + '\n\n\n1\nfixture-model\n')
            output = records[-1]['output']
            assert '\x1b' not in output and 'catalog-title' not in output
            assert 'Could not list provider models' in output
            assert '  fixture-model\n' not in output
        finally: env['DOIN_CONFIG_DIR'] = saved
    case('ChatGPT model catalog strips CSI and OSC before terminal output', catalog_controls)

    calls_file = root / 'calls.jsonl'
    calls = [json.loads(line) for line in calls_file.read_text().splitlines()] if calls_file.exists() else []
    def secret_arguments():
        assert calls_file.exists(), 'dependency call log missing'
        argv = json.dumps(calls)
        for secret in ('fixture-access-original', 'fixture-access-rotated', 'fixture-refresh-original', 'fixture-refresh-rotated'):
            assert secret not in argv
        assert not list((root / 'config').glob('*.tmp'))
        assert not list((root / 'config').glob('.verify-*'))
    case('secrets absent from subprocess argv and verification temporary files cleaned', secret_arguments)
    # Omit browser OAuth query strings from portable artifacts.
    for call in calls:
        if call['tool'] in ('open', 'xdg-open'): call['argv'] = ['[authorization URL redacted]']
    report = {'binary': str(binary), 'sha256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'cases': cases, 'commands': records, 'dependency_calls': calls}
    (artifacts / 'results.json').write_text(json.dumps(report, indent=2))
    (artifacts / 'transcript.md').write_text('# Authentication E2E\n\n' + '\n'.join(f"## {' '.join(r['argv'])}\n\nExit: {r['exit']}\n\n```text\n{r['output']}\n```\n" for r in records))
for c in cases: print(('PASS ' if c['passed'] else 'FAIL ') + c['name'])
print(f'Evidence: {artifacts}')
if args.case and not cases: raise SystemExit(f'No auth E2E case matched {args.case!r}')
raise SystemExit(0 if all(c['passed'] for c in cases) else 1)
