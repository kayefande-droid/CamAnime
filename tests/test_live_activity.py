"""Regression tests for the admin live activity feed."""

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import app as camanime  # noqa: E402
import streaming_providers  # noqa: E402


def _fresh():
    camanime.app.config["TESTING"] = True
    camanime._LIVE_ACTIVITY.clear()
    camanime._RECENT_VISITORS.clear()
    # Bypass the limiter so an unauthenticated probe is judged on permissions.
    camanime._RATE_BUCKETS.clear()
    return camanime.app.test_client()


def test_record_activity_marks_anonymous_users_as_guest():
    with camanime.app.test_request_context("/"):
        camanime._record_activity("stream", detail="cdn.example")
    row = camanime._LIVE_ACTIVITY[0]
    assert row["kind"] == "stream"
    assert row["guest"] is True
    assert row["email"] == "guest"
    assert row["detail"] == "cdn.example"


def test_summary_counts_recent_streams_and_downloads():
    camanime._LIVE_ACTIVITY.clear()
    with camanime.app.test_request_context("/"):
        camanime._record_activity("stream", detail="a.example")
        camanime._record_activity("stream", detail="b.example")
        camanime._record_activity("download", anime="Show - Ep 1", detail="c.example")
    summary = camanime._live_activity_summary()
    assert summary["active_streams_60s"] == 2
    assert summary["downloads_60s"] == 1
    assert summary["downloads_1h"] == 1
    kinds = [r["kind"] for r in summary["activity"]]
    assert "download" in kinds and "stream" in kinds


def test_admin_endpoint_labels_each_row():
    camanime._LIVE_ACTIVITY.clear()
    with camanime.app.test_request_context("/"):
        camanime._record_activity("stream", detail="a.example")
        camanime._record_activity("download", anime="Show", detail="b.example")
    rows = list(reversed(camanime._live_activity_summary()["activity"]))
    for row in rows:
        row["kind_label"] = camanime._KIND_LABELS.get(row["kind"], row["kind"].title())
    labels = {r["kind_label"] for r in rows}
    assert "Stream" in labels and "Download" in labels


def test_live_activity_is_admin_only():
    client = _fresh()
    assert client.get("/api/admin/live-activity").status_code == 403


def test_ring_buffer_cannot_grow_past_cap():
    for _ in range(5000):
        camanime._LIVE_ACTIVITY.append({"t": 0, "kind": "stream"})
    assert len(camanime._LIVE_ACTIVITY) <= camanime._LIVE_ACTIVITY.maxlen


def test_rate_limit_buckets_are_capped():
    camanime._RATE_BUCKETS.clear()
    for index in range(camanime._RATE_BUCKETS_MAX + 100):
        camanime._RATE_BUCKETS[f"probe-{index}"] = [time.time()]
    with camanime.app.test_request_context("/api/auth/login", environ_base={"REMOTE_ADDR": "203.0.113.1"}):
        camanime._rate_limited("/api/auth/login")
    assert len(camanime._RATE_BUCKETS) <= camanime._RATE_BUCKETS_MAX


def test_visitor_tracking_stays_bounded():
    client = _fresh()
    for index in range(camanime._RECENT_VISITORS_MAX + 100):
        camanime._RECENT_VISITORS[f"visitor-{index}"] = time.time()
    client.get("/healthz")
    assert len(camanime._RECENT_VISITORS) <= camanime._RECENT_VISITORS_MAX


def test_provider_response_caches_are_bounded(monkeypatch):
    from types import SimpleNamespace

    provider = streaming_providers.StreamingProvider()
    for index in range(provider.CACHE_MAX_ENTRIES + 20):
        provider._cache_set(f"key-{index}", "cached")
    assert len(provider.cache) == provider.CACHE_MAX_ENTRIES
    assert provider._cache_get("key-0") is None
    assert provider._cache_get(f"key-{provider.CACHE_MAX_ENTRIES + 19}") == "cached"

    manager = streaming_providers.StreamingManager()
    monkeypatch.setattr(manager.animeheaven, "find_best_id", lambda titles: None)
    monkeypatch.setattr(manager.anikoto, "find_best_slug", lambda titles: None)
    for index in range(manager._mapping_cache_max + 20):
        manager.resolve_anime_mapping(index + 1, [f"Anime {index}"])
    assert len(manager._mapping_cache) == manager._mapping_cache_max

    manager.anikoto.session.get = lambda *args, **kwargs: SimpleNamespace(text="getSources AES-CBC")
    for index in range(manager.anikoto._megaplay_script_cache_max + 4):
        manager.anikoto._get_megaplay_keys_and_ivs(
            f"host-{index}.example", '<script src="/bundle.js"></script>', "https://ref.example/"
        )
    assert len(manager.anikoto._megaplay_script_cache) == manager.anikoto._megaplay_script_cache_max

    resolver = streaming_providers.YouTubeTrailerResolver()
    resolver.session.get = lambda *args, **kwargs: SimpleNamespace(
        status_code=200, text='"videoId":"abcdefghijk"'
    )
    for index in range(resolver.CACHE_MAX_ENTRIES + 20):
        resolver.get_trailer_id(f"Anime {index}")
    assert len(resolver.cache) == resolver.CACHE_MAX_ENTRIES


def test_visitors_counter_is_deduplicated_by_ip():
    client = _fresh()
    client.get("/")
    stats = camanime._live_activity_summary()
    assert stats["online_now"] >= 1
    # A repeat visit from the same IP must not grow the counter.
    client.get("/")
    assert camanime._live_activity_summary()["online_now"] == stats["online_now"]
