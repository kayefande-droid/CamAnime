"""Resolution-reduced downloads (the YouTube-style quality ladder).

Providers usually publish one 1080p file per episode. That file is 300-500 MB,
which is a lot to keep on a phone. This module re-encodes it on the server into
a smaller height with a bounded bitrate, so the *same* episode can be saved at
roughly a third of the size without the user hunting for a mirror that happens
to offer 360p.

The encode is streamed: ffmpeg writes fragmented MP4 to stdout and the HTTP
response forwards it, so the download starts immediately instead of waiting for
the whole file to be re-encoded and stored. Nothing is cached on disk, so a
long episode cannot fill the host.

Sizes are set by profile rather than guessed: 360p at ~700 kbps video plus
64 kbps audio is about 120-140 MB for a 24-minute episode, against ~365 MB for
a typical 1080p source.

Requires the `ffmpeg` binary on the host (`CAMANIME_FFMPEG` overrides the path).
Without it `available()` is False and the endpoints report that honestly rather
than pretending a smaller file exists.
"""
import os
import shutil
import subprocess
from typing import Dict, Iterable, List, Optional
from urllib.parse import quote

# height -> encode settings. maxrate caps the size; crf keeps the picture sane
# on easy scenes so the cap is rarely the limiting factor.
PROFILES: Dict[int, Dict[str, int]] = {
    360: {"height": 360, "video_kbps": 700, "audio_kbps": 64},
    480: {"height": 480, "video_kbps": 1100, "audio_kbps": 96},
    720: {"height": 720, "video_kbps": 2000, "audio_kbps": 128},
}

# Offered in this order: best quality first, smallest last.
SAFE_HEIGHTS = (720, 480, 360)


def ffmpeg_path() -> str:
    override = (os.environ.get("CAMANIME_FFMPEG") or "").strip()
    if override and os.path.isfile(override):
        return override
    return shutil.which("ffmpeg") or ""


def available() -> bool:
    return bool(ffmpeg_path())


def profile(height) -> Optional[Dict[str, int]]:
    try:
        value = int(height)
    except (TypeError, ValueError):
        return None
    return PROFILES.get(value)


def estimated_mb(height, seconds: float) -> float:
    """Rough finished size for a duration, used for the UI promise."""
    prof = profile(height)
    if not prof or not seconds:
        return 0.0
    bits = (prof["video_kbps"] + prof["audio_kbps"]) * 1000
    return round(bits * float(seconds) / 8 / 1024 / 1024, 1)


def build_command(source: str, height, referer: str = "",
                  user_agent: str = "Mozilla/5.0") -> List[str]:
    """ffmpeg argv for one streamed re-encode.

    `min(height,ih)` means a 720p source is never upscaled to 720p-bigger, and
    a 360p request on a 360p source still produces a valid file.
    """
    prof = profile(height) or PROFILES[360]
    cmd = [ffmpeg_path() or "ffmpeg", "-nostdin", "-hide_banner",
           "-loglevel", "error"]
    if source.lower().startswith(("http://", "https://")):
        headers = f"User-Agent: {user_agent}\r\n"
        if referer:
            headers += f"Referer: {referer}\r\n"
        cmd += ["-headers", headers]
    cmd += [
        "-i", source,
        "-map", "0:v:0", "-map", "0:a:0?",
        "-vf", f"scale=-2:'min({prof['height']},ih)'",
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "26",
        "-maxrate", f"{prof['video_kbps']}k",
        "-bufsize", f"{prof['video_kbps'] * 2}k",
        "-c:a", "aac", "-b:a", f"{prof['audio_kbps']}k", "-ac", "2",
        # Fragmented MP4: playable/seekable while still downloading, and
        # requires no temporary file on the server.
        "-movflags", "frag_keyframe+empty_moov+default_base_moof",
        "-f", "mp4", "pipe:1",
    ]
    return cmd


def stream(source: str, height, referer: str = "",
           user_agent: str = "Mozilla/5.0") -> Iterable[bytes]:
    """Yield the converted file as it is produced. Kills ffmpeg on abort."""
    cmd = build_command(source, height, referer=referer, user_agent=user_agent)
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        bufsize=0,
    )
    try:
        assert proc.stdout is not None
        while True:
            chunk = proc.stdout.read(256 * 1024)
            if not chunk:
                break
            yield chunk
    finally:
        try:
            proc.kill()
        except Exception:
            pass
        try:
            if proc.stdout is not None:
                proc.stdout.close()
        except Exception:
            pass
        try:
            proc.wait(timeout=5)
        except Exception:
            pass


def transcode_url(source: str, height, title: str = "CamAnime_Episode",
                  referer: str = "") -> str:
    query = [
        f"url={quote(source, safe='')}",
        f"height={int(height)}",
        f"title={quote(title, safe='')}",
    ]
    if referer:
        query.append(f"ref={quote(referer, safe='')}")
    return "/api/download/transcode?" + "&".join(query)


def stream_url(source: str, height, title: str = "CamAnime_Episode",
               referer: str = "") -> str:
    """Inline playback URL for the converted episode (no attachment header)."""
    query = [
        f"url={quote(source, safe='')}",
        f"height={int(height)}",
        f"title={quote(title, safe='')}",
    ]
    if referer:
        query.append(f"ref={quote(referer, safe='')}")
    return "/api/stream/transcode?" + "&".join(query)


def upstream_url(server: Dict) -> str:
    """Best real media URL on a server entry.

    Newer seasons sometimes resolve through a proxy (stream_url) or a download
    URL without a raw_url. Falling back keeps those titles on the real quality
    ladder instead of silently offering only the full-size file.
    """
    for key in ("raw_url", "download_url", "stream_url"):
        value = (server.get(key) or "").strip()
        if value.startswith(("http://", "https://")):
            return value
    return ""


def add_stream_options(servers: List[Dict], title: str,
                       episode: Optional[int] = None) -> List[Dict]:
    """Append genuinely re-encoded 720p/480p/360p *streams* per audio track.

    The original sources are kept first, so a viewer still gets the best
    quality by default. Only one source per audio language is converted (the
    highest-priority one) because every converted mirror would cost a separate
    ffmpeg process per viewer; the resulting variants are real pixels, not
    labels on the same 1080p file.
    """
    if not available():
        return servers
    result = list(servers or [])
    first_by_audio: Dict[str, Dict] = {}
    for server in servers or []:
        if server.get("playback_mode") not in ("mp4", "hls"):
            continue
        if not upstream_url(server):
            continue
        first_by_audio.setdefault((server.get("audio") or "sub"), server)

    label_title = (title or "CamAnime").strip()[:70]
    episode_label = f"Ep {episode} " if episode else ""
    for audio, server in first_by_audio.items():
        raw = upstream_url(server)
        for height in SAFE_HEIGHTS:
            result.append({
                "id": f"transcode-{audio}-{height}",
                "name": f"CamAnime {height}p",
                "provider": "CamAnime re-encode",
                "audio": audio,
                "playback_mode": "mp4",
                "stream_url": stream_url(
                    raw, height,
                    title=f"{label_title} - {episode_label}".strip("- "),
                    referer=server.get("referer", ""),
                ),
                "quality": f"{height}p",
                "subtitles": server.get("subtitles") or [],
                "badge": "REAL PIXELS",
                "transcode": True,
                "height": height,
            })
    return result


def add_download_options(downloads: List[Dict], servers: List[Dict],
                         title: str, episode: Optional[int] = None) -> List[Dict]:
    """Append 720p/480p/360p converted files for every real MP4/HLS source.

    Only sources that are actually downloadable are used, and each source gets
    at most one option per height, so a provider listed twice cannot flood the
    download manager with duplicates.
    """
    if not available():
        return downloads
    seen = set()
    label_title = (title or "CamAnime").strip()[:70]
    for server in servers or []:
        if server.get("playback_mode") not in ("mp4", "hls"):
            continue
        raw = upstream_url(server)
        if not raw:
            continue
        audio = (server.get("audio") or "sub").upper()
        for height in SAFE_HEIGHTS:
            key = (raw, height, audio)
            if key in seen:
                continue
            seen.add(key)
            episode_label = f"Ep {episode} " if episode else ""
            downloads.append({
                "label": (f"{label_title} — {episode_label}{audio} · "
                          f"{height}p converted"),
                "quality": f"{height}p",
                "audio": audio,
                "url": transcode_url(raw, height,
                                     title=f"{label_title} - {episode_label}".strip("- "),
                                     referer=server.get("referer", "")),
                "direct": True,
                "transcode": True,
                "provider": server.get("name") or "CamAnime",
            })
    return downloads
