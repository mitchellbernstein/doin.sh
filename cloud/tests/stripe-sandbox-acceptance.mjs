#!/usr/bin/env node
// Real Stripe test-mode lifecycle acceptance for the actual exported Worker.
// Never execute with live credentials. See stripe-acceptance/README.md.
import assert from 'node:assert/strict';
import { createHash, createHmac, randomBytes, randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { build } from 'esbuild';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const VERSION = '2025-03-31.basil';
const HERE = dirname(fileURLToPath(import.meta.url));
const CLOUD = resolve(HERE, '..');
const ARTIFACT_DIR = resolve(CLOUD, 'tests/artifacts/stripe-sandbox-acceptance');
const PRICE_NAMES = ['STRIPE_MONTHLY_PRICE_ID', 'STRIPE_YEARLY_PRICE_ID', 'STRIPE_TEAM_PRICE_ID'];
const WAIT_LIMIT_MS = 120_000;
const INTERVAL = 1_000;
const checkRows = [];
const redacted = (id) => typeof id === 'string' && id.length > 12 ? `${id.slice(0, 7)}…${id.slice(-3)}` : 'redacted';
const safeError = (error) => (error instanceof Error ? error.message : 'Unexpected failure; details omitted.')
  .replace(/(?:sk|rk)_(?:test|live)_[A-Za-z0-9]+/g, '[redacted-key]')
  .replace(/whsec_[A-Za-z0-9]+/g, '[redacted-webhook-secret]')
  .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, '[redacted-email]')
  .replace(/https:\/\/checkout\.stripe\.com\S*/g, '[redacted-checkout-url]')
  .replace(/\b(?:cus|sub|cs|evt|in|price|clock|pm|pi)_[A-Za-z0-9]+\b/g, '[redacted-id]');
const customerOwnedByRun = (customer, data) => customer?.livemode === false && (
  customer.metadata?.doin_acceptance_run === data.run_id
  || Object.values(data.accounts || {}).some((a) => a.id === customer.metadata?.account_id)
  || (data.teams || []).some((t) => t.id === customer.metadata?.team_id)
);
const pass = (name, evidence = {}) => { checkRows.push({ name, status: 'PASS', ...evidence }); console.log(`PASS ${name}`); };
const now = () => Math.floor(Date.now() / 1000);
const timeout = (ms) => new Promise((_, reject) => setTimeout(() => reject(new Error('Timed out waiting for Stripe or local Worker state.')), ms));
let worker;
let cli;
let cliOwnsProcessGroup = false;
let apiKey = '';
let manifest;
let manifestPath;
let cliSecret = '';
let cliLog = '';
const cliDeliveries = new Map();
let report;
let failed = false;
const cleanupIssues = [];

function parseDevVars(raw) {
  for (const line of raw.split(/\r?\n/)) {
    const match = /^\s*(STRIPE_SECRET_KEY|STRIPE_MONTHLY_PRICE_ID|STRIPE_YEARLY_PRICE_ID|STRIPE_TEAM_PRICE_ID)\s*=\s*(.*?)\s*$/.exec(line);
    if (!match || process.env[match[1]]) continue;
    let value = match[2];
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) value = value.slice(1, -1);
    process.env[match[1]] = value;
  }
}

async function loadCredentials() {
  if (!process.env.STRIPE_SECRET_KEY || PRICE_NAMES.some((name) => !process.env[name])) {
    try { parseDevVars(await readFile(join(CLOUD, '.dev.vars'), 'utf8')); } catch { /* Report missing names below. */ }
  }
  if (PRICE_NAMES.some((name) => !process.env[name])) {
    // These values are already configured for the sandbox in wrangler.jsonc.
    // Read only the three Price IDs; ignore all unrelated config and secrets.
    const config = await readFile(join(CLOUD, 'wrangler.jsonc'), 'utf8').catch(() => '');
    for (const name of PRICE_NAMES) {
      if (process.env[name]) continue;
      const match = new RegExp(`^[ \\t]*"${name}"[ \\t]*:[ \\t]*"(price_[A-Za-z0-9]+)"`, 'm').exec(config);
      if (match) process.env[name] = match[1];
    }
  }
  const missing = ['STRIPE_SECRET_KEY', ...PRICE_NAMES].filter((name) => !process.env[name]);
  if (missing.length) throw new Error(`Missing Stripe test configuration variables: ${missing.join(', ')}. No Stripe mutation made.`);
  apiKey = process.env.STRIPE_SECRET_KEY;
  if (!/^sk_test_[A-Za-z0-9]+$/.test(apiKey)) throw new Error('STRIPE_SECRET_KEY must be a full sk_test_ key. No Stripe request made.');
  for (const name of PRICE_NAMES) if (!/^price_[A-Za-z0-9]+$/.test(process.env[name])) throw new Error(`${name} must be a Stripe Price ID. No Stripe mutation made.`);
}

async function stripe(path, { method = 'GET', fields, idempotencyKey, tolerateMissing = false } = {}) {
  const url = new URL(`/v1/${path.replace(/^\//, '')}`, 'https://api.stripe.com');
  const response = await fetch(url, {
    method,
    signal: AbortSignal.timeout(20_000),
    headers: {
      Authorization: `Bearer ${apiKey}`,
      'Stripe-Version': VERSION,
      ...(fields ? { 'content-type': 'application/x-www-form-urlencoded' } : {}),
      ...(idempotencyKey ? { 'idempotency-key': idempotencyKey } : {}),
    },
    body: fields ? new URLSearchParams(fields) : undefined,
    redirect: 'manual',
  });
  if (response.status >= 300 && response.status < 400) throw new Error('Stripe API redirected unexpectedly; response omitted.');
  const data = await response.json().catch(() => ({}));
  if (!response.ok && !(tolerateMissing && response.status === 404)) {
    const kind = data?.error?.type || `http_${response.status}`;
    throw new Error(`Stripe API ${method} ${url.pathname} failed (${kind}); response body omitted.`);
  }
  return response.ok ? data : null;
}

async function saveManifest() {
  await mkdir(dirname(manifestPath), { recursive: true });
  await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o600 });
  await chmod(manifestPath, 0o600);
}

async function managedWrite(name, path, fields, { method = 'POST' } = {}) {
  const idem = manifest.idempotency[name] || `doin-billing-acceptance-${manifest.run_id}-${name}`;
  manifest.idempotency[name] = idem;
  manifest.recovery[name] = { method, path, kind: name };
  await saveManifest();
  return stripe(path, { method, fields, idempotencyKey: idem });
}

async function getPrice(id, expected) {
  const p = await stripe(`prices/${encodeURIComponent(id)}`);
  assert.equal(p.id, id);
  assert.equal(p.livemode, false, 'Price must be test-mode');
  assert.equal(p.active, true);
  assert.equal(p.type, 'recurring');
  assert.equal(p.currency, 'usd');
  assert.equal(p.unit_amount, expected.amount);
  assert.equal(p.recurring?.interval, expected.interval);
  assert.equal(p.recurring?.interval_count, 1);
  if (expected.usage) assert.equal(p.recurring?.usage_type, expected.usage);
  return p;
}

async function preflight() {
  await loadCredentials();
  const prices = {
    month: await getPrice(process.env.STRIPE_MONTHLY_PRICE_ID, { amount: 499, interval: 'month' }),
    year: await getPrice(process.env.STRIPE_YEARLY_PRICE_ID, { amount: 4999, interval: 'year' }),
    team: await getPrice(process.env.STRIPE_TEAM_PRICE_ID, { amount: 9900, interval: 'year', usage: 'licensed' }),
  };
  pass('pinned Stripe test-mode Price preflight', { api_version: VERSION, prices: Object.fromEntries(Object.entries(prices).map(([k, p]) => [k, { id: redacted(p.id), livemode: p.livemode, amount: p.unit_amount, currency: p.currency, interval: p.recurring.interval }])) });
  return prices;
}

async function freePort() {
  const server = createServer();
  await new Promise((resolveListen, reject) => server.once('error', reject).listen(0, '127.0.0.1', resolveListen));
  const address = server.address();
  const port = address.port;
  await new Promise((resolveClose, reject) => server.close((e) => e ? reject(e) : resolveClose()));
  return port;
}

function listenToStripe(port) {
  const bin = process.env.STRIPE_CLI_BIN || 'stripe';
  cliOwnsProcessGroup = process.platform !== 'win32';
  cli = spawn(bin, ['listen', '--forward-to', `http://127.0.0.1:${port}/webhooks/stripe`], {
    cwd: CLOUD,
    env: { ...process.env, STRIPE_API_KEY: apiKey },
    stdio: ['ignore', 'pipe', 'pipe'],
    detached: cliOwnsProcessGroup,
  });
  let carry = '';
  let readyResolve;
  let readyReject;
  const ready = new Promise((resolveReady, rejectReady) => { readyResolve = resolveReady; readyReject = rejectReady; });
  const collect = (chunk) => {
    const text = String(chunk);
    carry = (carry + text).slice(-32_000);
    cliLog = (cliLog + text).slice(-64_000);
    const delivered = /<--\s+\[(\d{3})\]\s+POST\s+https?:\/\/[^\s]+\s+\[(evt_[A-Za-z0-9]+)\]/g;
    for (const match of cliLog.matchAll(delivered)) cliDeliveries.set(match[2], Number(match[1]));
    const secret = /whsec_[A-Za-z0-9]+/.exec(carry)?.[0];
    if (secret) { cliSecret = secret; readyResolve(); }
  };
  cli.stdout.on('data', collect);
  cli.stderr.on('data', collect);
  cli.once('error', () => readyReject(new Error('Stripe CLI could not start; no provider object has been created.')));
  cli.once('exit', (code) => { if (!cliSecret) readyReject(new Error(`Stripe CLI exited before listener readiness (status ${code ?? 'unknown'}).`)); });
  return Promise.race([ready, timeout(30_000)]).catch(() => { throw new Error('Stripe CLI listener did not become ready. Check CLI installation and existing test-mode login; output and credentials are suppressed.'); });
}

async function startWorker(port) {
  const temp = await mkdtemp(join(tmpdir(), 'doin-stripe-acceptance-'));
  const outfile = join(temp, 'worker.mjs');
  try {
    await build({ entryPoints: [join(CLOUD, 'worker.ts')], outfile, external: ['cloudflare:workers'], bundle: true, format: 'esm', platform: 'browser' });
    const script = await readFile(outfile, 'utf8');
    worker = new Miniflare(convertV4MiniflareOptions({
      host: '127.0.0.1', port,
      workers: [{
        name: 'doin-stripe-acceptance', modules: true, script, compatibilityDate: '2026-10-01',
        d1Databases: ['DB'], kvNamespaces: ['OAUTH_KV'],
        bindings: {
          ORIGIN: `http://127.0.0.1:${port}`,
          EMAIL_ENABLED: 'false', EMAIL_FROM: 'acceptance@example.test',
          STRIPE_SECRET_KEY: apiKey, STRIPE_WEBHOOK_SECRET: cliSecret,
          STRIPE_PRICE_ID: process.env.STRIPE_MONTHLY_PRICE_ID,
          STRIPE_MONTHLY_PRICE_ID: process.env.STRIPE_MONTHLY_PRICE_ID,
          STRIPE_YEARLY_PRICE_ID: process.env.STRIPE_YEARLY_PRICE_ID,
          STRIPE_TEAM_PRICE_ID: process.env.STRIPE_TEAM_PRICE_ID,
        },
        serviceBindings: { EMAIL: { name: 'no-email', entrypoint: 'Mailer' } },
        outboundService: async (request) => {
          const target = new URL(request.url);
          if (target.protocol !== 'https:' || target.hostname !== 'api.stripe.com' || target.port) throw new Error('Worker attempted an outbound request outside https://api.stripe.com; blocked.');
          return fetch(new Request(request, { redirect: 'manual' }));
        },
      }, {
        name: 'no-email', modules: true, compatibilityDate: '2026-10-01',
        script: "import {WorkerEntrypoint} from 'cloudflare:workers'; export class Mailer extends WorkerEntrypoint { async send(){ throw new Error('Acceptance runner blocks all email delivery.'); } } export default {fetch(){ return new Response('not found',{status:404}); }}",
        outboundService: async () => { throw new Error('Acceptance runner blocks all mail service network access.'); },
      }],
    }));
    await worker.ready;
  } finally {
    await rm(temp, { recursive: true, force: true });
  }
}

async function stopStripeCli() {
  if (!cli) return true;
  const groupExists = () => {
    if (!cliOwnsProcessGroup || !cli.pid) return cli.exitCode === null;
    try { process.kill(-cli.pid, 0); return true; } catch (error) { return error?.code !== 'ESRCH'; }
  };
  if (cli.exitCode !== null && !groupExists()) return true;
  const send = (signal) => {
    try {
      if (cliOwnsProcessGroup && cli.pid) process.kill(-cli.pid, signal);
      else cli.kill(signal);
    } catch (error) {
      if (error?.code !== 'ESRCH') cleanupIssues.push('stripe-cli-stop-failed');
    }
  };
  const waitForExit = async (ms) => {
    if (cli.exitCode !== null) return true;
    return Promise.race([
      new Promise((resolveExit) => cli.once('exit', () => resolveExit(true))),
      new Promise((resolveWait) => setTimeout(() => resolveWait(false), ms)),
    ]);
  };
  send('SIGTERM');
  await waitForExit(5_000);
  if (cli.exitCode !== null && !groupExists()) return true;
  send('SIGKILL');
  await waitForExit(2_000);
  if (cli.exitCode !== null && !groupExists()) return true;
  cleanupIssues.push('stripe-cli-survivor');
  return false;
}

// Miniflare's ready URL is authoritative. Cache it after startup.
let workerURL;
function bearer(token) { return { authorization: `Bearer ${token}` }; }
async function app(path, { method = 'GET', token, data, expected = 200 } = {}) {
  const response = await fetch(new URL(path, workerURL), {
    method,
    headers: { ...(token ? bearer(token) : {}), ...(data !== undefined ? { 'content-type': 'application/json' } : {}) },
    body: data === undefined ? undefined : JSON.stringify(data),
    redirect: 'manual',
    signal: AbortSignal.timeout(20_000),
  });
  const type = response.headers.get('content-type') || '';
  const body = type.includes('json') ? await response.json() : {};
  if (response.status !== expected) throw new Error(`Worker ${method} ${path} returned ${response.status} (expected ${expected}); body omitted${body?.error ? ` [${body.error}]` : ''}.`);
  return { response, body };
}

async function migrateAndSeed() {
  const db = await worker.getD1Database('DB');
  for (const file of ['0001.sql','0002.sql','0003.sql','0004.sql','0005.sql','0006.sql','0007.sql','0008.sql','0009.sql','0010.sql']) {
    await db.exec((await readFile(join(CLOUD, 'migrations', file), 'utf8')).replaceAll('\n', ' '));
  }
  manifest.accounts = {};
  const makeAccount = async (label, name) => {
    const id = randomUUID();
    const token = randomBytes(32).toString('hex');
    const expires = now() + 365 * 86400;
    const email = `billing+${manifest.run_id}-${label}@acceptance.example.test`;
    await db.prepare('INSERT INTO accounts(id,identity_key,email,name,created_at) VALUES(?,?,?,?,?)').bind(id, randomUUID(), email, name, now()).run();
    await db.prepare("INSERT INTO sessions(token_hash,account_id,kind,name,csrf,expires_at) VALUES(?,?,'device',?,'',?)").bind(createHash('sha256').update(token).digest('hex'), id, 'Sandbox acceptance', expires).run();
    manifest.accounts[label] = { id };
    await saveManifest();
    return { id, token, email };
  };
  manifest.db_name = `doin-stripe-acceptance-${manifest.run_id}`;
  manifest.customers = [];
  manifest.subscriptions = [];
  manifest.test_clocks = [];
  manifest.checkout_sessions = [];
  manifest.idempotency = {};
  manifest.recovery = {};
  await saveManifest();
  return { db, makeAccount };
}

async function createClock(label) {
  const clock = await managedWrite(`clock-${label}`, 'test_helpers/test_clocks', { frozen_time: String(now()), name: `doin-acceptance-${manifest.run_id}-${label}` });
  assert.equal(clock.livemode, false);
  manifest.test_clocks.push({ id: clock.id, name: clock.name });
  await saveManifest();
  return clock;
}

async function createCustomer(label, source, clock) {
  const fields = {
    name: `doin sandbox acceptance ${label}`,
    source,
    'metadata[doin_acceptance_run]': manifest.run_id,
    'metadata[doin_acceptance_role]': label,
    ...(clock ? { test_clock: clock.id } : {}),
  };
  const customer = await managedWrite(`customer-${label}`, 'customers', fields);
  assert.equal(customer.livemode, false);
  assert.equal(customer.metadata?.doin_acceptance_run, manifest.run_id);
  manifest.customers.push({ id: customer.id, role: label, clock: clock?.id || null });
  await saveManifest();
  return customer;
}

async function createSubscription(label, customer, price, quantity = 1) {
  const sub = await managedWrite(`subscription-${label}`, 'subscriptions', {
    customer: customer.id,
    'items[0][price]': price,
    'items[0][quantity]': String(quantity),
    payment_behavior: 'error_if_incomplete',
    'metadata[doin_acceptance_run]': manifest.run_id,
    'metadata[doin_acceptance_role]': label,
  });
  assert.equal(sub.livemode, false);
  assert.equal(sub.customer, customer.id);
  assert.equal(sub.status, 'active');
  assert.equal(sub.items?.data?.[0]?.price?.id, price);
  assert.ok(Number.isSafeInteger(sub.items.data[0].current_period_end));
  manifest.subscriptions.push({ id: sub.id, customer: customer.id, role: label });
  await saveManifest();
  return sub;
}

async function changeDefaultSource(subscription, customer, token, label) {
  const card = await managedWrite(`fail-source-${label}`, `customers/${encodeURIComponent(customer.id)}/sources`, { source: token });
  assert.equal(card.livemode, false);
  const changed = await managedWrite(`default-source-${label}`, `subscriptions/${encodeURIComponent(subscription.id)}`, { default_source: card.id });
  assert.equal(changed.id, subscription.id);
}

async function readBilling(token, path = '/v1/billing') {
  return (await app(path, { token })).body;
}

async function waitFor(test, description, timeoutMs = WAIT_LIMIT_MS) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await test()) return;
    await new Promise((resolveWait) => setTimeout(resolveWait, INTERVAL));
  }
  throw new Error(`Timed out waiting for ${description}.`);
}

async function deliveredEvent(type, customer) {
  return waitFor(async () => {
    const result = await stripe(`events?type=${encodeURIComponent(type)}&created[gte]=${manifest.started_at - 30}&limit=100`);
    const event = result.data?.find((x) => x.livemode === false && x.type === type && (x.data?.object?.customer === customer || x.data?.object?.id === customer));
    if (!event) return false;
    if (cliDeliveries.get(event.id) === 200) {
      manifest.events.push({ id: event.id, type, api_version: event.api_version || null, livemode: event.livemode });
      await saveManifest();
      return true;
    }
    return false;
  }, `real signed Stripe CLI webhook ${type}`);
}

async function checkoutSession(token, data, type) {
  const { body } = await app(type === 'personal' ? '/v1/checkout' : `/v1/teams/${data.team_id}/checkout`, {
    method: 'POST', token,
    data: type === 'personal' ? { interval: 'month' } : { seats: 2, accepted_terms: data.terms_version },
  });
  assert.equal(typeof body.url, 'string');
  const url = new URL(body.url);
  assert.equal(url.protocol, 'https:');
  assert.equal(url.hostname, 'checkout.stripe.com');
  const db = await worker.getD1Database('DB');
  const row = type === 'personal'
    ? await db.prepare('SELECT c.session_id,a.customer_id FROM checkouts c JOIN accounts a ON a.id=c.account_id WHERE c.account_id=?').bind(data.account_id).first()
    : await db.prepare('SELECT c.session_id,t.customer_id FROM team_checkouts c JOIN teams t ON t.id=c.team_id WHERE c.team_id=?').bind(data.team_id).first();
  assert.ok(row?.session_id);
  const session = await stripe(`checkout/sessions/${encodeURIComponent(row.session_id)}`);
  assert.equal(session.livemode, false);
  assert.equal(session.status, 'open');
  assert.equal(session.mode, 'subscription');
  assert.equal(session.customer, row.customer_id);
  const lines = await stripe(`checkout/sessions/${encodeURIComponent(session.id)}/line_items?limit=10`);
  const expectedPrice = type === 'personal' ? process.env.STRIPE_MONTHLY_PRICE_ID : process.env.STRIPE_TEAM_PRICE_ID;
  assert.equal(lines.data?.[0]?.price?.id, expectedPrice);
  assert.equal(lines.data?.[0]?.quantity, type === 'personal' ? 1 : 2);
  manifest.checkout_sessions.push({ id: session.id, customer: session.customer, type, owner_id: type === 'personal' ? data.account_id : data.team_id, livemode: false });
  if (!manifest.customers.some((c) => c.id === session.customer)) manifest.customers.push({ id: session.customer, role: `checkout-${type}`, owned_by: type === 'personal' ? { account: data.account_id } : { team: data.team_id }, clock: null });
  await saveManifest();
  return session;
}

async function runScenarios(prices) {
  const port = await freePort();
  await listenToStripe(port);
  await startWorker(port);
  workerURL = await worker.ready;
  assert.equal(new URL(workerURL).hostname, '127.0.0.1');
  const { db, makeAccount } = await migrateAndSeed();
  const billingTerms = (await app('/v1/teams/terms')).body;
  assert.equal(billingTerms.billing_mode, 'test');
  assert.equal(billingTerms.billing_ready, true);
  manifest.events = [];
  await saveManifest();

  // Personal monthly baseline, real subscription creation, and real switch to annual.
  const personal = await makeAccount('personal', 'Personal sandbox');
  const customer = await createCustomer('personal', 'tok_visa', null);
  await db.prepare('UPDATE accounts SET customer_id=? WHERE id=?').bind(customer.id, personal.id).run();
  const sub = await createSubscription('personal-month', customer, prices.month.id);
  await deliveredEvent('customer.subscription.created', customer.id);
  let billing = await readBilling(personal.token);
  assert.equal(billing.active, true);
  assert.equal(billing.interval, 'month');
  assert.equal(billing.amount, 499);
  assert.equal(billing.currency, 'usd');
  pass('real monthly subscription event grants personal entitlement', { interval: billing.interval, amount: billing.amount, currency: billing.currency });

  const quote = (await app('/v1/billing/change', { method: 'POST', token: personal.token, data: { interval: 'year' } })).body;
  assert.equal(quote.confirmation_required, true);
  assert.equal(quote.interval, 'year');
  assert.equal(quote.currency, 'usd');
  assert.equal(typeof quote.quote_id, 'string');
  assert.ok(Number.isSafeInteger(quote.amount_due));
  assert.ok(Number.isSafeInteger(quote.expires_at));
  const changed = (await app('/v1/billing/change', { method: 'POST', token: personal.token, data: { interval: 'year', quote_id: quote.quote_id, confirm_amount: quote.amount_due } })).body;
  assert.equal(changed.changed, true);
  assert.equal(changed.payment_pending, false);
  assert.equal(changed.interval, 'year');
  billing = await readBilling(personal.token);
  assert.equal(billing.interval, 'year');
  assert.equal(billing.amount, 4999);
  pass('monthly-to-yearly app quote confirms exact provider Price after real invoice payment', { interval: billing.interval, amount: billing.amount, confirmation_amount: quote.amount_due });

  // A separate monthly account uses Stripe's documented attachable failure fixture.
  const failAccount = await makeAccount('change-failure', 'Failed change sandbox');
  const failCustomer = await createCustomer('change-failure', 'tok_visa', null);
  await db.prepare('UPDATE accounts SET customer_id=? WHERE id=?').bind(failCustomer.id, failAccount.id).run();
  const failSub = await createSubscription('change-failure-month', failCustomer, prices.month.id);
  await deliveredEvent('customer.subscription.created', failCustomer.id);
  await changeDefaultSource(failSub, failCustomer, 'tok_visa_chargeCustomerFail', 'personal');
  const failQuote = (await app('/v1/billing/change', { method: 'POST', token: failAccount.token, data: { interval: 'year' } })).body;
  assert.equal(failQuote.confirmation_required, true);
  const pending = (await app('/v1/billing/change', { method: 'POST', token: failAccount.token, data: { interval: 'year', quote_id: failQuote.quote_id, confirm_amount: failQuote.amount_due } })).body;
  assert.equal(pending.changed, false);
  assert.equal(pending.payment_pending, true);
  assert.equal(pending.interval, 'month');
  assert.equal(pending.pending_interval, 'year');
  billing = await readBilling(failAccount.token);
  assert.equal(billing.interval, 'month');
  assert.equal(billing.pending_update, true);
  assert.equal(billing.pending_interval, 'year');
  const paidDocument = await app('/v1/document', { token: failAccount.token });
  assert.equal(paidDocument.response.status, 200, 'failed upgrade must preserve the already-paid monthly term');
  pass('failed upgrade keeps the paid monthly interval and entitlement while Stripe reports a pending annual update', { interval: billing.interval, pending_interval: billing.pending_interval, pending_update: billing.pending_update, existing_term_access: 200 });

  // Renewal and verified delivery use a Stripe test clock attached to the live monthly subscription.
  const clockRenewal = await createClock('renewal');
  const renewalAccount = await makeAccount('renewal', 'Renewal sandbox');
  const renewalCustomer = await createCustomer('renewal', 'tok_visa', clockRenewal);
  await db.prepare('UPDATE accounts SET customer_id=? WHERE id=?').bind(renewalCustomer.id, renewalAccount.id).run();
  const renewalSub = await createSubscription('renewal-month', renewalCustomer, prices.month.id);
  await deliveredEvent('customer.subscription.created', renewalCustomer.id);
  const active = await stripe(`subscriptions/${encodeURIComponent(renewalSub.id)}`);
  const periodEnd = active.items.data[0].current_period_end;
  const advanced = await stripe(`test_helpers/test_clocks/${encodeURIComponent(clockRenewal.id)}/advance`, { method: 'POST', fields: { frozen_time: String(periodEnd + 10) }, idempotencyKey: `doin-billing-acceptance-${manifest.run_id}-advance-monthly` });
  assert.equal(advanced.livemode, false);
  await waitFor(async () => (await stripe(`test_helpers/test_clocks/${encodeURIComponent(clockRenewal.id)}`)).status === 'ready', 'monthly test clock to finish advancing');
  const afterRenewal = await stripe(`subscriptions/${encodeURIComponent(renewalSub.id)}`);
  assert.equal(afterRenewal.status, 'active');
  assert.ok(afterRenewal.items.data[0].current_period_end > periodEnd);
  await deliveredEvent('customer.subscription.updated', renewalCustomer.id);
  pass('Stripe test clock renewed monthly subscription and delivered item-period update', { old_period_end: periodEnd, new_period_end: afterRenewal.items.data[0].current_period_end });

  // Checkout route check is real Stripe session creation only. Hosted form is intentionally manual.
  const checkoutActor = await makeAccount('personal-checkout', 'Checkout sandbox');
  const personalCheckout = await checkoutSession(checkoutActor.token, { account_id: checkoutActor.id }, 'personal');
  pass('personal Checkout route created genuine open Stripe test session', { session: redacted(personalCheckout.id), livemode: false, form_payment: 'NOT_RUN' });

  // Team subscription is seeded as a real Stripe purchase; app routes handle all changes.
  const termsVersion = billingTerms.version;
  async function teamFixture(label, source) {
    const actor = await makeAccount(`team-${label}`, `Team ${label} sandbox`);
    const teamCustomer = await createCustomer(`team-${label}`, 'tok_visa', null);
    const teamSub = await createSubscription(`team-${label}`, teamCustomer, prices.team.id, 1);
    await deliveredEvent('customer.subscription.created', teamCustomer.id);
    const id = randomUUID();
    const t = now();
    await db.batch([
      db.prepare('INSERT INTO teams(id,name,legal_entity,terms_version,accepted_by,accepted_at,deployment,customer_id,subscription_id,capacity,period_end,next_capacity,created_at) VALUES(?,?,?,?,?,?,\'hosted\',?,?,?,?,?,?)').bind(id, `Acceptance ${label}`, `Sandbox Entity ${label}`, termsVersion, actor.id, t, teamCustomer.id, teamSub.id, 1, teamSub.items.data[0].current_period_end, 1, t),
      db.prepare("INSERT INTO team_members(team_id,account_id,role,joined_at) VALUES(?,?,'owner',?)").bind(id, actor.id, t),
      db.prepare('INSERT INTO team_documents(team_id,updated_at) VALUES(?,?)').bind(id, t),
      db.prepare("INSERT INTO team_folders(team_id,id,parent_id,name,updated_at) VALUES(?,'root',NULL,'Home',?)").bind(id, t),
      db.prepare("INSERT INTO team_folder_grants(team_id,folder_id,account_id,access) VALUES(?,'root',?,'write')").bind(id, actor.id),
    ]);
    manifest.teams = manifest.teams || [];
    manifest.teams.push({ id, owner: actor.id, customer: teamCustomer.id, subscription: teamSub.id, role: label });
    await saveManifest();
    if (source === 'decline') await changeDefaultSource(teamSub, teamCustomer, 'tok_visa_chargeCustomerFail', `team-${label}`);
    return { actor, customer: teamCustomer, sub: teamSub, id };
  }
  const teamPaid = await teamFixture('paid', 'success');
  const seatQuote = (await app(`/v1/teams/${teamPaid.id}/seats`, { method: 'POST', token: teamPaid.actor.token, data: { seats: 2 } })).body;
  assert.equal(seatQuote.confirmation_required, true);
  assert.equal(seatQuote.currency, 'usd');
  const seatResult = (await app(`/v1/teams/${teamPaid.id}/seats`, { method: 'POST', token: teamPaid.actor.token, data: { seats: 2, confirm_amount: seatQuote.amount_due, proration_date: seatQuote.proration_date } })).body;
  assert.equal(seatResult.payment_pending, false);
  assert.equal(seatResult.paid_seats, 2);
  const teamBilling = (await app(`/v1/teams/${teamPaid.id}/billing`, { token: teamPaid.actor.token })).body;
  assert.equal(teamBilling.paid_seats, 2);
  pass('doinWITH seat proration invoice paid before capacity increases', { amount_due: seatQuote.amount_due, paid_seats: teamBilling.paid_seats });

  const teamPending = await teamFixture('failed-seats', 'decline');
  const failedSeatQuote = (await app(`/v1/teams/${teamPending.id}/seats`, { method: 'POST', token: teamPending.actor.token, data: { seats: 2 } })).body;
  const failedSeats = (await app(`/v1/teams/${teamPending.id}/seats`, { method: 'POST', token: teamPending.actor.token, data: { seats: 2, confirm_amount: failedSeatQuote.amount_due, proration_date: failedSeatQuote.proration_date } })).body;
  assert.equal(failedSeats.payment_pending, true);
  assert.equal(failedSeats.paid_seats, 1);
  const pendingBilling = (await app(`/v1/teams/${teamPending.id}/billing`, { token: teamPending.actor.token })).body;
  assert.equal(pendingBilling.paid_seats, 1);
  assert.equal(pendingBilling.pending_update, true);
  pass('failed doinWITH seat proration leaves paid capacity unchanged with pending update', { paid_seats: pendingBilling.paid_seats, pending_update: pendingBilling.pending_update });

  await app(`/v1/teams/${teamPaid.id}/cancel`, { method: 'POST', token: teamPaid.actor.token });
  let teamState = (await app(`/v1/teams/${teamPaid.id}/billing`, { token: teamPaid.actor.token })).body;
  assert.equal(teamState.cancel_at_period_end, true);
  assert.equal(teamState.active, true);
  await app(`/v1/teams/${teamPaid.id}/resume`, { method: 'POST', token: teamPaid.actor.token });
  teamState = (await app(`/v1/teams/${teamPaid.id}/billing`, { token: teamPaid.actor.token })).body;
  assert.equal(teamState.cancel_at_period_end, false);
  pass('doinWITH owner cancellation and resume preserve current paid term');

  // Team coverage is kept through term-end while the owner schedules the
  // personal renewal to stop, matching the explicit replacement confirmation.
  const ownerPersonal = await createCustomer('team-owner-personal', 'tok_visa', null);
  await db.prepare('UPDATE accounts SET customer_id=? WHERE id=?').bind(ownerPersonal.id, teamPaid.actor.id).run();
  const ownerSub = await createSubscription('team-owner-personal-month', ownerPersonal, prices.month.id);
  await deliveredEvent('customer.subscription.created', ownerPersonal.id);
  const replaced = (await app(`/v1/teams/${teamPaid.id}/personal-renewal/cancel`, { method: 'POST', token: teamPaid.actor.token, data: { confirmation: 'cancel personal renewal' } })).body;
  assert.equal(replaced.cancel_at_period_end, true);
  assert.equal((await stripe(`subscriptions/${encodeURIComponent(ownerSub.id)}`)).cancel_at_period_end, true);
  assert.equal((await app(`/v1/teams/${teamPaid.id}/billing`, { token: teamPaid.actor.token })).body.active, true);
  pass('doinWITH replacement confirmation schedules personal renewal cancellation and preserves paid team term');

  await app('/v1/billing/cancel', { method: 'POST', token: personal.token });
  billing = await readBilling(personal.token);
  assert.equal(billing.active, true);
  assert.equal(billing.cancel_at_period_end, true);
  await app('/v1/billing/resume', { method: 'POST', token: personal.token });
  billing = await readBilling(personal.token);
  assert.equal(billing.cancel_at_period_end, false);
  pass('personal cancellation and resume preserve the already-paid term');

  const personalPortal = (await app('/v1/billing/portal', { method: 'POST', token: personal.token })).body;
  assert.equal(new URL(personalPortal.url).hostname, 'billing.stripe.com');
  const personalPortalSession = await stripe(`billing_portal/sessions/${encodeURIComponent(new URL(personalPortal.url).pathname.split('/').at(-1))}`);
  assert.equal(personalPortalSession.livemode, false);
  assert.equal(personalPortalSession.customer, customer.id);
  assert.equal(personalPortalSession.flow?.type, 'payment_method_update');
  pass('personal billing portal creates genuine test-mode payment-method update session');

  const teamCheckoutActor = await makeAccount('team-checkout', 'Team checkout sandbox');
  const teamId = randomUUID();
  const termTime = now();
  await db.batch([
    db.prepare('INSERT INTO teams(id,name,legal_entity,terms_version,accepted_by,accepted_at,deployment,created_at) VALUES(?,?,?,?,?,?,\'hosted\',?)').bind(teamId, 'Acceptance Checkout', 'Sandbox Checkout Entity', termsVersion, teamCheckoutActor.id, termTime, termTime),
    db.prepare("INSERT INTO team_members(team_id,account_id,role,joined_at) VALUES(?,?,'owner',?)").bind(teamId, teamCheckoutActor.id, termTime),
    db.prepare('INSERT INTO team_documents(team_id,updated_at) VALUES(?,?)').bind(teamId, termTime),
    db.prepare("INSERT INTO team_folders(team_id,id,parent_id,name,updated_at) VALUES(?,'root',NULL,'Home',?)").bind(teamId, termTime),
    db.prepare("INSERT INTO team_folder_grants(team_id,folder_id,account_id,access) VALUES(?,'root',?,'write')").bind(teamId, teamCheckoutActor.id),
  ]);
  manifest.teams = manifest.teams || [];
  manifest.teams.push({ id: teamId, owner: teamCheckoutActor.id, customer: null, subscription: null, role: 'checkout-unpaid' });
  await saveManifest();
  const newTeamCheckout = await checkoutSession(teamCheckoutActor.token, { team_id: teamId, terms_version: termsVersion }, 'team');
  pass('doinWITH Checkout route created genuine open test session', { session: redacted(newTeamCheckout.id), livemode: false, form_payment: 'NOT_RUN' });

  const teamPortal = (await app(`/v1/teams/${teamPaid.id}/portal`, { method: 'POST', token: teamPaid.actor.token })).body;
  assert.equal(new URL(teamPortal.url).hostname, 'billing.stripe.com');
  const teamPortalSession = await stripe(`billing_portal/sessions/${encodeURIComponent(new URL(teamPortal.url).pathname.split('/').at(-1))}`);
  assert.equal(teamPortalSession.livemode, false);
  assert.equal(teamPortalSession.customer, teamPaid.customer.id);
  assert.equal(teamPortalSession.flow?.type, 'payment_method_update');
  pass('team billing portal creates genuine test-mode payment-method update session');

  // Verify rejection of an invalid signature using a real event body and a wrong HMAC.
  const eventList = await stripe(`events?type=customer.subscription.created&created[gte]=${manifest.started_at - 30}&limit=100`);
  const event = eventList.data?.find((e) => e.livemode === false && e.data?.object?.id === sub.id);
  assert.ok(event, 'Stripe must expose the real subscription event');
  const raw = JSON.stringify(event);
  const ts = now();
  const wrongSig = createHmac('sha256', 'whsec_intentionally_invalid').update(`${ts}.${raw}`).digest('hex');
  const rejected = await fetch(new URL('/webhooks/stripe', workerURL), { method: 'POST', headers: { 'stripe-signature': `t=${ts},v1=${wrongSig}`, 'content-type': 'application/json' }, body: raw });
  assert.equal(rejected.status, 400);
  pass('webhook handler rejects a real provider event body with invalid signature');

  report = {
    generated_at: new Date().toISOString(),
    // Checkout form payment, interactive 3DS, and replacement are explicitly
    // left for a browser operator and prevent an overall PASS until exercised.
    result: 'ISSUES',
    api_version: VERSION,
    mode: 'stripe_test_mode',
    actual_worker: true,
    worker_outbound_hosts: ['api.stripe.com'],
    real_email_sent: false,
    secret_values_recorded: false,
    email_values_recorded: false,
    payment_credentials_recorded: false,
    checkout_form_purchase: 'NOT_RUN',
    interactive_3ds: 'NOT_RUN',
    replacement_after_cancellation: 'PASS',
    checks: checkRows,
    objects: {
      customers: manifest.customers.map((c) => ({ id: redacted(c.id), role: c.role, livemode: false })),
      subscriptions: manifest.subscriptions.map((s) => ({ id: redacted(s.id), role: s.role, livemode: false })),
      checkout_sessions: manifest.checkout_sessions.map((s) => ({ id: redacted(s.id), type: s.type, status: 'open_before_cleanup', livemode: false })),
      webhook_events: manifest.events.map((e) => ({ id: redacted(e.id), type: e.type, api_version: e.api_version, livemode: e.livemode })),
      test_clocks: manifest.test_clocks.map((c) => ({ id: redacted(c.id), name: c.name, livemode: false })),
    },
    cleanup: 'pending',
  };
}

async function cleanupManifest(file) {
  if (!file.startsWith(`${ARTIFACT_DIR}/`)) throw new Error('Refusing cleanup: manifest must be inside the private acceptance artifact directory.');
  const data = JSON.parse(await readFile(file, 'utf8'));
  if (data.schema !== 1 || typeof data.run_id !== 'string' || !Array.isArray(data.customers) || !Array.isArray(data.test_clocks)) throw new Error('Refusing cleanup: invalid or unsupported manifest.');
  await loadCredentials();
  const cleanupErrors = [];
  const safeCall = async (label, fn) => { try { await fn(); return true; } catch { cleanupErrors.push(label); return false; } };
  const safeRead = async (label, fn) => {
    try { return await fn(); } catch { cleanupErrors.push(label); return undefined; }
  };
  const readList = async (path, label) => safeRead(label, async () => {
    const result = await stripe(path);
    if (!Array.isArray(result?.data) || result.has_more !== false) throw new Error('Incomplete Stripe list');
    return result.data;
  });
  // Recover only customers whose random local account/team IDs are in this run manifest.
  const findCustomers = async (query, role, owned_by) => {
    const customers = await readList(`customers/search?query=${encodeURIComponent(query)}&limit=100`, 'customer-search-incomplete');
    for (const customer of customers || []) if (customerOwnedByRun(customer, data) && !data.customers.some((x) => x.id === customer.id)) data.customers.push({ id: customer.id, role, owned_by, clock: customer.test_clock || null });
  };
  await findCustomers(`metadata['doin_acceptance_run']:'${data.run_id}'`, 'recovered-run-customer', null);
  for (const account of Object.values(data.accounts || {})) await findCustomers(`metadata['account_id']:'${account.id}'`, 'recovered-personal-checkout', { account: account.id });
  for (const team of data.teams || []) await findCustomers(`metadata['team_id']:'${team.id}'`, 'recovered-team-checkout', { team: team.id });
  const clocks = await readList('test_helpers/test_clocks?limit=100', 'test-clock-list-incomplete');
  for (const current of clocks || []) if (current.livemode === false && current.name?.startsWith(`doin-acceptance-${data.run_id}-`) && !data.test_clocks.some((x) => x.id === current.id)) data.test_clocks.push({ id: current.id, name: current.name });
  for (const entry of data.customers) {
    if (!/^cus_[A-Za-z0-9]+$/.test(entry.id)) { cleanupErrors.push('invalid-customer-id'); continue; }
    const customer = await safeRead('customer-lookup-failed', () => stripe(`customers/${encodeURIComponent(entry.id)}`, { tolerateMissing: true }));
    if (!customer) continue;
    if (!customerOwnedByRun(customer, data)) { cleanupErrors.push('customer-ownership-mismatch'); continue; }
    const checkouts = await readList(`checkout/sessions?customer=${encodeURIComponent(entry.id)}&status=open&limit=100`, 'checkout-list-incomplete');
    if (!checkouts) continue;
    let canDeleteCustomer = true;
    for (const session of checkouts) if (session.livemode === false && session.customer === entry.id) {
      if (!(await safeCall('checkout-expire-failed', async () => { await stripe(`checkout/sessions/${encodeURIComponent(session.id)}/expire`, { method: 'POST', fields: {} }); }))) canDeleteCustomer = false;
    }
    const subscriptions = await readList(`subscriptions?customer=${encodeURIComponent(entry.id)}&status=all&limit=100`, 'subscription-list-incomplete');
    if (!subscriptions) continue;
    for (const subscription of subscriptions) {
      if (subscription.livemode !== false || subscription.customer !== entry.id || subscription.metadata?.doin_acceptance_run !== data.run_id) { cleanupErrors.push('subscription-ownership-mismatch'); canDeleteCustomer = false; continue; }
      if (!['canceled', 'incomplete_expired'].includes(subscription.status) && !(await safeCall('subscription-cleanup-failed', async () => { await stripe(`subscriptions/${encodeURIComponent(subscription.id)}`, { method: 'DELETE' }); }))) canDeleteCustomer = false;
    }
    if (canDeleteCustomer) await safeCall('customer-cleanup-failed', async () => { await stripe(`customers/${encodeURIComponent(entry.id)}`, { method: 'DELETE' }); });
  }
  for (const clock of data.test_clocks) {
    const current = await safeRead('test-clock-lookup-failed', () => stripe(`test_helpers/test_clocks/${encodeURIComponent(clock.id)}`, { tolerateMissing: true }));
    if (!current) continue;
    if (current.livemode !== false || current.name !== clock.name || !clock.name.startsWith(`doin-acceptance-${data.run_id}-`)) { cleanupErrors.push('clock-ownership-mismatch'); continue; }
    await safeCall(`clock-${clock.id}`, async () => { await stripe(`test_helpers/test_clocks/${encodeURIComponent(clock.id)}`, { method: 'DELETE' }); });
  }
  data.cleanup = cleanupErrors.length ? 'ISSUES' : 'complete';
  data.cleanup_errors = cleanupErrors;
  await writeFile(file, `${JSON.stringify(data, null, 2)}\n`, { mode: 0o600 });
  if (cleanupErrors.length) throw new Error(`Cleanup incomplete for ${cleanupErrors.length} owned resources. Retry cleanup with the same manifest; keys and provider details omitted.`);
  console.log('Cleanup complete: only verified test-mode resources tagged by this run were expired, canceled, or deleted.');
}

async function cleanupCurrent() {
  if (!manifest) return;
  for (const customer of manifest.customers || []) {
    try {
      const liveCustomer = await stripe(`customers/${encodeURIComponent(customer.id)}`, { tolerateMissing: true });
      if (!liveCustomer) continue;
      if (!customerOwnedByRun(liveCustomer, manifest)) { cleanupIssues.push('customer-ownership-mismatch'); continue; }
      const list = await stripe(`checkout/sessions?customer=${encodeURIComponent(customer.id)}&status=open&limit=100`);
      if (!Array.isArray(list.data) || list.has_more !== false) { cleanupIssues.push('checkout-list-incomplete'); continue; }
      let canDeleteCustomer = true;
      for (const session of list.data) if (session.livemode === false && session.customer === customer.id) {
        try { await stripe(`checkout/sessions/${encodeURIComponent(session.id)}/expire`, { method: 'POST', fields: {} }); }
        catch { cleanupIssues.push('checkout-expire-failed'); canDeleteCustomer = false; }
      }
      const subs = await stripe(`subscriptions?customer=${encodeURIComponent(customer.id)}&status=all&limit=100`);
      if (!Array.isArray(subs.data) || subs.has_more !== false) { cleanupIssues.push('subscription-list-incomplete'); continue; }
      for (const sub of subs.data) {
        if (sub.livemode !== false || sub.customer !== customer.id || sub.metadata?.doin_acceptance_run !== manifest.run_id) { cleanupIssues.push('subscription-ownership-mismatch'); canDeleteCustomer = false; continue; }
        if (!['canceled', 'incomplete_expired'].includes(sub.status)) {
          try { await stripe(`subscriptions/${encodeURIComponent(sub.id)}`, { method: 'DELETE' }); }
          catch { cleanupIssues.push('subscription-cleanup-failed'); canDeleteCustomer = false; }
        }
      }
      if (canDeleteCustomer) await stripe(`customers/${encodeURIComponent(customer.id)}`, { method: 'DELETE' });
    } catch { cleanupIssues.push('customer-cleanup-failed'); }
  }
  for (const clock of manifest.test_clocks || []) {
    try {
      const liveClock = await stripe(`test_helpers/test_clocks/${encodeURIComponent(clock.id)}`, { tolerateMissing: true });
      if (liveClock?.livemode === false && liveClock.name === clock.name && clock.name.startsWith(`doin-acceptance-${manifest.run_id}-`)) await stripe(`test_helpers/test_clocks/${encodeURIComponent(clock.id)}`, { method: 'DELETE' });
      else if (liveClock) cleanupIssues.push('test-clock-ownership-mismatch');
    } catch { cleanupIssues.push('test-clock-cleanup-failed'); }
  }
}

async function main() {
  if (process.argv[2] === '--cleanup') {
    if (!process.argv[3]) throw new Error('Usage: node tests/stripe-sandbox-acceptance.mjs --cleanup <manifest.json>');
    await cleanupManifest(resolve(CLOUD, process.argv[3]));
    return;
  }
  if (process.argv.length > 2) throw new Error('Only supported option is --cleanup <manifest.json>.');
  const prices = await preflight();
  manifest = {
    schema: 1,
    run_id: randomUUID(),
    started_at: now(),
    api_version: VERSION,
    mode: 'test',
    customers: [],
    subscriptions: [],
    test_clocks: [],
    checkout_sessions: [],
    teams: [],
    events: [],
    idempotency: {},
    recovery: {},
  };
  manifestPath = join(ARTIFACT_DIR, `manifest-${manifest.run_id}.json`);
  await saveManifest();
  await runScenarios(prices);
}

try {
  await main();
} catch (error) {
  failed = true;
  report = report || { generated_at: new Date().toISOString(), result: 'ISSUES', api_version: VERSION, checks: checkRows };
  report.result = 'ISSUES';
  report.failure = safeError(error);
} finally {
  if (worker) {
    try { await worker.dispose(); } catch { failed = true; }
  }
  if (cli && !(await stopStripeCli())) failed = true;
  if (manifest && apiKey && /^sk_test_[A-Za-z0-9]+$/.test(apiKey)) await cleanupCurrent();
  if (manifestPath && manifest) {
    manifest.cleanup = cleanupIssues.length ? 'ISSUES' : 'complete';
    manifest.cleanup_errors = cleanupIssues;
    try { await saveManifest(); } catch { cleanupIssues.push('manifest-write-failed'); failed = true; }
  }
  if (cleanupIssues.length) failed = true;
  if (!report) report = { generated_at: new Date().toISOString(), result: 'ISSUES', api_version: VERSION, mode: 'preflight_or_setup', checks: checkRows };
  {
    // NOT_RUN browser-only steps keep this an issue until completed by a human.
    const incomplete = report.checkout_form_purchase === 'NOT_RUN' || report.interactive_3ds === 'NOT_RUN' || report.replacement_after_cancellation === 'NOT_RUN';
    report.result = failed || incomplete ? 'ISSUES' : 'PASS';
    report.cleanup = cleanupIssues.length ? 'ISSUES; inspect and replay the private manifest if needed' : failed && manifest ? 'attempted; inspect and replay the private manifest if needed' : manifest ? 'complete' : 'not_needed';
    if (cleanupIssues.length) report.cleanup_issues = cleanupIssues;
    report.manifest = manifestPath ? manifestPath.replace(`${CLOUD}/`, '') : undefined;
    const artifact = join(ARTIFACT_DIR, `report-${manifest?.run_id || new Date().toISOString().replace(/[:.]/g, '-')}.json`);
    await mkdir(dirname(artifact), { recursive: true });
    await writeFile(artifact, `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 });
    await chmod(artifact, 0o600);
    console.log(`${report.result}: secret-free evidence written to ${artifact.replace(`${CLOUD}/`, '')}.`);
    if (manifestPath) console.log(`Private cleanup manifest retained at ${manifestPath.replace(`${CLOUD}/`, '')}.`);
  }
}

if (failed || report?.result !== 'PASS') process.exitCode = 1;
