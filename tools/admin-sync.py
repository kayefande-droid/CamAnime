#!/usr/bin/env python3
"""CamAnime admin + secret sync checker.

Checks that website and native app share the same admin and secret:
  1. CAMANIME_SECRET is set (stable sessions across restarts/workers)
  2. Default or env admin exists and can sign in
  3. /api/admin/sync is reachable as admin (Bearer token works for apps)

Usage:
  python tools/admin-sync.py --base https://camanime.onrender.com \\
    --email admin@camanime.local --password 'your-password'

Only use accounts you own. Never commit real passwords.
"""
import argparse
import os
import secrets
import sys

try:
    import requests
except ImportError:
    print("Install requests first: pip install requests")
    sys.exit(2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default=os.environ.get("CAMANIME_API", "http://localhost:3000"))
    ap.add_argument("--email", default=os.environ.get("CAMANIME_ADMIN_EMAIL", "admin@camanime.local"))
    ap.add_argument("--password", default=os.environ.get("CAMANIME_ADMIN_PASSWORD", ""))
    ap.add_argument("--generate-secret", action="store_true", help="Print a new CAMANIME_SECRET value")
    args = ap.parse_args()

    if args.generate_secret:
        print("CAMANIME_SECRET=" + secrets.token_hex(32))
        print("Set it in Render dashboard -> Environment, then redeploy.")
        return 0

    base = args.base.rstrip("/")
    if not args.password:
        print("Provide --password or set CAMANIME_ADMIN_PASSWORD env.")
        print("Default first-run email is admin@camanime.local (change it in /admin).")
        return 2

    r = requests.post(base + "/api/auth/login", json={"email": args.email, "password": args.password}, timeout=20)
    try:
        data = r.json()
    except Exception:
        print(f"Login failed: HTTP {r.status_code} (not JSON)")
        return 1
    if data.get("status") != "success":
        print(f"Login failed: {data.get('error')}")
        return 1
    token = data["token"]
    role = data.get("user", {}).get("role")
    print(f"Login OK as {args.email} (role={role})")

    s = requests.get(base + "/api/admin/sync", headers={"Authorization": f"Bearer {token}"}, timeout=20)
    try:
        sync = s.json()
    except Exception:
        print(f"/api/admin/sync failed: HTTP {s.status_code}")
        return 1
    if sync.get("status") != "success":
        print(f"Sync check failed (admin only): {sync.get('error')}")
        print("Sign in at /login as admin first, or check the Bearer token.")
        return 1
    print(f"Sync OK: admin={sync['admin_email']} secret_configured={sync['secret_configured']}")
    print(f"DB: {sync['db_path']} app={sync['app_version']} apk={sync['apk_url']}")
    if not sync["secret_configured"]:
        print("WARNING: CAMANIME_SECRET is not set; sessions reset on restart.")
        print("Run: python tools/admin-sync.py --generate-secret")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
