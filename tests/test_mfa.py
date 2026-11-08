import base64
import importlib
import sys
import time
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
    for name in ("app", "camanime_platform", "app_version", "mfa", "push"):
        sys.modules.pop(name, None)
    module = importlib.import_module("app")
    module.app.config.update(TESTING=True)
    yield module
    for name in ("app", "camanime_platform", "app_version", "mfa", "push"):
        sys.modules.pop(name, None)
    if str(ROOT) in sys.path:
        sys.path.remove(str(ROOT))


def _make_admin(api, email="owner@example.com", password="strongpass123"):
    api.platform.create_admin_user(email, "Owner", password)
    return email


def _admin_headers(api, email):
    return {"Authorization": f"Bearer {api.platform.issue_token(email)['token']}"}


def test_totp_matches_rfc6238_reference_vectors(api):
    """RFC 6238 Appendix B, SHA-1, truncated to six digits."""
    secret = base64.b32encode(b"12345678901234567890").decode()
    assert api.mfa.code_at(secret, at=59) == "287082"
    assert api.mfa.code_at(secret, at=1111111109) == "081804"
    assert api.mfa.code_at(secret, at=1234567890) == "005924"


def test_enrollment_requires_a_valid_code_and_returns_recovery_codes(api):
    email = _make_admin(api)
    client = api.app.test_client()
    headers = _admin_headers(api, email)

    assert client.get("/api/admin/mfa", headers=headers).get_json()["mfa"]["enabled"] is False

    start = client.post("/api/admin/mfa/enroll", json={}, headers=headers)
    assert start.status_code == 200
    body = start.get_json()
    assert body["otpauth_url"].startswith("otpauth://totp/")
    assert len(body["secret"]) >= 16
    secret = body["secret"]

    wrong = client.post("/api/admin/mfa/confirm", json={"code": "000000"},
                        headers=headers)
    assert wrong.status_code == 400
    assert api.mfa.is_enabled(email) is False

    code = api.mfa.code_at(secret)
    done = client.post("/api/admin/mfa/confirm", json={"code": code},
                       headers=headers)
    assert done.status_code == 200
    assert api.mfa.status(email)["enabled"] is True
    recovery = done.get_json()["recovery_codes"]
    assert len(recovery) == 8
    assert all(len(c) == 9 and c[4] == "-" for c in recovery)
    # The secret is never echoed by the status endpoint.
    assert "secret" not in client.get("/api/admin/mfa", headers=headers).get_json()["mfa"]


def test_password_alone_cannot_sign_in_after_enrollment(api):
    email = _make_admin(api)
    client = api.app.test_client()
    headers = _admin_headers(api, email)
    secret = client.post("/api/admin/mfa/enroll", json={},
                         headers=headers).get_json()["secret"]
    confirm_code = api.mfa.code_at(secret)
    client.post("/api/admin/mfa/confirm", json={"code": confirm_code},
                headers=headers)

    no_code = client.post("/api/auth/login",
                          json={"email": email, "password": "strongpass123"})
    assert no_code.status_code == 401
    assert no_code.get_json()["mfa_required"] is True
    assert "token" not in no_code.get_json()

    bad = client.post("/api/auth/login",
                      json={"email": email, "password": "strongpass123",
                            "code": "111111"})
    assert bad.status_code == 401

    # A code from the next time step is valid (and not a replay of the one used
    # to confirm enrolment, which is deliberately single-use).
    fresh = api.mfa.code_at(secret, at=time.time() + 31)
    ok = client.post("/api/auth/login",
                     json={"email": email, "password": "strongpass123",
                           "code": fresh})
    assert ok.status_code == 200, ok.get_json()
    assert ok.get_json()["token"]

    replay = client.post("/api/auth/login",
                         json={"email": email, "password": "strongpass123",
                               "code": fresh})
    assert replay.status_code == 401


def test_recovery_code_works_once_then_stops(api):
    email = _make_admin(api)
    client = api.app.test_client()
    headers = _admin_headers(api, email)
    secret = client.post("/api/admin/mfa/enroll", json={},
                         headers=headers).get_json()["secret"]
    recovery = client.post("/api/admin/mfa/confirm",
                           json={"code": api.mfa.code_at(secret)},
                           headers=headers).get_json()["recovery_codes"]

    first = client.post("/api/auth/login",
                        json={"email": email, "password": "strongpass123",
                              "code": recovery[0]})
    assert first.status_code == 200
    assert client.post("/api/auth/login",
                       json={"email": email, "password": "strongpass123",
                             "code": recovery[0]}).status_code == 401
    assert api.mfa.status(email)["recovery_codes_remaining"] == 7


def test_web_login_shows_the_code_step_and_then_redirects(api):
    email = _make_admin(api)
    client = api.app.test_client()
    headers = _admin_headers(api, email)
    secret = client.post("/api/admin/mfa/enroll", json={},
                         headers=headers).get_json()["secret"]
    client.post("/api/admin/mfa/confirm",
                json={"code": api.mfa.code_at(secret)}, headers=headers)

    page = client.post("/login", data={"email": email,
                                       "password": "strongpass123"})
    assert page.status_code == 200
    assert b"Authenticator code" in page.data
    assert b"name=\"code\"" in page.data

    fresh = api.mfa.code_at(secret, at=time.time() + 31)
    ok = client.post("/login", data={"email": email,
                                     "password": "strongpass123",
                                     "code": fresh})
    assert ok.status_code == 302
    assert ok.headers["Location"].endswith("/")


def test_non_admins_are_not_affected_and_cannot_enroll(api):
    api.platform.register_user(None, "fan@example.com", "Fan", "fanpass1")
    api.platform.create_admin_user("owner@example.com", "Owner", "strongpass123")
    client = api.app.test_client()

    login = client.post("/api/auth/login",
                        json={"email": "fan@example.com", "password": "fanpass1"})
    assert login.status_code == 200
    assert client.get("/api/admin/mfa").status_code == 403
    assert client.post("/api/admin/mfa/enroll", json={}).status_code == 403


class _Clock:
    """Controllable clock so step boundaries cannot make these tests flaky."""

    def __init__(self, start: float):
        self.now = start

    def time(self) -> float:
        return self.now


def test_disable_requires_a_current_code(api, monkeypatch):
    clock = _Clock(1_800_000_000.0)
    monkeypatch.setattr(api.mfa, "time", clock)
    email = _make_admin(api)
    client = api.app.test_client()
    headers = _admin_headers(api, email)
    secret = client.post("/api/admin/mfa/enroll", json={},
                         headers=headers).get_json()["secret"]
    confirm_code = api.mfa.code_at(secret)
    client.post("/api/admin/mfa/confirm",
                json={"code": confirm_code}, headers=headers)

    refused = client.post("/api/admin/mfa/disable", json={"code": "000000"},
                          headers=headers)
    assert refused.status_code == 400
    assert api.mfa.is_enabled(email) is True

    # The confirmation code cannot be replayed to disable MFA, and the error
    # explains why instead of claiming the code is invalid.
    replay = client.post("/api/admin/mfa/disable", json={"code": confirm_code},
                         headers=headers)
    assert replay.status_code == 400
    assert "already used" in replay.get_json()["error"]
    assert api.mfa.is_enabled(email) is True

    clock.now += api.mfa.STEP_SECONDS
    fresh = api.mfa.code_at(secret)
    off = client.post("/api/admin/mfa/disable", json={"code": fresh},
                      headers=headers)
    assert off.status_code == 200
    assert api.mfa.is_enabled(email) is False
    # With MFA off the password is enough again.
    assert client.post("/api/auth/login",
                       json={"email": email,
                             "password": "strongpass123"}).status_code == 200


def test_mfa_required_flag_blocks_unenrolled_admins(api, monkeypatch):
    monkeypatch.setenv("CAMANIME_ADMIN_MFA_REQUIRED", "1")
    email = _make_admin(api)
    client = api.app.test_client()
    res = client.post("/api/auth/login",
                      json={"email": email, "password": "strongpass123"})
    assert res.status_code == 401
    assert res.get_json()["mfa_required"] is True
