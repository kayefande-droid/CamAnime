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
    maps = [{"attributes": {"externalId": "269"}}]
    calls = []

    def _kitsu(path, params=None):
        calls.append(path)
        return maps if "mappings" in path else single

    monkeypatch.setattr(api, "_kitsu_get", _kitsu)
    media, source = api._fallback_media_by_reserved_id(api.KITSU_ID_OFFSET + 1555)
    assert source == "kitsu"
    assert media["title"]["english"] == "Naruto: Shippuden"
    assert media["idMal"] == 269
    assert media["id"] == api.KITSU_ID_OFFSET + 1555
    # Record + MAL mapping resolve concurrently: exactly two upstream reads,
    # no extra sequential hop (lag reduction for cold watch pages).
    assert sorted(calls) == sorted(["/anime/1555", "/anime/1555/mappings"])
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


def test_detector_recovers_and_clears_stale_fallback_cache(monkeypatch):
    api._fallback_cache_set("kitsu_probe_row", {"stale": True})
    api._fallback_cache_set("jikan_probe_row", {"stale": True})
    api._fallback_cache_set("probe_anilist_row", {"fresh": True})
    try:
        class _Resp:
            def raise_for_status(self):
                pass

            def json(self):
                return {"data": {"Page": {"media": [{"id": 1}]}}}

        monkeypatch.setattr(api.requests, "post", lambda *a, **k: _Resp())
        with api._ANILIST_STATUS_LOCK:
            api._ANILIST_STATUS.update({"available": False, "last_check": 0.0,
                                        "last_success": 0.0, "consecutive_failures": 5})
        assert api.check_anilist_availability(force=True) is True
        snap = api._anilist_detector_snapshot()
        assert snap["available"] is True
        assert snap["consecutive_failures"] == 0
        assert snap["last_success"] > 0
        # Stale fallback rows are evicted so AniList resumes immediately;
        # genuine AniList cache entries are kept.
        assert api._fallback_cache_get("kitsu_probe_row") is None
        assert api._fallback_cache_get("jikan_probe_row") is None
        assert api._fallback_cache_get("probe_anilist_row") == {"fresh": True}
    finally:
        with api._FALLBACK_CACHE_LOCK:
            for key in ("kitsu_probe_row", "jikan_probe_row", "probe_anilist_row"):
                api._anilist_cache.pop(key, None)


def test_detector_reports_down(monkeypatch):
    def _boom(*a, **k):
        raise ConnectionError("anilist down")

    monkeypatch.setattr(api.requests, "post", _boom)
    with api._ANILIST_STATUS_LOCK:
        api._ANILIST_STATUS.update({"available": True, "last_check": 0.0,
                                    "last_success": 1.0, "consecutive_failures": 0})
    assert api.check_anilist_availability(force=True) is False
    assert api._anilist_detector_snapshot()["available"] is False


def test_health_reports_detector_state():
    resp = _client().get("/api/v1/health")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["catalog_source"] == "AniList"
    assert body["anilist_detector_interval_seconds"] == api._ANILIST_DETECTOR_INTERVAL
    assert isinstance(body["fallback_active"], bool)
    assert "anilist_available" in body


def test_unfiltered_browse_falls_back_when_anilist_down(monkeypatch):
    monkeypatch.setattr(api, "fetch_anilist", lambda *a, **k: {})
    monkeypatch.setattr(api, "_fallback_home_lists",
                        lambda: ({"trending": [api._kitsu_to_media(KITSU_ITEM)]}, "kitsu"))
    resp = _client().get("/api/v1/anime?page=1&limit=5")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["status"] == "success"
    assert body["catalog_source"] == "Kitsu"
    assert len(body["results"]) == 1


def test_format_browse_falls_back_when_anilist_down(monkeypatch):
    monkeypatch.setattr(api, "fetch_anilist", lambda *a, **k: {})
    monkeypatch.setattr(api, "_kitsu_get", lambda path, params=None: [KITSU_ITEM])
    resp = _client().get("/api/v1/anime?format=TV")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["status"] == "success"
    assert body["catalog_source"] == "Kitsu"
    assert body["results"]


def test_catalog_home_fallback_has_series_row(monkeypatch):
    def _kitsu(path, params=None):
        if "mappings" in path:
            return []
        return [KITSU_ITEM]

    monkeypatch.setattr(api, "fetch_anilist", lambda *a, **k: {})
    monkeypatch.setattr(api, "_kitsu_get", _kitsu)
    monkeypatch.setattr(api, "_jikan_get", lambda path, params=None: [])
    resp = _client().get("/api/v1/catalog/home")
    assert resp.status_code == 200
    catalog = resp.get_json()["catalog"]
    assert catalog["series"], "fallback catalogue must keep the series row"
    assert catalog["ongoing"], "fallback catalogue must keep the ongoing row"


def test_ongoing_series_watch_plays_video(monkeypatch):
    """New ongoing series streams via fallback exactly like via AniList."""
    import copy
    attrs = copy.deepcopy(KITSU_ITEM["attributes"])
    attrs["canonicalTitle"] = "Ongoing Saga"
    attrs["titles"] = {"en": "Ongoing Saga", "en_jp": "Ongoing Saga",
                        "ja_jp": ""}
    attrs["status"] = "current"
    attrs["episodeCount"] = None
    single = {"id": "9999", "attributes": attrs}
    maps = [{"attributes": {"externalId": "21"}}]
    rid = api.KITSU_ID_OFFSET + 9999

    monkeypatch.setattr(api, "fetch_anilist", lambda *a, **k: {})
    monkeypatch.setattr(api, "_kitsu_get",
                        lambda path, params=None: maps if "mappings" in path else single)
    monkeypatch.setattr(api.streaming_manager.youtube, "get_trailer_id", lambda *a: None)
    monkeypatch.setattr(api.streaming_manager, "resolve_anime_mapping",
                        lambda *a, **k: {"heaven_id": "h1", "anikoto_slug": "a1"})
    monkeypatch.setattr(api.streaming_manager.animeheaven, "get_anime_info",
                        lambda site_id: {"episodes": [{"num": 1}, {"num": 2}]})
    monkeypatch.setattr(api.streaming_manager.anikoto, "get_episodes", lambda slug: [])
    server = {"id": "s1", "name": "Heaven HD", "provider": "animeheaven",
              "audio": "sub", "playback_mode": "direct",
              "stream_url": "https://cdn.example/ongoing-s1e1.mp4",
              "quality": "1080p", "subtitles": []}
    monkeypatch.setattr(api.streaming_manager, "get_full_episode_bundle",
                        lambda **k: {"servers": [server], "downloads": [server],
                                     "active_server": server,
                                     "audio_availability": {"sub": True, "dub": False}})
    resp = _client().get(f"/watch/{rid}/1")
    assert resp.status_code == 200
    assert b"Ongoing Saga" in resp.data
    # The playable video URL is rendered into the player.
    assert b"https://cdn.example/ongoing-s1e1.mp4" in resp.data
    src = _client().get(f"/api/episode-sources/{rid}/1")
    assert src.status_code == 200
    servers = src.get_json()["servers"]
    assert servers and servers[0]["stream_url"].startswith("https://")
