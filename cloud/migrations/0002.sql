ALTER TABLE accounts RENAME COLUMN github_id TO identity_key;
ALTER TABLE accounts ADD COLUMN email TEXT;
CREATE UNIQUE INDEX accounts_email ON accounts(email);
ALTER TABLE accounts ADD COLUMN billing_lock TEXT;
ALTER TABLE accounts ADD COLUMN billing_lock_until INTEGER;
ALTER TABLE accounts ADD COLUMN closing_at INTEGER;
ALTER TABLE checkouts ADD COLUMN session_id TEXT;
CREATE TABLE auth_requests (
  id TEXT PRIMARY KEY,
  email TEXT NOT NULL,
  device_name TEXT NOT NULL,
  challenge TEXT NOT NULL,
  link_hash TEXT NOT NULL UNIQUE,
  confirmation_hash TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  approved_at INTEGER,
  claimed_hash TEXT,
  claimed_at INTEGER,
  verification_attempts INTEGER NOT NULL DEFAULT 0
);
