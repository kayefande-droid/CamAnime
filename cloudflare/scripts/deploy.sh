#!/usr/bin/env bash
# Finish the CamAnime edge deploy in one go.
#
# Prerequisites (only once, interactive):
#   npx wrangler login
#
# Then:  bash scripts/deploy.sh
#
# What it does:
#   1. Verifies the Cloudflare login.
#   2. Creates the D1 database if wrangler.jsonc still holds the placeholder,
#      and patches the real database_id into wrangler.jsonc.
#   3. Creates the R2 bucket (no-op if it already exists).
#   4. Applies schema.sql to the remote D1 database.
#   5. Deploys the worker and prints the live URL.
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

if ! command -v npx >/dev/null 2>&1; then
  echo "npx not found — install Node.js first." >&2
  exit 1
fi

echo "==> Checking Cloudflare authentication"
if npx wrangler whoami 2>&1 | grep -qi "not authenticated"; then
  echo "Not logged in. Run:  npx wrangler login" >&2
  exit 1
fi

DB_NAME="camanime"
BUCKET="camanime-files"

if grep -q "REPLACE_WITH_D1_DATABASE_ID" wrangler.jsonc; then
  echo "==> Creating D1 database '${DB_NAME}'"
  OUT="$(npx wrangler d1 create "$DB_NAME" 2>&1 || true)"
  printf '%s\n' "$OUT"
  DB_ID="$(printf '%s' "$OUT" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
  if [ -z "$DB_ID" ]; then
    echo "Could not read a database_id from the output." >&2
    echo "Create the database in the dashboard, paste its id into wrangler.jsonc, then rerun." >&2
    exit 1
  fi
  python - "$DB_ID" <<'PY'
import pathlib, sys
path = pathlib.Path("wrangler.jsonc")
text = path.read_text(encoding="utf-8")
text = text.replace("REPLACE_WITH_D1_DATABASE_ID", sys.argv[1])
path.write_text(text, encoding="utf-8")
print("wrangler.jsonc: database_id =", sys.argv[1])
PY
else
  echo "==> D1 database_id already configured"
fi

echo "==> Ensuring R2 bucket '${BUCKET}' exists"
npx wrangler r2 bucket create "$BUCKET" 2>&1 | sed 's/^/    /' || \
  echo "    (bucket may already exist — continuing)"

echo "==> Applying schema.sql to remote D1"
npx wrangler d1 execute "$DB_NAME" --remote --file=./schema.sql

echo "==> Deploying worker"
DEPLOY_OUT="$(npx wrangler deploy 2>&1)"
printf '%s\n' "$DEPLOY_OUT"

URL="$(printf '%s' "$DEPLOY_OUT" | grep -oE 'https://[a-zA-Z0-9._-]+\.workers\.dev' | head -1)"
if [ -n "$URL" ]; then
  echo
  echo "Deployed: $URL"
  echo -n "Health check: "
  curl -s --max-time 20 "$URL/healthz" || echo "(health check did not answer yet — CDN can take a few seconds)"
  echo
else
  echo "Deploy finished but no workers.dev URL was found in the output." >&2
fi
