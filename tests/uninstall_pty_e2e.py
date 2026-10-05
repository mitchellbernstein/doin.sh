#!/usr/bin/env python3
"""Drive uninstall's rich terminal confirmation prompts through a real PTY."""
import argparse
import fcntl
import hashlib
import json
import os
import pathlib
import pty
import re
import select
import shutil
import struct
import subprocess
import tempfile
import termios
import time
import traceback

p = argparse.ArgumentParser()
p.add_argument('--bin', default='zig-out/bin/doin')
p.add_argument('--artifacts', default='artifacts/uninstall-pty-e2e')
args = p.parse_args()
source = pathlib.Path(args.bin).resolve()
artifacts = pathlib.Path(args.artifacts).resolve()
artifacts.mkdir(parents=True, exist_ok=True)
cases = []

ANSI = re.compile(rb'\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\)|.)')
PROMPT_UNINSTALL = b'Uninstall doin and remove its executable and app settings? [y/N]:'
PROMPT_DELETE = b'Delete task folders and ALL their contents? [y/N]:'

def clean_terminal(raw):
    return ANSI.sub(b'', raw).replace(b'\r', b'')

def snapshot(root):
    return {str(f.relative_to(root)): hashlib.sha256(f.read_bytes()).hexdigest()
            for f in root.rglob('*') if f.is_file() and not f.is_symlink()}

def fixture(base, name):
    env_source = dict(os.environ)
    env_source.pop('NO_COLOR', None)
    root = base / name
    home = root / 'home'
    config = root / 'config'
    storage = home / 'Documents' / 'doin'
    storage.mkdir(parents=True)
    (storage / 'tasks.md').write_text('# PTY fixture\n\n- [ ] Keep or delete me\n')
    nested = storage / 'nested'
    nested.mkdir()
    (nested / 'private.txt').write_text('Nested task content.')
    config.mkdir()
    (config / 'config.json').write_text(json.dumps({'storage': str(storage), 'provider': 'manual'}))
    (config / 'unrelated.txt').write_text('Preserve unrelated settings.')
    executable = root / 'bin' / 'doin'
    executable.parent.mkdir()
    shutil.copy2(source, executable)
    env = {**env_source, 'HOME': str(home), 'USERPROFILE': str(home),
           'DOIN_CONFIG_DIR': str(config), 'TERM': 'xterm-256color',
           'DOIN_NO_ANIMATION': '1'}
    return root, storage, config, executable, env

def run_case(base, name, actions, observed):
    root, storage, config, executable, env = fixture(base, name)
    before = snapshot(root)
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 100, 0, 0))
    process = subprocess.Popen([str(executable), 'uninstall'], stdin=slave, stdout=slave,
                               stderr=slave, env=env, start_new_session=True,
                               close_fds=True)
    raw = bytearray()
    sent = set()
    deadline = time.monotonic() + 20
    try:
        while process.poll() is None and time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], 0.15)
            if ready:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                raw.extend(chunk)
                observed['transcript'] = clean_terminal(raw).decode('utf-8', 'replace')
            text = clean_terminal(raw)
            for marker, payload, key in actions:
                if key not in sent and marker in text:
                    ready_deadline = time.monotonic() + 3
                    while True:
                        mode = termios.tcgetattr(slave)
                        if not mode[3] & termios.ICANON and not mode[3] & termios.ECHO:
                            break
                        if time.monotonic() >= ready_deadline:
                            raise AssertionError('Terminal editor did not enter raw mode')
                        time.sleep(0.01)
                    os.write(master, payload)
                    sent.add(key)
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
            observed.update({'exit': process.returncode, 'sent': sorted(sent),
                             'timed_out': True, 'before': before, 'after': snapshot(root)})
            raise AssertionError('PTY scenario timed out; transcript saved in results.json')
        process.wait(timeout=1)
        while True:
            ready, _, _ = select.select([master], [], [], 0.1)
            if not ready:
                break
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            raw.extend(chunk)
    finally:
        os.close(master)
        os.close(slave)
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)

    transcript = clean_terminal(raw).decode('utf-8', 'replace')
    observed.update({'name': name, 'exit': process.returncode, 'sent': sorted(sent),
                     'transcript': transcript, 'before': before, 'after': snapshot(root)})
    assert process.returncode == 0, observed
    assert 'uninstall' in sent, observed
    if name in ('yes-no-keeps', 'yes-yes-deletes', 'blank-keeps', 'ctrl-c-second'):
        assert 'delete' in sent, observed
        assert PROMPT_UNINSTALL.decode() in transcript and PROMPT_DELETE.decode() in transcript, observed
    if name == 'yes-no-keeps':
        assert not executable.exists() and (storage / 'tasks.md').exists(), observed
        assert not (config / 'config.json').exists() and (config / 'unrelated.txt').exists(), observed
    elif name == 'yes-yes-deletes':
        assert not executable.exists() and not storage.exists(), observed
        assert (config / 'unrelated.txt').exists(), observed
    elif name == 'blank-keeps':
        assert not executable.exists() and (storage / 'tasks.md').exists(), observed
    elif name in ('first-no-cancels', 'ctrl-c-second'):
        assert observed['before'] == observed['after'], observed
    return observed

with tempfile.TemporaryDirectory(prefix='doin-uninstall-pty-') as tmp:
    base = pathlib.Path(tmp)
    scenarios = [
        ('yes-no-keeps', [(PROMPT_UNINSTALL, b'y\r', 'uninstall'), (PROMPT_DELETE, b'n\r', 'delete')]),
        ('yes-yes-deletes', [(PROMPT_UNINSTALL, b'y\r', 'uninstall'), (PROMPT_DELETE, b'y\r', 'delete')]),
        ('first-no-cancels', [(PROMPT_UNINSTALL, b'n\r', 'uninstall')]),
        ('ctrl-c-second', [(PROMPT_UNINSTALL, b'y\r', 'uninstall'), (PROMPT_DELETE, b'\x03', 'delete')]),
        ('blank-keeps', [(PROMPT_UNINSTALL, b'y\r', 'uninstall'), (PROMPT_DELETE, b'\r', 'delete')]),
    ]
    for name, actions in scenarios:
        observed = {'name': name, 'transcript': ''}
        try:
            cases.append(run_case(base, name, actions, observed))
        except Exception:
            observed.update({'passed': False, 'failure': traceback.format_exc()})
            cases.append(observed)

for case in cases:
    case['passed'] = 'failure' not in case
report = {'binary': str(source), 'sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
          'cases': cases}
(artifacts / 'results.json').write_text(json.dumps(report, indent=2))
for case in cases:
    print(('PASS ' if case['passed'] else 'FAIL ') + case['name'])
print('Evidence:', artifacts)
raise SystemExit(0 if all(case['passed'] for case in cases) else 1)
