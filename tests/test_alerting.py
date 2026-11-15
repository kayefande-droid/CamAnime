"""5xx responses reach the alert webhook, and nothing at all is sent unset.

Uptime is covered from the edge (the Worker's 5-minute health sweep); this file
covers the origin's own error path, which fires while the process is healthy.
"""
import importlib
import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
MODULES = ("app", "camanime_platform", "app_version", "mfa", "push")


def _load(tmp_path, monkeypatch, env):
    monkeypatch.setenv("CAMANIME_DB", str(tmp_path / "test.db"))
    monkeypatch.setenv("CAMANIME_SECRET", "test-secret-not-for-production")
    monkeypatch.delenv("CAMANIME_ADMIN_EMAIL", raising=False)
    monkeypatch.delenv("CAMANIME_ADMIN_PASSWORD", raising=False)
    for key, value in env.items():
        monkeypatch.setenv(key, value)
    sys.path.insert(0, str(ROOT))
    for name in MODULES:
        sys.modules.pop(name, None)
    module = importlib.import_module("app")
    module.app.config.update(TESTING=True)
    return module


def _drop():
    for name in MODULES:
        sys.modules.pop(name, None)
    if str(ROOT) in sys.path:
        sys.path.remove(str(ROOT))


@pytest.fixture()
def quiet(tmp_path, monkeypatch):
    module = _load(tmp_path, monkeypatch, {})
    yield module
    _drop()


@pytest.fixture()
def wired(tmp_path, monkeypatch):
    module = _load(
        tmp_path,
        monkeypatch,
        {"CAMANIME_ALERT_WEBHOOK": "https://hooks.example/camanime",
         "CAMANIME_ALERT_INTERVAL": "0"},
    )
    yield module
    _drop()


def _capture_posts(monkeypatch, module):
    posts = []

    class _Response:
        status_code = 200

    def _post(url, **kwargs):
        posts.append((url, kwargs))
        return _Response()

    monkeypatch.setattr(module.requests, "post", _post)
    return posts


def _wait_for(posts, count=1, timeout=2.0):
    deadline = time.time() + timeout
    while time.time() < deadline and len(posts) < count:
        time.sleep(0.01)
    return posts


def test_no_webhook_means_no_alert_and_no_thread(quiet):
    assert quiet.ALERT_WEBHOOK == ""
    assert quiet.send_alert("test", "nothing configured") is False


def test_a_failing_route_alerts_the_webhook(wired, monkeypatch):
    posts = _capture_posts(monkeypatch, wired)
    wired.app.add_url_rule(
        "/__alert_probe", "alert_probe", lambda: ("down", 503)
    )

    response = wired.app.test_client().get("/__alert_probe")
    assert response.status_code == 503

    _wait_for(posts)
    assert len(posts) == 1
    url, kwargs = posts[0]
    assert url == "https://hooks.example/camanime"
    payload = kwargs["json"]
    assert payload["kind"] == "http-503"
    assert "503 on GET /__alert_probe" in payload["message"]
    assert "CamAnime" in payload["text"]
    assert kwargs["timeout"] == 5


def test_a_healthy_page_sends_nothing(wired, monkeypatch):
    posts = _capture_posts(monkeypatch, wired)
    wired.app.add_url_rule("/__ok_probe", "ok_probe", lambda: ("fine", 200))

    assert wired.app.test_client().get("/__ok_probe").status_code == 200
    time.sleep(0.1)
    assert posts == []


def test_repeated_failures_are_throttled(tmp_path, monkeypatch):
    module = _load(
        tmp_path,
        monkeypatch,
        {"CAMANIME_ALERT_WEBHOOK": "https://hooks.example/camanime"},
    )
    try:
        posts = _capture_posts(monkeypatch, module)
        module.app.add_url_rule("/__loud", "loud", lambda: ("down", 500))
        client = module.app.test_client()
        client.get("/__loud")
        client.get("/__loud")
        _wait_for(posts)
        time.sleep(0.1)
        assert len(posts) == 1
    finally:
        _drop()


def test_the_webhook_failing_never_breaks_the_response(wired, monkeypatch):
    def _explode(url, **kwargs):
        raise OSError("webhook unreachable")

    monkeypatch.setattr(wired.requests, "post", _explode)
    wired.app.add_url_rule("/__flaky", "flaky", lambda: ("down", 502))

    response = wired.app.test_client().get("/__flaky")
    assert response.status_code == 502
