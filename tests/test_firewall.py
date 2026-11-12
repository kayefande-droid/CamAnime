"""The five firewall layers, exercised without a running app."""

from firewall import Firewall


def _req(fw, **kw):
    args = dict(ip="203.0.113.9", method="GET", path="/", query="", user_agent="Mozilla/5.0")
    args.update(kw)
    return fw.inspect(**args)


def test_clean_request_passes():
    fw = Firewall()
    assert _req(fw, path="/watch/21/1") is None


def test_scanner_and_traversal_paths_are_blocked():
    fw = Firewall()
    for path in ("/.env", "/wp-admin/install.php", "/../../etc/passwd", "/anime.php?id=1%20union%20select%201"):
        verdict = _req(fw, ip=f"198.51.100.{abs(hash(path)) % 200}", path=path)
        assert verdict is not None, path
        # The decoy 404 keeps a scanner from confirming which rule fired.
        assert verdict[1] == 404


def test_auth_rate_limit_is_tighter_than_pages():
    fw = Firewall()
    for _ in range(12):
        assert _req(fw, path="/api/auth/login", method="POST") is None
    verdict = _req(fw, path="/api/auth/login", method="POST")
    assert verdict is not None and verdict[1] == 429
    assert verdict[2]["Retry-After"] == "60"


def test_media_bucket_allows_a_playback_burst():
    fw = Firewall()
    for _ in range(400):
        assert _req(fw, path="/api/proxy/segment", query="?url=x") is None


def test_oversized_auth_body_is_rejected():
    fw = Firewall()
    verdict = _req(fw, path="/api/auth/register", method="POST", content_length=200_000)
    assert verdict is not None and verdict[1] == 413


def test_repeated_abuse_escalates_to_a_ban():
    fw = Firewall()
    for i in range(8):
        _req(fw, path=f"/.env?x={i}")
    verdict = _req(fw, path="/")
    assert verdict is not None and verdict[1] == 403
    assert verdict[2]["X-CamAnime-Firewall"] == "ban"
    assert int(verdict[2]["Retry-After"]) > 0


def test_attack_tool_user_agent_is_blocked_on_auth_only():
    fw = Firewall()
    assert _req(fw, path="/", user_agent="sqlmap/1.7") is None
    verdict = _req(fw, path="/api/auth/login", method="POST", user_agent="sqlmap/1.7")
    assert verdict is not None and verdict[1] == 403
