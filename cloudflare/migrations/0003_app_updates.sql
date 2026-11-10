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
