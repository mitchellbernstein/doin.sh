CREATE TABLE account_preferences (
 account_id TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
 accent TEXT
  CHECK(accent IS NULL OR (length(accent)=7 AND substr(accent,1,1)='#' AND substr(accent,2) NOT GLOB '*[^0-9A-Fa-f]*')),
 revision INTEGER NOT NULL DEFAULT 0 CHECK(revision >= 0),
 updated_at INTEGER NOT NULL DEFAULT 0
);
