"""Tests for the opt-in production schedule smoke check."""

import gzip
import importlib.util
import json
import importlib.util
import sys
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import Mock

import pytest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = ROOT / "tools" / "schedule_smoke.py"
spec = importlib.util.spec_from_file_location("schedule_smoke", SCRIPT_PATH)
smoke = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(smoke)
sys.modules["schedule_smoke"] = smoke
snapshot_spec = importlib.util.spec_from_file_location(
    "schedule_usage_snapshot", ROOT / "tools" / "schedule_usage_snapshot.py"
)
snapshot = importlib.util.module_from_spec(snapshot_spec)
assert snapshot_spec and snapshot_spec.loader
snapshot_spec.loader.exec_module(snapshot)


def valid_payload():
    return {
        "status": "success",
        "season": {"name": "FALL", "year": 2026},
        "items": [{
            "id": 12,
            "title": "Example Series",
            "next_airing_episode": {"episode": 3, "airing_at": 1_900_000_000},
            "playback_available": False,
            "download_available": False,
            "official_episode_link": None,
        }],
        "playback_available": False,
    }


def make_response(payload, compressed=False):
    body = json.dumps(payload).encode()
    headers = {"Content-Type": "application/json", "Cache-Control": "public, max-age=900"}
    if compressed:
        body = gzip.compress(body)
        headers["Content-Encoding"] = "gzip"
    response = Mock(status_code=200, headers=headers)
    response.raw = Mock()
    response.raw.read.return_value = body
    response.url = "https://camanime.onrender.com/api/v1/schedule"
    return response


def test_smoke_check_measures_compressed_and_plain_responses():
    for compressed in (False, True):
        result = smoke.inspect_response(make_response(valid_payload(), compressed), max_age=900)
        assert result["status"] == 200
        assert result["item_count"] == 1
        assert result["response_body_bytes"] > 0
        assert result["compressed"] is compressed
        assert result["cache_max_age_seconds"] == 900


def test_monthly_endpoint_byte_projection_uses_worker_window_and_handles_restart():
    previous = {
        "schedule_api_requests": 100,
        "worker_uptime_seconds": 500,
        "response_body_bytes": 200,
    }
    current = {
        "schedule_api_requests": 112,
        "worker_uptime_seconds": 1100,
        "response_body_bytes": 250,
        "window_seconds": 600,
    }
    assert snapshot._estimated_monthly_schedule_api_bytes(current, previous) == 12_960_000
    assert snapshot._estimated_monthly_schedule_api_bytes(
        {**current, "worker_uptime_seconds": 10}, previous
    ) is None
    assert snapshot._estimated_monthly_schedule_api_bytes(current, None) is None


def test_smoke_check_rejects_wrong_schema_and_playback_claims():
    for mutate in (
        lambda payload: payload["items"][0].update(playback_available=True),
        lambda payload: payload["items"][0].update(id="not-an-integer"),
        lambda payload: payload.update(season="FALL 2026"),
    ):
        payload = valid_payload()
        mutate(payload)
        with pytest.raises(smoke.SmokeCheckError):
            smoke.validate_payload(payload)


def test_smoke_check_rejects_non_https_provider_link():
    payload = valid_payload()
    payload["items"][0]["official_episode_link"] = {
        "url": "javascript:alert(1)", "provider": "Unsafe"
    }
    with pytest.raises(smoke.SmokeCheckError):
        smoke.validate_payload(payload)


def test_smoke_check_rejects_non_json_status_and_missing_cache_age():
    response = make_response(valid_payload())
    response.status_code = 503
    with pytest.raises(smoke.SmokeCheckError, match="HTTP 503"):
        smoke.inspect_response(response)

    response = make_response(valid_payload())
    response.headers["Cache-Control"] = "public"
    with pytest.raises(smoke.SmokeCheckError, match="max-age"):
        smoke.inspect_response(response)
