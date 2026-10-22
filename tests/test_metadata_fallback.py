"""Offline tests for the free fallback metadata layer (Kitsu -> Jikan).

All network accessors are monkeypatched: these tests never touch AniList,
Kitsu or Jikan and pass even during an upstream outage.
"""

import sys
from pathlib import Path
from unittest.mock import patch

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import app as api  # noqa: E402


KITSU_ITEM = {
    "id": "1555",
    "attributes": {
        "canonicalTitle": "Naruto: Shippuden",
        "titles": {"en": "Naruto: Shippuden", "en_jp": "Naruto Shippuden",
                   "ja_jp": "ナルト 疾風伝"},
        "synopsis": "Two and a half years of training.",
        "posterImage": {"large": "https://example.com/n.jpg", "original": "https://example.com/n.jpg"},
        "coverImage": {"large": "https://example.com/b.jpg"},
        "episodeCount": 500,
        "episodeLength": 23,
        "status": "finished",
        "subtype": "TV",
        "startDate": "2007-02-15",
        "averageRating": "84.5",
        "userCount": 100000,
        "youtubeVideoId": "abc123",
    },
}

JIKAN_ITEM = {
    "mal_id": 20,
    "title": "Naruto",
    "title_english": "Naruto",
    "title_japanese": "ナルト",
    "images": {"jpg": {"large_image_url": "https://example.com/m.jpg"}},
    "synopsis": "A ninja story. [Written by MAL Rewrite]",
    "episodes": 220,
    "duration": "24 min per ep",
    "status": "Finished Airing",
    "type": "TV",
    "season": "fall",
    "year": 2002,
    "score": 8.0,
    "members": 2000000,
    "genres": [{"name": "Action"}],
    "studios": [{"name": "Pierrot"}],
    "trailer": {"youtube_id": "xyz789"},
    "broadcast": {"day": "Thursdays", "time": "19:30", "timezone": "Asia/Tokyo"},
}


def _client():
    api.app.config["TESTING"] = True
    return api.app.test_client()


def test_kitsu_adapter_shape():
    media = api._kitsu_to_media(KITSU_ITEM)
    assert media["id"] == api.KITSU_ID_OFFSET + 1555
    assert media["title"]["english"] == "Naruto: Shippuden"
    assert media["status"] == "FINISHED"
    assert media["format"] == "TV"
    assert media["seasonYear"] == 2007
    assert media["season"] == "WINTER"
    assert media["episodes"] == 500
    assert media["averageScore"] == 84
    card = api.format_anime_card(media)
    assert card["title"] == "Naruto: Shippuden"
    assert card["id"] == media["id"]


def test_jikan_adapter_shape():
    media = api._jikan_to_media(JIKAN_ITEM)
    assert media["id"] == api.JIKAN_ID_OFFSET + 20
    assert media["idMal"] == 20
    assert media["title"]["english"] == "Naruto"
    assert media["status"] == "FINISHED"
    assert media["duration"] == 24
    assert media["averageScore"] == 80
    assert media["genres"] == ["Action"]
    assert "[Written by MAL Rewrite]" not in media["description"]
    card = api.format_anime_card(media)
    assert card["title"] == "Naruto"


def test_fallback_ids_never_collide_with_anilist():
    assert api._is_fallback_id(api.KITSU_ID_OFFSET + 1)
    assert api._is_fallback_id(api.JIKAN_ID_OFFSET + 1)
    assert not api._is_fallback_id(21)
    assert not api._is_fallback_id(None)


def test_fallback_home_lists_prefers_kitsu(monkeypatch):
    monkeypatch.setattr(api, "_kitsu_get",
                        lambda path, params=None: [KITSU_ITEM] if "mappings" not in path else [])
    called = []

    def _fail(path, params=None):
        called.append(path)
        raise AssertionError("Jikan must not be called when Kitsu answers")

    monkeypatch.setattr(api, "_jikan_get", _fail)
    lists, source = api._fallback_home_lists()
    assert source == "kitsu"
    assert lists["trending"][0]["title"]["english"] == "Naruto: Shippuden"


def test_fallback_search_uses_jikan_when_kitsu_empty(monkeypatch):
    monkeypatch.setattr(api, "_kitsu_get", lambda path, params=None: [])
    monkeypatch.setattr(api, "_jikan_get", lambda path, params=None: [JIKAN_ITEM])
    media, source = api._fallback_search_media("naruto", limit=5)
    assert source == "jikan"
    assert media[0]["idMal"] == 20


def test_media_titles_merges_synonyms():
    media = api._jikan_to_media(JIKAN_ITEM)
    titles = api._media_titles(media)
    assert titles[0] == "Naruto"
    assert "Naruto" in titles
    assert api._media_titles({}) == []
    assert api._media_titles(None) == []


def test_home_lists_include_ongoing_and_recent(monkeypatch):
    def _kitsu(path, params=None):
        params = params or {}
        if "mappings" in path:
            return []
        if params.get("filter[status]") == "current":
            return [KITSU_ITEM]
        if "filter[season]" in params:
            return [KITSU_ITEM]
        return [KITSU_ITEM]

    monkeypatch.setattr(api, "_kitsu_get", _kitsu)
    monkeypatch.setattr(api, "_jikan_get", lambda path, params=None: [])
    lists, source = api._fallback_home_lists()
    assert source == "kitsu"
    assert lists["ongoing"][0]["title"]["english"] == "Naruto: Shippuden"
    assert lists["recent"][0]["title"]["english"] == "Naruto: Shippuden"
    assert lists["popular"][0]["status"] == "FINISHED"


def test_home_uses_fallback_when_anilist_down(monkeypatch):
    monkeypatch.setattr(api, "fetch_anilist", lambda *a, **k: {})
    monkeypatch.setattr(api, "_fallback_home_lists",
                        lambda: ({"trending": [api._kitsu_to_media(KITSU_ITEM)],
                                  "popular": [], "top_rated": [], "movies": []}, "kitsu"))
    monkeypatch.setattr(api.streaming_manager.animeheaven, "browse_catalog", lambda feed="new": [])
    resp = _client().get("/")
    assert resp.status_code == 200
    assert b"Naruto" in resp.data


def test_details_uses_fallback_media_for_cached_title(monkeypatch):
    monkeypatch.setattr(api, "fetch_anilist", lambda *a, **k: {})
    monkeypatch.setattr(api.platform, "get_anime_meta",
                        lambda ids: {900001: {"title": "Naruto", "image": "", "banner": "",
                                              "format": "TV", "status": "Finished", "year": 2002,
                                              "episode_label": ""}})
    monkeypatch.setattr(api, "_fallback_media_by_title",
                        lambda title: (api._jikan_to_media(JIKAN_ITEM), "jikan"))
    monkeypatch.setattr(api.streaming_manager.youtube, "get_trailer_id", lambda *a: None)
    monkeypatch.setattr(api.streaming_manager, "resolve_anime_mapping",
                        lambda *a, **k: {"heaven_id": None, "anikoto_slug": None})
    resp = _client().get("/anime/900001")
    assert resp.status_code == 200
    assert b"Naruto" in resp.data


def test_reserved_id_decodes_directly_without_cache(monkeypatch):
    single = {"id": "1555", "attributes": KITSU_ITEM["attributes"]}
    monkeypatch.setattr(api, "_kitsu_get", lambda path, params=None: single)
    monkeypatch.setattr(api, "_kitsu_mal_id", lambda kid: 269)
    media, source = api._fallback_media_by_reserved_id(api.KITSU_ID_OFFSET + 1555)
    assert source == "kitsu"
    assert media["title"]["english"] == "Naruto: Shippuden"
    assert media["idMal"] == 269
    assert media["id"] == api.KITSU_ID_OFFSET + 1555
    assert api._fallback_media_by_reserved_id(21) == ({}, "")


def test_watch_uses_fallback_titles_and_mal_for_mapping(monkeypatch):
    rid = api.JIKAN_ID_OFFSET + 20
    assert api._is_fallback_id(rid)
    monkeypatch.setattr(api, "fetch_anilist", lambda *a, **k: {})
    monkeypatch.setattr(api.platform, "get_anime_meta",
                        lambda ids: {rid: {"title": "Naruto", "image": "", "banner": "",
                                          "format": "TV", "status": "Finished", "year": 2002,
                                          "episode_label": ""}})
    monkeypatch.setattr(api, "_fallback_media_by_title",
                        lambda title: (api._jikan_to_media(JIKAN_ITEM), "jikan"))
    seen = {}

    def _mapping(anime_id, titles, mal_id=None, heaven_override=None):
        seen.update(titles=titles, mal_id=mal_id)
        return {"heaven_id": None, "anikoto_slug": None}

    monkeypatch.setattr(api.streaming_manager, "resolve_anime_mapping", _mapping)
    monkeypatch.setattr(api.streaming_manager.youtube, "get_trailer_id", lambda *a: None)
    monkeypatch.setattr(api.streaming_manager, "get_full_episode_bundle",
                        lambda **k: {"servers": [], "downloads": [],
                                     "audio_availability": {"sub": False, "dub": False}})
    resp = _client().get(f"/watch/{rid}/1")
    # No provider servers and reserved id -> honest redirect to details.
    assert resp.status_code == 302
    assert "Naruto" in seen["titles"]
    assert seen["mal_id"] == 20


def test_v1_search_falls_back_to_kitsu(monkeypatch):
    monkeypatch.setattr(api, "fetch_anilist", lambda *a, **k: {})
    monkeypatch.setattr(api, "_fallback_search_media",
                        lambda q, limit=12: ([api._kitsu_to_media(KITSU_ITEM)], "kitsu"))
    resp = _client().get("/api/v1/search?q=naruto")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["status"] == "success"
    assert body["catalog_source"] == "Kitsu"
    assert body["results"]


def test_v1_genre_falls_back_to_kitsu(monkeypatch):
    monkeypatch.setattr(api, "fetch_anilist", lambda *a, **k: {})
    monkeypatch.setattr(api, "_kitsu_get",
                        lambda path, params=None: [KITSU_ITEM] if "categories" in str(params) else [])
    resp = _client().get("/api/v1/genres/action/anime")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["status"] == "success"
    assert body["catalog_source"] == "Kitsu"
