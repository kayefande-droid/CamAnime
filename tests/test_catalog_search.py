"""Regression tests for the search/genre catalogue endpoints."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import app  # noqa: E402



def _client():
    app.config["TESTING"] = True
    return app.test_client()


def test_search_returns_results():
    resp = _client().get("/api/v1/search?q=naruto")
    assert resp.status_code == 200, resp.get_data(as_text=True)[:200]
    payload = resp.get_json()
    assert payload["status"] == "success"
    assert payload["results"], "search must return at least one anime"
    first = payload["results"][0]
    assert first["id"], "result must carry the AniList id"
    assert "naruto" in (first.get("title") or "").lower()


def test_genre_endpoint_returns_results():
    resp = _client().get("/api/v1/genres/action/anime")
    assert resp.status_code == 200, resp.get_data(as_text=True)[:200]
    body = resp.get_json()
    assert body["status"] == "success" and body["results"]


def test_empty_search_is_rejected():
    assert _client().get("/api/v1/search?q=").status_code == 400


def test_oversized_search_is_rejected():
    assert _client().get("/api/v1/search?q=" + "a" * 101).status_code == 400


def test_unknown_genre_is_rejected():
    assert _client().get("/api/v1/genres/definitely-not-a-genre/anime").status_code == 404
