-- Developer streaming API: free-tier keys + daily usage.
CREATE TABLE IF NOT EXISTS api_keys (
  id TEXT PRIMARY KEY,
  email TEXT NOT NULL,
  name TEXT NOT NULL DEFAULT '',
  prefix TEXT NOT NULL DEFAULT '',
  key_hash TEXT NOT NULL UNIQUE,
  plan TEXT NOT NULL DEFAULT 'free',
  created INTEGER NOT NULL,
  last_used INTEGER NOT NULL DEFAULT 0,
  revoked INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_api_keys_email ON api_keys(email, created);
CREATE TABLE IF NOT EXISTS api_usage (
  key_id TEXT NOT NULL,
  day TEXT NOT NULL,
  calls INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (key_id, day)
);
