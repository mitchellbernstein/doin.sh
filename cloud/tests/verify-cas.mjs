import assert from 'node:assert/strict';
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const root = new URL('../', import.meta.url);
const temp = await mkdtemp(join(tmpdir(), 'doin-cas-defect-'));
try {
  const source = await readFile(new URL('worker.ts', root), 'utf8');
  assert.ok(source.includes('AND revision=? RETURNING'));
  const broken = source.replace('AND revision=? RETURNING', 'AND revision>=? RETURNING');
  const path = join(temp, 'worker.ts');
  await writeFile(path, broken);
  let detected = false, output = '';
  try {
    await promisify(execFile)(process.execPath, [new URL('tests/e2e.mjs', root).pathname], { cwd: root.pathname, env: { ...process.env, WORKER_SOURCE: path, TEST_ARTIFACT: 'cas-defect.json' } });
  } catch (error) {
    output = error.stderr;
    detected = /AssertionError/.test(output) && /409/.test(output);
  }
  assert.ok(detected, 'E2E must reject a stale writer when the CAS guard is broken');
  await writeFile(new URL('artifacts/cas-mutation.json', root), JSON.stringify({ command: 'cd cloud && node tests/verify-cas.mjs', defect: 'allow a stale revision to overwrite current content', detected, failure: output }, null, 2));
  console.log('PASS E2E detects stale-writer overwrite defect');
} finally {
  await rm(temp, { recursive: true, force: true });
}
