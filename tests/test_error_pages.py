"""Regression tests for website improvements: branded error pages, skip links.

Streaming paths are untouched by these changes; this file only pins the new
behaviour so future edits can't silently drop it.
"""

import sys
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
    """SEO safety: a transport error is not proof of nonexistence — keep 200."""
    api._anilist_cache.clear()
    api._anilist_missing_keys.clear()

    def _down(*args, **kwargs):
        raise ConnectionError("anilist down")

    with patch.object(api.requests, "post", side_effect=_down):
        resp = _client().get("/anime/999999")
    assert resp.status_code == 200


def test_500_handler_is_registered():
    assert 500 in api.app.error_handler_spec[None]
    assert 404 in api.app.error_handler_spec[None]


def test_robots_is_cached():
    resp = _client().get("/robots.txt")
    assert resp.status_code == 200
    assert "max-age" in resp.headers.get("Cache-Control", "")


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
