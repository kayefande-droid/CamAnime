"""Discontinued releases: 2.6.5 (versionCode 16) and older.

These builds must receive a distinct discontinued notice and lose both streaming
and downloads, whatever the editable minimum happens to be.
"""
import importlib
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture()
def api(tmp_path, monkeypatch):
    monkeypatch.setenv("CAMANIME_DB", str(tmp_path / "test.db"))
    monkeypatch.delenv("CAMANIME_ADMIN_EMAIL", raising=False)
    monkeypatch.delenv("CAMANIME_ADMIN_PASSWORD", raising=False)
    sys.path.insert(0, str(ROOT))
    for name in ("app", "camanime_platform", "app_version"):
        sys.modules.pop(name, None)
    module = importlib.import_module("app")
    module.app.config.update(TESTING=True)
    yield module
    for name in ("app", "camanime_platform", "app_version"):
        sys.modules.pop(name, None)
    if str(ROOT) in sys.path:
        sys.path.remove(str(ROOT))


def headers(build, version):
    return {
        "X-CamAnime-Version": version,
        "X-CamAnime-Build": str(build),
        "X-CamAnime-Platform": "android",
        "X-CamAnime-Install": "install-discontinued-1",
    }


def test_2_6_5_is_discontinued(api):
    assert api.app_version.discontinued(16) is True
    assert api.app_version.discontinued(15) is True
    assert api.app_version.discontinued(17) is False
    assert api.app_version.discontinued(None) is False


@pytest.mark.parametrize("path", [
    "/api/proxy/video?url=https%3A%2F%2Fcdn.example%2Fv.mp4",
    "/api/download/video?url=https%3A%2F%2Fcdn.example%2Fv.mp4",
    "/api/download/transcode?url=https%3A%2F%2Fcdn.example%2Fv.mp4&height=360",
    "/api/episode-sources/16498/1",
])
def test_streams_and_downloads_are_blocked_for_2_6_5(api, path):
    res = api.app.test_client().get(path, headers=headers(16, "2.6.5"))
    assert res.status_code == 426
    body = res.get_json()
    assert body["discontinued"] is True
    assert body["discontinued_at_or_below_version"] == "2.6.5"
    assert body["discontinued_at_or_below_version_code"] == 16
    assert body["message"].startswith("CamAnime 2.6.5 and older are discontinued")


def test_version_endpoint_flags_old_builds_without_blocking_the_check(api):
    res = api.app.test_client().get("/api/app/version", headers=headers(15, "2.6.4"))
    assert res.status_code == 200
    body = res.get_json()
    assert body["required"] is True
    assert body["policy"]["discontinued"] is True
    # The policy endpoint stays reachable so the app can show the notice.
    assert body["policy"]["download_url"]


def test_supported_build_is_not_flagged_as_discontinued(api):
    res = api.app.test_client().get("/api/app/ping", headers=headers(17, "2.7.0"))
    body = res.get_json()
    assert body["required"] is False
    assert body["policy"]["discontinued"] is False
