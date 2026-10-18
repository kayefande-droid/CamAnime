"""Security regression tests: headers, scanner blocking, rate limiting."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import app as camanime  # noqa: E402


def client():
    camanime.app.config["TESTING"] = True
    # Each test gets a clean limiter so buckets never leak between tests.
    camanime._RATE_BUCKETS.clear()
    return camanime.app.test_client()


def test_security_headers_present():
    r = client().get("/")
    assert r.headers["X-Content-Type-Options"] == "nosniff"
    assert r.headers["X-Frame-Options"] == "SAMEORIGIN"
    assert r.headers["Strict-Transport-Security"].startswith("max-age=")
    assert r.headers["Cross-Origin-Opener-Policy"] == "same-origin"
    assert r.headers["X-XSS-Protection"] == "1; mode=block"
    csp = r.headers["Content-Security-Policy"]
    assert "default-src 'self'" in csp
    assert "object-src 'none'" in csp
    assert "frame-ancestors 'self'" in csp


def test_scanner_paths_are_blocked():
    c = client()
    for path in ("/.env", "/wp-login.php", "/.git/config", "/etc/passwd"):
        assert c.get(path).status_code == 404, path


def test_login_is_rate_limited():
    c = client()
    codes = [
        c.post("/api/auth/login", json={"email": "a@b.c", "password": "nope"}).status_code
        for _ in range(14)
    ]
    assert 429 in codes, "login endpoint must throttle brute-force attempts"
    limited = c.post("/api/auth/login", json={"email": "a@b.c", "password": "nope"})
    assert limited.status_code == 429
    assert limited.headers["Retry-After"] == "60"


def test_oversized_path_is_rejected():
    assert client().get("/" + "a" * 600).status_code in (400, 404)


def test_video_stream_preserves_range_and_streams_chunks(monkeypatch):
    class Upstream:
        status_code = 206
        headers = {
            "Content-Type": "video/mp4",
            "Content-Length": "4",
            "Content-Range": "bytes 0-3/8",
            "Accept-Ranges": "bytes",
        }

        def iter_content(self, chunk_size):
            assert chunk_size == 262144
            yield b"data"

        def close(self):
            self.closed = True

    captured = {}
    monkeypatch.setattr(camanime, "_safe_upstream_url", lambda _url: "https://cdn.example/video.mp4")
    monkeypatch.setattr(camanime.platform, "bump_counter", lambda *_args, **_kwargs: None)
    monkeypatch.setattr(
        camanime.requests, "get",
        lambda url, **kwargs: (captured.update(url=url, **kwargs) or Upstream()),
    )
    response = client().get(
        "/api/proxy/video?url=https%3A%2F%2Fcdn.example%2Fvideo.mp4",
        headers={"Range": "bytes=0-3"},
    )
    assert response.status_code == 206
    assert response.data == b"data"
    assert response.headers["Content-Range"] == "bytes 0-3/8"
    assert captured["headers"]["Range"] == "bytes=0-3"
    assert captured["stream"] is True


def test_download_range_query_is_forwarded_without_buffering(monkeypatch):
    class Upstream:
        status_code = 206
        headers = {
            "Content-Type": "video/mp4",
            "Content-Length": "4",
            "Content-Range": "bytes 10-13/100",
            "Accept-Ranges": "bytes",
        }

        def iter_content(self, chunk_size):
            assert chunk_size == 1048576
            yield b"part"

        def close(self):
            self.closed = True

    captured = {}

    class Session:
        def get(self, url, **kwargs):
            captured.update(url=url, **kwargs)
            return Upstream()

    monkeypatch.setattr(camanime, "_safe_upstream_url", lambda _url: "https://cdn.example/video.mp4")
    monkeypatch.setattr(camanime.platform, "bump_counter", lambda *_args, **_kwargs: None)
    monkeypatch.setattr(camanime, "_shared_http_session", lambda: Session())
    response = client().get(
        "/api/download/video?url=https%3A%2F%2Fcdn.example%2Fvideo.mp4&range=10-13"
    )
    assert response.status_code == 206
    assert response.data == b"part"
    assert response.headers["Content-Range"] == "bytes 10-13/100"
    assert captured["headers"]["Range"] == "bytes=10-13"
    assert captured["stream"] is True


def test_ad_hosts_remain_blocked_for_streaming(monkeypatch):
    monkeypatch.setattr(camanime, "_safe_upstream_url", lambda _url: "https://doubleclick.net/video.mp4")
    response = client().get("/api/proxy/video?url=https%3A%2F%2Fdoubleclick.net%2Fvideo.mp4")
    assert response.status_code == 403
