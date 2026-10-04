CREATE TABLE mcp_provider_oauth (
 connection_id TEXT PRIMARY KEY REFERENCES mcp_connections(id) ON DELETE CASCADE,
 account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
 payload_ciphertext TEXT NOT NULL,
 version INTEGER NOT NULL DEFAULT 0,
 state_hash TEXT UNIQUE,
 expires_at INTEGER,
 device_hash TEXT,
 lock_id TEXT,
 lock_until INTEGER
);
CREATE TABLE mcp_auth_requests (
 id TEXT PRIMARY KEY,
 browser_hash TEXT NOT NULL,
 request_json TEXT NOT NULL,
 client_name TEXT NOT NULL,
 redirect_host TEXT NOT NULL,
 expires_at INTEGER NOT NULL,
 account_id TEXT REFERENCES accounts(id) ON DELETE CASCADE,
 scopes TEXT,
 approved_at INTEGER,
 denied_at INTEGER,
 completed_url_ciphertext TEXT,
 lock_id TEXT,
 lock_until INTEGER
);
CREATE TABLE mcp_auth_grants (
 id TEXT PRIMARY KEY,
 account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
 client_id TEXT NOT NULL,
 redirect_uri TEXT NOT NULL,
 scopes TEXT NOT NULL,
 created_at INTEGER NOT NULL,
 revoked_at INTEGER
);
CREATE INDEX mcp_auth_grants_account ON mcp_auth_grants(account_id);
ALTER TABLE mcp_connections ADD COLUMN auth_type TEXT NOT NULL DEFAULT 'none' CHECK(auth_type IN ('none','bearer','oauth'));
UPDATE mcp_connections SET auth_type='bearer' WHERE token_ciphertext IS NOT NULL;
ALTER TABLE mcp_auth_grants ADD COLUMN team_id TEXT;
ALTER TABLE mcp_auth_grants ADD COLUMN folder_id TEXT;
