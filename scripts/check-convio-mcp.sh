#!/usr/bin/env bash
# Prove the Convio MCP endpoint answers this machine.
#
#   CONVIO_API_KEY=... scripts/check-convio-mcp.sh
#
# The key belongs to the MCP client configuration and must never be committed.
# A successful run prints the server's name and protocol version from an MCP
# `initialize` handshake.
set -euo pipefail

URL="${CONVIO_MCP_URL:-https://mcp.convio.dev}"
: "${CONVIO_API_KEY:?set CONVIO_API_KEY (the one from your MCP client config)}"

body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"freebuff-check","version":"1"}}}'

code=$(curl -sS -m 30 -o /tmp/convio-init.json -w '%{http_code}' \
  -H "Authorization: Bearer ${CONVIO_API_KEY}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d "$body" "$URL")

echo "HTTP $code from $URL"
head -c 400 /tmp/convio-init.json; echo
if [ "$code" != "200" ]; then
  echo "FAILED: the endpoint did not accept the handshake (401 means a bad key)."
  exit 1
fi
grep -q '"result"' /tmp/convio-init.json \
  && echo "OK: MCP handshake completed" \
  || { echo "FAILED: no MCP result in the response"; exit 1; }
