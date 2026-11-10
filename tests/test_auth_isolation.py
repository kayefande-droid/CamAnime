"""Two accounts must never see each other's data, and nothing is public by accident.

These exercise the real app through Flask's test client: the web session path and
the bearer-token path both resolve to the same owner check, so each is tested.
"""
import importlib
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture()
def api(tmp_path, monkeypatch):
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
    yield module
    for name in modules:
        sys.modules.pop(name, None)
    if str(ROOT) in sys.path:
        sys.path.remove(str(ROOT))


def _account(api, email, role="user"):
    api.platform.create_admin_user(email, email.split("@")[0], "strongpass123", role)
    return email


def _client(api, email=None):
    client = api.app.test_client()
    if email:
        with client.session_transaction() as sess:
            sess["user_email"] = email
    return client


def _save(api, email, anime_id="207329", ep=3, position=120.0):
    client = _client(api, email)
    res = client.post("/api/history", json={
        "anime_id": anime_id, "ep": ep, "position": position,
        "duration": 1440, "title": "Frieren", "image": "",
    })
    assert res.status_code == 200, res.get_data(as_text=True)
    return res


def test_history_endpoints_reject_signed_out_requests(api):
    client = _client(api)
    assert client.get("/api/history").status_code == 401
    assert client.post("/api/history", json={"anime_id": "1", "ep": 1}).status_code == 401
    assert client.post("/api/history/remove", json={"anime_id": "1"}).status_code == 401


def test_owner_reads_back_what_they_saved(api):
    alice = _account(api, "alice@example.com")
    _save(api, alice)
    body = _client(api, alice).get("/api/history").get_json()
    assert body["status"] == "success"
    assert any(str(row.get("anime_id")) == "207329" for row in body["history"])


def test_one_account_cannot_read_anothers_history(api):
    alice = _account(api, "alice@example.com")
    bob = _account(api, "bob@example.com")
    _save(api, alice, anime_id="207329")

    body = _client(api, bob).get("/api/history").get_json()
    assert body["status"] == "success"
    assert all(str(row.get("anime_id")) != "207329" for row in body["history"])


def test_removal_only_touches_the_callers_rows(api):
    alice = _account(api, "alice@example.com")
    bob = _account(api, "bob@example.com")
    _save(api, alice, anime_id="207329")

    _client(api, bob).post("/api/history/remove", json={"anime_id": "207329"})

    still_there = api.platform.get_history(alice)
    assert any(str(row.get("anime_id")) == "207329" for row in still_there)


def test_bearer_token_resolves_to_its_own_account(api):
    alice = _account(api, "alice@example.com")
    _save(api, alice, anime_id="207329")
    token = getattr(api.platform, "issue_token", None) or getattr(api.platform, "create_token", None)
    if token is None:
        pytest.skip("no token issuer in the platform module")
    raw = token(alice)
    key = raw["token"] if isinstance(raw, dict) else raw
    client = _client(api)
    res = client.get("/api/history", headers={"Authorization": f"Bearer {key}"})
    body = res.get_json()
    assert any(str(row.get("anime_id")) == "207329" for row in body["history"])
