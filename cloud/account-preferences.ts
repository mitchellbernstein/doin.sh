export type AccountPreferences = { accent: string | null; revision: number };
export type AccountPreferencesEnv = { DB: D1Database };
type Boundary = { body: (request: Request, max?: number) => Promise<any> };

const fail = (status: number, error: string): never => { throw Response.json({ error }, { status }); };
const maxRevision = Number.MAX_SAFE_INTEGER;
const color = /^#[0-9a-fA-F]{6}$/;

function accent(value: unknown): string | null {
  if (value === null) return null;
  if (typeof value !== 'string' || !color.test(value)) fail(400, 'invalid_preferences');
  return value.toUpperCase();
}

function view(row: { accent: string | null; revision: number } | null): AccountPreferences {
  if (!row) return { accent: null, revision: 0 };
  if (!Number.isSafeInteger(row.revision) || row.revision < 0 || row.revision > maxRevision) fail(503, 'preferences_unavailable');
  return { accent: row.accent, revision: row.revision };
}

async function current(env: AccountPreferencesEnv, accountId: string): Promise<AccountPreferences> {
  return view(await env.DB.prepare('SELECT accent,revision FROM account_preferences WHERE account_id=?').bind(accountId).first<{ accent: string | null; revision: number }>());
}

export async function accountPreferencesRoute(request: Request, env: AccountPreferencesEnv, actor: { id: string }, boundary: Boundary): Promise<Response> {
  if (new URL(request.url).pathname !== '/v1/account/preferences') fail(404, 'not_found');
  if (request.method === 'GET') return Response.json(await current(env, actor.id));
  if (request.method !== 'PUT') fail(405, 'method_not_allowed');
  const contentType = request.headers.get('content-type')?.split(';', 1)[0].trim().toLowerCase();
  if (contentType !== 'application/json') fail(415, 'json_required');
  const data = await boundary.body(request, 1024);
  const keys = Object.keys(data).sort();
  if (keys.length !== 2 || keys[0] !== 'accent' || keys[1] !== 'revision' || !Number.isSafeInteger(data.revision) || data.revision < 0 || data.revision >= maxRevision) fail(400, 'invalid_preferences');
  const requestedAccent = accent(data.accent);
  const expected = data.revision as number;
  const saved = await env.DB.prepare(`
    INSERT INTO account_preferences(account_id,accent,revision,updated_at)
    SELECT ?,?,?,?
    WHERE ((?=0 AND ? IS NOT NULL) OR EXISTS(SELECT 1 FROM account_preferences WHERE account_id=?))
      AND EXISTS(SELECT 1 FROM accounts WHERE id=? AND closing_at IS NULL)
    ON CONFLICT(account_id) DO UPDATE SET
      accent=excluded.accent,
      revision=account_preferences.revision+1,
      updated_at=excluded.updated_at
    WHERE account_preferences.revision=?
      AND account_preferences.accent IS NOT excluded.accent
      AND EXISTS(SELECT 1 FROM accounts WHERE id=? AND closing_at IS NULL)
    RETURNING accent,revision
  `).bind(actor.id, requestedAccent, 1, Math.floor(Date.now() / 1000), expected, requestedAccent, actor.id, actor.id, expected, actor.id).first<{ accent: string | null; revision: number }>();
  if (saved) return Response.json(view(saved));

  const latest = await current(env, actor.id);
  const account = await env.DB.prepare('SELECT closing_at FROM accounts WHERE id=?').bind(actor.id).first<{ closing_at: number | null }>();
  if (!account) fail(404, 'account_not_found');
  if (account.closing_at !== null) fail(409, 'account_deletion_pending');
  if (latest.accent === requestedAccent && (latest.revision === expected || latest.revision === expected + 1)) return Response.json(latest);
  return Response.json({ error: 'preferences_conflict', preferences: latest }, { status: 409 });
}
