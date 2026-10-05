CREATE TABLE billing_change_quotes (
  quote_id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  customer_id TEXT NOT NULL,
  subscription_id TEXT NOT NULL,
  item_id TEXT NOT NULL,
  current_period_end INTEGER NOT NULL,
  from_price_id TEXT NOT NULL,
  to_price_id TEXT NOT NULL,
  interval TEXT NOT NULL CHECK(interval IN ('month','year')),
  amount_due INTEGER NOT NULL CHECK(amount_due >= 0),
  currency TEXT NOT NULL CHECK(currency = 'usd'),
  proration_date INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  idempotency_key TEXT NOT NULL UNIQUE,
  state TEXT NOT NULL DEFAULT 'quoted' CHECK(state IN ('quoted','applying','pending','complete','failed')),
  created_at INTEGER NOT NULL
);
CREATE INDEX billing_change_quotes_account_created ON billing_change_quotes(account_id,created_at DESC);
CREATE UNIQUE INDEX billing_change_quotes_single_outstanding ON billing_change_quotes(account_id) WHERE state IN ('applying','pending');
