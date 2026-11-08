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
    sys.path.insert(0, str(ROOT))
    for name in ("app", "camanime_platform", "app_version"):
        sys.modules.pop(name, None)
    module = importlib.import_module("app")
    module.app.config.update(TESTING=True)
    yield module
    for name in ("app", "camanime_platform", "app_version"):
        sys.modules.pop(name, None)
    if str(ROOT) in sys.path:
        sys.path.remove(str(ROOT))


def app_headers(build, version=None, install="install-test-0001"):
    from app_version import DEFAULT_POLICY
    return {
        "X-CamAnime-Version": version or DEFAULT_POLICY["latest_version"],
        "X-CamAnime-Build": str(build),
        "X-CamAnime-Platform": "android",
        "X-CamAnime-Install": install,
    }


def admin_headers(api, email="ops@example.com"):
    api.platform.create_admin_user(email, "Ops", "strongpass123")
    token = api.platform.issue_token(email)["token"]
    return {"Authorization": f"Bearer {token}"}


def test_version_endpoint_is_reachable_from_an_outdated_build(api):
    from app_version import DEFAULT_POLICY
    client = api.app.test_client()
    res = client.get("/api/app/version", headers=app_headers(16, "2.6.5"))
    assert res.status_code == 200
    body = res.get_json()
    assert body["policy"]["latest_version"] == DEFAULT_POLICY["latest_version"]
    assert body["policy"]["minimum_supported_version_code"] == 19
    assert body["required"] is True


def test_outdated_build_gets_structured_426_on_protected_api(api):
    from app_version import DEFAULT_POLICY
    client = api.app.test_client()
    res = client.post("/api/public/stream/download", json={"kind": "stream"},
                      headers=app_headers(16, "2.6.5"))
    assert res.status_code == 426
    body = res.get_json()
    assert body["code"] == "APP_UPDATE_REQUIRED"
    assert body["force_update"] is True
    assert body["latest_version"] == DEFAULT_POLICY["latest_version"]
    assert body["download_url"].startswith("https://camanime.onrender.com")
    # Build 16 is 2.6.5, which is discontinued: the message says that instead
    # of the generic "outdated" wording.
    assert body["discontinued"] is True
    assert "discontinued" in body["message"].lower()
    assert res.headers["X-CamAnime-Min-Build"] == "19"


def test_supported_build_is_allowed(api):
    client = api.app.test_client()
    res = client.post("/api/public/stream/download", json={"kind": "stream"},
                      headers=app_headers(19))
    assert res.status_code == 200


def test_browser_requests_without_build_header_are_unaffected(api):
    client = api.app.test_client()
    assert client.post("/api/public/stream/download",
                       json={"kind": "stream"}).status_code == 200
    assert client.get("/api/version").status_code == 200


def test_admin_policy_endpoint_rejects_anonymous_and_regular_users(api):
    client = api.app.test_client()
    assert client.get("/api/admin/version-policy").status_code == 403
    api.platform.register_user({}, "user@example.com", "User", "password123")
    token = api.platform.issue_token("user@example.com")["token"]
    res = client.get("/api/admin/version-policy",
                     headers={"Authorization": f"Bearer {token}"})
    assert res.status_code == 403


def test_policy_change_blocks_newly_unsupported_builds_and_is_audited(api):
    from app_version import DEFAULT_POLICY
    client = api.app.test_client()
    admin = admin_headers(api)
    latest_version = DEFAULT_POLICY["latest_version"]
    latest_version_code = DEFAULT_POLICY["latest_version_code"]
    # Raise the minimum above the current bar so a previously-supported build is
    # refused by the server (not just by the app UI). The new minimum must still
    # be <= the latest build the server is shipping.
    new_min_code = latest_version_code - 1
    res = client.post("/api/admin/version-policy", json={
        "latest_version": latest_version, "latest_version_code": latest_version_code,
        "minimum_supported_version": DEFAULT_POLICY["minimum_supported_version"],
        "minimum_supported_version_code": new_min_code,
        "force_update": True, "confirm_force_update": True,
        "download_url": "https://camanime.onrender.com/get/android",
        "release_notes": "Fix", "update_message": "Update now.",
    }, headers=admin)
    assert res.status_code == 200
    assert res.get_json()["policy"]["minimum_supported_version_code"] == DEFAULT_POLICY["latest_version_code"] - 1

    # The build just below the new minimum is now refused by the server.
    blocked = client.post("/api/public/stream/download",
                          json={"kind": "stream"}, headers=app_headers(new_min_code - 1))
    assert blocked.status_code == 426

    log = client.get("/api/admin/security-log", headers=admin).get_json()
    assert any(e["action"] == "version_policy.update" for e in log["entries"])


def test_forced_update_needs_explicit_confirmation(api):
    client = api.app.test_client()
    res = client.post("/api/admin/version-policy", json={
        "force_update": True, "minimum_supported_version_code": 99,
        "latest_version_code": 99, "latest_version": "9.9.9",
        "minimum_supported_version": "9.9.9",
    }, headers=admin_headers(api))
    assert res.status_code == 400
    assert "confirm_force_update" in res.get_json()["error"]


def test_policy_validation_rejects_impossible_ranges(api):
    client = api.app.test_client()
    admin = admin_headers(api)
    bad = client.post("/api/admin/version-policy", json={
        "latest_version": "9.9.9", "latest_version_code": 99,
        "minimum_supported_version": "9.9.10",
        "minimum_supported_version_code": 100,
    }, headers=admin)
    assert bad.status_code == 400
    lower = client.post("/api/admin/version-policy", json={
        "latest_version": "2.6.0", "latest_version_code": 10,
        "minimum_supported_version": "2.6.0",
        "minimum_supported_version_code": 10,
        "force_update": False,
    }, headers=admin)
    assert lower.status_code == 400
    assert "rollback" in lower.get_json()["error"]


def test_rollback_restores_the_previous_policy(api):
    client = api.app.test_client()
    admin = admin_headers(api)
    first = {
        "latest_version": "9.9.8", "latest_version_code": 98,
        "minimum_supported_version": "9.9.8",
        "minimum_supported_version_code": 98,
        "force_update": True, "confirm_force_update": True,
        "download_url": "https://camanime.onrender.com/get/android",
        "release_notes": "First", "update_message": "First.",
    }
    second = {
        "latest_version": "9.9.9", "latest_version_code": 99,
        "minimum_supported_version": "9.9.9",
        "minimum_supported_version_code": 99,
        "force_update": True, "confirm_force_update": True,
        "download_url": "https://camanime.onrender.com/get/android",
        "release_notes": "Second", "update_message": "Second.",
    }
    client.post("/api/admin/version-policy", json=first, headers=admin)
    client.post("/api/admin/version-policy", json=second, headers=admin)
    back = client.post("/api/admin/version-policy/rollback", json={},
                       headers=admin)
    assert back.status_code == 200
    assert back.get_json()["policy"]["latest_version"] == first["latest_version"]


def test_ping_records_the_install_for_adoption_reporting(api):
    client = api.app.test_client()
    res = client.get("/api/app/ping", headers=app_headers(16, "2.6.5",
                                                          "install-old-01"))
    assert res.status_code == 200
    assert res.get_json()["required"] is True
    stats = client.get("/api/admin/version-policy",
                       headers=admin_headers(api)).get_json()["stats"]
    assert stats["devices"] == 1
    assert stats["outdated_devices"] == 1


def test_notify_reports_delivery_honestly_without_a_push_transport(api):
    client = api.app.test_client()
    admin = admin_headers(api)
    client.get("/api/app/ping", headers=app_headers(16, "2.6.5", "install-old-02"))
    res = client.post("/api/admin/version-policy/notify", json={}, headers=admin)
    assert res.status_code == 200
    body = res.get_json()
    assert body["targets"] == 1
    assert body["push_available"] is False
    assert body["push_delivered"] == 0
    assert "update screen" in body["note"]


def test_removed_admin_sync_endpoint_no_longer_exists(api):
    client = api.app.test_client()
    assert client.get("/api/admin/sync",
                      headers=admin_headers(api)).status_code == 404
