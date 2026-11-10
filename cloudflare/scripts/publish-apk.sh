#!/usr/bin/env bash
# Publish the site's release APK into this deployment's own R2 bucket and switch
# the worker to serve it, so the mirror stops redirecting to the Render origin.
#
#   cloudflare/scripts/publish-apk.sh            # publish + deploy + verify
#   cloudflare/scripts/publish-apk.sh --check    # report readiness only
#
# Safe to re-run: the upload overwrites the same key and the binding is only
# corrected if the bucket name differs.
set -euo pipefail

cd "$(dirname "$0")/.."
BUCKET="${R2_BUCKET:-camanime}"
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

echo "== bucket ($BUCKET) =="
npx wrangler r2 bucket create "$BUCKET" 2>&1 | tail -2 || true

echo "== upload =="
[ -f "$APK" ] || { echo "missing $APK"; exit 1; }
sha256sum "$APK" | awk '{print "local sha256:", $1}'
npx wrangler r2 object put "$BUCKET/$KEY" --file="$APK" \
  --content-type="application/vnd.android.package-archive" --remote 2>&1 | tail -2

echo "== binding =="
BUCKET="$BUCKET" python - <<'BINDPY'
import io, os, re

p = "wrangler.jsonc"
s = io.open(p, encoding="utf-8", newline="").read()
bucket = os.environ["BUCKET"]
H = r"[^\S\r\n]"  # horizontal whitespace only, so it never spans a line break


def set_bucket(text):
    """Point the FILES binding at the bucket that holds the upload."""
    return re.sub(
        r'("binding"\s*:\s*"FILES"\s*,\s*"bucket_name"\s*:\s*")[^"]*(")',
        lambda m: m.group(1) + bucket + m.group(2),
        text,
    )


if not re.search(rf'^{H}*//{H}*"r2_buckets"', s, re.M):
    patched = set_bucket(s)
    if patched != s:
        io.open(p, "w", encoding="utf-8", newline="").write(patched)
        print(f"binding already enabled, pointed at {bucket}")
    else:
        print(f"binding already enabled on {bucket}")
else:
    block = re.search(rf'^{H}*//{H}*"r2_buckets".*?^{H}*//{H}*\],?', s, re.M | re.S)
    assert block, "commented r2_buckets block not found"
    raw = block.group(0)
    fixed = "".join(re.sub(rf'^{H}*//\s?', "", ln) for ln in raw.splitlines(True))
    io.open(p, "w", encoding="utf-8", newline="").write(s.replace(raw, set_bucket(fixed)))
    print(f"binding enabled on {bucket}")
BINDPY

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

echo "== download page agrees =="
curl -s -m 60 "$BASE/download?p=$RANDOM" | grep -oE 'CamAnime [0-9.]+ \(build [0-9]+\).*?MB' | head -1
