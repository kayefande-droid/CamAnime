"""Free developer streaming API for the Render deployment.

Mirrors /cloudflare/src/developer.js exactly so both hosts answer the same
shapes: one provider (AnimeHeaven direct MP4), keyed access, 1,000 calls/day.

Keys are created by a signed-in website account and stored as SHA-256 hashes;
the plaintext is returned once and never persisted.
"""
from __future__ import annotations

import hashlib
import secrets
import time
from typing import Dict, List, Optional

import requests
from flask import Blueprint, jsonify, render_template, request, session

from camanime_platform import _db, get_user, get_user_by_token, public_user
from streaming_providers import streaming_manager

DAILY_LIMIT = 1000
MAX_KEYS = 3
KEY_PREFIX = "ca_live_"
PROVIDER = "animeheaven"
PROVIDER_LABEL = "AnimeHeaven (direct MP4)"
ANILIST_URL = "https://graphql.anilist.co"

developer_bp = Blueprint("developer", __name__)


def _ensure_tables() -> None:
    with _db() as conn:
        conn.executescript(
            """
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
            """
        )


_ensure_tables()


def _hash(key: str) -> str:
    return hashlib.sha256(key.encode("utf-8")).hexdigest()


def _today() -> str:
    return time.strftime("%Y-%m-%d", time.gmtime())


def _current_user() -> Optional[Dict]:
    auth = request.headers.get("Authorization", "")
    if auth.lower().startswith("bearer "):
        user = get_user_by_token(auth[7:].strip())
        return public_user(user) if user else None
    email = session.get("user_email", "")
    user = get_user(email) if email else None
    return public_user(user) if user else None


def _reply(payload: Dict, status: int = 200, cors: bool = False, headers: Optional[Dict] = None):
    resp = jsonify(payload)
    resp.status_code = status
    if cors:
        resp.headers["Access-Control-Allow-Origin"] = "*"
        resp.headers["Access-Control-Allow-Headers"] = "x-api-key, authorization, content-type"
        resp.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
        resp.headers["Access-Control-Expose-Headers"] = "x-ratelimit-limit, x-ratelimit-remaining"
    for key, value in (headers or {}).items():
        resp.headers[key] = str(value)
    return resp


# ── pages ────────────────────────────────────────────────────────────────────

@developer_bp.route("/developers")
def developers_page():
    return render_template("developers.html", user=_current_user())


# ── key management (session auth) ────────────────────────────────────────────

@developer_bp.route("/api/developer/keys", methods=["GET"])
def list_keys():
    user = _current_user()
    if not user:
        return _reply({"error": "Sign in to manage API keys."}, 401)
    with _db() as conn:
        rows = conn.execute(
            "SELECT id, name, prefix, plan, created, last_used, revoked FROM api_keys "
            "WHERE email = ? ORDER BY created DESC LIMIT 20",
            (user["email"],),
        ).fetchall()
        usage = {
            r["key_id"]: r["calls"]
            for r in conn.execute(
                "SELECT key_id, calls FROM api_usage WHERE day = ? AND key_id IN "
                "(SELECT id FROM api_keys WHERE email = ?)",
                (_today(), user["email"]),
            ).fetchall()
        }
    return _reply({
        "keys": [{**dict(r), "calls_today": usage.get(r["id"], 0)} for r in rows],
        "daily_limit": DAILY_LIMIT,
        "max_keys": MAX_KEYS,
        "provider": PROVIDER,
    })


@developer_bp.route("/api/developer/keys", methods=["POST"])
def create_key():
    user = _current_user()
    if not user:
        return _reply({"error": "Sign in to create an API key."}, 401)
    body = request.get_json(silent=True) or {}
    name = (str(body.get("name") or "").strip() or "My site")[:40]
    with _db() as conn:
        active = conn.execute(
            "SELECT COUNT(*) FROM api_keys WHERE email = ? AND revoked = 0", (user["email"],)
        ).fetchone()[0]
        if active >= MAX_KEYS:
            return _reply({"error": f"The free tier keeps {MAX_KEYS} active keys. Revoke one first."}, 429)
        key = KEY_PREFIX + secrets.token_hex(24)
        key_id = secrets.token_hex(8)
        created = int(time.time() * 1000)
        conn.execute(
            "INSERT INTO api_keys (id, email, name, prefix, key_hash, plan, created, last_used, revoked) "
            "VALUES (?, ?, ?, ?, ?, 'free', ?, 0, 0)",
            (key_id, user["email"], name, key[:14], _hash(key), created),
        )
    return _reply({
        "ok": True,
        "id": key_id,
        "name": name,
        "key": key,
        "created": created,
        "provider": PROVIDER,
        "daily_limit": DAILY_LIMIT,
        "note": "Copy this key now — it is stored hashed and cannot be shown again.",
    }, 201)


@developer_bp.route("/api/developer/keys/<key_id>", methods=["DELETE", "POST"])
def revoke_key(key_id: str):
    user = _current_user()
    if not user:
        return _reply({"error": "Sign in to manage API keys."}, 401)
    with _db() as conn:
        row = conn.execute(
            "SELECT id FROM api_keys WHERE id = ? AND email = ?", (key_id, user["email"])
        ).fetchone()
        if not row:
            return _reply({"error": "Key not found."}, 404)
        conn.execute("UPDATE api_keys SET revoked = 1 WHERE id = ?", (key_id,))
    return _reply({"ok": True, "id": key_id})


# ── public stream endpoint ───────────────────────────────────────────────────

def _key_from_request() -> str:
    header = (request.headers.get("x-api-key") or "").strip()
    if header:
        return header
    auth = request.headers.get("Authorization", "")
    if auth.lower().startswith("bearer "):
        return auth[7:].strip()
    return (request.args.get("key") or "").strip()


def _anilist(query: str, variables: Dict) -> Optional[Dict]:
    """One GraphQL call to AniList; None means "provider unreachable"."""
    try:
        resp = requests.post(
            ANILIST_URL, json={"query": query, "variables": variables}, timeout=15
        )
        if resp.status_code != 200:
            return None
        payload = resp.json()
        if payload.get("errors"):
            return None
        return payload.get("data")
    except Exception:
        return None


def _card(media: Dict) -> Dict:
    """Catalogue card shape — the same fields the CamAnime site renders."""
    title = media.get("title") or {}
    cover = media.get("coverImage") or {}
    return {
        "id": str(media.get("id") or ""),
        "idMal": media.get("idMal"),
        "title": title.get("english") or title.get("romaji") or title.get("native") or "",
        "title_romaji": title.get("romaji") or "",
        "image": cover.get("large") or cover.get("medium") or "",
        "episodes": media.get("episodes"),
        "score": media.get("averageScore"),
        "format": media.get("format"),
        "year": media.get("seasonYear"),
    }


def _consume_key():
    """Validates the caller's key and books the call against the daily limit.

    Returns (key_id, calls) on success, or (None, response) when the request
    must be answered immediately.
    """
    key = _key_from_request()
    origin = request.url_root.rstrip("/")
    if not key:
        return None, _reply({
            "error": "Missing API key. Send it as the x-api-key header.",
            "docs": origin + "/developers",
            "create_key": origin + "/developers#keys",
        }, 401, cors=True)
    day = _today()
    with _db() as conn:
        row = conn.execute(
            "SELECT id, revoked FROM api_keys WHERE key_hash = ?", (_hash(key),)
        ).fetchone()
        if not row or row["revoked"]:
            return None, _reply({"error": "Invalid or revoked API key."}, 403, cors=True)
        conn.execute(
            "INSERT INTO api_usage (key_id, day, calls) VALUES (?, ?, 1) "
            "ON CONFLICT(key_id, day) DO UPDATE SET calls = calls + 1",
            (row["id"], day),
        )
        calls = conn.execute(
            "SELECT calls FROM api_usage WHERE key_id = ? AND day = ?", (row["id"], day)
        ).fetchone()[0]
        if calls > DAILY_LIMIT:
            return None, _reply({
                "error": f"Daily free-tier limit of {DAILY_LIMIT} calls reached.",
                "calls_today": calls,
                "daily_limit": DAILY_LIMIT,
            }, 429, cors=True)
        conn.execute(
            "UPDATE api_keys SET last_used = ? WHERE id = ?",
            (int(time.time() * 1000), row["id"]),
        )
    return row["id"], calls


SORTS = {
    "popular": "POPULARITY_DESC",
    "trending": "TRENDING_DESC",
    "rating": "SCORE_DESC",
    "recent": "START_DATE_DESC",
    "alphabetical": "TITLE_ROMAJI",
}
FORMATS = {"TV", "TV_SHORT", "MOVIE", "OVA", "ONA", "SPECIAL"}

LIST_QUERY = """
query($page:Int,$perPage:Int,$sort:[MediaSort],$search:String,$format:MediaFormat,$genre:String){
  Page(page:$page,perPage:$perPage){
    pageInfo{hasNextPage total}
    media(type:ANIME,sort:$sort,search:$search,format:$format,genre:$genre,isAdult:false){
      id idMal format seasonYear episodes averageScore
      title{romaji english native}
      coverImage{large medium}
    }
  }
}
"""

DETAIL_QUERY = """
query($id:Int){
  Media(id:$id,type:ANIME){
    id idMal format seasonYear episodes duration averageScore description(asHtml:false)
    status genres
    title{romaji english native}
    coverImage{large medium extraLarge}
    bannerImage
    studios(isMain:true){nodes{name}}
  }
}
"""


@developer_bp.route("/api/v1/dev/catalog", methods=["GET", "OPTIONS"])
def api_anime_list():
    """Catalogue, filter and search in one call.

    /api/v1/dev/catalog?q=jujutsu&sort=popular&format=TV&genre=Action&page=1&perPage=24
    """
    if request.method == "OPTIONS":
        return _reply({}, 204, cors=True)
    _key_id, bookkeeping = _consume_key()
    if _key_id is None:
        return bookkeeping

    query = (request.args.get("q") or request.args.get("search") or "").strip()[:100]
    genre = (request.args.get("genre") or "").strip()
    media_format = (request.args.get("format") or "").strip().upper()
    sort_key = (request.args.get("sort") or "popular").strip().lower()
    page = max(1, min(1000, request.args.get("page", default=1, type=int) or 1))
    per_page = max(1, min(50, request.args.get("perPage", default=24, type=int) or 24))
    if sort_key not in SORTS:
        return _reply({
            "error": "Unsupported sort.",
            "allowed": sorted(SORTS.keys()),
        }, 400, cors=True)
    if media_format and media_format not in FORMATS:
        return _reply({
            "error": "Unsupported format.",
            "allowed": sorted(FORMATS),
        }, 400, cors=True)

    variables = {"page": page, "perPage": per_page, "sort": [SORTS[sort_key]]}
    if query:
        variables["search"] = query
    if genre:
        variables["genre"] = genre
    if media_format:
        variables["format"] = media_format

    data = _anilist(LIST_QUERY, variables)
    if data is None:
        return _reply({"error": "The catalogue provider is unavailable."}, 502, cors=True)
    page_data = data.get("Page") or {}
    results = [_card(m) for m in (page_data.get("media") or []) if m]
    info = page_data.get("pageInfo") or {}
    return _reply({
        "api": "camanime-catalog",
        "version": 1,
        "query": {"q": query, "genre": genre, "format": media_format, "sort": sort_key},
        "results": results,
        "page": page,
        "perPage": per_page,
        "has_next_page": bool(info.get("hasNextPage")),
        "usage": {"calls_today": bookkeeping, "daily_limit": DAILY_LIMIT},
        "attribution": "Powered by CamAnime — https://camanime.onrender.com",
    }, 200, cors=True, headers={
        "x-ratelimit-limit": DAILY_LIMIT,
        "x-ratelimit-remaining": max(0, DAILY_LIMIT - int(bookkeeping)),
    })


@developer_bp.route("/api/v1/dev/anime/<int:anime_id>", methods=["GET", "OPTIONS"])
def api_anime_detail(anime_id: int):
    if request.method == "OPTIONS":
        return _reply({}, 204, cors=True)
    _key_id, bookkeeping = _consume_key()
    if _key_id is None:
        return bookkeeping
    data = _anilist(DETAIL_QUERY, {"id": anime_id})
    media = (data or {}).get("Media")
    if not media:
        return _reply({"error": "Anime not found."}, 404, cors=True)
    card = _card(media)
    prefix = request.url_root.rstrip("/")
    episodes = int(media.get("episodes") or 0)
    card.update({
        "description": media.get("description") or "",
        "status": media.get("status"),
        "genres": media.get("genres") or [],
        "duration": media.get("duration"),
        "banner": media.get("bannerImage") or "",
        "studios": [
            (n or {}).get("name")
            for n in ((media.get("studios") or {}).get("nodes") or [])
            if (n or {}).get("name")
        ],
        "episode_list": [
            {"episode": n, "stream": f"{prefix}/api/v1/stream/{anime_id}/{n}"}
            for n in range(1, episodes + 1)
        ],
    })
    return _reply({
        "api": "camanime-anime",
        "version": 1,
        "anime": card,
        "usage": {"calls_today": bookkeeping, "daily_limit": DAILY_LIMIT},
        "attribution": "Powered by CamAnime — https://camanime.onrender.com",
    }, 200, cors=True)


def _anilist_media(anime_id: int) -> Optional[Dict]:
    query = (
        "query($id:Int){Media(id:$id,type:ANIME){id idMal title{romaji english native} "
        "episodes coverImage{large} averageScore}}"
    )
    try:
        resp = requests.post(
            ANILIST_URL, json={"query": query, "variables": {"id": anime_id}}, timeout=10
        )
        if resp.status_code != 200:
            return None
        return ((resp.json().get("data") or {}).get("Media")) or None
    except Exception:
        return None


@developer_bp.route("/api/v1/stream/<int:anime_id>/<int:ep>", methods=["GET", "OPTIONS"])
def stream(anime_id: int, ep: int):
    if request.method == "OPTIONS":
        return _reply({}, 204, cors=True)

    key_id, calls = _consume_key()
    if key_id is None:
        return calls

    media = _anilist_media(anime_id)
    if not media:
        return _reply({"error": "Anime not found on AniList."}, 404, cors=True)

    titles: List[str] = [
        (media.get("title") or {}).get("english"),
        (media.get("title") or {}).get("romaji"),
        (media.get("title") or {}).get("native"),
    ]
    titles = [t for t in titles if t]
    episode = max(1, int(ep or 1))
    audio = "dub" if (request.args.get("audio") or "sub").lower() == "dub" else "sub"

    try:
        bundle = streaming_manager.get_full_episode_bundle(
            anilist_id=anime_id,
            ep_num=episode,
            titles=titles or [f"Anime {anime_id}"],
            mal_id=media.get("idMal"),
            preferred_audio=audio,
        )
    except Exception:
        return _reply({"error": "The provider could not be reached. Retry shortly."}, 502, cors=True)

    sources = [
        s for s in (bundle or {}).get("servers", [])
        if s.get("provider") == PROVIDER and s.get("playback_mode") == "mp4" and s.get("stream_url")
    ]
    if not sources:
        return _reply({
            "error": "No source for this episode yet.",
            "anime": {"id": str(anime_id), "title": titles[0] if titles else f"Anime {anime_id}"},
            "episode": episode,
            "provider": PROVIDER,
            "hint": "The provider list is live; a title with no file answers 404 rather than a dead link.",
        }, 404, cors=True)

    origin = request.url_root.rstrip("/")
    with _db() as conn:
        conn.execute(
            "UPDATE api_keys SET last_used = ? WHERE id = ?", (int(time.time() * 1000), key_id)
        )

    return _reply({
        "api": "camanime-stream",
        "version": 1,
        "provider": PROVIDER,
        "provider_label": PROVIDER_LABEL,
        "anime": {
            "id": str(anime_id),
            "title": titles[0] if titles else f"Anime {anime_id}",
            "image": (media.get("coverImage") or {}).get("large", ""),
            "episodes": media.get("episodes"),
        },
        "episode": episode,
        "audio": audio,
        "streams": [
            {
                "id": s.get("id") or f"stream-{i + 1}",
                "label": s.get("name") or f"Mirror {i + 1}",
                "type": "video/mp4",
                "quality": s.get("quality") or "1080p",
                "url": (s.get("stream_url") or "").replace("/api/proxy/video", origin + "/api/proxy/video", 1)
                if (s.get("stream_url") or "").startswith("/api/")
                else s.get("stream_url"),
            }
            for i, s in enumerate(sources)
        ],
        "usage": {"calls_today": calls, "daily_limit": DAILY_LIMIT},
        "attribution": "Powered by CamAnime — https://camanime.onrender.com",
        "docs": origin + "/developers",
    }, 200, cors=True, headers={
        "x-ratelimit-limit": DAILY_LIMIT,
        "x-ratelimit-remaining": max(0, DAILY_LIMIT - calls),
    })
