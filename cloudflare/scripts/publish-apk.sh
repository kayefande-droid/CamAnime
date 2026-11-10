#!/usr/bin/env bash
# Publish the site's release APK into this deployment's own R2 bucket and switch
# the worker to serve it, so the mirror stops redirecting to the Render origin.
#
# Run it after R2 is enabled for the account (Dashboard → R2 → Enable). Until
# then the Cloudflare API answers 10042 and this script stops before changing
# anything.
#
#   cloudflare/scripts/publish-apk.sh            # publish + deploy + verify
#   cloudflare/scripts/publish-apk.sh --check    # report readiness only
set -euo pipefail

cd "$(dirname "$0")/.."
BUCKET="camanime-files"
KEY="downloads/CamAnime.apk"
APK="../static/downloads/CamAnime.apk"
BASE="https://camanjme.camanime.workers.dev"

[ -f .cf-deploy.env ] || { echo "missing cloudflare/.cf-deploy.env"; exit 1; }
set -a; . ./.cf-deploy.env; set +a

auth=(-H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}")

echo "== R2 status =="
r2=$(curl -s -m 30 "${auth[@]}" \
  "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/r2/buckets")
case "$r2" in
  *'"success":true'*) echo "R2 enabled" ;;
  *)
    echo "$r2" | head -c 300; echo
    echo "R2 is not enabled on this account — enable it in the dashboard first."
    exit 2 ;;
esac

[ "${1:-}" = "--check" ] && exit 0

echo "== bucket =="
npx wrangler r2 bucket create "$BUCKET" 2>&1 | tail -2 || true

echo "== upload =="
[ -f "$APK" ] || { echo "missing $APK"; exit 1; }
sha256sum "$APK" | awk '{print "local sha256:", $1}'
npx wrangler r2 object put "$BUCKET/$KEY" --file="$APK" \
  --content-type="application/vnd.android.package-archive" --remote 2>&1 | tail -3

echo "== binding =="
python - <<'PY'
import io, re
p = "wrangler.jsonc"
s = io.open(p, encoding="utf-8", newline="").read()
if '"r2_buckets"' in s and not re.search(r'^\s*//\s*"r2_buckets"', s, re.M):
    print("binding already enabled")
else:
    block = re.search(r'^\s*//\s*"r2_buckets".*?^\s*//\s*\],?', s, re.M | re.S)
    assert block, "r2_buckets block not found"
    raw = block.group(0)
    fixed = "\n".join(re.sub(r'^(\s*)//\s?', r'\1', ln) for ln in raw.splitlines())
    s = s.replace(raw, fixed)
    io.open(p, "w", encoding="utf-8", newline="").write(s)
    print("binding enabled")
PY

echo "== deploy =="
npx wrangler deploy 2>&1 | tail -3
sleep 6

echo "== verify =="
read -r code length < <(curl -s -m 90 -o /dev/null -D - "$BASE/get/android?verify=$RANDOM" \
  | tr -d '\r' \
  | awk 'BEGIN{IGNORECASE=1} /^HTTP/{c=$2} /^content-length:/{l=$2} END{print c, l}')
echo "GET /get/android -> $code, content-length ${length:-none}"
[ "$code" = "200" ] || { echo "still not served from R2"; exit 1; }
expected=$(stat -c %s "$APK" 2>/dev/null || stat -f %z "$APK")
[ "${length:-0}" = "$expected" ] && echo "bytes match the site build ($expected)" \
  || { echo "size mismatch: served ${length:-none}, local $expected"; exit 1; }

echo "== range support =="
curl -s -m 60 -o /dev/null -D - -H "Range: bytes=0-1023" "$BASE/get/android?r=$RANDOM" \
  | tr -d '\r' | awk 'BEGIN{IGNORECASE=1} /^HTTP|^content-range|^content-length/'
