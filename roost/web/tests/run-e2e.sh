#!/usr/bin/env bash
# Builds the server + web app, starts a fresh server, runs the Playwright E2E.
# Usage: tests/run-e2e.sh   (from roost/web)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d)
PORT=${PORT:-8097}
(cd "$ROOT/server" && CGO_ENABLED=0 go build -o "$WORK/roost-server" .)
(cd "$ROOT/web" && npx tsc --noEmit && npx vite build >/dev/null)
ROOST_WEB_PATH=/h/test-family/ ROOST_WEB_DIR="$ROOT/web/dist" "$WORK/roost-server" serve --http 127.0.0.1:$PORT --dir "$WORK/pb" >"$WORK/server.log" 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null; rm -rf "$WORK"' EXIT
for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null && break; sleep 0.2; done
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost ROOST_E2E_URL="http://127.0.0.1:$PORT/h/test-family/" node "$ROOT/web/tests/e2e.mjs"
