import logging
import re
import time
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

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = Flask(__name__)
app.secret_key = os.environ.get("CAMANIME_SECRET", "camanime-dev-secret-change-me")

PLATFORM_STORE = platform.load_store()
platform.ensure_admin(PLATFORM_STORE)
PLATFORM_STORE = platform.load_store()

ANILIST_API_URL = "https://graphql.anilist.co"
_anilist_cache: Dict[str, tuple] = {}
ANILIST_CACHE_TTL = 900  # 15 minutes

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
}}
"""

SEARCH_FILTER_QUERY = f"""
query ($search: String, $genre: String, $format: MediaFormat, $sort: [MediaSort], $page: Int, $perPage: Int) {{
  Page(page: $page, perPage: $perPage) {{
    media(search: $search, genre: $genre, format: $format, sort: $sort, type: ANIME, isAdult: false) {{
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


def fetch_anilist(query: str, variables: Optional[Dict] = None) -> Dict:
    """Fetches data from AniList GraphQL API with in-memory caching."""
    cache_key = f"{hash(query)}_{str(sorted((variables or {}).items()))}"
    now = time.time()
    if cache_key in _anilist_cache:
        data, ts = _anilist_cache[cache_key]
        if now - ts < ANILIST_CACHE_TTL:
            return data

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
        return data
    except Exception as e:
        logger.error(f"AniList API Error: {e}")
        return {}


def clean_html_description(desc: Optional[str]) -> str:
    if not desc:
        return "No synopsis available."
    text = re.sub(r"<br\s*/?>", "\n", desc, flags=re.I)
    text = re.sub(r"<[^>]+>", "", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


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
    if next_ep and next_ep.get("episode"):
        aired_eps = max(1, next_ep["episode"] - 1)
        ep_badge = f"EP {aired_eps}" + (f" / {total_eps}" if total_eps else "")
        latest_ep = aired_eps
    elif total_eps:
        ep_badge = f"{total_eps} EPS"
        latest_ep = total_eps
    else:
        ep_badge = "AIRING" if anime.get("status") == "RELEASING" else "EPS ?"
        latest_ep = 12

    trailer = anime.get("trailer") or {}
    yt_id = (
        trailer.get("id")
        if (trailer.get("site") or "").lower() == "youtube"
        else None
    )

    studios = ((anime.get("studios") or {}).get("nodes") or [])
    studio_name = studios[0].get("name") if studios else "Anime Studio"

    score = anime.get("averageScore")
    rating = f"{score / 10:.1f}" if score else "N/A"

    return {
        "id": anime.get("id"),
        "mal_id": anime.get("idMal"),
        "title": title,
        "title_romaji": title_ro or title,
        "title_native": title_obj.get("native") or "",
        "description": clean_html_description(anime.get("description")),
        "image": image_url,
        "banner": anime.get("bannerImage") or image_url,
        "color": cover.get("color") or "#f59e0b",
        "episode": ep_badge,
        "latest_ep": latest_ep,
        "total_episodes": total_eps,
        "format": anime.get("format") or "TV",
        "status": (anime.get("status") or "FINISHED").replace("_", " ").title(),
        "season": f"{(anime.get('season') or '').title()} {anime.get('seasonYear') or ''}".strip(),
        "year": anime.get("seasonYear") or "",
        "duration": f"{anime.get('duration')}m" if anime.get("duration") else "24m",
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


@app.route("/")
def home():
    genre = request.args.get("genre", "").strip()
    fmt = request.args.get("format", "").strip()

    if genre or fmt:
        variables: Dict = {"page": 1, "perPage": 24, "sort": ["POPULARITY_DESC"]}
        if genre:
            variables["genre"] = genre
        if fmt in ("TV", "MOVIE", "OVA", "ONA", "SPECIAL"):
            variables["format"] = fmt
        data = fetch_anilist(SEARCH_FILTER_QUERY, variables)
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
            page_type="filter",
        )

    data = fetch_anilist(HOME_DASHBOARD_QUERY)
    trending_raw = data.get("trending", {}).get("media", [])
    season_raw = data.get("popularSeason", {}).get("media", [])
    top_raw = data.get("topRated", {}).get("media", [])

    trending = [format_anime_card(a) for a in trending_raw if a]
    popular_season = [format_anime_card(a) for a in season_raw if a]
    top_rated = [format_anime_card(a) for a in top_raw if a]

    hero_slides = [a for a in trending if a.get("banner")][:6] or trending[:5]
    featured = hero_slides[0] if hero_slides else None

    # Fetch live AnimeHeaven latest releases for the homepage live scraper strip
    heaven_recent = streaming_manager.animeheaven.browse_catalog("new")[:12]

    return render_template(
        "index.html",
        trending=trending,
        popular_season=popular_season,
        top_rated=top_rated,
        heaven_recent=heaven_recent,
        featured=featured,
        hero_slides=hero_slides,
        genres=POPULAR_GENRES,
        active_genre="",
        active_format="",
        page_type="home",
    )


@app.route("/search")
def search():
    query = (request.args.get("q") or "").strip()
    if not query:
        return redirect(url_for("home"))

    data = fetch_anilist(
        SEARCH_FILTER_QUERY,
        {"search": query, "page": 1, "perPage": 24, "sort": ["POPULARITY_DESC"]},
    )
    raw_results = data.get("Page", {}).get("media", [])
    results = [format_anime_card(a) for a in raw_results if a]

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
        genres=POPULAR_GENRES,
        active_genre="",
        active_format="",
        page_type="search",
    )


@app.route("/anime/<int:anime_id>")
def details(anime_id: int):
    data = fetch_anilist(DETAILS_QUERY, {"id": anime_id})
    raw_anime = data.get("Media")
    if not raw_anime:
        return render_template("index.html", trending=[], page_type="error", error_msg="Anime not found"), 404

    card = format_anime_card(raw_anime)
    titles = [
        raw_anime["title"].get("english"),
        raw_anime["title"].get("romaji"),
    ]

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

    # Calculate episodes
    total_episodes = raw_anime.get("episodes") or 0
    if raw_anime.get("status") == "RELEASING" and raw_anime.get("nextAiringEpisode"):
        total_episodes = max(total_episodes, raw_anime["nextAiringEpisode"]["episode"] - 1)
    if heaven_info and heaven_info.get("total_episodes"):
        total_episodes = max(total_episodes, heaven_info["total_episodes"])
    if total_episodes <= 0:
        total_episodes = 12

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
    for i in range(1, total_episodes + 1):
        meta = ep_meta_by_num.get(i, {})
        h_ep = heaven_eps_by_num.get(i)
        episode_list.append({
            "id": i,
            "num": i,
            "title": meta.get("title") or f"Episode {i}",
            "thumbnail": meta.get("thumbnail") or card["banner"] or card["image"],
            "heaven_key": h_ep["key"] if h_ep else None,
            "added": h_ep.get("added", "") if h_ep else "",
        })

    # Related seasons / sequels / prequels
    relations = []
    for edge in (raw_anime.get("relations") or {}).get("edges") or []:
        node = edge.get("node") or {}
        if node.get("type") == "ANIME" and node.get("id"):
            rel_card = format_anime_card(node)
            rel_card["relation"] = (edge.get("relationType") or "RELATED").replace("_", " ")
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
    heaven_override = request.args.get("heaven_id")

    data = fetch_anilist(DETAILS_QUERY, {"id": anime_id})
    raw_anime = data.get("Media") or {}
    card = format_anime_card(raw_anime) if raw_anime else {
        "id": anime_id,
        "mal_id": None,
        "title": f"Anime #{anime_id}",
        "title_romaji": f"Anime #{anime_id}",
        "image": "",
        "banner": "",
        "description": "",
        "rating": "N/A",
        "format": "TV",
        "status": "Releasing",
        "genres": [],
        "trailer_id": None,
    }

    titles = []
    if raw_anime.get("title"):
        titles = [
            raw_anime["title"].get("english"),
            raw_anime["title"].get("romaji"),
        ]
    else:
        titles = [card["title"]]

    trailer_id = streaming_manager.youtube.get_trailer_id(
        card["title"], raw_anime.get("trailer")
    )
    card["trailer_id"] = trailer_id

    bundle = streaming_manager.get_full_episode_bundle(
        anilist_id=anime_id,
        ep_num=ep_num,
        titles=titles,
        mal_id=raw_anime.get("idMal"),
        preferred_audio=preferred_audio,
        heaven_override=heaven_override,
    )

    # Calculate episode list
    total_episodes = raw_anime.get("episodes") or 0
    if raw_anime.get("status") == "RELEASING" and raw_anime.get("nextAiringEpisode"):
        total_episodes = max(total_episodes, raw_anime["nextAiringEpisode"]["episode"] - 1)
    if bundle.get("heaven_id"):
        h_info = streaming_manager.animeheaven.get_anime_info(bundle["heaven_id"])
        if h_info and h_info.get("total_episodes"):
            total_episodes = max(total_episodes, h_info["total_episodes"])
    if total_episodes < ep_num:
        total_episodes = max(ep_num, 12)

    episodes = [{"id": i, "num": i, "title": f"Episode {i}"} for i in range(1, total_episodes + 1)]

    active_server = bundle.get("active_server") or {
        "id": "embed-vidsrc-sub",
        "name": "VidSrc Pro (SUB)",
        "playback_mode": "iframe",
        "stream_url": f"https://vidsrc.cc/v2/embed/anime/ani{anime_id}/{ep_num}/sub",
        "subtitles": [],
    }
    backup_embed = f"https://vidsrc.cc/v2/embed/anime/ani{anime_id}/{ep_num}/sub"

    # Related seasons for quick switching
    relations = []
    for edge in (raw_anime.get("relations") or {}).get("edges") or []:
        node = edge.get("node") or {}
        if node.get("type") == "ANIME" and node.get("id"):
            rel_card = format_anime_card(node)
            rel_card["relation"] = (edge.get("relationType") or "RELATED").replace("_", " ")
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
        prev_ep={"id": ep_num - 1, "num": ep_num - 1} if ep_num > 1 else None,
        next_ep={"id": ep_num + 1, "num": ep_num + 1} if ep_num < total_episodes else None,
    )


@app.route("/scraper")
def scraper_hub():
    """
    Dedicated AnimeHeaven Reverse-Engineered Scraper & Direct Downloader Hub
    (Upgraded version of the attached AnimeHeaven-Scraper test frontend integrated into CamAnime)
    """
    feed = request.args.get("feed", "new")
    query = (request.args.get("q") or "").strip()
    site_id = (request.args.get("id") or "").strip()

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
    ep_num = int(request.args.get("ep", 1))
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
    heaven_id = request.args.get("heaven_id")
    data = fetch_anilist(DETAILS_QUERY, {"id": anime_id})
    raw_anime = data.get("Media") or {}
    titles = []
    if raw_anime.get("title"):
        titles = [raw_anime["title"].get("english"), raw_anime["title"].get("romaji")]
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
    results = streaming_manager.animeheaven.browse_catalog(feed)
    return jsonify({"status": "success", "feed": feed, "count": len(results), "results": results})


@app.route("/api/heaven/anime/<site_id>")
def api_heaven_anime(site_id: str):
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
    site_id = request.args.get("site_id")
    res = streaming_manager.animeheaven.get_streaming_sources(episode_key, referer_site_id=site_id)
    if not res.get("sources"):
        return jsonify({"status": "error", "error": "Could not resolve MP4 stream"}), 404
    sources = []
    for s in res["sources"]:
        u = s["url"]
        sources.append({
            **s,
            "proxy_url": f"/api/proxy/video?url={quote(u, safe='')}",
            "download_url": f"/api/download/video?url={quote(u, safe='')}&title={quote(request.args.get('title', f'AnimeHeaven_{episode_key[:8]}'), safe='')}",
        })
    return jsonify({"status": "success", "episode_key": episode_key, "sources": sources})


@app.route("/api/heaven/season-pack/<site_id>")
def api_heaven_season_pack(site_id: str):
    """Resolves direct MP4 download links for episodes in an AnimeHeaven season/series."""
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
            resolved_pack.append({
                "num": ep["num"],
                "key": ep["key"],
                "raw_mp4": primary["url"],
                "stream_url": f"/api/proxy/video?url={quote(primary['url'], safe='')}",
                "download_url": f"/api/download/video?url={quote(primary['url'], safe='')}&title={quote(ep_title, safe='')}",
            })
    return jsonify({
        "status": "success",
        "site_id": site_id,
        "title": info["title"],
        "total_episodes": info["total_episodes"],
        "resolved_count": len(resolved_pack),
        "episodes": resolved_pack,
    })


@app.route("/api/proxy/hls")
def proxy_hls():
    """CORS-clean HLS playlist & segment proxy that rewrites M3U8 internal URIs."""
    url = request.args.get("url", "").strip()
    ref = request.args.get("ref", "").strip()
    if not url or not url.startswith(("http://", "https://")):
        return jsonify({"error": "Invalid url"}), 400

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
            url, headers=headers, stream=True, timeout=15, verify=False
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
    url = request.args.get("url", "").strip()
    ref = request.args.get("ref", "https://animeheaven.me/").strip()
    if not url or not url.startswith(("http://", "https://")):
        return jsonify({"error": "Invalid url"}), 400

    headers = {
        "User-Agent": DEFAULT_UA,
        "Accept": "*/*",
        "Referer": ref,
    }
    if request.headers.get("Range"):
        headers["Range"] = request.headers["Range"]

    try:
        upstream = requests.get(url, headers=headers, stream=True, timeout=20)

        def generate():
            try:
                for chunk in upstream.iter_content(chunk_size=131072):
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


@app.route("/api/download/video")
def download_video():
    """Forces a direct browser file download (.mp4) of the anime episode."""
    if not _current_user():
        if "text/html" in (request.headers.get("Accept", "") or ""):
            return redirect(url_for("login_page", next=request.full_path))
        return jsonify({"error": "Sign in to download episodes.", "login": "/login"}), 401
    url = request.args.get("url", "").strip()
    title = request.args.get("title", "CamAnime_Episode").strip()
    ref = request.args.get("ref", "https://animeheaven.me/").strip()
    if not url or not url.startswith(("http://", "https://")):
        return jsonify({"error": "Invalid url"}), 400

    safe_filename = re.sub(r"[^a-zA-Z0-9_\-\. ]", "", title).strip().replace(" ", "_") or "CamAnime_Episode"
    if not safe_filename.lower().endswith(".mp4"):
        safe_filename += ".mp4"

    headers = {
        "User-Agent": DEFAULT_UA,
        "Accept": "*/*",
        "Referer": ref,
    }
    if request.headers.get("Range"):
        headers["Range"] = request.headers["Range"]

    try:
        upstream = requests.get(url, headers=headers, stream=True, timeout=25)

        def generate():
            try:
                for chunk in upstream.iter_content(chunk_size=131072):
                    if chunk:
                        yield chunk
            finally:
                upstream.close()

        resp = Response(
            generate(),
            status=upstream.status_code,
            content_type="video/mp4",
        )
        resp.headers["Content-Disposition"] = f'attachment; filename="{safe_filename}"'
        resp.headers["Access-Control-Allow-Origin"] = "*"
        for h in ("Content-Length", "Content-Range", "Accept-Ranges"):
            if h in upstream.headers:
                resp.headers[h] = upstream.headers[h]
        return resp
    except Exception as e:
        logger.error(f"Video Download Error ({url}): {e}")
        return jsonify({"error": str(e)}), 502


@app.route("/api/proxy/subtitle")
def proxy_subtitle():
    """Proxies WebVTT / SRT subtitle tracks with open CORS and automatic SRT->VTT conversion."""
    url = request.args.get("url", "").strip()
    ref = request.args.get("ref", "https://megaplay.buzz/").strip()
    if not url or not url.startswith(("http://", "https://")):
        return jsonify({"error": "Invalid url"}), 400

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
    csp = ("default-src 'self' https: data: blob:; " "script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net https://cdnjs.cloudflare.com; " "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com https://cdnjs.cloudflare.com; " "font-src 'self' https://fonts.gstatic.com https://cdnjs.cloudflare.com; " "img-src 'self' https: data: blob:; " "media-src 'self' https: blob: data:; " "frame-src 'self' https:; " "connect-src 'self' https: blob:;")
    resp.headers.setdefault("Content-Security-Policy", csp)
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
    store = platform.load_store()
    u = store["users"].get(email.lower())
    return platform.public_user(u) if u else None


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
    store = platform.load_store()
    items = [n for n in store["notifications"] if n["to"] == u["email"]][-20:]
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
    store = platform.load_store()
    error = ""
    mode = request.args.get("mode", "signin")
    if request.method == "POST":
        email = request.form.get("email", "").strip()
        password = request.form.get("password", "")
        name = request.form.get("name", "").strip()
        action = request.form.get("action", "signin")
        try:
            if action == "signup":
                user = platform.register_user(store, email, name or email.split("@")[0], password)
            else:
                store = platform.load_store()
                user = platform.verify_user(store, email, password)
            _s["user_email"] = user["email"]
            nxt = request.args.get("next", "/")
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
    store = platform.load_store()
    stats = platform.admin_stats(store)
    return render_template("admin.html", user=u, stats=stats, schedule=platform.CLASSICS_SCHEDULE)


@app.route("/schedule")
def schedule_page():
    return render_template("schedule.html", schedule=platform.CLASSICS_SCHEDULE, user=_current_user())


@app.route("/promo")
def promo_page():
    return render_template("promo.html", user=_current_user())


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


RELEASE_TAG = os.environ.get("CAMANIME_RELEASE_TAG", "v1.0.0")
RELEASE_DL = "https://github.com/kayefande-droid/CamAnime/releases/download"


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
    return _serve_app_file(["CamAnime.apk"], "CamAnime.apk", "CamAnime.apk")


@app.route("/get/windows")
def get_windows():
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
    store = platform.load_store()
    anime_id = request.args.get("anime_id", "")
    ep = request.args.get("ep", "")
    items = [c for c in store["comments"] if str(c["anime_id"]) == str(anime_id) and (not ep or str(c["ep"]) == str(ep))]
    items = sorted(items, key=lambda x: x["t"])[-100:]
    return jsonify({"status": "success", "comments": items, "stickers": platform.CAM_STICKERS})


@app.route("/api/community/comment", methods=["POST"])
def api_comment_post():
    u = _current_user()
    if not u:
        return jsonify({"status": "error", "error": "Sign in to comment."}), 401
    store = platform.load_store()
    full = store["users"].get(u["email"], {})
    try:
        c = platform.add_comment(store, _post_data().get("anime_id", ""), _post_data().get("ep", ""), {**u, "email": u["email"]}, _post_data().get("text", ""), _post_data().get("parent", ""), _post_data().get("sticker", ""))
        return jsonify({"status": "success", "comment": c})
    except Exception as e:
        return jsonify({"status": "error", "error": str(e)}), 400


@app.route("/api/community/like/<cid>", methods=["POST"])
def api_comment_like(cid):
    u = _current_user()
    if not u:
        return jsonify({"status": "error", "error": "Sign in to like."}), 401
    store = platform.load_store()
    try:
        c = platform.like_comment(store, cid, u["email"])
        return jsonify({"status": "success", "likes": c["likes"]})
    except Exception as e:
        return jsonify({"status": "error", "error": str(e)}), 404


@app.route("/api/community/rate", methods=["POST"])
def api_rate():
    u = _current_user()
    if not u:
        return jsonify({"status": "error", "error": "Sign in to rate."}), 401
    store = platform.load_store()
    r = platform.rate_anime(store, _post_data().get("anime_id", ""), u["email"], _post_data().get("score", 8))
    return jsonify({"status": "success", "rating": r})


@app.route("/api/community/notifications")
def api_notifications():
    u = _current_user()
    if not u:
        return jsonify({"status": "error", "notifications": []}), 401
    store = platform.load_store()
    items = [n for n in store["notifications"] if n["to"] == u["email"]][-20:]
    unread = sum(1 for n in items if not n.get("read"))
    return jsonify({"status": "success", "notifications": items, "unread": unread})


@app.route("/api/track", methods=["POST"])
def api_track():
    store = platform.load_store()
    d = _post_data()
    platform.track(store, d.get("kind", "click"), {"anime_id": d.get("anime_id", ""), "ep": d.get("ep", "")})
    return jsonify({"status": "ok"})


@app.route("/api/public/anime/<int:anime_id>")
def api_public_anime(anime_id: int):
    """Public streaming API for the native apps."""
    data = fetch_anilist(DETAILS_QUERY, {"id": anime_id})
    raw = data.get("Media") or {}
    titles = [raw.get("title", {}).get("english"), raw.get("title", {}).get("romaji")] if raw.get("title") else []
    bundle = streaming_manager.get_full_episode_bundle(anime_id, int(request.args.get("ep", 1)), [t for t in titles if t], mal_id=raw.get("idMal"))
    store = platform.load_store()
    return jsonify({"status": "success", "anime_id": anime_id, "title": (titles[0] if titles else ""), "servers": bundle.get("servers", []), "downloads_require_login": True, "rating": platform.anime_rating(store, anime_id)})


@app.route("/sitemap.xml")
def sitemap():
    xml = "<?xml version='1.0' encoding='UTF-8'?><urlset xmlns='http://www.sitemaps.org/schemas/sitemap/0.9'>" + "".join(f"<url><loc>{request.host_url.rstrip('/')}{p}</loc></url>" for p in ["/", "/scraper", "/schedule", "/promo", "/download", "/login"]) + "</urlset>"
    return Response(xml, mimetype="application/xml")


@app.route("/robots.txt")
def robots():
    return Response("User-agent: *\nAllow: /\nSitemap: " + request.host_url.rstrip("/") + "/sitemap.xml\n", mimetype="text/plain")


@app.route("/google78cbf317abe48f6e.html")
def google_verify():
    return app.send_static_file("google78cbf317abe48f6e.html")


if __name__ == "__main__":
    app.run(debug=True, host="0.0.0.0", port=3000)
