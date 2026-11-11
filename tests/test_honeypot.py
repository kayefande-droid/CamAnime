"""Decoy containment: hostile clients land in an inert clone, not a 404.

The clone is deception plus evidence. These tests pin the boundaries that make
it safe: real members are never trapped, no password is ever stored, and the
evidence chain proves whether anything was edited afterwards.
"""

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import app as camanime  # noqa: E402
import honeypot  # noqa: E402

BROWSER = {
    "Accept": "text/html,application/xhtml+xml",
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/131.0",
}


@pytest.fixture(autouse=True)
def isolated_ledger(monkeypatch, tmp_path):
    monkeypatch.setenv("CAMANIME_INTRUSIONS", str(tmp_path / "intrusions.db"))
    monkeypatch.delenv("CAMANIME_DECOY", raising=False)
    honeypot._AUTH_FAILS.clear()
    honeypot._ADMIN_DENIES.clear()
    camanime._RATE_BUCKETS.clear()
    camanime.app.config["TESTING"] = True
    yield


def client():
    return camanime.app.test_client()


def test_browser_scanner_is_walked_into_the_clone():
    c = client()
    first = c.get("/wp-login.php", headers=BROWSER)
    assert first.status_code == 302
    assert first.headers["Location"].endswith("/decoy")

    # The flag sticks: even a normal page now shows the clone, not the real site.
    second = c.get("/", headers=BROWSER)
    assert second.status_code == 302
    assert second.headers["Location"].endswith("/decoy")

    page = c.get("/decoy", headers=BROWSER)
    assert page.status_code == 200
    assert page.headers["X-CamAnime-Decoy"] == "1"
    assert b"Trending now" in page.data
    assert b"Cam" in page.data


def test_non_browser_scanner_still_gets_nothing():
    r = client().get("/.env", headers={"Accept": "application/json",
                                       "User-Agent": "curl/8.5.0"})
    assert r.status_code == 404
    assert not honeypot.is_flagged("127.0.0.1")


def test_decoy_login_never_stores_a_password():
    c = client()
    c.get("/decoy/login", headers=BROWSER)
    c.post("/decoy/login",
           data={"email": "intruder@evil.test", "password": "Sup3rSecret!"},
           headers=BROWSER)
    rows = honeypot.entries(100)
    blob = json.dumps(rows)
    assert rows, "the decoy must record the attempt"
    assert "Sup3rSecret!" not in blob
    assert "intruder@evil.test" not in blob
    assert "sha256:" in blob


def test_evidence_chain_is_verifiable_and_detects_tampering():
    honeypot.record("203.0.113.9", "GET", "/decoy/login", "ua-1", detail="a")
    honeypot.record("203.0.113.9", "POST", "/decoy/login", "ua-1", detail="b")
    ok, broken = honeypot.verify_chain()
    assert ok and broken is None

    conn = honeypot._connect()
    conn.execute("UPDATE ledger SET path='/edited' WHERE id=1")
    conn.commit()
    conn.close()

    ok2, broken2 = honeypot.verify_chain()
    assert not ok2
    assert broken2 == 1


def test_signed_in_member_is_never_trapped():
    c = client()
    with c.session_transaction() as sess:
        sess["user_email"] = "member@example.com"
    honeypot.flag("127.0.0.1", "scanner-path")
    r = c.get("/", headers=BROWSER)
    assert r.status_code != 302


def test_kill_switch_disables_the_clone(monkeypatch):
    monkeypatch.setenv("CAMANIME_DECOY", "0")
    r = client().get("/wp-login.php", headers=BROWSER)
    assert r.status_code == 404


def test_brute_force_threshold_flags_the_client():
    for _ in range(7):
        honeypot.note_auth_failure("198.51.100.7")
    assert not honeypot.is_flagged("198.51.100.7")
    honeypot.note_auth_failure("198.51.100.7")
    assert honeypot.is_flagged("198.51.100.7")


def test_evidence_report_is_owner_only(monkeypatch):
    assert client().get("/api/admin/intrusion-report").status_code == 403

    monkeypatch.setattr(camanime, "_require_role",
                        lambda role: {"email": "owner@example.com"} if role == "owner" else None)
    honeypot.record("203.0.113.9", "GET", "/decoy", detail="x")
    r = client().get("/api/admin/intrusion-report")
    assert r.status_code == 200
    body = r.get_json()
    assert body["chain_ok"] is True
    assert body["entry_count"] == 1
    assert len(body["head_digest"]) == 64

    text = client().get("/api/admin/intrusion-report?format=text")
    assert text.status_code == 200
    assert b"hostile-access evidence report" in text.data


def test_owner_can_release_a_false_positive(monkeypatch):
    honeypot.flag("203.0.113.44", "scanner-path")
    assert honeypot.is_flagged("203.0.113.44")
    monkeypatch.setattr(camanime, "_require_role",
                        lambda role: {"email": "owner@example.com"} if role == "owner" else None)
    r = client().post("/api/admin/intrusion-release", json={"ip": "203.0.113.44"})
    assert r.status_code == 200
    assert not honeypot.is_flagged("203.0.113.44")
