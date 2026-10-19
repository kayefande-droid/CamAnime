import importlib
import sys
import time
from datetime import datetime, timezone
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


def test_episode_card_uses_fallback_artwork_and_details_without_confirmed_episode(api):
    upcoming = anime(anime_id=124, title="Upcoming Example")
    upcoming.update({"status": "NOT_YET_RELEASED", "episodes": 24})
    payload = {"trending": {"media": [upcoming]}, "popularSeason": {"media": []},
               "topRated": {"media": []}, "recentlyAdded": {"media": []},
               "featuredMovie": {"media": []}, "series": {"media": []}}
    with patch.object(api, "fetch_anilist", return_value=payload), \
         patch.object(api.streaming_manager.animeheaven, "browse_catalog", return_value=[]):
        response = api.app.test_client().get("/")
    assert response.status_code == 200
    assert b"/static/brand/camanime-icon.svg" in response.data
    assert b"/watch/124/1" not in response.data
    assert b"/anime/124" in response.data


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


def test_details_and_watch_use_only_exact_provider_episode_numbers(api, monkeypatch):
    raw = anime()
    raw.update({"status": "RELEASING", "episodes": 24, "nextAiringEpisode": None})
    provider_episodes = [{"num": 1, "key": "episode-one"}, {"num": 3, "key": "episode-three"}]
    with patch.object(api, "fetch_anilist", return_value={"Media": raw}), \
         patch.object(api.streaming_manager, "resolve_anime_mapping", return_value={"heaven_id": "matched"}), \
         patch.object(api.streaming_manager.animeheaven, "get_anime_info", return_value={"episodes": provider_episodes}), \
         patch.object(api.streaming_manager.youtube, "get_trailer_id", return_value=None):
        details = api.app.test_client().get("/anime/123")
        invalid_episode = api.app.test_client().get("/watch/123/2")
        valid_episode = api.app.test_client().get("/watch/123/3")
    assert details.status_code == 200
    assert b'data-ep="1"' in details.data
    assert b'data-ep="3"' in details.data
    assert b'data-ep="2"' not in details.data
    assert invalid_episode.status_code == 302
    assert invalid_episode.headers["Location"].endswith("/anime/123")
    assert valid_episode.status_code == 200
    assert b"Next Ep" in valid_episode.data
    assert b"/watch/123/3" not in valid_episode.data.split(b"Next Ep", 1)[1][:100]


def test_confirmed_episodes_distinguish_airing_finished_and_unknown(api):
    airing = anime()
    airing.update({"status": "RELEASING", "episodes": 24})
    airing["nextAiringEpisode"] = {"episode": 8, "airingAt": 2000}
    assert api._confirmed_episode_numbers(airing, now_ts=1000) == list(range(1, 8))
    assert api._confirmed_episode_numbers(
        airing, [{"num": 9}, {"num": 12}, {"num": "special"}], now_ts=1000
    ) == list(range(1, 8)) + [9, 12]
    assert api._confirmed_episode_numbers(airing, now_ts=2000) == list(range(1, 8))

    completed = anime()
    completed.update({"status": "FINISHED", "episodes": 3})
    assert api._confirmed_episode_numbers(completed) == [1, 2, 3]

    unknown = anime()
    unknown.update({"status": "UNKNOWN", "episodes": None})
    assert api._confirmed_episode_numbers(unknown) == []
    assert api._confirmed_episode_numbers(
        unknown, [{"num": 2}, {"num": 5}]
    ) == [2, 5]


def test_homepage_omits_unverified_series_without_streaming_listing(api):
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
    assert b"Avatar: Seven Havens" not in response.data
    assert b"/watch/123/1" in response.data


def test_release_schedule_api_includes_all_current_season_airings(api, monkeypatch):
    monkeypatch.setattr(api, "current_anime_season", lambda: ("FALL", 2026))
    media = []
    for index in range(9):
        item = anime(anime_id=500 + index, title=f"Seasonal {index}")
        item.update({"status": "RELEASING", "season": "FALL", "seasonYear": 2026})
        item["nextAiringEpisode"] = {
            "episode": index + 2,
            "airingAt": 1793000000 + index * 3600,
            "timeUntilAiring": 1800 + index * 3600,
        }
        media.append(item)
    monkeypatch.setattr(api, "_SEASON_SCHEDULE_CACHE", {})
    with patch.object(api, "fetch_anilist", return_value={"Page": {"media": media}}) as fetch:
        response = api.app.test_client().get("/api/v1/schedule")
    assert response.status_code == 200
    assert response.json["season"] == {"name": "FALL", "year": 2026}
    assert len(response.json["items"]) == 9
    assert response.json["items"][-1]["next_airing_episode"]["episode"] == 10
    assert all(item["upcoming"] is True for item in response.json["items"])
    assert fetch.call_args_list[0].args[1] == {"season": "FALL", "seasonYear": 2026, "page": 1, "perPage": 50}
    assert all(call.kwargs["cache_ttl"] == api._SEASON_SCHEDULE_CACHE_TTL for call in fetch.call_args_list)
    assert all(item["playback_available"] is False for item in response.json["items"])
    assert response.headers["Cache-Control"].startswith("public, max-age=900")


def test_schedule_endpoint_exposes_worker_request_and_refresh_counters(api, monkeypatch):
    monkeypatch.setattr(api, "_SCHEDULE_API_REQUESTS", 40)
    monkeypatch.setattr(api, "_SCHEDULE_CACHE_MISSES", 9)
    monkeypatch.setattr(api, "_SCHEDULE_PROCESS_STARTED_AT", api.time.time() - 60)
    monkeypatch.setattr(api, "current_anime_season", lambda: ("FALL", 2026))
    monkeypatch.setattr(api, "get_current_season_schedule", lambda: [])

    response = api.app.test_client().get("/api/v1/schedule")

    assert response.status_code == 200
    assert response.headers["X-Schedule-Api-Requests"] == "41"
    assert response.headers["X-Schedule-Cache-Misses"] == "9"
    assert int(response.headers["X-Schedule-Worker-Uptime"]) >= 59
    assert "X-Schedule-Api-Requests" in response.headers["Access-Control-Expose-Headers"]


def test_schedule_page_cache_bounds_repeated_requests_and_isolates_cache(api, monkeypatch):
    monkeypatch.setattr(api, "current_anime_season", lambda: ("FALL", 2026))
    monkeypatch.setattr(api, "_SEASON_SCHEDULE_CACHE", {})
    monkeypatch.setattr(api.time, "monotonic", lambda: 1000)
    empty_page = {"Page": {"media": []}}
    with patch.object(api, "fetch_anilist", return_value=empty_page) as fetch:
        client = api.app.test_client()
        first = client.get("/api/v1/schedule")
        second = client.get("/api/v1/schedule")
    assert first.status_code == second.status_code == 200
    assert fetch.call_count == 1
    assert api._SEASON_SCHEDULE_CACHE[("FALL", 2026)][1] == api._SEASON_SCHEDULE_CACHE_TTL


def test_schedule_failure_cooldown_prevents_upstream_retry_storm(api, monkeypatch):
    monkeypatch.setattr(api, "current_anime_season", lambda: ("FALL", 2026))
    monkeypatch.setattr(api, "_SEASON_SCHEDULE_CACHE", {})
    monkeypatch.setattr(api.time, "monotonic", lambda: 1000)
    with patch.object(api, "fetch_anilist", return_value={}) as fetch:
        client = api.app.test_client()
        first = client.get("/api/v1/schedule")
        second = client.get("/api/v1/schedule")
    assert first.status_code == second.status_code == 200
    assert fetch.call_count == 1
    assert api._SEASON_SCHEDULE_CACHE[("FALL", 2026)][1] == api._SEASON_SCHEDULE_FAILURE_TTL


def test_schedule_cache_expires_after_fifteen_minutes(api, monkeypatch):
    monkeypatch.setattr(api, "current_anime_season", lambda: ("FALL", 2026))
    monkeypatch.setattr(api, "_SEASON_SCHEDULE_CACHE", {})
    now = [1000]
    monkeypatch.setattr(api.time, "monotonic", lambda: now[0])
    empty_page = {"Page": {"media": []}}
    with patch.object(api, "fetch_anilist", return_value=empty_page) as fetch:
        client = api.app.test_client()
        client.get("/api/v1/schedule")
        now[0] += api._SEASON_SCHEDULE_CACHE_TTL
        client.get("/api/v1/schedule")
    assert fetch.call_count == 2


def test_schedule_caps_work_to_two_pages_of_50_titles(api, monkeypatch):
    monkeypatch.setattr(api, "current_anime_season", lambda: ("FALL", 2026))
    monkeypatch.setattr(api, "_utc_now_timestamp", lambda: 100)

    def page_items(start):
        rows = []
        for anime_id in range(start, start + 50):
            row = anime(anime_id=anime_id, title=f"Bounded {anime_id}")
            row.update({"status": "RELEASING", "season": "FALL", "seasonYear": 2026})
            row["nextAiringEpisode"] = {"episode": 2, "airingAt": 200, "timeUntilAiring": 100}
            rows.append(row)
        return {"Page": {"media": rows}}

    monkeypatch.setattr(api, "_SEASON_SCHEDULE_CACHE", {})
    with patch.object(api, "fetch_anilist", side_effect=[page_items(1000), page_items(1050)]) as fetch:
        response = api.app.test_client().get("/api/v1/schedule")
    assert response.status_code == 200
    assert len(response.json["items"]) == 100
    assert fetch.call_count == 2
    assert [call.args[1]["page"] for call in fetch.call_args_list] == [1, 2]


def test_schedule_query_is_small_and_uses_legal_streaming_metadata(api):
    assert "description" not in api.SEASON_MEDIA_FRAGMENT
    assert "characters" not in api.SEASON_MEDIA_FRAGMENT
    assert "recommendations" not in api.SEASON_MEDIA_FRAGMENT
    assert "streamingEpisodes { title url site }" in api.SEASON_MEDIA_FRAGMENT
    assert "perPage: 1" in api.SEASON_MEDIA_FRAGMENT
    assert "status_in: [RELEASING, NOT_YET_RELEASED]" in api.SEASON_AIRING_QUERY


def test_current_anime_season_uses_utc_quarter_boundaries(api):
    assert api.current_anime_season(datetime(2026, 1, 1, tzinfo=timezone.utc)) == ("WINTER", 2026)
    assert api.current_anime_season(datetime(2026, 4, 1, tzinfo=timezone.utc)) == ("SPRING", 2026)
    assert api.current_anime_season(datetime(2026, 7, 1, tzinfo=timezone.utc)) == ("SUMMER", 2026)
    assert api.current_anime_season(datetime(2026, 10, 1, tzinfo=timezone.utc)) == ("FALL", 2026)
    assert api.current_anime_season(datetime(2026, 12, 15, tzinfo=timezone.utc)) == ("FALL", 2026)


def test_release_schedule_handles_aired_unknown_and_finished_titles(api, monkeypatch):
    monkeypatch.setattr(api, "current_anime_season", lambda: ("FALL", 2026))
    active = anime(anime_id=701, title="Still Airing")
    active.update({"status": "RELEASING", "season": "FALL", "seasonYear": 2026})
    active["nextAiringEpisode"] = {"episode": 5, "airingAt": 1793000000, "timeUntilAiring": 10}
    past = anime(anime_id=703, title="Past Air Time")
    past.update({"status": "RELEASING", "season": "FALL", "seasonYear": 2026})
    past["nextAiringEpisode"] = {"episode": 6, "airingAt": 1700000000, "timeUntilAiring": 0}
    unknown = anime(anime_id=704, title="Unknown Schedule")
    unknown.update({"status": "NOT_YET_RELEASED", "season": "FALL", "seasonYear": 2026})
    unknown["episodes"] = None
    finished = anime(anime_id=702, title="Finished")
    finished.update({"status": "FINISHED", "season": "FALL", "seasonYear": 2026})
    monkeypatch.setattr(api, "_SEASON_SCHEDULE_CACHE", {})
    with patch.object(api, "fetch_anilist", return_value={"Page": {"media": [active, past, unknown, finished]}}):
        response = api.app.test_client().get("/api/v1/schedule")
    assert response.status_code == 200
    by_id = {item["id"]: item for item in response.json["items"]}
    assert set(by_id) == {701, 703, 704}
    assert by_id[701]["availability"] == "upcoming"
    assert by_id[703]["availability"] == "air_time_passed"
    assert by_id[704]["availability"] == "date_unknown"
    assert by_id[704]["next_airing_episode"] is None
    assert by_id[704]["upcoming"] is False


def test_schedule_links_only_a_matching_already_released_official_episode(api, monkeypatch):
    monkeypatch.setattr(api, "_SEASON_SCHEDULE_CACHE", {})
    raw = anime(anime_id=705, title="Official Episode")
    raw.update({"status": "RELEASING", "season": "FALL", "seasonYear": 2026})
    raw["nextAiringEpisode"] = {"episode": 12, "airingAt": int(time.time()) - 100, "timeUntilAiring": 0}
    raw["streamingEpisodes"] = [
        {"title": "Episode 11", "url": "https://official.example/11", "site": "Official"},
        {"title": "Episode 12", "url": "https://official.example/12", "site": "Official"},
    ]
    with patch.object(api, "current_anime_season", return_value=("FALL", 2026)), \
         patch.object(api, "fetch_anilist", return_value={"Page": {"media": [raw]}}):
        response = api.app.test_client().get("/api/v1/schedule")
    item = response.json["items"][0]
    assert item["released_episode"] == 12
    assert item["official_episode_link"] == {
        "url": "https://official.example/12", "provider": "Official"
    }
    assert item["official_link_available"] is True
    assert item["playback_available"] is False
    assert item["download_available"] is False


def test_homepage_renders_schedule_only_in_live_drawer(api, monkeypatch):
    monkeypatch.setattr(api, "current_anime_season", lambda: ("FALL", 2026))
    schedule = []
    for index in range(8):
        schedule.append({
            **api.format_anime_card({
                **anime(anime_id=800 + index, title=f"Countdown {index}"),
                "status": "RELEASING", "season": "FALL", "seasonYear": 2026,
                "nextAiringEpisode": {"episode": 2, "airingAt": 1793000000 + index,
                                      "timeUntilAiring": 30 + index},
            }),
        })
    monkeypatch.setattr(api, "_SEASON_SCHEDULE_CACHE", {
        ("FALL", 2026): (api.time.monotonic(), api._SEASON_SCHEDULE_CACHE_TTL, schedule)
    })
    payload = {"trending": {"media": []}, "popularSeason": {"media": []},
               "topRated": {"media": []}, "recentlyAdded": {"media": []},
               "featuredMovie": {"media": []}, "series": {"media": []}}
    with patch.object(api, "fetch_anilist", return_value=payload), \
         patch.object(api, "get_current_season_schedule", return_value=schedule), \
         patch.object(api.streaming_manager.animeheaven, "browse_catalog", return_value=[]):
        response = api.app.test_client().get("/")
    assert response.status_code == 200
    assert response.data.count(b'class="release-ticker release-ticker-compact"') == 8
    assert b"id=\"liveScheduleList\"" in response.data
    assert b"Countdown 7" in response.data
    assert b"id=\"liveScheduleDrawer\"" in response.data
    assert b"id=\"releaseTickerList\"" not in response.data
    assert b"Open live release schedule" in response.data
    assert b"/watch/800/1" not in response.data


def test_shared_html_pages_include_accessible_live_schedule_drawer(api):
    response = api.app.test_client().get("/login")
    assert response.status_code == 200
    assert b"id=\"liveScheduleDrawer\"" in response.data
    assert b"aria-label=\"Live release schedule\"" in response.data
    assert b"aria-expanded=\"false\"" in response.data
    assert b"sync.css?v=20261019-responsive" in response.data
    assert b"release-schedule.js?v=20261019-drawer" in response.data


def test_templates_include_only_desktop_tablet_mobile_breakpoints(api):
    client = api.app.test_client()
    for path in ("/", "/anime/123"):
        if path == "/":
            payload = {"trending": {"media": [anime()]}, "popularSeason": {"media": []},
                       "topRated": {"media": []}, "recentlyAdded": {"media": []},
                       "featuredMovie": {"media": []}, "series": {"media": []}}
            with patch.object(api, "fetch_anilist", return_value=payload), \
                 patch.object(api.streaming_manager.animeheaven, "browse_catalog", return_value=[]):
                response = client.get(path)
        else:
            with patch.object(api, "fetch_anilist", return_value={"Media": anime()}), \
                 patch.object(api.streaming_manager, "resolve_anime_mapping", return_value={}), \
                 patch.object(api.streaming_manager.youtube, "get_trailer_id", return_value=None):
                response = client.get(path)
        assert response.status_code == 200
        assert b"min-width: 768px" in response.data
        assert b"max-width: 1023px" in response.data
        assert b"max-width: 767px" in response.data
        assert b"sync.css?v=20261019-responsive" in response.data


def test_legacy_schedule_url_opens_shared_drawer(api, monkeypatch):
    monkeypatch.setattr(api, "current_anime_season", lambda: ("FALL", 2026))
    response = api.app.test_client().get("/schedule")
    assert response.status_code == 302
    assert response.headers["Location"].endswith("/?schedule=open")

    payload = {"trending": {"media": []}, "popularSeason": {"media": []},
               "topRated": {"media": []}, "recentlyAdded": {"media": []},
               "featuredMovie": {"media": []}, "series": {"media": []}}
    with patch.object(api, "fetch_anilist", return_value=payload), \
         patch.object(api.streaming_manager.animeheaven, "browse_catalog", return_value=[]):
        opened = api.app.test_client().get("/?schedule=open")
    assert opened.status_code == 200
    assert b"class=\"live-schedule-drawer is-open\"" in opened.data
    assert b"aria-expanded=\"true\"" in opened.data
    assert b"id=\"releaseTickerList\"" not in opened.data


def test_ongoing_anime_episode_metadata_refreshes_from_provider(api, monkeypatch):
    airing = anime(anime_id=456, title="Airing Season")
    airing["status"] = "RELEASING"
    airing["nextAiringEpisode"] = {
        "episode": 15,
        "airingAt": 1793000000,
        "timeUntilAiring": 1800,
    }
    monkeypatch.setattr(api, "_utc_now_timestamp", lambda: 1792000000)
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
