"""Real browser native-form regression. Run, open /, submit, inspect artifact.

Probe uses the deployed source's policy, exact Origin guard, and no real email.
Before fix: Origin:null rejected. After fix: own origin accepted, token query
never appears in Referer. Cross-origin and null POST remain rejected.
"""
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import json, re

ROOT = Path(__file__).resolve().parents[1]
PORT = 8793
ORIGIN = f'http://127.0.0.1:{PORT}'
POLICY = re.search(r"headers.set\('referrer-policy', '([^']+)'\)", (ROOT / 'worker.ts').read_text()).group(1)
ARTIFACT = ROOT / 'artifacts/browser-origin.json'
records = json.loads(ARTIFACT.read_text())['records'] if ARTIFACT.exists() else []

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
        self.send_header('Referrer-Policy', POLICY)
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(b'<h1>Native form origin regression</h1><form method="post" action="/confirm"><button>Confirm probe</button></form>')
    def do_POST(self):
        origin = self.headers.get('Origin')
        referrer = self.headers.get('Referer')
        accepted = origin == ORIGIN
        record = {'policy': POLICY, 'origin': origin, 'referrer': referrer, 'accepted': accepted,
                  'token_leaked': bool(referrer and 'synthetic-token' in referrer)}
        records.append(record)
        ARTIFACT.parent.mkdir(exist_ok=True)
        ARTIFACT.write_text(json.dumps({'command': 'python3 tests/browser-origin-probe.py', 'records': records}, indent=2))
        self.send_response(200 if accepted else 403)
        self.send_header('Content-Type', 'text/plain')
        self.end_headers()
        self.wfile.write(json.dumps(record).encode())

print(json.dumps({'ready': True, 'url': ORIGIN + '/?token=synthetic-token', 'policy': POLICY}), flush=True)
HTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
