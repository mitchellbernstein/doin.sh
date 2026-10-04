CREATE TABLE mcp_connections (
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  id TEXT NOT NULL UNIQUE,
  url TEXT NOT NULL,
  token_ciphertext TEXT,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (account_id, name)
);
