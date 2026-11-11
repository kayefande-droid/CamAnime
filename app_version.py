"""Central application version policy, install registry and admin audit trail.

One row in `version_policy` is the single authority on what release is current
and what build is still allowed to use protected services. The Android app only
*reports* its build number; every decision about whether that build may stream,
download or post is made here, on the server.

Also stores:
- `app_installs`: one row per app installation that has identified itself, with
  the reported version, so obsolete clients can be counted and flagged.
- `admin_audit`: append-only trail of administrative actions (policy changes,
  rollbacks, notification runs) kept to the most recent 500 entries.

Nothing in this module trusts client-supplied version names; comparisons use
integer build codes.
"""
import json
import os
import sqlite3
import time
from typing import Dict, List, Optional

import camanime_platform as platform

DEFAULT_POLICY = {
    "latest_version": "2.14.0",
    "latest_version_code": 27,
    "minimum_supported_version": "2.9.0",
    "minimum_supported_version_code": 19,
    "force_update": 1,
    "download_url": "https://camanime.onrender.com/get/android",
    "release_notes": (
        "Build 27: install fix, version-stamped APK filename, home redesign, "
        "sub/dub switching, device-delete, poster persistence, notifications."
    ),
    "update_message": (
        "Your CamAnime version is outdated. Please update to the latest version "
        "from our official website to continue watching anime."
    ),
    "release_enabled": 1,
}

# Releases at or below this build are discontinued outright: they lose stream
# and download access for good, even if an operator later lowers the general
# minimum. 2.7.0 was versionCode 17, so 17 and anything below it is refused.
DISCONTINUED_AT_OR_BELOW_VERSION = "2.7.0"
DISCONTINUED_AT_OR_BELOW_VERSION_CODE = 17

# 2.9.0 is the mandatory release for the genuine-provider-quality update. This
# floor upgrades policy rows created by older deployments (which still said
# 2.7.0/build 17) so every existing install is moved to 2.9.0 without an
# operator having to edit the row by hand.
MANDATORY_MINIMUM_VERSION = "2.9.0"
MANDATORY_MINIMUM_VERSION_CODE = 19

DISCONTINUED_MESSAGE = (
    "CamAnime 2.7.0 and older are discontinued and can no longer stream or "
    "download anime. Install the current CamAnime from the official website to "
    "continue."
)


def discontinued(build_code) -> bool:
    """True for builds the project has retired (ignores the editable minimum)."""
    try:
        return (build_code is not None
                and int(build_code) <= DISCONTINUED_AT_OR_BELOW_VERSION_CODE)
    except (TypeError, ValueError):
        return False


_SCHEMA = """
CREATE TABLE IF NOT EXISTS version_policy (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  latest_version TEXT NOT NULL,
  latest_version_code INTEGER NOT NULL,
  minimum_supported_version TEXT NOT NULL,
  minimum_supported_version_code INTEGER NOT NULL,
  force_update INTEGER NOT NULL DEFAULT 1,
  download_url TEXT NOT NULL,
  release_notes TEXT NOT NULL DEFAULT '',
  update_message TEXT NOT NULL DEFAULT '',
  release_enabled INTEGER NOT NULL DEFAULT 1,
  updated INTEGER NOT NULL,
  updated_by TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS app_installs (
  install_id TEXT PRIMARY KEY,
  platform TEXT NOT NULL DEFAULT 'android',
  version_name TEXT NOT NULL DEFAULT '',
  version_code INTEGER NOT NULL DEFAULT 0,
  email TEXT NOT NULL DEFAULT '',
  first_seen INTEGER NOT NULL,
  last_seen INTEGER NOT NULL,
  update_notified_for TEXT NOT NULL DEFAULT '',
  update_notified_at INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_installs_seen ON app_installs(last_seen);
CREATE INDEX IF NOT EXISTS idx_installs_code ON app_installs(version_code);
CREATE TABLE IF NOT EXISTS admin_audit (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  t INTEGER NOT NULL,
  email TEXT NOT NULL,
  action TEXT NOT NULL,
  detail TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_audit_t ON admin_audit(t);
"""


def _connect() -> sqlite3.Connection:
    conn = sqlite3.connect(platform.DB_PATH, timeout=15)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def ensure_schema() -> None:
    with _connect() as conn:
        conn.executescript(_SCHEMA)


def get_policy() -> Dict:
    """Current policy, seeded with DEFAULT_POLICY on first read."""
    ensure_schema()
    now = int(time.time())
    with _connect() as conn:
        row = conn.execute("SELECT * FROM version_policy WHERE id=1").fetchone()
        if not row:
            d = DEFAULT_POLICY
            conn.execute(
                "INSERT OR IGNORE INTO version_policy("
                "id,latest_version,latest_version_code,minimum_supported_version,"
                "minimum_supported_version_code,force_update,download_url,"
                "release_notes,update_message,release_enabled,updated,updated_by)"
                " VALUES (1,?,?,?,?,?,?,?,?,?,?,?)",
                (d["latest_version"], d["latest_version_code"],
                 d["minimum_supported_version"],
                 d["minimum_supported_version_code"], d["force_update"],
                 d["download_url"], d["release_notes"], d["update_message"],
                 d["release_enabled"], now, "system"),
            )
            row = conn.execute("SELECT * FROM version_policy WHERE id=1").fetchone()
        # A shipped release must become visible without an operator manually
        # editing the row after every deploy. Only the *latest* fields advance;
        # the minimum supported build remains under operator control.
        if int(row["latest_version_code"]) < int(DEFAULT_POLICY["latest_version_code"]):
            conn.execute(
                "UPDATE version_policy SET latest_version=?, latest_version_code=?,"
                " release_notes=?, updated=?, updated_by='release' WHERE id=1",
                (DEFAULT_POLICY["latest_version"],
                 DEFAULT_POLICY["latest_version_code"],
                 DEFAULT_POLICY["release_notes"], now),
            )
            row = conn.execute("SELECT * FROM version_policy WHERE id=1").fetchone()
        if int(row["minimum_supported_version_code"]) < MANDATORY_MINIMUM_VERSION_CODE:
            conn.execute(
                "UPDATE version_policy SET minimum_supported_version=?,"
                " minimum_supported_version_code=?, updated=?, updated_by='release-floor'"
                " WHERE id=1",
                (MANDATORY_MINIMUM_VERSION, MANDATORY_MINIMUM_VERSION_CODE, now),
            )
            row = conn.execute("SELECT * FROM version_policy WHERE id=1").fetchone()
    return {
        "latest_version": row["latest_version"],
        "latest_version_code": int(row["latest_version_code"]),
        "minimum_supported_version": row["minimum_supported_version"],
        "minimum_supported_version_code": int(row["minimum_supported_version_code"]),
        "force_update": bool(row["force_update"]),
        "download_url": row["download_url"],
        "release_notes": row["release_notes"],
        "update_message": row["update_message"],
        "release_enabled": bool(row["release_enabled"]),
        "updated": int(row["updated"]),
        "updated_by": row["updated_by"],
    }


def update_required(policy: Dict, build_code: Optional[int]) -> bool:
    """True when a reported build must upgrade before protected use.

    An unknown build code (None) means the caller never identified itself as an
    app; that path is treated as a browser and left to the normal website flow
    rather than being blocked.
    """
    if build_code is None:
        return False
    if not policy.get("release_enabled"):
        return False
    return int(build_code) < int(policy["minimum_supported_version_code"])


def _coerce_bool(value) -> bool:
    if isinstance(value, str):
        return value.strip().lower() not in ("", "0", "false", "no", "off")
    return bool(value)


def set_policy(changes: Dict, actor: str) -> Dict:
    """Validate and apply a policy change, recording before/after in the audit."""
    before = get_policy()
    new = dict(before)
    for key in ("latest_version", "minimum_supported_version", "download_url",
                "release_notes", "update_message"):
        if changes.get(key) is not None:
            new[key] = str(changes[key]).strip()[:2000]
    for key in ("latest_version_code", "minimum_supported_version_code"):
        if changes.get(key) not in (None, ""):
            try:
                new[key] = int(changes[key])
            except (TypeError, ValueError):
                raise ValueError(f"{key} must be a whole number.")
            if new[key] < 1:
                raise ValueError(f"{key} must be at least 1.")
    for key in ("force_update", "release_enabled"):
        if changes.get(key) is not None:
            new[key] = _coerce_bool(changes[key])

    if not new["latest_version"] or not new["minimum_supported_version"]:
        raise ValueError("Latest and minimum version names are required.")
    url = new["download_url"]
    if not (url.startswith("https://") or url.startswith("/")):
        raise ValueError("Download URL must be an https:// URL or a site path.")
    if new["minimum_supported_version_code"] > new["latest_version_code"]:
        raise ValueError("The minimum supported build cannot be newer than the latest build.")
    if new["latest_version_code"] < before["latest_version_code"]:
        raise ValueError("Use the rollback action to lower the release build.")

    now = int(time.time())
    with _connect() as conn:
        conn.execute(
            "UPDATE version_policy SET latest_version=?, latest_version_code=?,"
            " minimum_supported_version=?, minimum_supported_version_code=?,"
            " force_update=?, download_url=?, release_notes=?, update_message=?,"
            " release_enabled=?, updated=?, updated_by=? WHERE id=1",
            (new["latest_version"], new["latest_version_code"],
             new["minimum_supported_version"], new["minimum_supported_version_code"],
             1 if new["force_update"] else 0, new["download_url"],
             new["release_notes"], new["update_message"],
             1 if new["release_enabled"] else 0, now, str(actor or "admin")[:120]),
        )
    after = get_policy()
    audit(actor, "version_policy.update",
          json.dumps({"before": before, "after": after}, sort_keys=True))
    return after


def rollback(actor: str) -> Dict:
    """Restore the policy that preceded the most recent change."""
    ensure_schema()
    previous = None
    with _connect() as conn:
        rows = conn.execute(
            "SELECT detail FROM admin_audit WHERE action='version_policy.update'"
            " ORDER BY id DESC LIMIT 2").fetchall()
    if len(rows) >= 2:
        try:
            previous = json.loads(rows[1]["detail"]).get("after")
        except (TypeError, ValueError):
            previous = None
    if not previous:
        previous = DEFAULT_POLICY
    now = int(time.time())
    with _connect() as conn:
        conn.execute(
            "UPDATE version_policy SET latest_version=?, latest_version_code=?,"
            " minimum_supported_version=?, minimum_supported_version_code=?,"
            " force_update=?, download_url=?, release_notes=?, update_message=?,"
            " release_enabled=?, updated=?, updated_by=? WHERE id=1",
            (previous["latest_version"], int(previous["latest_version_code"]),
             previous["minimum_supported_version"],
             int(previous["minimum_supported_version_code"]),
             1 if previous.get("force_update") else 0, previous["download_url"],
             previous.get("release_notes", ""), previous.get("update_message", ""),
             1 if previous.get("release_enabled", 1) else 0, now,
             str(actor or "admin")[:120]),
        )
    audit(actor, "version_policy.rollback", json.dumps(previous, sort_keys=True))
    return get_policy()


def record_install(install_id: str, platform_name: str, version_name: str,
                   version_code: int, email: str = "") -> None:
    install_id = (install_id or "").strip()[:64]
    if not install_id:
        return
    ensure_schema()
    now = int(time.time())
    with _connect() as conn:
        conn.execute(
            "INSERT INTO app_installs(install_id,platform,version_name,version_code,"
            "email,first_seen,last_seen) VALUES (?,?,?,?,?,?,?)"
            " ON CONFLICT(install_id) DO UPDATE SET platform=excluded.platform,"
            " version_name=excluded.version_name, version_code=excluded.version_code,"
            " email=CASE WHEN excluded.email != '' THEN excluded.email"
            "            ELSE app_installs.email END,"
            " last_seen=excluded.last_seen",
            (install_id, (platform_name or "android")[:16],
             (version_name or "")[:24], int(version_code or 0),
             (email or "").strip().lower()[:120], now, now),
        )


def stats(days: int = 30) -> Dict:
    ensure_schema()
    policy = get_policy()
    since = int(time.time()) - max(1, int(days)) * 86400
    with _connect() as conn:
        total = conn.execute("SELECT COUNT(*) c FROM app_installs").fetchone()["c"]
        active = conn.execute(
            "SELECT COUNT(*) c FROM app_installs WHERE last_seen >= ?",
            (since,)).fetchone()["c"]
        outdated = conn.execute(
            "SELECT COUNT(*) c FROM app_installs WHERE version_code < ?",
            (policy["minimum_supported_version_code"],)).fetchone()["c"]
        current = conn.execute(
            "SELECT COUNT(*) c FROM app_installs WHERE version_code >= ?",
            (policy["latest_version_code"],)).fetchone()["c"]
        flagged = conn.execute(
            "SELECT COUNT(*) c FROM app_installs WHERE update_notified_for = ?",
            (policy["latest_version"],)).fetchone()["c"]
        platforms = conn.execute(
            "SELECT platform, COUNT(*) c FROM app_installs GROUP BY platform").fetchall()
        versions = conn.execute(
            "SELECT version_name, version_code, COUNT(*) c FROM app_installs"
            " GROUP BY version_name, version_code"
            " ORDER BY version_code DESC LIMIT 12").fetchall()
    return {
        "devices": total,
        "active_devices": active,
        "outdated_devices": outdated,
        "up_to_date_devices": current,
        "adoption_percent": round(100.0 * current / total, 1) if total else 0.0,
        "flagged_devices": flagged,
        "platforms": {r["platform"]: r["c"] for r in platforms},
        "versions": [{"version": r["version_name"], "code": r["version_code"],
                      "devices": r["c"]} for r in versions],
        "window_days": days,
    }


def outdated_installs(minimum_code: int) -> List[Dict]:
    ensure_schema()
    with _connect() as conn:
        rows = conn.execute(
            "SELECT install_id, platform, version_name, version_code, email,"
            " update_notified_for, last_seen FROM app_installs"
            " WHERE version_code < ? ORDER BY last_seen DESC",
            (int(minimum_code),)).fetchall()
    return [dict(r) for r in rows]


def mark_notified(install_id: str, version: str) -> None:
    ensure_schema()
    with _connect() as conn:
        conn.execute(
            "UPDATE app_installs SET update_notified_for=?, update_notified_at=?"
            " WHERE install_id=?",
            ((version or "")[:24], int(time.time()), install_id))


def audit(actor: str, action: str, detail: str = "") -> None:
    """Append an administrative action. Never raises: auditing is best-effort."""
    try:
        ensure_schema()
        with _connect() as conn:
            conn.execute(
                "INSERT INTO admin_audit(t,email,action,detail) VALUES (?,?,?,?)",
                (int(time.time()), str(actor or "system")[:120],
                 str(action or "")[:80], str(detail or "")[:4000]))
            conn.execute(
                "DELETE FROM admin_audit WHERE id NOT IN"
                " (SELECT id FROM admin_audit ORDER BY id DESC LIMIT 500)")
    except Exception:
        pass


def list_audit(limit: int = 50) -> List[Dict]:
    ensure_schema()
    with _connect() as conn:
        rows = conn.execute(
            "SELECT id,t,email,action,detail FROM admin_audit ORDER BY id DESC LIMIT ?",
            (max(1, min(int(limit or 50), 200)),)).fetchall()
    return [dict(r) for r in rows]


def bootstrap_admin_password_file(db_path: str) -> str:
    """Path of the one-time bootstrap file written next to the SQLite database."""
    folder = os.path.dirname(os.path.abspath(db_path)) or "."
    return os.path.join(folder, "admin_bootstrap.txt")
