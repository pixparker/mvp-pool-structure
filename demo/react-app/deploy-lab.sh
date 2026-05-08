#!/usr/bin/env bash
# deploy-lab.sh — lab deploy for the react-app demo.
#
#   slug:    lab-react-app
#   url:     https://lab-react-app.pagio.ir
#
# Thin wrapper — actual logic in deploy-core.sh, parameterised by SLUG.

set -euo pipefail
export SLUG="${SLUG:-lab-react-app}"
exec bash "$(dirname "$0")/deploy-core.sh" "$@"
