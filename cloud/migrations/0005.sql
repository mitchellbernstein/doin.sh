CREATE TABLE teams (
 id TEXT PRIMARY KEY, name TEXT NOT NULL, legal_entity TEXT NOT NULL,
 terms_version TEXT NOT NULL, accepted_by TEXT NOT NULL, accepted_at INTEGER NOT NULL,
 deployment TEXT NOT NULL CHECK(deployment IN ('hosted','self_hosted')),
 customer_id TEXT UNIQUE, subscription_id TEXT, capacity INTEGER NOT NULL DEFAULT 0,
 period_end INTEGER NOT NULL DEFAULT 0, next_capacity INTEGER NOT NULL DEFAULT 0,
 billing_lock TEXT, billing_lock_until INTEGER, closing_at INTEGER,
 created_at INTEGER NOT NULL
);
CREATE TABLE team_members (
 team_id TEXT NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
 account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
 role TEXT NOT NULL CHECK(role IN ('owner','admin','member')),
 joined_at INTEGER NOT NULL, PRIMARY KEY(team_id,account_id)
);
CREATE UNIQUE INDEX team_one_owner ON team_members(team_id) WHERE role='owner';
CREATE TABLE team_documents (
 team_id TEXT PRIMARY KEY REFERENCES teams(id) ON DELETE CASCADE,
 revision INTEGER NOT NULL DEFAULT 0, content TEXT NOT NULL DEFAULT '', updated_at INTEGER NOT NULL
);
CREATE TABLE team_invites (
 id TEXT PRIMARY KEY, team_id TEXT NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
 email TEXT NOT NULL, role TEXT NOT NULL CHECK(role IN ('admin','member')),
 token_hash TEXT NOT NULL UNIQUE, inviter TEXT NOT NULL, expires_at INTEGER NOT NULL,
 claim TEXT, consumed_at INTEGER
);
CREATE TABLE team_checkouts (
 team_id TEXT PRIMARY KEY REFERENCES teams(id) ON DELETE CASCADE,
 idempotency_key TEXT NOT NULL, price_id TEXT NOT NULL, seats INTEGER NOT NULL,
 expires_at INTEGER NOT NULL, session_id TEXT, url TEXT
);
CREATE TABLE team_seat_operations (
 team_id TEXT PRIMARY KEY REFERENCES teams(id) ON DELETE CASCADE,
 idempotency_key TEXT NOT NULL, seats INTEGER NOT NULL, proration_date INTEGER NOT NULL,
 completed INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE team_audit (
 id TEXT PRIMARY KEY, team_id TEXT NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
 actor TEXT NOT NULL, action TEXT NOT NULL, target TEXT NOT NULL, created_at INTEGER NOT NULL
);
CREATE TRIGGER team_owner_account_guard BEFORE DELETE ON accounts
WHEN EXISTS(SELECT 1 FROM team_members WHERE account_id=OLD.id AND role='owner')
BEGIN SELECT RAISE(ABORT,'transfer_or_delete_team'); END;
CREATE TRIGGER team_departure_invites BEFORE DELETE ON accounts
BEGIN DELETE FROM team_invites WHERE email=OLD.email OR inviter=OLD.id; END;
