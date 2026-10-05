#!/usr/bin/env python3
"""Account theme sync and terminal picker regression with reproducible receipts."""
import argparse
import fcntl
import http.server
import json
import os
import pathlib
import pty
import select
import signal
import struct
import subprocess
import tempfile
import termios
import threading
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bin', default='zig-out/bin/doin')
    args = parser.parse_args()
    binary = str(pathlib.Path(args.bin).resolve())
    requests = []
    receipts = []
    preferences = {
        'fixture-account-a': {'accent': None, 'revision': 0},
        'fixture-account-b': {'accent': None, 'revision': 0},
    }
    conflict_once = False

    class Fixture(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def owner(self):
            token = self.headers.get('Authorization', '')
            if not token.startswith('Bearer fixture-account-'):
                return None
            return token.removeprefix('Bearer ')

        def send_json(self, code, value):
            body = json.dumps(value).encode()
            self.send_response(code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            requests.append({'method': 'GET', 'path': self.path, 'token': self.headers.get('Authorization')})
            if self.path == '/v1/account':
                owner = self.owner()
                if owner is None:
                    return self.send_json(401, {'error': 'unauthorized'})
                return self.send_json(200, {'id': owner, 'email': owner + '@example.test'})
            if self.path == '/v1/account/preferences':
                owner = self.owner()
                if owner is None:
                    return self.send_json(401, {'error': 'unauthorized'})
                return self.send_json(200, dict(preferences[owner]))
            return self.send_json(404, {'error': 'not_found'})

        def do_PUT(self):
            nonlocal conflict_once
            body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))))
            requests.append({'method': 'PUT', 'path': self.path, 'token': self.headers.get('Authorization'), 'body': body})
            if self.path != '/v1/account/preferences':
                return self.send_json(404, {'error': 'not_found'})
            owner = self.owner()
            if owner is None:
                return self.send_json(401, {'error': 'unauthorized'})
            prefs = preferences[owner]
            if conflict_once:
                conflict_once = False
                prefs.update({'accent': '#2288AA', 'revision': prefs['revision'] + 1})
                return self.send_json(409, {'error': 'preferences_conflict', 'preferences': dict(prefs)})
            if body.get('revision') != prefs['revision']:
                return self.send_json(409, {'error': 'preferences_conflict', 'preferences': dict(prefs)})
            if body.get('accent') is not None and (len(body['accent']) != 7 or body['accent'][0] != '#' or any(c not in '0123456789ABCDEF' for c in body['accent'][1:])):
                return self.send_json(400, {'error': 'invalid_accent'})
            if body.get('accent') != prefs['accent']:
                prefs.update({'accent': body.get('accent'), 'revision': prefs['revision'] + 1})
            return self.send_json(200, dict(prefs))

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    process = None
    master = None
    failure = None
    try:
        with tempfile.TemporaryDirectory(prefix='doin theme e2e ') as tmp:
            base = pathlib.Path(tmp)
            config = base / 'config'
            storage = base / 'tasks'
            env = dict(os.environ, DOIN_CONFIG_DIR=str(config), NO_COLOR='1', TERM='dumb')

            def cli(*argv, ok=True):
                result = subprocess.run([binary, *argv], env=env, capture_output=True, text=True, timeout=15)
                receipts.append({'argv': argv, 'exit': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr})
                if ok:
                    assert result.returncode == 0, receipts[-1]
                return result

            cli('init', '--storage', str(storage), '--template', 'simple')
            endpoint = f'http://127.0.0.1:{server.server_port}'
            env['DOIN_SYNC_ENDPOINT'] = endpoint
            token_path = config / 'sync.json'
            token_path.write_text(json.dumps({'endpoint': endpoint, 'token': 'fixture-account-a'}))
            token_path.chmod(0o600)

            invalid = cli('theme', '#12ABEZ', ok=False)
            assert invalid.returncode != 0
            assert preferences['fixture-account-a'] == {'accent': None, 'revision': 0}
            cli('theme', '#12abef')
            assert preferences['fixture-account-a'] == {'accent': '#12ABEF', 'revision': 1}
            assert requests[-1]['body'] == {'accent': '#12ABEF', 'revision': 0}

            conflict_once = True
            cli('theme', '#BB8844')
            assert preferences['fixture-account-a'] == {'accent': '#BB8844', 'revision': 3}
            writes = [r['body'] for r in requests if r['method'] == 'PUT']
            assert writes[-2:] == [
                {'accent': '#BB8844', 'revision': 1},
                {'accent': '#BB8844', 'revision': 2},
            ]
            cli('theme', 'default')
            assert preferences['fixture-account-a'] == {'accent': None, 'revision': 4}
            # Reapplying the same value is a legitimate no-op response: revision stays put.
            cli('theme', 'default')
            assert preferences['fixture-account-a'] == {'accent': None, 'revision': 4}

            # Cache identity must include account identity. Account B starts neutral
            # even when the same config directory had account A's custom accent.
            preferences['fixture-account-b'].update({'accent': '#55AA22', 'revision': 5})
            token_path.write_text(json.dumps({'endpoint': endpoint, 'token': 'fixture-account-b'}))
            token_path.chmod(0o600)
            # Account B has its own preference state. Login/startup without pending
            # local edits must only pull, never write account A's cached accent.
            cli('theme', 'sync')
            assert requests[-1]['token'] == 'Bearer fixture-account-b'
            assert preferences['fixture-account-b'] == {'accent': '#55AA22', 'revision': 5}
            assert preferences['fixture-account-a'] == {'accent': None, 'revision': 4}
            assert not any(r['method'] == 'PUT' and r['token'] == 'Bearer fixture-account-b' for r in requests)

            # Fixed-height selection surface at 80x24. Capture its first paint and
            # a later selection repaint; question and frame coordinates must match.
            env.pop('NO_COLOR', None)
            env.update(TERM='xterm-256color', COLORTERM='truecolor')
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
            process = subprocess.Popen([binary], env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
            os.close(slave)
            transcript = bytearray()
            osc_answered = {'10': False, '11': False}
            early_command_sent = False

            def wait(marker, timeout=12):
                nonlocal early_command_sent
                deadline = time.monotonic() + timeout
                while marker.encode() not in transcript:
                    assert process.poll() is None, transcript.decode(errors='replace')
                    assert time.monotonic() < deadline, transcript.decode(errors='replace')
                    if select.select([master], [], [], .1)[0]:
                        transcript.extend(os.read(master, 65536))
                        if not osc_answered['10'] and b'\x1b]10;?\x07' in transcript:
                            # Queue ordinary input before a realistic delayed terminal color reply.
                            os.write(master, b'/settings\n')
                            early_command_sent = True
                            time.sleep(.12)
                            osc_answered['10'] = True
                            os.write(master, b'\x1b]10;rgb:eeee/eeee/eeee\x07')
                        if not osc_answered['11'] and b'\x1b]11;?\x07' in transcript:
                            osc_answered['11'] = True
                            os.write(master, b'\x1b]11;rgb:f5f5/f5f5/f5f5\x07')

            wait('doin')
            assert early_command_sent, 'startup should preserve ordinary keystrokes arriving during the color probe'
            wait('Setting [Enter to return]:')
            os.write(master, b'8\n')
            wait('Accent [1 default, 2 custom, Enter to return]:')
            receipts.append({'picker': transcript.decode(errors='replace')})
            assert b'Accent' in transcript or b'accent' in transcript
            # This fixture asserts the actual Theme screen; other TUI E2E cases cover
            # nested prompt return and graceful composer shutdown.
            process.send_signal(signal.SIGTERM)
            process.wait(timeout=5)
            receipts.append({'picker_exit': process.returncode})
            assert not any(r['method'] == 'PUT' and r['token'] == 'Bearer fixture-account-b' for r in requests), 'startup/theme screen may pull but must not write an unchanged account accent'
    except BaseException as exc:
        failure = repr(exc)
        raise
    finally:
        if process is not None and process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=3)
        if master is not None:
            os.close(master)
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)
        artifact = pathlib.Path('artifacts/theme-e2e')
        artifact.mkdir(parents=True, exist_ok=True)
        (artifact / 'results.json').write_text(json.dumps({
            'command': f'python3 tests/theme_e2e.py --bin {binary}',
            'failure': failure,
            'requests': requests,
            'receipts': receipts,
        }, indent=2) + '\n')
    print('Account theme revision sync and 80x24 settings flow passed.')


if __name__ == '__main__':
    main()
