import importlib
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

ROOT = Path(__file__).resolve().parents[1]

DEAD = "dead-token-aaaaaaaaaaaaaaaaaaaaaaaa"


class _FcmStub(BaseHTTPRequestHandler):
    """Local stand-in for Google's OAuth + FCM HTTP v1 endpoints."""

    def log_message(self, *args):  # keep pytest output clean
        pass

    def _json(self, code, payload):
        raw = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        if self.path.endswith("/token"):
            # A real token endpoint would validate the signed assertion; the
            # transport's job here is to send it and use the answer.
            assert b"grant_type=urn" in raw
            self._json(200, {"access_token": "stub-access-token",
                             "expires_in": 3600})
            return
        if self.path.endswith("/messages:send"):
            message = json.loads(raw or b"{}").get("message", {})
            if message.get("token") == DEAD:
                self._json(404, {"error": {"status": "NOT_FOUND",
                                           "message": "Requested entity was not found."}})
                return
            if not message.get("notification", {}).get("title"):
                self._json(400, {"error": {"status": "INVALID_ARGUMENT"}})
                return
            self._json(200, {"name": "projects/demo/messages/1"})
            return
        self._json(404, {})


@pytest.fixture()
def api(tmp_path, monkeypatch):
    monkeypatch.setenv("CAMANIME_DB", str(tmp_path / "test.db"))
    monkeypatch.delenv("CAMANIME_ADMIN_EMAIL", raising=False)
    monkeypatch.delenv("CAMANIME_ADMIN_PASSWORD", raising=False)
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


@pytest.fixture()
def fcm(monkeypatch):
    server = ThreadingHTTPServer(("127.0.0.1", 0), _FcmStub)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{server.server_port}"
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    ).decode()
    account = {
        "type": "service_account",
        "project_id": "demo",
        "client_email": "sender@demo.iam.gserviceaccount.com",
        "private_key": pem,
        "token_uri": f"{base}/token",
    }
    monkeypatch.setenv("FCM_SERVICE_ACCOUNT_JSON", json.dumps(account))
    monkeypatch.setenv("CAMANIME_FCM_ENDPOINT", base)
    monkeypatch.delenv("FCM_SERVICE_ACCOUNT_FILE", raising=False)
    yield {"base": base}
    server.shutdown()
    server.server_close()


def app_headers(build=18, version="2.8.0", install="install-push-01"):
    return {
        "X-CamAnime-Version": version,
        "X-CamAnime-Build": str(build),
        "X-CamAnime-Platform": "android",
        "X-CamAnime-Install": install,
    }


def admin_headers(api, email="push-admin@example.com"):
    api.platform.create_admin_user(email, "Ops", "strongpass123")
    token = api.platform.issue_token(email)["token"]
    return {"Authorization": f"Bearer {token}"}


def test_push_is_unavailable_without_credentials(api):
    assert api.push.available() is False
    result = api.push.send_update_alert(["missing"], "Update", "Body")
    assert result == {"available": False, "targets": 0, "delivered": 0,
                      "failed": 0, "pruned": 0, "errors": []}


def test_delivery_counts_successes_and_prunes_dead_tokens(api, fcm):
    api.push.register("inst-good-1", "good-token-" + "a" * 30)
    api.push.register("inst-dead", DEAD)
    api.push.register("inst-good-2", "good-token-" + "b" * 30)

    result = api.push.send_update_alert(
        ["inst-good-1", "inst-dead", "inst-good-2"],
        "Update CamAnime", "A newer CamAnime is available.",
        {"type": "app_update", "version": "2.8.0"})

    assert result["available"] is True
    assert result["targets"] == 3
    assert result["delivered"] == 2
    assert result["failed"] == 1
    assert result["pruned"] == 1
    assert api.push.token_count() == 2


def test_app_endpoint_registers_and_removes_a_token(api, fcm):
    client = api.app.test_client()
    token = "registered-token-" + "c" * 30
    res = client.post("/api/app/push-token", json={"token": token},
                      headers=app_headers())
    assert res.status_code == 200, res.get_json()
    assert res.get_json()["registered"] is True
    assert res.get_json()["push_available"] is True
    assert api.push.token_count() == 1

    removed = client.delete("/api/app/push-token", headers=app_headers())
    assert removed.status_code == 200
    assert api.push.token_count() == 0


def test_app_endpoint_rejects_a_bogus_token(api, fcm):
    client = api.app.test_client()
    res = client.post("/api/app/push-token", json={"token": "short"},
                      headers=app_headers())
    assert res.status_code == 400


def test_admin_notify_actually_delivers_to_outdated_devices(api, fcm):
    client = api.app.test_client()
    outdated = app_headers(build=16, version="2.6.5", install="install-old-77")
    assert client.get("/api/app/ping", headers=outdated).status_code == 200
    client.post("/api/app/push-token",
                json={"token": "outdated-token-" + "d" * 30},
                headers=outdated)

    current = app_headers(build=18, install="install-new-78")
    client.get("/api/app/ping", headers=current)
    client.post("/api/app/push-token",
                json={"token": "current-token-" + "e" * 30},
                headers=current)

    res = client.post("/api/admin/version-policy/notify", json={},
                      headers=admin_headers(api))
    assert res.status_code == 200
    body = res.get_json()
    assert body["targets"] == 1
    assert body["push_available"] is True
    assert body["push_registered_devices"] == 1
    assert body["push_delivered"] == 1
    assert body["push_failed"] == 0
