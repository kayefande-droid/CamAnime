CREATE TABLE IF NOT EXISTS users (
  email TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  pw TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'user',
  avatar TEXT NOT NULL DEFAULT '',
  created INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS tokens (
  token TEXT PRIMARY KEY,
  email TEXT NOT NULL REFERENCES users(email) ON DELETE CASCADE,
  created INTEGER NOT NULL,
  expires INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS comments (
  id TEXT PRIMARY KEY,
  anime_id TEXT NOT NULL,
  ep TEXT NOT NULL DEFAULT '',
  email TEXT NOT NULL,
  username TEXT NOT NULL,
  text TEXT NOT NULL DEFAULT '',
  parent TEXT NOT NULL DEFAULT '',
  sticker TEXT NOT NULL DEFAULT '',
  likes INTEGER NOT NULL DEFAULT 0,
  liked_by TEXT NOT NULL DEFAULT '[]',
  t INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_comments_anime ON comments(anime_id, ep, t);
CREATE TABLE IF NOT EXISTS ratings (
  anime_id TEXT NOT NULL,
  email TEXT NOT NULL,
  score INTEGER NOT NULL,
  t INTEGER NOT NULL,
  PRIMARY KEY (anime_id, email)
);
CREATE TABLE IF NOT EXISTS notifications (
  id TEXT PRIMARY KEY,
  email TEXT NOT NULL,
  text TEXT NOT NULL,
  read INTEGER NOT NULL DEFAULT 0,
  t INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_notif_email ON notifications(email, t);
CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  t INTEGER NOT NULL,
  kind TEXT NOT NULL,
  anime_id TEXT NOT NULL DEFAULT '',
  ep TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_events_kind ON events(kind, t);
CREATE TABLE IF NOT EXISTS counters (
  key TEXT PRIMARY KEY,
  value INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS announcements (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL DEFAULT '',
  body TEXT NOT NULL DEFAULT '',
  author TEXT NOT NULL DEFAULT '',
  t INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_ann_t ON announcements(t);
CREATE TABLE IF NOT EXISTS anime_cache (
  id INTEGER PRIMARY KEY,
  title TEXT NOT NULL DEFAULT '',
  image TEXT NOT NULL DEFAULT '',
  banner TEXT NOT NULL DEFAULT '',
  format TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT '',
  year INTEGER NOT NULL DEFAULT 0,
  episode_label TEXT NOT NULL DEFAULT '',
  t INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS user_history (
  email TEXT NOT NULL,
  anime_id INTEGER NOT NULL,
  ep INTEGER NOT NULL DEFAULT 1,
  position REAL NOT NULL DEFAULT 0,
  duration REAL NOT NULL DEFAULT 0,
  title TEXT NOT NULL DEFAULT '',
  image TEXT NOT NULL DEFAULT '',
  t INTEGER NOT NULL,
  PRIMARY KEY (email, anime_id)
);
CREATE INDEX IF NOT EXISTS idx_history_email ON user_history(email, t);
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

INSERT OR IGNORE INTO counters (key, value) VALUES ('player_starts', 0);
INSERT OR IGNORE INTO counters (key, value) VALUES ('visits', 0);
-- CamAnime notification, OTA/APK release and remote-configuration tables.
-- Safe to re-run: every statement is IF NOT EXISTS.

CREATE TABLE IF NOT EXISTS devices (
  install_id      TEXT PRIMARY KEY,
  token           TEXT NOT NULL DEFAULT '',
  platform        TEXT NOT NULL DEFAULT 'android',
  app_version     TEXT NOT NULL DEFAULT '',
  app_build       INTEGER NOT NULL DEFAULT 0,
  android_version TEXT NOT NULL DEFAULT '',
  language        TEXT NOT NULL DEFAULT '',
  prefs           TEXT NOT NULL DEFAULT '{}',
  topics          TEXT NOT NULL DEFAULT '[]',
  created         INTEGER NOT NULL,
  updated         INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_devices_updated ON devices(updated);
CREATE INDEX IF NOT EXISTS idx_devices_token ON devices(token);
CREATE INDEX IF NOT EXISTS idx_devices_build ON devices(app_build);

CREATE TABLE IF NOT EXISTS notification_log (
  id           TEXT PRIMARY KEY,
  title        TEXT NOT NULL DEFAULT '',
  body         TEXT NOT NULL DEFAULT '',
  image        TEXT NOT NULL DEFAULT '',
  action       TEXT NOT NULL DEFAULT '',
  deep_link    TEXT NOT NULL DEFAULT '',
  category     TEXT NOT NULL DEFAULT 'announcement',
  target       TEXT NOT NULL DEFAULT 'all',
  target_value TEXT NOT NULL DEFAULT '',
  channel      TEXT NOT NULL DEFAULT 'stable',
  status       TEXT NOT NULL DEFAULT 'queued',
  scheduled_at INTEGER NOT NULL DEFAULT 0,
  sent         INTEGER NOT NULL DEFAULT 0,
  failed       INTEGER NOT NULL DEFAULT 0,
  error        TEXT NOT NULL DEFAULT '',
  author       TEXT NOT NULL DEFAULT '',
  created      INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_notif_log_created ON notification_log(created);
CREATE INDEX IF NOT EXISTS idx_notif_log_status ON notification_log(status, scheduled_at);

CREATE TABLE IF NOT EXISTS app_releases (
  version             TEXT NOT NULL,
  channel             TEXT NOT NULL DEFAULT 'stable',
  build               INTEGER NOT NULL,
  released            INTEGER NOT NULL DEFAULT 0,
  apk_key             TEXT NOT NULL DEFAULT '',
  apk_url             TEXT NOT NULL DEFAULT '',
  size                INTEGER NOT NULL DEFAULT 0,
  sha256              TEXT NOT NULL DEFAULT '',
  min_supported_build INTEGER NOT NULL DEFAULT 19,
  mandatory           INTEGER NOT NULL DEFAULT 0,
  notes               TEXT NOT NULL DEFAULT '',
  compatibility       TEXT NOT NULL DEFAULT '',
  published           INTEGER NOT NULL DEFAULT 1,
  created             INTEGER NOT NULL,
  PRIMARY KEY (version, channel)
);
CREATE INDEX IF NOT EXISTS idx_releases_build ON app_releases(channel, build);

CREATE TABLE IF NOT EXISTS remote_config (
  key        TEXT PRIMARY KEY,
  value      TEXT NOT NULL,
  updated    INTEGER NOT NULL,
  updated_by TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS admin_audit (
  id     INTEGER PRIMARY KEY AUTOINCREMENT,
  t      INTEGER NOT NULL,
  email  TEXT NOT NULL DEFAULT '',
  action TEXT NOT NULL,
  detail TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_audit_t ON admin_audit(t);
CREATE TABLE IF NOT EXISTS edge_cache (
  key TEXT PRIMARY KEY,
  body TEXT NOT NULL,
  t INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_edge_cache_t ON edge_cache(t);
