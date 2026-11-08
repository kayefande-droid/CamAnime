"""TOTP two-factor authentication for CamAnime administrator accounts.

Implements RFC 6238 (TOTP) and RFC 4226 (HOTP) directly with the standard
library: HMAC-SHA1 over a 30-second counter, six digits, one step of clock
drift tolerated. Nothing is trusted from the client beyond the six digits.

Also stores one-time recovery codes (hashed with SHA-256) so a lost phone does
not permanently lock the owner out of the dashboard, and remembers the last
accepted time step so a captured code cannot be replayed.

Set CAMANIME_ADMIN_MFA_REQUIRED=1 to refuse admin sign-in until the account has
enrolled. By default enrolment is offered in the dashboard and enforced for any
admin account that has completed it.
"""
import base64
import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import struct
import time
from typing import Dict, List, Optional, Tuple

import camanime_platform as platform

DIGITS = 6
STEP_SECONDS = 30
DRIFT_STEPS = 1
ISSUER = os.environ.get("CAMANIME_MFA_ISSUER", "CamAnime")

_SCHEMA = """
CREATE TABLE IF NOT EXISTS admin_mfa (
  email TEXT PRIMARY KEY,
  secret TEXT NOT NULL DEFAULT '',
  enabled INTEGER NOT NULL DEFAULT 0,
  last_step INTEGER NOT NULL DEFAULT 0,
  created INTEGER NOT NULL,
  enabled_at INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS admin_mfa_recovery (
  email TEXT NOT NULL,
  code_hash TEXT NOT NULL,
  used INTEGER NOT NULL DEFAULT 0,
  created INTEGER NOT NULL,
  PRIMARY KEY (email, code_hash)
);
"""


def _connect() -> sqlite3.Connection:
    conn = sqlite3.connect(platform.DB_PATH, timeout=15)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def ensure_schema() -> None:
    with _connect() as conn:
        conn.executescript(_SCHEMA)


def required() -> bool:
    """True when the deployment forces admins to enrol before signing in."""
    return (os.environ.get("CAMANIME_ADMIN_MFA_REQUIRED", "0").strip().lower()
            in ("1", "true", "yes", "on"))


# ── Base32 + HOTP/TOTP ────────────────────────────────────────────────

def _b32encode(raw: bytes) -> str:
    return base64.b32encode(raw).decode("ascii").rstrip("=")


def _b32decode(secret: str) -> bytes:
    cleaned = "".join(ch for ch in (secret or "").upper()
                      if ch in "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    cleaned += "=" * ((8 - len(cleaned) % 8) % 8)
    return base64.b32decode(cleaned, casefold=True)


def generate_secret(length: int = 20) -> str:
    return _b32encode(secrets.token_bytes(length))


def _hotp(secret: str, counter: int, digits: int = DIGITS) -> str:
    digest = hmac.new(_b32decode(secret), struct.pack(">Q", int(counter)),
                      hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    value = struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF
    return str(value % (10 ** digits)).zfill(digits)


def code_at(secret: str, at: Optional[float] = None, digits: int = DIGITS) -> str:
    """The code an authenticator app shows for `secret` right now."""
    stamp = int(at if at is not None else time.time())
    return _hotp(secret, stamp // STEP_SECONDS, digits)


def _match_step(secret: str, code: str, at: Optional[float] = None,
                drift: int = DRIFT_STEPS) -> Optional[int]:
    """Time step the submitted code belongs to, or None when it is wrong."""
    candidate = "".join(ch for ch in (code or "") if ch.isdigit())
    if len(candidate) != DIGITS:
        return None
    current = int(at if at is not None else time.time()) // STEP_SECONDS
    for offset in range(-drift, drift + 1):
        step = current + offset
        if hmac.compare_digest(_hotp(secret, step), candidate):
            return step
    return None


def verify_code(secret: str, code: str, at: Optional[float] = None) -> bool:
    return _match_step(secret, code, at) is not None


def otpauth_url(email: str, secret: str) -> str:
    """otpauth:// URI an authenticator app can import (or render as a QR)."""
    label = f"{ISSUER}:{email}".replace(" ", "%20")
    params = (f"secret={secret}&issuer={ISSUER}&algorithm=SHA1"
              f"&digits={DIGITS}&period={STEP_SECONDS}")
    return f"otpauth://totp/{label}?{params}"


# ── Storage ───────────────────────────────────────────────────────────

def _row(email: str):
    ensure_schema()
    with _connect() as conn:
        return conn.execute("SELECT * FROM admin_mfa WHERE email=?",
                            ((email or "").lower(),)).fetchone()


def is_enabled(email: str) -> bool:
    row = _row(email)
    return bool(row and row["enabled"])


def status(email: str) -> Dict:
    row = _row(email)
    remaining = 0
    if row:
        with _connect() as conn:
            remaining = conn.execute(
                "SELECT COUNT(*) c FROM admin_mfa_recovery"
                " WHERE email=? AND used=0", ((email or "").lower(),)
            ).fetchone()["c"]
    return {
        "enabled": bool(row and row["enabled"]),
        "pending_enrollment": bool(row and not row["enabled"]),
        "recovery_codes_remaining": remaining,
        "required": required(),
        "issuer": ISSUER,
        "digits": DIGITS,
        "period": STEP_SECONDS,
    }


def begin_enrollment(email: str) -> Dict:
    """Create a fresh secret for this admin; not active until confirmed."""
    key = (email or "").strip().lower()
    if not key:
        raise ValueError("Sign in before enrolling.")
    if is_enabled(key):
        raise ValueError("Two-factor authentication is already enabled. "
                         "Disable it before enrolling again.")
    secret = generate_secret()
    now = int(time.time())
    ensure_schema()
    with _connect() as conn:
        conn.execute(
            "INSERT INTO admin_mfa(email,secret,enabled,last_step,created,enabled_at)"
            " VALUES (?,?,0,0,?,0)"
            " ON CONFLICT(email) DO UPDATE SET secret=excluded.secret,"
            " enabled=0, last_step=0, created=excluded.created",
            (key, secret, now),
        )
    return {
        "secret": secret,
        "otpauth_url": otpauth_url(key, secret),
        "issuer": ISSUER,
        "digits": DIGITS,
        "period": STEP_SECONDS,
        "instructions": ("Add this secret to Google Authenticator, Authy, 1Password "
                         "or any TOTP app, then enter the current 6-digit code."),
    }


def confirm_enrollment(email: str, code: str) -> List[str]:
    """Activate MFA once the current code proves the authenticator works."""
    key = (email or "").strip().lower()
    row = _row(key)
    if not row:
        raise ValueError("Start enrolment first.")
    if row["enabled"]:
        raise ValueError("Two-factor authentication is already enabled.")
    step = _match_step(row["secret"], code)
    if step is None:
        raise ValueError("That code is not valid. Check the clock on your phone "
                         "and enter the current 6-digit code.")
    recovery = _new_recovery_codes(key)
    now = int(time.time())
    with _connect() as conn:
        conn.execute(
            "UPDATE admin_mfa SET enabled=1, enabled_at=?, last_step=? WHERE email=?",
            (now, step, key),
        )
    return recovery


def _hash_recovery(code: str) -> str:
    return hashlib.sha256(("camanime:mfa:" + code.replace("-", "").upper())
                          .encode()).hexdigest()


def _new_recovery_codes(email: str) -> List[str]:
    codes: List[str] = []
    rows: List[Tuple[str, str, int, int]] = []
    now = int(time.time())
    for _ in range(8):
        raw = secrets.token_hex(4).upper()
        code = f"{raw[:4]}-{raw[4:]}"
        codes.append(code)
        rows.append((email, _hash_recovery(code), 0, now))
    with _connect() as conn:
        conn.execute("DELETE FROM admin_mfa_recovery WHERE email=?", (email,))
        conn.executemany(
            "INSERT OR REPLACE INTO admin_mfa_recovery(email,code_hash,used,created)"
            " VALUES (?,?,?,?)", rows)
    return codes


def _use_recovery_code(email: str, code: str) -> bool:
    cleaned = (code or "").replace("-", "").replace(" ", "").upper()
    if len(cleaned) != 8 or not all(c in "0123456789ABCDEF" for c in cleaned):
        return False
    digest = _hash_recovery(cleaned)
    with _connect() as conn:
        row = conn.execute(
            "SELECT 1 FROM admin_mfa_recovery WHERE email=? AND code_hash=? AND used=0",
            (email, digest)).fetchone()
        if not row:
            return False
        conn.execute(
            "UPDATE admin_mfa_recovery SET used=1 WHERE email=? AND code_hash=?",
            (email, digest))
    return True


def verify_login(email: str, code: Optional[str]) -> bool:
    """Second factor check. True when MFA is off, or the code/recovery matches.

    A TOTP code is accepted at most once: the last accepted step is stored, so
    replaying a code that was just used (or an older one from the drift window)
    fails.
    """
    key = (email or "").strip().lower()
    row = _row(key)
    if not row or not row["enabled"]:
        return True
    step = _match_step(row["secret"], code or "")
    if step is not None and step > int(row["last_step"]):
        with _connect() as conn:
            conn.execute("UPDATE admin_mfa SET last_step=? WHERE email=?",
                         (step, key))
        return True
    return _use_recovery_code(key, code or "")


def disable(email: str, code: Optional[str]) -> None:
    """Remove the second factor. Requires a valid current code or recovery code."""
    key = (email or "").strip().lower()
    if not is_enabled(key):
        raise ValueError("Two-factor authentication is not enabled.")
    row = _row(key)
    step = _match_step((row or {})["secret"], code or "")
    if step is not None and step <= int(row["last_step"]):
        # The code is correct but was already spent (usually the one used to
        # confirm enrolment seconds ago). Say so instead of "wrong code".
        raise ValueError("That code was already used. Wait for your "
                         "authenticator to show the next one, then try again.")
    if not verify_login(key, code):
        raise ValueError("Enter the current 6-digit code (or a recovery code) "
                         "to turn two-factor authentication off.")
    with _connect() as conn:
        conn.execute("DELETE FROM admin_mfa WHERE email=?", (key,))
        conn.execute("DELETE FROM admin_mfa_recovery WHERE email=?", (key,))


def snapshot() -> Dict:
    """Counts for the dashboard, never exposing secrets."""
    ensure_schema()
    with _connect() as conn:
        enabled = conn.execute(
            "SELECT COUNT(*) c FROM admin_mfa WHERE enabled=1").fetchone()["c"]
        pending = conn.execute(
            "SELECT COUNT(*) c FROM admin_mfa WHERE enabled=0").fetchone()["c"]
    return {"enrolled_admins": enabled, "pending_enrollment": pending,
            "required": required()}
