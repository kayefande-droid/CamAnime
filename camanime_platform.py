"""CamAnime platform layer: permanent SQLite database + token auth for native apps.

- Users, comments, ratings, notifications, events, counters live in SQLite
  (file from CAMANIME_DB env, default camanime.db). Survives restarts/deploys
  when the file (or its volume) persists — unlike the old JSON store.
- Passwords use PBKDF2-HMAC-SHA256 (werkzeug). Admin seeded via env.
- JSON store (camanime_store.json) is auto-migrated once into SQLite.
- API tokens (secrets.token_hex) let the Flutter/Windows app sign in against
  the same website accounts via /api/auth/* with `Authorization: Bearer <token>`.
"""
import json
import os
import secrets
import sqlite3
import time
from typing import Dict, List, Optional

from werkzeug.security import check_password_hash, generate_password_hash

DB_PATH = os.environ.get("CAMANIME_DB", "camanime.db")
LEGACY_JSON = os.environ.get("CAMANIME_STORE", "camanime_store.json")
ADMIN_EMAIL = os.environ.get("CAMANIME_ADMIN_EMAIL", "admin@camanime.local")
ADMIN_PASSWORD = os.environ.get("CAMANIME_ADMIN_PASSWORD")
if os.environ.get("CAMANIME_ADMIN_EMAIL") and not ADMIN_PASSWORD:
    raise RuntimeError("CAMANIME_ADMIN_PASSWORD is required when CAMANIME_ADMIN_EMAIL is configured.")
# Default first-run admin (changeable from /admin when logged in as admin).
# Env always wins when set; otherwise the first boot with an empty user table
# creates this account so the owner is never locked out. Change it immediately.
DEFAULT_ADMIN_EMAIL = "admin@camanime.local"
DEFAULT_ADMIN_PASSWORD = os.environ.get("CAMANIME_DEFAULT_ADMIN_PASSWORD", "CamAnime123!")
TOKEN_TTL = 60 * 60 * 24 * 90  # 90 days

SEO_KEYWORDS = (
    "free anime streaming website, watch anime online free, anime websites Cameroon, "
    "free streaming websites worldwide, watch anime sub dub 1080p, download anime episodes free, "
    "best free anime sites, anime movies online, simulcast anime schedule"
)

CLASSICS_SCHEDULE = [
    {"day": "Monday", "slots": [
        {"time": "17:00 UTC", "title": "One Piece (Simulcast)", "kind": "Long-running"},
        {"time": "19:30 UTC", "title": "Naruto Shippuden (Classic)", "kind": "Classic"},
    ]},
    {"day": "Tuesday", "slots": [
        {"time": "17:00 UTC", "title": "Jujutsu Kaisen (Season Batch)", "kind": "Season"},
        {"time": "19:30 UTC", "title": "Bleach (Classic)", "kind": "Classic"},
    ]},
    {"day": "Wednesday", "slots": [
        {"time": "17:00 UTC", "title": "Demon Slayer (Simulcast)", "kind": "Season"},
        {"time": "19:30 UTC", "title": "Death Note (Classic)", "kind": "Classic"},
    ]},
    {"day": "Thursday", "slots": [
        {"time": "17:00 UTC", "title": "Attack on Titan (Marathon)", "kind": "Classic"},
        {"time": "19:30 UTC", "title": "My Hero Academia", "kind": "Season"},
    ]},
    {"day": "Friday", "slots": [
        {"time": "17:00 UTC", "title": "Frieren (Simulcast)", "kind": "Season"},
        {"time": "19:30 UTC", "title": "Cowboy Bebop (Classic)", "kind": "Classic"},
    ]},
    {"day": "Saturday", "slots": [
        {"time": "15:00 UTC", "title": "New Episode Drop Block", "kind": "Premiere"},
        {"time": "19:30 UTC", "title": "Studio Ghibli Movies", "kind": "Movie"},
    ]},
    {"day": "Sunday", "slots": [
        {"time": "15:00 UTC", "title": "Community Watch Party", "kind": "Event"},
        {"time": "19:30 UTC", "title": "Dragon Ball Z (Classic)", "kind": "Classic"},
    ]},
]

CAM_STICKERS = ["🍥", "⚔️", "🐉", "👺", "🌸", "🔥", "🍜", "⛩️", "👾", "💫", "🎴", "🍡"]


# ─── low-level DB ────────────────────────────────────────────────────────────

def _db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH, timeout=15)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def _init() -> None:
    with _db() as conn:
        conn.executescript("""
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
        """)
        conn.execute("INSERT OR IGNORE INTO counters(key, value) VALUES ('site_clicks', 0)")
        conn.execute("INSERT OR IGNORE INTO counters(key, value) VALUES ('plays', 0)")
        conn.execute("INSERT OR IGNORE INTO counters(key, value) VALUES ('app_downloads', 12840)")


def _migrate_legacy_once() -> None:
    """Import the old JSON store into SQLite once, then leave the JSON untouched."""
    if not os.path.exists(LEGACY_JSON):
        return
    with _db() as conn:
        n = conn.execute("SELECT COUNT(*) AS c FROM users").fetchone()["c"]
        if n > 0:
            return
    try:
        with open(LEGACY_JSON, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        return
    with _db() as conn:
        for key, u in (data.get("users") or {}).items():
            conn.execute(
                "INSERT OR IGNORE INTO users(email,name,pw,role,avatar,created) VALUES (?,?,?,?,?,?)",
                (key, u.get("name", key), u.get("pw", ""), u.get("role", "user"),
                 u.get("avatar", ""), u.get("created", int(time.time()))),
            )
        for c in data.get("comments") or []:
            conn.execute(
                "INSERT OR IGNORE INTO comments(id,anime_id,ep,email,username,text,parent,sticker,likes,liked_by,t)"
                " VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                (c.get("id"), str(c.get("anime_id", "")), str(c.get("ep", "")),
                 c.get("email", ""), c.get("user", ""), c.get("text", ""),
                 c.get("parent", ""), c.get("sticker", ""), c.get("likes", 0),
                 json.dumps(c.get("liked_by", [])),
                 c.get("t", int(time.time()))),
            )
        for r in data.get("ratings") or []:
            conn.execute(
                "INSERT OR REPLACE INTO ratings(anime_id,email,score,t) VALUES (?,?,?,?)",
                (str(r.get("anime_id", "")), r.get("email", ""), r.get("score", 8),
                 r.get("t", int(time.time()))),
            )
        for n_ in data.get("notifications") or []:
            conn.execute(
                "INSERT OR IGNORE INTO notifications(id,email,text,read,t) VALUES (?,?,?,?,?)",
                (n_.get("id"), n_.get("to", ""), n_.get("text", ""),
                 1 if n_.get("read") else 0, n_.get("t", int(time.time()))),
            )
        for e in data.get("events") or []:
            meta = e.get("meta") or {}
            conn.execute(
                "INSERT INTO events(t,kind,anime_id,ep) VALUES (?,?,?,?)",
                (e.get("t", int(time.time())), e.get("kind", ""),
                 str(meta.get("anime_id", "")), str(meta.get("ep", ""))),
            )
        for k in ("site_clicks", "plays"):
            v = (data.get("counters") or {}).get(k, 0)
            conn.execute("UPDATE counters SET value = value + ? WHERE key = ?", (v, k))
        if data.get("app_downloads"):
            conn.execute("UPDATE counters SET value = MAX(value, ?) WHERE key='app_downloads'",
                         (data["app_downloads"],))


def _row_user(r) -> Dict:
    return {"email": r["email"], "name": r["name"], "pw": r["pw"],
            "role": r["role"], "avatar": r["avatar"], "created": r["created"]}


_init()
_migrate_legacy_once()


# ─── compat snapshot API (same shape as the old JSON store) ──────────────────

def load_store() -> Dict:
    with _db() as conn:
        users = {r["email"]: _row_user(r) for r in conn.execute("SELECT * FROM users")}
        comments = []
        for r in conn.execute("SELECT * FROM comments ORDER BY t"):
            comments.append({"id": r["id"], "anime_id": r["anime_id"], "ep": r["ep"],
                             "user": r["username"], "email": r["email"], "text": r["text"],
                             "parent": r["parent"], "sticker": r["sticker"],
                             "likes": r["likes"], "liked_by": json.loads(r["liked_by"] or "[]"),
                             "t": r["t"]})
        ratings = [{"anime_id": r["anime_id"], "email": r["email"],
                    "score": r["score"], "t": r["t"]}
                   for r in conn.execute("SELECT * FROM ratings")]
        notifications = [{"id": r["id"], "to": r["email"], "text": r["text"],
                          "read": bool(r["read"]), "t": r["t"]}
                         for r in conn.execute("SELECT * FROM notifications ORDER BY t")]
        events = [{"t": r["t"], "kind": r["kind"],
                   "meta": {"anime_id": r["anime_id"], "ep": r["ep"]}}
                  for r in conn.execute("SELECT * FROM events ORDER BY id DESC LIMIT 2000")]
        counters = {r["key"]: r["value"] for r in conn.execute("SELECT * FROM counters")}
        announcements = [{"id": r["id"], "title": r["title"], "body": r["body"],
                          "author": r["author"], "t": r["t"]}
                         for r in conn.execute("SELECT * FROM announcements ORDER BY t DESC LIMIT 20")]
        return {"users": users, "comments": comments[-1000:], "ratings": ratings,
                "announcements": announcements,
                "notifications": notifications[-200:],
                "events": events,
                "app_downloads": counters.get("app_downloads", 0),
                "counters": {"site_clicks": counters.get("site_clicks", 0),
                             "plays": counters.get("plays", 0)}}


def save_store(data: Dict) -> None:
    """Compat shim — writes go straight to SQLite; snapshots are read-only."""


# ─── CEO announcements ───────────────────────────────────────────────────────

def list_announcements(limit: int = 10):
    _init()
    with _db() as conn:
        return [{"id": r["id"], "title": r["title"], "body": r["body"],
                 "author": r["author"], "t": r["t"]}
                for r in conn.execute("SELECT * FROM announcements ORDER BY t DESC LIMIT ?",
                                      (max(1, min(int(limit or 10), 20)),))]


def post_announcement(title: str, body: str, author: str):
    title = (title or "").strip()[:120]
    body = (body or "").strip()[:2000]
    if not title or not body:
        raise ValueError("Title and message are required.")
    _init()
    aid = secrets.token_hex(6)
    now = int(time.time())
    with _db() as conn:
        conn.execute("INSERT INTO announcements(id,title,body,author,t) VALUES (?,?,?,?,?)",
                     (aid, title, body, author or "kayefande-droid & co.", now))
        conn.execute("DELETE FROM announcements WHERE id NOT IN (SELECT id FROM announcements ORDER BY t DESC LIMIT 50)")
    return {"id": aid, "title": title, "body": body, "author": author, "t": now}


# ─── auth ────────────────────────────────────────────────────────────────────

def ensure_admin(data: Dict = None) -> Optional[Dict]:
    if not ADMIN_PASSWORD:
        # Do not seed a known or unreachable password into the database.
        return None
    with _db() as conn:
        row = conn.execute("SELECT * FROM users WHERE email = ?",
                           (ADMIN_EMAIL.lower(),)).fetchone()
        if not row:
            conn.execute(
                "INSERT INTO users(email,name,pw,role,avatar,created) VALUES (?,?,?,?,?,?)",
                (ADMIN_EMAIL.lower(), "CamAnime Admin",
                 generate_password_hash(ADMIN_PASSWORD), "admin", "", int(time.time())),
            )
            row = conn.execute("SELECT * FROM users WHERE email = ?",
                               (ADMIN_EMAIL.lower(),)).fetchone()
        return _row_user(row)


def ensure_default_admin() -> Optional[Dict]:
    """Create the changeable first-run admin if no admin exists yet.

    Env-seeded admin (ensure_admin) always runs first. This fallback only
    fires on a fresh DB with zero admin rows, so the owner is never locked
    out. Change the password immediately from /admin (admin-only)."""
    _init()
    with _db() as conn:
        has_admin = conn.execute("SELECT 1 FROM users WHERE role='admin' LIMIT 1").fetchone()
        if has_admin:
            row = conn.execute("SELECT * FROM users WHERE email=?", (DEFAULT_ADMIN_EMAIL.lower(),)).fetchone()
            return _row_user(row) if row else None
        conn.execute(
            "INSERT OR IGNORE INTO users(email,name,pw,role,avatar,created) VALUES (?,?,?,?,?,?)",
            (DEFAULT_ADMIN_EMAIL.lower(), "CamAnime Admin",
             generate_password_hash(DEFAULT_ADMIN_PASSWORD), "admin", "", int(time.time())),
        )
        row = conn.execute("SELECT * FROM users WHERE email=?", (DEFAULT_ADMIN_EMAIL.lower(),)).fetchone()
        return _row_user(row) if row else None


def create_admin_user(email: str, name: str, password: str) -> Dict:
    """Create an extra admin. Caller must already be an admin (checked in app.py)."""
    key = (email or "").strip().lower()
    if not key or "@" not in key:
        raise ValueError("Enter a valid admin email address.")
    if len(password or "") < 8:
        raise ValueError("Admin password must be at least 8 characters.")
    _init()
    with _db() as conn:
        if conn.execute("SELECT 1 FROM users WHERE email=?", (key,)).fetchone():
            raise ValueError("That email already has an account.")
        conn.execute(
            "INSERT INTO users(email,name,pw,role,avatar,created) VALUES (?,?,?,?,?,?)",
            (key, (name or "").strip() or key.split("@")[0],
             generate_password_hash(password), "admin", "", int(time.time())),
        )
        row = conn.execute("SELECT * FROM users WHERE email=?", (key,)).fetchone()
        return _row_user(row)


def change_own_password(email: str, current_password: str, new_password: str) -> None:
    """Admin/owner changes their own password after verifying the current one."""
    if len(new_password or "") < 8:
        raise ValueError("New password must be at least 8 characters.")
    _init()
    with _db() as conn:
        row = conn.execute("SELECT * FROM users WHERE email=?", (email.lower(),)).fetchone()
        if not row or not check_password_hash(row["pw"], current_password or ""):
            raise ValueError("Current password is incorrect.")
        conn.execute("UPDATE users SET pw=? WHERE email=?",
                     (generate_password_hash(new_password), email.lower()))
        conn.execute("DELETE FROM tokens WHERE email=?", (email.lower(),))


def admin_reset_password(target_email: str, new_password: str) -> None:
    """Admin resets any account password (admin-only route). Revokes its tokens."""
    if len(new_password or "") < 8:
        raise ValueError("New password must be at least 8 characters.")
    _init()
    with _db() as conn:
        row = conn.execute("SELECT * FROM users WHERE email=?", (target_email.lower(),)).fetchone()
        if not row:
            raise ValueError("Account not found.")
        conn.execute("UPDATE users SET pw=? WHERE email=?",
                     (generate_password_hash(new_password), target_email.lower()))
        conn.execute("DELETE FROM tokens WHERE email=?", (target_email.lower(),))


def register_user(data: Dict, email: str, name: str, password: str) -> Dict:
    key = email.strip().lower()
    if not key or "@" not in key:
        raise ValueError("Enter a valid email address.")
    if len(password or "") < 6:
        raise ValueError("Password must be at least 6 characters.")
    with _db() as conn:
        if conn.execute("SELECT 1 FROM users WHERE email = ?", (key,)).fetchone():
            raise ValueError("Account already exists. Please sign in.")
        conn.execute(
            "INSERT INTO users(email,name,pw,role,avatar,created) VALUES (?,?,?,?,?,?)",
            (key, (name or "").strip() or key.split("@")[0],
             generate_password_hash(password), "user", "", int(time.time())),
        )
        row = conn.execute("SELECT * FROM users WHERE email = ?", (key,)).fetchone()
        return _row_user(row)


def verify_user(data: Dict, email: str, password: str) -> Dict:
    key = email.strip().lower()
    with _db() as conn:
        row = conn.execute("SELECT * FROM users WHERE email = ?", (key,)).fetchone()
    if not row or not check_password_hash(row["pw"], password or ""):
        raise ValueError("Invalid email or password.")
    return _row_user(row)


def public_user(user: Dict) -> Dict:
    return {"email": user["email"], "name": user["name"],
            "role": user.get("role", "user"), "avatar": user.get("avatar", "")}


def issue_token(email: str) -> Dict:
    token = secrets.token_hex(24)
    now = int(time.time())
    with _db() as conn:
        # Opportunistic cleanup on login keeps the SQLite file small on free-tier disks.
        conn.execute("DELETE FROM tokens WHERE expires <= ?", (now,))
        conn.execute("INSERT INTO tokens(token,email,created,expires) VALUES (?,?,?,?)",
                     (token, email.lower(), now, now + TOKEN_TTL))
    return {"token": token, "expires": now + TOKEN_TTL}


def get_user_by_token(token: str) -> Optional[Dict]:
    if not token:
        return None
    now = int(time.time())
    with _db() as conn:
        row = conn.execute(
            "SELECT u.* FROM tokens t JOIN users u ON u.email = t.email "
            "WHERE t.token = ? AND t.expires > ?", (token, now)).fetchone()
    return _row_user(row) if row else None


def revoke_token(token: str) -> None:
    with _db() as conn:
        conn.execute("DELETE FROM tokens WHERE token = ?", (token,))


# ─── community ───────────────────────────────────────────────────────────────

def track(data: Dict, kind: str, meta: Dict = None) -> None:
    meta = meta or {}
    with _db() as conn:
        conn.execute("INSERT INTO events(t,kind,anime_id,ep) VALUES (?,?,?,?)",
                     (int(time.time()), kind, str(meta.get("anime_id", "")),
                      str(meta.get("ep", ""))))
        if kind == "click":
            conn.execute("UPDATE counters SET value = value + 1 WHERE key='site_clicks'")
        elif kind == "play":
            conn.execute("UPDATE counters SET value = value + 1 WHERE key='plays'")
        conn.execute("DELETE FROM events WHERE id NOT IN (SELECT id FROM events ORDER BY id DESC LIMIT 5000)")


def add_comment(data: Dict, anime_id: str, ep: str, user: Dict, text: str,
                parent: str = "", sticker: str = "") -> Dict:
    text = (text or "").strip()[:600]
    if not text and not sticker:
        raise ValueError("Write something or pick a sticker.")
    cid = secrets.token_hex(6)
    now = int(time.time())
    with _db() as conn:
        conn.execute(
            "INSERT INTO comments(id,anime_id,ep,email,username,text,parent,sticker,likes,liked_by,t)"
            " VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            (cid, str(anime_id), str(ep), user["email"], user["name"], text,
             parent or "", sticker or "", 0, "[]", now),
        )
        if parent:
            prow = conn.execute("SELECT email FROM comments WHERE id = ?",
                                (parent,)).fetchone()
            if prow and prow["email"] != user["email"]:
                conn.execute(
                    "INSERT INTO notifications(id,email,text,read,t) VALUES (?,?,?,?,?)",
                    (secrets.token_hex(6), prow["email"],
                     f"{user['name']} replied to your comment on anime {anime_id} ep {ep}.",
                     0, now),
                )
    return {"id": cid, "anime_id": str(anime_id), "ep": str(ep), "user": user["name"],
            "email": user["email"], "text": text, "parent": parent or "",
            "sticker": sticker or "", "likes": 0, "liked_by": [], "t": now}


def like_comment(data: Dict, cid: str, email: str) -> Dict:
    with _db() as conn:
        row = conn.execute("SELECT * FROM comments WHERE id = ?", (cid,)).fetchone()
        if not row:
            raise ValueError("Comment not found.")
        liked = json.loads(row["liked_by"] or "[]")
        if email in liked:
            liked.remove(email)
        else:
            liked.append(email)
        conn.execute("UPDATE comments SET likes = ?, liked_by = ? WHERE id = ?",
                     (len(liked), json.dumps(liked), cid))
        return {"id": cid, "likes": len(liked)}


def rate_anime(data: Dict, anime_id: str, email: str, score: int) -> Dict:
    score = max(1, min(10, int(score)))
    with _db() as conn:
        conn.execute("INSERT OR REPLACE INTO ratings(anime_id,email,score,t) VALUES (?,?,?,?)",
                     (str(anime_id), email, score, int(time.time())))
    return anime_rating(data, anime_id)


def anime_rating(data: Dict, anime_id: str) -> Dict:
    with _db() as conn:
        rows = conn.execute("SELECT score FROM ratings WHERE anime_id = ?",
                            (str(anime_id),)).fetchall()
    scores = [r["score"] for r in rows]
    if not scores:
        return {"anime_id": str(anime_id), "count": 0, "avg": 0}
    return {"anime_id": str(anime_id), "count": len(scores),
            "avg": round(sum(scores) / len(scores), 1)}


def admin_stats(data: Dict = None) -> Dict:
    with _db() as conn:
        users = conn.execute("SELECT COUNT(*) AS c FROM users").fetchone()["c"]
        comments = conn.execute("SELECT COUNT(*) AS c FROM comments").fetchone()["c"]
        ratings = conn.execute("SELECT COUNT(*) AS c FROM ratings").fetchone()["c"]
        counters = {r["key"]: r["value"] for r in conn.execute("SELECT * FROM counters")}
        top = conn.execute(
            "SELECT anime_id, COUNT(*) AS plays FROM events WHERE kind='play' AND anime_id != '' "
            "GROUP BY anime_id ORDER BY plays DESC LIMIT 10").fetchall()
    return {"users": users, "comments": comments, "ratings": ratings,
            "clicks": counters.get("site_clicks", 0), "plays": counters.get("plays", 0),
            "app_downloads": counters.get("app_downloads", 0),
            "most_watched": [{"anime_id": r["anime_id"], "plays": r["plays"]} for r in top]}
