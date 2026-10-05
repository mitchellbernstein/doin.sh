#!/usr/bin/env python3
"""Drive the actual executable through PTYs; save reproducible terminal screens and transcripts."""
import argparse, datetime, codecs, fcntl, hashlib, html, http.server, json, os, pathlib, pty, re, select, signal, shutil, struct, subprocess, sys, tempfile, termios, threading, time, traceback, unicodedata

parser = argparse.ArgumentParser()
parser.add_argument('--bin', default='zig-out/bin/doin')
parser.add_argument('--artifacts', default='artifacts/tui-e2e')
parser.add_argument('--baseline', default='')
parser.add_argument('--case', help='Run only the exact named E2E case')
args = parser.parse_args()
binary = pathlib.Path(args.bin).resolve(); artifacts = pathlib.Path(args.artifacts).resolve(); artifacts.mkdir(parents=True, exist_ok=True)
cases, requests, captures, restorations = [], [], [], []
service_calls, service_state = [], {}
slow_poll_started = threading.Event()
try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    Image = None


def screen(raw, cols, rows):
    cells = [[(' ', '#eeeeee', False, '#111111') for _ in range(cols)] for _ in range(rows)]
    x = y = 0; top = 0; bottom = rows - 1; saved = (0, 0); color = '#eeeeee'; bold = False; background = '#111111'
    text = raw.decode('utf-8', errors='replace'); i = 0
    while i < len(text):
        c = text[i]
        if c == '\x1b':
            if text[i:i+2] in ('\x1b7','\x1b8'):
                if text[i+1]=='7': saved=(x,y)
                else: x,y=saved
                i+=2; continue
            match = re.match(r'\x1b\[([0-9;?]*)([A-Za-z~])', text[i:])
            if match:
                parameters, command = match.groups(); i += len(match.group(0))
                numbers = [int(n) if n else 0 for n in parameters.lstrip('?').split(';')]; n = numbers[0] or 1
                if command == 'A': y = max(0, y - n)
                elif command == 'B': y = min(rows - 1, y + n)
                elif command == 'C': x = min(cols - 1, x + n)
                elif command == 'D': x = max(0, x - n)
                elif command in ('H', 'f'): y = min(rows - 1, max(0, numbers[0] - 1)); x = min(cols - 1, max(0, (numbers[1] if len(numbers) > 1 else 1) - 1))
                elif command == 'r':
                    top = max(0, numbers[0]-1) if parameters else 0
                    bottom = min(rows-1, (numbers[1] if len(numbers)>1 else rows)-1)
                    x=y=0
                elif command == 'J' and numbers[0] == 2:
                    cells = [[(' ', color, bold, background) for _ in range(cols)] for _ in range(rows)]
                elif command == 'K':
                    if numbers[0] == 2: cells[y] = [(' ', color, bold, background) for _ in range(cols)]
                    else:
                        for xx in range(x, cols): cells[y][xx] = (' ', color, bold, background)
                elif command == 'm':
                    index = 0
                    while index < len(numbers):
                        code = numbers[index]
                        if code == 0: color = '#eeeeee'; bold = False; background = '#111111'
                        elif code == 1: bold = True
                        elif code == 36: color = '#67d6db'
                        elif code in (38, 48) and numbers[index + 1:index + 2] == [2] and index + 4 < len(numbers):
                            rgb = '#' + ''.join(f'{v:02x}' for v in numbers[index + 2:index + 5])
                            if code == 38: color = rgb
                            else: background = rgb
                            index += 4
                        index += 1
                continue
            i += 1; continue
        i += 1
        if c == '\r': x = 0; continue
        if c == '\n':
            if y == bottom:
                cells.pop(top); cells.insert(bottom, [(' ', color, bold, background) for _ in range(cols)])
            elif y < rows-1: y += 1
            continue
        if ord(c) < 32: continue
        width = 0 if unicodedata.combining(c) or c in ('\u200d', '\ufe0f') else (2 if unicodedata.east_asian_width(c) in ('W', 'F') else 1)
        if x >= cols:
            x=0
            if y==bottom: cells.pop(top); cells.insert(bottom,[(' ',color,bold,background) for _ in range(cols)])
            elif y<rows-1: y+=1
        if width:
            cells[y][x] = (c, color, bold, background)
            if width == 2 and x + 1 < cols: cells[y][x + 1] = ('', color, bold, background)
            x += width
    return cells


class Terminal:
    def __init__(self, executable, env, cols=88, rows=32):
        self.cols, self.rows = cols, rows; self.raw = bytearray()
        self.master, self.slave = pty.openpty(); self.original = termios.tcgetattr(self.slave)
        self.resize(cols, rows)
        self.process = subprocess.Popen([str(executable)], env=env, stdin=self.slave, stdout=self.slave, stderr=self.slave, start_new_session=True)
    def resize(self, cols, rows):
        self.cols, self.rows = cols, rows
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
    def pump(self, duration=.08):
        deadline = time.monotonic() + duration
        while time.monotonic() < deadline:
            if select.select([self.master], [], [], min(.02, max(0, deadline - time.monotonic())))[0]:
                try: data = os.read(self.master, 65536)
                except OSError: break
                if not data: break
                self.raw.extend(data)
    def wait(self, marker, offset=0, timeout=8):
        deadline = time.monotonic() + timeout
        while marker.encode() not in self.raw[offset:]:
            self.pump()
            if self.process.poll() is not None or time.monotonic() >= deadline: raise AssertionError(f'Missing {marker!r}; exit={self.process.poll()}; tail={bytes(self.raw[-2000:])!r}')
    def send(self, data):
        os.write(self.master, data.encode() if isinstance(data, str) else data); self.pump()
    def raw_mode(self):
        attributes = termios.tcgetattr(self.slave)
        return not attributes[3] & termios.ICANON and not attributes[3] & termios.ECHO
    def ready(self):
        deadline = time.monotonic() + 5
        while not self.raw_mode():
            self.pump()
            assert self.process.poll() is None and time.monotonic() < deadline
        self.pump()
    def capture(self, name):
        self.pump(); raw = bytes(self.raw)
        (artifacts / (name + '.ansi')).write_bytes(raw)
        grid = screen(raw, self.cols, self.rows)
        lines = [''.join(c[0] for c in row).rstrip() for row in grid]
        (artifacts / (name + '.txt')).write_text('\n'.join(lines) + '\n')
        elements = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.cols * 9 + 32}" height="{self.rows * 20 + 32}" viewBox="0 0 {self.cols * 9 + 32} {self.rows * 20 + 32}"><rect width="100%" height="100%" fill="#111111"/>']
        for yy, row in enumerate(grid):
            for xx, (char, color, bold, background) in enumerate(row):
                if background != '#111111': elements.append(f'<rect x="{16 + xx * 9}" y="{16 + yy * 20}" width="9" height="20" fill="{background}"/>')
                if char.strip(): elements.append(f'<text x="{16 + xx * 9}" y="{32 + yy * 20}" font-family="Menlo,DejaVu Sans Mono,monospace" font-size="15" font-weight="{700 if bold else 400}" fill="{color}">{html.escape(char)}</text>')
        elements.append('</svg>'); (artifacts / (name + '.svg')).write_text(''.join(elements))
        if Image is not None:
            image = Image.new('RGB', (self.cols * 9 + 32, self.rows * 20 + 32), '#111111')
            draw = ImageDraw.Draw(image)
            font_path = next((p for p in ('/System/Library/Fonts/Menlo.ttc', '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf') if pathlib.Path(p).exists()), None)
            font = ImageFont.truetype(font_path, 15) if font_path else ImageFont.load_default()
            wide_path = pathlib.Path('/System/Library/Fonts/Supplemental/Arial Unicode.ttf')
            wide_font = ImageFont.truetype(str(wide_path), 15) if wide_path.exists() else font
            symbol_path = pathlib.Path('/System/Library/Fonts/Apple Symbols.ttf')
            symbol_font = ImageFont.truetype(str(symbol_path), 15) if symbol_path.exists() else font
            emoji_path = pathlib.Path('/System/Library/Fonts/Apple Color Emoji.ttc')
            emoji_font = ImageFont.truetype(str(emoji_path), 20) if emoji_path.exists() else symbol_font
            for yy, row in enumerate(grid):
                for xx, (char, color, bold, background) in enumerate(row):
                    if background != '#111111': draw.rectangle((16 + xx * 9, 16 + yy * 20, 25 + xx * 9, 36 + yy * 20), fill=background)
                    if char.strip(): draw.text((16 + xx * 9, 16 + yy * 20), char, fill=color, font=wide_font if ord(char[0]) >= 0x2e80 and ord(char[0]) < 0x1f000 else emoji_font if ord(char[0]) >= 0x1f000 else font, embedded_color=True)
            image.save(artifacts / (name + '.png'))
        captures.append({'name': name, 'columns': self.cols, 'rows': self.rows, 'raw': name + '.ansi', 'screen': name + '.svg', 'png': name + '.png' if Image is not None else None})
        return '\n'.join(lines)
    def finish(self, data=b'\x03', sig=None):
        if self.process.poll() is None:
            if sig: os.kill(self.process.pid, sig)
            else: self.send(data)
        self.process.wait(timeout=5); self.pump()
        after = termios.tcgetattr(self.slave)
        before = list(self.original); durable_after = list(after)
        pending = getattr(termios, 'PENDIN', 0)
        before[3] &= ~pending; durable_after[3] &= ~pending
        restorations.append({'before_flags': self.original[:6], 'after_flags': after[:6], 'ignored_kernel_state': pending, 'restored': durable_after == before})
        assert durable_after == before, ('Terminal settings were not restored', before, durable_after)
        assert b'\x1b[?1049h' not in self.raw and b'\x1b[3J' not in self.raw, 'Scrollback was erased'
    def close(self):
        if self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGTERM)
            try: self.process.wait(timeout=3)
            except subprocess.TimeoutExpired: os.killpg(self.process.pid, signal.SIGKILL); self.process.wait()
        os.close(self.master); os.close(self.slave)


class Fixture(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        if self.path in ('/v1/plan', '/v1/account'):
            service_calls.append(self.path)
            value = {'name': 'doinMORE', 'amount': 499, 'currency': 'usd', 'interval': 'month', 'options': [{'interval':'month','amount':499},{'interval':'year','amount':4999}], 'billing_mode': 'test', 'email_ready': True, 'billing_ready': True} if self.path == '/v1/plan' else {'id': 'fixture-account', 'email': 'fixture@example.test'}
            if self.path=='/v1/plan' and 'bad_offers' in service_state: value['options']=service_state['bad_offers']
            payload = json.dumps(value).encode(); self.send_response(200); self.send_header('Content-Length', str(len(payload))); self.end_headers(); self.wfile.write(payload); return
        if self.path == '/v1/models':
            payload = json.dumps({'data': [{'id': 'fixture-api-model'}]}).encode()
            self.send_response(200); self.send_header('Content-Length', str(len(payload))); self.end_headers(); self.wfile.write(payload); return
        if self.path != '/api/tags':
            self.send_response(503); self.end_headers(); return
        payload = json.dumps({'models': [{'name': '\x1b[2Jfixture-local\x1b]0;local-catalog-title\x07'}, {'name': 'fixture-local'}, {'name': 'fixture-reasoner'}, {'name': 'fixture-small'}, {'name': 'fixture-no-show'}]}).encode()
        self.send_response(200); self.send_header('Content-Length', str(len(payload))); self.end_headers(); self.wfile.write(payload)
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append(request)
        if self.path in ('/v1/auth/start', '/v1/auth/poll', '/v1/checkout'):
            service_calls.append(self.path)
            if self.path == '/v1/auth/start':
                if service_state.get('deny_email'): self.send_response(503); self.end_headers(); return
                service_state.update(email=request['email'], challenge=request['code_challenge'])
                value = {'request_id': 'fixture-request', 'confirmation_code': '123456', 'expires_in': 20, 'interval': 1}
            elif self.path == '/v1/auth/poll':
                if service_state.get('slow_poll'):
                    slow_poll_started.set(); time.sleep(3)
                import base64
                assert base64.urlsafe_b64encode(hashlib.sha256(request['code_verifier'].encode()).digest()).decode().rstrip('=') == service_state['challenge']
                value = {'token': 'fixture.session.token', 'expires_at': int(time.time()) + 3600, 'account': {'id': 'fixture-account', 'email': service_state['email']}}
            else:
                assert request.get('interval') in ('month','year') and set(request)=={'interval'}
                service_state.setdefault('checkout_intervals',[]).append(request.get('interval','month'))
                value = {'url': 'https://checkout.stripe.com/c/pay/fixture#retained-fragment'}
            payload = json.dumps(value).encode(); self.send_response(200); self.send_header('Content-Length', str(len(payload))); self.end_headers(); self.wfile.write(payload); return
        if self.path == '/api/show':
            if request['model'] == 'fixture-no-show': self.send_response(503); self.end_headers(); return
            payload = json.dumps({'model_info': {'fixture.context_length': 32768}, 'thinking': {'values': ['low', 'medium', 'high'], 'default': 'medium'}}).encode()
            self.send_response(200); self.send_header('Content-Length', str(len(payload))); self.end_headers(); self.wfile.write(payload); return
        slow = 'slow footer fixture' in request['messages'][1]['content']
        if slow: time.sleep(2)
        generating = 'Return only Markdown' in request['messages'][0]['content']
        response = '## Weekend plan\n\n- [ ] Review café launch\n- [ ] Verify backup restore\n' if generating else 'Review migration before launch.\x1b[2J Keep the backup note.\x1b]0;unsafe-title\x07'
        payload = json.dumps({'message': {'role': 'assistant', 'content': response}, 'done': True}).encode()
        self.send_response(200); self.send_header('Content-Length', str(len(payload))); self.end_headers(); self.wfile.write(payload)


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
active = []
with tempfile.TemporaryDirectory(prefix='doin-tui-e2e-') as temp:
    root = pathlib.Path(temp).resolve(); storage = root / 'tasks space'; config = root / 'config'; env = dict(os.environ, TERM='xterm-256color', DOIN_CONFIG_DIR=str(config))
    real_curl=shutil.which('curl'); assert real_curl
    guard_dir=root/'network-guard'; guard_dir.mkdir(); guard_log=root/'blocked-network.log'; browser_guard_log=root/'blocked-browser.jsonl'
    guard=guard_dir/'curl'
    guard.write_text('#!'+sys.executable+'\nimport os,sys,urllib.parse\nfrom pathlib import Path\nurls=[v for v in sys.argv[1:] if v.startswith(("http://","https://"))]\nif not urls or any(urllib.parse.urlsplit(v).hostname not in ("localhost","127.0.0.1","::1") for v in urls):\n with Path(os.environ["TUI_NETWORK_GUARD_LOG"]).open("a") as f:f.write("blocked\\n")\n sys.exit(97)\nos.execv(os.environ["TUI_REAL_CURL"],[os.environ["TUI_REAL_CURL"],*sys.argv[1:]])\n')
    guard.chmod(0o700)
    for executable in ('open', 'xdg-open'):
        browser_guard=guard_dir/executable
        browser_guard.write_text('#!'+sys.executable+'\nimport json,os,sys\nfrom pathlib import Path\nwith Path(os.environ["TUI_BROWSER_GUARD_LOG"]).open("a") as f:f.write(json.dumps({"command":Path(sys.argv[0]).name,"argv":sys.argv[1:]})+"\\n")\nsys.exit(97)\n')
        browser_guard.chmod(0o700)
    env.update(PATH=str(guard_dir)+os.pathsep+env['PATH'],TUI_REAL_CURL=real_curl,TUI_NETWORK_GUARD_LOG=str(guard_log),TUI_BROWSER_GUARD_LOG=str(browser_guard_log))
    denied=subprocess.run([str(guard),'--url','https://example.invalid'],env=env,capture_output=True)
    assert denied.returncode==97 and guard_log.read_text()=='blocked\n','Nonfixture denial guard failed'
    denied_browser=subprocess.run([str(guard_dir/'open'),'https://example.invalid'],env=env,capture_output=True)
    assert denied_browser.returncode==97 and json.loads(browser_guard_log.read_text())=={'command':'open','argv':['https://example.invalid']},'Browser denial guard failed'
    env.pop('NO_COLOR', None)
    subprocess.run([str(binary), 'init', '--storage', str(storage), '--provider', 'manual'], env=env, check=True, capture_output=True)
    taskfile = storage / 'tasks.md'
    original = '# Launch café\n\n## This week\n\n- [ ] Review migration with the operations team before the long deployment window\n  - [ ] Verify 東京 backup 🚀\n- [x] Capture baseline\n\n```markdown\n- [ ] Example only\n```\n\n## Personal\n\n- [ ] Buy groceries\n'
    taskfile.write_text(original)
    def case(name, fn):
        if args.case and name != args.case: return
        try: fn(); cases.append({'name': name, 'passed': True})
        except Exception: cases.append({'name': name, 'passed': False, 'failure': traceback.format_exc()})
    def start(executable=binary, custom_env=None, cols=88, rows=32):
        terminal = Terminal(executable, custom_env or env, cols, rows); active.append(terminal); return terminal
    def contents(expected):
        deadline = time.monotonic() + 5
        while expected not in taskfile.read_text():
            assert time.monotonic() < deadline, expected; time.sleep(.02)
    if args.baseline:
        t = start(pathlib.Path(args.baseline).resolve()); t.pump(.3); t.capture('before'); t.finish(b'quit\n'); t.close(); active.remove(t)

    def manual():
        t = start()
        try:
            t.wait('Tasks   '); t.ready()
            initial = t.capture('manual-board')
            assert 'Model' in initial and 'Manual' in initial and 'File' in initial and 'This week' in initial and 'Personal' in initial
            assert 'Example only' not in initial
            assert '[ ]' in initial and '[x]' in initial and 'ADD A TASK' not in initial and 'TASKS & QUESTIONS' not in initial
            grid = screen(bytes(t.raw), t.cols, t.rows)
            for row in grid:
                text = ''.join(cell[0] for cell in row)
                if '[ ]' in text: assert any(cell[1] == '#d0d0d0' and cell[0].strip() for cell in row)
                if '[x]' in text: assert any(cell[1] == '#949494' and cell[0].strip() for cell in row)
            t.send('/add Review café'); t.send(b'\x1b[D\x1b[3~'); t.send('e 🚀'); t.send(b'\x7f'); t.send('東京'); t.capture('editing-unicode'); t.send('\r')
            contents('- [ ] Review cafe 東京'); t.ready()
            t.send('/note current draft'); t.send(b'\x1b[A\x1b[B\r'); contents('current draft'); t.ready()
            t.send('/do\t1\r'); contents('- [x] Review migration'); t.ready()
            t.send('/he\t\r'); t.wait('Preview AI-generated Markdown'); t.ready()
            before = taskfile.read_bytes(); t.send(b'\x1b[200~Buy bread\nthen plan dinner\x1b[201~'); t.pump(.2)
            assert taskfile.read_bytes() == before, 'Paste submitted without Enter'
            t.send('\r'); contents('- [ ] Buy bread then plan dinner'); t.ready()
            t.send('Long draft 東京'); t.resize(32, 20); t.pump(.25); t.send(' with enough words to need horizontal scrolling'); t.capture('narrow-resized'); t.send('\r')
            contents('- [ ] Long draft 東京 with enough words to need horizontal scrolling'); t.ready()
            before = taskfile.read_bytes(); t.send('Unsubmitted task'); t.finish(); assert taskfile.read_bytes() == before
            t.capture('manual-exit')
        finally: t.close(); active.remove(t)
    case('sectioned task board, Unicode editing/delete, history draft, completion, paste, resize and Ctrl+C restore', manual)

    def slash_commands():
        t = start()
        try:
            t.wait('Tasks   '); t.ready(); before = taskfile.read_bytes()
            t.send('/'); t.wait('/add'); t.wait('/ask'); t.capture('slash-menu-open')
            opened = '\n'.join(''.join(cell[0] for cell in row) for row in screen(bytes(t.raw), t.cols, t.rows))
            assert '› /add' in opened and '/ask' in opened, 'Slash did not open selectable command rows immediately'
            t.send(b'\x1b'); t.pump(.12); t.capture('slash-menu-dismissed')
            dismissed = '\n'.join(''.join(cell[0] for cell in row) for row in screen(bytes(t.raw), t.cols, t.rows))
            assert '/' in dismissed and '/add' not in dismissed, 'Escape should hide choices while preserving the slash draft'
            t.send(b'\x7f'); offset = len(t.raw); t.send('/d'); t.wait('/done', offset); t.wait('/delete', offset); t.capture('slash-menu-filtered')
            filtered = '\n'.join(''.join(cell[0] for cell in row) for row in screen(bytes(t.raw), t.cols, t.rows))
            assert '/done' in filtered and '/delete' in filtered and '/add' not in filtered, 'Command choices did not filter by typed prefix'
            t.send(b'\x1b[B'); t.pump(.2); selected = t.capture('slash-menu-arrow-selected')
            assert '› /delete' in selected, 'Arrow keys did not move menu selection'
            offset = len(t.raw); t.resize(42, 14); t.wait('/delete', offset); t.ready(); resized = t.capture('slash-menu-resized')
            assert '› /delete' in resized, 'Resize lost the draft or menu selection'
            t.send('\t'); t.pump(.2); t.capture('slash-menu-tab-completed')
            completed = '\n'.join(''.join(cell[0] for cell in row) for row in screen(bytes(t.raw), t.cols, t.rows))
            assert '/delete ' in completed and '/done' not in completed and taskfile.read_bytes() == before, 'Tab must fill the highlighted command, hide choices for arguments and avoid execution'
            t.send(b'\x15'); offset = len(t.raw); t.send('/up'); t.wait('/update', offset); t.wait('/upgrade', offset); ambiguous = t.capture('slash-menu-update-upgrade')
            assert '/update' in ambiguous and '/upgrade' in ambiguous, 'The shared command table must include all valid update commands'
            t.send('\t'); t.pump(.2); completed_update = t.capture('slash-menu-update-tab-completed')
            assert '/update ' in completed_update and taskfile.read_bytes() == before, 'Tab should complete the highlighted /up match without executing it'
            t.send(b'\x15'); t.send(b'\x1b[200~pasted draft\x1b[201~'); t.pump(.2); pasted = t.capture('slash-menu-paste-remains-draft')
            assert 'pasted draft' in pasted and taskfile.read_bytes() == before, 'Pasting ordinary text must preserve it as a draft'
            t.send(b'\x15'); offset = len(t.raw); t.send('/help\r'); t.wait('tiny Markdown tasks', offset); t.ready(); t.capture('slash-menu-enter-exact-command')
            assert taskfile.read_bytes() == before, 'Enter should still submit a complete typed command'
            t.send(b'\x03'); t.finish(); assert taskfile.read_bytes() == before
        finally: t.close(); active.remove(t)
    case('slash menu opens immediately, dismisses without losing draft, filters and fills safely', slash_commands)

    def ai():
        subprocess.run([str(binary), 'init', '--storage', str(storage), '--provider', 'ollama', '--model', 'fixture-local', '--endpoint', f'http://127.0.0.1:{server.server_port}'], env=env, check=True, capture_output=True)
        t = start()
        try:
            t.wait('Tasks   '); t.ready(); before = taskfile.read_bytes()
            offset = len(t.raw); t.send('What should I do first?\r'); t.wait('Review migration before launch', offset); t.ready()
            assert taskfile.read_bytes() == before and 'Review migration' in json.dumps(requests[-1])
            assert b'\x1b[2J' not in t.raw and b'unsafe-title' not in t.raw
            sgr = re.findall(rb'\x1b\[([0-9;]*)m', bytes(t.raw))
            assert not any(code in (b'31', b'32', b'36', b'91', b'92', b'96') for code in sgr), 'Accent palette remains'
            assert b'\x1b[48;2;36;36;36m' in t.raw and b'User' in t.raw and b'Assistant' in t.raw, 'Neutral user band and assistant role missing'
            assert b'\x1b[38;2;255;255;255m' in t.raw and b'\x1b[38;2;208;208;208m' in t.raw and b'\x1b[38;2;148;148;148m' in t.raw, 'User/assistant/system contrast hierarchy missing'
            conversation = t.capture('neutral-conversation')
            assert conversation.count('What should I do first?') == 1, 'Submitted composer duplicates user turn'
            grid = screen(bytes(t.raw), t.cols, t.rows)
            user_row = next(i for i, row in enumerate(grid) if 'User  What should I do first?' in ''.join(cell[0] for cell in row))
            for row in (grid[user_row - 1], grid[user_row + 1]):
                assert not ''.join(cell[0] for cell in row).strip() and sum(cell[3] == '#242424' for cell in row) >= t.cols - 5, 'Gray vertical padding missing'
            for cols,rows in [(52,20),(100,30),(62,24)]:
                offset=len(t.raw);t.resize(cols,rows);t.wait('Enter submit',offset);t.ready()
                resized=t.capture(f'ai-response-resize-{cols}')
                assert 'Review migration before launch' in resized and resized.count('╭')==1,'Resize displaced latest AI response'
            assert taskfile.read_bytes()==before
            offset = len(t.raw); t.send('Plan my weekend\r'); t.wait('Append this Markdown?', offset); t.ready(); t.capture('ai-preview'); t.send('n\r'); t.wait('Nothing saved', offset); t.ready()
            assert taskfile.read_bytes() == before
            prompt_rules=requests[-1]['messages'][0]['content']
            assert datetime.date.today().isoformat() in prompt_rules and '@due(YYYY-MM-DD)' in prompt_rules and 'only when the user requests it' in prompt_rules
            offset = len(t.raw); t.send('Plan my weekend\r'); t.wait('Append this Markdown?', offset); t.ready(); t.send('y\r')
            contents('## Weekend plan'); t.ready(); t.capture('ai-saved'); t.finish(b'\x04')
        finally: t.close(); active.remove(t)
    case('natural-language question is read-only; AI plan preview rejects/accepts; terminal output sanitized; Ctrl+D restore', ai)

    def model_picker():
        custom = dict(env, DOIN_CONFIG_DIR=str(root / 'picker-config'))
        subprocess.run([str(binary), 'init', '--storage', str(storage), '--provider', 'ollama', '--model', 'fixture-local', '--endpoint', f'http://127.0.0.1:{server.server_port}'], env=custom, check=True, capture_output=True)
        configfile = root / 'picker-config' / 'config.json'
        t = start(custom_env=custom)
        try:
            t.wait('Tasks   '); t.ready(); before = configfile.read_bytes()
            offset = len(t.raw); t.send('/model '); t.wait('<model>', offset); t.ready(); t.capture('model-picker-models')
            t.send(b'fixture-reasoner\t8192\thigh\r'); t.wait('Model settings saved', offset); t.ready()
            settings = json.loads(configfile.read_text()); assert settings['model'] == 'fixture-reasoner' and settings['context_tokens'] == 8192 and settings['effort'] == 'high'
            offset = len(t.raw); t.send('/ask What should I do first?\r'); t.wait('Review migration before launch', offset); t.ready()
            assert requests[-1]['options']['num_ctx'] == 8192 and requests[-1]['think'] == 'high'
            before = configfile.read_bytes(); offset = len(t.raw); t.send('/model '); t.wait('<model>', offset); t.ready()
            t.send(b'\x1b[200~fixture-reasoner\t8192\nhigh\x1b[201~'); t.pump(.2); assert configfile.read_bytes() == before
            t.send(b'\x1b'); t.wait('Model selection cancelled', offset); t.ready(); assert configfile.read_bytes() == before
            offset = len(t.raw); t.send('/model '); t.wait('<model>', offset); t.ready(); t.send('reasoner\t'); t.wait('Context window', offset); t.ready(); t.send('8192\t'); t.wait('Reasoning effort', offset); t.ready(); t.capture('model-picker-effort')
            t.send(b'\x1b[Z'); t.pump(.2); t.ready(); t.send(b'\x1b[B\x1b[A\x1b'); t.wait('Model selection cancelled', offset); t.ready(); assert configfile.read_bytes() == before
            offset = len(t.raw); t.send('/model '); t.wait('<model>', offset); t.ready(); t.resize(42, 14); t.pump(.4); t.ready(); assert configfile.read_bytes() == before; t.capture('model-picker-resized'); t.finish()
        finally: t.close(); active.remove(t)
        t = start(custom_env=custom, cols=60, rows=10)
        try:
            t.wait('Tasks   '); t.pump(); offset = len(t.raw); t.send('/model\n'); t.wait('Choice [1;', offset); assert not t.raw_mode(); t.capture('model-picker-short'); t.send(b'\x1b\n'); t.wait('Model selection cancelled', offset); t.pump(); t.finish(b'/quit\n')
        finally: t.close(); active.remove(t)
    case('model picker filters and navigates fields; queued selection wires provider controls; paste/cancel/resize/short-height preserve settings', model_picker)

    def model_fallbacks():
        for provider, endpoint, model, missing_catalog in [('api', '/v1', 'fixture-api-model', False), ('api', '/unavailable', 'custom-private-model', True), ('ollama', '', 'fixture-no-show', False)]:
            custom = dict(env, DOIN_CONFIG_DIR=str(root / ('fallback-' + model)), DOIN_API_KEY='fixture-key')
            subprocess.run([str(binary), 'init', '--storage', str(storage), '--provider', provider, '--model', model, '--endpoint', f'http://127.0.0.1:{server.server_port}{endpoint}'], env=custom, check=True, capture_output=True)
            t = start(custom_env=custom)
            try:
                t.wait('Tasks   '); t.ready(); offset = len(t.raw); t.send('/model ')
                if missing_catalog: t.wait('Model name:', offset); t.ready(); t.send(model + '\r')
                t.wait('<model>', offset); t.ready(); t.send(model + '\t'); t.wait('Context window', offset); t.ready(); t.send('\t'); t.wait('Reasoning effort', offset); t.ready(); t.capture('model-defaults-' + model)
                settings_path = pathlib.Path(custom['DOIN_CONFIG_DIR']) / 'config.json'; before = settings_path.read_bytes()
                t.send('\t'); t.pump(.2); t.ready(); assert settings_path.read_bytes() == before, 'Final Tab saved settings'
                t.send(model + '\t\t\r'); t.wait('Model settings saved', offset); t.ready()
                settings = json.loads(settings_path.read_text()); assert settings['model'] == model and settings['context_tokens'] is None and settings['effort'] is None
                t.finish()
            finally: t.close(); active.remove(t)
    case('API catalog data shape, offline custom-name fallback, capability outage defaults, and final Tab never saves', model_fallbacks)

    def productivity_settings():
        custom = dict(env, DOIN_CONFIG_DIR=str(root / 'commands-config'))
        subprocess.run([str(binary), 'init', '--storage', str(storage), '--provider', 'manual'], env=custom, check=True, capture_output=True)
        saved = taskfile.read_bytes()
        try:
            taskfile.write_text('# Work\n- [ ] Ship milestone @priority(high) @due(2020-01-01)\n- [x] Completed migration\n# Home\n- [ ] Buy milk\nNotes survive.\n')
            before = taskfile.read_bytes(); t = start(custom_env=custom)
            try:
                t.wait('Tasks   '); t.ready(); offset = len(t.raw); t.send('/review\r'); t.wait('Open tasks', offset); t.ready(); assert taskfile.read_bytes() == before
                offset = len(t.raw); t.send('/prioritize\r'); t.wait('Priority preview', offset); t.ready(); assert taskfile.read_bytes() == before
                offset = len(t.raw); t.send('/visualize\r'); t.wait('Completion by group', offset); t.ready(); t.send(b'\x1b[C'); view = t.capture('visualize-selected-group'); assert '> Home' in view and 'Work' in view
                t.send('\r'); t.pump(.2); t.ready(); assert taskfile.read_bytes() == before
                offset = len(t.raw); t.send('/clear\r'); t.wait('Delete 1 tasks?', offset); t.ready(); t.capture('clear-preview'); t.send('n\r'); t.pump(.2); t.ready(); assert taskfile.read_bytes() == before
                offset = len(t.raw); t.send('/delete 1\r'); t.wait('Delete 1 tasks?', offset); t.ready(); taskfile.write_bytes(before + b'External note.\n'); t.send('y\r'); t.wait('Markdown changed externally', offset); t.ready(); assert taskfile.read_bytes().endswith(b'External note.\n')
                offset = len(t.raw); t.send('/remind 1 in 15m\r'); t.wait('Task reminder saved', offset); t.ready(); assert b'doin:id=' in taskfile.read_bytes(); t.send('/list\r'); t.pump(.2); t.ready(); board = t.capture('reminder-task-board'); assert 'doin:id=' not in board
                offset = len(t.raw); t.send('/settings\r'); t.wait('Setting [Enter', offset); t.ready(); t.capture('settings-menu'); t.send('4\r'); t.wait('Notification action', offset); t.ready(); t.capture('notification-settings'); t.send('2\r'); t.pump(.2); t.ready()
                offset = len(t.raw); t.send('/remind status\r'); t.wait('Reminders on', offset); t.ready(); t.finish()
            finally: t.close(); active.remove(t)
        finally: taskfile.write_bytes(saved)
    case('review/prioritize/chart stay read-only; batch preview cancellation and external-edit guard; settings menu uses native input', productivity_settings)

    def upgrade_flow():
        custom = dict(env, DOIN_CONFIG_DIR=str(root / 'upgrade-config'), DOIN_SYNC_ENDPOINT=f'http://127.0.0.1:{server.server_port}')
        subprocess.run([str(binary), 'init', '--storage', str(storage), '--provider', 'manual'], env=custom, check=True, capture_output=True)
        helpers = root / 'browser-bin'; helpers.mkdir(); browser_log = root / 'browser-log.json'
        for executable in ('open', 'xdg-open'):
            helper = helpers / executable; helper.write_text('#!' + sys.executable + '\nimport json, os, sys\nfrom pathlib import Path\nPath(os.environ["BROWSER_LOG"]).write_text(json.dumps(sys.argv[1:]))\n'); helper.chmod(0o700)
        custom.update(PATH=str(helpers) + os.pathsep + custom['PATH'], BROWSER_LOG=str(browser_log))
        t = start(custom_env=custom)
        try:
            t.wait('Tasks   '); t.ready(); before = taskfile.read_bytes(); offset = len(t.raw); call_offset = len(service_calls)
            t.send('/upgrade\r'); t.wait('Stay lame', offset); t.wait('Sandbox', offset); t.ready(); price_screen = t.capture('upgrade-choice'); assert '$4.99 / month' in price_screen and '$49.99 / year' in price_screen and '$4.+99' not in price_screen
            t.send('3\r'); t.pump(.2); t.ready()
            assert not browser_log.exists() and service_calls[call_offset:] == ['/v1/plan'] and not (root / 'upgrade-config' / 'sync.json').exists()
            offset = len(t.raw); call_offset = len(service_calls); t.send('/upgrade\r'); t.wait('Stay lame', offset); t.ready(); t.send('1\r'); t.wait('Email', offset); t.ready(); t.send('fixture@example.test\r'); t.wait('Signed in', offset); t.wait('Secure payment entry', offset); t.pump(.3); t.ready(); t.capture('upgrade-checkout')
            assert json.loads(browser_log.read_text()) == ['https://checkout.stripe.com/c/pay/fixture#retained-fragment']
            assert service_calls[call_offset:] == ['/v1/plan', '/v1/auth/start', '/v1/auth/poll', '/v1/account', '/v1/checkout']
            assert service_state['checkout_intervals'][-1]=='month'
            offset=len(t.raw); call_offset=len(service_calls); t.send('/account\r'); t.wait('Account action',offset); t.ready(); t.send('6\r'); t.wait('Stay lame',offset); t.ready(); t.capture('upgrade-monthly-yearly'); t.send('Upgrade yearly\r'); t.wait('Secure payment entry',offset); t.pump(.2); t.ready()
            assert service_state['checkout_intervals'][-1]=='year' and service_calls[call_offset:]==['/v1/plan','/v1/account','/v1/checkout']
            assert taskfile.read_bytes()==before
            count=len(service_state['checkout_intervals']); invalid=subprocess.run([str(binary),'sync','billing','day'],env=custom,capture_output=True); assert invalid.returncode!=0 and len(service_state['checkout_intervals'])==count
            annual=subprocess.run([str(binary),'account','subscribe','year'],env=custom,capture_output=True); assert annual.returncode==0 and service_state['checkout_intervals'][-1]=='year'
            monthly=subprocess.run([str(binary),'sync','billing'],env=custom,capture_output=True); assert monthly.returncode==0 and service_state['checkout_intervals'][-1]=='month'
            try:
                for offers in ([],[{'interval':'month','amount':499},{'interval':'month','amount':499}],[{'interval':'year','amount':4999}],[{'interval':'month','amount':499},{'interval':'year','amount':-1}],[{'interval':'day','amount':499}],[{'interval':'month','amount':499},{'interval':'year','amount':3999}]):
                    service_state['bad_offers']=offers; calls=len(service_calls); rejected=subprocess.run([str(binary),'upgrade'],env=custom,input=b'',capture_output=True)
                    assert rejected.returncode!=0 and service_calls[calls:]==['/v1/plan'] and taskfile.read_bytes()==before
            finally: service_state.pop('bad_offers',None)
            assert taskfile.read_bytes()==before; t.finish()
        finally: t.close(); active.remove(t)
    case('upgrade declines without sign-in/browser; sandbox price shown; verified email precedes checkout and browser preserves Stripe fragment', upgrade_flow)

    def upgrade_origin():
        wrong_requests = []
        class WrongOrigin(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_GET(self):
                wrong_requests.append(self.path)
                payload = json.dumps({'name': 'doinMORE', 'amount': 499, 'currency': 'usd', 'interval': 'month', 'options': [{'interval':'month','amount':499},{'interval':'year','amount':4999}], 'billing_mode': 'live', 'email_ready': True, 'billing_ready': True}).encode()
                self.send_response(200); self.send_header('Content-Length', str(len(payload))); self.end_headers(); self.wfile.write(payload)
            def do_POST(self): wrong_requests.append(self.path); self.send_response(500); self.end_headers()
        wrong = http.server.HTTPServer(('127.0.0.1', 0), WrongOrigin); wrong_thread = threading.Thread(target=wrong.serve_forever, daemon=True); wrong_thread.start()
        try:
            custom = dict(env, DOIN_CONFIG_DIR=str(root / 'origin-config'), DOIN_SYNC_ENDPOINT=f'http://127.0.0.1:{server.server_port}', PATH=str(root / 'browser-bin') + os.pathsep + env['PATH'], BROWSER_LOG=str(root / 'origin-browser.json'))
            subprocess.run([str(binary), 'init', '--storage', str(storage), '--provider', 'manual'], env=custom, check=True, capture_output=True)
            credentials = root / 'origin-config' / 'sync.json'; old = json.dumps({'endpoint': f'http://127.0.0.1:{wrong.server_port}', 'token': 'wrong.origin.fixture.token'}).encode(); credentials.write_bytes(old); credentials.chmod(0o600)
            t = start(custom_env=custom)
            try:
                t.wait('Tasks   '); t.ready(); offset = len(t.raw); t.send('/upgrade\r'); t.wait('Sandbox', offset); t.ready(); t.send('1\r'); t.wait('different sync server', offset); t.wait('Email', offset); t.ready(); service_state['deny_email'] = True; t.send('fixture@example.test\r'); t.wait('Sync could not finish', offset); t.ready()
                assert credentials.read_bytes() == old and not wrong_requests and not pathlib.Path(custom['BROWSER_LOG']).exists()
                service_state['deny_email'] = False; offset = len(t.raw); t.send('/upgrade\r'); t.wait('Sandbox', offset); t.ready(); t.send('1\r'); t.wait('Email', offset); t.ready(); t.send('fixture@example.test\r'); t.wait('Secure payment entry', offset); t.pump(.3); t.ready(); t.capture('upgrade-origin-pinned')
                assert not wrong_requests and json.loads(credentials.read_text())['endpoint'] == custom['DOIN_SYNC_ENDPOINT']
                assert json.loads(pathlib.Path(custom['BROWSER_LOG']).read_text()) == ['https://checkout.stripe.com/c/pay/fixture#retained-fragment']; t.finish()
            finally: service_state['deny_email'] = False; t.close(); active.remove(t)
        finally: wrong.shutdown(); wrong.server_close(); wrong_thread.join(timeout=5)
    case('two-origin upgrade pins sandbox plan and checkout; wrong-origin credentials never sent and failed new sign-in preserves prior session', upgrade_origin)

    folder_fixture = root / 'folder-choice.json'
    folder_log = root / 'folder-picker.jsonl'
    picker = guard_dir / 'osascript'
    picker.write_text('#!' + sys.executable + '\nimport json,os,sys\nfrom pathlib import Path\nf=json.loads(Path(os.environ["FOLDER_FIXTURE"]).read_text())\nwith Path(os.environ["FOLDER_PICKER_LOG"]).open("a") as log: log.write(json.dumps({"argv":sys.argv[1:],"choice":f})+"\\n")\nsys.exit(1) if f.get("fail") else print(f.get("path", ""))\n')
    picker.chmod(0o700)
    def onboarding_env(name, chosen):
        chosen.mkdir(parents=True, exist_ok=True)
        folder_fixture.write_text(json.dumps({'path': str(chosen)}))
        custom = dict(env, DOIN_CONFIG_DIR=str(root / name), FOLDER_FIXTURE=str(folder_fixture), FOLDER_PICKER_LOG=str(folder_log))
        fallback_home = root / (name + '-home'); fallback_home.mkdir()
        (fallback_home / 'Documents').symlink_to(chosen, target_is_directory=True)
        custom['HOME'] = str(fallback_home)
        return custom
    def storage_choice(t):
        t.wait('Select a folder'); t.ready(); t.send('\x1b[B\r')
        t.wait('Use this folder'); t.ready(); t.send('Documents\r')
        t.pump(.2); t.ready(); t.send('\r')

    def onboarding_default_and_cancel():
        fakehome = root / 'new home'; (fakehome / 'Documents').mkdir(parents=True)
        chosen = root / 'selected café folder'
        custom = onboarding_env('default-storage', chosen); custom['HOME'] = str(fakehome)
        before = folder_log.read_bytes() if folder_log.exists() else b''
        t = start(custom_env=custom, cols=76, rows=28)
        try:
            t.wait('Select a folder'); t.ready()
            first = t.capture('storage-recommended-default')
            assert '› 1' in first and '(Recommended)' in first and 'Documents/doin' in first
            t.send('\r'); t.wait('How would you like to organize'); t.ready(); t.send('\r')
            t.wait('How would you like your AI?'); t.ready(); t.send('\x1b[B\x1b[B\x1b[B\r'); t.wait('Manual — no model needed'); t.ready(); t.send('\r'); t.wait('Tasks   '); t.ready()
            settings = json.loads((root / 'default-storage' / 'config.json').read_text())
            assert settings['storage'] == str(fakehome / 'Documents' / 'doin')
            assert (folder_log.read_bytes() if folder_log.exists() else b'') == before
            t.finish()
        finally: t.close(); active.remove(t)
        custom = onboarding_env('cancel-storage', chosen)
        t = start(custom_env=custom, cols=76, rows=28)
        try:
            t.wait('Select a folder'); t.ready(); t.send('\x1b[B\r')
            t.wait('Use this folder'); t.ready(); t.send(b'\x1b'); t.pump(.2)
            cancelled = t.capture('storage-picker-cancelled')
            assert 'Select a folder' in cancelled and not (root / 'cancel-storage' / 'config.json').exists()
            t.send('\x1b[B\r'); t.wait('Use this folder'); t.ready(); t.send('Documents\r'); t.pump(.2); t.send('\r')
            t.wait('How would you like to organize'); t.ready(); t.send('\r')
            t.wait('How would you like your AI?'); t.ready(); t.send('\x1b[B\x1b[B\x1b[B\r'); t.wait('Manual — no model needed'); t.ready(); t.send('\r'); t.wait('Tasks   '); t.ready()
            assert json.loads((root / 'cancel-storage' / 'config.json').read_text())['storage'] == str(chosen)
            assert (folder_log.read_bytes() if folder_log.exists() else b'') == before
            t.capture('storage-picker-selected-unicode'); t.finish()
        finally: t.close(); active.remove(t)
    case('storage offers recommended default and terminal browsing with cancellation and Unicode selection', onboarding_default_and_cancel)

    def storage_browser_fallback():
        home = root / 'browser home'; documents = home / 'Documents'; documents.mkdir(parents=True)
        vanished = documents / 'Alpha vanished'; vanished.mkdir()
        target = documents / 'Beta café project'; target.mkdir()
        (documents / 'Gamma link').symlink_to(target, target_is_directory=True)
        for i in range(24): (documents / f'Project {i:02}').mkdir()
        (home / 'Downloads').mkdir()
        (documents / '2026 Roadmap').mkdir()
        custom = onboarding_env('browser-storage', target); custom['HOME'] = str(home)
        t = start(custom_env=custom, cols=76, rows=20)
        try:
            t.wait('Select a folder'); t.ready(); t.send('\x1b[B\r'); t.wait('Downloads'); t.ready()
            t.capture('storage-browser-home'); t.send('Documents\x1b[C'); t.pump(.2); t.ready()
            t.wait('Alpha vanished'); t.capture('storage-browser-initial')
            t.send('Alpha'); t.pump(.2); vanished.rmdir(); t.send('\r'); t.wait('Cannot open'); t.ready()
            t.capture('storage-browser-recovered'); t.send('\x15No such folder\r'); t.pump(.2)
            assert not (root / 'browser-storage' / 'config.json').exists()
            t.capture('storage-browser-no-match'); t.send('\x15Gamma'); t.pump(.2); t.resize(48,14); t.pump(.3); t.ready()
            resized=t.capture('storage-browser-filter-resized'); assert 'Gamma' in resized
            t.send('\r'); t.pump(.2); t.ready(); t.capture('storage-browser-symlink')
            t.send('\x1b[1;3D'); t.pump(.2); t.ready(); t.send('\x1b[1;3C'); t.pump(.2); t.ready()
            t.send('\x1b[D'); t.pump(.2); t.ready(); t.send('2026x\x7f\r'); t.pump(.2); t.ready(); t.send('\x1b[D'); t.pump(.2); t.ready(); t.send('Beta\r'); t.pump(.2); t.ready(); t.send('\r')
            t.wait('How would you like to organize'); t.ready(); t.send('\r')
            t.wait('How would you like your AI?'); t.ready(); t.send('\x1b[B\x1b[B\x1b[B\r'); t.wait('Manual — no model needed'); t.ready(); t.send('\r'); t.wait('Tasks   '); t.ready()
            settings = json.loads((root / 'browser-storage' / 'config.json').read_text())
            assert settings['storage'] == str(target.resolve())
            t.finish()
        finally: t.close(); active.remove(t)
    case('terminal browser filters, navigates history and symlinks, handles vanished folders and resizes without committing', storage_browser_fallback)

    def onboarding():
        custom = onboarding_env('onboarding', root / 'onboarded tasks')
        t = start(custom_env=custom, cols=70, rows=28)
        try:
            t.wait('Select a folder'); t.ready(); onboarding_screen=t.capture('onboarding-first-step'); assert '1/3 Where should your markdown live?' in onboarding_screen and '╭' not in onboarding_screen; storage_choice(t); t.wait('How would you like to organize your tasks?'); t.ready(); t.send('\r'); t.wait('ChatGPT'); t.ready(); t.send('\x1b[B\x1b[B\x1b[B\r'); t.wait('Manual — no model needed'); t.ready(); t.send('\r'); t.wait('Tasks   '); t.ready()
            assert b'1/3 Where should your markdown live?' in t.raw
            assert b'2/3 How would you like to organize your tasks?' in t.raw
            assert b'3/3 How would you like your AI?' in t.raw
            settings = json.loads((root / 'onboarding' / 'config.json').read_text()); assert settings['provider'] == 'manual' and settings['storage'] == str(root / 'onboarded tasks')
            t.capture('onboarding-complete'); t.finish(sig=signal.SIGTERM)
        finally: t.close(); active.remove(t)
    case('first-run guided setup continues into composer; SIGTERM restores terminal', onboarding)

    def onboarding_arrows():
        custom = onboarding_env('arrows-onboarding', root / 'areas-tasks')
        t = start(custom_env=custom, cols=80, rows=24)
        try:
            storage_choice(t)
            t.wait('How would you like to organize your tasks?'); t.ready()
            initial=t.capture('onboarding-organization-recommended'); assert '2/3 How would you like to organize your tasks?' in initial and '› 1  Simple (Recommended) — one Markdown list' in initial and 'Working · input resumes when ready' not in initial and '╭' not in initial
            t.send('\x1b[B\x1b[B\r'); t.wait('Projects (Recommended) — Inbox, Projects, Archive'); t.ready()
            nested=t.capture('onboarding-template-recommended'); assert '2/3 Template for your tasks' in nested and 'Back' in nested and 'Working · input resumes when ready' not in nested and '╭' not in nested
            t.send('\x1b'); t.wait('How would you like to organize your tasks?'); t.ready(); t.capture('onboarding-template-escape-back')
            t.send('\x1b[B\x1b[B\r'); t.wait('Projects (Recommended) — Inbox, Projects, Archive'); t.ready(); t.send('\x1b[B\x1b[B\r')
            t.wait('How would you like to organize your tasks?'); t.ready(); t.send('\x1b[B\x1b[B\r'); t.wait('Projects (Recommended) — Inbox, Projects, Archive'); t.ready(); t.send('\x1b[B\r')
            t.wait('Areas — Personal, Work, Someday'); t.ready()
            t.wait('How would you like your AI?'); t.ready()
            short=t.capture('onboarding-ai-shortlist'); assert '3/3 How would you like your AI?' in short and '› 1  ChatGPT' in short and '2  Grok' in short and '3  Local with Ollama' in short and '4  More...' in short and 'Manual' not in short and '╭' not in short
            t.send('\x1b[B\x1b[B\x1b[B\r'); t.wait('Manual — no model needed'); t.ready()
            full=t.capture('onboarding-ai-expanded'); assert '› 1  Manual — no model needed' in full and '15  Fireworks AI' in full and '╭' not in full
            t.send('\r'); t.wait('Tasks   '); t.ready()
            settings=json.loads((root / 'arrows-onboarding' / 'config.json').read_text())
            assert settings['provider']=='manual'
            names={p.parent.name for p in (root / 'areas-tasks').rglob('.doin-folder.json')}
            assert {'Personal','Work','Someday'} <= names
            t.capture('onboarding-areas-persisted'); t.finish()
        finally: t.close(); active.remove(t)
    case('onboarding questions stay visible; template Escape and Back return to organization; expanded provider list includes Manual', onboarding_arrows)

    def onboarding_template_escape_custom():
        custom = onboarding_env('template-back-custom', root / 'template-back-tasks')
        t = start(custom_env=custom, cols=80, rows=24)
        try:
            storage_choice(t)
            t.wait('How would you like to organize your tasks?'); t.ready(); t.send('\x1b[B\x1b[B\r'); t.wait('Projects (Recommended) — Inbox, Projects, Archive'); t.ready()
            t.capture('onboarding-template-before-escape'); t.send('\x1b'); t.wait('How would you like to organize your tasks?'); t.ready()
            t.send('\x1b[B\r'); t.wait('Folder name [Inbox]'); t.ready(); t.send('Studio\r'); t.wait('First task [Enter to skip]'); t.ready(); t.send('Review the launch checklist\r')
            t.wait('How would you like your AI?'); t.ready(); t.send('\x1b[B\x1b[B\x1b[B\r'); t.wait('Manual — no model needed'); t.ready(); t.send('\r'); t.wait('Tasks   '); t.ready()
            config=json.loads((root / 'template-back-custom' / 'config.json').read_text()); assert config['provider']=='manual' and config['storage']==str(root / 'template-back-tasks' / 'Studio')
            assert 'Review the launch checklist' in (root / 'template-back-tasks' / 'Studio' / 'tasks.md').read_text()
            t.capture('onboarding-template-escape-custom-complete'); t.finish()
        finally: t.close(); active.remove(t)
    case('template Escape returns to organization so Custom folder and first task can complete', onboarding_template_escape_custom)

    def onboarding_resize_cancel():
        custom = onboarding_env('resize-onboarding', root / 'resize-tasks')
        t = start(custom_env=custom, cols=70, rows=28)
        try:
            storage_choice(t)
            t.wait('Simple (Recommended)'); t.ready(); t.resize(80, 16); t.pump(.3)
            resized=t.capture('onboarding-resize-recommended'); assert '› 1  Simple (Recommended)' in resized
            assert not (root / 'resize-onboarding' / 'config.json').exists()
            t.finish(sig=signal.SIGINT)
        finally: t.close(); active.remove(t)
    case('onboarding resize redraws recommendation; SIGINT restores terminal before saving', onboarding_resize_cancel)

    def provider_menu_resize():
        custom = dict(env, DOIN_CONFIG_DIR=str(root / 'provider-menu'))
        subprocess.run([str(binary), 'init', '--storage', str(storage), '--provider', 'manual'], env=custom, check=True, capture_output=True)
        before = (root / 'provider-menu' / 'config.json').read_bytes()
        t = start(custom_env=custom, cols=76, rows=16)
        try:
            t.ready(); t.send('/provider\r'); t.wait('AI provider'); t.ready()
            t.send('\x1b[B' * 3 + '\r'); t.wait('Manual — no model needed'); t.ready()
            t.send('\x1b[B' * 14); t.pump(.2)
            last = t.capture('provider-menu-last-option-short')
            assert '› 15  Fireworks AI' in last
            assert b'\x1b[1;0r' not in t.raw and b'\x1b[0;1H' not in t.raw
            for cols, rows in [(60, 12), (84, 28), (64, 16)]:
                offset = len(t.raw); t.resize(cols, rows); t.pump(.25)
                assert len(t.raw) - offset < 12000
                assert b'\x1b[1;0r' not in t.raw[offset:]
            t.capture('provider-menu-resized')
            t.send('\x1b'); t.pump(.2)
            assert (root / 'provider-menu' / 'config.json').read_bytes() == before
            offset = len(t.raw); t.ready(); t.send('/path\r'); t.wait('tasks.md', offset=offset)
            t.finish()
        finally: t.close(); active.remove(t)
    case('long provider menu scrolls, avoids zero-row margins, resizes with bounded redraw and cancels unchanged', provider_menu_resize)

    def local_catalog():
        custom = onboarding_env('local-onboarding', root / 'local-model-tasks')
        t = start(custom_env=custom)
        try:
            storage_choice(t)
            t.wait('How would you like to organize your tasks?'); t.ready(); t.send('\r'); t.wait('Local with Ollama'); t.ready(); t.send('3\r'); t.wait('API base URL'); t.ready()
            t.send(f'http://127.0.0.1:{server.server_port}\r'); t.wait('fixture-local'); t.ready()
            assert b'\x1b[2J' not in t.raw and b'local-catalog-title' not in t.raw
            t.send('fixture-local\r'); t.wait('Tasks   '); t.ready(); t.capture('local-catalog-sanitized'); t.finish()
        finally: t.close(); active.remove(t)
    case('local model catalog control sequences cannot clear the actual PTY or change its title', local_catalog)

    def voice():
        helper = root / 'voice-helper'
        helper.write_text('#!' + sys.executable + '\nimport json, os, termios\nfrom pathlib import Path\nPath(os.environ["VOICE_FLAGS"]).write_text(json.dumps(termios.tcgetattr(0)[:6]))\nprint("Review café voice draft")\n'); helper.chmod(0o700)
        custom = dict(env, DOIN_VOICE_COMMAND=str(helper), VOICE_FLAGS=str(root / 'voice-flags.json'))
        t = start(custom_env=custom)
        try:
            t.wait('Tasks   '); t.ready(); before = taskfile.read_bytes()
            t.send('/voice\r'); t.pump(.4); t.ready(); t.capture('voice-editable-draft')
            assert taskfile.read_bytes() == before
            flags = json.loads((root / 'voice-flags.json').read_text()); assert flags[3] & termios.ICANON and flags[3] & termios.ECHO
            t.send(b'\x01'); t.send('/add '); t.send(b'\x05'); t.send(' edited\r'); contents('Review café voice draft edited'); t.ready(); t.finish()
        finally: t.close(); active.remove(t)
    case('optional voice helper runs outside raw mode and only fills editable unsubmitted draft', voice)

    def account_menu():
        t = start()
        try:
            t.wait('Tasks   '); t.ready(); before = taskfile.read_bytes()
            offset = len(t.raw); t.send('/account\r'); t.wait('Your account', offset); t.wait('Account action', offset); t.ready()
            screen = t.capture('account-menu'); assert all(label in screen for label in ('Export cloud Markdown', 'Resume renewal', 'Repair payment', 'Delete account'))
            t.send('\r'); t.pump(.2); t.ready()
            offset = len(t.raw); t.send('/account\r'); t.wait('Account action', offset); t.ready(); t.send('1\r'); t.wait('Email', offset); t.ready()
            assert t.raw_mode(), 'Email entry bypassed native composer'
            t.send('unfinished@example'); t.send(b'\x1b[D\x7f'); t.capture('account-email-editing'); t.finish()
            assert taskfile.read_bytes() == before, 'Account interaction changed tasks'
        finally: t.close(); active.remove(t)
    case('account menu back navigation and native email editing/cancellation preserve tasks and terminal', account_menu)

    def processing_signal():
        custom=dict(env,DOIN_CONFIG_DIR=str(root/'signal-config'))
        subprocess.run([str(binary),'init','--storage',str(storage),'--provider','ollama','--model','fixture-local','--endpoint',f'http://127.0.0.1:{server.server_port}'],env=custom,check=True,capture_output=True)
        t=start(custom_env=custom)
        try:
            t.wait('Tasks   '); t.ready(); before=taskfile.read_bytes(); offset=len(t.raw); t.send('/ask slow footer fixture\r')
            t.pump(.3); view=t.capture('processing-fixed-footer'); assert '╭' in view.splitlines()[-4] and 'Working' in view.splitlines()[-1]
            children=subprocess.run(['pgrep','-P',str(t.process.pid)],capture_output=True,text=True).stdout.split(); assert children,'Provider child absent from slow fixture'
            os.kill(t.process.pid,signal.SIGTERM); t.pump(.3); assert b'\x1b[r' in t.raw[offset:],'Margins not reset immediately'
            t.process.wait(timeout=5); t.finish(); assert taskfile.read_bytes()==before
            for pid in children:
                try: os.kill(int(pid),0)
                except ProcessLookupError: continue
                raise AssertionError('Owned curl survived signal exit')
        finally: t.close(); active.remove(t)
    case('SIGTERM during actual slow HTTP restores margins immediately, reaps curl, keeps tasks and never reopens input',processing_signal)

    def footer_chart_login():
        original=taskfile.read_bytes(); taskfile.write_text(''.join(f'# Group {i}\n- [ ] Task {i} 東京\n' for i in range(25)))
        t=start(cols=80,rows=24)
        try:
            t.wait('Tasks   '); t.ready(); offset=len(t.raw); t.send('/visualize\r'); t.wait('←→ select group',offset); t.ready()
            view=t.capture('many-groups-chart-footer'); assert 'Completion' in view and '╭' in view.splitlines()[-4]
            t.send('\r'); t.pump(.2); t.ready(); t.finish()
        finally: t.close(); active.remove(t); taskfile.write_bytes(original)
        custom=dict(env,DOIN_CONFIG_DIR=str(root/'poll-config'),DOIN_SYNC_ENDPOINT=f'http://127.0.0.1:{server.server_port}')
        subprocess.run([str(binary),'init','--storage',str(storage),'--provider','manual'],env=custom,check=True,capture_output=True)
        service_state['slow_poll']=True; slow_poll_started.clear(); t=start(custom_env=custom)
        try:
            t.wait('Tasks   '); t.ready(); before=taskfile.read_bytes(); offset=len(t.raw); t.send(f'/account login --endpoint http://127.0.0.1:{server.server_port}\r'); t.wait('Email',offset); t.ready(); t.send('footer@example.test\r'); t.wait('Waiting for verification',offset); assert slow_poll_started.wait(5),'Email poll did not reach fixture'; t.pump(.1)
            children=subprocess.run(['pgrep','-P',str(t.process.pid)],capture_output=True,text=True).stdout.split(); assert children
            t.capture('email-poll-fixed-footer'); os.kill(t.process.pid,signal.SIGTERM); t.pump(.3); assert b'\x1b[r' in t.raw[offset:]; t.process.wait(timeout=5); t.finish(); assert taskfile.read_bytes()==before
            for pid in children:
                try: os.kill(int(pid),0)
                except ProcessLookupError: continue
                raise AssertionError('Email curl survived cancellation')
        finally: t.close(); active.remove(t); service_state.pop('slow_poll',None)
    case('many-group chart uses output-region height; interrupted email poll restores footer session and reaps curl',footer_chart_login)

    def footer_startup_resize():
        t=start(cols=80,rows=12)
        try:
            t.wait('Enter submit'); t.ready(); t.send('startup draft')
            t.resize(122,40); t.pump(.4); t.ready()
            screen=t.capture('startup-grow-single-footer')
            assert screen.count('╭')==1 and screen.count('Enter submit')==1, 'Stale composer survived startup growth'
            assert 'startup draft' in screen.splitlines()[-3] and '╭' in screen.splitlines()[-4]
            assert screen.splitlines()[-4].count('─')==116, 'Composer did not span new viewport width'
            t.resize(68,26); t.pump(.4); t.ready(); screen=t.capture('startup-grow-shrink-single-footer')
            assert screen.count('╭')==1 and 'startup draft' in screen.splitlines()[-3]
            t.finish()
        finally: t.close(); active.remove(t)
    case('startup 12-to-40-row growth clears previous composer; width and draft survive subsequent shrink',footer_startup_resize)

    def repeated_short_prompts():
        t=start(cols=90,rows=30)
        try:
            t.wait('Enter submit'); t.ready(); offset=len(t.raw)
            t.resize(23,11); t.pump(.4); assert t.raw_mode(),'Short session cannot observe growth while waiting for input'
            offset=len(t.raw); t.send('/path\n'); t.wait('tasks.md',offset); t.pump(.2)
            offset=len(t.raw); t.send('/path\n'); t.wait('tasks.md',offset); t.pump(.2)
            visible=t.capture('short-repeated-prompts-preserve-output')
            assert ''.join(visible.splitlines()).count('tasks.md')>=2, 'Unchanged short prompt erased prior visible output'
            t.finish(b'/quit\n')
        finally: t.close(); active.remove(t)
    case('rich-to-short fallback keeps repeated unchanged-size prompt output visible',repeated_short_prompts)

    def footer_idle():
        custom = dict(env, DOIN_CONFIG_DIR=str(root / 'empty-config'))
        empty_store=root/'empty-store'
        subprocess.run([str(binary),'init','--storage',str(empty_store),'--provider','manual'],env=custom,check=True,capture_output=True)
        t=start(custom_env=custom)
        try:
            t.wait('Tasks   '); t.ready(); t.pump(.3); first=t.capture('empty-orbit-frame-one'); t.pump(.4); second=t.capture('empty-orbit-frame-two')
            assert first!=second and 'd o i n' in second
            assert 'Tasks   0 open · 0 done' in second and 'Manual · AI off' in second and 'File' in second
            assert 'Nothing here yet' not in second and 'Type a task, ask' not in second
            assert '╭' in second.splitlines()[-4] and 'Enter submit' in second.splitlines()[-1]
            t.send('draft'); t.pump(.2); stopped=len(t.raw); t.pump(.5); assert len(t.raw)==stopped,'Idle animation continued while typing'
            assert 'd o i n' not in t.capture('empty-draft-art-cleared')
            t.resize(88,38); t.pump(.4); t.ready(); resized=t.capture('height-only-resize-footer'); assert 'draft' in resized.splitlines()[-3] and '╭' in resized.splitlines()[-4]
            t.resize(20,10); t.pump(.3); assert t.raw_mode(); offset=len(t.raw); t.resize(88,32); t.wait('Enter submit',offset); t.ready(); restored=t.capture('small-to-large-footer'); assert '╭' in restored.splitlines()[-4] and 'draft' in restored.splitlines()[-3]
            t.send(b'\x15/help\r'); t.wait('tiny Markdown tasks'); t.ready(); long_screen=t.capture('long-help-fixed-footer'); assert '╭' in long_screen.splitlines()[-4] and 'Enter submit' in long_screen.splitlines()[-1]
            t.finish(); assert b'\x1b[r' in t.raw
        finally: t.close(); active.remove(t)
        (empty_store/'tasks.md').write_text('# Tasks\n\nJust a note with no checkboxes.\n')
        t=start(custom_env=custom)
        try:
            t.wait('Tasks   '); t.ready(); t.pump(.5); assert 'd o i n' not in t.capture('notes-only-no-art'); t.finish()
        finally: t.close(); active.remove(t)
        (empty_store/'tasks.md').write_text('# Tasks\n\n')
        t=start(custom_env=dict(custom,DOIN_NO_ANIMATION='1'))
        try:
            t.wait('Tasks   '); t.ready(); t.wait('d o i n'); t.pump(.2); before=len(t.raw); t.pump(.5); assert len(t.raw)==before; t.capture('no-animation-poster'); t.finish()
        finally: t.close(); active.remove(t)
    case('empty orbit stays in place and stops on typing; footer survives help and height-only resize; notes and no-motion respected', footer_idle)

    def status_workflow():
        original = taskfile.read_bytes()
        custom = dict(env, DOIN_CONFIG_DIR=str(root / 'status-config'))
        subprocess.run([str(binary), 'init', '--storage', str(storage), '--provider', 'ollama', '--model', 'fixture-local', '--endpoint', f'http://127.0.0.1:{server.server_port}'], env=custom, check=True, capture_output=True)
        taskfile.write_text('# Work\n- [ ] Launch @due(2020-01-01)\n- [x] Delivered @status(blocked)\n- [ ] Waiting @status(blocked)\n')
        t = start(custom_env=custom)
        try:
            t.wait('Tasks   '); t.ready()
            offset=len(t.raw); t.send('/mark 1 doing\r'); t.wait('→ doing', offset); t.ready(); assert '@status(doing)' in taskfile.read_text()
            offset=len(t.raw); t.send('/status doing\r'); t.wait('Tasks — status: doing', offset); t.ready(); assert 'Launch' in t.capture('status-doing')
            offset=len(t.raw); t.send('/today\r'); t.wait('Due today', offset); t.ready(); t.capture('due-today')
            offset=len(t.raw); t.send('/statuses add waiting\r'); t.wait('Apply status changes?', offset); t.ready(); t.send('y\r'); t.pump(.2); t.ready()
            offset=len(t.raw); t.send('/mark 3 waiting\r'); t.wait('→ waiting', offset); t.ready()
            offset=len(t.raw); t.send('/status waiting\r'); t.wait('Tasks — status: waiting', offset); t.ready(); t.capture('custom-status-waiting'); assert '@status(waiting)' in taskfile.read_text()
            before=taskfile.read_bytes(); offset=len(t.raw); t.send('/unblock 3 waiting for supplier\r'); t.wait('Review migration before launch', offset); t.ready(); t.capture('unblock-read-only'); assert taskfile.read_bytes()==before
            assert 'waiting for supplier' in requests[-1]['messages'][1]['content'] and 'Do not invent dependencies' in requests[-1]['messages'][1]['content']
            offset=len(t.raw); t.send('/mark 1 nonsense\r'); t.wait('Use a registered status', offset); t.ready(); assert taskfile.read_bytes()==before
            t.finish()
        finally: t.close(); active.remove(t); taskfile.write_bytes(original)
    case('status and local due views, invalid status, and selected-task unblock AI remain explicit and read-only', status_workflow)

    def plain():
        result = subprocess.run([str(binary), 'list'], env=dict(env, NO_COLOR='1'), capture_output=True, check=True)
        assert b'\x1b' not in result.stdout and b'Model' in result.stdout and b'Review migration' in result.stdout
        t = start(custom_env=dict(env, NO_COLOR='1'), cols=40, rows=24)
        try:
            t.wait('Tasks   '); assert not t.raw_mode(); t.capture('no-color'); t.finish(b'/quit\n'); assert b'\x1b' not in t.raw
        finally: t.close(); active.remove(t)
        t = start(custom_env=dict(env, TERM='dumb'), cols=20, rows=15)
        try:
            t.wait('Tasks   '); assert not t.raw_mode(); t.finish(b'/quit\n'); assert b'\x1b' not in t.raw
        finally: t.close(); active.remove(t)
    case('NO_COLOR, dumb narrow terminal, and piped CLI output remain plain', plain)
    def network_boundary():
        assert guard_log.read_text()=="blocked\n", "Application attempted external network"
        browser_attempts=[json.loads(line) for line in browser_guard_log.read_text().splitlines()]
        assert browser_attempts==[{'command':'open','argv':['https://example.invalid']}], "An application case attempted to launch a real browser"
    case("network and browser guards reject nonfixture destinations; app cases make no unexpected browser attempts",network_boundary)
    for terminal in active: terminal.close()
server.shutdown(); server.server_close(); thread.join(timeout=5)
report = {'binary': str(binary), 'sha256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'binary_bytes': binary.stat().st_size, 'cases': cases, 'captures': captures, 'requests': requests, 'service_calls': service_calls, 'terminal_restorations': restorations}
(artifacts / 'results.json').write_text(json.dumps(report, indent=2))
(artifacts / 'README.md').write_text('# Real PTY evidence\n\nRun `python3 tests/tui_e2e.py --bin zig-out/bin/doin`. SVG files render the screen decoded from each raw ANSI transcript; text files contain the same screen cells. No screenshots are fabricated from layout code. Provider/microphone fixtures test adapters, not real account consent or microphone capture.\n\n' + '\n'.join(f"- [{c['name']}]({c['screen']}) at {c['columns']} columns × {c['rows']} rows." for c in captures) + '\n')
for c in cases: print(('PASS ' if c['passed'] else 'FAIL ') + c['name'])
if args.case and not cases: raise SystemExit(f'No E2E case named {args.case!r}')
print(f'Binary: {binary.stat().st_size} bytes; evidence: {artifacts}')
raise SystemExit(0 if all(c['passed'] for c in cases) else 1)
