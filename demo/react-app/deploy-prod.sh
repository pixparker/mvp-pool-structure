#!/usr/bin/env bash
# deploy-prod.sh — production deploy for the react-app demo.
#
#   slug:    react-app
#   url:     https://react-app.pagio.ir
#
# Thin wrapper — actual logic in deploy-core.sh, parameterised by SLUG.

set -euo pipefail
export SLUG="${SLUG:-react-app}"
exec bash "$(dirname "$0")/deploy-core.sh" "$@"
