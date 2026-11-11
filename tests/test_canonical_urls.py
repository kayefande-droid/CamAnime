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


@pytest.fixture()
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("CAMANIME_DB", str(tmp_path / "test.db"))
    monkeypatch.setenv("CAMANIME_SECRET", "test-secret-not-for-production")
    monkeypatch.delenv("CAMANIME_ADMIN_EMAIL", raising=False)
    monkeypatch.delenv("CAMANIME_ADMIN_PASSWORD", raising=False)
    sys.path.insert(0, str(ROOT))
    modules = ("app", "camanime_platform", "app_version", "mfa", "push")
    for name in modules:
        sys.modules.pop(name, None)
    module = importlib.import_module("app")
    module.app.config.update(TESTING=True)
    yield module.app.test_client()
    for name in modules:
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
