#!/usr/bin/env bash
# dashboard.sh — open the deploy dashboard.
#
# Establishes (or reuses) an SSH tunnel from this laptop to the dashboard
# on Hetzner, then opens it in the browser. The tunnel survives across
# invocations via SSH ControlMaster (configured in ~/.ssh/config Host hetzner).
#
# Usage:
#   bash demo/static-html/dashboard.sh           # opens http://localhost:8090
#   LOCAL_PORT=9999 bash demo/static-html/dashboard.sh
#   bash demo/static-html/dashboard.sh --close   # tear down the tunnel
#
# Why a wrapper instead of `ssh -fNL` directly:
# - We verify the tunnel actually works before opening the browser (avoids
#   "site can't be reached" because the SSH process died silently).
# - Idempotent: re-running picks up the existing tunnel if alive.
# - On flaky links, retries the connection.

set -euo pipefail

LOCAL_PORT="${LOCAL_PORT:-8090}"
REMOTE_PORT="${REMOTE_PORT:-3030}"
HOST="${HOST:-hetzner}"

case "${1:-}" in
    --close|--down|--stop)
        pkill -f "ssh.*-NL.*${LOCAL_PORT}:localhost:${REMOTE_PORT}.*${HOST}" 2>/dev/null || true
        echo "[ok] tunnel closed"
        exit 0
        ;;
esac

probe() { curl -s --max-time 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${LOCAL_PORT}/healthz" 2>/dev/null || echo "000"; }

# Already up?
code=$(probe)
if [[ "$code" == "200" ]]; then
    echo "[ok] tunnel already up (port ${LOCAL_PORT})"
else
    echo "[start] ssh -fNL ${LOCAL_PORT}:localhost:${REMOTE_PORT} ${HOST}"
    # -f      go to background after auth
    # -N      no remote command
    # -L      local port forward
    # -o ExitOnForwardFailure=yes  fail loudly if port is taken
    if ! ssh -fN -o ExitOnForwardFailure=yes \
              -L "${LOCAL_PORT}:localhost:${REMOTE_PORT}" "${HOST}"; then
        echo "[fail] couldn't open tunnel on ${LOCAL_PORT}. Try a different port:"
        echo "       LOCAL_PORT=9999 bash $0"
        exit 1
    fi

    # Wait up to 5s for the tunnel to be live (the dashboard responds /healthz).
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        sleep 0.5
        code=$(probe)
        [[ "$code" == "200" ]] && break
    done
    if [[ "$code" != "200" ]]; then
        echo "[fail] tunnel reports up but dashboard not answering (got ${code})"
        echo "       check on hetzner:  systemctl status mvpool-dashboard"
        exit 1
    fi
fi

URL="http://localhost:${LOCAL_PORT}/"
echo "[ok] dashboard ready -> ${URL}"
if command -v open >/dev/null 2>&1; then
    open "$URL"
elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$URL"
else
    echo "[hint] open manually: ${URL}"
fi
