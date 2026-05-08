#!/usr/bin/env bash
# deploy-core.sh — shared deploy logic for this demo, env-agnostic.
#
# Inputs (env vars):
#   SLUG          required.  e.g. "hello-static" or "lab-hello-static"
#   SOURCE_DIR    optional.  default: this script's directory
#   STATIC_ROOT   optional.  default: "prototype"
#   POOL_SSH      optional.  default: "$MVPOOL_HOST" or "pagio"
#
# Idempotent. Safe to re-run. Steps:
#   1) Register the slug on the pool VPS via `mvpool-local mvp:add` if absent.
#   2) Patch /srv/infra/sites/<slug>.caddy to use the `http://` prefix
#      (Iran-restricted pattern — origin can't reach Let's Encrypt for ACME).
#   3) Build on the configured BUILD_HOST (default: hetzner) and tarball-ship
#      via the laptop to pagio. mvpool-local also creates the ArvanCloud
#      DNS record idempotently (uses MVPOOL_ARVANCLOUD_API_TOKEN).
#
# Direct use is fine, but the env-specific wrappers (deploy-prod.sh,
# deploy-lab.sh) are more readable: they just `export SLUG=… && exec
# deploy-core.sh`.

set -euo pipefail

: "${SLUG:?must set SLUG (e.g. hello-static or lab-hello-static)}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="${SOURCE_DIR:-$HERE}"
STATIC_ROOT="${STATIC_ROOT:-prototype}"
POOL_SSH="${POOL_SSH:-${MVPOOL_HOST:-pagio}}"

# --background / --bg / BG=1: detach the deploy after launch so the terminal
# returns immediately. Output redirects to /tmp/mvpool-deploy-<slug>-<ts>.log
# on the laptop, and the dashboard's status transitions still update normally.
BG=0
for arg in "$@"; do
	case "$arg" in
		--background|--bg) BG=1 ;;
	esac
done
[[ "${BG_ENV:-${BG_FLAG:-0}}" == "1" ]] && BG=1
[[ "${BG_ALREADY_DETACHED:-0}" == "1" ]] && BG=0   # we're inside the detached child

if (( BG )); then
	JOB_ID="${SLUG}-$(date -u +%Y%m%d-%H%M%S)-$(openssl rand -hex 2)"
	LOG="/tmp/mvpool-deploy-${JOB_ID}.log"
	echo "[deploy] backgrounding — job ${JOB_ID}"
	echo "  log:  tail -f ${LOG}"
	echo "  ui:   bash demo/static-html/dashboard.sh   (opens http://localhost:8090)"
	echo "  url:  https://${SLUG}.${POOL_DOMAIN:-pagio.ir}"
	# Re-exec self in detached mode. Pass everything except --background flags.
	clean_args=()
	for a in "$@"; do
		case "$a" in --background|--bg) ;; *) clean_args+=("$a") ;; esac
	done
	# `${arr[@]:+...}` is the safe expansion that yields nothing when arr is
	# empty (avoiding the "unbound variable" error from `set -u`).
	BG_ALREADY_DETACHED=1 MVPOOL_JOB_ID="$JOB_ID" \
		nohup bash "$0" ${clean_args[@]+"${clean_args[@]}"} >"$LOG" 2>&1 &
	disown $! 2>/dev/null || true
	exit 0
fi

step() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }

step "1/3  ensure slug '${SLUG}' is registered on ${POOL_SSH}"
if ssh "$POOL_SSH" "test -f /srv/apps/${SLUG}/.meta" 2>/dev/null; then
    note "already registered (/srv/apps/${SLUG}/.meta exists)"
else
    mvpool-local mvp:add "$SLUG" --type static --no-db --no-redis
fi

step "2/3  ensure Caddy site uses http:// prefix (Iran-restricted pattern)"
ssh "$POOL_SSH" "set -eu
site=/srv/infra/sites/${SLUG}.caddy
[ -f \"\$site\" ] || { echo \"   site file not found, skipping patch\"; exit 0; }
if grep -q '^http://${SLUG}\\.' \"\$site\"; then
    echo '   already http:// prefixed'
elif grep -qE '^${SLUG}\\.[a-z]' \"\$site\"; then
    sed -i.bak 's|^${SLUG}\\.|http://${SLUG}.|' \"\$site\"
    echo '   patched site file, reloading Caddy'
    mvpool infra:reload-caddy 2>&1 | tail -1
else
    echo \"   unexpected site-file shape, leaving alone\"
fi
"

step "3/3  build + ship (mvpool-local also auto-creates ArvanCloud DNS)"
mvpool-local deploy "$SLUG" \
    --from "$SOURCE_DIR" \
    --static-root "$STATIC_ROOT" \
    --mode tarball

step "done"
note "https:    https://${SLUG}.pagio.ir/      (ArvanCloud edge TLS)"
note "version:  curl -s https://${SLUG}.pagio.ir/version.txt"
note ""
note "If HTTPS fails for a brand-new slug, the ArvanCloud DNS record is"
note "still propagating (TTL 120s). Wait a minute, then retry."
