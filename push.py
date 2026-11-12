"""Remote push delivery for update notices (Firebase Cloud Messaging HTTP v1).

The server keeps the device tokens the app registers, and can deliver a real
OS notification to devices that are running a build below the minimum, even
when the app is closed. Delivery uses the FCM HTTP v1 API with an OAuth2 access
token derived from a Firebase service account (RS256 JWT assertion, signed with
`cryptography`) — no extra SDK and no Google client library.

Configuration (environment, never committed):

- ``FCM_SERVICE_ACCOUNT_JSON``  full service-account JSON as a string, or
- ``FCM_SERVICE_ACCOUNT_FILE``  path to the downloaded service-account JSON
  (``firebase-service-account.json`` in the project root is also picked up).

Without one of those, the transport honestly reports itself as unavailable and
delivers nothing: nothing pretends to have been pushed. ``CAMANIME_FCM_ENDPOINT``
overrides the API base URL (used by the test-suite against a local stub).
"""
import json
import os
import sqlite3
import time
from typing import Dict, List, Optional, Tuple
from urllib.parse import urlencode

import requests
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding

import camanime_platform as platform

SCOPE = "https://www.googleapis.com/auth/firebase.messaging"
DEFAULT_ENDPOINT = "https://fcm.googleapis.com"
TIMEOUT = 8

_SCHEMA = """
CREATE TABLE IF NOT EXISTS push_tokens (
  install_id TEXT PRIMARY KEY,
  token TEXT NOT NULL,
  platform TEXT NOT NULL DEFAULT 'android',
  email TEXT NOT NULL DEFAULT '',
  created INTEGER NOT NULL,
  updated INTEGER NOT NULL,
  last_error TEXT NOT NULL DEFAULT '',
  last_sent INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_push_tokens_token ON push_tokens(token);
"""

_service_cache: Dict[str, object] = {}
_token_cache: Dict[str, object] = {"value": "", "expires": 0.0}


def _connect():
    return platform.db()


_CAMPAIGN_SCHEMA = """
CREATE TABLE IF NOT EXISTS push_campaigns (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  t INTEGER NOT NULL,
  title TEXT NOT NULL DEFAULT '',
  body TEXT NOT NULL DEFAULT '',
  actor TEXT NOT NULL DEFAULT '',
  available INTEGER NOT NULL DEFAULT 0,
  targets INTEGER NOT NULL DEFAULT 0,
  delivered INTEGER NOT NULL DEFAULT 0,
  failed INTEGER NOT NULL DEFAULT 0,
  pruned INTEGER NOT NULL DEFAULT 0
);
"""


_META_SCHEMA = """
CREATE TABLE IF NOT EXISTS push_meta (
  k TEXT PRIMARY KEY,
  v TEXT NOT NULL,
  updated INTEGER NOT NULL
);
"""

def ensure_schema() -> None:
    with _connect() as conn:
        conn.executescript(_SCHEMA)
        conn.executescript(_CAMPAIGN_SCHEMA)
        conn.executescript(_META_SCHEMA)


def record_campaign(actor: str, title: str, body: str, result: Dict) -> int:
    """Persist the measured result of one notification run (never estimated)."""
    ensure_schema()
    with _connect() as conn:
        cur = conn.execute(
            "INSERT INTO push_campaigns(t,title,body,actor,available,targets,"
            "delivered,failed,pruned) VALUES (?,?,?,?,?,?,?,?,?)",
            (int(time.time()), (title or "")[:120], (body or "")[:500],
             (actor or "")[:120], 1 if result.get("available") else 0,
             int(result.get("targets") or 0), int(result.get("delivered") or 0),
             int(result.get("failed") or 0), int(result.get("pruned") or 0)),
        )
    return int(cur.lastrowid or 0)


def list_campaigns(limit: int = 10) -> list:
    ensure_schema()
    with _connect() as conn:
        rows = conn.execute(
            "SELECT id,t,title,actor,available,targets,delivered,failed,pruned"
            " FROM push_campaigns ORDER BY id DESC LIMIT ?",
            (max(1, min(int(limit or 10), 50)),)).fetchall()
    return [dict(r) for r in rows]


# ── Credentials ───────────────────────────────────────────────────────

def _service_account() -> Optional[Dict]:
    """Parsed service account, or None when this deployment has no sender."""
    raw = os.environ.get("FCM_SERVICE_ACCOUNT_JSON", "").strip()
    path = os.environ.get("FCM_SERVICE_ACCOUNT_FILE", "").strip()
    source = raw
    if not source and path and os.path.isfile(path):
        try:
            with open(path, "r", encoding="utf-8") as fh:
                source = fh.read()
        except OSError:
            source = ""
    if not source:
        fallback = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "firebase-service-account.json")
        if os.path.isfile(fallback):
            try:
                with open(fallback, "r", encoding="utf-8") as fh:
                    source = fh.read()
            except OSError:
                source = ""
    if not source:
        return None
    try:
        data = json.loads(source)
    except (TypeError, ValueError):
        return None
    if not data.get("client_email") or not data.get("private_key"):
        return None
    data.setdefault("token_uri", "https://oauth2.googleapis.com/token")
    return data


def available() -> bool:
    return _service_account() is not None


def _endpoint() -> str:
    return (os.environ.get("CAMANIME_FCM_ENDPOINT", "").strip().rstrip("/")
            or DEFAULT_ENDPOINT)


def _b64url(raw: bytes) -> str:
    import base64
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def _jwt_assertion(account: Dict) -> str:
    """Signed RS256 JWT proving we own the service account."""
    now = int(time.time())
    header = {"alg": "RS256", "typ": "JWT"}
    claims = {
        "iss": account["client_email"],
        "scope": SCOPE,
        "aud": account.get("token_uri", "https://oauth2.googleapis.com/token"),
        "iat": now,
        "exp": now + 3600,
    }
    signing_input = (f"{_b64url(json.dumps(header, separators=(',', ':')).encode())}."
                     f"{_b64url(json.dumps(claims, separators=(',', ':')).encode())}")
    key = serialization.load_pem_private_key(
        account["private_key"].encode(), password=None)
    signature = key.sign(signing_input.encode(), padding.PKCS1v15(), hashes.SHA256())
    return f"{signing_input}.{_b64url(signature)}"


def _access_token(account: Dict) -> str:
    cached = str(_token_cache.get("value") or "")
    if cached and float(_token_cache.get("expires") or 0) > time.time() + 60:
        return cached
    assertion = _jwt_assertion(account)
    resp = requests.post(
        account.get("token_uri", "https://oauth2.googleapis.com/token"),
        data=urlencode({
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": assertion,
        }),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        timeout=TIMEOUT,
    )
    resp.raise_for_status()
    payload = resp.json()
    token = str(payload.get("access_token") or "")
    if not token:
        raise RuntimeError("OAuth token response contained no access_token")
    _token_cache["value"] = token
    _token_cache["expires"] = time.time() + int(payload.get("expires_in") or 3000)
    return token


# ── Token registry ────────────────────────────────────────────────────

def register(install_id: str, token: str, platform_name: str = "android",
             email: str = "") -> None:
    install_id = (install_id or "").strip()[:64]
    token = (token or "").strip()[:4096]
    if not install_id or not token:
        raise ValueError("A device token and install id are required.")
    ensure_schema()
    now = int(time.time())
    with _connect() as conn:
        conn.execute(
            "INSERT INTO push_tokens(install_id,token,platform,email,created,updated)"
            " VALUES (?,?,?,?,?,?)"
            " ON CONFLICT(install_id) DO UPDATE SET token=excluded.token,"
            " platform=excluded.platform, updated=excluded.updated,"
            " email=CASE WHEN excluded.email != '' THEN excluded.email"
            "            ELSE push_tokens.email END",
            (install_id, token, (platform_name or "android")[:16],
             (email or "").strip().lower()[:120], now, now),
        )


def unregister(install_id: str) -> None:
    ensure_schema()
    with _connect() as conn:
        conn.execute("DELETE FROM push_tokens WHERE install_id=?",
                     ((install_id or "").strip()[:64],))


def tokens_for(install_ids: List[str]) -> List[sqlite3.Row]:
    ids = [i for i in install_ids if i]
    if not ids:
        return []
    ensure_schema()
    placeholders = ",".join("?" * len(ids))
    with _connect() as conn:
        return conn.execute(
            f"SELECT * FROM push_tokens WHERE install_id IN ({placeholders})",
            tuple(ids)).fetchall()


def token_count() -> int:
    ensure_schema()
    with _connect() as conn:
        return conn.execute("SELECT COUNT(*) c FROM push_tokens").fetchone()["c"]


def _prune(token: str, error: str) -> None:
    ensure_schema()
    with _connect() as conn:
        conn.execute("DELETE FROM push_tokens WHERE token=?", (token,))
    _ = error


def _stamp(token: str, error: str = "") -> None:
    ensure_schema()
    with _connect() as conn:
        conn.execute(
            "UPDATE push_tokens SET last_error=?, last_sent=? WHERE token=?",
            ((error or "")[:200], int(time.time()), token))


# ── Delivery ──────────────────────────────────────────────────────────

def _is_dead_token(status: int, body: Dict) -> bool:
    """FCM says the token can never work again (uninstalled/reinstalled app)."""
    if status != 404 and status != 400:
        return False
    text = json.dumps(body or {}).lower()
    return ("unregistered" in text or "registration token is not a valid" in text
            or "requested entity was not found" in text)


def _send_one(account: Dict, access: str, row: sqlite3.Row,
              title: str, body: str, data: Dict) -> Tuple[bool, bool, str]:
    """Returns (delivered, token_is_dead, error_message)."""
    message = {
        "message": {
            "token": row["token"],
            "notification": {"title": title, "body": body},
            "data": {str(k): str(v) for k, v in (data or {}).items()},
            "android": {
                "priority": "HIGH",
                "notification": {
                    "channel_id": "camanime_updates",
                    "click_action": "FLUTTER_NOTIFICATION_CLICK",
                },
            },
        }
    }
    url = (f"{_endpoint()}/v1/projects/{account.get('project_id', '')}"
           "/messages:send")
    last_error = ""
    for attempt in range(2):
        try:
            resp = requests.post(
                url,
                json=message,
                headers={"Authorization": f"Bearer {access}",
                         "Content-Type": "application/json"},
                timeout=TIMEOUT,
            )
            status = int(resp.status_code)
            try:
                payload = resp.json()
            except ValueError:
                payload = {}
            if status < 300:
                return True, False, ""
            if _is_dead_token(status, payload):
                return False, True, "unregistered"
            last_error = _error_text(payload) or f"HTTP {status}"
            if status in (429, 500, 502, 503, 504) and attempt == 0:
                time.sleep(0.4)
                continue
            return False, False, last_error
        except requests.RequestException as exc:
            last_error = str(exc)[:200]
            if attempt == 0:
                time.sleep(0.4)
    return False, False, last_error or "network error"


def _error_text(payload: Dict) -> str:
    try:
        return str(((payload or {}).get("error") or {}).get("status")
                   or (payload or {}).get("error") or "")[:200]
    except Exception:
        return ""


def all_tokens(limit: int = 5000) -> List[sqlite3.Row]:
    """Every install that registered a push address, newest first."""
    ensure_schema()
    with _connect() as conn:
        return conn.execute(
            "SELECT * FROM push_tokens ORDER BY updated DESC LIMIT ?",
            (max(1, min(int(limit or 5000), 10000)),)).fetchall()


def _deliver(account: Optional[Dict], targets: List[sqlite3.Row], title: str,
             body: str, data: Dict) -> Dict:
    """Deliver one notification per target, counting only real acceptances."""
    result = {
        "available": account is not None,
        "targets": len(targets),
        "delivered": 0,
        "failed": 0,
        "pruned": 0,
        "errors": [],
    }
    if account is None or not targets:
        return result
    try:
        access = _access_token(account)
    except Exception as exc:  # noqa: BLE001 - reported, never raised to the UI
        result["errors"].append(f"auth: {str(exc)[:160]}")
        result["available"] = False
        return result
    for row in targets:
        ok, dead, error = _send_one(account, access, row, title, body, data or {})
        if ok:
            result["delivered"] += 1
            _stamp(row["token"])
            continue
        result["failed"] += 1
        if dead:
            _prune(row["token"], error)
            result["pruned"] += 1
            continue
        _stamp(row["token"], error)
        if error and error not in result["errors"]:
            result["errors"].append(error)
    return result


def _meta_get(key: str) -> str:
    ensure_schema()
    with _connect() as conn:
        row = conn.execute("SELECT v FROM push_meta WHERE k=?",
                            (key,)).fetchone()
    return str(row["v"]) if row else ""

def _meta_set(key: str, value: str) -> None:
    ensure_schema()
    with _connect() as conn:
        conn.execute(
            "INSERT INTO push_meta(k,v,updated) VALUES (?,?,?)"
            " ON CONFLICT(k) DO UPDATE SET v=excluded.v, updated=excluded.updated",
            (key, str(value), int(time.time())),
        )

def announce_release_once(version: str, build_code: int, notes: str = "") -> Dict:
    """Notify every registered install about a build, at most once per build.

    This runs on the server, so it reaches devices whose app is closed or was
    killed: the notification is posted by the OS from the FCM message, not by
    the app process. A build is only marked announced once at least one device
    was reached, so an early deploy cannot silence a release for everybody.
    """
    account = _service_account()
    result: Dict = {"available": account is not None, "targets": 0,
                    "delivered": 0, "failed": 0, "pruned": 0, "errors": [],
                    "skipped": False}
    if account is None:
        return result
    try:
        announced = int(_meta_get("announced_build_code") or 0)
    except ValueError:
        announced = 0
    if int(build_code) <= announced:
        result["skipped"] = True
        return result
    title = f"CamAnime {version} is available"
    body = (notes or "A new CamAnime build is ready. Tap to update.").strip()[:180]
    result.update(_deliver(account, all_tokens(), title, body,
                           {"type": "app_update", "version": str(version),
                            "build": str(build_code),
                            "deep_link": "/download"}))
    if result["targets"]:
        _meta_set("announced_build_code", str(build_code))
        record_campaign("release", title, body, result)
    return result

def send_update_alert(install_ids: List[str], title: str, body: str,
                      data: Optional[Dict] = None) -> Dict:
    """Deliver one notification per registered device.

    The returned counts are measured, never assumed: ``delivered`` only counts
    accepted FCM responses, dead tokens are pruned, and every other failure is
    reported back with its reason.
    """
    return _deliver(_service_account(), tokens_for(install_ids),
                    title, body, data or {})


def send_broadcast(title: str, body: str,
                   data: Optional[Dict] = None) -> Dict:
    """Admin announcement to every registered app install (not just old builds)."""
    return _deliver(_service_account(), all_tokens(), title, body, data or {})
