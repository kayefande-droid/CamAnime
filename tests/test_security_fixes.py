"""Regression tests for the security review findings.

Each test drives the real Flask app, so it fails again if the guard is removed.
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
    monkeypatch.delenv("CAMANIME_ADMIN_MFA_REQUIRED", raising=False)
    sys.path.insert(0, str(ROOT))
    for name in ("app", "camanime_platform", "app_version", "mfa", "push",
                 "releases"):
        sys.modules.pop(name, None)
    module = importlib.import_module("app")
    module.app.config.update(TESTING=True)
    module._RATE_BUCKETS.clear()
    yield module
    for name in ("app", "camanime_platform", "app_version", "mfa", "push",
                 "releases"):
        sys.modules.pop(name, None)
    if str(ROOT) in sys.path:
        sys.path.remove(str(ROOT))


def bearer(api, email, role="owner", password="strongpass123"):
    api.platform.create_admin_user(email, email.split("@")[0], password, role)
    return {"Authorization": f"Bearer {api.platform.issue_token(email)['token']}"}


def test_comment_sticker_must_come_from_the_published_set(api):
    """A sticker is rendered as markup, so arbitrary HTML must never be stored."""
    client = api.app.test_client()
    payload = '<img src=x onerror="alert(1)">'
    posted = client.post("/api/community/comment",
                         json={"anime_id": "16498", "ep": "1",
                               "text": "nice episode", "sticker": payload})
    assert posted.status_code == 200
    stored = posted.get_json()["comment"]["sticker"]
    assert stored == "", stored
    listed = client.get("/api/community/comments?anime_id=16498&ep=1").get_json()
    assert all(c["sticker"] == "" for c in listed["comments"])
    # A sticker-only post with markup has nothing valid left, so it is refused.
    with client.session_transaction() as sess:
        sess.pop("guest_last_comment", None)
    rejected = client.post("/api/community/comment",
                           json={"anime_id": "16498", "ep": "1",
                                 "text": "", "sticker": payload})
    assert rejected.status_code == 400
    # The published set still works (the per-session guest spam throttle is
    # cleared so the assertion is about the sticker, not about timing).
    with client.session_transaction() as sess:
        sess.pop("guest_last_comment", None)
    ok = client.post("/api/community/comment",
                     json={"anime_id": "16498", "ep": "1", "sticker": "\U0001F525"})
    assert ok.status_code == 200
    assert ok.get_json()["comment"]["sticker"] == "\U0001F525"


def test_non_owner_admin_cannot_reset_the_owner_password(api):
    """Support must not be able to seize the owner account via password reset."""
    client = api.app.test_client()
    bearer(api, "owner@example.com")
    support = bearer(api, "support@example.com", role="support")
    attempt = client.post("/api/admin/password",
                          json={"target_email": "owner@example.com",
                                "new_password": "hijacked123"}, headers=support)
    assert attempt.status_code == 403
    # The owner password is untouched: the original still signs in.
    login = client.post("/api/auth/login",
                        json={"email": "owner@example.com",
                              "password": "strongpass123"})
    assert login.status_code == 200


def test_owner_may_still_reset_another_account(api):
    client = api.app.test_client()
    owner = bearer(api, "owner@example.com")
    api.platform.register_user({}, "fan@example.com", "Fan", "fanpass1")
    reset = client.post("/api/admin/password",
                        json={"target_email": "fan@example.com",
                              "new_password": "brandnew123"}, headers=owner)
    assert reset.status_code == 200
    login = client.post("/api/auth/login",
                        json={"email": "fan@example.com", "password": "brandnew123"})
    assert login.status_code == 200


@pytest.mark.parametrize("url", [
    "http://127.0.0.1/video.mp4",
    "http://10.0.0.5/video.mp4",
    "http://172.16.4.4/video.mp4",
    "http://192.168.1.1/video.mp4",
    "http://169.254.169.254/latest/meta-data/",
    "http://[::1]/video.mp4",
    "file:///etc/passwd",
])
def test_media_proxy_refuses_internal_addresses(api, url):
    assert api._safe_upstream_url(url) is None, url


def test_media_proxy_allows_a_public_address(api):
    assert api._safe_upstream_url("http://1.1.1.1/video.mp4") == "http://1.1.1.1/video.mp4"
