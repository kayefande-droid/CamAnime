"""
CamAnime Streaming & Scraper Engine
Real, live-tested multi-provider anime streaming & downloading integration:
1. AnimeHeavenProvider (animeheaven.me)
   - Reverse-engineered fastsearch.php + anime.php + gate.php (cookie `key=<episode_key>`)
   - Extracts direct MP4 video mirrors (rt.animeheaven.me, ct.animeheaven.me, ck.animeheaven.me)
   - Supports catalog browsing (New, Popular, Recent, Random, Show Details, Season batch download)
2. AnikotoProvider (anikoto.net)
   - Reverse-engineered /filter + /watch/<slug> + /ajax/episode/list + /ajax/server/list + /ajax/server
   - MegaPlay AES-256-CBC dynamic client-script key/IV decryption to extract 1080p HLS (.m3u8) + multi-language WebVTT subtitles + intro/outro skip timestamps
   - Supports both SUB and DUB servers (HD-1, HD-2, Vidstream-1, Vidstream-2)
   - Kiwi Mapper (mapper.nekostream.site) integration for direct 360p/720p/1080p Pahe download links
3. YouTubeTrailerResolver
   - Resolves official anime PV / trailer YouTube video IDs via AniList metadata or live YouTube search
"""

import base64
import json
import logging
import os
import re
import time
from collections import OrderedDict
from typing import Dict, List, Optional, Tuple
from urllib.parse import quote, unquote, urljoin, urlparse

import requests
from bs4 import BeautifulSoup
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "WARNING").upper())
logger = logging.getLogger(__name__)

DEFAULT_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
)

TYPE_INDICATOR_WORDS = {
    "ova", "ona", "special", "specials", "movie", "film",
    "recap", "picture", "pv", "season", "part", "cour", "saga",
}


def normalize_title(title: str) -> str:
    return re.sub(r"[^a-z0-9]", "", (title or "").lower())


def significant_words(s: str) -> List[str]:
    cleaned = re.sub(r"[^a-z0-9\s]", " ", (s or "").lower())
    return [w for w in cleaned.split() if len(w) >= 2]


def adds_unrequested_type_indicator(query: str, candidate_title: str) -> bool:
    q_words = set(significant_words(query))
    return any(
        w in TYPE_INDICATOR_WORDS and w not in q_words
        for w in significant_words(candidate_title)
    )


def score_title(query: str, candidate: str) -> int:
    needle = normalize_title(query)
    hay = normalize_title(candidate)
    if not needle or not hay:
        return 0
    if hay == needle:
        return 100

    # Check if candidate contains comma-separated aliases (AnimeHeaven often formats "Jujutsu Kaisen 2nd Season, jjk")
    parts = [p.strip() for p in candidate.split(",") if p.strip()]
    if len(parts) > 1:
        sub_scores = [score_title_single(query, p) for p in parts]
        return max(sub_scores)

    return score_title_single(query, candidate)


def score_title_single(query: str, candidate: str) -> int:
    needle = normalize_title(query)
    hay = normalize_title(candidate)
    if not needle or not hay:
        return 0
    if hay == needle:
        return 100

    ratio = min(len(needle), len(hay)) / max(len(needle), len(hay))
    query_is_longer = len(needle) > len(hay)
    missing_words = (
        len(significant_words(query)) - len(significant_words(candidate))
        if query_is_longer
        else 0
    )
    spinoff_marker = not query_is_longer and adds_unrequested_type_indicator(query, candidate)

    if hay.startswith(needle) or needle.startswith(hay):
        if query_is_longer and missing_words >= 2:
            return int(ratio * 35)
        if spinoff_marker:
            return int(ratio * 40)
        return 85 if ratio >= 0.6 else int(ratio * 65)

    if needle in hay or hay in needle:
        if query_is_longer and missing_words >= 2:
            return int(ratio * 30)
        if spinoff_marker:
            return int(ratio * 35)
        return 68 if ratio >= 0.6 else int(ratio * 50)

    matches = sum(1 for ch in needle if ch in hay)
    return int((matches / max(len(needle), 1)) * 40)


def generate_title_variants(titles: List[str]) -> List[str]:
    variants = []
    for raw in titles:
        if not raw:
            continue
        t = raw.strip()
        no_poss = re.sub(r"[’']s\b", "", t, flags=re.I)
        no_apos = re.sub(r"[’']", "", t)
        candidates = [
            t,
            no_poss,
            no_apos,
            t.replace("+", " "),
            re.split(r"[:(|-]", t)[0].strip(),
            re.split(r"[:(|-]", no_poss)[0].strip(),
            " ".join(no_apos.split()[:3]),
            " ".join(no_apos.split()[:2]),
            no_apos.split()[0] if no_apos.split() else "",
        ]
        for c in candidates:
            c_clean = c.strip()
            if len(c_clean) >= 2 and c_clean not in variants:
                variants.append(c_clean)
    return variants


class StreamingProvider:
    """Base provider with a bounded LRU/TTL cache to cap worker memory."""

    CACHE_MAX_ENTRIES = 64

    def __init__(self, timeout: int = 12):
        self.timeout = timeout
        self.cache: OrderedDict[str, Tuple[object, float]] = OrderedDict()
        self.cache_duration = 1800  # 30 minutes

    def _cache_get(self, key: str, ttl: Optional[int] = None):
        entry = self.cache.get(key)
        if entry is None:
            return None
        data, timestamp = entry
        max_age = ttl if ttl is not None else self.cache_duration
        if time.time() - timestamp >= max_age:
            self.cache.pop(key, None)
            return None
        self.cache.move_to_end(key)
        return data

    def _cache_set(self, key: str, value: object):
        now = time.time()
        cutoff = now - self.cache_duration
        for old_key, (_old_value, timestamp) in list(self.cache.items()):
            if timestamp < cutoff:
                self.cache.pop(old_key, None)
        self.cache[key] = (value, now)
        self.cache.move_to_end(key)
        while len(self.cache) > self.CACHE_MAX_ENTRIES:
            self.cache.popitem(last=False)


class AnimeHeavenProvider(StreamingProvider):
    """
    Reverse-engineered AnimeHeaven (animeheaven.me) Scraper & Stream Resolver.
    - Search: GET /fastsearch.php?xhr=1&s=<query>
    - Browse: GET /new.php, /popular.php, /index.php, /random.php
    - Details & Episodes: GET /anime.php?<site_id>
    - Stream Resolution: GET /gate.php with Cookie `key=<episode_key>` -> extracts direct MP4 links
    """

    def __init__(self, timeout: int = 12):
        super().__init__(timeout)
        self.base_url = "https://animeheaven.me"
        self.session = requests.Session()
        self.session.headers.update({
            "User-Agent": DEFAULT_UA,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
            "Referer": f"{self.base_url}/",
            "Origin": self.base_url,
        })

    def _abs_url(self, path_or_url: str) -> str:
        if not path_or_url:
            return ""
        return urljoin(f"{self.base_url}/", path_or_url.lstrip("/"))

    def search(self, query: str) -> List[Dict]:
        """Search anime on AnimeHeaven via fastsearch.php"""
        q = (query or "").strip()
        if not q:
            return []
        cache_key = f"heaven_search_{q.lower()}"
        cached = self._cache_get(cache_key, ttl=900)
        if cached is not None:
            return cached

        try:
            resp = self.session.get(
                f"{self.base_url}/fastsearch.php",
                params={"xhr": 1, "s": q},
                timeout=self.timeout,
            )
            resp.raise_for_status()
            soup = BeautifulSoup(resp.text, "html.parser")
            results = []
            seen = set()

            for a in soup.select('a[href*="anime.php?"]'):
                href = a.get("href", "")
                if "?" not in href:
                    continue
                site_id = href.split("?", 1)[1].strip()
                if not site_id or site_id in seen:
                    continue
                fastname = a.select_one(".fastname")
                img = a.find("img")
                title = (
                    fastname.get_text(" ", strip=True)
                    if fastname
                    else (img.get("alt", "").strip() if img else a.get_text(" ", strip=True))
                )
                if not title:
                    continue
                seen.add(site_id)
                img_src = img.get("src", "") if img else ""
                results.append({
                    "id": site_id,
                    "title": title,
                    "url": self._abs_url(f"anime.php?{site_id}"),
                    "image": self._abs_url(img_src) if img_src else "",
                    "provider": "animeheaven",
                })

            self._cache_set(cache_key, results)
            return results
        except Exception as e:
            logger.error(f"[AnimeHeaven] search error ({q}): {e}")
            return []

    def find_best_id(self, titles: List[str]) -> Optional[str]:
        """Find best matching AnimeHeaven site_id given English/Romaji titles"""
        variants = generate_title_variants(titles)
        primary_title = titles[0] if titles else ""
        all_results: Dict[str, Dict] = {}

        for variant in variants:
            res = self.search(variant)
            for item in res:
                all_results[item["id"]] = item
            # Early stop if high-confidence match
            if any(
                max(score_title(t, item["title"]) for t in titles if t) >= 85
                for item in res
            ):
                break

        if not all_results:
            return None

        scored = []
        for item in all_results.values():
            best_s = max((score_title(t, item["title"]) for t in titles if t), default=0)
            scored.append((best_s, item))

        scored.sort(key=lambda x: x[0], reverse=True)
        best_score, best_item = scored[0]
        if best_score < 55:
            logger.info(
                f"[AnimeHeaven] rejected low-score match '{best_item['title']}' ({best_score}) for {primary_title}"
            )
            return None
        logger.info(
            f"[AnimeHeaven] matched '{best_item['title']}' (id={best_item['id']}, score={best_score})"
        )
        return best_item["id"]

    def get_anime_info(self, site_id: str) -> Optional[Dict]:
        """Scrape full anime details & episode keys from anime.php?<site_id>"""
        cache_key = f"heaven_info_{site_id}"
        cached = self._cache_get(cache_key, ttl=900)
        if cached is not None:
            return cached

        try:
            url = f"{self.base_url}/anime.php?{site_id}"
            resp = self.session.get(url, timeout=self.timeout)
            resp.raise_for_status()
            soup = BeautifulSoup(resp.text, "html.parser")

            title_el = soup.select_one(".infotitle")
            title_jp_el = soup.select_one(".infotitlejp")
            desc_el = soup.select_one(".infodes")
            year_el = soup.select_one(".infoyear")
            tags_el = soup.select_one(".infotags")
            poster_el = soup.select_one("img.posterimg")

            title = title_el.get_text(" ", strip=True) if title_el else "Unknown"
            title_jp = title_jp_el.get_text(" ", strip=True) if title_jp_el else ""
            description = desc_el.get_text(" ", strip=True) if desc_el else ""
            meta_line = year_el.get_text(" ", strip=True) if year_el else ""
            poster = self._abs_url(poster_el.get("src", "")) if poster_el else ""

            tags = []
            if tags_el:
                raw_tags = tags_el.get_text(" ", strip=True).replace("Tags:", "").strip()
                tags = [a.get_text(strip=True) for a in tags_el.find_all("a")] or raw_tags.split()

            # Parse episodes and their gate keys
            episodes = []
            seen_keys = set()
            for a in soup.find_all("a"):
                onmouseover = a.get("onmouseover", "")
                onclick = a.get("onclick", "")
                href = a.get("href", "")
                text = a.get_text(" ", strip=True)
                attrs = f"{onmouseover} {onclick} {href}"

                if not re.search(r"gate[ha]\s*\(|gate\.php|episode", f"{attrs} {text}", re.I):
                    continue

                key_match = (
                    re.search(r"gate[ha]\s*\(\s*['\"]([^'\"]+)['\"]", attrs, re.I)
                    or re.search(r"gate[ha]\s*\(\s*([^,)\s]+)", attrs, re.I)
                    or re.search(r"[?&](?:key|id)=([^&#]+)", href, re.I)
                )
                if not key_match:
                    continue
                ep_key = unquote(key_match.group(1).strip())
                if not ep_key or ep_key in seen_keys:
                    continue

                watch2 = a.select_one(".watch2")
                raw_num = ""
                if watch2:
                    raw_num = watch2.get_text(strip=True)
                if not raw_num:
                    m_num = re.search(r"episode\s*([0-9]+(?:\.[0-9]+)?)", text, re.I) or re.match(
                        r"^([0-9]+(?:\.[0-9]+)?)$", text
                    )
                    if m_num:
                        raw_num = m_num.group(1)

                try:
                    ep_num_float = float(re.sub(r"^0+(\d)", r"\1", raw_num))
                    ep_num = int(ep_num_float) if ep_num_float.is_integer() else ep_num_float
                except Exception:
                    continue

                # Also extract relative age if available (e.g. "2 days ago")
                watch1 = a.select(".watch1")
                added_ago = watch1[-1].get_text(strip=True) if len(watch1) > 1 else ""

                seen_keys.add(ep_key)
                episodes.append({
                    "id": ep_key,
                    "key": ep_key,
                    "num": ep_num,
                    "title": f"Episode {raw_num}",
                    "added": added_ago,
                })

            episodes.sort(key=lambda x: float(x["num"]))

            # Parse related / similar shows on the page
            related = []
            for ch in soup.select(".info3 a[href*='anime.php?']"):
                r_href = ch.get("href", "")
                r_id = r_href.split("?", 1)[1].strip() if "?" in r_href else ""
                r_img = ch.find("img")
                r_title = r_img.get("alt", "").strip() if r_img else ch.get_text(" ", strip=True)
                if r_id and r_title and not any(x["id"] == r_id for x in related):
                    related.append({
                        "id": r_id,
                        "title": r_title,
                        "image": self._abs_url(r_img.get("src", "")) if r_img else "",
                    })

            info = {
                "site_id": site_id,
                "title": title,
                "title_jp": title_jp,
                "description": description,
                "meta": meta_line,
                "image": poster,
                "tags": tags,
                "episodes": episodes,
                "total_episodes": len(episodes),
                "related": related[:12],
                "url": url,
            }
            self._cache_set(cache_key, info)
            return info
        except Exception as e:
            logger.error(f"[AnimeHeaven] get_anime_info error ({site_id}): {e}")
            return None

    def get_episodes(self, site_id: str) -> Tuple[List[Dict], str]:
        info = self.get_anime_info(site_id)
        if not info:
            return [], "Unknown"
        return info.get("episodes", []), info.get("title", "Unknown")

    def get_streaming_sources(self, episode_key: str, referer_site_id: Optional[str] = None) -> Dict:
        """
        Resolve an AnimeHeaven episode key via gate.php with Cookie: key=<episode_key>.
        Returns direct MP4 video mirrors.
        """
        cache_key = f"heaven_stream_{episode_key}"
        cached = self._cache_get(cache_key, ttl=900)
        if cached is not None:
            return cached

        referer = (
            f"{self.base_url}/anime.php?{referer_site_id}"
            if referer_site_id
            else f"{self.base_url}/"
        )
        try:
            headers = {
                "User-Agent": DEFAULT_UA,
                "Referer": referer,
                "Origin": self.base_url,
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Cache-Control": "no-cache",
                "Sec-Fetch-Dest": "document",
                "Sec-Fetch-Mode": "navigate",
                "Sec-Fetch-Site": "same-origin",
                "Cookie": f"key={episode_key}",
            }
            resp = self.session.get(
                f"{self.base_url}/gate.php",
                headers=headers,
                timeout=self.timeout,
            )
            resp.raise_for_status()
            html = resp.text

            if re.search(r"watch\s+episode\s+on\s+animeheaven\.me", html, re.I):
                logger.warning("[AnimeHeaven] gate.php returned placeholder player")
                return {"sources": [], "subtitles": [], "provider": "animeheaven"}

            soup = BeautifulSoup(html, "html.parser")
            raw_urls = []
            for src_el in soup.select("video source"):
                s_url = (src_el.get("src") or "").strip()
                if s_url.startswith("http") and s_url not in raw_urls:
                    raw_urls.append(s_url)

            # Fallback regex in scripts if needed
            if not raw_urls:
                for m in re.finditer(r"https?://[^\s\"']+\.mp4[^\s\"']*", html):
                    u = m.group(0)
                    if u not in raw_urls:
                        raw_urls.append(u)

            sources = []
            for idx, u in enumerate(raw_urls):
                host = urlparse(u).hostname or f"mirror-{idx+1}"
                label = "Direct MP4 (Primary CDN)" if idx == 0 else f"Direct MP4 ({host.split('.')[0].upper()} Mirror)"
                sources.append({
                    "url": u,
                    "quality": "1080p / 720p MP4",
                    "label": label,
                    "isM3u8": False,
                    "isMp4": True,
                    "referer": f"{self.base_url}/",
                })

            result = {
                "sources": sources,
                "subtitles": [],
                "provider": "animeheaven",
                "episode_id": episode_key,
                "referer": f"{self.base_url}/",
            }
            if sources:
                self._cache_set(cache_key, result)
            return result
        except Exception as e:
            logger.error(f"[AnimeHeaven] gate.php error ({episode_key}): {e}")
            return {"sources": [], "subtitles": [], "provider": "animeheaven", "error": str(e)}

    def browse_catalog(self, feed: str = "new") -> List[Dict]:
        """
        Browse AnimeHeaven feeds directly:
        - 'new': /new.php (latest episode releases)
        - 'popular': /popular.php (top popular anime on AnimeHeaven)
        - 'home': /index.php (main chart feed)
        """
        page_map = {
            "new": "new.php",
            "popular": "popular.php",
            "home": "index.php",
        }
        page = page_map.get(feed, "new.php")
        cache_key = f"heaven_catalog_{page}"
        cached = self._cache_get(cache_key, ttl=600)
        if cached is not None:
            return cached

        try:
            resp = self.session.get(f"{self.base_url}/{page}", timeout=self.timeout)
            resp.raise_for_status()
            soup = BeautifulSoup(resp.text, "html.parser")
            items = []
            seen = set()

            for ch in soup.select(".chart"):
                a = ch.select_one('a[href*="anime.php?"]')
                if not a:
                    continue
                href = a.get("href", "")
                site_id = href.split("?", 1)[1].strip() if "?" in href else ""
                if not site_id or site_id in seen:
                    continue
                seen.add(site_id)

                img = ch.find("img", class_="coverimg") or ch.find("img")
                title_el = ch.select_one(".charttitle a") or ch.select_one(".charttitle")
                title_jp_el = ch.select_one(".charttitlejp")
                ep_el = ch.select_one(".chartep") or ch.select_one(".chartepm")
                timer_el = ch.select_one(".charttimer")

                title = (
                    title_el.get_text(" ", strip=True)
                    if title_el
                    else (img.get("alt", "").strip() if img else site_id)
                )
                items.append({
                    "id": site_id,
                    "title": title,
                    "title_jp": title_jp_el.get_text(" ", strip=True) if title_jp_el else "",
                    "image": self._abs_url(img.get("src", "")) if img else "",
                    "episode": ep_el.get_text(strip=True) if ep_el else "?",
                    "updated": timer_el.get_text(" ", strip=True) if timer_el else "",
                    "url": self._abs_url(f"anime.php?{site_id}"),
                })

            self._cache_set(cache_key, items)
            return items
        except Exception as e:
            logger.error(f"[AnimeHeaven] browse_catalog error ({feed}): {e}")
            return []

    def get_random_anime(self) -> Optional[Dict]:
        """Follow AnimeHeaven's /random.php redirect and scrape the resulting show"""
        try:
            resp = self.session.get(
                f"{self.base_url}/random.php", allow_redirects=True, timeout=self.timeout
            )
            resp.raise_for_status()
            if "?" in resp.url:
                site_id = resp.url.split("?", 1)[1].strip()
                return self.get_anime_info(site_id)
        except Exception as e:
            logger.error(f"[AnimeHeaven] random error: {e}")
        return None


class AnikotoProvider(StreamingProvider):
    """
    Reverse-engineered Anikoto (anikoto.net) + MegaPlay AES-256-CBC HLS Decryptor + Kiwi Pahe Downloader.
    Provides 1080p Sub & Dub HLS streams, multi-language subtitles, intro/outro skip times,
    and direct 360p/720p/1080p episode download links.
    """

    def __init__(self, timeout: int = 12):
        super().__init__(timeout)
        self.base_url = "https://anikoto.net"
        self.session = requests.Session()
        self.session.headers.update({
            "User-Agent": DEFAULT_UA,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
            "Referer": f"{self.base_url}/",
        })
        self._megaplay_script_cache: OrderedDict[str, Tuple[List[bytes], List[bytes], float]] = OrderedDict()
        self._megaplay_script_cache_max = 16

    def search(self, query: str) -> List[Dict]:
        q = (query or "").strip()
        if not q:
            return []
        cache_key = f"anikoto_search_{q.lower()}"
        cached = self._cache_get(cache_key, ttl=900)
        if cached is not None:
            return cached

        try:
            resp = self.session.get(
                f"{self.base_url}/filter",
                params={"keyword": q},
                timeout=self.timeout,
            )
            resp.raise_for_status()
            soup = BeautifulSoup(resp.text, "html.parser")
            results = []
            seen = set()

            for el in soup.select(".items .item, .flw-item"):
                a = el if el.name == "a" else el.find("a", href=True)
                if not a:
                    continue
                href = a.get("href", "")
                slug = re.sub(r"^https?://[^/]+", "", href)
                slug = re.sub(r"^/watch/", "", slug)
                slug = re.sub(r"/ep-\d+.*$", "", slug).strip("/")
                if not slug or slug in seen:
                    continue

                title_el = el.select_one(".name, .d-title")
                title = title_el.get_text(" ", strip=True) if title_el else ""
                if not title:
                    continue

                img = el.find("img")
                seen.add(slug)
                results.append({
                    "id": slug,
                    "slug": slug,
                    "title": title,
                    "image": (img.get("data-src") or img.get("src") or "") if img else "",
                    "provider": "anikoto",
                })

            self._cache_set(cache_key, results)
            return results
        except Exception as e:
            logger.error(f"[Anikoto] search error ({q}): {e}")
            return []

    def find_best_slug(self, titles: List[str]) -> Optional[str]:
        variants = generate_title_variants(titles)
        all_results: Dict[str, Dict] = {}

        for variant in variants:
            res = self.search(variant)
            for item in res:
                all_results[item["slug"]] = item
            if any(
                max(score_title(t, item["title"]) for t in titles if t) >= 85
                for item in res
            ):
                break

        if not all_results:
            return None

        scored = []
        for item in all_results.values():
            best_s = max((score_title(t, item["title"]) for t in titles if t), default=0)
            scored.append((best_s, item))

        scored.sort(key=lambda x: x[0], reverse=True)
        best_score, best_item = scored[0]
        if best_score < 50:
            return None
        logger.info(
            f"[Anikoto] matched '{best_item['title']}' (slug={best_item['slug']}, score={best_score})"
        )
        return best_item["slug"]

    def get_episodes(self, slug: str) -> List[Dict]:
        cache_key = f"anikoto_eps_{slug}"
        cached = self._cache_get(cache_key, ttl=900)
        if cached is not None:
            return cached

        try:
            resp = self.session.get(f"{self.base_url}/watch/{slug}", timeout=self.timeout)
            resp.raise_for_status()
            soup = BeautifulSoup(resp.text, "html.parser")
            watch_main = soup.select_one("#watch-main")
            anime_id = watch_main.get("data-id", "") if watch_main else ""

            ep_links = soup.select("#w-episodes a[data-num], #w-episodes a[href*='/watch/']")
            if not ep_links and anime_id:
                ajax_resp = self.session.get(
                    f"{self.base_url}/ajax/episode/list/{anime_id}",
                    headers={"X-Requested-With": "XMLHttpRequest", "Referer": f"{self.base_url}/watch/{slug}"},
                    timeout=self.timeout,
                )
                if ajax_resp.status_code == 200:
                    ep_html = ajax_resp.json().get("result", "")
                    ep_soup = BeautifulSoup(ep_html, "html.parser")
                    ep_links = ep_soup.select("a[data-num], a[href]")

            episodes = []
            seen_nums = set()
            for a in ep_links:
                raw_num = (
                    a.get("data-num")
                    or (a.select_one(".number, .d-title, span").get_text(strip=True) if a.select_one(".number, .d-title, span") else "")
                )
                try:
                    num_f = float(raw_num)
                    num = int(num_f) if num_f.is_integer() else num_f
                except Exception:
                    continue
                if num in seen_nums:
                    continue
                seen_nums.add(num)

                episodes.append({
                    "num": num,
                    "title": a.get("title") or f"Episode {raw_num}",
                    "data_ids": a.get("data-ids") or a.get("data-id") or "",
                    "data_mal": a.get("data-mal") or "",
                    "data_timestamp": a.get("data-timestamp") or "",
                    "has_sub": a.get("data-sub") == "1",
                    "has_dub": a.get("data-dub") == "1",
                    "slug": slug,
                })

            episodes.sort(key=lambda x: float(x["num"]))
            if episodes:
                self._cache_set(cache_key, episodes)
            return episodes
        except Exception as e:
            logger.error(f"[Anikoto] get_episodes error ({slug}): {e}")
            return []

    def get_servers(self, slug: str, ep_num: int, data_ids: str) -> List[Dict]:
        cache_key = f"anikoto_servers_{slug}_{ep_num}_{data_ids[:24]}"
        cached = self._cache_get(cache_key, ttl=900)
        if cached is not None:
            return cached

        servers = []
        if not data_ids:
            return servers

        try:
            resp = self.session.get(
                f"{self.base_url}/ajax/server/list",
                params={"servers": data_ids},
                headers={
                    "X-Requested-With": "XMLHttpRequest",
                    "Referer": f"{self.base_url}/watch/{slug}/ep-{ep_num}",
                },
                timeout=self.timeout,
            )
            resp.raise_for_status()
            html = (
                resp.json().get("result", "")
                if "json" in resp.headers.get("content-type", "")
                else resp.text
            )
            soup = BeautifulSoup(html, "html.parser")

            for el in soup.select("[data-link-id]"):
                link_id = el.get("data-link-id", "")
                if not link_id:
                    continue
                sv_id = el.get("data-sv-id", "")
                name = el.get_text(" ", strip=True) or "Server"
                type_parent = el.find_parent(class_="type")
                type_text = type_parent.get_text(" ", strip=True).lower() if type_parent else "sub"
                audio_type = "dub" if "dub" in type_text else ("raw" if "raw" in type_text else "sub")

                servers.append({
                    "name": name,
                    "type": audio_type,
                    "link_id": link_id,
                    "sv_id": sv_id,
                    "slug": slug,
                    "ep_num": ep_num,
                })

            self._cache_set(cache_key, servers)
            return servers
        except Exception as e:
            logger.error(f"[Anikoto] get_servers error ({slug} ep {ep_num}): {e}")
            return []

    def _get_megaplay_keys_and_ivs(self, host: str, html: str, referer: str) -> Tuple[List[bytes], List[bytes]]:
        now = time.time()
        if host in self._megaplay_script_cache:
            keys, ivs, ts = self._megaplay_script_cache[host]
            if now - ts < 1800:
                self._megaplay_script_cache.move_to_end(host)
                return keys, ivs
            self._megaplay_script_cache.pop(host, None)

        script_urls = [
            urljoin(f"https://{host}/", m.group(1))
            for m in re.finditer(r"<script[^>]+src=[\"']([^\"']+)[\"']", html, re.I)
        ]
        for su in script_urls:
            try:
                sc_resp = self.session.get(
                    su,
                    headers={"User-Agent": DEFAULT_UA, "Referer": referer},
                    timeout=8,
                )
                sc = sc_resp.text
                if "getSources" in sc and "AES-CBC" in sc:
                    raw_strs = [
                        m.group(2)
                        for m in re.finditer(r"([\"'])((?:\\.|(?!\1).){1,64})\1", sc)
                    ]
                    candidates = []
                    for rs in raw_strs:
                        try:
                            dec = bytes(rs, "utf-8").decode("unicode_escape")
                        except Exception:
                            dec = rs
                        if dec not in candidates:
                            candidates.append(dec)

                    ivs = [c.encode("utf-8") for c in candidates if len(c.encode("utf-8")) == 16]
                    keys = [c.encode("utf-8") for c in candidates if 0 < len(c.encode("utf-8")) <= 32]
                    self._megaplay_script_cache[host] = (keys, ivs, now)
                    self._megaplay_script_cache.move_to_end(host)
                    while len(self._megaplay_script_cache) > self._megaplay_script_cache_max:
                        self._megaplay_script_cache.popitem(last=False)
                    return keys, ivs
            except Exception as e:
                logger.debug(f"[MegaPlay] script fetch failed ({su}): {e}")

        return [], []

    def _decrypt_megaplay_enc(self, enc_b64: str, keys: List[bytes], ivs: List[bytes]) -> Optional[str]:
        if not enc_b64 or not keys or not ivs:
            return None
        padded = enc_b64 + "=" * ((4 - len(enc_b64) % 4) % 4)
        try:
            enc_bytes = base64.urlsafe_b64decode(padded)
        except Exception:
            return None

        if not enc_bytes or len(enc_bytes) % 16 != 0:
            return None

        for k in keys:
            key32 = k.ljust(32, b"\x00")
            for iv in ivs:
                try:
                    cipher = Cipher(algorithms.AES(key32), modes.CBC(iv))
                    decryptor = cipher.decryptor()
                    pt = decryptor.update(enc_bytes) + decryptor.finalize()
                    pad_len = pt[-1]
                    if 1 <= pad_len <= 16 and pt.endswith(bytes([pad_len]) * pad_len):
                        pt_str = pt[:-pad_len].decode("utf-8")
                        data = json.loads(pt_str)
                        src = (
                            data.get("file")
                            or data.get("url")
                            or (data.get("sources", {}) if isinstance(data.get("sources"), dict) else {}).get("file")
                        )
                        if isinstance(src, str) and src.startswith("http"):
                            return src
                except Exception:
                    continue
        return None

    def resolve_server_stream(self, server_info: Dict) -> Optional[Dict]:
        """Resolve an Anikoto server entry into an embedUrl + decrypted HLS m3u8 + subtitles"""
        link_id = server_info.get("link_id")
        sv_id = server_info.get("sv_id")
        slug = server_info.get("slug")
        ep_num = server_info.get("ep_num")
        if not link_id:
            return None

        cache_key = f"anikoto_stream_{link_id}_{sv_id}"
        cached = self._cache_get(cache_key, ttl=900)
        if cached is not None:
            return cached

        try:
            params = {"get": link_id}
            if sv_id:
                params["sv"] = sv_id
            ep_referer = f"{self.base_url}/watch/{slug}/ep-{ep_num}"
            resp = self.session.get(
                f"{self.base_url}/ajax/server",
                params=params,
                headers={"X-Requested-With": "XMLHttpRequest", "Referer": ep_referer},
                timeout=self.timeout,
            )
            resp.raise_for_status()
            res_data = resp.json().get("result", {})
            embed_url = res_data.get("url")
            skip_data = res_data.get("skip_data") or {}
            if not embed_url:
                return None

            # Normalize vidwish / bloggy mirrors to megaplay.buzz
            norm_url = (
                embed_url.replace("vidwish.live", "megaplay.buzz")
                .replace("megacloud.bloggy.click", "megaplay.buzz")
            )
            parsed = urlparse(norm_url)
            host = parsed.netloc
            embed_referer = f"https://{host}/"

            html_resp = self.session.get(
                norm_url,
                headers={"User-Agent": DEFAULT_UA, "Referer": self.base_url + "/"},
                timeout=self.timeout,
            )
            html = html_resp.text
            m_file = re.search(r"<title>File\s+(\d+)", html, re.I) or re.search(
                r'data-id=["\'](\d+)["\']', html
            )
            if not m_file:
                return {
                    "embed_url": embed_url,
                    "m3u8": None,
                    "subtitles": [],
                    "server": server_info.get("name", "Server"),
                    "type": server_info.get("type", "sub"),
                    "referer": embed_referer,
                }

            file_id = m_file.group(1)
            src_resp = self.session.get(
                f"https://{host}/stream/getSources",
                params={"id": file_id},
                headers={
                    "User-Agent": DEFAULT_UA,
                    "X-Requested-With": "XMLHttpRequest",
                    "Referer": norm_url,
                },
                timeout=self.timeout,
            )
            src_data = src_resp.json()

            subtitles = []
            for tr in src_data.get("tracks") or []:
                if tr.get("file") and tr.get("kind") in ("captions", "subtitles", None):
                    subtitles.append({
                        "url": tr["file"],
                        "lang": tr.get("label") or "English",
                        "default": bool(tr.get("default")),
                    })

            m3u8 = None
            raw_sources = src_data.get("sources")
            if isinstance(raw_sources, dict):
                m3u8 = raw_sources.get("file")
            elif isinstance(raw_sources, list) and raw_sources:
                m3u8 = raw_sources[0].get("file")

            if not m3u8 and src_data.get("enc"):
                keys, ivs = self._get_megaplay_keys_and_ivs(host, html, embed_referer)
                m3u8 = self._decrypt_megaplay_enc(src_data["enc"], keys, ivs)

            result = {
                "embed_url": embed_url,
                "m3u8": m3u8,
                "subtitles": subtitles,
                "intro": src_data.get("intro") or skip_data.get("intro"),
                "outro": src_data.get("outro") or skip_data.get("outro"),
                "server": server_info.get("name", "HD-1"),
                "type": server_info.get("type", "sub"),
                "referer": embed_referer,
            }
            if m3u8 or embed_url:
                self._cache_set(cache_key, result)
            return result
        except Exception as e:
            logger.error(f"[Anikoto] resolve_server_stream error: {e}")
            return None

    def get_kiwi_downloads(self, mal_id: str, ep_num: int, timestamp: str) -> Dict[str, Dict[str, str]]:
        """
        Query Kiwi Mapper (mapper.nekostream.site) for direct 360p/720p/1080p Pahe download links
        keyed by {'sub': {'360p': url, '720p': url, '1080p': url}, 'dub': {...}}
        """
        if not mal_id or not timestamp:
            return {}
        cache_key = f"kiwi_dl_{mal_id}_{ep_num}"
        cached = self._cache_get(cache_key, ttl=900)
        if cached is not None:
            return cached

        try:
            url = f"https://mapper.nekostream.site/api/mal/{mal_id}/{ep_num}/{timestamp}"
            resp = self.session.get(
                url,
                headers={"User-Agent": DEFAULT_UA, "Referer": f"{self.base_url}/", "Origin": self.base_url},
                timeout=8,
            )
            if resp.status_code != 200:
                return {}
            data = resp.json()
            kiwi = data.get("Kiwi") or {}
            downloads: Dict[str, Dict[str, str]] = {}
            for audio in ("sub", "dub"):
                dl_map = (kiwi.get(audio) or {}).get("download") or {}
                if isinstance(dl_map, dict) and dl_map:
                    downloads[audio] = {
                        q: u for q, u in dl_map.items() if isinstance(u, str) and u.startswith("http")
                    }
            self._cache_set(cache_key, downloads)
            return downloads
        except Exception as e:
            logger.debug(f"[Kiwi] mapper error: {e}")
            return {}


class YouTubeTrailerResolver:
    """Resolves official YouTube trailer IDs for anime preview playback"""

    CACHE_MAX_ENTRIES = 64

    def __init__(self):
        self.cache: OrderedDict[str, str] = OrderedDict()
        self.session = requests.Session()
        self.session.headers.update({"User-Agent": DEFAULT_UA})

    def get_trailer_id(self, title: str, anilist_trailer: Optional[Dict] = None) -> Optional[str]:
        # 1. Check AniList trailer object first
        if anilist_trailer and isinstance(anilist_trailer, dict):
            site = (anilist_trailer.get("site") or "").lower()
            vid = anilist_trailer.get("id")
            if site == "youtube" and vid:
                return vid

        if not title:
            return None
        key = title.lower().strip()
        if key in self.cache:
            self.cache.move_to_end(key)
            return self.cache[key]

        # 2. Live YouTube search scrape for official PV / trailer
        try:
            resp = self.session.get(
                "https://www.youtube.com/results",
                params={"search_query": f"{title} official anime trailer PV"},
                timeout=8,
            )
            if resp.status_code == 200:
                vids = list(dict.fromkeys(re.findall(r'"videoId":"([a-zA-Z0-9_-]{11})"', resp.text)))
                if vids:
                    self.cache[key] = vids[0]
                    self.cache.move_to_end(key)
                    while len(self.cache) > self.CACHE_MAX_ENTRIES:
                        self.cache.popitem(last=False)
                    return vids[0]
        except Exception as e:
            logger.warning(f"[YouTube] trailer search failed for '{title}': {e}")

        return None


class StreamingManager:
    """
    Unified orchestrator combining AnimeHeaven (Direct MP4 stream + download),
    Anikoto / MegaPlay (1080p Sub/Dub HLS + multi-subtitles), Kiwi/Pahe download links,
    and multi-embed fallbacks.
    """

    def __init__(self):
        self.animeheaven = AnimeHeavenProvider()
        self.anikoto = AnikotoProvider()
        self.youtube = YouTubeTrailerResolver()
        self.providers = {
            "animeheaven": self.animeheaven,
            "anikoto": self.anikoto,
        }
        self._mapping_cache: OrderedDict[str, Dict] = OrderedDict()
        self._mapping_cache_timestamps: Dict[str, float] = {}
        self._mapping_cache_max = 128
        self._mapping_cache_ttl = 900

    def resolve_anime_mapping(
        self,
        anilist_id: int,
        titles: List[str],
        mal_id: Optional[int] = None,
        heaven_override: Optional[str] = None,
    ) -> Dict:
        cache_key = f"map_{anilist_id}_{heaven_override or ''}"
        cached_at = self._mapping_cache_timestamps.get(cache_key, 0)
        if cache_key in self._mapping_cache and time.time() - cached_at < self._mapping_cache_ttl:
            self._mapping_cache.move_to_end(cache_key)
            return self._mapping_cache[cache_key]
        self._mapping_cache.pop(cache_key, None)
        self._mapping_cache_timestamps.pop(cache_key, None)

        clean_titles = [t for t in titles if t]
        heaven_id = heaven_override or self.animeheaven.find_best_id(clean_titles)
        anikoto_slug = self.anikoto.find_best_slug(clean_titles)

        mapping = {
            "anilist_id": anilist_id,
            "mal_id": mal_id,
            "titles": clean_titles,
            "heaven_id": heaven_id,
            "anikoto_slug": anikoto_slug,
        }
        self._mapping_cache[cache_key] = mapping
        self._mapping_cache_timestamps[cache_key] = time.time()
        self._mapping_cache.move_to_end(cache_key)
        while len(self._mapping_cache) > self._mapping_cache_max:
            expired_key, _ = self._mapping_cache.popitem(last=False)
            self._mapping_cache_timestamps.pop(expired_key, None)
        return mapping

    def get_full_episode_bundle(
        self,
        anilist_id: int,
        ep_num: int,
        titles: List[str],
        mal_id: Optional[int] = None,
        preferred_audio: str = "sub",
        heaven_override: Optional[str] = None,
    ) -> Dict:
        """
        Resolves all playable servers, direct MP4 streams, decrypted 1080p HLS streams,
        subtitles, and direct download links for a specific anime episode.
        """
        preferred_audio = preferred_audio if preferred_audio in ("sub", "dub") else "sub"
        mapping = self.resolve_anime_mapping(anilist_id, titles, mal_id, heaven_override)
        heaven_id = mapping.get("heaven_id")
        anikoto_slug = mapping.get("anikoto_slug")

        servers = []
        downloads = []
        heaven_ep_key = None
        heaven_info = None

        # 1. AnimeHeaven Direct MP4 Stream & Direct Download
        if heaven_id:
            heaven_info = self.animeheaven.get_anime_info(heaven_id)
            if heaven_info and heaven_info.get("episodes"):
                eps = heaven_info["episodes"]
                target_ep = next(
                    (e for e in eps if int(round(float(e["num"]))) == int(ep_num)),
                    None,
                )
                if target_ep:
                    heaven_ep_key = target_ep["key"]
                    st = self.animeheaven.get_streaming_sources(heaven_ep_key, referer_site_id=heaven_id)
                    for idx, src in enumerate(st.get("sources", [])):
                        _ref = src.get('referer', 'https://animeheaven.me/')
                        proxy_url = f"/api/proxy/video?url={quote(src['url'], safe='')}&ref={quote(_ref, safe='')}"
                        dl_url = f"/api/download/video?url={quote(src['url'], safe='')}&title={quote((titles[0] if titles else 'Anime') + f' - Ep {ep_num}', safe='')}&ref={quote(_ref, safe='')}"
                        servers.append({
                            "id": f"heaven-mp4-{idx+1}",
                            "name": f"AnimeHeaven {('Primary' if idx == 0 else f'Mirror {idx+1}')}",
                            "provider": "animeheaven",
                            "audio": "sub",
                            "playback_mode": "mp4",
                            "stream_url": proxy_url,
                            "raw_url": src["url"],
                            "download_url": dl_url,
                            "quality": "1080p MP4",
                            "subtitles": [],
                            "badge": "DIRECT MP4",
                        })
                        if idx == 0:
                            downloads.append({
                                "label": f"Episode {ep_num} Direct MP4 (AnimeHeaven High-Speed)",
                                "quality": "1080p / 720p MP4",
                                "audio": "SUB",
                                "url": dl_url,
                                "direct": True,
                                "provider": "AnimeHeaven",
                            })

        # 2. Anikoto / MegaPlay 1080p HLS (SUB & DUB) + Subtitles + Kiwi Downloads
        if anikoto_slug:
            ak_eps = self.anikoto.get_episodes(anikoto_slug)
            ak_ep = next(
                (e for e in ak_eps if int(round(float(e["num"]))) == int(ep_num)),
                None,
            )
            if ak_ep:
                ak_servers = self.anikoto.get_servers(anikoto_slug, ep_num, ak_ep.get("data_ids", ""))
                # Resolve top Sub and top Dub server eagerly so playback is instant,
                # and include remaining servers with on-demand or embed URLs
                resolved_per_audio = {"sub": 0, "dub": 0}
                for srv in ak_servers:
                    audio = srv.get("type", "sub")
                    if audio not in resolved_per_audio:
                        continue
                    if resolved_per_audio[audio] < 2:
                        stream_data = self.anikoto.resolve_server_stream(srv)
                        if stream_data:
                            resolved_per_audio[audio] = resolved_per_audio.get(audio, 0) + 1
                            m3u8 = stream_data.get("m3u8")
                            ref = stream_data.get("referer", "https://megaplay.buzz/")
                            subs = [
                                {
                                    "lang": s["lang"],
                                    "url": f"/api/proxy/subtitle?url={quote(s['url'], safe='')}&ref={quote(ref, safe='')}",
                                    "default": s.get("default", False),
                                }
                                for s in (stream_data.get("subtitles") or [])
                            ]
                            if m3u8:
                                hls_proxy = f"/api/proxy/hls?url={quote(m3u8, safe='')}&ref={quote(ref, safe='')}"
                                hls_dl = f"/api/download/video?url={quote(m3u8, safe='')}&title={quote((titles[0] if titles else 'Anime') + f' - Ep {ep_num} {audio.upper()}', safe='')}&ref={quote(ref, safe='')}"
                                servers.append({
                                    "id": f"anikoto-{audio}-{srv['name'].lower()}-{resolved_per_audio[audio]}",
                                    "name": f"CamStream {srv['name']} ({audio.upper()})",
                                    "provider": "anikoto",
                                    "audio": audio,
                                    "playback_mode": "hls",
                                    "stream_url": hls_proxy,
                                    "raw_url": m3u8,
                                    "download_url": hls_dl,
                                    "embed_url": stream_data.get("embed_url"),
                                    "quality": "1080p HLS",
                                    "subtitles": subs,
                                    "intro": stream_data.get("intro"),
                                    "outro": stream_data.get("outro"),
                                    "badge": f"1080p {audio.upper()}",
                                })
                                downloads.append({
                                    "label": f"Episode {ep_num} {audio.upper()} Stream File (same as playing)",
                                    "quality": "HLS playlist",
                                    "audio": audio.upper(),
                                    "url": hls_dl,
                                    "direct": True,
                                    "provider": f"CamStream {srv['name']}",
                                })
                            elif stream_data.get("embed_url"):
                                servers.append({
                                    "id": f"anikoto-embed-{audio}-{srv['name'].lower()}",
                                    "name": f"{srv['name']} Embed ({audio.upper()})",
                                    "provider": "anikoto",
                                    "audio": audio,
                                    "playback_mode": "iframe",
                                    "stream_url": stream_data["embed_url"],
                                    "quality": "HD Embed",
                                    "subtitles": [],
                                    "badge": f"EMBED {audio.upper()}",
                                })

                # Kiwi / AnimePahe Direct Download Mirrors
                eff_mal = ak_ep.get("data_mal") or (str(mal_id) if mal_id else "")
                eff_ts = ak_ep.get("data_timestamp") or ""
                if eff_mal and eff_ts:
                    kiwi_dls = self.anikoto.get_kiwi_downloads(eff_mal, ep_num, eff_ts)
                    for audio_key, q_map in kiwi_dls.items():
                        for q_label, dl_link in q_map.items():
                            downloads.append({
                                "label": f"Episode {ep_num} ({audio_key.upper()} · {q_label})",
                                "quality": q_label,
                                "audio": audio_key.upper(),
                                "url": dl_link,
                                "direct": False,
                                "provider": "AnimePahe / Kiwi Mirror",
                            })

        # A dubbed server is offered only when the provider lists that episode's
        # audio variant and resolves a real stream or provider player for it.
        audio_availability = {
            "sub": any(server.get("audio") == "sub" for server in servers),
            "dub": any(server.get("audio") == "dub" for server in servers),
        }

        # 3. No-title iframe fallbacks (verified reachable first). VidLink is
        # primary (HTTP 200); VidSrc stays only as a secondary mirror since
        # vidsrc.cc currently times out. Do not invent a DUB mirror.
        # Fallback-range ids (>= 900M, minted by Kitsu/Jikan adapters) have no
        # valid upstream embed id: VidLink needs a real MAL id, VidSrc a real
        # AniList id — so skip whichever fallback would be a bogus URL.
        try:
            _is_reserved = int(anilist_id) >= 900_000_000
        except (TypeError, ValueError):
            _is_reserved = True
        _mid = mal_id or (None if _is_reserved else anilist_id)
        if _mid:
            servers.append({
                "id": "embed-vidlink-sub",
                "name": "VidLink Ultra (SUB)",
                "provider": "vidlink",
                "audio": "sub",
                "playback_mode": "iframe",
                "stream_url": f"https://vidlink.pro/anime/{_mid}/{ep_num}/sub",
                "quality": "1080p Embed",
                "subtitles": [],
                "badge": "BACKUP SUB",
                "fallback": True,
            })
        if not _is_reserved:
            servers.append({
                "id": "embed-vidsrc-sub",
                "name": "VidSrc Pro (SUB)",
                "provider": "vidsrc",
                "audio": "sub",
                "playback_mode": "iframe",
                "stream_url": f"https://vidsrc.cc/v2/embed/anime/ani{anilist_id}/{ep_num}/sub",
                "quality": "1080p Embed",
                "subtitles": [],
                "badge": "MIRROR SUB",
                "fallback": True,
            })

        # Sort servers so preferred_audio comes first, and direct MP4/HLS comes before iframe
        def server_priority(s: Dict) -> Tuple[int, int]:
            audio_match = 0 if s.get("audio") == preferred_audio else 1
            mode_rank = 0 if s.get("playback_mode") in ("hls", "mp4") else 1
            return (audio_match, mode_rank)

        servers.sort(key=server_priority)

        # Download manager promise: EVERY episode must offer at least one
        # direct-file download path. When no scraper resolved a file, hand the
        # watcher a one-click resolver that scrapes AnimeHeaven for this exact
        # title, instead of a dead end.
        if not downloads:
            _q = quote((titles[0] if titles else f"anime {anilist_id}"), safe="")
            downloads.append({
                "label": f"Episode {ep_num} — resolve direct MP4 via AnimeHeaven Scraper",
                "quality": "Scraper resolver",
                "audio": ("DUB" if audio_availability["dub"] and preferred_audio == "dub" else "SUB"),
                "url": f"/scraper?q={_q}&auto_resolve={ep_num}",
                "direct": False,
                "provider": "AnimeHeaven resolver",
            })

        return {
            "anilist_id": anilist_id,
            "mal_id": mal_id,
            "episode": ep_num,
            "heaven_id": heaven_id,
            "heaven_ep_key": heaven_ep_key,
            "anikoto_slug": anikoto_slug,
            "servers": servers,
            "downloads": downloads,
            "audio_availability": audio_availability,
            "requested_audio": preferred_audio,
            "audio_fallback": preferred_audio == "dub" and not audio_availability["dub"],
            "active_server": next(
                (server for server in servers if server.get("audio") == preferred_audio),
                servers[0] if servers else None,
            ),
        }

    # Backwards-compatible methods
    def search(self, query: str, provider: Optional[str] = None) -> Dict:
        prov = provider or "animeheaven"
        if prov == "animeheaven":
            res = self.animeheaven.search(query)
            if res:
                return {"provider": "animeheaven", "results": res, "status": "success"}
        res_ak = self.anikoto.search(query)
        if res_ak:
            return {"provider": "anikoto", "results": res_ak, "status": "fallback"}
        return {"error": "No results found", "results": [], "status": "failed"}

    def get_episodes(self, anime_id: str, provider: Optional[str] = None) -> Dict:
        eps, title = self.animeheaven.get_episodes(anime_id)
        if eps:
            return {
                "provider": "animeheaven",
                "anime_id": anime_id,
                "title": title,
                "episodes": eps,
                "total": len(eps),
                "status": "success",
            }
        return {"error": "No episodes found", "episodes": [], "status": "failed"}

    def get_streaming_sources(
        self,
        episode_id: str,
        provider: Optional[str] = None,
        fallback_providers: Optional[List[str]] = None,
    ) -> Dict:
        res = self.animeheaven.get_streaming_sources(episode_id)
        if res.get("sources"):
            res["status"] = "success"
            return res
        return {
            "sources": [],
            "subtitles": [],
            "provider": provider or "animeheaven",
            "status": "failed",
            "error": "No streaming sources found",
        }

    def clear_cache(self):
        self.animeheaven.cache.clear()
        self.anikoto.cache.clear()
        self.anikoto._megaplay_script_cache.clear()
        self.youtube.cache.clear()
        self._mapping_cache.clear()
        self._mapping_cache_timestamps.clear()


# Global instance
streaming_manager = StreamingManager()
