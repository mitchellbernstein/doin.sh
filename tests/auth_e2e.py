#!/usr/bin/env python3
"""Black-box OAuth/loopback/real RSA verification. Provider dependencies are fixture shims."""
import argparse, base64, hashlib, json, os, pathlib, re, shutil, socket, subprocess, sys, tempfile, time, traceback, urllib.parse


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
        try: fn(); cases.append({'name': name, 'passed': True})
        except Exception: cases.append({'name': name, 'passed': False, 'failure': traceback.format_exc()})

    def login(mode='valid', ok=True, wrong_first=False, client_mismatch=False, argv=('login',), stdin=None, deny=False):
        statefile.write_text(json.dumps({'jwk': jwk, 'mode': mode}))
        urlfile = root / 'browser-url'; urlfile.unlink(missing_ok=True)
        process = subprocess.Popen([str(binary), *argv], env=env, stdin=subprocess.PIPE if stdin is not None else None, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if stdin is not None: process.stdin.write(stdin); process.stdin.flush()
        try:
            limit = time.monotonic() + 10
            while not urlfile.exists():
                if process.poll() is not None: raise AssertionError(process.communicate())
                if time.monotonic() > limit: raise TimeoutError('Browser URL not captured')
                time.sleep(.02)
            auth = urllib.parse.parse_qs(urllib.parse.urlparse(urlfile.read_text()).query)
            assert 'id_token_hint' not in auth
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
            stdout, stderr = process.communicate(timeout=15)
            records.append({'argv': [*argv, mode], 'exit': process.returncode, 'output': redact(stdout + stderr)})
            assert (process.returncode == 0) == ok, records[-1]
        finally:
            if process.poll() is None:
                process.terminate(); process.wait(timeout=5)

    run('init', '--storage', str(root / 'tasks'), '--provider', 'manual')

    def successful_login():
        login(wrong_first=True)
        record = json.loads(credentials.read_text())
        assert record['subject'] == 'fixture-account' and record['client_id'] == 'oaiapp_fixture'
        assert record['scope'].split().count('chatgpt.tokens.use.direct') == 1
        assert credentials.stat().st_mode & 0o777 == 0o600
        assert (root / 'config' / 'host-id').stat().st_mode & 0o777 == 0o600
    case('wrong state rejected; fragmented real callback; RSA JWT accepted; owner-only persistence', successful_login)

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
            login(argv=('init',), stdin=str(root / 'onboarding-tasks') + '\n\n4\nfixture-model\n')
            config = json.loads((root / 'onboarding-config' / 'config.json').read_text())
            assert config['provider'] == 'chatgpt' and config['model'] == 'fixture-model'
            assert config['storage'] == str(root / 'onboarding-tasks')
            assert 'Could not list provider models' in records[-1]['output']
            assert (root / 'onboarding-tasks' / 'tasks.md').exists()
            env['DOIN_CONFIG_DIR'] = str(root / 'denied-onboarding-config')
            login(argv=('init',), stdin=str(root / 'denied-onboarding-tasks') + '\n\n4\n1\n', deny=True)
            denied_config = json.loads((root / 'denied-onboarding-config' / 'config.json').read_text())
            assert denied_config['provider'] == 'manual'
            assert denied_config['storage'] == str(root / 'denied-onboarding-tasks')
            assert 'Account sign-in was cancelled' in records[-1]['output']
            assert not (root / 'denied-onboarding-config' / 'chatgpt.json').exists()
        finally: env['DOIN_CONFIG_DIR'] = saved
    case('onboarding survives catalog outage and cancelled consent with manual fallback', onboarding)

    def catalog_controls():
        saved = env['DOIN_CONFIG_DIR']; env['DOIN_CONFIG_DIR'] = str(root / 'catalog-config')
        try:
            login(mode='catalog_control', argv=('init',), stdin=str(root / 'catalog-tasks') + '\n\n4\nfixture-model\n')
            output = records[-1]['output']
            assert '\x1b' not in output and 'catalog-title' not in output
            assert 'Could not list provider models' in output
            assert '  fixture-model\n' not in output
        finally: env['DOIN_CONFIG_DIR'] = saved
    case('ChatGPT model catalog strips CSI and OSC before terminal output', catalog_controls)

    calls = [json.loads(line) for line in (root / 'calls.jsonl').read_text().splitlines()]
    def secret_arguments():
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
raise SystemExit(0 if all(c['passed'] for c in cases) else 1)
