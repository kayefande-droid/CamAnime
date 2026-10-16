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
