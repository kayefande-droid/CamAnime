import logging
import re
import time
import random
from datetime import datetime, timezone
from threading import Lock
from collections import OrderedDict, deque
from typing import Dict, List, Optional
from urllib.parse import quote, urljoin, urlparse

import requests
from flask import (
    Flask,
    Response,
    jsonify,
    redirect,
    render_template,
    request,
    send_file,
    stream_with_context,
    url_for,
)

from streaming_providers import DEFAULT_UA, streaming_manager

import hashlib
import os

from flask import session

import camanime_platform as platform


def _utc_now_timestamp() -> int:
    return int(time.time())


# Quiet by default on Render free tier (LOG_LEVEL=INFO to debug). Cuts log volume/spam.
logging.basicConfig(level=os.environ.get("LOG_LEVEL", "WARNING").upper())
logger = logging.getLogger(__name__)

app = Flask(__name__)


def _load_secret_key():
    """Synced secret without needing Render env on first login.

    Order: CAMANIME_SECRET env > local file camanime_secret.key > ephemeral.
    The file is auto-created on first boot, gitignored (never committed),
    and reused across restarts on the same disk. Change it anytime by
    setting CAMANIME_SECRET env. No secret is stored in git."""
    env_secret = os.environ.get("CAMANIME_SECRET")
    if env_secret:
        return env_secret.encode() if isinstance(env_secret, str) else env_secret
    secret_path = os.environ.get("CAMANIME_SECRET_FILE", "camanime_secret.key")
    try:
        if os.path.isfile(secret_path):
            with open(secret_path, "rb") as f:
                raw = f.read().strip()
                if len(raw) >= 32:
                    return raw
        import secrets as _secrets
        raw = _secrets.token_hex(32).encode()
        try:
            with open(secret_path, "wb") as f:
                f.write(raw)
        except Exception:
            pass
        return raw
    except Exception:
        import secrets as _secrets
        return _secrets.token_hex(32).encode()


app.secret_key = _load_secret_key()

app.config["SEND_FILE_MAX_AGE_DEFAULT"] = 86400  # /static cached 1 day

# ── Session / cookie hardening ─────────────────────────
# Secure cookies require HTTPS; Render terminates TLS so this is correct in
# production. Set CAMANIME_COOKIE_SECURE=0 for local plain-HTTP development.
app.config.update(
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
    SESSION_COOKIE_SECURE=os.environ.get("CAMANIME_COOKIE_SECURE", "1") != "0",
    PERMANENT_SESSION_LIFETIME=60 * 60 * 24 * 14,
    MAX_CONTENT_LENGTH=2 * 1024 * 1024,
)

# ── Lightweight in-memory rate limiting (stdlib only, no new deps) ──
_RATE_BUCKETS: Dict[str, List[float]] = {}
_RATE_BUCKETS_MAX = 4096
_RATE_BUCKET_EVICT = 256
_RATE_RULES = (
    # (path prefix, max requests, window in seconds)
    ("/api/auth/login", 10, 300),
    ("/api/auth/register", 5, 3600),
    # The web login form is a separate endpoint from /api/auth/login and is
    # backed by the same user store — brute-forcing it must cost exactly the same.
    ("/login", 10, 300),
    ("/api/download/video", 30, 600),
    ("/api/proxy/", 300, 600),
    ("/api/community/comment", 20, 600),
    ("/api/community/like", 60, 600),
    ("/api/community/rate", 30, 600),
    ("/api/track", 120, 600),
    ("/api/admin/", 10, 300),
)

# Patterns that are only ever requested by vulnerability scanners.
_BLOCKED_PATTERNS = re.compile(
    r"(?i)(\.env|\.git|\.svn|wp-admin|wp-login|wp-config|xmlrpc\.php|"
    r"phpmyadmin|/\.aws/|/\.ssh/|id_rsa|/etc/passwd|base64_decode|"
    r"\.sql$|\.bak$|\.old$|/actuator|/c99\.php|/boaform/|\.DS_Store)"
)

# ── ZERO-AD-TOLERANCE: server-side ad-network blocklist ─────────────────────
# CamAnime resolves and streams every video through our own /api/proxy/* endpoints.
# Any URL routed through those endpoints that belongs to a known ad / tracking
# network is refused at the server, so ad traffic can never reach the player
# even if a third-party embed tries to load one.
AD_NETWORK_PATTERN = re.compile(
    r"(?i)(doubleclick\.net|googlesyndication\.com|googletagservices\.com|"
    r"googleadservices\.com|google-analytics\.com|Analytics([^.]*?)\.edgekey|"
    r"adnxs\.com|adsystem\.|adsrvr\.org|taboola\.com|outbrain\.com|criteo\.com|"
    r"zedo\.com|rubiconproject\.com|pubmatic\.com|openx\.net|smartadserver\.com|"
    r"adform\.net|yieldmo\.com|media\.net|revcontent\.com|mgid\.com|"
    r"propellerads|popads\.net|popcash\.net|adcash\.com|onclickads\.net|"
    r"trafficjunky|exoclick\.com|juicyads\.com|ero-advertising\.com|"
    r"/ads\.js|/adserver|/pagead/|banner(?:s)?/.|adservice\.google|"
    r"amazon-adsystem\.com|moatads\.com|adsafeprotected\.com|servedby-?adbutler)"
)


def _is_ad_url(url_text: str) -> bool:
    return bool(AD_NETWORK_PATTERN.search(url_text or ""))

_AUTHENTICATED_PATHS = ("/admin", "/settings", "/login", "/logout")


def _client_ip() -> str:
    """Real client IP, honouring Render's proxy header."""
    forwarded = (request.headers.get("X-Forwarded-For") or "").split(",")[0].strip()
    return forwarded or request.remote_addr or "unknown"


def _rate_limited(path: str) -> bool:
    """Sliding-window limiter for sensitive endpoints."""
    now = time.time()
    for prefix, limit, window in _RATE_RULES:
        if path.startswith(prefix):
            key = f"{prefix}|{_client_ip()}"
            if key not in _RATE_BUCKETS and len(_RATE_BUCKETS) >= _RATE_BUCKETS_MAX:
                cutoff = now - max(rule[2] for rule in _RATE_RULES)
                for old_key, timestamps in list(_RATE_BUCKETS.items())[:_RATE_BUCKET_EVICT]:
                    if not timestamps or timestamps[-1] < cutoff:
                        _RATE_BUCKETS.pop(old_key, None)
                while len(_RATE_BUCKETS) >= _RATE_BUCKETS_MAX:
                    _RATE_BUCKETS.pop(next(iter(_RATE_BUCKETS)))
            bucket = _RATE_BUCKETS.setdefault(key, [])
            cutoff = now - window
            bucket[:] = [t for t in bucket if t >= cutoff]
            if len(bucket) >= limit:
                return True
            bucket.append(now)
            return False
    return False


# ── Live activity feed (admin panel) ───────────────────
# Ephemeral in-memory ring buffer: streams and downloads are *live* by
# definition, so nothing here touches SQLite or can slow a playback request.
# Recording is wrapped so a failure can never break the media path.
_LIVE_ACTIVITY: deque = deque(maxlen=300)
_RECENT_VISITORS: Dict[str, float] = {}
_RECENT_VISITORS_MAX = 4000
_KIND_LABELS = {"stream": "Stream", "download": "Download", "play": "Played"}


def _record_activity(kind: str, anime: str = "", ep: str = "", detail: str = "") -> None:
    """Log one live hit (stream/download) with who it was. Never raises."""
    try:
        logged = bool(request.headers.get("Authorization")) or bool(session.get("user_email"))
        user = _current_user() if logged else None
        _LIVE_ACTIVITY.append({
            "t": int(time.time()), "kind": kind, "who": (user or {}).get("id", "") or "",
            "email": (user or {}).get("email") or "guest",
            "guest": user is None,
            "anime": (anime or "")[:80], "ep": str(ep or ""), "detail": (detail or "")[:120],
            "ip": _client_ip(),
        })
    except Exception:
        logger.debug("live activity logging failed", exc_info=True)


@app.before_request
def _see_visitor():
    """Cheapest possible online counter: ip -> last seen, no storage growth."""
    try:
        _RECENT_VISITORS[_client_ip()] = time.time()
        if len(_RECENT_VISITORS) > _RECENT_VISITORS_MAX:
            cutoff = time.time() - 600
            for key in [k for k, v in _RECENT_VISITORS.items() if v < cutoff][:1500]:
                _RECENT_VISITORS.pop(key, None)
            while len(_RECENT_VISITORS) > _RECENT_VISITORS_MAX:
                _RECENT_VISITORS.pop(next(iter(_RECENT_VISITORS)))
    except Exception:
        pass


def _live_activity_summary():
    """Aggregate live counters + recent rows, all in-memory."""
    now = time.time()
    # Distinct IPs seen anywhere on the site in the last 2 minutes.
    online_ips = {ip for ip, ts in _RECENT_VISITORS.items() if now - ts < 120}
    rows = list(_LIVE_ACTIVITY)
    def within(seconds, kind=None):
        return [r for r in rows
                if now - r["t"] <= seconds and (kind is None or r["kind"] == kind)]
    logged = len([r for r in rows[-80:] if not r["guest"]])
    return {
        "now": int(now),
        "online_now": len(online_ips),
        "media_ips_2min": len({r["ip"] for r in within(120)}),
        "logged_in_recent": logged,
        "guest_recent": max(0, len(rows[-80:]) - logged),
        "active_streams_60s": len(within(60, "stream")) + len(within(60, "play")),
        "downloads_60s": len(within(60, "download")),
        "downloads_1h": len(within(3600, "download")),
        "activity": list(reversed(rows[-120:])),
    }


@app.before_request
def _guard_request():
    """Reject scanner traffic, oversized bodies and abusive request rates."""
    path = request.path or "/"
    if _BLOCKED_PATTERNS.search(path):
        return jsonify({"status": "error", "error": "Not found."}), 404
    if len(path) > 512:
        return jsonify({"status": "error", "error": "Bad request."}), 400
    if request.method in ("POST", "PUT", "PATCH") and (request.content_length or 0) > 2 * 1024 * 1024:
        return jsonify({"status": "error", "error": "Payload too large."}), 413
    if _rate_limited(path):
        resp = jsonify({"status": "error",
                        "error": "Too many requests. Please slow down and try again shortly."})
        resp.status_code = 429
        resp.headers["Retry-After"] = "60"
        return resp
    return None


@app.after_request
def _speed_headers(resp):
    """Long-cache static assets; gzip large text responses (stdlib, no deps)."""
    try:
        if request.path.startswith("/static/"):
            resp.headers["Cache-Control"] = "public, max-age=86400, immutable"
            return resp
        if resp.status_code == 200 and "gzip" in (request.headers.get("Accept-Encoding") or ""):
            ctype = resp.headers.get("Content-Type", "")
            compressible = any(t in ctype for t in (
                "text/html", "application/json", "javascript", "text/css"))
            if not compressible:
                return resp
            body = resp.get_data()
            if len(body) > 1024:
                import gzip as _gz
                resp.set_data(_gz.compress(body, compresslevel=5))
                resp.headers["Content-Encoding"] = "gzip"
                resp.headers["Content-Length"] = str(len(resp.get_data()))
    except Exception:
        pass
    return resp


@app.after_request
def _inject_live_schedule_drawer(response):
    """Add the lightweight schedule drawer to every rendered HTML page."""
    if (response.status_code >= 400 or response.direct_passthrough
            or "text/html" not in response.headers.get("Content-Type", "")):
        return response
    try:
        body = response.get_data(as_text=True)
        if "</body>" not in body or "liveScheduleDrawer" in body:
            return response
        season, year = current_anime_season()
        with _SEASON_SCHEDULE_LOCK:
            cached = _SEASON_SCHEDULE_CACHE.get((season, year))
            schedule_items = (
                cached[2] if cached and time.monotonic() - cached[0] < cached[1]
                else None
            )
        drawer = render_template(
            "_live_schedule_drawer.html",
            schedule_items=schedule_items or [],
            schedule_needs_initial_load=schedule_items is None,
            season_name=season.title(),
            season_year=year,
            now_ts=_utc_now_timestamp(),
            open_schedule=request.args.get("schedule") == "open",
        )
        stylesheet_pattern = r'(href=["\'])/static/css/sync\.css(?:\?[^"\']*)?(["\'])'
        body, stylesheet_count = re.subn(
            stylesheet_pattern,
            r'\1/static/css/sync.css?v=20261019-themes\2',
            body,
            count=1,
        )
        body = body.replace(
            "/static/css/sync.css?v=20261019-themes",
            "/static/css/sync.css?v=20261019-themes",
        )
        if not stylesheet_count and "</head>" in body:
            body = body.replace(
                "</head>",
                '<link href="/static/css/sync.css?v=20261019-themes" rel="stylesheet"></head>',
                1,
            )
        script = ''
        if "/static/js/release-schedule.js" not in body:
            script = '<script src="/static/js/release-schedule.js?v=20261019-tabprefs" defer></script>'
        response.set_data(body.replace("</body>", drawer + script + "</body>", 1))
    except Exception:
        logger.warning("live schedule drawer injection failed", exc_info=True)
    return response


platform.ensure_admin()
platform.ensure_default_admin()

# ─── ANIME CLASSICS SECTION (homepage) ──────────────────────────────────────
# Curated timeless anime with verified AniList ids; each card links to the
# normal details/watch pages so streaming & downloads work like any other row.
ANIME_CLASSICS: List[Dict] = [
    {"id": 16498, "title": "Attack on Titan", "year": 2013, "why": "Widely ranked the #1 modern shonen era-definer"},
    {"id": 16429, "title": "Death Note", "year": 2006, "why": "All-time classic cat-and-mouse thriller"},
    {"id": 21, "title": "One Piece", "year": 1999, "why": "Longest-running top adventure epic"},
    {"id": 20, "title": "Naruto Shippuden", "year": 2007, "why": "The ninja classic that defined a generation"},
    {"id": 11061, "title": "HUNTERxHUNTER (2011)", "year": 2011, "why": "Peerless adventure & nen power system"},
    {"id": 5114, "title": "Fullmetal Alchemist: Brotherhood", "year": 2009, "why": "Consistently the top-rated classic shonen"},
    {"id": 321, "title": "Samurai Champloo", "year": 2004, "why": "Hip-hop samurai classic by Watanabe"},
    {"id": 1, "title": "Cowboy Bebop", "year": 1998, "why": "The definitive space-western jazz classic"},
    {"id": 199, "title": "Spirited Away", "year": 2001, "why": "Ghibli Oscar-winning timeless film"},
    {"id": 5680, "title": "K-On!", "year": 2009, "why": "Beloved slice-of-life band classic"},
    {"id": 11719, "title": "Sword Art Online", "year": 2012, "why": "Isekai VR-era modern classic"},
]

ANILIST_API_URL = "https://graphql.anilist.co"
_anilist_cache: OrderedDict[str, tuple] = OrderedDict()
ANILIST_CACHE_TTL = 3600  # 1 hour: catalog metadata changes slowly; repeat loads skip AniList
ANILIST_CACHE_MAX = 64  # detail responses include large relations/character lists; cap worker memory
_SEASON_SCHEDULE_LOCK = Lock()
_SEASON_SCHEDULE_CACHE = {}
_SEASON_SCHEDULE_CACHE_TTL = 900
_SEASON_SCHEDULE_FAILURE_TTL = 300
_SCHEDULE_METRICS_LOCK = Lock()
_SCHEDULE_API_REQUESTS = 0
_SCHEDULE_CACHE_MISSES = 0
_SCHEDULE_PROCESS_STARTED_AT = time.time()

MEDIA_FRAGMENT = """
  id
  idMal
  title { romaji english native }
  description(asHtml: false)
  coverImage { large extraLarge color }
  bannerImage
  episodes
  duration
  status
  format
  season
  seasonYear
  averageScore
  popularity
  genres
  studios(isMain: true) { nodes { name } }
  trailer { id site thumbnail }
  nextAiringEpisode { episode airingAt timeUntilAiring }
"""

CLASSICS_CARD_QUERY = f"""
query ($ids: [Int]) {{
  Page(perPage: 14) {{
    media(id_in: $ids, type: ANIME, sort: POPULARITY_DESC, isAdult: false) {{
      {MEDIA_FRAGMENT}
    }}
  }}
}}
"""

HOME_DASHBOARD_QUERY = f"""
query {{
  trending: Page(page: 1, perPage: 16) {{
    media(sort: TRENDING_DESC, type: ANIME, isAdult: false) {{
      {MEDIA_FRAGMENT}
    }}
  }}
  popularSeason: Page(page: 1, perPage: 12) {{
    media(sort: POPULARITY_DESC, type: ANIME, status: RELEASING, isAdult: false) {{
      {MEDIA_FRAGMENT}
    }}
  }}
  topRated: Page(page: 1, perPage: 12) {{
    media(sort: SCORE_DESC, type: ANIME, isAdult: false) {{
      {MEDIA_FRAGMENT}
    }}
  }}
  recentlyAdded: Page(page: 1, perPage: 16) {{
    media(sort: ID_DESC, type: ANIME, isAdult: false) {{
      {MEDIA_FRAGMENT}
    }}
  }}
  featuredMovie: Page(page: 1, perPage: 8) {{
    media(sort: POPULARITY_DESC, type: ANIME, format: MOVIE, isAdult: false) {{
      {MEDIA_FRAGMENT}
    }}
  }}
  series: Page(page: 1, perPage: 12) {{
    media(sort: POPULARITY_DESC, type: ANIME, format_in: [TV, TV_SHORT], isAdult: false) {{
      {MEDIA_FRAGMENT}
    }}
  }}
}}
"""

# AniList has no `seasonYear_lesser` filter; `startDate_lesser` takes a
# FuzzyDateInt (YYYYMMDD), so the year is sent as December 31st of that year.
SEARCH_FILTER_QUERY = f"""  query ($search: String, $genre: String, $format: MediaFormat, $status: MediaStatus, $sort: [MediaSort], $page: Int, $perPage: Int, $startDateBefore: FuzzyDateInt) {{
  Page(page: $page, perPage: $perPage) {{
    media(search: $search, genre: $genre, format: $format, status: $status, startDate_lesser: $startDateBefore, sort: $sort, type: ANIME, isAdult: false) {{
      {MEDIA_FRAGMENT}
    }}
  }}
}}
"""

DETAILS_QUERY = f"""
query ($id: Int) {{
  Media(id: $id, type: ANIME) {{
    {MEDIA_FRAGMENT}
    streamingEpisodes {{ title thumbnail url site }}
    relations {{
      edges {{
        relationType(version: 2)
        node {{
          id
          idMal
          type
          title {{ romaji english }}
          coverImage {{ large extraLarge }}
          episodes
          format
          status
          seasonYear
          averageScore
        }}
      }}
    }}
    recommendations(perPage: 10, sort: RATING_DESC) {{
      nodes {{
        mediaRecommendation {{
          id
          idMal
          title {{ romaji english }}
          coverImage {{ large extraLarge }}
          episodes
          format
          status
          seasonYear
          averageScore
        }}
      }}
    }}
    characters(perPage: 8, sort: [ROLE, RELEVANCE]) {{
      edges {{
        role
        node {{
          name {{ full }}
          image {{ large }}
        }}
      }}
    }}
  }}
}}
"""

POPULAR_GENRES = [
    "Action",
    "Adventure",
    "Comedy",
    "Drama",
    "Fantasy",
    "Horror",
    "Mystery",
    "Psychological",
    "Romance",
    "Sci-Fi",
    "Slice of Life",
    "Sports",
    "Supernatural",
    "Thriller",
]


def fetch_anilist(query: str, variables: Optional[Dict] = None,
                  cache_ttl: int = ANILIST_CACHE_TTL) -> Dict:
    """Fetch AniList data with bounded per-process TTL/LRU caching."""
    cache_key = f"{hash(query)}_{str(sorted((variables or {}).items()))}"
    now = time.time()
    if cache_key in _anilist_cache:
        data, ts = _anilist_cache[cache_key]
        if now - ts < max(0, int(cache_ttl)):
            _anilist_cache.move_to_end(cache_key)
            return data
        _anilist_cache.pop(cache_key, None)

    try:
        response = requests.post(
            ANILIST_API_URL,
            json={"query": query, "variables": variables or {}},
            headers={"User-Agent": DEFAULT_UA, "Accept": "application/json"},
            timeout=10,
        )
        response.raise_for_status()
        data = response.json().get("data", {})
        if data:
            _anilist_cache[cache_key] = (data, now)
            _anilist_cache.move_to_end(cache_key)
            while len(_anilist_cache) > ANILIST_CACHE_MAX:
                _anilist_cache.popitem(last=False)
        return data
    except Exception as e:
        logger.error(f"AniList API Error: {e}")
        return {}


# ─── Free fallback metadata providers (used only when AniList is down) ──────
# Chain: AniList (primary) -> Kitsu (no key, JSON:API, verified reachable) ->
# Jikan v4 / MyAnimeList (no key, 3 req/sec + 60 req/min; may be unreachable
# from some networks, so it stays second). Both adapters emit AniList-shaped
# dicts so format_anime_card() and every downstream path work unchanged.
# Fallback ids are offset into a reserved range (>= 900M) so they can never
# collide with real AniList ids; embeds needing real MAL ids use `idMal`.
KITSU_API_URL = "https://kitsu.io/api/edge"
JIKAN_API_URL = "https://api.jikan.moe/v4"
KITSU_ID_OFFSET = 900_000_000
JIKAN_ID_OFFSET = 910_000_000
_FALLBACK_API_NAMES = {"kitsu": "Kitsu", "jikan": "Jikan (MyAnimeList)"}
_JIKAN_MIN_INTERVAL = 0.5  # stay under Jikan's 3 req/sec limit
_jikan_last_call = 0.0
_jikan_lock = Lock()

KITSU_STATUS_MAP = {"current": "RELEASING", "finished": "FINISHED",
                    "upcoming": "NOT_YET_RELEASED", "unreleased": "NOT_YET_RELEASED"}
JIKAN_STATUS_MAP = {"currently airing": "RELEASING", "finished airing": "FINISHED",
                    "not yet aired": "NOT_YET_RELEASED"}
KITSU_FORMAT_MAP = {"tv": "TV", "movie": "MOVIE", "special": "SPECIAL",
                    "ova": "OVA", "ona": "ONA", "music": "MUSIC"}
JIKAN_FORMAT_MAP = {"tv": "TV", "movie": "MOVIE", "special": "SPECIAL",
                    "ova": "OVA", "ona": "ONA", "music": "MUSIC",
                    "tv special": "SPECIAL", "cm": "SPECIAL", "pv": "SPECIAL"}
KITSU_GENRE_SLUG_MAP = {"action": "action", "adventure": "adventure",
    "comedy": "comedy", "drama": "drama", "fantasy": "fantasy",
    "horror": "horror", "mystery": "mystery", "psychological": "psychological",
    "romance": "romance", "sci-fi": "sci-fi", "slice of life": "slice-of-life",
    "sports": "sports", "supernatural": "supernatural", "thriller": "thriller"}


def _fallback_cache_get(key: str):
    entry = _anilist_cache.get(key)
    if not entry:
        return None
    data, ts = entry
    if time.time() - ts > ANILIST_CACHE_TTL:
        _anilist_cache.pop(key, None)
        return None
    _anilist_cache.move_to_end(key)
    return data


def _fallback_cache_set(key: str, data):
    _anilist_cache[key] = (data, time.time())
    _anilist_cache.move_to_end(key)
    while len(_anilist_cache) > ANILIST_CACHE_MAX:
        _anilist_cache.popitem(last=False)


def _kitsu_get(path: str, params: Optional[Dict] = None):
    """GET a Kitsu JSON:API collection; returns the `data` list (or {} on error)."""
    key = f"kitsu_{path}_{str(sorted((params or {}).items()))}"
    cached = _fallback_cache_get(key)
    if cached is not None:
        return cached
    try:
        resp = requests.get(f"{KITSU_API_URL}{path}", params=params or {},
                            headers={"User-Agent": DEFAULT_UA, "Accept": "application/vnd.api+json"},
                            timeout=10)
        resp.raise_for_status()
        data = resp.json().get("data", [])
        _fallback_cache_set(key, data)
        return data
    except Exception as e:
        logger.error(f"Kitsu API Error ({path}): {e}")
        return {}


def _jikan_get(path: str, params: Optional[Dict] = None):
    """GET a Jikan v4 endpoint honouring its 3 req/sec limit; {} on error."""
    global _jikan_last_call
    key = f"jikan_{path}_{str(sorted((params or {}).items()))}"
    cached = _fallback_cache_get(key)
    if cached is not None:
        return cached
    try:
        with _jikan_lock:
            wait = _JIKAN_MIN_INTERVAL - (time.time() - _jikan_last_call)
            if wait > 0:
                time.sleep(wait)
            resp = requests.get(f"{JIKAN_API_URL}{path}", params=params or {},
                                headers={"User-Agent": DEFAULT_UA, "Accept": "application/json"},
                                timeout=12)
            _jikan_last_call = time.time()
        resp.raise_for_status()
        payload = resp.json()
        data = payload.get("data", payload)
        _fallback_cache_set(key, data)
        return data
    except Exception as e:
        logger.error(f"Jikan API Error ({path}): {e}")
        return {}


def _season_from_month(month: int) -> str:
    return ("WINTER" if month in (1, 2, 3) else "SPRING" if month in (4, 5, 6)
            else "SUMMER" if month in (7, 8, 9) else "FALL")


def _kitsu_to_media(item: Dict) -> Dict:
    """Adapt one Kitsu anime resource to an AniList MEDIA_FRAGMENT-shaped dict."""
    a = (item or {}).get("attributes", {}) or {}
    try:
        kid = int((item or {}).get("id", 0) or 0)
    except (TypeError, ValueError):
        kid = 0
    titles = a.get("titles") or {}
    title_en = titles.get("en") or a.get("canonicalTitle") or ""
    title_ro = titles.get("en_jp") or title_en
    poster = (a.get("posterImage") or {})
    img = poster.get("large") or poster.get("original") or ""
    cover = (a.get("coverImage") or {})
    start = (a.get("startDate") or "")
    year, season = "", ""
    try:
        if len(start) >= 7:
            year = int(start[:4])
            season = _season_from_month(int(start[5:7]))
    except (TypeError, ValueError):
        year, season = "", ""
    try:
        score = int(float(a.get("averageRating") or 0))
    except (TypeError, ValueError):
        score = 0
    trailer_id = a.get("youtubeVideoId") or None
    synonyms = [s for s in (a.get("abbreviatedTitles") or []) if s]
    return {
        "id": KITSU_ID_OFFSET + kid,
        "_kitsu_id": kid,
        "idMal": None,
        "title": {"romaji": title_ro or title_en or f"Anime #{kid}",
                   "english": title_en or None,
                   "native": titles.get("ja_jp") or ""},
        "description": (a.get("synopsis") or "").strip(),
        "coverImage": {"large": img, "extraLarge": img,
                        "color": None},
        "bannerImage": cover.get("large") or cover.get("original") or "",
        "episodes": a.get("episodeCount"),
        "duration": a.get("episodeLength"),
        "status": KITSU_STATUS_MAP.get((a.get("status") or "").lower(), "FINISHED"),
        "format": KITSU_FORMAT_MAP.get((a.get("subtype") or "tv").lower(), "TV"),
        "season": season,
        "seasonYear": year,
        "averageScore": score,
        "popularity": a.get("userCount") or 0,
        "genres": [],
        "studios": {"nodes": []},            "trailer": ({"site": "Youtube", "id": trailer_id} if trailer_id else None),
            "nextAiringEpisode": None,
            "_source": "kitsu",
            "_synonyms": synonyms,
        }


def _clean_jikan_synopsis(text: str) -> str:
    return re.sub(r"\s*\[Written by MAL Rewrite\]\s*", "", text or "").strip()


def _jikan_to_media(item: Dict) -> Dict:
    """Adapt one Jikan anime object to an AniList MEDIA_FRAGMENT-shaped dict."""
    item = item or {}
    try:
        mal_id = int(item.get("mal_id", 0) or 0)
    except (TypeError, ValueError):
        mal_id = 0
    images = ((item.get("images") or {}).get("jpg") or {})
    img = images.get("large_image_url") or images.get("image_url") or ""
    trailer = (item.get("trailer") or {})
    yt_id = trailer.get("youtube_id")
    minutes = None
    try:
        m = re.search(r"(\d+)\s*min", item.get("duration") or "", re.I)
        minutes = int(m.group(1)) if m else None
    except (TypeError, ValueError):
        minutes = None
    try:
        score = int(round(float(item.get("score") or 0) * 10))
    except (TypeError, ValueError):
        score = 0
    season_raw = (item.get("season") or "").upper()
    synonyms = [s for s in (item.get("title_synonyms") or []) if s]
    return {
        "id": JIKAN_ID_OFFSET + mal_id,
        "idMal": mal_id or None,
        "title": {"romaji": item.get("title") or item.get("title_english") or f"Anime #{mal_id}",
                   "english": item.get("title_english") or None,
                   "native": item.get("title_japanese") or ""},
        "description": _clean_jikan_synopsis(item.get("synopsis")),
        "coverImage": {"large": img, "extraLarge": img, "color": None},
        "bannerImage": "",
        "episodes": item.get("episodes"),
        "duration": minutes,
        "status": JIKAN_STATUS_MAP.get((item.get("status") or "").lower(), "FINISHED"),
        "format": JIKAN_FORMAT_MAP.get((item.get("type") or "tv").lower(), "TV"),
        "season": season_raw if season_raw in ("WINTER", "SPRING", "SUMMER", "FALL") else "",
        "seasonYear": item.get("year") or "",
        "averageScore": score,
        "popularity": item.get("members") or 0,
        "genres": [g.get("name") for g in (item.get("genres") or []) if g.get("name")],
        "studios": {"nodes": [{"name": s.get("name")} for s in (item.get("studios") or []) if s.get("name")]},            "trailer": ({"site": "Youtube", "id": yt_id} if yt_id else None),
            "nextAiringEpisode": None,
            "_source": "jikan",
            "_synonyms": synonyms,
        }


def _media_titles(media: Dict) -> List[str]:
    """All searchable titles for provider mapping: english/romaji/native +
    fallback-provider synonyms. Powers streaming resolution when AniList is
    down, so every anime keeps its heaven/anikoto servers."""
    media = media or {}
    out: List[str] = []
    title = media.get("title") or {}
    for key in ("english", "romaji", "native"):
        value = (title.get(key) or "").strip()
        if value and value not in out:
            out.append(value)
    for syn in (media.get("_synonyms") or []):
        value = (syn or "").strip()
        if value and value not in out:
            out.append(value)
    return out


def _kitsu_mal_id(kitsu_id: int):
    """Resolve a Kitsu anime id to its MyAnimeList id (enables real MAL embeds)."""
    if not kitsu_id:
        return None
    data = _kitsu_get(f"/anime/{kitsu_id}/mappings",
                      {"filter[externalSite]": "myAnimeList/anime"})
    try:
        for m in (data or []):
            ext = ((m or {}).get("attributes") or {}).get("externalId")
            if ext and str(ext).isdigit():
                return int(ext)
    except Exception:
        pass
    return None


def _fallback_search_media(query: str, limit: int = 12) -> Tuple[List[Dict], str]:
    """Title search across fallback providers; returns (media_list, source)."""
    query = (query or "").strip()
    if not query:
        return [], ""
    items = _kitsu_get("/anime", {"filter[text]": query, "page[limit]": max(1, min(limit, 20))})
    if items:
        return [_kitsu_to_media(i) for i in items], "kitsu"
    data = _jikan_get("/anime", {"q": query, "limit": max(1, min(limit, 20)),
                                   "order_by": "members", "sort": "desc", "sfw": "true"})
    if isinstance(data, list) and data:
        return [_jikan_to_media(i) for i in data], "jikan"
    return [], ""


def _fallback_media_by_reserved_id(anime_id: int) -> Tuple[Dict, str]:
    """Direct record lookup for fallback-range ids (no cache or title needed).

    Kitsu ids decode as id - KITSU_ID_OFFSET, Jikan/MAL ids as id -
    JIKAN_ID_OFFSET, so a watch/details URL built from a fallback card
    always resolves back to full metadata + MAL ids for streaming."""
    try:
        aid = int(anime_id)
    except (TypeError, ValueError):
        return {}, ""
    if KITSU_ID_OFFSET <= aid < JIKAN_ID_OFFSET:
        kitsu_id = aid - KITSU_ID_OFFSET
        data = _kitsu_get(f"/anime/{kitsu_id}")
        item = data if isinstance(data, dict) and data.get("attributes") else {}
        if item:
            media = _kitsu_to_media(item)
            mal = _kitsu_mal_id(kitsu_id)
            if mal:
                media["idMal"] = mal
            return media, "kitsu"
        return {}, ""
    if aid >= JIKAN_ID_OFFSET:
        data = _jikan_get(f"/anime/{aid - JIKAN_ID_OFFSET}/full")
        item = data if isinstance(data, dict) and data.get("mal_id") else {}
        if item:
            return _jikan_to_media(item), "jikan"
        return {}, ""
    return {}, ""


def _fallback_media_by_title(title: str) -> Tuple[Dict, str]:
    """Best single fallback record for a title (details path)."""
    media, source = _fallback_search_media(title, limit=5)
    if not media:
        return {}, ""
    best = media[0]
    if source == "kitsu" and best.get("_kitsu_id"):
        mal = _kitsu_mal_id(best["_kitsu_id"])
        if mal:
            best["idMal"] = mal
    return best, source


def _fallback_recent_media(prefer_kitsu: bool = True) -> List[Dict]:
    """Recently-started airing shows. Lazy second-provider lookup: the slow
    cross-provider hop only happens when the primary returns nothing, so a
    cold homepage never waits on both APIs."""
    def _kitsu_season() -> List[Dict]:
        season, year = current_anime_season()
        items = _kitsu_get("/anime", {"filter[season]": season.lower(),
                                       "filter[seasonYear]": year,
                                       "sort": "-userCount", "page[limit]": 12}) or []
        return [_kitsu_to_media(i) for i in items]

    def _jikan_recent() -> List[Dict]:
        recent = _jikan_get("/anime", {"order_by": "start_date", "sort": "desc",
                                        "status": "airing", "limit": 12, "page": 1,
                                        "sfw": "true"})
        items = [i for i in (recent if isinstance(recent, list) else [])]
        return [_jikan_to_media(i) for i in items]

    if prefer_kitsu:
        return _kitsu_season() or _jikan_recent()
    return _jikan_recent() or _kitsu_season()


def _fallback_home_lists() -> Tuple[Dict[str, List[Dict]], str]:
    """Homepage rows when the AniList dashboard query fails.

    `popular`/`ongoing` carry currently-airing shows (the "Popular This
    Season" shelf), `recent` carries recently-started airing shows, so the
    site keeps showing recent and ongoing anime with zero AniList."""
    trending = _kitsu_get("/anime", {"sort": "-userCount", "page[limit]": 12})
    if trending:
        top = _kitsu_get("/anime", {"sort": "-averageRating", "page[limit]": 12}) or []
        movies = _kitsu_get("/anime", {"filter[subtype]": "movie",
                                        "sort": "-userCount", "page[limit]": 8}) or []
        ongoing = _kitsu_get("/anime", {"filter[status]": "current",
                                         "sort": "-userCount", "page[limit]": 12}) or []
        return {"trending": [_kitsu_to_media(i) for i in trending],
                "popular": [_kitsu_to_media(i) for i in (ongoing or trending[:10])],
                "ongoing": [_kitsu_to_media(i) for i in ongoing],
                "top_rated": [_kitsu_to_media(i) for i in top],
                "movies": [_kitsu_to_media(i) for i in movies],
                "recent": _fallback_recent_media(prefer_kitsu=True)}, "kitsu"
    airing = _jikan_get("/top/anime", {"filter": "airing", "limit": 12, "page": 1})
    top = _jikan_get("/top/anime", {"limit": 12, "page": 1})
    if isinstance(airing, list) and airing:
        return {"trending": [_jikan_to_media(i) for i in airing],
                "popular": [_jikan_to_media(i) for i in airing[:10]],
                "ongoing": [_jikan_to_media(i) for i in airing],
                "top_rated": [_jikan_to_media(i) for i in (top if isinstance(top, list) else [])],
                "movies": [],
                "recent": _fallback_recent_media(prefer_kitsu=False)}, "jikan"
    return {}, ""


def _fallback_season_schedule(season: str, year: int) -> Optional[List[Dict]]:
    """Current-season airing rows via Jikan seasons/now, else Kitsu season filter.

    Neither exposes exact episode air-times, so rows are honest `date_unknown`
    listings of shows really airing now — never fabricated countdowns."""
    now_ts = _utc_now_timestamp()
    sched: List[Dict] = []
    for page in (1, 2):
        data = _jikan_get("/seasons/now", {"page": page, "limit": 25, "sfw": "true"})
        if not isinstance(data, list) or not data:
            break
        for item in data:
            media = _jikan_to_media(item)
            card = format_anime_card(media)
            b = (item or {}).get("broadcast") or {}
            when = " ".join(x for x in (b.get("day"), b.get("time"), b.get("timezone")) if x).strip()
            card["next_airing_episode"] = None
            card["airing_hour"] = when
            card["availability"] = "date_unknown"
            card["upcoming"] = False
            card["released_episode"] = None
            card["official_episode_link"] = None
            card["official_link_available"] = False
            card["playback_available"] = False
            card["download_available"] = False
            sched.append({"id": card["id"], "title": card["title"],
                          "next_airing_episode": None, "airing_hour": when,
                          "availability": "date_unknown", "upcoming": False,
                          "released_episode": None, "official_episode_link": None,
                          "official_link_available": False, "playback_available": False,
                          "download_available": False})
        if len(data) < 25:
            break
    if sched:
        return sched
    items = _kitsu_get("/anime", {"filter[season]": (season or "").lower(),
                                   "filter[seasonYear]": year,
                                   "sort": "-userCount", "page[limit]": 20})
    if items:
        out = []
        for item in items:
            media = _kitsu_to_media(item)
            card = format_anime_card(media)
            out.append({"id": card["id"], "title": card["title"],
                        "next_airing_episode": None, "airing_hour": "",
                        "availability": "date_unknown", "upcoming": False,
                        "released_episode": None, "official_episode_link": None,
                        "official_link_available": False, "playback_available": False,
                        "download_available": False})
        return out
    return None


def current_anime_season(now: Optional[datetime] = None):
    """Return AniList's initial-release season for the current UTC date."""
    now = now or datetime.now(timezone.utc)
    season = ("WINTER" if now.month in (1, 2, 3) else
              "SPRING" if now.month in (4, 5, 6) else
              "SUMMER" if now.month in (7, 8, 9) else "FALL")
    return season, now.year


SEASON_MEDIA_FRAGMENT = """
  id
  idMal
  title { romaji english native }
  coverImage { large extraLarge color }
  bannerImage
  episodes
  status
  format
  season
  seasonYear
  averageScore
  genres
  nextAiringEpisode { episode airingAt timeUntilAiring }
  streamingEpisodes { title url site }
  airingSchedule(notYetAired: true, page: 1, perPage: 1) {
    nodes { episode airingAt timeUntilAiring }
  }
"""

SEASON_AIRING_QUERY = f"""
query ($page: Int, $perPage: Int, $season: MediaSeason, $seasonYear: Int) {{
  Page(page: $page, perPage: $perPage) {{
    media(type: ANIME, status_in: [RELEASING, NOT_YET_RELEASED],
          season: $season, seasonYear: $seasonYear,
          format_in: [TV, TV_SHORT], sort: POPULARITY_DESC, isAdult: false) {{
      {SEASON_MEDIA_FRAGMENT}
    }}
  }}
}}
"""


def get_current_season_schedule(now_ts: Optional[int] = None) -> List[Dict]:
    """Serve a per-worker cached schedule and coalesce concurrent upstream fetches."""
    global _SCHEDULE_CACHE_MISSES
    season, year = current_anime_season()
    cache_key = (season, year)
    with _SEASON_SCHEDULE_LOCK:
        cached = _SEASON_SCHEDULE_CACHE.get(cache_key)
        if cached and time.monotonic() - cached[0] < cached[1]:
            return cached[2]
        with _SCHEDULE_METRICS_LOCK:
            _SCHEDULE_CACHE_MISSES += 1
        schedule = _load_current_season_schedule(now_ts, season, year)
        # On provider errors, cool down instead of retrying on every homepage
        # or API request. Successful (including empty) seasons cache for 15m.
        if schedule is None:
            schedule = []
            ttl = _SEASON_SCHEDULE_FAILURE_TTL
        else:
            ttl = _SEASON_SCHEDULE_CACHE_TTL
        _SEASON_SCHEDULE_CACHE[cache_key] = (time.monotonic(), ttl, schedule)
        return schedule


def _load_current_season_schedule(now_ts: Optional[int] = None,
                                  season: Optional[str] = None,
                                  year: Optional[int] = None) -> Optional[List[Dict]]:
    """Fetch every currently airing or upcoming TV series for this season."""
    if season is None or year is None:
        season, year = current_anime_season()
    now_ts = _utc_now_timestamp() if now_ts is None else int(now_ts)
    per_page = 50
    schedule = []
    # Two bounded pages cover current seasons (71 Fall 2026 titles observed)
    # without unbounded work. Cache each page for 15m so visitor refreshes don't
    # multiply AniList requests per worker.
    for page in range(1, 3):
        data = fetch_anilist(SEASON_AIRING_QUERY, {
            "season": season, "seasonYear": year, "page": page, "perPage": per_page,
        }, cache_ttl=_SEASON_SCHEDULE_CACHE_TTL)
        if "Page" not in data:
            # AniList down: fall back to free providers instead of an empty drawer.
            return _fallback_season_schedule(season, year)
        page_data = data.get("Page") or {}
        media = page_data.get("media") or []
        for anime in media:
            if anime.get("status") not in ("RELEASING", "NOT_YET_RELEASED"):
                continue
            next_ep = anime.get("nextAiringEpisode") or {}
            next_time = next_ep.get("airingAt")
            if not isinstance(next_time, int) or next_time <= now_ts:
                future = [ep for ep in ((anime.get("airingSchedule") or {}).get("nodes") or [])
                          if isinstance(ep.get("airingAt"), int) and ep["airingAt"] > now_ts]
                if future:
                    next_ep = future[0]
                    next_time = next_ep.get("airingAt")
            card = format_anime_card(anime)
            if isinstance(next_time, int):
                card["next_airing_episode"] = {
                    "episode": next_ep.get("episode"),
                    "airing_at": next_time,
                    "seconds_until_airing": max(0, next_time - now_ts),
                }
                card["airing_hour"] = datetime.fromtimestamp(next_time, timezone.utc).strftime("%H:%M UTC")
                card["availability"] = "upcoming" if next_time > now_ts else "air_time_passed"
            else:
                card["next_airing_episode"] = None
                card["airing_hour"] = ""
                card["availability"] = "date_unknown"
            card["upcoming"] = card["availability"] == "upcoming"
            next_episode_number = next_ep.get("episode") if isinstance(next_ep, dict) else None
            if isinstance(next_episode_number, int) and isinstance(next_time, int):
                released_episode_number = (
                    next_episode_number if next_time <= now_ts
                    else (next_episode_number - 1 if next_episode_number > 1 else None)
                )
            else:
                released_episode_number = None
            official_link = None
            if isinstance(released_episode_number, int):
                for source in anime.get("streamingEpisodes") or []:
                    match = re.search(r"\b(?:episode|ep)\s*0*(\d+)\b", source.get("title") or "", re.I)
                    source_url = (source.get("url") or "").strip()
                    parsed_source = urlparse(source_url)
                    if (match and int(match.group(1)) == released_episode_number
                            and parsed_source.scheme in ("http", "https") and parsed_source.hostname
                            and not parsed_source.username and not parsed_source.password):
                        official_link = {"url": source_url, "provider": source.get("site") or "Official provider"}
                        break
            if not official_link:
                # A link to an episode known to have released is still useful,
                # but must never be advertised as an upcoming playable source.
                last_aired_episode = next_ep.get("episode") if isinstance(next_ep, dict) else None
                if isinstance(last_aired_episode, int) and isinstance(next_time, int) and next_time > now_ts:
                    for source in anime.get("streamingEpisodes") or []:
                        match = re.search(r"\b(?:episode|ep)\s*0*(\d+)\b", source.get("title") or "", re.I)
                        source_url = (source.get("url") or "").strip()
                        parsed_source = urlparse(source_url)
                        if (match and int(match.group(1)) == last_aired_episode - 1
                                and parsed_source.scheme in ("http", "https") and parsed_source.hostname
                                and not parsed_source.username and not parsed_source.password):
                            official_link = {"url": source_url, "provider": source.get("site") or "Official provider"}
                            released_episode_number = last_aired_episode - 1
                            break
            card["released_episode"] = released_episode_number
            card["official_episode_link"] = official_link
            card["official_link_available"] = bool(official_link)
            # AniList metadata links out to legal providers; it does not grant
            # CamAnime rights to host, embed, or download the episode itself.
            card["playback_available"] = False
            card["download_available"] = False
            # Keep responses and server-rendered pages small: schedule views
            # need no poster, banner, genre, or general catalogue metadata.
            schedule.append({
                "id": card["id"],
                "title": card["title"],
                "next_airing_episode": card["next_airing_episode"],
                "airing_hour": card["airing_hour"],
                "availability": card["availability"],
                "upcoming": card["upcoming"],
                "released_episode": card["released_episode"],
                "official_episode_link": card["official_episode_link"],
                "official_link_available": card["official_link_available"],
                "playback_available": False,
                "download_available": False,
            })
        if len(media) < per_page:
            break
    schedule.sort(key=lambda item: (
        item["next_airing_episode"]["airing_at"] if item["next_airing_episode"] else float("inf"),
        item["title"].casefold()))
    return schedule


def clean_html_description(desc: Optional[str]) -> str:
    if not desc:
        return "No synopsis available."
    text = re.sub(r"<br\s*/?>", "\n", desc, flags=re.I)
    text = re.sub(r"<[^>]+>", "", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def _episode_number(value) -> Optional[int]:
    """Return a positive whole episode number; ignore malformed/special labels."""
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    if number < 1 or not number.is_integer():
        return None
    return int(number)


def _confirmed_episode_numbers(anime: Dict, provider_episodes=None,
                               now_ts: Optional[int] = None) -> List[int]:
    """Return episode numbers confirmed aired or explicitly listed by a provider."""
    anime = anime or {}
    now_ts = _utc_now_timestamp() if now_ts is None else int(now_ts)
    provider_numbers = {
        number for number in (
            _episode_number((episode or {}).get("num"))
            for episode in (provider_episodes or [])
        ) if number is not None
    }
    status = (anime.get("status") or "").upper()
    next_airing = anime.get("nextAiringEpisode") or {}
    next_number = _episode_number(next_airing.get("episode"))
    airing_at = next_airing.get("airingAt")

    if status == "RELEASING":
        # Never count the listed next episode at its scheduled instant; wait
        # for AniList to advance or an exact episode listing from a provider.
        aired_count = 0
        if next_number and isinstance(airing_at, int):
            aired_count = next_number - 1 if airing_at >= now_ts else next_number
        provider_numbers.update(range(1, aired_count + 1))
    elif status == "FINISHED":
        # A finished series' known AniList total is its completed episode count.
        total = _episode_number(anime.get("episodes")) or 0
        provider_numbers.update(range(1, total + 1))

    return sorted(provider_numbers)


def _confirmed_episode_count(anime: Dict, provider_episodes=None,
                             now_ts: Optional[int] = None) -> int:
    """Return the highest episode number confirmed aired or provider-listed."""
    return max(_confirmed_episode_numbers(anime, provider_episodes, now_ts), default=0)


def format_anime_card(anime: Dict) -> Dict:
    if not anime:
        return {}
    title_obj = anime.get("title") or {}
    title_en = title_obj.get("english")
    title_ro = title_obj.get("romaji")
    title = title_en or title_ro or "Unknown Anime"
    cover = anime.get("coverImage") or {}
    image_url = cover.get("extraLarge") or cover.get("large") or ""

    next_ep = anime.get("nextAiringEpisode")
    total_eps = anime.get("episodes")
    status = (anime.get("status") or "").upper()
    latest_ep = _confirmed_episode_count(anime)
    if status == "RELEASING":
        ep_badge = f"EP {latest_ep}" if latest_ep else "AIRING"
    elif status == "NOT_YET_RELEASED":
        ep_badge = "UPCOMING"
    elif latest_ep:
        ep_badge = f"{latest_ep} EPS"
    else:
        ep_badge = "EPS ?"
    latest_ep = latest_ep or None

    trailer = anime.get("trailer") or {}
    yt_id = (
        trailer.get("id")
        if (trailer.get("site") or "").lower() == "youtube"
        else None
    )

    studios = ((anime.get("studios") or {}).get("nodes") or [])
    studio_name = studios[0].get("name") if studios else ""

    score = anime.get("averageScore")
    rating = f"{score / 10:.1f}" if score else "N/A"

    return {
        "id": anime.get("id"),
        "mal_id": anime.get("idMal"),
        "title": title,
        "title_romaji": title_ro or title,
        "title_native": title_obj.get("native") or "",
        "description": clean_html_description(anime.get("description")),
        "image": image_url or "/static/brand/camanime-icon.svg",
        "banner": anime.get("bannerImage") or image_url or "/static/brand/camanime-icon.svg",
        "color": cover.get("color") or "#f59e0b",
        "episode": ep_badge,
        "latest_ep": latest_ep,
        "total_episodes": _episode_number(total_eps) if status == "FINISHED" else None,
        "format": anime.get("format") or "TV",
        "status": (anime.get("status") or "FINISHED").replace("_", " ").title(),
        "season": f"{(anime.get('season') or '').title()} {anime.get('seasonYear') or ''}".strip(),
        "year": anime.get("seasonYear") or "",
        "next_airing_episode": ({
            "episode": next_ep.get("episode"),
            "airing_at": next_ep.get("airingAt"),
            "seconds_until_airing": next_ep.get("timeUntilAiring"),
        } if next_ep else None),
        "airing_hour": (
            datetime.fromtimestamp(next_ep["airingAt"], timezone.utc).strftime("%H:%M UTC")
            if next_ep and next_ep.get("airingAt") else ""),
        "duration": f"{anime.get('duration')}m" if anime.get("duration") else "",
        "rating": rating,
        "score": score or 0,
        "genres": (anime.get("genres") or [])[:4],
        "studio": studio_name,
        "trailer_id": yt_id,
    }


def rewrite_hls_playlist(body: str, source_url: str, ref: Optional[str] = None) -> str:
    """Rewrites all segment/variant/key/audio/subtitle URIs in an M3U8 playlist to route through /api/proxy/hls."""
    ref_param = f"&ref={quote(ref, safe='')}" if ref else ""

    def proxy_uri(uri: str) -> str:
        full_url = urljoin(source_url, uri.strip())
        return f"/api/proxy/hls?url={quote(full_url, safe='')}{ref_param}"

    lines = body.splitlines()
    has_default_audio = any(
        "#EXT-X-MEDIA:TYPE=AUDIO" in ln and "DEFAULT=YES" in ln for ln in lines
    )
    first_audio_marked = False
    out_lines = []

    for line in lines:
        trimmed = line.strip()
        if not trimmed:
            out_lines.append(line)
            continue

        processed = line
        if (
            not has_default_audio
            and not first_audio_marked
            and "#EXT-X-MEDIA:TYPE=AUDIO" in trimmed
        ):
            processed = processed.replace("DEFAULT=NO", "DEFAULT=YES").replace(
                "AUTOSELECT=NO", "AUTOSELECT=YES"
            )
            first_audio_marked = True

        if processed.lstrip().startswith("#"):
            if "URI=" in processed:
                processed = re.sub(
                    r'URI="([^"]+)"',
                    lambda m: f'URI="{proxy_uri(m.group(1))}"',
                    processed,
                )
            out_lines.append(processed)
        else:
            out_lines.append(proxy_uri(trimmed))

    return "\n".join(out_lines)


# ─── WEB PAGES ───────────────────────────────────────────────────────────────


def _web_catalog_filters(search_query: str = "") -> Dict:
    """Validate the small set of discovery filters accepted by the web UI."""
    genre = request.args.get("genre", "").strip()
    if genre not in POPULAR_GENRES:
        genre = ""
    media_format = request.args.get("format", "").strip().upper()
    if media_format not in CATALOG_FORMATS:
        media_format = ""
    status = request.args.get("status", "").strip().upper()
    if status not in {"FINISHED", "RELEASING", "NOT_YET_RELEASED", "CANCELLED"}:
        status = ""
    year_before = request.args.get("year_before", type=int)
    if year_before is not None and not 1900 <= year_before <= 2100:
        year_before = None
    sort_key = request.args.get("sort", "popular").strip().lower()
    if sort_key not in CATALOG_SORTS:
        sort_key = "popular"
    variables: Dict = {"page": 1, "perPage": 24, "sort": [CATALOG_SORTS[sort_key]]}
    if search_query:
        variables["search"] = search_query
    if genre:
        variables["genre"] = genre
    if media_format:
        variables["format"] = media_format
    if status:
        variables["status"] = status
    if year_before is not None:
        variables["startDateBefore"] = year_before * 10000 + 1231
    return {
        "genre": genre,
        "format": media_format,
        "status": status,
        "year_before": year_before or "",
        "sort": sort_key,
        "variables": variables,
    }


@app.route("/")
def home():
    filters = _web_catalog_filters()
    genre, fmt = filters["genre"], filters["format"]

    if any((genre, fmt, filters["status"], filters["year_before"])) or filters["sort"] != "popular":
        data = fetch_anilist(SEARCH_FILTER_QUERY, filters["variables"])
        raw_list = data.get("Page", {}).get("media", [])
        filtered_cards = [format_anime_card(a) for a in raw_list if a]
        featured = filtered_cards[0] if filtered_cards else None
        return render_template(
            "index.html",
            trending=filtered_cards,
            popular_season=[],
            top_rated=[],
            heaven_recent=[],
            featured=featured,
            hero_slides=filtered_cards[:5],
            genres=POPULAR_GENRES,
            active_genre=genre,
            active_format=fmt,
            active_status=filters["status"],
            active_year_before=filters["year_before"],
            active_sort=filters["sort"],
            page_type="filter",
        )

    data = fetch_anilist(HOME_DASHBOARD_QUERY)
    trending_raw = data.get("trending", {}).get("media", [])
    season_raw = data.get("popularSeason", {}).get("media", [])
    top_raw = data.get("topRated", {}).get("media", [])

    trending = [format_anime_card(a) for a in trending_raw if a]
    popular_season = [format_anime_card(a) for a in season_raw if a]
    top_rated = [format_anime_card(a) for a in top_raw if a]
    if not trending and not popular_season and not top_rated:
        # AniList down: free fallback providers keep the homepage real.
        fb_lists, _fb_source = _fallback_home_lists()
        trending = [format_anime_card(a) for a in fb_lists.get("trending", [])]
        popular_season = [format_anime_card(a) for a in fb_lists.get("popular", [])]
        top_rated = [format_anime_card(a) for a in fb_lists.get("top_rated", [])]

    # Seasons / best-of rows: put this WEEK's and this MONTH's standouts in
    # shuffled rows so users always discover something new on every visit.
    weekly_row = [a for a in trending if a.get("status") == "Releasing"][:10]
    monthly_row = [a for a in top_rated if a.get("score", 0) >= 78][:10]
    random.shuffle(weekly_row)
    random.shuffle(monthly_row)

    # Cache each card's meta for the server-side watch-history viewer + rankings
    for card in (trending + popular_season + top_rated):
        try:
            platform.cache_anime_meta(
                card.get("id"), title=card.get("title", ""), image=card.get("image", ""),
                banner=card.get("banner", ""), format=card.get("format", ""),
                status=card.get("status", ""), year=card.get("year") or 0,
                episode_label=card.get("episode", ""))
        except Exception:
            pass

    hero_slides = [a for a in trending if a.get("banner")][:6] or trending[:5]
    featured = hero_slides[0] if hero_slides else None

    # Anime Classics: real AniList cards (covers auto-refresh hourly via the
    # metadata cache) fused with the curated 'why it's a classic' notes.
    classics_raw = (fetch_anilist(CLASSICS_CARD_QUERY, {"ids": [c["id"] for c in ANIME_CLASSICS]})
                    .get("Page", {}).get("media") or [])
    why_map = {c["id"]: c.get("why", "") for c in ANIME_CLASSICS}
    classics = []
    for a in classics_raw:
        ccard = format_anime_card(a)
        ccard["why"] = why_map.get(ccard["id"], "")
        classics.append(ccard)
    if not classics:
        # AniList hiccup fallback: still show the section with raw curated ids
        classics = [{**c, "image": "", "rating": "", "episode": "CLASSIC", "format": "TV"}
                    for c in ANIME_CLASSICS]

    # Global most-watched ranking feed for all three tabs (Day/Week/Month)
    try:
        most_viewed_day = platform.most_watched(int(time.time()) - 86400, limit=12)
        most_viewed_week = platform.most_watched(int(time.time()) - 7*86400, limit=12)
        most_viewed_month = platform.most_watched(int(time.time()) - 30*86400, limit=12)
    except Exception:
        most_viewed_day = most_viewed_week = most_viewed_month = []

    # Factual public counters for homepage stat strip
    try:
        _c = platform.get_counters()
        public_counters = {
            "app_downloads": _c.get("app_downloads", 0),
            # Count each player-start event once. Proxy chunks and retries are not plays.
            "streams": _c.get("plays", 0),
            "downloads": _c.get("downloads", 0),
            "users": platform.get_user_count(),
        }
    except Exception:
        public_counters = {"app_downloads": 0, "streams": 0, "downloads": 0, "users": 0}

    # Complete current-season schedule; the client refreshes it as air times pass.
    countdown_items = get_current_season_schedule()

    # Fetch live AnimeHeaven latest releases for the homepage live scraper strip
    heaven_recent = streaming_manager.animeheaven.browse_catalog("new")[:12]

    # Sign-in aware continue-watching: server-synced rows when logged in, else local
    synced_history = []
    current_user = _current_user()
    if current_user and not current_user.get("guest"):
        try:
            synced_history = platform.get_history(current_user["email"], limit=12)
        except Exception:
            synced_history = []

    return render_template(
        "index.html",
        trending=trending,
        popular_season=popular_season,
        top_rated=top_rated,
        weekly_row=weekly_row,
        monthly_row=monthly_row,
        classics=classics,
        most_viewed_day=most_viewed_day,
        most_viewed_week=most_viewed_week,
        most_viewed_month=most_viewed_month,
        public_counters=public_counters,
        countdown_items=countdown_items,
        season_name=current_anime_season()[0].title(),
        season_year=current_anime_season()[1],
        now_ts=_utc_now_timestamp(),
        synced_history=synced_history,
        signed_in=bool(current_user and not current_user.get("guest")),
        heaven_recent=heaven_recent,
        featured=featured,
        hero_slides=hero_slides,
        open_schedule=request.args.get("schedule") == "open",
        genres=POPULAR_GENRES,
        active_genre="",
        active_format="",
        active_status="",
        active_year_before="",
        active_sort="popular",
        page_type="home",
        announcement=(platform.list_announcements(1) or [None])[0],
    )


@app.route("/search")
def search():
    query = (request.args.get("q") or "").strip()
    if not query:
        return redirect(url_for("home"))

    filters = _web_catalog_filters(query)
    data = fetch_anilist(SEARCH_FILTER_QUERY, filters["variables"])
    raw_results = data.get("Page", {}).get("media", [])
    results = [format_anime_card(a) for a in raw_results if a]
    if not results:
        # AniList down: free fallback providers keep search real.
        fb_media, _fb_source = _fallback_search_media(query, limit=12)
        results = [format_anime_card(a) for a in fb_media]

    # Also search AnimeHeaven directly so niche / scraper-only shows appear
    heaven_matches = streaming_manager.animeheaven.search(query)[:12]

    return render_template(
        "index.html",
        trending=results,
        heaven_recent=heaven_matches,
        popular_season=[],
        top_rated=[],
        featured=results[0] if results else None,
        hero_slides=[],
        search_query=query,
        search_result_count=len(results),
        provider_result_count=len(heaven_matches),
        genres=POPULAR_GENRES,
        active_genre=filters["genre"],
        active_format=filters["format"],
        active_status=filters["status"],
        active_year_before=filters["year_before"],
        active_sort=filters["sort"],
        page_type="search",
    )


def _details_provider_fallback(anime_id: int):
    """Last-resort details page: server cache + live provider listings only."""
    card = _fallback_card(anime_id)
    titles = [card["title"]]
    mapping = streaming_manager.resolve_anime_mapping(anime_id, titles, mal_id=None)
    heaven_info = (
        streaming_manager.animeheaven.get_anime_info(mapping["heaven_id"])
        if mapping.get("heaven_id") else None
    )
    provider_episodes = list((heaven_info or {}).get("episodes") or [])
    if mapping.get("anikoto_slug"):
        provider_episodes.extend(streaming_manager.anikoto.get_episodes(mapping["anikoto_slug"]))
    confirmed_numbers = sorted({
        n for n in (_episode_number((e or {}).get("num")) for e in provider_episodes)
        if n is not None
    })
    episode_list = [{"id": i, "num": i, "title": f"Episode {i}",
                     "thumbnail": card["banner"] or card["image"],
                     "heaven_key": None, "provider_listed": True,
                     "availability_label": "Provider episode listing found · playback not verified",
                     "added": ""} for i in confirmed_numbers]
    return render_template("details.html", anime={
        **card, "tags": [], "episodes": episode_list, "relations": [],
        "recommendations": [], "characters": [],
        "heaven_id": mapping.get("heaven_id"),
        "anikoto_slug": mapping.get("anikoto_slug"),
        "heaven_info": heaven_info,
        "anilist_unavailable": True,
    })


@app.route("/anime/<int:anime_id>")
def details(anime_id: int):
    data = fetch_anilist(DETAILS_QUERY, {"id": anime_id})
    raw_anime = data.get("Media")
    if not raw_anime:
        # AniList outage: try free fallback providers (Kitsu -> Jikan), so the
        # page keeps real metadata + MAL ids. Reserved-range ids decode
        # directly; real ids use the cached title. Only when both fail do we
        # serve the generic provider-listing fallback.
        if _is_fallback_id(anime_id):
            raw_anime, _fb_source = _fallback_media_by_reserved_id(anime_id)
        if not raw_anime:
            try:
                _meta = (platform.get_anime_meta([anime_id]) or {}).get(int(anime_id), {})
                _cached_title = (_meta.get("title") or "").strip()
            except Exception:
                _cached_title = ""
            if _cached_title and not _cached_title.startswith("Anime #"):
                fb_media, _fb_source = _fallback_media_by_title(_cached_title)
                if fb_media:
                    raw_anime = fb_media
        if not raw_anime:
            return _details_provider_fallback(anime_id)
        # Fall through to the normal path with fallback-sourced metadata.

    card = format_anime_card(raw_anime)
    titles = _media_titles(raw_anime)

    # Resolve YouTube Trailer (AniList trailer or live YouTube search fallback)
    trailer_id = streaming_manager.youtube.get_trailer_id(
        card["title"], raw_anime.get("trailer")
    )
    card["trailer_id"] = trailer_id

    # Map to AnimeHeaven & Anikoto to verify real available episodes
    mapping = streaming_manager.resolve_anime_mapping(
        anime_id, titles, mal_id=raw_anime.get("idMal")
    )
    heaven_info = (
        streaming_manager.animeheaven.get_anime_info(mapping["heaven_id"])
        if mapping.get("heaven_id")
        else None
    )

    # Only list episodes AniList says have aired or a matched provider lists.
    provider_episodes = list((heaven_info or {}).get("episodes") or [])
    if mapping.get("anikoto_slug"):
        provider_episodes.extend(streaming_manager.anikoto.get_episodes(mapping["anikoto_slug"]))
    confirmed_numbers = _confirmed_episode_numbers(raw_anime, provider_episodes)
    total_episodes = len(confirmed_numbers)
    provider_numbers = {
        _episode_number((episode or {}).get("num"))
        for episode in provider_episodes
    }
    provider_numbers.discard(None)

    # Build rich episode metadata from AniList streamingEpisodes if available
    st_eps = raw_anime.get("streamingEpisodes") or []
    ep_meta_by_num: Dict[int, Dict] = {}
    for se in st_eps:
        m = re.search(r"Episode\s*(\d+)", se.get("title") or "", re.I)
        if m:
            ep_meta_by_num[int(m.group(1))] = {
                "title": se.get("title"),
                "thumbnail": se.get("thumbnail"),
            }

    heaven_eps_by_num: Dict[int, Dict] = {}
    if heaven_info and heaven_info.get("episodes"):
        for he in heaven_info["episodes"]:
            try:
                heaven_eps_by_num[int(round(float(he["num"])))] = he
            except Exception:
                pass

    episode_list = []
    for i in confirmed_numbers:
        meta = ep_meta_by_num.get(i, {})
        h_ep = heaven_eps_by_num.get(i)
        episode_list.append({
            "id": i,
            "num": i,
            "title": meta.get("title") or f"Episode {i}",
            "thumbnail": meta.get("thumbnail") or card["banner"] or card["image"],
            "heaven_key": h_ep["key"] if h_ep else None,
            "provider_listed": i in provider_numbers,
            "availability_label": "Provider episode listing found · playback not verified" if i in provider_numbers else "Aired · playback source not checked",
            "added": h_ep.get("added", "") if h_ep else "",
        })

    # Related seasons / sequels / prequels
    relations = []
    for edge in (raw_anime.get("relations") or {}).get("edges") or []:
        node = edge.get("node") or {}
        if node.get("type") == "ANIME" and node.get("id"):
            rel_card = format_anime_card(node)
            rel_card["relation"] = (edge.get("relationType") or "RELATED").replace("_", " ")
            # Accurate per-season episode count: a null `episodes` is normal for
            # titles still airing, so use the aired count instead of a blank or
            # invented number.
            _count = _confirmed_episode_count(node)
            rel_card["episode_count"] = _count or None
            relations.append(rel_card)

    # Order seasons chronologically: prequels/parents first, then by year
    _rel_order = {"PREQUEL": 0, "PARENT": 0, "SOURCE": 1, "SEQUEL": 2, "SPIN OFF": 3, "SIDE STORY": 3}
    relations.sort(key=lambda r: (_rel_order.get((r.get("relation") or "").upper(), 4), r.get("year") or 0))

    # Recommendations
    recommendations = []
    for rec in (raw_anime.get("recommendations") or {}).get("nodes") or []:
        mr = rec.get("mediaRecommendation")
        if mr and mr.get("id"):
            recommendations.append(format_anime_card(mr))

    # Characters
    characters = []
    for ch_edge in (raw_anime.get("characters") or {}).get("edges") or []:
        c_node = ch_edge.get("node") or {}
        if c_node.get("name", {}).get("full"):
            characters.append({
                "name": c_node["name"]["full"],
                "role": (ch_edge.get("role") or "MAIN").title(),
                "image": (c_node.get("image") or {}).get("large") or "",
            })

    anime_payload = {
        **card,
        "tags": raw_anime.get("genres") or [],
        "episodes": episode_list,
        "relations": relations[:8],
        "recommendations": recommendations[:8],
        "characters": characters[:8],
        "heaven_id": mapping.get("heaven_id"),
        "anikoto_slug": mapping.get("anikoto_slug"),
        "heaven_info": heaven_info,
    }

    return render_template("details.html", anime=anime_payload)


@app.route("/watch/<int:anime_id>/<int:ep_num>")
def watch(anime_id: int, ep_num: int):
    preferred_audio = request.args.get("audio", "sub").lower()
    if preferred_audio not in ("sub", "dub"):
        preferred_audio = "sub"
    heaven_override = _safe_site_id(request.args.get("heaven_id", ""))

    data = fetch_anilist(DETAILS_QUERY, {"id": anime_id})
    raw_anime = data.get("Media") or {}
    anilist_down = not raw_anime
    if not raw_anime:
        # AniList down: resolve real fallback metadata (Kitsu -> Jikan) so
        # provider mapping gets true titles + MAL ids and streaming works
        # exactly like before. Reserved-range ids decode directly (no cache
        # needed); real AniList ids fall back to the cached title.
        if _is_fallback_id(anime_id):
            raw_anime, _fb_src = _fallback_media_by_reserved_id(anime_id)
        if not raw_anime:
            try:
                _meta = (platform.get_anime_meta([anime_id]) or {}).get(int(anime_id), {})
                _cached = (_meta.get("title") or "").strip()
            except Exception:
                _cached = ""
            if _cached and not _cached.startswith("Anime #"):
                fb_media, _fb_src = _fallback_media_by_title(_cached)
                if fb_media:
                    raw_anime = fb_media
    card = format_anime_card(raw_anime) if raw_anime else _fallback_card(anime_id)

    titles = _media_titles(raw_anime) or [card["title"]]

    trailer_id = streaming_manager.youtube.get_trailer_id(
        card["title"], raw_anime.get("trailer")
    )
    card["trailer_id"] = trailer_id

    # Resolve real provider episode numbers before building the selector. This
    # also prevents an arbitrary /watch/<id>/<future-episode> URL from inventing
    # a slot for an unreleased episode.
    mapping = streaming_manager.resolve_anime_mapping(
        anime_id, titles, mal_id=raw_anime.get("idMal"), heaven_override=heaven_override
    )
    provider_episodes = []
    if mapping.get("heaven_id"):
        h_info = streaming_manager.animeheaven.get_anime_info(mapping["heaven_id"])
        provider_episodes.extend((h_info or {}).get("episodes") or [])
    if mapping.get("anikoto_slug"):
        provider_episodes.extend(streaming_manager.anikoto.get_episodes(mapping["anikoto_slug"]))
    confirmed_numbers = _confirmed_episode_numbers(raw_anime, provider_episodes)
    total_episodes = len(confirmed_numbers)
    if ep_num not in confirmed_numbers:
        if anilist_down and ep_num >= 1:
            # AniList outage: provider lists may also be title-less. Never
            # bounce the user — render the player with working embeds and an
            # honest notice instead of a redirect loop to a 404 details page.
            confirmed_numbers = [ep_num]
            episodes = [{"id": ep_num, "num": ep_num, "title": f"Episode {ep_num}"}]
            total_episodes = 1
            episode_position = 0
            previous_number = None
            next_number = None
        else:
            return redirect(url_for("details", anime_id=anime_id))

    bundle = streaming_manager.get_full_episode_bundle(
        anilist_id=anime_id,
        ep_num=ep_num,
        titles=titles,
        mal_id=(raw_anime.get("idMal") if raw_anime else None),
        preferred_audio=preferred_audio,
        heaven_override=mapping.get("heaven_id"),
    )
    if anilist_down:
        # During an AniList outage the provider mapping may be title-less, so
        # make sure the working no-title embeds are present as fallbacks.
        # Fallback-range ids have no valid upstream embed id: those pages
        # rely on resolved provider servers instead of a bogus iframe URL.
        embeds = _working_embed_urls(anime_id, None, ep_num)
        have = {s.get("stream_url") for s in bundle.get("servers", [])}
        if embeds["vidlink_sub"] not in have and not _is_fallback_id(anime_id):
            bundle.setdefault("servers", []).append({
                "id": "embed-vidlink-sub",
                "name": "VidLink Ultra (SUB)",
                "provider": "vidlink",
                "audio": "sub",
                "playback_mode": "iframe",
                "stream_url": embeds["vidlink_sub"],
                "quality": "1080p Embed",
                "subtitles": [],
                "badge": "MIRROR SUB",
            })
        if not bundle.get("servers"):
            return redirect(url_for("details", anime_id=anime_id))
        bundle["anilist_unavailable"] = True
    episodes = [{"id": i, "num": i, "title": f"Episode {i}"} for i in confirmed_numbers]
    episode_position = confirmed_numbers.index(ep_num)
    previous_number = confirmed_numbers[episode_position - 1] if episode_position > 0 else None
    next_number = confirmed_numbers[episode_position + 1] if episode_position + 1 < len(confirmed_numbers) else None

    _embeds = _working_embed_urls(anime_id, (raw_anime.get("idMal") if raw_anime else None), ep_num)
    active_server = bundle.get("active_server") or {
        "id": "embed-vidlink-sub",
        "name": "VidLink Ultra (SUB)",
        "playback_mode": "iframe",
        "stream_url": _embeds["vidlink_sub"],
        "subtitles": [],
    }
    backup_embed = _embeds["vidlink_sub"]

    # Related seasons for quick switching
    relations = []
    for edge in (raw_anime.get("relations") or {}).get("edges") or []:
        node = edge.get("node") or {}
        if node.get("type") == "ANIME" and node.get("id"):
            rel_card = format_anime_card(node)
            rel_card["relation"] = (edge.get("relationType") or "RELATED").replace("_", " ")
            # Accurate per-season episode count: a null `episodes` is normal for
            # titles still airing, so use the aired count instead of a blank or
            # invented number.
            _count = _confirmed_episode_count(node)
            rel_card["episode_count"] = _count or None
            relations.append(rel_card)

    return render_template(
        "watch.html",
        anime={
            **card,
            "bannerImage": card.get("banner") or "",
            "episodes": episodes,
            "relations": relations[:6],
        },
        ep_num=ep_num,
        total_episodes=total_episodes,
        stream_url=active_server.get("stream_url") or backup_embed,
        backup_embed=backup_embed,
        bundle=bundle,
        servers=bundle.get("servers", []),
        downloads=bundle.get("downloads", []),
        active_server=active_server,
        preferred_audio=preferred_audio,
        prev_ep={"id": previous_number, "num": previous_number} if previous_number else None,
        next_ep={"id": next_number, "num": next_number} if next_number else None,
    )


@app.route("/scraper")
def scraper_hub():
    """
    Dedicated AnimeHeaven Reverse-Engineered Scraper & Direct Downloader Hub
    (Upgraded version of the attached AnimeHeaven-Scraper test frontend integrated into CamAnime)
    """
    feed = request.args.get("feed", "new")
    if feed not in ("new", "popular", "home"):
        feed = "new"
    query = (request.args.get("q") or "").strip()[:120]
    site_id = _safe_site_id(request.args.get("id", "")) or ""

    selected_anime = None
    if site_id:
        selected_anime = streaming_manager.animeheaven.get_anime_info(site_id)

    if query:
        items = streaming_manager.animeheaven.search(query)
    else:
        items = streaming_manager.animeheaven.browse_catalog(feed)

    return render_template(
        "scraper.html",
        items=items,
        feed=feed,
        query=query,
        selected_anime=selected_anime,
    )


@app.route("/heaven/<site_id>")
def heaven_direct_watch(site_id: str):
    """Watch or download any show directly by its AnimeHeaven site_id"""
    site_id = _safe_site_id(site_id) or ""
    if not site_id:
        return redirect(url_for("scraper_hub"))
    try:
        ep_num = max(1, min(int(request.args.get("ep", 1)), 3000))
    except (TypeError, ValueError):
        ep_num = 1
    info = streaming_manager.animeheaven.get_anime_info(site_id)
    if not info:
        return redirect(url_for("scraper_hub"))

    # Try to find matching AniList entry for rich metadata, or render watch directly
    data = fetch_anilist(
        SEARCH_FILTER_QUERY,
        {"search": info["title"], "page": 1, "perPage": 5, "sort": ["POPULARITY_DESC"]},
    )
    media_list = data.get("Page", {}).get("media", [])
    if media_list:
        return redirect(
            url_for("watch", anime_id=media_list[0]["id"], ep_num=ep_num, heaven_id=site_id)
        )

    return redirect(url_for("scraper_hub", id=site_id))


# ─── JSON API & STREAMING / DOWNLOAD PROXIES ─────────────────────────────────


@app.route("/api/trailer")
def api_trailer():
    title = request.args.get("title", "").strip()
    anime_id = request.args.get("anime_id", type=int)
    anilist_trailer = None
    if anime_id:
        data = fetch_anilist(DETAILS_QUERY, {"id": anime_id})
        media = data.get("Media") or {}
        anilist_trailer = media.get("trailer")
        if not title and media.get("title"):
            title = media["title"].get("english") or media["title"].get("romaji") or ""

    yt_id = streaming_manager.youtube.get_trailer_id(title, anilist_trailer)
    if not yt_id:
        return jsonify({"status": "error", "error": "Trailer not found"}), 404
    return jsonify({
        "status": "success",
        "youtube_id": yt_id,
        "embed_url": f"https://www.youtube.com/embed/{yt_id}?autoplay=1&rel=0",
        "watch_url": f"https://www.youtube.com/watch?v={yt_id}",
    })


@app.route("/api/episode-sources/<int:anime_id>/<int:ep_num>")
def api_episode_sources(anime_id: int, ep_num: int):
    audio = request.args.get("audio", "sub").lower()
    _hv = _safe_site_id(request.args.get("heaven_id", ""))
    heaven_id = _hv
    data = fetch_anilist(DETAILS_QUERY, {"id": anime_id})
    raw_anime = data.get("Media") or {}
    if not raw_anime:
        # Same fallback-metadata upgrade as the watch page: real titles +
        # MAL ids from Kitsu/Jikan so servers resolve like before.
        if _is_fallback_id(anime_id):
            raw_anime, _fb_src = _fallback_media_by_reserved_id(anime_id)
        if not raw_anime:
            try:
                _m = (platform.get_anime_meta([anime_id]) or {}).get(int(anime_id), {})
                _cached = (_m.get("title") or "").strip()
            except Exception:
                _cached = ""
            if _cached and not _cached.startswith("Anime #"):
                fb_media, _fb_src = _fallback_media_by_title(_cached)
                if fb_media:
                    raw_anime = fb_media
    titles = _media_titles(raw_anime)
    if not titles or not any(titles):
        try:
            _m = (platform.get_anime_meta([anime_id]) or {}).get(int(anime_id), {})
            if _m.get("title"):
                titles = [_m["title"]]
        except Exception:
            pass
    if not titles or not any(titles):
        titles = [f"Anime {anime_id}"]
    bundle = streaming_manager.get_full_episode_bundle(
        anilist_id=anime_id,
        ep_num=ep_num,
        titles=titles or [f"Anime {anime_id}"],
        mal_id=raw_anime.get("idMal"),
        preferred_audio=audio,
        heaven_override=heaven_id,
    )
    return jsonify(bundle)


@app.route("/api/heaven/search")
def api_heaven_search():
    q = request.args.get("q", "").strip()
    if not q:
        return jsonify({"status": "error", "results": []}), 400
    results = streaming_manager.animeheaven.search(q)
    return jsonify({"status": "success", "count": len(results), "results": results})


@app.route("/api/heaven/catalog")
def api_heaven_catalog():
    feed = request.args.get("feed", "new")
    if feed not in ("new", "popular", "home"):
        feed = "new"
    results = streaming_manager.animeheaven.browse_catalog(feed)
    return jsonify({"status": "success", "feed": feed, "count": len(results), "results": results})


@app.route("/api/heaven/anime/<site_id>")
def api_heaven_anime(site_id: str):
    site_id = _safe_site_id(site_id) or ""
    if not site_id:
        return jsonify({"status": "error", "error": "Invalid id."}), 400
    info = streaming_manager.animeheaven.get_anime_info(site_id)
    if not info:
        return jsonify({"status": "error", "error": "Anime not found on AnimeHeaven"}), 404
    return jsonify({"status": "success", "anime": info})


@app.route("/api/heaven/random")
def api_heaven_random():
    info = streaming_manager.animeheaven.get_random_anime()
    if not info:
        return jsonify({"status": "error", "error": "Failed to fetch random anime"}), 502
    return jsonify({"status": "success", "anime": info})


@app.route("/api/heaven/resolve/<episode_key>")
def api_heaven_resolve(episode_key: str):
    episode_key = _safe_site_id(episode_key) or ""
    if not episode_key:
        return jsonify({"status": "error", "error": "Invalid episode key."}), 400
    site_id = _safe_site_id(request.args.get("site_id", ""))
    res = streaming_manager.animeheaven.get_streaming_sources(episode_key, referer_site_id=site_id)
    if not res.get("sources"):
        return jsonify({"status": "error", "error": "Could not resolve MP4 stream"}), 404
    sources = []
    for s in res["sources"]:
        u = s["url"]
        sref = s.get("referer", "https://animeheaven.me/")
        sources.append({
            **s,
            "proxy_url": f"/api/proxy/video?url={quote(u, safe='')}&ref={quote(sref, safe='')}",
            "download_url": f"/api/download/video?url={quote(u, safe='')}&title={quote(request.args.get('title', f'AnimeHeaven_{episode_key[:8]}'), safe='')}&ref={quote(sref, safe='')}",
        })
    return jsonify({"status": "success", "episode_key": episode_key, "sources": sources})


@app.route("/api/heaven/season-pack/<site_id>")
def api_heaven_season_pack(site_id: str):
    """Resolves direct MP4 download links for episodes in an AnimeHeaven season/series."""
    site_id = _safe_site_id(site_id) or ""
    if not site_id:
        return jsonify({"status": "error", "error": "Invalid id."}), 400
    info = streaming_manager.animeheaven.get_anime_info(site_id)
    if not info:
        return jsonify({"status": "error", "error": "Show not found"}), 404

    limit = min(int(request.args.get("limit", 12)), 25)
    episodes = info.get("episodes", [])[:limit]
    resolved_pack = []
    for ep in episodes:
        st = streaming_manager.animeheaven.get_streaming_sources(ep["key"], referer_site_id=site_id)
        primary = (st.get("sources") or [None])[0]
        if primary:
            ep_title = f"{info['title']} - Episode {ep['num']}"
            pref = primary.get("referer", "https://animeheaven.me/")
            resolved_pack.append({
                "num": ep["num"],
                "key": ep["key"],
                "raw_mp4": primary["url"],
                "stream_url": f"/api/proxy/video?url={quote(primary['url'], safe='')}&ref={quote(pref, safe='')}",
                "download_url": f"/api/download/video?url={quote(primary['url'], safe='')}&title={quote(ep_title, safe='')}&ref={quote(pref, safe='')}",
            })
    return jsonify({
        "status": "success",
        "site_id": site_id,
        "title": info["title"],
        "total_episodes": info["total_episodes"],
        "resolved_count": len(resolved_pack),
        "episodes": resolved_pack,
    })


def _media_host_allowed(host: str) -> bool:
    """Optional allowlist for owned/licensed media hosts.

    Set CAMANIME_MEDIA_HOSTS="cdn.example.com,files.example.com" to restrict
    /api/proxy/* and /api/download/video to hosts you own or are licensed to
    distribute. When unset (default), the SSRF guard below still applies but no
    allowlist is enforced."""
    raw = (os.environ.get("CAMANIME_MEDIA_HOSTS") or "").strip()
    if not raw:
        return True
    allowed = {h.strip().lower() for h in raw.split(",") if h.strip()}
    return (host or "").lower() in allowed


_SAFE_ID_RE = re.compile(r"^[A-Za-z0-9_\-\.]{1,80}$")


def _safe_site_id(value) -> Optional[str]:
    """Allowlist for provider ids/keys used in upstream URLs and DB lookups."""
    v = (value or "").strip()
    if not v or len(v) > 80 or not _SAFE_ID_RE.match(v):
        return None
    return v


def _safe_next_url(value) -> str:
    """Login `next` must be a same-site path, never an absolute/external URL."""
    v = (value or "/").strip()
    if not v.startswith("/") or v.startswith("//") or "\\" in v:
        return "/"
    if any(c in v for c in ("\n", "\r", "\x00")):
        return "/"
    return v[:512]


def _fallback_card(anime_id: int) -> Dict:
    """Minimal card used when AniList metadata is temporarily unavailable.

    Prefers the server-side anime_cache (real titles from when AniList was
    reachable) so details/watch pages keep working during an outage."""
    meta = {}
    try:
        meta = (platform.get_anime_meta([anime_id]) or {}).get(int(anime_id), {})
    except Exception:
        meta = {}
    title = (meta.get("title") or f"Anime #{anime_id}").strip() or f"Anime #{anime_id}"
    image = meta.get("image") or "/static/brand/camanime-icon.svg"
    return {
        "id": anime_id,
        "mal_id": None,
        "title": title,
        "title_romaji": title,
        "title_native": "",
        "description": "Metadata is temporarily unavailable (upstream AniList API is down). Episode servers below are still live — try them directly.",
        "image": image,
        "banner": meta.get("banner") or image,
        "color": "#f59e0b",
        "episode": meta.get("episode_label") or "EPS ?",
        "latest_ep": None,
        "total_episodes": None,
        "format": meta.get("format") or "TV",
        "status": (meta.get("status") or "Unknown").replace("_", " ").title() if meta.get("status") else "Unknown",
        "season": "",
        "year": meta.get("year") or "",
        "next_airing_episode": None,
        "airing_hour": "",
        "duration": "",
        "rating": "N/A",
        "score": 0,
        "genres": [],
        "studio": "",
        "trailer_id": None,
    }


def _is_fallback_id(anilist_id) -> bool:
    """True for reserved-range ids minted by fallback providers (no upstream embed)."""
    try:
        return int(anilist_id) >= KITSU_ID_OFFSET
    except (TypeError, ValueError):
        return False


def _working_embed_urls(anilist_id: int, mal_id, ep_num: int):
    """Embed fallbacks that do not depend on AniList or scraper titles.

    vidlink.pro verified reachable (HTTP 200); vidsrc.cc currently times out,
    so VidLink is primary and VidSrc stays only as a secondary mirror.
    Fallback-range ids have no valid upstream embed id; `mid` is None then
    and callers must not use the VidLink URL."""
    mid = mal_id or (anilist_id if not _is_fallback_id(anilist_id) else None)
    return {
        "vidlink_sub": f"https://vidlink.pro/anime/{mid}/{ep_num}/sub",
        "vidlink_dub": f"https://vidlink.pro/anime/{mid}/{ep_num}/dub",
        "vidsrc_sub": f"https://vidsrc.cc/v2/embed/anime/ani{anilist_id}/{ep_num}/sub",
    }


def _safe_upstream_url(url):
    """SSRF guard for the media proxies: allows only public http(s) hosts.

    Blocks credentials in URL, localhost/internal names, and any host that
    resolves to a private, loopback, link-local, multicast, reserved, or
    unspecified IP (incl. cloud metadata endpoints like 169.254.169.254).
    """
    import ipaddress
    import socket
    try:
        from urllib.parse import urlparse as _up
        par = _up((url or "").strip())
        if par.scheme not in ("http", "https") or not par.hostname:
            return None
        if par.username or par.password or "@" in (par.netloc or ""):
            return None
        host = par.hostname.lower()
        if host == "localhost" or host.endswith((".localhost", ".internal", ".local", ".lan")):
            return None
        try:
            infos = socket.getaddrinfo(host, None)
        except Exception:
            return None
        for _fam, _t, _p, _c, sockaddr in infos:
            try:
                ip = ipaddress.ip_address(sockaddr[0])
            except ValueError:
                return None
            if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_reserved or ip.is_unspecified:
                return None
        if not _media_host_allowed(host):
            return None
        return par.geturl()
    except Exception:
        return None


@app.route("/api/proxy/hls")
def proxy_hls():
    """CORS-clean HLS playlist & segment proxy that rewrites M3U8 internal URIs."""
    url = _safe_upstream_url(request.args.get("url", ""))
    ref = request.args.get("ref", "").strip()
    if not url:
        return jsonify({"error": "Invalid or private url"}), 400
    if _is_ad_url(url):
        logger.warning(f"Ad-blocked proxy request: {url}")
        return jsonify({"error": "Blocked: this URL belongs to an ad network. CamAnime is 100%% ad-free."}), 403
    headers = {
        "User-Agent": DEFAULT_UA,
        "Accept": "*/*",
        "Accept-Language": "en-US,en;q=0.9",
    }
    if ref and ref.startswith(("http://", "https://")):
        headers["Referer"] = ref
        parsed_ref = urlparse(ref)
        headers["Origin"] = f"{parsed_ref.scheme}://{parsed_ref.netloc}"
    if request.headers.get("Range"):
        headers["Range"] = request.headers["Range"]

    try:
        upstream = requests.get(
            url, headers=headers, stream=True, timeout=15
        )
        content_type = upstream.headers.get("Content-Type", "")

        is_m3u8 = ".m3u8" in url.lower() or "mpegurl" in content_type.lower()
        if is_m3u8:
            text = upstream.text
            if text.lstrip().startswith("#EXTM3U"):
                rewritten = rewrite_hls_playlist(text, url, ref)
                resp = Response(
                    rewritten,
                    status=upstream.status_code,
                    content_type="application/vnd.apple.mpegurl; charset=utf-8",
                )
                resp.headers["Access-Control-Allow-Origin"] = "*"
                resp.headers["Cache-Control"] = "public, max-age=30"
                return resp

        def generate():
            try:
                for chunk in upstream.iter_content(chunk_size=65536):
                    if chunk:
                        yield chunk
            finally:
                upstream.close()

        resp = Response(
            generate(),
            status=upstream.status_code,
            content_type=content_type or "video/mp2t",
        )
        resp.headers["Access-Control-Allow-Origin"] = "*"
        for h in ("Accept-Ranges", "Content-Range", "Content-Length", "Cache-Control"):
            if h in upstream.headers:
                resp.headers[h] = upstream.headers[h]
        return resp
    except Exception as e:
        logger.error(f"HLS Proxy Error ({url}): {e}")
        return jsonify({"error": str(e)}), 502


@app.route("/api/proxy/video")
def proxy_video():
    """Streams direct MP4 video with full HTTP Range support for instant seeking."""
    url = _safe_upstream_url(request.args.get("url", ""))
    ref = request.args.get("ref", "https://animeheaven.me/").strip()
    if not url:
        return jsonify({"error": "Invalid or private url"}), 400
    if _is_ad_url(url):
        logger.warning(f"Ad-blocked proxy request: {url}")
        return jsonify({"error": "Blocked: this URL belongs to an ad network. CamAnime is 100%% ad-free."}), 403
    # Playback starts are recorded by /api/track. Do not count proxy range
    # requests here: seeking, retries, and HLS reloads are not new streams.

    headers = {
        "User-Agent": DEFAULT_UA,
        "Accept": "*/*",
        "Referer": ref,
    }
    if request.headers.get("Range"):
        headers["Range"] = request.headers["Range"]

    try:
        upstream = requests.get(url, headers=headers, stream=True, timeout=20)
        ctype = (upstream.headers.get("Content-Type", "") or "").lower()
        if upstream.status_code >= 400:
            upstream.close()
            logger.error(f"Video Proxy upstream {upstream.status_code} ({url})")
            return jsonify({"error": f"Stream source returned {upstream.status_code}. Try another server.", "upstream": upstream.status_code}), 502
        if "text/html" in ctype or "application/json" in ctype:
            upstream.close()
            logger.error(f"Video Proxy blocked page, not video ({url}, {ctype})")
            return jsonify({"error": "Stream source returned a block page, not video. Try another server.", "content_type": ctype}), 502

        def generate():
            try:
                # 256 KB chunks keep the pipe full on fast connections without
                # delaying the first frame on slow ones.
                for chunk in upstream.iter_content(chunk_size=262144):
                    if chunk:
                        yield chunk
            finally:
                upstream.close()

        resp = Response(
            generate(),
            status=upstream.status_code,
            content_type=upstream.headers.get("Content-Type", "video/mp4"),
        )
        resp.headers["Access-Control-Allow-Origin"] = "*"
        for h in ("Accept-Ranges", "Content-Range", "Content-Length", "ETag", "Last-Modified"):
            if h in upstream.headers:
                resp.headers[h] = upstream.headers[h]
        if "Accept-Ranges" not in resp.headers:
            resp.headers["Accept-Ranges"] = "bytes"
        return resp
    except Exception as e:
        logger.error(f"Video Proxy Error ({url}): {e}")
        return jsonify({"error": str(e)}), 502


# ─── Turbo download support (parallel segmented transfers) ─────────────────

_pool_lock = None
_SHARED_HTTP = None


def _shared_http_session():
    """One pooled HTTP session for media transfers: keep-alive connections
    cut handshake overhead and raise sustained throughput."""
    global _SHARED_HTTP
    if _SHARED_HTTP is None:
        s = requests.Session()
        adapter = requests.adapters.HTTPAdapter(
            pool_connections=8, pool_maxsize=32, max_retries=2)
        s.mount("https://", adapter)
        s.mount("http://", adapter)
        s.headers.update({"User-Agent": DEFAULT_UA, "Accept": "*/*"})
        _SHARED_HTTP = s
    return _SHARED_HTTP


@app.route("/api/download/probe")
def download_probe():
    """Turbo-download preflight: report size + range support so the client can
    split the file into parallel segments. Cheap HEAD-first, GET fallback."""
    url = _safe_upstream_url(request.args.get("url", ""))
    ref = (request.args.get("ref", "https://animeheaven.me/") or "https://animeheaven.me/").strip()
    if not url:
        return jsonify({"error": "Invalid or private url"}), 400
    if _is_ad_url(url):
        return jsonify({"error": "Blocked: ad network URL."}), 403
    try:
        s = _shared_http_session()
        r = s.head(url, headers={"Referer": ref}, timeout=10, allow_redirects=True)
        size = r.headers.get("Content-Length")
        ranges = (r.headers.get("Accept-Ranges", "") or "").lower()
        ctype = (r.headers.get("Content-Type", "") or "").lower()
        if "text/html" in ctype or "application/json" in ctype:
            return jsonify({"error": "Source returned a block page, not a file."}), 502
        if not size or size == "0" or "bytes" not in ranges:
            # GET-fallback probe: some CDNs lie about HEAD
            r = s.get(url, headers={"Referer": ref, "Range": "bytes=0-0"},
                      timeout=10, stream=True)
            cr = r.headers.get("Content-Range", "")
            size = cr.split("/")[-1] if cr else None
            ranges = "bytes" if cr else ranges
            r.close()
        try:
            size_val = int(size) if size else 0
        except ValueError:
            size_val = 0
        return jsonify({"status": "success", "size": size_val,
                        "ranges": "bytes" in ranges, "content_type": ctype})
    except Exception as e:
        return jsonify({"error": str(e)}), 502


@app.route("/api/download/video")
def download_video():
    """Directly downloads the same file that is streaming (no sign-in).

    MP4 sources save as .mp4; HLS (.m3u8) sources save as .m3u8 so the exact
    playing stream can always be kept from the website."""
    url = _safe_upstream_url(request.args.get("url", ""))
    title = (request.args.get("title", "CamAnime_Episode") or "CamAnime_Episode").strip()
    ref = (request.args.get("ref", "https://animeheaven.me/") or "https://animeheaven.me/").strip()
    if not url:
        return jsonify({"error": "Invalid or private url"}), 400
    if _is_ad_url(url):
        logger.warning(f"Ad-blocked download request: {url}")
        return jsonify({"error": "Blocked: this URL belongs to an ad network. CamAnime is 100%% ad-free."}), 403

    safe_filename = re.sub(r"[^a-zA-Z0-9_\-\. ]", "", title).strip().replace(" ", "_") or "CamAnime_Episode"
    # Live feed + factual homepage counter — cheap, best-effort, never blocks the download.
    _record_activity("download", anime=title[:80], detail=urlparse(url).netloc)
    try:
        platform.bump_counter("downloads")
    except Exception:
        pass
    wants_hls = ".m3u8" in url.lower()
    want_ext = ".m3u8" if wants_hls else ".mp4"
    if not safe_filename.lower().endswith(want_ext):
        base = safe_filename
        if base.lower().endswith(".mp4") or base.lower().endswith(".m3u8"):
            base = base.rsplit(".", 1)[0]
        safe_filename = base + want_ext

    headers = {
        "User-Agent": DEFAULT_UA,
        "Accept": "*/*",
        "Referer": ref,
    }
    # Byte-range passthrough: the watch page's turbo downloader requests one
    # parallel segment per connection in the form ?range=start-end.
    range_arg = (request.args.get("range", "") or "").strip()
    header_range = request.headers.get("Range")
    if header_range:
        headers["Range"] = header_range
    elif range_arg.isdigit() or re.fullmatch(r"\d+-\d*", range_arg):
        s0, _, e0 = range_arg.partition("-")
        headers["Range"] = f"bytes={s0}-" + (e0 if e0 else "")

    try:
        # Pooled keep-alive session + 1 MiB chunks: fewer handshakes and less
        # per-chunk overhead = faster sustained transfer on all hosts.
        upstream = _shared_http_session().get(url, headers=headers, stream=True, timeout=25)
        ctype = (upstream.headers.get("Content-Type", "") or "").lower()
        if upstream.status_code >= 400:
            upstream.close()
            logger.error(f"Video Download upstream {upstream.status_code} ({url})")
            return jsonify({"error": f"Download source returned {upstream.status_code}. The same file failed to stream, so there is nothing to save. Try another server.", "upstream": upstream.status_code}), 502
        if "text/html" in ctype or "application/json" in ctype:
            upstream.close()
            logger.error(f"Video Download blocked page, not video ({url}, {ctype})")
            return jsonify({"error": "Download source returned a block page, not video. The stream itself failed too.", "content_type": ctype}), 502

        def generate():
            try:
                # 1 MiB chunks keep the pipe saturated on fast connections
                # while still yielding regularly for slow clients.
                for chunk in upstream.iter_content(chunk_size=1048576):
                    if chunk:
                        yield chunk
            finally:
                upstream.close()

        out_ctype = "application/vnd.apple.mpegurl" if wants_hls else "video/mp4"
        resp = Response(
            generate(),
            status=upstream.status_code,
            content_type=out_ctype,
        )
        resp.headers["Content-Disposition"] = f'attachment; filename="{safe_filename}"'
        resp.headers["Access-Control-Allow-Origin"] = "*"
        for h in ("Content-Length", "Content-Range", "Accept-Ranges"):
            if h in upstream.headers:
                resp.headers[h] = upstream.headers[h]
        if "Accept-Ranges" not in resp.headers:
            resp.headers["Accept-Ranges"] = "bytes"
        return resp
    except Exception as e:
        logger.error(f"Video Download Error ({url}): {e}")
        return jsonify({"error": str(e)}), 502


@app.route("/api/proxy/subtitle")
def proxy_subtitle():
    """Proxies WebVTT / SRT subtitle tracks with open CORS and automatic SRT->VTT conversion."""
    url = _safe_upstream_url(request.args.get("url", ""))
    ref = request.args.get("ref", "https://megaplay.buzz/").strip()
    if not url:
        return jsonify({"error": "Invalid or private url"}), 400
    if _is_ad_url(url):
        return jsonify({"error": "Blocked: ad network URL."}), 403

    try:
        resp = requests.get(
            url,
            headers={"User-Agent": DEFAULT_UA, "Referer": ref},
            timeout=10,
        )
        text = resp.text
        if not text.lstrip().startswith("WEBVTT"):
            converted = re.sub(r"(\d{2}:\d{2}:\d{2}),(\d{3})", r"\1.\2", text)
            text = f"WEBVTT\n\n{converted}"
        out = Response(text, status=200, content_type="text/vtt; charset=utf-8")
        out.headers["Access-Control-Allow-Origin"] = "*"
        out.headers["Cache-Control"] = "public, max-age=3600"
        return out
    except Exception as e:
        logger.error(f"Subtitle Proxy Error ({url}): {e}")
        return jsonify({"error": str(e)}), 502


@app.after_request
def apply_security_headers(resp):
    resp.headers.setdefault("X-Content-Type-Options", "nosniff")
    resp.headers.setdefault("X-Frame-Options", "SAMEORIGIN")
    resp.headers.setdefault("Referrer-Policy", "strict-origin-when-cross-origin")
    resp.headers.setdefault("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
    resp.headers.setdefault("X-XSS-Protection", "1; mode=block")
    resp.headers.setdefault("Cross-Origin-Opener-Policy", "same-origin")
    resp.headers.setdefault("Cross-Origin-Resource-Policy", "same-site")
    # Only meaningful over HTTPS; browsers ignore HSTS on plain HTTP.
    resp.headers.setdefault(
        "Strict-Transport-Security", "max-age=31536000; includeSubDomains")
    csp = ("default-src 'self' https: data: blob:; " "script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net https://cdnjs.cloudflare.com; " "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com https://cdnjs.cloudflare.com; " "font-src 'self' https://fonts.gstatic.com https://cdnjs.cloudflare.com; " "img-src 'self' https: data: blob:; " "media-src 'self' https: blob: data:; " "frame-src 'self' https:; " "connect-src 'self' https: blob:; " "object-src 'none'; " "base-uri 'self'; " "form-action 'self'; " "frame-ancestors 'self';")
    resp.headers.setdefault("Content-Security-Policy", csp)
    # Private pages must never be cached by a shared proxy or restored from a
    # stale cache after logout. Public pages keep caching for fast navigation.
    if resp.mimetype == "text/html" and any(
            (request.path or "").startswith(p) for p in _AUTHENTICATED_PATHS):
        resp.headers["Cache-Control"] = "private, no-store"
    return resp


def _bearer_token():
    auth = request.headers.get("Authorization", "")
    if auth.lower().startswith("bearer "):
        return auth[7:].strip()
    return (request.args.get("token", "") or "").strip() or None


def _current_user():
    token = _bearer_token()
    if token:
        u = platform.get_user_by_token(token)
        return platform.public_user(u) if u else None
    email = session.get("user_email", "")
    if not email:
        return None
    u = platform.get_user(email)
    return platform.public_user(u) if u else None


def _acting_user(allow_guest=True):
    """Logged-in user or stable guest (no sign-in required for rate/comment/like).

    Guests get a server-stored session id (guest:<hex>) so one browser = one
    rating identity and attributable comments. Name comes from the posted
    `name` field or saved session name, sanitized to 2-24 chars."""
    u = _current_user()
    if u:
        return {**u, "guest": False}
    if not allow_guest:
        return None
    import secrets as _secrets
    gid = session.get("guest_id", "")
    if not gid or len(gid) < 8:
        gid = _secrets.token_hex(8)
        session["guest_id"] = gid
    posted_name = ""
    try:
        posted_name = (_post_data().get("name", "") or "").strip()
    except Exception:
        posted_name = ""
    if posted_name:
        posted_name = posted_name[:24]
        session["guest_name"] = posted_name
    name = posted_name or session.get("guest_name", "") or f"Guest-{gid[:4].upper()}"
    name = str(name).strip()[:24] or f"Guest-{gid[:4].upper()}"
    return {"email": f"guest:{gid}@guests.camanime.local", "name": name,
            "role": "guest", "avatar": "", "guest": True}


def _guest_throttle_ok(key="comment", seconds=8):
    """Simple per-session spam throttle for guest actions."""
    import time as _t
    now = _t.time()
    last = float(session.get(f"guest_last_{key}", 0) or 0)
    if now - last < seconds:
        return False
    session[f"guest_last_{key}"] = now
    return True


def _auth_payload():
    if request.is_json:
        body = request.get_json(silent=True) or {}
        return (body.get("email", ""), body.get("password", ""), body.get("name", ""))
    return (request.form.get("email", ""), request.form.get("password", ""),
            request.form.get("name", ""))


@app.route("/api/auth/register", methods=["POST"])
def api_auth_register():
    email, password, name = _auth_payload()
    try:
        user = platform.register_user(None, email, name or email.split("@")[0], password)
    except Exception as e:
        return jsonify({"status": "error", "error": str(e)}), 400
    tok = platform.issue_token(user["email"])
    return jsonify({"status": "success", "token": tok["token"],
                    "expires": tok["expires"], "user": platform.public_user(user)})


@app.route("/api/auth/login", methods=["POST"])
def api_auth_login():
    email, password, _name = _auth_payload()
    try:
        user = platform.verify_user(None, email, password)
    except Exception as e:
        return jsonify({"status": "error", "error": str(e)}), 401
    tok = platform.issue_token(user["email"])
    return jsonify({"status": "success", "token": tok["token"],
                    "expires": tok["expires"], "user": platform.public_user(user)})


@app.route("/api/auth/me")
def api_auth_me():
    u = _current_user()
    if not u:
        return jsonify({"status": "error", "error": "Not signed in."}), 401
    items = platform.get_notifications(u["email"], limit=20)
    return jsonify({"status": "success", "user": u,
                    "unread": sum(1 for n in items if not n.get("read")),
                    "notifications": items})


@app.route("/api/auth/logout", methods=["POST"])
def api_auth_logout():
    token = _bearer_token()
    if token:
        platform.revoke_token(token)
    session.pop("user_email", None)
    return jsonify({"status": "ok"})


@app.route("/login", methods=["GET", "POST"])
def login_page():
    from flask import session as _s
    error = ""
    mode = request.args.get("mode", "signin")
    if request.method == "POST":
        email = request.form.get("email", "").strip()
        password = request.form.get("password", "")
        name = request.form.get("name", "").strip()
        action = request.form.get("action", "signin")
        try:
            if action == "signup":
                user = platform.register_user(None, email, name or email.split("@")[0], password)
            else:
                user = platform.verify_user(None, email, password)
            _s["user_email"] = user["email"]
            nxt = _safe_next_url(request.args.get("next", "/"))
            return redirect(nxt)
        except Exception as e:
            error = str(e)
    return render_template("login.html", error=error, mode=mode, user=_current_user())


@app.route("/logout")
def logout_page():
    session.pop("user_email", None)
    return redirect(url_for("home"))


@app.route("/admin")
def admin_page():
    u = _current_user()
    if not u or u.get("role") != "admin":
        return redirect(url_for("login_page", mode="admin", next="/admin"))
    stats = platform.admin_stats()
    return render_template("admin.html", user=u, stats=stats, schedule=platform.CLASSICS_SCHEDULE)


@app.route("/schedule")
def schedule_page():
    """Keep the legacy schedule URL, but show the shared homepage drawer only."""
    return redirect(url_for("home", schedule="open"))


@app.route("/promo")
def promo_page():
    return render_template("promo.html", user=_current_user())


@app.route("/settings")
def settings_page():
    return render_template("settings.html", user=_current_user())


def _app_file_info(filename: str):
    import datetime
    path = os.path.join(app.static_folder or "static", "downloads", filename)
    if not os.path.isfile(path):
        return None
    st = os.stat(path)
    size_mb = st.st_size / (1024 * 1024)
    size = f"{size_mb:.1f} MB" if size_mb >= 1 else f"{st.st_size // 1024} KB"
    return {"url": f"/static/downloads/{filename}",
            "name": filename, "size": size,
            "updated": datetime.datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%d")}


@app.route("/download")
def download_page():
    apk = _app_file_info("CamAnime.apk")
    winapp = _app_file_info("CamAnime-Windows.zip") or _app_file_info("CamAnime.exe")
    return render_template("download.html", user=_current_user(), apk=apk, winapp=winapp)


RELEASE_TAG = os.environ.get("CAMANIME_RELEASE_TAG", "v1.2.0")
RELEASE_DL = "https://github.com/kayefande-droid/CamAnime/releases/download"
APP_VERSION = "1.2.0"  # keep aligned with mobile/camanime_app/pubspec.yaml


def _serve_app_file(local_names, release_name, download_name):
    """One-click app download: serves the bundled file if present, else
    redirects straight to the GitHub Release asset (starts downloading
    immediately via Content-Disposition: attachment)."""
    for fn in local_names:
        path = os.path.join(app.static_folder or "static", "downloads", fn)
        if os.path.isfile(path):
            return send_file(path, as_attachment=True, download_name=download_name)
    return redirect(f"{RELEASE_DL}/{RELEASE_TAG}/{release_name}", code=302)


@app.route("/get/android")
def get_android():
    try:
        platform.bump_counter("app_downloads")
    except Exception:
        pass
    return _serve_app_file(["CamAnime.apk"], "CamAnime.apk", "CamAnime.apk")


@app.route("/get/windows")
def get_windows():
    try:
        platform.bump_counter("app_downloads")
    except Exception:
        pass
    return _serve_app_file(["CamAnime-Windows.zip", "CamAnime.exe"],
                           "CamAnime-Windows.zip", "CamAnime-Windows.zip")


def _post_data():
    """Merges JSON body over form fields so website (FormData) and native
    apps (JSON) use the same endpoints."""
    data = {}
    try:
        j = request.get_json(silent=True)
        if isinstance(j, dict):
            data.update({str(k): v for k, v in j.items()})
    except Exception:
        pass
    for k in request.form:
        data.setdefault(k, request.form.get(k))
    return data


@app.route("/api/community/comments")
def api_comments():
    anime_id = request.args.get("anime_id", "")
    ep = request.args.get("ep", "")
    items = platform.get_comments(anime_id, ep=ep, limit=100)
    return jsonify({"status": "success", "comments": items, "stickers": platform.CAM_STICKERS})


@app.route("/api/community/comment", methods=["POST"])
def api_comment_post():
    d = _post_data()
    if not (d.get("anime_id", "") or "").strip():
        return jsonify({"status": "error", "error": "anime_id is required."}), 400
    u = _acting_user(allow_guest=True)
    if u.get("guest") and not _guest_throttle_ok("comment", 8):
        return jsonify({"status": "error", "error": "Slow down — wait a few seconds before posting again."}), 429
    try:
        c = platform.add_comment(None, d.get("anime_id", ""), d.get("ep", ""), {**u, "email": u["email"]}, d.get("text", ""), d.get("parent", ""), d.get("sticker", ""))
        return jsonify({"status": "success", "comment": c, "guest": bool(u.get("guest"))})
    except Exception as e:
        return jsonify({"status": "error", "error": str(e)}), 400


@app.route("/api/community/like/<cid>", methods=["POST"])
def api_comment_like(cid):
    u = _acting_user(allow_guest=True)
    try:
        c = platform.like_comment(None, cid, u["email"])
        return jsonify({"status": "success", "likes": c["likes"]})
    except Exception as e:
        return jsonify({"status": "error", "error": str(e)}), 404


@app.route("/api/community/rate", methods=["POST"])
def api_rate():
    d = _post_data()
    try:
        score = int(d.get("score", 8))
    except Exception:
        return jsonify({"status": "error", "error": "Score must be 1-10."}), 400
    if score < 1 or score > 10:
        return jsonify({"status": "error", "error": "Score must be 1-10."}), 400
    if not (d.get("anime_id", "") or "").strip():
        return jsonify({"status": "error", "error": "anime_id is required."}), 400
    u = _acting_user(allow_guest=True)
    if u.get("guest") and not _guest_throttle_ok("rate", 5):
        return jsonify({"status": "error", "error": "Slow down — wait a few seconds before rating again."}), 429
    r = platform.rate_anime(None, _post_data().get("anime_id", ""), u["email"], score)
    return jsonify({"status": "success", "rating": r, "guest": bool(u.get("guest"))})


@app.route("/api/community/notifications")
def api_notifications():
    u = _current_user()
    if not u:
        return jsonify({"status": "error", "notifications": []}), 401
    items = platform.get_notifications(u["email"], limit=20)
    unread = sum(1 for n in items if not n.get("read"))
    return jsonify({"status": "success", "notifications": items, "unread": unread})


@app.route("/api/track", methods=["POST"])
def api_track():
    d = _post_data()
    kind = (d.get("kind", "click") or "click").strip().lower()
    anime_id = str(d.get("anime_id", "") or "").strip()
    ep = str(d.get("ep", "") or "").strip()
    meta = {"anime_id": anime_id, "ep": ep}
    platform.track(None, kind, meta)
    if kind == "play":
        detail = f"Anime {anime_id}" if anime_id else "Player start"
        if ep:
            detail += f" · Episode {ep}"
        _record_activity("stream", anime=detail, ep=ep, detail=detail)
    return jsonify({"status": "ok"})


# ─── Cross-device account sync: server-side watch history + watchlist ────────
# One account = one continue-watching list everywhere (website, Android, Windows).
# Guests keep localStorage-only behaviour; signed-in users get true device sync.

@app.route("/api/history", methods=["GET"])
def api_history_get():
    u = _current_user()
    if not u:
        return jsonify({"status": "error", "error": "Sign in to sync your watch history across devices."}), 401
    return jsonify({"status": "success", "synced": True, "history": platform.get_history(u["email"], limit=int(request.args.get("limit", 30)))})


@app.route("/api/history", methods=["POST"])
def api_history_upsert():
    u = _current_user()
    if not u or u.get("guest"):
        return jsonify({"status": "error", "error": "Sign in to sync your watch history across devices."}), 401
    d = _post_data()
    try:
        row = platform.upsert_history(
            u["email"], d.get("anime_id"), int(d.get("ep", 1) or 1),
            float(d.get("position", 0) or 0), float(d.get("duration", 0) or 0),
            d.get("title", ""), d.get("image", ""))
        return jsonify({"status": "success", "row": row})
    except Exception as e:
        return jsonify({"status": "error", "error": str(e)}), 400


@app.route("/api/history/remove", methods=["POST"])
def api_history_remove():
    u = _current_user()
    if not u or u.get("guest"):
        return jsonify({"status": "error", "error": "Sign in first."}), 401
    d = _post_data()
    platform.remove_history(u["email"], d.get("anime_id"))
    return jsonify({"status": "success"})


# ─── Home page data: factual counters + real most-watched ranking ───────────

@app.route("/api/public/counters")
def api_public_counters():
    """Expose cumulative player starts and other real SQLite-backed counts.

    Proxy requests are intentionally excluded: seeking and retries are not new plays.
    """
    c = platform.get_counters()
    return jsonify({
        "status": "success",
        "app_downloads": c.get("app_downloads", 0),
        # `plays` increments once when the player starts; proxy requests may retry.
        "streams": c.get("plays", 0),
        "downloads": c.get("downloads", 0),
        "users": platform.get_user_count(),
        "source": "real events only",
    })


# ─── Versioned shared catalogue API ─────────────────────────────────────────
# Website templates and the Flutter app share the same AniList-backed
# normalization (format_anime_card); this API is the native client's contract.
# Contract documentation: README.md, "Versioned catalogue API" section.
CATALOG_FORMATS = {"TV", "TV_SHORT", "MOVIE", "OVA", "ONA", "SPECIAL"}
CATALOG_SORTS = {
    "popular": "POPULARITY_DESC",
    "trending": "TRENDING_DESC",
    "rating": "SCORE_DESC",
    "recent": "ID_DESC",
    "alphabetical": "TITLE_ROMAJI",
}


def _catalog_error(message: str, status: int):
    return jsonify({"status": "error", "error": {"message": message}}), status


def _catalog_media(data: Dict) -> List[Dict]:
    return [format_anime_card(item) for item in (data.get("Page", {}).get("media") or []) if item]


@app.route("/api/v1/health")
def api_v1_health():
    return jsonify({"status": "ok", "api_version": "v1", "catalog_source": "AniList",
                    "catalog_fallback": "Kitsu, then Jikan (MyAnimeList) when AniList is unreachable",
                    "persistence": "SQLite for user/community records; catalogue metadata is provider-cached"})


@app.route("/api/v1/schedule")
def api_v1_schedule():
    global _SCHEDULE_API_REQUESTS
    with _SCHEDULE_METRICS_LOCK:
        _SCHEDULE_API_REQUESTS += 1
    season, year = current_anime_season()
    schedule = get_current_season_schedule()
    with _SCHEDULE_METRICS_LOCK:
        api_requests = _SCHEDULE_API_REQUESTS
        cache_misses = _SCHEDULE_CACHE_MISSES
    response = jsonify({
        "status": "success", "season": {"name": season, "year": year},
        "items": schedule,
        "playback_available": False,
        "availability_note": "Matched outbound official-provider metadata is only a listing, not confirmation the episode is playable; CamAnime does not host or embed these episodes.",
    })
    response.headers["Cache-Control"] = "public, max-age=900, stale-while-revalidate=300"
    response.headers["Access-Control-Expose-Headers"] = (
        "X-Schedule-Api-Requests, X-Schedule-Cache-Misses, X-Schedule-Worker-Uptime"
    )
    # Per-worker cumulative counters sampled by the scheduled production smoke
    # workflow. They reset on process restart/deploy; uptime lets that be detected.
    response.headers["X-Schedule-Api-Requests"] = str(api_requests)
    response.headers["X-Schedule-Cache-Misses"] = str(cache_misses)
    response.headers["X-Schedule-Worker-Uptime"] = str(max(0, int(time.time() - _SCHEDULE_PROCESS_STARTED_AT)))
    return response


@app.route("/api/v1/catalog/home")
def api_v1_catalog_home():
    data = fetch_anilist(HOME_DASHBOARD_QUERY)
    if not data:
        fb_lists, fb_source = _fallback_home_lists()
        if fb_lists:
            cards = {
                "trending": [format_anime_card(a) for a in fb_lists.get("trending", [])],
                "popular": [format_anime_card(a) for a in fb_lists.get("popular", [])],
                "ongoing": [format_anime_card(a) for a in fb_lists.get("ongoing", [])],
                "top_rated": [format_anime_card(a) for a in fb_lists.get("top_rated", [])],
                "recently_added": [format_anime_card(a) for a in fb_lists.get("recent", [])],
                "movies": [format_anime_card(a) for a in fb_lists.get("movies", [])],
                "series": [format_anime_card(a) for a in fb_lists.get("trending", [])],
            }
            cards["featured"] = (cards["trending"] or [None])[0]
            response = jsonify({"status": "success",
                                "catalog_source": _FALLBACK_API_NAMES.get(fb_source, fb_source),
                                "catalog": cards})
            response.headers["Cache-Control"] = "public, max-age=300, stale-while-revalidate=600"
            return response
        return _catalog_error("Catalogue provider is temporarily unavailable.", 503)
    cards = {
        "trending": [format_anime_card(a) for a in (data.get("trending", {}).get("media") or []) if a],
        "popular": [format_anime_card(a) for a in (data.get("popularSeason", {}).get("media") or []) if a],
        "top_rated": [format_anime_card(a) for a in (data.get("topRated", {}).get("media") or []) if a],
        "recently_added": [format_anime_card(a) for a in (data.get("recentlyAdded", {}).get("media") or []) if a],
        "movies": [format_anime_card(a) for a in (data.get("featuredMovie", {}).get("media") or []) if a],
        "series": [format_anime_card(a) for a in (data.get("series", {}).get("media") or []) if a],
    }
    cards["featured"] = (cards["trending"] or cards["popular"] or [None])[0]
    response = jsonify({"status": "success", "catalog_source": "AniList", "catalog": cards})
    response.headers["Cache-Control"] = "public, max-age=300, stale-while-revalidate=600"
    return response


@app.route("/api/v1/anime")
def api_v1_anime_list(genre_override: Optional[str] = None):
    query = (request.args.get("q") or request.args.get("search") or "").strip()
    genre = genre_override or request.args.get("genre", "").strip()
    media_format = request.args.get("format", "").strip().upper()
    sort_key = request.args.get("sort", "popular").strip().lower()
    page = request.args.get("page", default=1, type=int)
    limit = request.args.get("limit", default=24, type=int)
    if len(query) > 100:
        return _catalog_error("Search query must be 100 characters or fewer.", 400)
    if genre and genre not in POPULAR_GENRES:
        return _catalog_error("Unsupported genre filter.", 400)
    if media_format and media_format not in CATALOG_FORMATS:
        return _catalog_error("Unsupported media format.", 400)
    if sort_key not in CATALOG_SORTS:
        return _catalog_error("Unsupported sort order.", 400)
    if page < 1 or page > 10000 or limit < 1 or limit > 50:
        return _catalog_error("Page must be positive and limit must be between 1 and 50.", 400)
    year_before = request.args.get("year_before", type=int)
    if year_before is not None and (year_before < 1900 or year_before > 2100):
        return _catalog_error("year_before must be between 1900 and 2100.", 400)
    variables = {"page": page, "perPage": limit, "sort": [CATALOG_SORTS[sort_key]]}
    if year_before is not None:
        # FuzzyDateInt: end of the requested year, so the filter is inclusive.
        variables["startDateBefore"] = (year_before * 10000) + 1231
    if query:
        variables["search"] = query
    if genre:
        variables["genre"] = genre
    if media_format:
        variables["format"] = media_format
    data = fetch_anilist(SEARCH_FILTER_QUERY, variables)
    if not data:
        # AniList down: free fallback providers (genre via Kitsu categories,
        # text queries via Kitsu then Jikan). Unfiltered browses stay 503
        # rather than dumping an unsorted list under a sorted contract.
        fb_results, fb_source = [], ""
        if query and not genre and not media_format:
            fb_media, fb_source = _fallback_search_media(query, limit=limit)
            fb_results = [format_anime_card(a) for a in fb_media]
        elif genre and not query and not media_format:
            slug = KITSU_GENRE_SLUG_MAP.get(genre.lower())
            # Kitsu caps page[limit] at 20; asking for more is a hard 400.
            items = _kitsu_get("/anime", {"filter[categories]": slug,
                                           "sort": "-userCount",
                                           "page[limit]": min(limit, 20)}) if slug else []
            if items:
                fb_results = [format_anime_card(_kitsu_to_media(i)) for i in items]
                fb_source = "kitsu"
        if fb_results:
            result = jsonify({"status": "success",
                              "catalog_source": _FALLBACK_API_NAMES.get(fb_source, fb_source),
                              "results": fb_results, "page": page, "limit": limit})
            result.headers["Cache-Control"] = "public, max-age=120, stale-while-revalidate=300"
            return result
        return _catalog_error("Catalogue provider is temporarily unavailable.", 503)
    result = jsonify({"status": "success", "catalog_source": "AniList",
                      "results": _catalog_media(data), "page": page, "limit": limit})
    result.headers["Cache-Control"] = "public, max-age=120, stale-while-revalidate=300"
    return result


@app.route("/api/v1/search")
def api_v1_search():
    if not (request.args.get("q") or "").strip():
        return _catalog_error("A non-empty q parameter is required.", 400)
    return api_v1_anime_list()


@app.route("/api/v1/genres")
def api_v1_genres():
    return jsonify({"status": "success", "genres": POPULAR_GENRES})


@app.route("/api/v1/genres/<slug>/anime")
def api_v1_genre_anime(slug: str):
    genre = next((g for g in POPULAR_GENRES if g.lower().replace(" ", "-") == slug.lower()), None)
    if not genre:
        return _catalog_error("Genre not found.", 404)
    # Route through the same validated, paginated catalogue query.
    return api_v1_anime_list(genre_override=genre)


def _anime_metadata(anime_id: int):
    data = fetch_anilist(DETAILS_QUERY, {"id": anime_id})
    raw = data.get("Media") if data else None
    source = "AniList"
    if not raw:
        if _is_fallback_id(anime_id):
            raw, _src = _fallback_media_by_reserved_id(anime_id)
            source = _FALLBACK_API_NAMES.get(_src, _src) if raw else source
        if not raw:
            try:
                _meta = (platform.get_anime_meta([anime_id]) or {}).get(int(anime_id), {})
                _t = (_meta.get("title") or "").strip()
            except Exception:
                _t = ""
            if _t and not _t.startswith("Anime #"):
                raw, _src = _fallback_media_by_title(_t)
                source = _FALLBACK_API_NAMES.get(_src, _src) if raw else source
        if not raw:
            return None
    card = format_anime_card(raw)
    count = raw.get("episodes") if isinstance(raw.get("episodes"), int) else None
    # Shows still airing report a null `episodes`; derive the real count from
    # the next airing episode so the app never shows a guessed "12 episodes".
    next_airing = raw.get("nextAiringEpisode") or {}
    next_ep_num = next_airing.get("episode") if isinstance(next_airing, dict) else None
    if isinstance(next_ep_num, int) and next_ep_num > 1:
        count = max(count or 0, next_ep_num - 1)
    known_streaming = raw.get("streamingEpisodes") or []
    relations = []
    for edge in ((raw.get("relations") or {}).get("edges") or []):
        node = edge.get("node") or {}
        if node.get("type") == "ANIME" and node.get("id"):
            relations.append({
                **format_anime_card(node),
                "relation": (edge.get("relationType") or "RELATED").replace("_", " "),
                "episode_count": node.get("episodes"),
            })
    relations.sort(key=lambda item: (item.get("year") or 0, item.get("id") or 0))
    return {"id": raw.get("id"), "mal_id": raw.get("idMal"), **card,
            "title_alternates": [t for t in ((raw.get("title") or {}).get("english"),
                                               (raw.get("title") or {}).get("romaji"),
                                               (raw.get("title") or {}).get("native")) if t],
            "seasons": relations,
            "season_count": len(relations),
            "episode_count": count,
            "next_airing_episode": next_ep_num,
            "streaming_metadata_count": len(known_streaming),
            "streaming_metadata_available": bool(known_streaming),
            "streaming_metadata": [{"title": x.get("title", ""),
                                    "thumbnail": x.get("thumbnail", ""),
                                    "provider": x.get("site", "")}
                                   for x in known_streaming if x],
            "catalog_source": source}


@app.route("/api/v1/anime/<int:anime_id>")
def api_v1_anime_detail(anime_id: int):
    if anime_id <= 0:
        return _catalog_error("Anime ID must be positive.", 400)
    anime = _anime_metadata(anime_id)
    if anime is None:
        return _catalog_error("Anime not found.", 404)
    response = jsonify({"status": "success", "anime": anime})
    response.headers["Cache-Control"] = "public, max-age=600, stale-while-revalidate=1800"
    return response


@app.route("/api/v1/anime/<int:anime_id>/episodes")
def api_v1_anime_episodes(anime_id: int):
    data = fetch_anilist(DETAILS_QUERY, {"id": anime_id})
    raw = (data.get("Media") or {}) if data else {}
    if not raw:
        # Fallback providers carry no per-episode preview metadata: report an
        # honest empty manifest instead of a 404 for a show that may exist.
        anime = _anime_metadata(anime_id)
        if anime is not None:
            return jsonify({"status": "success", "anime_id": anime_id, "episodes": [],
                            "known_count": 0, "page": 1, "limit": 50,
                            "has_more": False, "playback_available": False,
                            "download_available": False,
                            "catalog_source": anime.get("catalog_source", "")})
        return _catalog_error("Anime not found.", 404)
    page = request.args.get("page", default=1, type=int)
    limit = request.args.get("limit", default=50, type=int)
    if page < 1 or limit < 1 or limit > 100:
        return _catalog_error("Page must be positive and limit must be between 1 and 100.", 400)
    # AniList supplies episode preview metadata, not a complete authorized source
    # manifest. Only expose this endpoint when the metadata exists; it must never
    # claim playback rights or fabricate missing episode rows.
    episodes = []
    for item in raw.get("streamingEpisodes") or []:
        if not item:
            continue
        episodes.append({"title": item.get("title", ""),
                         "thumbnail": item.get("thumbnail", ""),
                         "provider": item.get("site", ""),
                         "metadata_url": item.get("url", ""),
                         "playable": False, "download_allowed": False})
    start = (page - 1) * limit
    rows = episodes[start:start + limit]
    return jsonify({"status": "success", "anime_id": anime_id, "episodes": rows,
                    "known_count": len(episodes), "page": page, "limit": limit,
                    "has_more": start + limit < len(episodes),
                    "playback_available": False, "download_available": False})


@app.route("/api/public/anime/<int:anime_id>")
def api_public_anime(anime_id: int):
    """Public streaming API for the native apps."""
    data = fetch_anilist(DETAILS_QUERY, {"id": anime_id})
    raw = data.get("Media") or {}
    titles = [raw.get("title", {}).get("english"), raw.get("title", {}).get("romaji")] if raw.get("title") else []
    bundle = streaming_manager.get_full_episode_bundle(anime_id, int(request.args.get("ep", 1)), [t for t in titles if t], mal_id=raw.get("idMal"))
    return jsonify({"status": "success", "anime_id": anime_id, "title": (titles[0] if titles else ""), "servers": bundle.get("servers", []), "downloads_require_login": True, "rating": platform.anime_rating(None, anime_id)})


@app.route("/api/public/stream/download", methods=["POST"])
def api_public_stream_or_download():
    """Users + apps can register a real stream/download (no auth) purely for the
    factual homepage counters. Never used for payments or private data."""
    d = _post_data()
    kind = (d.get("kind", "stream") or "stream").lower()
    if kind not in ("stream", "download"):
        kind = "stream"
    anime_id = (d.get("anime_id", "") or "").strip()
    title = (d.get("title", "") or "").strip()
    image = (d.get("image", "") or "").strip()
    event_kind = "play" if kind == "stream" else "download"
    meta = {"anime_id": anime_id, "ep": d.get("ep", "")}
    platform.track({}, event_kind, meta)
    if kind == "stream":
        detail = f"{title or f'Anime {anime_id}'}" if anime_id else "Player start"
        if meta["ep"]:
            detail += f" · Episode {meta['ep']}"
        _record_activity("stream", anime=detail, ep=meta["ep"], detail=detail)
    if anime_id and title:
        platform.cache_anime_meta(anime_id, title=title, image=image,
                                  episode_label=f"EP {meta['ep']}" if meta["ep"] else "")
    return jsonify({"status": "ok"})


@app.route("/api/version")
def api_version():
    """Update-check endpoint for native apps: current release + direct links."""
    return jsonify({"status": "success", "app_version": APP_VERSION,
                    "apk": "CamAnime.apk", "windows": "CamAnime-Windows.zip",
                    "apk_url": "/get/android", "windows_url": "/get/windows"})


@app.route("/api/announcements")
def api_announcements():
    """CEO announcements feed for website banner + native apps."""
    return jsonify({"status": "success",
                    "announcements": platform.list_announcements(10)})


@app.route("/api/public/most-viewed")
def api_public_most_viewed():
    """Most-watched ranking per Day / Week / Month / Year, from real play events.

    Only anime actually played on CamAnime appear in each window."""
    import time as _t
    now = int(_t.time())
    windows = {"day": 86400, "week": 7 * 86400, "month": 30 * 86400, "year": 365 * 86400}
    key = request.args.get("window", "day").lower()
    if key == "all":
        since = 0
    else:
        since = now - windows.get(key, windows["day"])
    rows = platform.most_watched(since, limit=12)
    return jsonify({"status": "success", "window": key, "items": rows})


@app.route("/api/admin/announce", methods=["POST"])
def api_admin_announce():
    u = _current_user()
    if not u or u.get("role") != "admin":
        return jsonify({"status": "error", "error": "Admin only."}), 403
    d = _post_data()
    try:
        a = platform.post_announcement(d.get("title", ""), d.get("body", ""), u.get("name") or u.get("email"))
        return jsonify({"status": "success", "announcement": a})
    except Exception as e:
        return jsonify({"status": "error", "error": str(e)}), 400


def _require_admin():
    """Admin-only guard shared by web + native app (session or Bearer token)."""
    u = _current_user()
    if not u or u.get("role") != "admin":
        return None
    return u


@app.route("/api/admin/sync")
def api_admin_sync():
    """Synced admin/secret status for apps + tools. Admin only."""
    u = _require_admin()
    if not u:
        return jsonify({"status": "error", "error": "Admin only. Sign in as admin."}), 403
    import os as _os
    secret_set = bool(_os.environ.get("CAMANIME_SECRET"))
    return jsonify({
        "status": "success",
        "admin_email": u["email"],
        "default_admin_email": platform.DEFAULT_ADMIN_EMAIL,
        "env_admin_email": _os.environ.get("CAMANIME_ADMIN_EMAIL") or "",
        "secret_configured": secret_set,
        "db_path": platform.DB_PATH,
        "app_version": APP_VERSION,
        "apk_url": "/get/android",
        "windows_url": "/get/windows",
        "message": "OK - app and website share this admin + secret." if secret_set else "CAMANIME_SECRET is not set; sessions reset on restart.",
    })


@app.route("/api/admin/password", methods=["POST"])
def api_admin_password():
    """Change own admin password (needs current pw) or reset another user (admin only).

    Body: {current_password, new_password} for self-change, or
    {target_email, new_password} for an admin reset. Website form + app JSON both work."""
    u = _require_admin()
    if not u:
        return jsonify({"status": "error", "error": "Admin only."}), 403
    d = _post_data()
    try:
        target = (d.get("target_email") or "").strip().lower()
        new_pw = d.get("new_password") or ""
        if target and target != u["email"].lower():
            platform.admin_reset_password(target, new_pw)
            return jsonify({"status": "success", "reset_for": target})
        platform.change_own_password(u["email"], d.get("current_password") or "", new_pw)
        return jsonify({"status": "success", "changed_for": u["email"]})
    except Exception as e:
        return jsonify({"status": "error", "error": str(e)}), 400


@app.route("/api/admin/live-activity")
def api_admin_live_activity():
    """Live streams, downloads and online users for the admin panel.

    Logged-in requests show the account; anonymous traffic is reported as
    `guest`. Data is in-memory and ephemeral by design — this is a live feed,
    not an audit log."""
    u = _require_admin()
    if not u:
        return jsonify({"status": "error", "error": "Admin only. Sign in as admin."}), 403
    data = _live_activity_summary()
    for row in data["activity"]:
        row["kind_label"] = _KIND_LABELS.get(row["kind"], row["kind"].title())
    return jsonify({"status": "success", **data})


@app.route("/api/admin/create-admin", methods=["POST"])
def api_admin_create():
    """Create an extra admin. Admin only."""
    u = _require_admin()
    if not u:
        return jsonify({"status": "error", "error": "Admin only."}), 403
    d = _post_data()
    try:
        created = platform.create_admin_user(d.get("email", ""), d.get("name", ""), d.get("password", ""))
        return jsonify({"status": "success", "admin": platform.public_user(created)})
    except Exception as e:
        return jsonify({"status": "error", "error": str(e)}), 400


@app.route("/sitemap.xml")
def sitemap():
    """SEO sitemap: static pages + every anime page we have metadata for
    (from the anime_cache table), each with real lastmod timestamps."""
    base = request.host_url.rstrip("/")
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    entries = [
        ("/", 1.0, "daily", now),
        ("/scraper", 0.9, "hourly", now),
        ("/schedule", 0.8, "weekly", now),
        ("/download", 0.8, "weekly", now),
        ("/promo", 0.7, "monthly", now),
    ]
    try:
        import sqlite3 as _sq
        with platform._db() as conn:
            rows = conn.execute(
                "SELECT id, t FROM anime_cache ORDER BY t DESC LIMIT 2000").fetchall()
        for r in rows:
            last = datetime.fromtimestamp(r["t"], timezone.utc).strftime("%Y-%m-%d")
            entries.append((f"/anime/{r['id']}", 0.7, "weekly", last))
    except Exception:
        pass
    xml = ("<?xml version='1.0' encoding='UTF-8'?>"
           "<urlset xmlns='http://www.sitemaps.org/schemas/sitemap/0.9'>")
    for path, prio, freq, lastmod in entries:
        xml += (f"<url><loc>{base}{path}</loc>"
                f"<lastmod>{lastmod}</lastmod>"
                f"<changefreq>{freq}</changefreq>"
                f"<priority>{prio}</priority></url>")
    xml += "</urlset>"
    resp = Response(xml, mimetype="application/xml")
    resp.headers["Cache-Control"] = "public, max-age=1800"
    return resp


@app.route("/robots.txt")
def robots():
    return Response("User-agent: *\nAllow: /\nSitemap: " + request.host_url.rstrip("/") + "/sitemap.xml\n", mimetype="text/plain")


@app.route("/google78cbf317abe48f6e.html")
def google_verify():
    return app.send_static_file("google78cbf317abe48f6e.html")


@app.route("/healthz")
def healthz():
    """Render health check: no DB, no upstream calls — cheap and log-quiet."""
    return jsonify({"status": "ok", "version": APP_VERSION if "APP_VERSION" in globals() else "1.2.0"}), 200


if __name__ == "__main__":
    app.run(debug=False, host="0.0.0.0", port=3000)
