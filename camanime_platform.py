"""CamAnime platform layer: auth (hashed), community, ratings, analytics, schedule.

SQLite-free JSON store so it runs on any host without migrations.
Passwords use PBKDF2-HMAC-SHA256 (werkzeug). Admin seeded via env.
"""
import hashlib
import json
import os
import secrets
import time
from typing import Dict, List

from werkzeug.security import check_password_hash, generate_password_hash

STORE_PATH = os.environ.get("CAMANIME_STORE", "camanime_store.json")
ADMIN_EMAIL = os.environ.get("CAMANIME_ADMIN_EMAIL", "admin@camanime.local")
ADMIN_PASSWORD = os.environ.get("CAMANIME_ADMIN_PASSWORD", "CamAnime-Admin-2026!")

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


def _default_store() -> Dict:
    return {
        "users": {},
        "comments": [],
        "ratings": [],
        "notifications": [],
        "events": [],
        "app_downloads": 12840,
        "counters": {"site_clicks": 0, "plays": 0},
    }


def load_store() -> Dict:
    try:
        if os.path.exists(STORE_PATH):
            with open(STORE_PATH, "r", encoding="utf-8") as f:
                data = json.load(f)
            for k, v in _default_store().items():
                data.setdefault(k, v)
            return data
    except Exception:
        pass
    return _default_store()


def save_store(data: Dict) -> None:
    tmp = STORE_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    os.replace(tmp, STORE_PATH)


def ensure_admin(data: Dict) -> Dict:
    admin = data["users"].get(ADMIN_EMAIL.lower())
    if not admin:
        data["users"][ADMIN_EMAIL.lower()] = {
            "email": ADMIN_EMAIL.lower(),
            "name": "Kayefande (Admin)",
            "pw": generate_password_hash(ADMIN_PASSWORD),
            "role": "admin",
            "avatar": "",
            "created": int(time.time()),
            "token": secrets.token_hex(16),
        }
        save_store(data)
    return data["users"][ADMIN_EMAIL.lower()]


def register_user(data: Dict, email: str, name: str, password: str) -> Dict:
    key = email.strip().lower()
    if key in data["users"]:
        raise ValueError("Account already exists. Please sign in.")
    user = {
        "email": key,
        "name": name.strip() or key.split("@")[0],
        "pw": generate_password_hash(password),
        "role": "user",
        "avatar": "",
        "created": int(time.time()),
        "token": secrets.token_hex(16),
    }
    data["users"][key] = user
    save_store(data)
    return user


def verify_user(data: Dict, email: str, password: str) -> Dict:
    key = email.strip().lower()
    user = data["users"].get(key)
    if not user or not check_password_hash(user.get("pw", ""), password):
        raise ValueError("Invalid email or password.")
    return user


def public_user(user: Dict) -> Dict:
    return {"email": user["email"], "name": user["name"], "role": user.get("role", "user"),
            "avatar": user.get("avatar", "")}


def track(data: Dict, kind: str, meta: Dict = None) -> None:
    data["events"].append({"t": int(time.time()), "kind": kind, "meta": meta or {}})
    data["events"] = data["events"][-2000:]
    if kind == "click":
        data["counters"]["site_clicks"] = data["counters"].get("site_clicks", 0) + 1
    if kind == "play":
        data["counters"]["plays"] = data["counters"].get("plays", 0) + 1
    save_store(data)


def add_comment(data: Dict, anime_id: str, ep: str, user: Dict, text: str,
                parent: str = "", sticker: str = "") -> Dict:
    text = (text or "").strip()[:600]
    if not text and not sticker:
        raise ValueError("Write something or pick a sticker.")
    c = {"id": secrets.token_hex(6), "anime_id": str(anime_id), "ep": str(ep),
         "user": user["name"], "email": user["email"], "text": text,
         "parent": parent or "", "sticker": sticker or "", "likes": 0,
         "liked_by": [], "t": int(time.time())}
    data["comments"].append(c)
    data["comments"] = data["comments"][-1000:]
    # notify parent author
    if parent:
        for p in data["comments"]:
            if p["id"] == parent and p["email"] != user["email"]:
                data["notifications"].append(
                    {"id": secrets.token_hex(6), "to": p["email"],
                     "text": f"{user['name']} replied to your comment on anime {anime_id} ep {ep}.",
                     "read": False, "t": int(time.time())})
                break
    save_store(data)
    return c


def like_comment(data: Dict, cid: str, email: str) -> Dict:
    for c in data["comments"]:
        if c["id"] == cid:
            if email in c.get("liked_by", []):
                c["liked_by"].remove(email)
                c["likes"] = max(0, c.get("likes", 1) - 1)
            else:
                c["liked_by"].append(email)
                c["likes"] = c.get("likes", 0) + 1
            save_store(data)
            return c
    raise ValueError("Comment not found.")


def rate_anime(data: Dict, anime_id: str, email: str, score: int) -> Dict:
    score = max(1, min(10, int(score)))
    data["ratings"] = [r for r in data["ratings"]
                       if not (str(r["anime_id"]) == str(anime_id) and r["email"] == email)]
    data["ratings"].append({"anime_id": str(anime_id), "email": email,
                            "score": score, "t": int(time.time())})
    save_store(data)
    return anime_rating(data, anime_id)


def anime_rating(data: Dict, anime_id: str) -> Dict:
    scores = [r["score"] for r in data["ratings"] if str(r["anime_id"]) == str(anime_id)]
    if not scores:
        return {"anime_id": str(anime_id), "count": 0, "avg": 0}
    return {"anime_id": str(anime_id), "count": len(scores),
            "avg": round(sum(scores) / len(scores), 1)}


def admin_stats(data: Dict) -> Dict:
    plays: Dict[str, int] = {}
    for e in data["events"]:
        if e["kind"] == "play":
            k = str((e.get("meta") or {}).get("anime_id", "?"))
            plays[k] = plays.get(k, 0) + 1
    top = sorted(plays.items(), key=lambda x: x[1], reverse=True)[:10]
    return {"users": len(data["users"]), "comments": len(data["comments"]),
            "ratings": len(data["ratings"]), "clicks": data["counters"].get("site_clicks", 0),
            "plays": data["counters"].get("plays", 0),
            "app_downloads": data.get("app_downloads", 0),
            "most_watched": [{"anime_id": k, "plays": v} for k, v in top]}
