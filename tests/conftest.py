"""Shared test isolation.

The decoy ledger is disk-backed, so without a per-test database a test that
legitimately trips the brute-force threshold would contain every later test in
the same process from 127.0.0.1. Each test gets a private, empty ledger instead.
"""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))


@pytest.fixture(autouse=True)
def _isolated_intrusion_ledger(monkeypatch, tmp_path):
    monkeypatch.setenv("CAMANIME_INTRUSIONS", str(tmp_path / "intrusions.db"))
    monkeypatch.delenv("CAMANIME_DECOY", raising=False)
    try:
        import honeypot

        honeypot._AUTH_FAILS.clear()
        honeypot._ADMIN_DENIES.clear()
    except Exception:
        pass
    # The request firewall keeps per-address counters in the process. Tests all
    # arrive from 127.0.0.1, so without a fresh instance the 300th request in a
    # session would be rate limited and unrelated assertions would fail.
    try:
        import firewall as firewall_module
        import app as app_module

        fresh = firewall_module.Firewall()
        firewall_module.firewall = fresh
        app_module.firewall = fresh
    except Exception:
        pass
    yield
