"""Release inventory, RBAC and blocked-build telemetry.

The inventory itself is asserted against the real seeded evidence (builds 12,
13, 15, 16 blocked; 17 and 18 supported).
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
    yield module
    for name in ("app", "camanime_platform", "app_version", "mfa", "push",
                 "releases"):
        sys.modules.pop(name, None)
    if str(ROOT) in sys.path:
        sys.path.remove(str(ROOT))


def app_headers(build, version):
    return {"X-CamAnime-Version": version, "X-CamAnime-Build": str(build),
            "X-CamAnime-Platform": "android",
            "X-CamAnime-Install": f"install-{build}-audit"}


def token(api, email, role="owner", password="strongpass123"):
    api.platform.create_admin_user(email, email.split("@")[0], password, role)
    return {"Authorization": f"Bearer {api.platform.issue_token(email)['token']}"}


def user_token(api, email="fan@example.com"):
    api.platform.register_user({}, email, "Fan", "fanpass1")
    return {"Authorization": f"Bearer {api.platform.issue_token(email)['token']}"}


def test_inventory_seeds_verified_classifications(api):
    rows = {r["version_code"]: r for r in api.releases.list_releases()}
    assert {12, 13, 15, 16} <= set(rows)
    assert all(rows[c]["status"] == "BLOCKED" for c in (12, 13, 15, 16))
    assert rows[17]["status"] == "SUPPORTED"
    assert rows[18]["status"] == "SUPPORTED"
    assert rows[16]["inspection"] == "UNAVAILABLE"  # no 2.6.5 APK exists
    assert rows[12]["inspection"] == "INSPECTED"


def test_blocked_build_gets_both_official_links_and_discontinued_reason(api):
    res = api.app.test_client().get(
        "/api/download/video?url=https%3A%2F%2Fcdn.example%2Fv.mp4",
        headers=app_headers(15, "2.6.4"))
    assert res.status_code == 426
    body = res.get_json()
    assert body["status"] == "update_required"
    assert body["reason"] == "discontinued"
    assert body["download_urls"]["render"].startswith("https://camanime.onrender.com")
    assert body["download_urls"]["cloudflare"].endswith("/get/android")
    assert "discontinued" in body["message"].lower()


def test_blocked_request_is_recorded_for_the_dashboard(api):
    api.app.test_client().get(
        "/api/episode-sources/1/1", headers=app_headers(12, "2.6.1"))
    owner = token(api, "owner@example.com")
    data = api.app.test_client().get("/api/admin/releases",
                                     headers=owner).get_json()
    assert data["blocked"]["total"] >= 1
    assert any(v["code"] == 12 for v in data["blocked"]["versions"])


def test_supported_build_not_flagged_or_blocked(api):
    res = api.app.test_client().get("/api/app/ping", headers=app_headers(17, "2.7.0"))
    body = res.get_json()
    assert body["required"] is False
    assert body["policy"]["reason"] == ""


def test_regular_user_cannot_reach_admin_release_or_user_apis(api):
    client = api.app.test_client()
    fan = user_token(api)
    for path in ("/api/admin/releases", "/api/admin/users",
                 "/api/admin/security-log"):
        assert client.get(path, headers=fan).status_code == 403, path
    assert client.post("/api/admin/releases",
                       json={"version_code": 17, "status": "BLOCKED"},
                       headers=fan).status_code == 403


def test_developer_cannot_change_policy_or_release_status(api):
    client = api.app.test_client()
    dev = token(api, "dev@example.com", "developer")
    assert client.get("/api/admin/releases", headers=dev).status_code == 200
    assert client.get("/api/admin/security-log", headers=dev).status_code == 200
    denied = client.post("/api/admin/releases",
                         json={"version_code": 17, "status": "BLOCKED",
                               "confirm_block": True}, headers=dev)
    assert denied.status_code == 403
    denied_policy = client.post("/api/admin/version-policy",
                                json={"minimum_supported_version_code": 18},
                                headers=dev)
    assert denied_policy.status_code == 403


def test_owner_blocks_and_restores_a_release_with_confirmation(api):
    client = api.app.test_client()
    owner = token(api, "owner@example.com")
    no_confirm = client.post("/api/admin/releases",
                             json={"version_code": 17, "status": "BLOCKED"},
                             headers=owner)
    assert no_confirm.status_code == 400
    blocked = client.post("/api/admin/releases",
                          json={"version_code": 17, "status": "BLOCKED",
                                "confirm_block": True}, headers=owner)
    assert blocked.status_code == 200
    assert blocked.get_json()["release"]["status"] == "BLOCKED"
    restored = client.post("/api/admin/releases",
                           json={"version_code": 17, "status": "SUPPORTED"},
                           headers=owner)
    assert restored.status_code == 200
    assert restored.get_json()["release"]["status"] == "SUPPORTED"
    log = client.get("/api/admin/security-log", headers=owner).get_json()
    assert any(e["action"] == "release.status" for e in log["entries"])


def test_user_list_never_contains_password_hashes(api):
    client = api.app.test_client()
    owner = token(api, "owner@example.com")
    user_token(api)
    body = client.get("/api/admin/users", headers=owner).get_json()
    assert body["users"]
    for row in body["users"]:
        assert set(row) <= {"email", "name", "role", "created"}


def test_owner_role_change_is_audited_and_last_owner_is_protected(api):
    client = api.app.test_client()
    owner = token(api, "owner@example.com")
    user_token(api)
    changed = client.post("/api/admin/users/role",
                          json={"email": "fan@example.com", "role": "support"},
                          headers=owner)
    assert changed.status_code == 200
    assert changed.get_json()["role"] == "support"
    self_demote = client.post("/api/admin/users/role",
                              json={"email": "owner@example.com", "role": "user"},
                              headers=owner)
    assert self_demote.status_code == 400


def test_notify_records_a_measured_campaign(api):
    client = api.app.test_client()
    owner = token(api, "owner@example.com")
    client.get("/api/app/ping", headers=app_headers(16, "2.6.5"))
    res = client.post("/api/admin/version-policy/notify", json={}, headers=owner)
    assert res.status_code == 200
    campaigns = api.push.list_campaigns(5)
    assert campaigns and campaigns[0]["targets"] >= 0
    assert campaigns[0]["available"] in (0, 1)
