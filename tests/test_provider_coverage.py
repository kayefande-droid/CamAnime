"""The streaming providers are permanent (see AGENTS.md).

These tests fail if a provider, a mirror host or a download path disappears
from the code or from an episode bundle. They use fixtures, not the network, so
a provider outage cannot be mistaken for a code change — and a deleted provider
cannot hide behind an outage either.
"""

from pathlib import Path

import pytest

import streaming_providers as sp

ROOT = Path(__file__).resolve().parent.parent


def _bundle(**overrides):
    bundle = {
        "anilist_id": 113415,
        "mal_id": 40748,
        "episode": 1,
        "heaven_id": "62reo",
        "anikoto_slug": "jujutsu-kaisen-tv-8ssye",
        "servers": [
            {
                "id": "heaven-mp4-1",
                "name": "AnimeHeaven Primary",
                "provider": "animeheaven",
                "playback_mode": "mp4",
                "raw_url": "https://rt.animeheaven.me/video.mp4?k",
                "stream_url": "/api/proxy/video?url=x",
                "download_url": "/api/download/video?url=x",
            },
            {
                "id": "anikoto-sub-hd-1-1",
                "name": "CamStream HD-1 (SUB)",
                "provider": "anikoto",
                "audio": "sub",
                "playback_mode": "hls",
                "raw_url": "https://cdn.example/sub.m3u8",
                "stream_url": "/api/proxy/hls?url=x",
            },
            {
                "id": "anikoto-dub-hd-1-1",
                "name": "CamStream HD-1 (DUB)",
                "provider": "anikoto",
                "audio": "dub",
                "playback_mode": "hls",
                "raw_url": "https://cdn.example/dub.m3u8",
                "stream_url": "/api/proxy/hls?url=x",
            },
            {
                "id": "embed-vidlink-sub",
                "name": "VidLink Ultra (SUB)",
                "provider": "vidlink",
                "playback_mode": "iframe",
                "stream_url": "https://vidlink.pro/anime/40748/1/sub",
            },
            {
                "id": "embed-vidsrc-sub",
                "name": "VidSrc Pro (SUB)",
                "provider": "vidsrc",
                "playback_mode": "iframe",
                "stream_url": "https://vidsrc.cc/v2/embed/anime/ani113415/1/sub",
            },
        ],
        "downloads": [
            {"label": "Episode 1 Direct MP4 (AnimeHeaven High-Speed)", "provider": "AnimeHeaven"},
            {"label": "Episode 1 SUB (single file)", "provider": "CamStream HD-1"},
        ],
        "audio_availability": {"sub": True, "dub": True},
        "available_qualities": [1080, 720, 360],
        "active_server": None,
    }
    bundle.update(overrides)
    return bundle


def test_every_provider_is_registered_with_the_manager():
    manager = sp.StreamingManager()
    assert set(manager.providers) == {"animeheaven", "anikoto"}
    assert manager.animeheaven.base_url == "https://animeheaven.me"


def test_expected_provider_list_is_not_trimmed():
    assert sp.EXPECTED_STREAM_PROVIDERS == ("animeheaven", "anikoto", "vidlink", "vidsrc")


def test_a_complete_bundle_drops_nothing():
    assert sp.missing_stream_providers(_bundle()) == []


@pytest.mark.parametrize("provider", sp.EXPECTED_STREAM_PROVIDERS)
def test_removing_a_provider_is_a_regression(provider):
    bundle = _bundle()
    bundle["servers"] = [s for s in bundle["servers"] if s["provider"] != provider]
    assert sp.missing_stream_providers(bundle) == [provider]


def test_both_audio_tracks_and_a_download_path_stay_listed():
    servers = _bundle()["servers"]
    audios = {s.get("audio") for s in servers if s["provider"] == "anikoto"}
    assert audios == {"sub", "dub"}, "a dub server must never be dropped from Anikoto"
    assert any(d["provider"] == "AnimeHeaven" for d in _bundle()["downloads"])


def test_provider_code_and_mirrors_are_still_present():
    source = (ROOT / "streaming_providers.py").read_text(encoding="utf-8")
    for marker in (
        "class AnimeHeavenProvider",
        "class AnikotoProvider",
        "fastsearch.php",
        "gate.php",
        "rt.animeheaven.me",
        "megaplay",
        "/api/proxy/video",
        "/api/proxy/hls",
        "/api/download/video",
        "/api/download/hls",
    ):
        assert marker.lower() in source.lower(), f"{marker} disappeared"

    app_source = (ROOT / "app.py").read_text(encoding="utf-8")
    for marker in ("vidlink.pro", "vidsrc.cc", "episode-sources"):
        assert marker in app_source, f"{marker} disappeared"


def test_worker_mirror_keeps_the_same_providers():
    worker = (ROOT / "cloudflare" / "src" / "providers.js").read_text(encoding="utf-8")
    for marker in (
        "AnimeHeaven",
        "anikoto",
        "vidlink",
        "vidsrc",
        "heaven-mp4-",
        "EXPECTED_PROVIDERS",
    ):
        assert marker.lower() in worker.lower(), f"{marker} disappeared from the mirror"
