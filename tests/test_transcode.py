"""Real checks for resolution-reduced downloads.

The important test runs ffmpeg for real: it builds a 720p clip, converts it to
360p through `transcode.stream`, and verifies the output is genuinely smaller
and actually 360 pixels tall. That is the promise the UI makes, so it is worth
executing rather than mocking.
"""
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import transcode  # noqa: E402

HAS_FFMPEG = bool(shutil.which("ffmpeg"))
HAS_FFPROBE = bool(shutil.which("ffprobe"))
needs_ffmpeg = pytest.mark.skipif(not HAS_FFMPEG, reason="ffmpeg not installed")


@pytest.fixture(scope="module")
def clip(tmp_path_factory):
    if not HAS_FFMPEG:
        pytest.skip("ffmpeg not installed")
    path = tmp_path_factory.mktemp("media") / "source.mp4"
    subprocess.run(
        ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
         "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30:duration=4",
         "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
         "-c:v", "libx264", "-b:v", "3000k", "-c:a", "aac", "-b:a", "128k",
         str(path)],
        check=True,
    )
    assert path.stat().st_size > 0
    return path


def test_profiles_are_a_real_ladder():
    assert transcode.profile(360)["height"] == 360
    assert transcode.profile("480")["height"] == 480
    assert transcode.profile(1080) is None
    # Bounded bitrate is what makes the size drop predictable.
    assert transcode.profile(360)["video_kbps"] < transcode.profile(720)["video_kbps"]
    assert transcode.estimated_mb(360, 24 * 60) < transcode.estimated_mb(720, 24 * 60)


@needs_ffmpeg
def test_command_caps_never_upscales_and_sends_referer():
    cmd = transcode.build_command("https://cdn.example/v.mp4", 360,
                                  referer="https://ref.example/")
    joined = " ".join(cmd)
    assert "min(360,ih)" in joined           # 1080p -> 360p, 240p stays 240p
    assert "libx264" in joined
    assert "pipe:1" in joined
    assert "Referer: https://ref.example/" in joined
    assert "frag_keyframe" in joined


@needs_ffmpeg
def test_conversion_produces_a_smaller_360p_file(clip, tmp_path):
    out = tmp_path / "out.mp4"
    with open(out, "wb") as fh:
        for chunk in transcode.stream(str(clip), 360, user_agent="CamAnime/Test"):
            fh.write(chunk)
    assert out.stat().st_size > 0
    assert out.stat().st_size < clip.stat().st_size, (
        f"converted {out.stat().st_size} is not smaller than {clip.stat().st_size}"
    )
    if HAS_FFPROBE:
        probe = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "v:0",
             "-show_entries", "stream=height", "-of", "csv=p=0", str(out)],
            capture_output=True, text=True, check=True,
        )
        assert probe.stdout.strip() == "360"


def test_bundle_options_cover_every_downloadable_source(monkeypatch):
    monkeypatch.setattr(transcode, "available", lambda: True)
    downloads = []
    servers = [
        {"playback_mode": "mp4", "raw_url": "https://cdn.example/ep1.mp4",
         "audio": "sub", "name": "CamStream HD-1 (SUB)"},
        # Duplicate source: must not be listed twice.
        {"playback_mode": "mp4", "raw_url": "https://cdn.example/ep1.mp4",
         "audio": "sub", "name": "Mirror"},
        {"playback_mode": "iframe", "stream_url": "https://embed.example/x"},
    ]
    transcode.add_download_options(downloads, servers, "Frieren", episode=3)
    assert {d["quality"] for d in downloads} == {"720p", "480p", "360p"}
    assert len(downloads) == 3
    assert all(d["direct"] and d["transcode"] for d in downloads)
    assert all("/api/download/transcode?" in d["url"] for d in downloads)
    assert all("height=" in d["url"] for d in downloads)


def test_stream_options_are_real_transcodes(monkeypatch):
    monkeypatch.setattr(transcode, "available", lambda: True)
    servers = [
        {"playback_mode": "mp4", "raw_url": "https://cdn.example/ep1.mp4",
         "audio": "sub", "name": "HD", "referer": "https://ref.example/"},
        {"playback_mode": "hls", "raw_url": "https://cdn.example/ep1.m3u8",
         "audio": "dub", "name": "DUB"},
        {"playback_mode": "iframe", "stream_url": "https://embed.example/x"},
    ]
    result = transcode.add_stream_options(servers, "Frieren", episode=3)
    added = [s for s in result if s.get("transcode")]
    assert {s["quality"] for s in added} == {"720p", "480p", "360p"}
    assert {s["audio"] for s in added} == {"sub", "dub"}
    assert all(s["playback_mode"] == "mp4" for s in added)
    assert all("/api/stream/transcode?" in s["stream_url"] for s in added)
    assert all("height=" in s["stream_url"] for s in added)
    assert all("ref=" in s["stream_url"] for s in added if s["audio"] == "sub")
    # The original sources survive in front, so default playback stays best quality.
    assert result[:3] == servers


def test_stream_options_fall_back_to_proxy_url(monkeypatch):
    monkeypatch.setattr(transcode, "available", lambda: True)
    servers = [{
        "playback_mode": "hls",
        "stream_url": "/api/proxy/hls?url=x",
        "download_url": "https://cdn.example/new-season.m3u8",
        "audio": "sub",
    }]
    result = transcode.add_stream_options(servers, "Black Clover", episode=2)
    added = [s for s in result if s.get("transcode")]
    assert len(added) == 3
    assert all("new-season.m3u8" in s["stream_url"] for s in added)


def test_stream_options_absent_without_encoder(monkeypatch):
    monkeypatch.setattr(transcode, "available", lambda: False)
    servers = [{"playback_mode": "mp4", "raw_url": "https://cdn.example/ep1.mp4",
                "audio": "sub"}]
    assert transcode.add_stream_options(servers, "Frieren", episode=1) == servers


def test_stream_endpoint_is_inline_mp4(client, monkeypatch):
    import app as api

    def fake_stream(url, height, referer="", user_agent=""):
        yield b"\x00\x00\x00\x18ftypmp42"
        yield b"y" * 1024

    monkeypatch.setattr(api, "_safe_upstream_url", lambda u: u)
    monkeypatch.setattr(api, "_record_activity", lambda *a, **k: None)
    monkeypatch.setattr(transcode, "available", lambda: True)
    monkeypatch.setattr(transcode, "stream", fake_stream)
    res = client.get(
        "/api/stream/transcode?url=https%3A%2F%2Fcdn.example%2Fv.mp4&height=480")
    assert res.status_code == 200
    assert res.headers["Content-Type"].startswith("video/mp4")
    assert res.headers["Content-Disposition"] == "inline"
    assert res.headers["X-Transcoded-Height"] == "480"
    assert len(res.data) == len(b"\x00\x00\x00\x18ftypmp42") + 1024


def test_no_options_when_encoder_is_missing(monkeypatch):
    monkeypatch.setattr(transcode, "available", lambda: False)
    downloads = []
    transcode.add_download_options(
        downloads,
        [{"playback_mode": "mp4", "raw_url": "https://cdn.example/ep1.mp4",
          "audio": "sub"}],
        "Frieren", episode=1,
    )
    assert downloads == []


@pytest.fixture()
def client(tmp_path, monkeypatch):
    for var in ("DATABASE_URL", "CAMANIME_DB"):
        monkeypatch.delenv(var, raising=False)
    monkeypatch.chdir(ROOT)
    import app as api
    monkeypatch.setitem(api.app.config, "TESTING", True)
    monkeypatch.setattr(api.app, "test_client_class", None, raising=False)
    return api.app.test_client()


def test_endpoint_reports_missing_encoder(client, monkeypatch):
    import app as api
    monkeypatch.setattr(api, "_safe_upstream_url", lambda u: u)
    monkeypatch.setattr(transcode, "available", lambda: False)
    res = client.get("/api/download/transcode?url=https%3A%2F%2Fcdn.example%2Fv.mp4&height=360")
    assert res.status_code == 503
    assert res.get_json()["transcode_available"] is False


def test_endpoint_rejects_unsupported_height(client, monkeypatch):
    import app as api
    monkeypatch.setattr(api, "_safe_upstream_url", lambda u: u)
    monkeypatch.setattr(transcode, "available", lambda: True)
    res = client.get("/api/download/transcode?url=https%3A%2F%2Fcdn.example%2Fv.mp4&height=1080")
    assert res.status_code == 400
    assert res.get_json()["heights"] == [720, 480, 360]


def test_endpoint_streams_converted_mp4(client, monkeypatch):
    import app as api

    def fake_stream(url, height, referer="", user_agent=""):
        yield b"\x00\x00\x00\x18ftypmp42"
        yield b"x" * 2048

    monkeypatch.setattr(api, "_safe_upstream_url", lambda u: u)
    monkeypatch.setattr(api, "_record_activity", lambda *a, **k: None)
    monkeypatch.setattr(transcode, "available", lambda: True)
    monkeypatch.setattr(transcode, "stream", fake_stream)
    res = client.get("/api/download/transcode?url=https%3A%2F%2Fcdn.example%2Fv.mp4&height=360&title=My%20Show%20Ep%201")
    assert res.status_code == 200
    assert res.headers["Content-Type"].startswith("video/mp4")
    assert "My_Show_Ep_1_360p.mp4" in res.headers["Content-Disposition"]
    assert res.headers["X-Transcoded-Height"] == "360"
    assert len(res.data) == len(b"\x00\x00\x00\x18ftypmp42") + 2048
