import importlib
import sys
from pathlib import Path
from unittest.mock import patch

import pytest


ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture()
def api(tmp_path, monkeypatch):
    monkeypatch.setenv("CAMANIME_DB", str(tmp_path / "test.db"))
    monkeypatch.delenv("CAMANIME_ADMIN_EMAIL", raising=False)
    monkeypatch.delenv("CAMANIME_ADMIN_PASSWORD", raising=False)
    sys.path.insert(0, str(ROOT))
    sys.modules.pop("app", None)
    sys.modules.pop("camanime_platform", None)
    module = importlib.import_module("app")
    module.app.config.update(TESTING=True)
    yield module
    sys.modules.pop("app", None)
    sys.modules.pop("camanime_platform", None)
    if str(ROOT) in sys.path:
        sys.path.remove(str(ROOT))


def anime(anime_id=123, title="Canonical", banner="https://img.example/banner.jpg"):
    return {
        "id": anime_id,
        "idMal": 456,
        "title": {"english": title, "romaji": "Canonical Romaji", "native": "原題"},
        "description": "Short synopsis",
        "coverImage": {"large": "https://img.example/poster.jpg", "extraLarge": "https://img.example/poster-xl.jpg"},
        "bannerImage": banner,
        "episodes": 12,
        "status": "FINISHED",
        "format": "TV",
        "seasonYear": 2024,
        "averageScore": 87,
        "genres": ["Action", "Fantasy"],
        "studios": {"nodes": []},
        "streamingEpisodes": [],
    }


def test_download_page_exposes_copyable_android_url_and_direct_download(api):
    client = api.app.test_client()
    page = client.get("/download")
    assert page.status_code == 200
    assert b'id="android-download-url"' in page.data
    assert b'value="http://localhost/get/android"' in page.data
    assert b'id="copy-android-url"' in page.data
    assert b'navigator.clipboard.writeText(field.value)' in page.data

    apk = client.head("/get/android")
    assert apk.status_code == 200
    assert "attachment" in apk.headers["Content-Disposition"]
    apk_path = Path(api.app.static_folder or "static") / "downloads" / "CamAnime.apk"
    assert apk.headers["Content-Length"] == str(apk_path.stat().st_size)

    version = client.get("/api/version")
    assert version.status_code == 200
    assert version.json["app_version"] == "1.2.0"
    assert version.json["apk_url"] == "/get/android"


def test_health_is_versioned(api):
    response = api.app.test_client().get("/api/v1/health")
    assert response.status_code == 200
    assert response.json["api_version"] == "v1"
    assert response.json["catalog_source"] == "AniList"


def test_home_catalog_normalizes_canonical_ids_and_real_feed_rows(api):
    payload = {
        "trending": {"media": [anime()]},
        "popularSeason": {"media": [anime(anime_id=321, title="Seasonal")]},
        "topRated": {"media": []},
        "recentlyAdded": {"media": []},
        "featuredMovie": {"media": []},
        "series": {"media": []},
    }
    with patch.object(api, "fetch_anilist", return_value=payload):
        response = api.app.test_client().get("/api/v1/catalog/home")
    assert response.status_code == 200
    catalog = response.json["catalog"]
    assert catalog["trending"][0]["id"] == 123
    assert catalog["featured"]["id"] == 123
    assert catalog["featured"]["image"] == "https://img.example/poster-xl.jpg"
    assert catalog["featured"]["genres"] == ["Action", "Fantasy"]
    assert "Anime Studio" not in str(catalog)


def test_search_validates_and_returns_catalogue_schema(api):
    payload = {"Page": {"media": [anime()]}}
    with patch.object(api, "fetch_anilist", return_value=payload) as fetch:
        response = api.app.test_client().get("/api/v1/search?q=Canonical&limit=3")
    assert response.status_code == 200
    assert response.json["results"][0]["id"] == 123
    assert response.json["limit"] == 3
    assert fetch.call_args.args[1]["search"] == "Canonical"

    missing_query = api.app.test_client().get("/api/v1/search")
    assert missing_query.status_code == 400
    assert missing_query.json["status"] == "error"
    assert isinstance(missing_query.json["error"], dict)


def test_episode_metadata_does_not_claim_playback_or_download_rights(api):
    raw = anime()
    raw["streamingEpisodes"] = [{
        "title": "Episode 1", "thumbnail": "https://img.example/ep.jpg",
        "url": "https://provider.example/metadata", "site": "Metadata Provider",
    }]
    with patch.object(api, "fetch_anilist", return_value={"Media": raw}):
        response = api.app.test_client().get("/api/v1/anime/123/episodes")
    assert response.status_code == 200
    assert response.json["episodes"][0]["playable"] is False
    assert response.json["episodes"][0]["download_allowed"] is False
    assert response.json["download_available"] is False
    assert "url" not in response.json["episodes"][0]


def test_anime_detail_uses_canonical_provider_id(api):
    with patch.object(api, "fetch_anilist", return_value={"Media": anime()}):
        response = api.app.test_client().get("/api/v1/anime/123")
    assert response.status_code == 200
    assert response.json["anime"]["id"] == 123
    assert response.json["anime"]["title_alternates"] == [
        "Canonical", "Canonical Romaji", "原題"
    ]


def test_anime_list_rejects_invalid_filters_before_provider_call(api):
    with patch.object(api, "fetch_anilist") as fetch:
        response = api.app.test_client().get("/api/v1/anime?limit=999")
    assert response.status_code == 400
    assert response.json["status"] == "error"
    fetch.assert_not_called()


def test_homepage_exposes_avatar_seven_havens_officially(api):
    payload = {
        "trending": {"media": [anime()]},
        "popularSeason": {"media": []},
        "topRated": {"media": []},
        "recentlyAdded": {"media": []},
        "featuredMovie": {"media": []},
        "series": {"media": []},
    }
    with patch.object(api, "fetch_anilist", return_value=payload), \
         patch.object(api.streaming_manager.animeheaven, "browse_catalog", return_value=[]):
        response = api.app.test_client().get("/")
    assert response.status_code == 200
    assert b"Avatar: Seven Havens" in response.data
    assert b"https://www.paramountplus.com/shows/avatar-seven-havens/" in response.data
    assert b"New series" in response.data
    assert b"2026 SERIES" in response.data
    assert b"/watch/avatar-seven-havens/1" not in response.data


def test_ongoing_anime_episode_metadata_refreshes_from_provider(api):
    airing = anime(anime_id=456, title="Airing Season")
    airing["status"] = "RELEASING"
    airing["nextAiringEpisode"] = {
        "episode": 15,
        "airingAt": 1793000000,
        "timeUntilAiring": 1800,
    }
    card = api.format_anime_card(airing)
    assert card["status"] == "Releasing"
    assert card["latest_ep"] == 14
    assert card["episode"].startswith("EP 14")
    assert card["next_airing_episode"]["episode"] == 15
    assert card["next_airing_episode"]["seconds_until_airing"] == 1800


def test_anilist_cache_limit_is_lowered_for_worker_memory(api, monkeypatch):
    from collections import OrderedDict

    api._anilist_cache.clear()
    api._anilist_cache = OrderedDict()
    assert api.ANILIST_CACHE_MAX == 64
    class Response:
        def raise_for_status(self):
            return None

        def json(self):
            return {"data": {"ok": True}}

    monkeypatch.setattr(api.requests, "post", lambda *args, **kwargs: Response())
    for index in range(api.ANILIST_CACHE_MAX + 10):
        api.fetch_anilist(f"query-{index}")
    assert len(api._anilist_cache) == api.ANILIST_CACHE_MAX
    refreshed_key = f"{hash('query-10')}_[]"
    api.fetch_anilist("query-10")
    assert next(reversed(api._anilist_cache)) == refreshed_key


def test_comment_and_notification_reads_are_bounded(api):
    user = {"email": "reader@example.com", "name": "Reader"}
    for index in range(125):
        api.platform.add_comment(None, "123", "1", user, f"Comment {index}")
    comments = api.platform.get_comments("123", ep="1", limit=30)
    assert len(comments) == 30
    assert comments[-1]["text"] == "Comment 124"

    with api.platform._db() as conn:
        for index in range(125):
            conn.execute(
                "INSERT INTO notifications(id,email,text,read,t) VALUES (?,?,?,?,?)",
                (f"n{index}", user["email"], f"Notification {index}", 0, index),
            )
    notifications = api.platform.get_notifications(user["email"], limit=20)
    assert len(notifications) == 20
    assert notifications[-1]["text"] == "Notification 124"


def test_single_account_and_counter_reads_avoid_store_snapshot(api, monkeypatch):
    user = api.platform.get_user(api.platform.DEFAULT_ADMIN_EMAIL)
    assert user and user["role"] == "admin"
    monkeypatch.setattr(api.platform, "load_store", lambda: (_ for _ in ()).throw(AssertionError("snapshot")))
    assert api.app.test_client().get("/api/public/counters").status_code == 200
    assert api.platform.get_user_count() >= 1
    assert api.app.test_client().get("/api/community/comments?anime_id=123").status_code == 200
    with api.app.test_request_context("/", environ_base={"REMOTE_ADDR": "203.0.113.9"}):
        monkeypatch.setattr(api.platform, "verify_user", lambda *_args: user)
        monkeypatch.setattr(api.platform, "register_user", lambda *_args: user)
        response = api.app.test_client().post("/login", data={
            "email": "admin@camanime.local", "password": "correct-password", "action": "signin"
        })
        assert response.status_code in (302, 303)
