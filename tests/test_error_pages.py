"""Regression tests for website improvements: branded error pages, skip links.

Streaming paths are untouched by these changes; this file only pins the new
behaviour so future edits can't silently drop it.
"""

import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import app as api  # noqa: E402


def _client():
    api.app.config["TESTING"] = True
    return api.app.test_client()


def test_404_page_is_branded():
    resp = _client().get("/no-such-page-anywhere-xyz")
    assert resp.status_code == 404
    assert b"CamAnime" in resp.data
    assert b"404" in resp.data
    assert b"Back to Discover" in resp.data


def test_api_404_stays_json():
    resp = _client().get("/api/definitely-not-a-route")
    assert resp.status_code == 404
    body = resp.get_json()
    assert body["status"] == "error"


def test_scanner_paths_still_404():
    assert _client().get("/.env").status_code == 404


class _NotFoundUpstream:
    """AniList GraphQL explicit Not Found: HTTP 200 + null Media + error."""
    def raise_for_status(self):
        pass

    def json(self):
        return {"data": {"Media": None},
                "errors": [{"message": "Not Found.", "status": 404}]}


def test_details_returns_404_when_anilist_says_not_found():
    """SEO: nonexistent anime must 404, not serve a thin soft-404 200 page."""
    api._anilist_cache.clear()
    api._anilist_missing_keys.clear()
    with patch.object(api.requests, "post", return_value=_NotFoundUpstream()):
        resp = _client().get("/anime/999999")
    assert resp.status_code == 404
    assert b"noindex" in resp.data


def test_watch_returns_404_when_anilist_says_not_found():
    api._anilist_cache.clear()
    api._anilist_missing_keys.clear()
    with patch.object(api.requests, "post", return_value=_NotFoundUpstream()):
        resp = _client().get("/watch/999999/1")
    assert resp.status_code == 404


def test_details_keeps_fallback_on_outage_not_404():
    """SEO safety: outage fallback remains a 200 page without inventing episode counts."""
    api._anilist_cache.clear()
    api._anilist_missing_keys.clear()

    def _down(*args, **kwargs):
        raise ConnectionError("anilist down")

    with patch.object(api.requests, "post", side_effect=_down), \
         patch.object(api.platform, "get_anime_meta", return_value={}), \
         patch.object(api.streaming_manager, "resolve_anime_mapping", return_value={}), \
         patch.object(api.streaming_manager.youtube, "get_trailer_id", return_value=None):
        resp = _client().get("/anime/999999")
    assert resp.status_code == 200
    assert b'"numberOfEpisodes"' not in resp.data
    assert b"Released episodes (0)" in resp.data


def test_500_handler_is_registered():
    assert 500 in api.app.error_handler_spec[None]
    assert 404 in api.app.error_handler_spec[None]


def test_robots_is_cached():
    resp = _client().get("/robots.txt")
    assert resp.status_code == 200
    assert "max-age" in resp.headers.get("Cache-Control", "")


def test_sitemap_uses_canonical_indexable_routes_without_unreliable_lastmod(monkeypatch, tmp_path):
    monkeypatch.setattr(api.platform, "DB_PATH", str(tmp_path / "seo-sitemap.db"))
    api.platform._init()
    client = _client()
    api.platform.cache_anime_meta(123, title="Unverified client title")
    api.platform.cache_anime_meta(124, title="Verified catalogue title", catalogue_verified=True)
    response = client.get("/sitemap.xml")
    assert response.status_code == 200
    assert response.mimetype == "application/xml"
    root = ET.fromstring(response.data)
    ns = {"sm": "http://www.sitemaps.org/schemas/sitemap/0.9"}
    locations = [node.text for node in root.findall("sm:url/sm:loc", ns)]
    assert "https://camanime.onrender.com/" in locations
    assert "https://camanime.onrender.com/scraper" in locations
    assert "https://camanime.onrender.com/download" in locations
    assert "https://camanime.onrender.com/promo" in locations
    assert "https://camanime.onrender.com/anime/124" in locations
    assert "https://camanime.onrender.com/anime/123" not in locations
    assert all(loc.startswith("https://camanime.onrender.com/") for loc in locations)
    assert len(locations) == len(set(locations))
    assert not any("?" in loc or any(path in loc for path in ("/api/", "/login", "/admin", "/settings", "/get/")) for loc in locations)
    assert not response.data.count(b"<lastmod>")


def test_catalogue_verified_flag_survives_unverified_metadata_refresh(monkeypatch, tmp_path):
    monkeypatch.setattr(api.platform, "DB_PATH", str(tmp_path / "seo-cache.db"))
    api.platform._init()
    api.platform.cache_anime_meta(125, title="Verified", catalogue_verified=True)
    api.platform.cache_anime_meta(125, title="Updated by a client event", cache_title=False)
    response = _client().get("/sitemap.xml")
    root = ET.fromstring(response.data)
    ns = {"sm": "http://www.sitemaps.org/schemas/sitemap/0.9"}
    locations = [node.text for node in root.findall("sm:url/sm:loc", ns)]
    assert "https://camanime.onrender.com/anime/125" in locations
    metadata = api.platform.get_anime_meta([125])[125]
    assert metadata["title"] == "Verified"


def test_schedule_redirect_target_is_the_indexed_home_route():
    response = _client().get("/schedule", follow_redirects=False)
    assert response.status_code == 302
    assert response.headers["Location"].endswith("/?schedule=open")
    assert _client().get(response.headers["Location"]).status_code == 200


def test_home_has_skip_link_and_main_landmark(monkeypatch):
    monkeypatch.setattr(api, "fetch_anilist", lambda *a, **k: {})
    monkeypatch.setattr(api, "_fallback_home_lists", lambda: ({}, ""))
    monkeypatch.setattr(api.streaming_manager.animeheaven, "browse_catalog",
                        lambda feed="new": [])
    with patch.object(api, "get_current_season_schedule", return_value=[]):
        resp = _client().get("/")
    assert resp.status_code == 200
    assert b"skip-link" in resp.data
    assert b'main-content' in resp.data


def test_details_and_watch_templates_have_skip_links():
    root = Path(__file__).resolve().parent.parent / "templates"
    for name in ("details.html", "watch.html", "index.html"):
        text = (root / name).read_text(encoding="utf-8")
        assert "skip-link" in text, name
        assert "main-content" in text, name
