"""A page URL with a trailing slash must land on the page, not a 404.

Werkzeug only matches the exact rule, so `/download/` used to 404 while
`/download` worked. The Cloudflare mirror redirects the same way, so both hosts
answer one canonical URL per page.
"""
import importlib
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


def _load_client(tmp_path, monkeypatch, extra_env=None):
    monkeypatch.setenv("CAMANIME_DB", str(tmp_path / "test.db"))
    monkeypatch.setenv("CAMANIME_SECRET", "test-secret-not-for-production")
    monkeypatch.delenv("CAMANIME_ADMIN_EMAIL", raising=False)
    monkeypatch.delenv("CAMANIME_ADMIN_PASSWORD", raising=False)
    for key, value in (extra_env or {}).items():
        monkeypatch.setenv(key, value)
    sys.path.insert(0, str(ROOT))
    modules = ("app", "camanime_platform", "app_version", "mfa", "push")
    for name in modules:
        sys.modules.pop(name, None)
    module = importlib.import_module("app")
    module.app.config.update(TESTING=True)
    return module.app.test_client()


@pytest.fixture()
def client(tmp_path, monkeypatch):
    yield _load_client(tmp_path, monkeypatch)
    for name in ("app", "camanime_platform", "app_version", "mfa", "push"):
        sys.modules.pop(name, None)
    if str(ROOT) in sys.path:
        sys.path.remove(str(ROOT))


@pytest.fixture()
def custom_origin_client(tmp_path, monkeypatch):
    yield _load_client(
        tmp_path, monkeypatch, {"CAMANIME_PUBLIC_ORIGIN": "https://camanime.example"}
    )
    for name in ("app", "camanime_platform", "app_version", "mfa", "push"):
        sys.modules.pop(name, None)
    if str(ROOT) in sys.path:
        sys.path.remove(str(ROOT))


@pytest.mark.parametrize("path", ["/download/", "/developers/", "/settings/"])
def test_trailing_slash_redirects_to_the_page(client, path):
    response = client.get(path, follow_redirects=False)
    assert response.status_code == 308
    assert response.headers["Location"].endswith(path.rstrip("/"))


def test_trailing_slash_keeps_the_query_string(client):
    response = client.get("/search/?q=naruto", follow_redirects=False)
    assert response.status_code == 308
    assert response.headers["Location"].endswith("/search?q=naruto")


def test_root_is_untouched(client):
    response = client.get("/", follow_redirects=False)
    assert response.status_code == 200


# ── Custom domain: one hostname, one canonical ──


def test_www_redirects_to_the_configured_apex(custom_origin_client):
    response = custom_origin_client.get(
        "/anime/21?eps=2", headers={"Host": "www.camanime.example"}, follow_redirects=False
    )
    assert response.status_code == 301
    assert response.headers["Location"] == "https://camanime.example/anime/21?eps=2"


def test_apex_is_served_without_a_redirect(custom_origin_client):
    response = custom_origin_client.get(
        "/download", headers={"Host": "camanime.example"}, follow_redirects=False
    )
    assert response.status_code == 200


def test_canonical_names_the_configured_origin(custom_origin_client):
    response = custom_origin_client.get("/download", headers={"Host": "camanime.example"})
    html = response.data.decode("utf-8")
    assert '<link rel="canonical" href="https://camanime.example/download">' in html
    assert "camanime.onrender.com" not in html


def test_sitemap_and_robots_use_the_configured_origin(custom_origin_client):
    robots = custom_origin_client.get("/robots.txt").data.decode("utf-8")
    assert "Sitemap: https://camanime.example/sitemap.xml" in robots
    sitemap = custom_origin_client.get("/sitemap.xml").data.decode("utf-8")
    assert "https://camanime.example/" in sitemap
    assert "camanime.onrender.com" not in sitemap


def test_render_hostname_stays_reachable_for_health_checks(client):
    # No CAMANIME_PUBLIC_ORIGIN set: the Render host itself must answer, never
    # redirect, so Render's health check and the mirror's relay keep working.
    response = client.get("/healthz", follow_redirects=False)
    assert response.status_code == 200
    html = client.get("/download").data.decode("utf-8")
    assert '<link rel="canonical" href="https://camanime.onrender.com/download">' in html
