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
