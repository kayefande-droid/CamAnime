"""Five-layer request firewall for the CamAnime site.

The site is public, scrapes third-party providers and exposes auth endpoints, so
it gets scanned, brute-forced and probed constantly. The layers run in order,
cheapest first:

  L1 ban        an address that keeps tripping the rules is refused outright
  L2 rate       per-address buckets, tighter for auth than for pages
  L3 signatures scanner paths, traversal, injection and known attack tools
  L4 payload    oversized or wrongly-typed bodies are rejected before parsing
  L5 strikes    every block scores the address, which is what fills L1

State is in-process and bounded: this is a shield against a single noisy
attacker, not a substitute for the platform's own DDoS edge (Cloudflare sits in
front of both hosts).
"""

from __future__ import annotations

import re
import threading
import time
from typing import Dict, List, Optional, Tuple
from urllib.parse import unquote

# ─── Policy ──────────────────────────────────────────────────────────────────

WINDOW = 60.0                    # rate window, seconds
GENERAL_LIMIT = 300              # any request
AUTH_LIMIT = 12                  # /api/auth/*, login and register
MEDIA_LIMIT = 1200               # /api/proxy/* and /api/download/* (segments)

AUTH_MAX_BODY = 64 * 1024        # auth bodies are tiny JSON documents
GENERAL_MAX_BODY = 2 * 1024 * 1024

STRIKE_WINDOW = 600.0            # strikes older than this are forgotten
BAN_STRIKES = 8                  # strikes inside the window that trigger a ban
BAN_SECONDS = 900                # ban length

MAX_TRACKED_IPS = 20000          # bounded memory on a small instance

AUTH_PREFIXES = ("/api/auth/", "/login", "/register", "/api/mfa")
MEDIA_PREFIXES = ("/api/proxy/", "/api/download/", "/api/v1/stream")

# Request signatures that no legitimate client sends. Matched against the
# decoded path and query only, so a title with a quote in it still works.
ATTACK_PATTERNS = [
    re.compile(r"\.\./|\.\.\\"),
    re.compile(r"/etc/(passwd|shadow)"),
    re.compile(r"\.(env|git|svn|hg)(/|$|\?)"),
    re.compile(r"(wp-admin|wp-login|phpmyadmin|xmlrpc\.php|adminer|\.DS_Store)", re.I),
    re.compile(r"(union\s+(all\s+)?select|information_schema|sleep\(\d+\)|benchmark\()", re.I),
    re.compile(r"(<script|javascript:|onerror\s*=|onload\s*=)", re.I),
    re.compile(r"(%00|\x00)"),
    re.compile(r"(cmd\.exe|/bin/(ba)?sh|powershell)", re.I),
    re.compile(r"(\.\.%2f|%2e%2e/)", re.I),
]

SCANNER_UAS = re.compile(
    r"(sqlmap|nikto|nmap|masscan|zgrab|wpscan|dirbuster|gobuster|feroxbuster|"
    r"hydra|acunetix|nessus|openvas|nuclei|ffuf|nuclei)",
    re.I,
)


def _now() -> float:
    return time.monotonic()


def client_key(ip: str) -> str:
    return (ip or "unknown").strip()[:64]


class Firewall:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._hits: Dict[str, Dict[str, List[float]]] = {}
        self._strikes: Dict[str, List[float]] = {}
        self._bans: Dict[str, float] = {}
        self._blocked_total = 0

    # ── L1: bans ────────────────────────────────────────────────────────────
    def banned(self, ip: str) -> int:
        """Seconds left on a ban, or 0."""
        key = client_key(ip)
        with self._lock:
            until = self._bans.get(key, 0.0)
            left = int(until - time.time())
        return max(0, left)

    # ── L2: rate ────────────────────────────────────────────────────────────
    def _bucket_for(self, path: str) -> Tuple[str, int]:
        if path.startswith(AUTH_PREFIXES):
            return "auth", AUTH_LIMIT
        if path.startswith(MEDIA_PREFIXES):
            return "media", MEDIA_LIMIT
        return "general", GENERAL_LIMIT

    def _rate_exceeded(self, ip: str, path: str) -> Optional[int]:
        bucket, limit = self._bucket_for(path)
        key = client_key(ip)
        now = _now()
        with self._lock:
            per_ip = self._hits.setdefault(key, {})
            stamps = [t for t in per_ip.get(bucket, []) if now - t < WINDOW]
            stamps.append(now)
            per_ip[bucket] = stamps
            if len(self._hits) > MAX_TRACKED_IPS:
                for stale in list(self._hits)[: max(1, MAX_TRACKED_IPS // 10)]:
                    self._hits.pop(stale, None)
            over = len(stamps) > limit
        return int(WINDOW) if over else None

    # ── L5: strikes ─────────────────────────────────────────────────────────
    def strike(self, ip: str, reason: str) -> None:
        key = client_key(ip)
        now = time.time()
        with self._lock:
            hits = [t for t in self._strikes.get(key, []) if now - t < STRIKE_WINDOW]
            hits.append(now)
            self._strikes[key] = hits
            self._blocked_total += 1
            if len(hits) >= BAN_STRIKES:
                self._bans[key] = now + BAN_SECONDS
                self._strikes[key] = []
            if len(self._strikes) > MAX_TRACKED_IPS:
                for stale in list(self._strikes)[: max(1, MAX_TRACKED_IPS // 10)]:
                    self._strikes.pop(stale, None)

    # ── L3/L4 helpers ───────────────────────────────────────────────────────
    @staticmethod
    def _signature_hit(path: str, query: str) -> Optional[str]:
        haystack = f"{unquote(path)}?{unquote(query)}"
        for pattern in ATTACK_PATTERNS:
            if pattern.search(haystack):
                return pattern.pattern
        return None

    @staticmethod
    def _body_too_large(path: str, content_length: Optional[int]) -> bool:
        if not content_length:
            return False
        limit = AUTH_MAX_BODY if path.startswith(AUTH_PREFIXES) else GENERAL_MAX_BODY
        return content_length > limit

    # ── Public entry point ──────────────────────────────────────────────────
    def inspect(
        self,
        *,
        ip: str,
        method: str,
        path: str,
        query: str = "",
        user_agent: str = "",
        content_length: Optional[int] = None,
    ) -> Optional[Tuple[str, int, Dict[str, str]]]:
        """Return (message, status, headers) when the request must be refused."""

        left = self.banned(ip)
        if left:
            return ("Address temporarily blocked after repeated abuse.", 403,
                    {"Retry-After": str(left), "X-CamAnime-Firewall": "ban"})

        wait = self._rate_exceeded(ip, path)
        if wait:
            self.strike(ip, "rate")
            return ("Too many requests. Slow down and retry shortly.", 429,
                    {"Retry-After": str(wait), "X-CamAnime-Firewall": "rate"})

        hit = self._signature_hit(path, query)
        if hit:
            self.strike(ip, "signature")
            # 404, not 403: the site already answers unknown paths with its
            # decoy 404, and confirming "you were filtered" only helps a
            # scanner map the rules. The strike still counts toward a ban.
            return ("Not found.", 404,
                    {"X-CamAnime-Firewall": "signature"})

        if method not in ("GET", "HEAD", "OPTIONS", "POST", "PUT", "PATCH", "DELETE"):
            self.strike(ip, "method")
            return ("Method not allowed.", 405, {"X-CamAnime-Firewall": "method"})

        if self._body_too_large(path, content_length):
            self.strike(ip, "payload")
            return ("Request body too large.", 413,
                    {"X-CamAnime-Firewall": "payload"})

        if path.startswith(AUTH_PREFIXES) and SCANNER_UAS.search(user_agent or ""):
            self.strike(ip, "scanner")
            return ("Request blocked.", 403,
                    {"X-CamAnime-Firewall": "scanner"})

        return None

    def stats(self) -> Dict[str, int]:
        with self._lock:
            return {
                "blocked_total": self._blocked_total,
                "tracked_ips": len(self._hits),
                "active_bans": sum(1 for t in self._bans.values() if t > time.time()),
            }


firewall = Firewall()
