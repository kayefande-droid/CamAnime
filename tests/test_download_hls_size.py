"""A stitched HLS download must publish its real byte size.

The app uses that length to show the actual file size and to reject a transfer
that ended before the whole episode arrived.
"""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import app as camanime  # noqa: E402

PLAYLIST = """#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXTINF:6.0,
segment-1.ts
#EXTINF:6.0,
segment-2.ts
#EXT-X-ENDLIST
"""


class Reply:
    def __init__(self, text="", headers=None, content=b"", status=200):
        self.text = text
        self.headers = headers or {}
        self.content = content
        self.status_code = status

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError(f"upstream {self.status_code}")


class Session:
    def get(self, url, **_kwargs):
        if url.endswith(".m3u8"):
            return Reply(text=PLAYLIST)
        return Reply(headers={"Content-Length": "100"}, content=b"x" * 100)

    def head(self, _url, **_kwargs):
        return Reply(headers={"Content-Length": "100"})


@pytest.fixture(autouse=True)
def _isolate_activity_log():
    # The stitch route records a download; do not leak that row into the
    # live-activity tests that run after this file.
    camanime._LIVE_ACTIVITY.clear()
    yield
    camanime._LIVE_ACTIVITY.clear()


def client():
    camanime.app.config["TESTING"] = True
    camanime._RATE_BUCKETS.clear()
    return camanime.app.test_client()


def test_stitched_hls_reports_exact_size_and_streams_every_segment(monkeypatch):
    monkeypatch.setattr(
        camanime, "_safe_upstream_url", lambda _url: "https://cdn.example/master.m3u8"
    )
    monkeypatch.setattr(camanime, "_shared_http_session", lambda: Session())

    response = client().get("/api/download/hls?url=https%3A%2F%2Fcdn.example%2Fmaster.m3u8")

    assert response.status_code == 200
    assert response.headers["Content-Length"] == "200"
    assert response.headers["X-Total-Bytes"] == "200"
    assert response.headers["X-Total-Exact"] == "1"
    assert len(response.data) == 200


def test_head_probe_returns_the_real_size_without_a_body(monkeypatch):
    monkeypatch.setattr(
        camanime, "_safe_upstream_url", lambda _url: "https://cdn.example/master.m3u8"
    )
    monkeypatch.setattr(camanime, "_shared_http_session", lambda: Session())

    response = client().head("/api/download/hls?url=https%3A%2F%2Fcdn.example%2Fmaster.m3u8")

    assert response.status_code == 200
    assert response.headers["Content-Length"] == "200"
    assert response.data == b""
