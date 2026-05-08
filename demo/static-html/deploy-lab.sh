#!/usr/bin/env bash
# deploy-lab.sh — lab deploy for this demo.
#
#   slug:    lab-hello-static
#   url:     https://lab-hello-static.pagio.ir
#
# Lab is its own slug, so the framework gives it a fully separate compose
# stack, env file, DB role (if any), and domain alongside prod. You can
# break lab freely without affecting prod.
#
# Thin wrapper — the actual logic lives in deploy-core.sh. Same pattern as
# deploy-prod.sh.

set -euo pipefail
export SLUG="${SLUG:-lab-hello-static}"
exec bash "$(dirname "$0")/deploy-core.sh" "$@"
