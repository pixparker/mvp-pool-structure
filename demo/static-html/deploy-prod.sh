#!/usr/bin/env bash
# deploy-prod.sh — production deploy for this demo.
#
#   slug:    hello-static
#   url:     https://hello-static.pagio.ir
#
# Thin wrapper — the actual logic lives in deploy-core.sh, parameterised by
# the SLUG env var below. Same pattern as deploy-lab.sh.

set -euo pipefail
export SLUG="${SLUG:-hello-static}"
exec bash "$(dirname "$0")/deploy-core.sh" "$@"
