"""Persistent hosted storage for the website: Cloudflare D1 over HTTPS.

A Render free instance has an ephemeral disk, so the SQLite file used for
accounts, comments, ratings and notifications vanished on every deploy. D1 is
a hosted SQLite database with exactly the same dialect — the worker deployment
already keeps the same tables — so the Flask side can keep its SQL and only
swap the connection.

Configuration (all three, or the local SQLite file is used):

  CAMANIME_D1_ACCOUNT_ID   Cloudflare account id
  CAMANIME_D1_DATABASE_ID  D1 database uuid
  CAMANIME_D1_TOKEN        API token with D1 Edit permission

Statements are atomic on their own. D1 has no interactive transactions over
the HTTP API, so a `with conn:` block commits per statement instead of as one
unit; every write in this codebase is independent, so that matches the intent.
"""
import hashlib
import json
import os
import sqlite3
import time
import urllib.error
import urllib.request

API = "https://api.cloudflare.com/client/v4/accounts/{account}/d1/database/{database}/query"

# Schema scripts are idempotent but several modules call ensure_schema() on
# every request. Running them once per process keeps that free.
_EXECUTED = set()


class D1Error(RuntimeError):
    """Raised for an upstream D1 failure; callers keep their own error paths."""


class Row:
    """Read-only row with sqlite3.Row-style access (name, index, keys())."""

    __slots__ = ("_data",)

    def __init__(self, data):
        self._data = dict(data)

    def keys(self):
        return list(self._data.keys())

    def __getitem__(self, key):
        if isinstance(key, str):
            return self._data[key]
        return list(self._data.values())[key]

    def __iter__(self):
        return iter(self._data.values())

    def __len__(self):
        return len(self._data)

    def __contains__(self, key):
        return key in self._data

    def __repr__(self):
        return f"Row({self._data!r})"


class Cursor:
    def __init__(self, rows, lastrowid=0, rowcount=0):
        self._rows = [Row(r) for r in rows]
        self.lastrowid = lastrowid
        self.rowcount = rowcount

    def fetchone(self):
        return self._rows[0] if self._rows else None

    def fetchall(self):
        return list(self._rows)

    def fetchmany(self, size=1):
        return self._rows[:size]

    def __iter__(self):
        return iter(self._rows)


def configured():
    """True when the three D1 variables are present."""
    return all(
        os.environ.get(name, "").strip()
        for name in ("CAMANIME_D1_ACCOUNT_ID", "CAMANIME_D1_DATABASE_ID", "CAMANIME_D1_TOKEN")
    )


class D1Connection:
    """sqlite3.Connection look-alike backed by the D1 HTTP API."""

    def __init__(self):
        self.row_factory = Row
        self._account = os.environ["CAMANIME_D1_ACCOUNT_ID"].strip()
        self._database = os.environ["CAMANIME_D1_DATABASE_ID"].strip()
        self._token = os.environ["CAMANIME_D1_TOKEN"].strip()
        self._url = API.format(account=self._account, database=self._database)

    # ── transport ──────────────────────────────────────────────────────────

    def _post(self, payload, attempts=2):
        body = json.dumps(payload).encode("utf-8")
        last = None
        for attempt in range(attempts):
            request = urllib.request.Request(
                self._url,
                data=body,
                method="POST",
                headers={
                    "Authorization": f"Bearer {self._token}",
                    "content-type": "application/json",
                    "accept": "application/json",
                },
            )
            try:
                with urllib.request.urlopen(request, timeout=20) as response:
                    data = json.loads(response.read().decode("utf-8"))
            except urllib.error.HTTPError as exc:
                # A query error arrives as a 4xx with the real SQLite message in
                # the body, so surface that instead of the bare status code.
                try:
                    payload = json.loads(exc.read().decode("utf-8"))
                except Exception:
                    raise D1Error(f"D1 HTTP {exc.code}") from exc
                message = "; ".join(
                    str(err.get("message") or err) for err in (payload.get("errors") or [])
                ) or f"D1 HTTP {exc.code}"
                raise D1Error(message) from exc
            except (urllib.error.URLError, TimeoutError, OSError) as exc:
                last = exc
                if attempt + 1 < attempts:
                    time.sleep(0.4 * (attempt + 1))
                    continue
                raise D1Error(f"D1 unreachable: {exc}") from exc
            except ValueError as exc:
                raise D1Error("D1 returned a non-JSON response") from exc

            if not data.get("success", False):
                message = "; ".join(
                    str(err.get("message") or err) for err in (data.get("errors") or [])
                ) or "D1 query failed"
                raise D1Error(message)
            result = (data.get("result") or [{}])[0]
            if result.get("success") is False:
                raise D1Error(str(result.get("error") or "D1 query failed"))
            return result
        raise D1Error(str(last or "D1 query failed"))

    # ── sqlite3 surface ────────────────────────────────────────────────────

    @staticmethod
    def _translate(sql):
        text = sql.strip()
        lowered = text.lower()
        if lowered.startswith("pragma table_info"):
            # D1 answers this natively, including the column metadata callers read.
            return text, True
        if lowered.startswith("pragma"):
            # journal_mode / foreign_keys are per-connection settings the hosted
            # database manages itself; D1 rejects them, and they are not needed.
            return None, False
        if lowered.startswith("begin") or lowered.startswith("commit") or lowered.startswith("rollback"):
            return None, False
        return text, True

    def _run(self, sql, params=()):
        statement, runnable = self._translate(sql)
        if not runnable:
            return Cursor([])
        if params is None:
            params = ()
        result = self._post({"sql": statement, "params": list(params)})
        rows = result.get("results") or []
        if isinstance(rows, dict):
            rows = [rows]
        meta = result.get("meta") or {}
        return Cursor(rows, int(meta.get("last_row_id") or 0), int(meta.get("changes") or 0))

    def execute(self, sql, params=()):
        return self._run(sql, params)

    def executemany(self, sql, seq_of_params):
        last = Cursor([])
        for params in seq_of_params:
            last = self._run(sql, params)
        return last

    def executescript(self, script):
        digest = hashlib.sha256(script.encode("utf-8")).hexdigest()
        if digest in _EXECUTED:
            return self
        for statement in _split(script):
            self._run(statement)
        _EXECUTED.add(digest)
        return self

    def commit(self):
        return None

    def rollback(self):
        return None

    def close(self):
        return None

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False


def _split(script):
    """Split a DDL script into statements without breaking quoted semicolons."""
    statements, current, quote = [], [], None
    for char in script:
        if quote:
            current.append(char)
            if char == quote:
                quote = None
            continue
        if char in ("'", '"'):
            quote = char
            current.append(char)
            continue
        if char == ";":
            statements.append("".join(current))
            current = []
            continue
        current.append(char)
    if "".join(current).strip():
        statements.append("".join(current))
    return [s.strip() for s in statements if s.strip()]


def local_connection(path):
    conn = sqlite3.connect(path, timeout=15)
    conn.row_factory = sqlite3.Row
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA foreign_keys=ON")
    except sqlite3.Error:
        pass
    return conn


def connection(path):
    """D1 when configured, otherwise the SQLite file (local dev and tests)."""
    if configured():
        return D1Connection()
    return local_connection(path)


def target(path):
    """Identity of the storage this process talks to (used for init caching)."""
    if configured():
        return ("d1", os.environ["CAMANIME_D1_DATABASE_ID"].strip())
    return ("sqlite", os.path.abspath(path))


def status():
    """Small dict for /healthz and the admin console."""
    if configured():
        return {"backend": "d1", "persistent": True}
    return {"backend": "sqlite", "persistent": False}
