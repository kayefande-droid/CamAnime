#!/usr/bin/env python3
"""Smoke-check a deployed CamAnime schedule endpoint and emit compact metrics.

Run manually with ``python tools/schedule_smoke.py`` or set CAMANIME_BASE_URL.
This performs one GET only; it does not force refresh, bypass HTTP caches, or
contact AniList directly. The response headers expose per-worker counters.
"""

from __future__ import annotations

import argparse
import gzip
import json
import os
import sys
from datetime import datetime, timezone
from urllib.parse import urlparse

import requests


DEFAULT_BASE_URL = "https://camanime.onrender.com"
DEFAULT_MAX_AGE = 900
DEFAULT_MAX_BODY_BYTES = 1_000_000


class SmokeCheckError(RuntimeError):
    """Raised when the production schedule endpoint violates its contract."""


def _decode_response(response) -> tuple[bytes, bytes]:
    raw = response.raw.read(decode_content=False)
    encoding = (response.headers.get("Content-Encoding") or "identity").lower()
    if encoding == "gzip":
        try:
            decoded = gzip.decompress(raw)
        except OSError as error:
            raise SmokeCheckError(f"invalid gzip response body: {error}") from error
    elif encoding in ("identity", ""):
        decoded = raw
    else:
        raise SmokeCheckError(f"unsupported Content-Encoding: {encoding}")
    return raw, decoded


def validate_payload(payload: object) -> dict:
    if not isinstance(payload, dict) or payload.get("status") != "success":
        raise SmokeCheckError("response JSON must contain status='success'")
    season = payload.get("season")
    if not isinstance(season, dict) or not isinstance(season.get("name"), str) or not isinstance(season.get("year"), int):
        raise SmokeCheckError("season must contain a string name and integer year")
    if payload.get("playback_available") is not False:
        raise SmokeCheckError("schedule must not claim CamAnime playback availability")
    items = payload.get("items")
    if not isinstance(items, list):
        raise SmokeCheckError("items must be an array")
    for index, item in enumerate(items):
        prefix = f"items[{index}]"
        if not isinstance(item, dict):
            raise SmokeCheckError(f"{prefix} must be an object")
        if not isinstance(item.get("id"), int) or isinstance(item.get("id"), bool):
            raise SmokeCheckError(f"{prefix}.id must be an integer")
        if not isinstance(item.get("title"), str) or not item["title"].strip():
            raise SmokeCheckError(f"{prefix}.title must be a non-empty string")
        if item.get("playback_available") is not False or item.get("download_available") is not False:
            raise SmokeCheckError(f"{prefix} must not claim playback or downloads")
        airing = item.get("next_airing_episode")
        if airing is not None and (not isinstance(airing, dict) or not isinstance(airing.get("airing_at"), int)):
            raise SmokeCheckError(f"{prefix}.next_airing_episode must be null or include integer airing_at")
        official_link = item.get("official_episode_link")
        if official_link is not None:
            if not isinstance(official_link, dict):
                raise SmokeCheckError(f"{prefix}.official_episode_link must be null or an object")
            url = official_link.get("url")
            parsed = urlparse(url if isinstance(url, str) else "")
            if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
                raise SmokeCheckError(f"{prefix}.official_episode_link.url must be a credential-free HTTPS URL")
    return payload


def inspect_response(response, max_age: int = DEFAULT_MAX_AGE) -> dict:
    if response.status_code != 200:
        raise SmokeCheckError(f"schedule endpoint returned HTTP {response.status_code}")
    content_type = response.headers.get("Content-Type", "")
    if "application/json" not in content_type.lower():
        raise SmokeCheckError(f"expected JSON, received Content-Type {content_type!r}")
    raw, decoded = _decode_response(response)
    if not decoded or len(decoded) > DEFAULT_MAX_BODY_BYTES:
        raise SmokeCheckError(f"decoded response size is invalid: {len(decoded)} bytes")
    try:
        payload = validate_payload(json.loads(decoded))
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise SmokeCheckError(f"invalid JSON response: {error}") from error
    cache_control = response.headers.get("Cache-Control", "")
    max_age_value = None
    for directive in cache_control.split(","):
        directive = directive.strip().lower()
        if directive.startswith("max-age="):
            try:
                max_age_value = int(directive.split("=", 1)[1])
            except ValueError as error:
                raise SmokeCheckError("Cache-Control has an invalid max-age") from error
            break
    if max_age_value is None or max_age_value < max_age:
        raise SmokeCheckError(f"Cache-Control max-age must be at least {max_age} seconds")
    return {
        "checked_at": datetime.now(timezone.utc).isoformat(),
        "url": response.url,
        "status": response.status_code,
        "season": payload["season"],
        "item_count": len(payload["items"]),
        "response_body_bytes": len(raw),
        "decoded_json_bytes": len(decoded),
        "compressed": (response.headers.get("Content-Encoding") or "identity").lower() == "gzip",
        "cache_max_age_seconds": max_age_value,
        "schedule_api_requests": _counter(response, "X-Schedule-Api-Requests"),
        "schedule_cache_misses": _counter(response, "X-Schedule-Cache-Misses"),
        "worker_uptime_seconds": _counter(response, "X-Schedule-Worker-Uptime"),
    }


def _counter(response, header: str) -> int | None:
    value = response.headers.get(header)
    if value is None:
        return None
    try:
        result = int(value)
    except ValueError as error:
        raise SmokeCheckError(f"{header} must be an integer") from error
    if result < 0:
        raise SmokeCheckError(f"{header} cannot be negative")
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default=os.environ.get("CAMANIME_BASE_URL", DEFAULT_BASE_URL))
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--max-age", type=int, default=DEFAULT_MAX_AGE)
    args = parser.parse_args(argv)
    base = args.base_url.rstrip("/")
    parsed_base = urlparse(base)
    if parsed_base.scheme != "https" or not parsed_base.hostname:
        parser.error("--base-url must be an HTTPS URL")
    try:
        response = requests.get(
            f"{base}/api/v1/schedule",
            headers={"Accept": "application/json", "Accept-Encoding": "gzip"},
            timeout=args.timeout,
            stream=True,
        )
        try:
            metrics = inspect_response(response, max_age=args.max_age)
        finally:
            response.close()
    except (requests.RequestException, SmokeCheckError) as error:
        print(json.dumps({"status": "fail", "error": str(error)}), file=sys.stderr)
        return 1
    print(json.dumps({"status": "pass", **metrics}, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
