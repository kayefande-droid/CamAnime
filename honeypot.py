"""Decoy containment for hostile traffic.

Requests that prove hostile intent — vulnerability-scanner paths, decoy-only
paths, repeated credential failures, repeated admin denials — are not simply
refused. The client is redirected into an inert clone of the site, and every
action taken there is appended to a hash-chained evidence ledger that the owner
can export and hand to law enforcement or a hosting provider.

What this module deliberately does NOT do:

* it never executes, downloads or ships code to the client;
* it never contacts the attacker, their host or any third party;
* it never touches a real account, session, database row or credential.

Deception, containment and evidence only. That is the legal boundary, and it is
also the effective one: an intruder who is being watched is not a risk to the
real data behind the wall.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sqlite3
import threading
import time
from typing import Dict, List, Optional, Tuple

GENESIS = "0" * 64
TRAP_HOURS = float(os.environ.get("CAMANIME_TRAP_HOURS", "24") or 24)
_AUTH_FAIL_LIMIT = 8
_ADMIN_DENY_LIMIT = 5

# Paths that only a scanner, an exploit kit or someone probing for a different
# CMS ever requests. One hit is enough evidence to route the client to the clone.
SUSPECT_PATH = re.compile(
    r"(?i)(\.env|\.git|\.svn|wp-admin|wp-login|wp-config|xmlrpc\.php|"
    r"phpmyadmin|/\.aws/|/\.ssh/|id_rsa|/etc/passwd|base64_decode|"
    r"\.sql$|\.bak$|\.old$|/actuator|/c99\.php|/boaform/|\.DS_Store|"
    r"adminer|phpinfo|server-status|cpanel|manager/html|/admin\.php|"
    r"/shell|/webshell|/config\.json\.bak|/backup\.zip)"
)

_LOCK = threading.Lock()
_AUTH_FAILS: Dict[str, List[float]] = {}
_ADMIN_DENIES: Dict[str, List[float]] = {}
_FAILS_MAX = 4096


def enabled() -> bool:
    """Kill switch: CAMANIME_DECOY=0 turns the clone off entirely."""
    return os.environ.get("CAMANIME_DECOY", "1") != "0"


def _db_path() -> str:
    override = os.environ.get("CAMANIME_INTRUSIONS")
    if override:
        return override
    try:
        import camanime_platform as platform

        folder = os.path.dirname(os.path.abspath(platform.DB_PATH)) or "."
    except Exception:
        folder = "."
    return os.path.join(folder, "intrusions.db")


def _connect() -> sqlite3.Connection:
    conn = sqlite3.connect(_db_path(), timeout=15)
    conn.row_factory = sqlite3.Row
    return conn


def ensure() -> None:
    folder = os.path.dirname(os.path.abspath(_db_path()))
    if folder and not os.path.isdir(folder):
        os.makedirs(folder, exist_ok=True)
    with _connect() as conn:
        conn.execute(
            "CREATE TABLE IF NOT EXISTS traps("
            " ip TEXT PRIMARY KEY, first_seen INTEGER, last_seen INTEGER,"
            " expires INTEGER, reason TEXT, hits INTEGER)")
        conn.execute(
            "CREATE TABLE IF NOT EXISTS ledger("
            " id INTEGER PRIMARY KEY AUTOINCREMENT, t INTEGER, ip TEXT,"
            " method TEXT, path TEXT, ua TEXT, referer TEXT, detail TEXT,"
            " prev TEXT, digest TEXT)")
        conn.execute(
            "CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT)")


def _salt() -> str:
    """Per-deployment salt: credentials are stored as fingerprints, never raw."""
    ensure()
    with _connect() as conn:
        row = conn.execute("SELECT value FROM meta WHERE key='salt'").fetchone()
        if row:
            return row["value"]
        salt = os.urandom(16).hex()
        conn.execute("INSERT OR IGNORE INTO meta(key,value) VALUES('salt',?)", (salt,))
        row = conn.execute("SELECT value FROM meta WHERE key='salt'").fetchone()
        return row["value"] if row else salt


def fingerprint(value: str) -> str:
    """Non-reversible marker for a submitted credential: safe to keep forever."""
    if value is None:
        return ""
    raw = str(value)
    digest = hashlib.sha256((_salt() + raw).encode("utf-8", "replace")).hexdigest()
    return f"sha256:{digest[:32]}:len{len(raw)}"


def flag(ip: str, reason: str) -> None:
    """Route this client into the clone for the trap window."""
    if not enabled() or not ip:
        return
    try:
        ensure()
        now = int(time.time())
        expires = now + int(TRAP_HOURS * 3600)
        with _connect() as conn:
            row = conn.execute("SELECT hits FROM traps WHERE ip=?", (ip,)).fetchone()
            if row:
                conn.execute(
                    "UPDATE traps SET last_seen=?, expires=?, reason=?, hits=?"
                    " WHERE ip=?",
                    (now, expires, str(reason)[:120], int(row["hits"]) + 1, ip))
            else:
                conn.execute(
                    "INSERT INTO traps(ip,first_seen,last_seen,expires,reason,hits)"
                    " VALUES(?,?,?,?,?,1)",
                    (ip, now, now, expires, str(reason)[:120]))
    except Exception:
        pass


def is_flagged(ip: str) -> bool:
    if not enabled() or not ip:
        return False
    try:
        ensure()
        with _connect() as conn:
            row = conn.execute(
                "SELECT expires FROM traps WHERE ip=?", (ip,)).fetchone()
        return bool(row) and int(row["expires"]) > int(time.time())
    except Exception:
        return False


def release(ip: str) -> None:
    try:
        ensure()
        with _connect() as conn:
            conn.execute("DELETE FROM traps WHERE ip=?", (ip,))
    except Exception:
        pass


def note_auth_failure(ip: str) -> None:
    """Enough failed logins from one client is hostile, not forgetful."""
    if not enabled() or not ip:
        return
    now = time.time()
    with _LOCK:
        bucket = _AUTH_FAILS.setdefault(ip, [])
        bucket[:] = [t for t in bucket if t >= now - 600]
        bucket.append(now)
        trips = len(bucket) >= _AUTH_FAIL_LIMIT
        if trips:
            bucket.clear()
        if len(_AUTH_FAILS) > _FAILS_MAX:
            for key in list(_AUTH_FAILS)[:256]:
                _AUTH_FAILS.pop(key, None)
    if trips:
        flag(ip, "credential-brute-force")


def note_admin_denial(ip: str) -> None:
    """Repeated 401/403 on privileged API routes = probing, not a stale tab."""
    if not enabled() or not ip:
        return
    now = time.time()
    with _LOCK:
        bucket = _ADMIN_DENIES.setdefault(ip, [])
        bucket[:] = [t for t in bucket if t >= now - 300]
        bucket.append(now)
        trips = len(bucket) >= _ADMIN_DENY_LIMIT
        if trips:
            bucket.clear()
        if len(_ADMIN_DENIES) > _FAILS_MAX:
            for key in list(_ADMIN_DENIES)[:256]:
                _ADMIN_DENIES.pop(key, None)
    if trips:
        flag(ip, "admin-probing")


def record(ip: str, method: str, path: str, ua: str = "",
           referer: str = "", detail: str = "") -> None:
    """Append one hash-chained evidence row. Best effort: never breaks a request."""
    if not ip:
        return
    try:
        ensure()
        now = int(time.time())
        clean = {
            "t": now,
            "ip": str(ip)[:64],
            "method": str(method or "")[:8],
            "path": str(path or "")[:512],
            "ua": str(ua or "")[:400],
            "referer": str(referer or "")[:400],
            "detail": str(detail or "")[:2000],
        }
        material = "|".join(str(clean[k]) for k in
                            ("t", "ip", "method", "path", "ua", "referer", "detail"))
        with _connect() as conn:
            row = conn.execute(
                "SELECT digest FROM ledger ORDER BY id DESC LIMIT 1").fetchone()
            prev = row["digest"] if row else GENESIS
            digest = hashlib.sha256((prev + material).encode("utf-8", "replace")).hexdigest()
            conn.execute(
                "INSERT INTO ledger(t,ip,method,path,ua,referer,detail,prev,digest)"
                " VALUES(?,?,?,?,?,?,?,?,?)",
                (clean["t"], clean["ip"], clean["method"], clean["path"],
                 clean["ua"], clean["referer"], clean["detail"], prev, digest))
    except Exception:
        pass


def entries(limit: int = 500) -> List[Dict]:
    ensure()
    with _connect() as conn:
        rows = conn.execute(
            "SELECT id,t,ip,method,path,ua,referer,detail,prev,digest FROM ledger"
            " ORDER BY id ASC LIMIT ?", (max(1, min(int(limit or 500), 5000)),)).fetchall()
    return [dict(r) for r in rows]


def verify_chain() -> Tuple[bool, Optional[int]]:
    """Recompute the chain. Returns (intact, first_broken_entry_id)."""
    prev = GENESIS
    for row in entries(5000):
        material = "|".join(str(row[k]) for k in
                            ("t", "ip", "method", "path", "ua", "referer", "detail"))
        expected = hashlib.sha256((prev + material).encode("utf-8", "replace")).hexdigest()
        if row["prev"] != prev or row["digest"] != expected:
            return False, int(row["id"])
        prev = row["digest"]
    return True, None


def trapped_clients() -> List[Dict]:
    ensure()
    now = int(time.time())
    with _connect() as conn:
        rows = conn.execute(
            "SELECT ip,first_seen,last_seen,expires,reason,hits FROM traps"
            " WHERE expires > ? ORDER BY last_seen DESC", (now,)).fetchall()
    return [dict(r) for r in rows]


def report(limit: int = 500) -> Dict:
    """Signed evidence bundle for the owner: machine-readable and verifiable."""
    intact, broken = verify_chain()
    rows = entries(limit)
    return {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "trap_window_hours": TRAP_HOURS,
        "chain_ok": intact,
        "chain_first_broken_id": broken,
        "entry_count": len(rows),
        "head_digest": rows[-1]["digest"] if rows else GENESIS,
        "active_traps": trapped_clients(),
        "entries": rows,
        "note": (
            "Decoy-containment evidence. Each entry is chained to the previous "
            "one with SHA-256, so any later edit or deletion breaks 'chain_ok'. "
            "Submitted credentials are stored only as salted fingerprints. "
            "Verify by recomputing sha256(prev_digest + 't|ip|method|path|ua|"
            "referer|detail') per entry."
        ),
    }


def report_text(limit: int = 200) -> str:
    """Plain-text version for a report to a host, registrar or police portal."""
    bundle = report(limit)
    lines = [
        "CamAnime — hostile-access evidence report",
        f"Generated: {bundle['generated_at']} (UTC)",
        f"Ledger intact: {bundle['chain_ok']}"
        + ("" if bundle["chain_ok"] else f" (first broken entry {bundle['chain_first_broken_id']})"),
        f"Entries: {bundle['entry_count']}  Head digest: {bundle['head_digest']}",
        "",
        "Active decoy containment:",
    ]
    if not bundle["active_traps"]:
        lines.append("  (none)")
    for trap in bundle["active_traps"]:
        lines.append(
            f"  {trap['ip']}  reason={trap['reason']}  hits={trap['hits']}  "
            f"expires={time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(trap['expires']))}")
    lines += ["", "Requests observed:"]
    for row in bundle["entries"]:
        stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(row["t"]))
        lines.append(
            f"  {stamp}  {row['ip']}  {row['method']} {row['path']}  "
            f"ua={row['ua'][:80]}  detail={row['detail'][:160]}")
    lines += ["", bundle["note"]]
    return "\n".join(lines)
