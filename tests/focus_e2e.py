#!/usr/bin/env python3
"""Real CLI and PTY coverage for the one-task daily focus workflow.

Failure census: stale/missing/duplicate identity, edits and reordering after
selection, completed/fenced/nested tasks, invalid indices, picker cancellation,
date rollover and timezone boundaries, separate storage folders, undo, literal
manual next steps, terminal resize/restart, and accidental Markdown changes.
The fixture clock is explicit; no AI provider, HTTP service, or network is used.
"""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
import pathlib
import pty
import re
import select
import signal
import struct
import subprocess
import tempfile
import termios
import time
import traceback
from zoneinfo import ZoneInfo


parser = argparse.ArgumentParser()
parser.add_argument('--bin', default='zig-out/bin/doin')
parser.add_argument('--artifacts', default='artifacts/focus-e2e')
args = parser.parse_args()
binary = pathlib.Path(args.bin).resolve()
artifacts = pathlib.Path(args.artifacts).resolve()
artifacts.mkdir(parents=True, exist_ok=True)
records, cases, captures, active = [], [], [], []
local_zone = ZoneInfo('America/Chicago')
fixture_start = int(datetime.datetime(2026, 10, 4, 23, 50, tzinfo=local_zone).timestamp())
fixture_next_day = int(datetime.datetime(2026, 10, 5, 0, 1, tzinfo=local_zone).timestamp())


class Terminal:
    def __init__(self, env, cols=84, rows=26):
        self.cols, self.rows = cols, rows
        self.raw = bytearray()
        self.master, self.slave = pty.openpty()
        self.original = termios.tcgetattr(self.slave)
        self.resize(cols, rows)
        self.process = subprocess.Popen(
            [str(binary)], env=env, stdin=self.slave, stdout=self.slave,
            stderr=self.slave, start_new_session=True,
        )

    def resize(self, cols, rows):
        self.cols, self.rows = cols, rows
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))

    def pump(self, duration=.08):
        deadline = time.monotonic() + duration
        while time.monotonic() < deadline:
            if select.select([self.master], [], [], min(.02, max(0, deadline - time.monotonic())))[0]:
                try:
                    data = os.read(self.master, 65536)
                except OSError:
                    break
                if not data:
                    break
                self.raw.extend(data)

    def wait(self, marker, offset=0, timeout=8):
        deadline = time.monotonic() + timeout
        while marker.encode() not in self.raw[offset:]:
            self.pump()
            if self.process.poll() is not None or time.monotonic() >= deadline:
                raise AssertionError(f'Missing {marker!r}; exit={self.process.poll()}; tail={bytes(self.raw[-2500:])!r}')

    def send(self, value):
        os.write(self.master, value.encode() if isinstance(value, str) else value)
        self.pump()

    def ready(self):
        deadline = time.monotonic() + 5
        while True:
            attrs = termios.tcgetattr(self.slave)
            if not attrs[3] & termios.ICANON and not attrs[3] & termios.ECHO:
                break
            self.pump()
            assert self.process.poll() is None and time.monotonic() < deadline, 'Composer did not enter raw mode'
        self.pump()

    def capture(self, name):
        self.pump()
        raw = bytes(self.raw)
        (artifacts / f'{name}.ansi').write_bytes(raw)
        text = raw.decode('utf-8', errors='replace')
        text = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', text)
        text = re.sub(r'\x1b\][^\x07]*(?:\x07|\x1b\\)', '', text)
        text = text.replace('\r', '')
        (artifacts / f'{name}.txt').write_text(text)
        captures.append({'name': name, 'ansi': f'{name}.ansi', 'text': f'{name}.txt', 'columns': self.cols, 'rows': self.rows})
        return text

    def finish(self):
        if self.process.poll() is None:
            self.send('/quit\r')
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGTERM)
                try:
                    self.process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(self.process.pid, signal.SIGKILL)
                    self.process.wait()
        after = termios.tcgetattr(self.slave)
        before_flags, after_flags = list(self.original), list(after)
        pending = getattr(termios, 'PENDIN', 0)
        before_flags[3] &= ~pending
        after_flags[3] &= ~pending
        assert after_flags == before_flags, ('Terminal state was not restored', before_flags, after_flags)
        assert b'\x1b[3J' not in self.raw, 'Terminal scrollback was erased'

    def close(self):
        if self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGTERM)
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait()
        os.close(self.master)
        os.close(self.slave)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def case(name, fn):
    try:
        fn()
        cases.append({'name': name, 'passed': True})
    except Exception:
        cases.append({'name': name, 'passed': False, 'failure': traceback.format_exc()})


def main():
    with tempfile.TemporaryDirectory(prefix='doin-focus-e2e-') as temporary:
        root = pathlib.Path(temporary).resolve()
        storage = root / 'Release café tasks'
        other_storage = root / 'Home tasks'
        config = root / 'private config'
        env = dict(os.environ, DOIN_CONFIG_DIR=str(config), DOIN_REMINDER_NOW=str(fixture_start), TZ='America/Chicago', TERM='xterm-256color', DOIN_NO_ANIMATION='1')
        env.pop('DOIN_API_KEY', None)
        env.pop('NO_COLOR', None)
        taskfile = storage / 'tasks.md'
        stable = {
            'review': '11111111111111111111111111111111',
            'backup': '22222222222222222222222222222222',
            'baseline': '33333333333333333333333333333333',
            'groceries': '44444444444444444444444444444444',
        }
        original = (
            '# Release café\n\n'
            '## Today\n\n'
            f'- [ ] Review migration with the operations team <!-- doin:task={"a" * 32} --> <!-- doin:values={{"owner":"Mina"}} --> <!-- doin:id={stable["review"]} remind=1893456000 -->\n'
            '  - Context note: keep the source map intact.\n'
            f'* [ ] Verify 東京 backup 🚀 <!-- doin:task={"b" * 32} --> <!-- doin:id={stable["backup"]} -->\n'
            f'- [x] Capture baseline <!-- doin:task={"c" * 32} --> <!-- doin:id={stable["baseline"]} -->\n\n'
            '```markdown\n- [ ] Example only; fenced tasks are not real work\n```\n\n'
            '## Home\n\n'
            f'- [ ] Buy groceries <!-- doin:task={"d" * 32} --> <!-- doin:id={stable["groceries"]} -->\n'
            '\nBudget: $300. Keep [the launch note](https://example.org) and this prose.\n'
        )

        def run(*argv, stdin='', ok=True, env_override=None):
            child_env = env if env_override is None else env_override
            result = subprocess.run([str(binary), *argv], env=child_env, input=stdin, text=True, capture_output=True, timeout=15)
            record = {'argv': list(argv), 'exit': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr}
            records.append(record)
            if ok is not None:
                assert (result.returncode == 0) == ok, record
            return result.stdout + result.stderr

        def init(target):
            subprocess.run([str(binary), 'init', '--storage', str(target), '--provider', 'manual'], env=env, check=True, capture_output=True, timeout=15)

        init(storage)
        taskfile.write_text(original)

        def selected_identity_file(target):
            key = hashlib.sha256(str(target.resolve()).encode()).hexdigest()[:16]
            path = config / f'focus-{key}.json'
            assert path.exists(), f'Missing per-folder focus state: {path.name}'
            return path

        def identity_follow_and_done():
            env['DOIN_REMINDER_NOW'] = str(fixture_start)
            init(storage)
            taskfile.write_text(original)
            before = taskfile.read_bytes()
            output = run('focus', '2')
            assert 'Verify 東京 backup' in output
            assert taskfile.read_bytes() == before
            state_file = selected_identity_file(storage)
            assert state_file.stat().st_mode & 0o777 == 0o600
            focus_status = run('focus', 'status')
            assert 'Verify 東京 backup' in focus_status
            assert 'Review migration' not in focus_status and 'Buy groceries' not in focus_status

            state_before_invalid = state_file.read_bytes()
            markdown_before_invalid = taskfile.read_bytes()
            run('focus', '999', ok=False)
            assert state_file.read_bytes() == state_before_invalid and taskfile.read_bytes() == markdown_before_invalid
            run('focus', '0', ok=False)
            assert state_file.read_bytes() == state_before_invalid and taskfile.read_bytes() == markdown_before_invalid

            # Now track the first task through an external reorder and title edit.
            selected_review = run('focus', '1')
            assert 'Review migration with the operations team' in selected_review

            # External editor reorders tasks and changes the selected title.
            current = taskfile.read_text()
            review_line = next(line for line in current.splitlines() if 'Review migration' in line)
            backup_line = next(line for line in current.splitlines() if 'Verify 東京 backup' in line)
            grocery_line = next(line for line in current.splitlines() if 'Buy groceries' in line)
            rewritten = current.replace(review_line + '\n', '').replace(backup_line + '\n', '').replace(grocery_line + '\n', '')
            rewritten = rewritten.replace('## Home\n\n', '## Home\n\n' + grocery_line + '\n')
            rewritten = rewritten.replace('## Today\n\n', '## Today\n\n' + review_line.replace('Review migration with the operations team', 'Review migration after the release review') + '\n' + backup_line + '\n')
            taskfile.write_text(rewritten)
            after_external_edit = taskfile.read_bytes()
            assert 'Review migration after the release review' in run('focus', 'status')
            assert 'Buy groceries' not in run('focus', 'status')

            literal_step = 'finish the archival script with café and 東京'
            step_output = run('focus', 'step', literal_step)
            assert literal_step in step_output
            status = run('focus', 'status')
            assert literal_step in status and 'Review migration after the release review' in status
            assert taskfile.read_bytes() == after_external_edit

            # Each CLI call is a process restart; identity still resolves after another status read.
            assert 'Review migration after the release review' in run('focus', 'status')
            before_done = taskfile.read_bytes()
            run('focus', 'done')
            after_done = taskfile.read_bytes()
            expected_done = before_done.replace(
                b'- [ ] Review migration after the release review',
                b'- [x] Review migration after the release review', 1,
            )
            assert after_done == expected_done, 'focus done changed more than the selected Markdown checkbox'
            completed_status = run('focus', 'status')
            assert "You finished today's focus" in completed_status
            assert '[x]' in completed_status and 'Review migration after the release review' in completed_status
            assert 'Verify 東京 backup' not in completed_status and 'Buy groceries' not in completed_status
            run('undo')
            assert taskfile.read_bytes() == before_done, 'Undo did not restore the exact pre-completion Markdown'
            records.append({'artifact': 'identity-follow-receipt', 'before_sha256': sha(before), 'after_external_edit_sha256': sha(after_external_edit), 'after_done_sha256': sha(after_done), 'undo_sha256': sha(taskfile.read_bytes())})

        case('stable identity follows external reorder/title edits across CLI restarts; literal step and selected-only done/undo', identity_follow_and_done)

        def missing_or_duplicate_id_refuses_wrong_completion():
            nonlocal taskfile
            env['DOIN_REMINDER_NOW'] = str(fixture_start)
            target = root / 'Identity safety'
            init(target)
            isolated_file = target / 'tasks.md'
            first_id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            second_id = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
            original_safety = f'- [ ] First target <!-- doin:id={first_id} -->\n- [ ] Second target <!-- doin:id={second_id} -->\n'
            isolated_file.write_text(original_safety)
            run('focus', '1')
            missing = isolated_file.read_text().replace(f' <!-- doin:id={first_id} -->', '')
            isolated_file.write_text(missing)
            before = isolated_file.read_bytes()
            run('focus', 'done', ok=None)
            assert isolated_file.read_bytes() == before and '- [ ] First target' in before.decode()

            isolated_file.write_text(original_safety)
            run('focus', '1')
            duplicate = isolated_file.read_text().replace(f'<!-- doin:id={second_id} -->', f'<!-- doin:id={first_id} -->')
            isolated_file.write_text(duplicate)
            before = isolated_file.read_bytes()
            run('focus', 'done', ok=None)
            assert isolated_file.read_bytes() == before and before.count(b'- [ ]') == 2
            records.append({'artifact': 'identity-safety-receipt', 'missing_sha256': sha(missing.encode()), 'duplicate_sha256': sha(duplicate.encode())})

        case('missing or duplicate selected identity never completes another task', missing_or_duplicate_id_refuses_wrong_completion)

        def corrupt_state_and_noop_selection_safety():
            env['DOIN_REMINDER_NOW'] = str(fixture_start)
            target = root / 'Focus state recovery'
            init(target)
            isolated_file = target / 'tasks.md'
            stable_id = 'cccccccccccccccccccccccccccccccc'
            original_recovery = f'- [ ] Preserve recovery note <!-- doin:id={stable_id} -->\n'
            isolated_file.write_text(original_recovery)

            # Choosing an already identified task is a Markdown no-op. It must
            # preserve the undo checkpoint created by the preceding task add.
            run('add', 'Temporary follow-up')
            with_added_task = isolated_file.read_bytes()
            assert b'Temporary follow-up' in with_added_task
            run('focus', '1')
            assert isolated_file.read_bytes() == with_added_task
            run('undo')
            assert isolated_file.read_text() == original_recovery, 'No-op focus selection replaced the prior undo checkpoint'

            # Malformed device state must not block ordinary Markdown access or
            # let focus done guess a task. Explicit off remains a recovery path.
            run('focus', '1')
            state_file = selected_identity_file(target)
            corrupt = b'{"date":'
            state_file.write_bytes(corrupt)
            before_corrupt_ops = isolated_file.read_bytes()
            listing = run('list')
            assert 'Preserve recovery note' in listing
            run('focus', 'done', ok=None)
            assert isolated_file.read_bytes() == before_corrupt_ops
            run('focus', 'off')
            assert not state_file.exists()
            assert 'No focus saved today' in run('focus', 'status')
            assert isolated_file.read_bytes() == before_corrupt_ops
            records.append({'artifact': 'focus-recovery-receipt', 'before_sha256': sha(before_corrupt_ops), 'corrupt_state_sha256': sha(corrupt), 'after_sha256': sha(isolated_file.read_bytes())})

        case('no-op existing-ID selection preserves undo; corrupt focus state leaves Markdown usable and off recovers', corrupt_state_and_noop_selection_safety)

        def per_folder_and_daily_expiry():
            nonlocal taskfile
            # The stored date is the local fixture date, and rollover expires the focus.
            env['DOIN_REMINDER_NOW'] = str(fixture_start)
            init(storage)
            taskfile.write_text(original)
            run('focus', '1')
            primary_state = selected_identity_file(storage)
            primary_json = json.loads(primary_state.read_text())
            assert '2026-10-04' in json.dumps(primary_json), 'Focus state did not use the fixture local date'
            env['DOIN_REMINDER_NOW'] = str(fixture_next_day)
            expired = run('focus', 'status')
            assert 'No active focus' in expired or 'expired' in expired.lower()
            assert taskfile.read_text() == original, 'Daily expiry changed task Markdown'

            init(other_storage)
            other_file = other_storage / 'tasks.md'
            other_file.write_text('- [ ] Home task with a different folder identity\n')
            run('focus', '1')
            other_after_selection = other_file.read_bytes()
            other_state = selected_identity_file(other_storage)
            assert other_state != primary_state
            assert 'Home task' in run('focus', 'status')
            init(storage)
            env['DOIN_REMINDER_NOW'] = str(fixture_next_day)
            expired_again = run('focus', 'status')
            assert 'No active focus' in expired_again or 'expired' in expired_again.lower()
            assert other_file.read_bytes() == other_after_selection
            env['DOIN_REMINDER_NOW'] = str(fixture_start)
            init(other_storage)
            backward_clock_status = run('focus', 'status')
            assert 'expired' in backward_clock_status.lower()
            assert other_file.read_bytes() == other_after_selection
            env['DOIN_REMINDER_NOW'] = str(fixture_next_day)
            assert 'Home task' in run('focus', 'status')
            assert other_file.read_bytes() == other_after_selection
            init(storage)

        case('focus expires at next local day and each storage folder has separate private state', per_folder_and_daily_expiry)

        def picker_tui_lifecycle():
            nonlocal taskfile
            env['DOIN_REMINDER_NOW'] = str(fixture_start)
            init(storage)
            taskfile.write_text(original)
            run('focus', '1')
            # Start in the terminal with no arguments, matching the user's real entry point.
            terminal = Terminal(env)
            active.append(terminal)
            try:
                terminal.wait('Focus for today')
                terminal.ready()
                before_cancel = taskfile.read_bytes()
                state_path = selected_identity_file(storage)
                state_before_picker = state_path.read_bytes()
                terminal.send('/focus pick\r')
                terminal.wait('Focus on one task today')
                terminal.ready()
                picker = terminal.capture('focus-picker-open')
                assert 'Review migration' in picker and 'Verify 東京 backup' in picker
                assert 'Capture baseline' not in picker and 'Example only' not in picker
                terminal.send(b'\x1b')
                terminal.wait('Cancelled. Focus unchanged.')
                terminal.ready()
                assert taskfile.read_bytes() == before_cancel
                assert state_path.read_bytes() == state_before_picker
                state_before_cancel = state_path.read_bytes()

                terminal.send('/focus pick\r')
                terminal.wait('Focus on one task today')
                terminal.ready()
                terminal.send(b'\x1b[B')
                terminal.capture('focus-picker-selected-before-resize')
                terminal.resize(48, 16)
                terminal.pump(.3)
                resized_picker = terminal.capture('focus-picker-resized')
                assert 'Focus on one task today' in resized_picker
                terminal.send(b'\x1b[B\r')
                terminal.pump(.2)
                terminal.ready()
                selected = terminal.capture('focus-picker-selected')
                assert 'Buy groceries' in selected or 'Focus' in selected
                assert 'Buy groceries' in run('focus', 'status')
                assert 'Review migration' not in run('focus', 'status')
                assert state_path.read_bytes() != state_before_cancel

                offset = len(terminal.raw)
                terminal.send('/focus status\r')
                terminal.wait('Buy groceries', offset)
                terminal.ready()
                terminal.capture('focus-status-after-picker')
                terminal.finish()
            finally:
                terminal.close()
                active.remove(terminal)

            # A new PTY process must recover the same focus; then off preserves Markdown.
            terminal = Terminal(env, cols=74, rows=22)
            active.append(terminal)
            try:
                terminal.wait('Focus for today')
                terminal.ready()
                offset = len(terminal.raw)
                terminal.send('/focus status\r')
                terminal.wait('Buy groceries', offset)
                terminal.ready()
                terminal.capture('focus-status-after-terminal-restart')
                before_off = taskfile.read_bytes()
                offset = len(terminal.raw)
                terminal.send('/focus off\r')
                terminal.wait('Focus cleared. Markdown kept.', offset)
                terminal.pump(.2)
                terminal.ready()
                off_screen = terminal.capture('focus-off')
                off_tail = bytes(terminal.raw[offset:]).decode('utf-8', errors='replace')
                off_tail = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', off_tail).replace('\r', '')
                assert 'Focus cleared. Markdown kept.' in off_tail
                assert 'Review migration' in off_screen and 'Buy groceries' in off_screen
                assert taskfile.read_bytes() == before_off
                assert 'No focus saved today' in run('focus', 'status')

                # Complete one task through the composer UI after selecting it.
                terminal.send('/focus 1\r')
                terminal.pump(.2)
                terminal.ready()
                terminal.send('/focus done\r')
                terminal.pump(.25)
                done_screen = terminal.capture('focus-done-ui')
                assert "You finished today's focus" in done_screen
                assert 'Review migration with the operations team' in done_screen and '[x]' in done_screen
                assert '- [x] Review migration with the operations team' in taskfile.read_text()
                assert '* [ ] Verify 東京 backup 🚀' in taskfile.read_text()
                assert '- [ ] Buy groceries' in taskfile.read_text()
                terminal.finish()
            finally:
                terminal.close()
                active.remove(terminal)

        case('real composer picker arrows/cancel/resize/restart/off and UI completion', picker_tui_lifecycle)

    # Retain reports even when one scenario fails, so a parent run is diagnosable.
    report = {
        'binary': str(binary),
        'binary_sha256': sha(binary.read_bytes()) if binary.exists() else None,
        'fixture_timezone': 'America/Chicago',
        'fixture_start_local': '2026-10-04 23:50',
        'fixture_rollover_local': '2026-10-05 00:01',
        'cases': cases,
        'commands': records,
        'captures': captures,
    }
    (artifacts / 'results.json').write_text(json.dumps(report, indent=2, ensure_ascii=False))
    transcript = ['# Focus E2E transcript', '', f'Binary: `{binary}`', '', 'Fixture clock: 2026-10-04 23:50 to 2026-10-05 00:01 America/Chicago', '']
    for record in records:
        if 'argv' not in record:
            continue
        transcript += [f"## doin {' '.join(record['argv'])}", '', f"Exit: {record['exit']}", '', '```text', record['stdout'] + record['stderr'], '```', '']
    (artifacts / 'transcript.md').write_text('\n'.join(transcript))
    for item in cases:
        print(('PASS' if item['passed'] else 'FAIL') + ' ' + item['name'])
    print(f'Evidence: {artifacts}')
    raise SystemExit(0 if all(item['passed'] for item in cases) else 1)


try:
    main()
finally:
    for terminal in active[:]:
        terminal.close()
        active.remove(terminal)
