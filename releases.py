"""Verified historical release inventory and blocked-build telemetry.

Every row here is backed by evidence gathered from the actual artifacts: the
APKs on disk were opened with `aapt dump badging` (versionCode, permissions)
and their native/libapp.so was scanned for admin API strings. A release that
could not be found is recorded as UNAVAILABLE rather than guessed at.

Only integer version codes are compared; version names are labels.
"""
import sqlite3
import time
from typing import Dict, List, Optional

import camanime_platform as platform

STATUSES = ("SUPPORTED", "UNSUPPORTED", "BLOCKED", "DEPRECATED", "UNKNOWN")
INSPECTION = ("INSPECTED", "UNAVAILABLE")

_SCHEMA = """
CREATE TABLE IF NOT EXISTS app_releases (
  version_code INTEGER PRIMARY KEY,
  version_name TEXT NOT NULL,
  app_id TEXT NOT NULL DEFAULT 'com.camanime.app',
  status TEXT NOT NULL DEFAULT 'UNKNOWN',
  inspection TEXT NOT NULL DEFAULT 'UNAVAILABLE',
  security TEXT NOT NULL DEFAULT '',
  compatibility TEXT NOT NULL DEFAULT '',
  notes TEXT NOT NULL DEFAULT '',
  apk_url TEXT NOT NULL DEFAULT '',
  sha256 TEXT NOT NULL DEFAULT '',
  released INTEGER NOT NULL DEFAULT 0,
  updated INTEGER NOT NULL,
  updated_by TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS blocked_requests (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  t INTEGER NOT NULL,
  install_id TEXT NOT NULL DEFAULT '',
  version_name TEXT NOT NULL DEFAULT '',
  version_code INTEGER NOT NULL DEFAULT 0,
  path TEXT NOT NULL DEFAULT '',
  reason TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_blocked_t ON blocked_requests(t);
"""

# Evidence for each decision, kept short enough to read in the dashboard.
SEED = [
    {
        "version_code": 12, "version_name": "2.6.1", "status": "BLOCKED",
        "inspection": "INSPECTED",
        "security": "Admin API strings present in libapp.so (/api/admin); no owner MFA; pre-hardening build.",
        "compatibility": "Incompatible with the 2.8 policy surface; no REQUEST_INSTALL_PACKAGES.",
        "notes": "Discontinued by policy (<= 2.6.5). Artifact: CamAnime-2.6.1-android.apk.",
    },
    {
        "version_code": 13, "version_name": "2.6.2", "status": "BLOCKED",
        "inspection": "INSPECTED",
        "security": "Same admin API surface as 2.6.1; no MFA support.",
        "compatibility": "Incompatible; superseded by 2.6.4/2.7.0.",
        "notes": "Discontinued by policy (<= 2.6.5). Artifact: CamAnime-2.6.2-android.apk.",
    },
    {
        "version_code": 15, "version_name": "2.6.4", "status": "BLOCKED",
        "inspection": "INSPECTED",
        "security": "Admin API strings present; in-app installer permission added; no MFA.",
        "compatibility": "Incompatible with current auth/version surface.",
        "notes": "Discontinued by policy (<= 2.6.5). Artifact: CamAnime-2.6.4-android.apk.",
    },
    {
        "version_code": 16, "version_name": "2.6.5", "status": "BLOCKED",
        "inspection": "UNAVAILABLE",
        "security": "Artifact not present on this machine or in any accessible release store, so it was not inspected; it is blocked by numeric policy.",
        "compatibility": "Blocked by policy regardless of inspection.",
        "notes": "No APK found — classification is policy-based, not artifact-based.",
    },
    {
        "version_code": 17, "version_name": "2.7.0", "status": "SUPPORTED",
        "inspection": "INSPECTED",
        "security": "No /api/admin strings in libapp.so; admin surface removed from the APK. Obfuscated release build.",
        "compatibility": "Lowest verified release above 2.6.5; remains the minimum supported build.",
        "notes": "Artifact: CamAnime-2.7.0-android.apk.",
    },
    {
        "version_code": 18, "version_name": "2.8.0", "status": "SUPPORTED",
        "inspection": "INSPECTED",
        "security": "No admin strings; obfuscated Dart; MFA and version enforcement live server-side.",
        "compatibility": "Previous release; still supported above the minimum build.",
        "notes": "Artifact: mobile/apk/CamAnime-2.8.0.apk.",
    },
    {
        "version_code": 19, "version_name": "2.9.0", "status": "SUPPORTED",
        "inspection": "INSPECTED",
        "security": "No admin strings; obfuscated Dart; server-side version gate unchanged.",
        "compatibility": "Current release; provider-published qualities and dubs only.",
        "notes": "Artifact: static/downloads/CamAnime.apk.",
    },
]


def _connect() -> sqlite3.Connection:
    conn = sqlite3.connect(platform.DB_PATH, timeout=15)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def ensure_schema() -> None:
    with _connect() as conn:
        conn.executescript(_SCHEMA)
    seed()


def seed() -> None:
    """Insert discovered releases once; never overwrite an operator decision."""
    now = int(time.time())
    with _connect() as conn:
        for row in SEED:
            conn.execute(
                "INSERT OR IGNORE INTO app_releases("
                "version_code,version_name,status,inspection,security,"
                "compatibility,notes,updated,updated_by)"
                " VALUES (?,?,?,?,?,?,?,?,?)",
                (row["version_code"], row["version_name"], row["status"],
                 row["inspection"], row["security"], row["compatibility"],
                 row["notes"], now, "audit"),
            )


def list_releases() -> List[Dict]:
    ensure_schema()
    with _connect() as conn:
        rows = conn.execute(
            "SELECT * FROM app_releases ORDER BY version_code DESC").fetchall()
    return [dict(r) for r in rows]


def get_release(version_code: int) -> Optional[Dict]:
    ensure_schema()
    with _connect() as conn:
        row = conn.execute("SELECT * FROM app_releases WHERE version_code=?",
                           (int(version_code),)).fetchone()
    return dict(row) if row else None


def set_status(version_code: int, status: str, actor: str,
               notes: str = "") -> Dict:
    status = (status or "").upper().strip()
    if status not in STATUSES:
        raise ValueError(f"Status must be one of {', '.join(STATUSES)}.")
    ensure_schema()
    with _connect() as conn:
        row = conn.execute("SELECT * FROM app_releases WHERE version_code=?",
                           (int(version_code),)).fetchone()
        if not row:
            raise ValueError("Unknown release.")
        conn.execute(
            "UPDATE app_releases SET status=?, notes=?, updated=?, updated_by=?"
            " WHERE version_code=?",
            (status, (notes or row["notes"])[:2000], int(time.time()),
             str(actor or "admin")[:120], int(version_code)),
        )
    return get_release(version_code) or {}


def record_blocked(install_id: str, version_name: str, version_code: int,
                   path: str, reason: str) -> None:
    """Best-effort telemetry for a request refused by the version gate."""
    try:
        ensure_schema()
        with _connect() as conn:
            conn.execute(
                "INSERT INTO blocked_requests(t,install_id,version_name,"
                "version_code,path,reason) VALUES (?,?,?,?,?,?)",
                (int(time.time()), (install_id or "")[:64],
                 (version_name or "")[:24], int(version_code or 0),
                 (path or "")[:120], (reason or "")[:80]),
            )
            conn.execute(
                "DELETE FROM blocked_requests WHERE id NOT IN"
                " (SELECT id FROM blocked_requests ORDER BY id DESC LIMIT 2000)")
    except Exception:
        pass


def blocked_stats(limit: int = 25) -> Dict:
    ensure_schema()
    with _connect() as conn:
        total = conn.execute("SELECT COUNT(*) c FROM blocked_requests").fetchone()["c"]
        recent = conn.execute(
            "SELECT t,version_name,version_code,path,reason FROM blocked_requests"
            " ORDER BY id DESC LIMIT ?", (max(1, min(int(limit or 25), 100)),)
        ).fetchall()
        versions = conn.execute(
            "SELECT version_name, version_code, COUNT(*) c FROM blocked_requests"
            " GROUP BY version_code ORDER BY c DESC LIMIT 10").fetchall()
    return {
        "total": total,
        "recent": [dict(r) for r in recent],
        "versions": [{"version": r["version_name"], "code": r["version_code"],
                      "requests": r["c"]} for r in versions],
    }
