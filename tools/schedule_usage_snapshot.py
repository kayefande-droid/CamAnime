#!/usr/bin/env python3
"""Collect a production schedule response-size and worker-counter snapshot.

The workflow stores each JSON result as a retained artifact. This script queries
GitHub Actions artifacts for previous samples (when GH_TOKEN is available) and
reports deltas for response bytes, API requests, cache misses and worker uptime.
"""

from __future__ import annotations

import argparse
import io
import json
import os
import sys
import zipfile
from datetime import datetime, timezone
from urllib.parse import urlparse

import requests

from schedule_smoke import DEFAULT_BASE_URL, SmokeCheckError, inspect_response


def _previous_snapshot(repo: str, token: str, current_run_id: str) -> dict | None:
    if not repo or not token:
        return None
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}
    api = f"https://api.github.com/repos/{repo}/actions/artifacts"
    try:
        response = requests.get(api, headers=headers, params={"per_page": 100}, timeout=15)
        response.raise_for_status()
        artifacts = response.json().get("artifacts", [])
    except requests.RequestException:
        return None
    candidates = [
        artifact for artifact in artifacts
        if not artifact.get("expired")
        and artifact.get("name", "").startswith("schedule-usage-")
        and str(artifact.get("workflow_run", {}).get("id")) != current_run_id
    ]
    candidates.sort(key=lambda artifact: artifact.get("created_at", ""), reverse=True)
    for artifact in candidates:
        try:
            archive = requests.get(artifact["archive_download_url"], headers=headers, timeout=20)
            archive.raise_for_status()
            with zipfile.ZipFile(io.BytesIO(archive.content)) as bundle:
                candidate = next((name for name in bundle.namelist() if name.endswith("schedule-usage.json")), None)
                if candidate:
                    return json.loads(bundle.read(candidate))
        except (requests.RequestException, KeyError, ValueError, OSError, zipfile.BadZipFile):
            continue
    return None


def _delta(current: int | None, previous: int | None) -> int | None:
    if current is None or previous is None or current < previous:
        return None
    return current - previous


def _estimated_monthly_schedule_api_bytes(current: dict, previous: dict | None) -> int | None:
    """Project endpoint response-body bytes from the latest valid sample window."""
    if not previous:
        return None
    if (current.get("worker_uptime_seconds") is None
            or previous.get("worker_uptime_seconds") is None
            or current["worker_uptime_seconds"] < previous["worker_uptime_seconds"]):
        return None
    request_delta = _delta(
        current.get("schedule_api_requests"), previous.get("schedule_api_requests")
    )
    interval_seconds = current.get("window_seconds")
    response_bytes = current.get("response_body_bytes")
    if (request_delta is None or not isinstance(interval_seconds, int) or interval_seconds <= 0
            or not isinstance(response_bytes, int) or response_bytes < 0):
        return None
    return round(response_bytes * request_delta * (30 * 24 * 60 * 60) / interval_seconds)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default=os.environ.get("CAMANIME_BASE_URL", DEFAULT_BASE_URL))
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--output", default="schedule-usage.json")
    parser.add_argument("--repository", default=os.environ.get("GH_REPOSITORY", ""))
    parser.add_argument("--run-id", default=os.environ.get("GH_RUN_ID", ""))
    args = parser.parse_args(argv)
    base_url = args.base_url.rstrip("/")
    if urlparse(base_url).scheme != "https":
        parser.error("--base-url must use HTTPS")

    response = None
    try:
        response = requests.get(
            f"{base_url}/api/v1/schedule",
            headers={"Accept": "application/json", "Accept-Encoding": "gzip"},
            timeout=args.timeout,
            stream=True,
        )
        current = inspect_response(response, max_age=900)
    except (requests.RequestException, SmokeCheckError) as error:
        failure = {"status": "fail", "checked_at": datetime.now(timezone.utc).isoformat(), "error": str(error)}
        with open(args.output, "w", encoding="utf-8") as output:
            json.dump(failure, output, separators=(",", ":"))
        print(json.dumps(failure, separators=(",", ":")), file=sys.stderr)
        return 1
    finally:
        if response is not None:
            response.close()

    previous = _previous_snapshot(
        args.repository, os.environ.get("GH_TOKEN", ""), args.run_id
    )
    current["status"] = "pass"
    current["deltas_since_previous_sample"] = {
        key: _delta(current.get(key), previous.get(key) if previous else None)
        for key in ("response_body_bytes", "schedule_api_requests", "schedule_cache_misses")
    }
    current["previous_sample_at"] = previous.get("checked_at") if previous else None
    current["window_seconds"] = None
    if previous:
        try:
            start = datetime.fromisoformat(previous["checked_at"])
            end = datetime.fromisoformat(current["checked_at"])
            current["window_seconds"] = int((end - start).total_seconds())
        except (KeyError, TypeError, ValueError):
            current["window_seconds"] = None
    current["estimated_monthly_schedule_api_bytes"] = _estimated_monthly_schedule_api_bytes(
        current, previous
    )
    current["bandwidth_scope"] = "schedule endpoint response bodies only; not Render service-wide bandwidth"
    with open(args.output, "w", encoding="utf-8") as output:
        json.dump(current, output, separators=(",", ":"))
    print(json.dumps(current, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
