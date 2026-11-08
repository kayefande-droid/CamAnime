"""The owner console is reachable only at its private path.

`/admin` must 404 for everyone, including signed-in owners, and the private path
must still enforce authentication and roles rather than relying on obscurity.
"""
import importlib
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SECRET_PATH = "/owner-console-test-9f3a"


@pytest.fixture()
def api(tmp_path, monkeypatch):
    monkeypatch.setenv("CAMANIME_DB", str(tmp_path / "test.db"))
    monkeypatch.setenv("CAMANIME_SECRET", "test-secret-not-for-production")
    monkeypatch.setenv("CAMANIME_ADMIN_PATH", SECRET_PATH)
    monkeypatch.delenv("CAMANIME_ADMIN_EMAIL", raising=False)
    monkeypatch.delenv("CAMANIME_ADMIN_PASSWORD", raising=False)
    sys.path.insert(0, str(ROOT))
    modules = ("app", "camanime_platform", "app_version", "mfa", "push")
    for name in modules:
        sys.modules.pop(name, None)
    module = importlib.import_module("app")
    module.app.config.update(TESTING=True)
    yield module
    for name in modules:
        sys.modules.pop(name, None)
    if str(ROOT) in sys.path:
        sys.path.remove(str(ROOT))


def _owner(api, email="owner@example.com"):
    api.platform.create_admin_user(email, "Owner", "strongpass123", "owner")
    return email


def test_public_admin_url_is_a_404(api):
    client = api.app.test_client()
    assert client.get("/admin").status_code == 404
    assert client.get("/admin?next=/admin").status_code == 404


def test_private_path_redirects_anonymous_visitors_to_normal_login(api):
    client = api.app.test_client()
    res = client.get(SECRET_PATH)
    assert res.status_code == 302
    assert "/login" in res.headers["Location"]
    assert "mode=admin" not in res.headers["Location"]


def test_private_path_denies_a_normal_user(api):
    api.platform.register_user(None, "viewer@example.com", "Viewer",
                              "strongpass123")
    client = api.app.test_client()
    with client.session_transaction() as sess:
        sess["user_email"] = "viewer@example.com"
    res = client.get(SECRET_PATH)
    assert res.status_code == 302
    assert "/login" in res.headers["Location"]


def test_owner_can_open_only_the_private_path(api):
    email = _owner(api)
    client = api.app.test_client()
    with client.session_transaction() as sess:
        sess["user_email"] = email
    private = client.get(SECRET_PATH)
    assert private.status_code == 200
    assert b"Admin Control Deck" in private.data
    assert client.get("/admin").status_code == 404


def test_non_admin_settings_never_advertises_the_console(api):
    api.platform.register_user(None, "viewer@example.com", "Viewer",
                              "strongpass123")
    client = api.app.test_client()
    with client.session_transaction() as sess:
        sess["user_email"] = "viewer@example.com"
    body = client.get("/settings").data.decode()
    assert SECRET_PATH not in body
    assert "Admin sign in" not in body


def test_owner_settings_links_to_the_private_path(api):
    email = _owner(api)
    client = api.app.test_client()
    with client.session_transaction() as sess:
        sess["user_email"] = email
    body = client.get("/settings").data.decode()
    assert SECRET_PATH in body
    assert "/admin" not in body


def test_create_admin_api_still_rejects_non_owners(api):
    client = api.app.test_client()
    assert client.post("/api/admin/create-admin",
                       json={"email": "x@example.com", "password": "strongpass123"}
                       ).status_code == 403
