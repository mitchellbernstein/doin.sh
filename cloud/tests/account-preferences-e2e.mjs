import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { build } from 'esbuild';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';

const root = new URL('../', import.meta.url);
const temp = await mkdtemp(join(tmpdir(), 'doin-account-preferences-e2e-'));
const checks = [];
const failureCoverage = [
  'missing, malformed, expired, revoked and wrong-account authentication',
  'account isolation, including preference row missing on first write',
  'default reads for accounts before and after migration; free account access',
  'strict request shape, JSON content type, malformed values and uppercase normalization',
  'concurrent first-write and stale-revision CAS behavior',
  'same-value idempotent retry and stale replay cannot overwrite a newer revision',
  'reset-to-default revision and account-deletion cascade',
  'unsupported methods and closing-account write denial',
];
const pass = name => { checks.push(name); console.log(`PASS ${name}`); };
let complete = false;
let failure = null;
let mf;

try {
  const source = await readFile(new URL('worker.ts', root), 'utf8');
  await build({ stdin: { contents: source, loader: 'ts', resolveDir: root.pathname }, outfile: join(temp, 'worker.mjs'), bundle: true, external: ['cloudflare:workers'], format: 'esm', platform: 'browser' });
  mf = new Miniflare(convertV4MiniflareOptions({ workers: [{
    name: 'account-preferences-e2e', modules: true,
    script: await readFile(join(temp, 'worker.mjs'), 'utf8'), compatibilityDate: '2026-10-01',
    d1Databases: ['DB'], kvNamespaces: ['OAUTH_KV'],
    bindings: { ORIGIN: 'https://sync.doin.sh', EMAIL_ENABLED: 'false', EMAIL_FROM: 'login@doin.sh', STRIPE_SECRET_KEY: 'sk_test_fixture', STRIPE_WEBHOOK_SECRET: 'whsec_fixture', STRIPE_PRICE_ID: 'price_sync', STRIPE_MONTHLY_PRICE_ID: 'price_month', STRIPE_YEARLY_PRICE_ID: 'price_year' },
    outboundService: async request => new Response(`unexpected outbound request: ${request.url}`, { status: 599 }),
  }] }));
  const db = await mf.getD1Database('DB');
  const migrations = (await readdir(new URL('migrations/', root))).filter(name => /^\d+\.sql$/.test(name)).sort();
  const now = Math.floor(Date.now() / 1000);
  const tokens = { alice: 'a'.repeat(64), bob: 'b'.repeat(64), postMigration: 'c'.repeat(64), expired: 'd'.repeat(64), closing: 'e'.repeat(64), revoked: 'f'.repeat(64), browser: '1'.repeat(64), maxrev: '2'.repeat(64) };
  const seed = async (id, token) => {
    await db.prepare('INSERT INTO accounts(id,identity_key,email,name,created_at) VALUES(?,?,?,?,?)').bind(id, id, `${id}@example.test`, id, now).run();
    await db.prepare("INSERT INTO sessions(token_hash,account_id,kind,name,csrf,expires_at) VALUES(?,?,'device','E2E','',?)").bind(createHash('sha256').update(token).digest('hex'), id, now + 3600).run();
  };
  for (const migration of migrations.filter(name => name < '0011.sql')) await db.exec((await readFile(new URL(`migrations/${migration}`, root), 'utf8')).replaceAll('\n', ' '));
  await seed('alice', tokens.alice);
  await seed('bob', tokens.bob);
  await seed('expired', tokens.expired);
  await seed('closing', tokens.closing);
  await seed('revoked', tokens.revoked);
  await seed('browser', tokens.browser);
  await seed('maxrev', tokens.maxrev);
  await db.prepare("UPDATE sessions SET kind='browser' WHERE token_hash=?").bind(createHash('sha256').update(tokens.browser).digest('hex')).run();
  await db.prepare('DELETE FROM sessions WHERE token_hash=?').bind(createHash('sha256').update(tokens.revoked).digest('hex')).run();
  for (const migration of migrations.filter(name => name >= '0011.sql')) await db.exec((await readFile(new URL(`migrations/${migration}`, root), 'utf8')).replaceAll('\n', ' '));
  await db.prepare('UPDATE sessions SET expires_at=0 WHERE token_hash=?').bind(createHash('sha256').update(tokens.expired).digest('hex')).run();
  await db.prepare('UPDATE accounts SET closing_at=? WHERE id=?').bind(now, 'closing').run();

  const base = 'https://sync.doin.sh';
  const request = (path, token, init = {}) => mf.dispatchFetch(base + path, {
    ...init,
    headers: { ...(init.body !== undefined ? { 'content-type': 'application/json' } : {}), ...(token ? { authorization: `Bearer ${token}` } : {}), ...init.headers },
  });
  const json = async (response, status = 200) => {
    assert.equal(response.status, status, await response.clone().text());
    return response.json();
  };
  const prefs = '/v1/account/preferences';
  const read = (token, status = 200) => request(prefs, token).then(response => json(response, status));
  const putRaw = (token, accent, revision) => request(prefs, token, { method: 'PUT', body: JSON.stringify({ accent, revision }) });
  const put = (token, accent, revision, status = 200) => putRaw(token, accent, revision).then(response => json(response, status));

  assert.equal((await request(prefs, null)).status, 401);
  assert.equal((await request(prefs, '9'.repeat(64))).status, 401);
  assert.equal((await request(prefs, tokens.expired)).status, 401);
  assert.equal((await request(prefs, tokens.revoked)).status, 401);
  assert.equal((await request(prefs, tokens.browser)).status, 401);
  assert.deepEqual(await read(tokens.alice), { accent: null, revision: 0 });
  assert.deepEqual(await read(tokens.bob), { accent: null, revision: 0 });
  assert.equal(await db.prepare('SELECT count(*) AS n FROM subscriptions WHERE account_id IN (?,?)').bind('alice', 'bob').first().then(row => row.n), 0, 'preference reads and writes are available without paid subscriptions');
  pass('authentication boundary, migration defaults, account isolation and free access');

  const beforeInvalid = await read(tokens.alice);
  assert.equal((await request(prefs, tokens.alice, { method: 'PATCH' })).status, 405);
  assert.equal((await request(prefs, tokens.alice, { method: 'PUT', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: 'accent=%23abcdef&revision=0' })).status, 415);
  assert.equal((await request(prefs, tokens.alice, { method: 'PUT', headers: { 'content-type': 'application/json' }, body: '{' })).status, 400);
  for (const value of [
    { accent: '#abcdef', revision: 0, extra: true },
    { revision: 0 },
    { accent: '#abc', revision: 0 },
    { accent: '#12345g', revision: 0 },
    { accent: 'default', revision: 0 },
    { accent: 4, revision: 0 },
    { accent: null, revision: -1 },
    { accent: null, revision: 0.5 },
    { accent: null, revision: Number.MAX_SAFE_INTEGER + 1 },
  ]) {
    assert.equal((await request(prefs, tokens.alice, { method: 'PUT', body: JSON.stringify(value) })).status, 400, JSON.stringify(value));
  }
  assert.deepEqual(await read(tokens.alice), beforeInvalid, 'invalid input must not mutate value or revision');
  assert.deepEqual(await put(tokens.alice, '#abcdef', 0), { accent: '#ABCDEF', revision: 1 });
  assert.deepEqual(await json(await request(`${prefs}?account_id=bob`, tokens.alice)), { accent: '#ABCDEF', revision: 1 }, 'caller cannot select a different account through query input');
  assert.deepEqual(await read(tokens.bob), { accent: null, revision: 0 }, 'one account token cannot read another account preference');
  pass('strict input validation and canonical hex response');

  // Simulate a missing legacy row: concurrent initial writes still use one atomic CAS.
  await db.prepare('DELETE FROM account_preferences WHERE account_id=?').bind('bob').run();
  await db.prepare('INSERT INTO account_preferences(account_id,accent,revision,updated_at) VALUES(?,?,?,?)').bind('maxrev', null, Number.MAX_SAFE_INTEGER - 1, now).run();
  assert.deepEqual(await read(tokens.bob), { accent: null, revision: 0 });
  const outcomes = await Promise.all([putRaw(tokens.bob, '#112233', 0), putRaw(tokens.bob, '#445566', 0)]);
  assert.deepEqual(outcomes.map(response => response.status).sort(), [200, 409]);
  const successResponse = outcomes.find(response => response.status === 200);
  const conflictResponse = outcomes.find(response => response.status === 409);
  const winner = await successResponse.json();
  assert.deepEqual(await conflictResponse.json(), { error: 'preferences_conflict', preferences: winner });
  assert.equal(winner.revision, 1);
  assert.deepEqual(await read(tokens.bob), winner);
  const retry = await put(tokens.bob, winner.accent, 0);
  assert.deepEqual(retry, winner, 'retry of the just-committed value is idempotent');
  const changed = await put(tokens.bob, winner.accent === '#112233' ? '#445566' : '#112233', 1);
  assert.equal(changed.revision, 2);
  const stale = await request(prefs, tokens.bob, { method: 'PUT', body: JSON.stringify({ accent: winner.accent, revision: 0 }) });
  assert.equal(stale.status, 409);
  assert.deepEqual(await stale.json(), { error: 'preferences_conflict', preferences: changed });
  assert.deepEqual(await read(tokens.bob), changed, 'stale retry cannot replace newer revision');
  assert.deepEqual(await put(tokens.bob, null, 2), { accent: null, revision: 3 });
  pass('atomic first-write CAS, conflict payload, retry idempotence and reset');

  assert.deepEqual(await put(tokens.maxrev, '#123456', Number.MAX_SAFE_INTEGER - 1), { accent: '#123456', revision: Number.MAX_SAFE_INTEGER });
  assert.deepEqual(await read(tokens.maxrev), { accent: '#123456', revision: Number.MAX_SAFE_INTEGER });
  assert.equal((await putRaw(tokens.maxrev, '#654321', Number.MAX_SAFE_INTEGER)).status, 400, 'revision exhaustion must be rejected before mutation');
  assert.deepEqual(await read(tokens.maxrev), { accent: '#123456', revision: Number.MAX_SAFE_INTEGER });
  pass('safe-integer revision ceiling is readable and cannot overflow');

  await seed('created-after-migration', tokens.postMigration);
  assert.deepEqual(await read(tokens.postMigration), { accent: null, revision: 0 });
  assert.deepEqual(await put(tokens.postMigration, '#00aaFF', 0), { accent: '#00AAFF', revision: 1 });
  assert.equal((await request(prefs, tokens.closing, { method: 'PUT', body: JSON.stringify({ accent: '#FF0000', revision: 0 }) })).status, 409);
  await db.prepare('DELETE FROM accounts WHERE id=?').bind('created-after-migration').run();
  assert.equal(await db.prepare('SELECT account_id FROM account_preferences WHERE account_id=?').bind('created-after-migration').first(), null, 'deleting an account cascades preferences');
  complete = true;
  pass('post-migration account, closing-account fence and deletion cascade');
} catch (error) {
  failure = error instanceof Error ? { name: error.name, message: error.message, stack: error.stack } : String(error);
  throw error;
} finally {
  if (mf) await mf.dispose();
  await mkdir(new URL('artifacts/account-theme/', root), { recursive: true });
  await writeFile(new URL('artifacts/account-theme/preferences-e2e.json', root), JSON.stringify({
    command: 'cd cloud && node tests/account-preferences-e2e.mjs',
    date: new Date().toISOString(), node: process.version, complete, checks, failureCoverage, failure,
    secrets: 'Fixture bearer tokens omitted from the report.',
  }, null, 2));
  await rm(temp, { recursive: true, force: true });
}
