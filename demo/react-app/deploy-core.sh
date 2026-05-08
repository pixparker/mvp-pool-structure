#!/usr/bin/env bash
# deploy-core.sh — shared deploy logic for the react-app demo, env-agnostic.
#
# Inputs (env vars):
#   SLUG          required.  e.g. "react-app" or "lab-react-app"
#   SOURCE_DIR    optional.  default: this script's directory
#   POOL_SSH      optional.  default: "$MVPOOL_HOST" or "pagio"
#
# Steps (idempotent):
#   1) `mvpool-local mvp:add` if not already registered.
#   2) Patch /srv/infra/sites/<slug>.caddy to use http:// prefix
#      (Iran-restricted pattern; origin can't ACME).
#   3) `mvpool-local deploy ... --build-on hetzner --mode tarball` —
#      Hetzner runs the multi-stage Dockerfile (npm install → vite build →
#      copy dist into runtime image), zstd tarball ships through laptop
#      to pagio. ArvanCloud DNS record auto-created.
#
# --bg / --background: detach the deploy after launch (writes to /tmp log).
# Runs deploy-core via deploy-prod.sh / deploy-lab.sh thin wrappers.

set -euo pipefail

: "${SLUG:?must set SLUG (e.g. react-app or lab-react-app)}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="${SOURCE_DIR:-$HERE}"
POOL_SSH="${POOL_SSH:-${MVPOOL_HOST:-pagio}}"

# --background passthrough (same shape as static-html's deploy-core.sh).
BG=0
for arg in "$@"; do
	case "$arg" in --background|--bg) BG=1 ;; esac
done
[[ "${BG_ALREADY_DETACHED:-0}" == "1" ]] && BG=0

if (( BG )); then
	JOB_ID="${SLUG}-$(date -u +%Y%m%d-%H%M%S)-$(openssl rand -hex 2)"
	LOG="/tmp/mvpool-deploy-${JOB_ID}.log"
	echo "[deploy] backgrounding — job ${JOB_ID}"
	echo "  log:  tail -f ${LOG}"
	echo "  ui:   mvpool-local ui   (opens deploy dashboard, http://localhost:8090)"
	echo "  url:  https://${SLUG}.${POOL_DOMAIN:-pagio.ir}"
	clean_args=()
	for a in "$@"; do
		case "$a" in --background|--bg) ;; *) clean_args+=("$a") ;; esac
	done
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
	mvpool-local mvp:add "$SLUG" --type node-server --no-db --no-redis
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

# Auto-bump the React app's semver patch on **prod** deploys, then use that
# version as the docker image tag. Lab/staging/qa deploys use the current
# version unchanged so they don't fight prod for the same number space.
#
# Override:
#   BUMP=patch | minor | major | none   (default: patch on prod, none elsewhere)
#
# Side-effects: package.json is rewritten (dirty in your tree). We don't auto-
# commit / git-tag — you commit when you're ready, then deploy again to use
# that committed version.
case "$SLUG" in
	lab-*|staging-*|qa-*)  BUMP_DEFAULT=none ;;
	*)                     BUMP_DEFAULT=patch ;;
esac
BUMP="${BUMP:-$BUMP_DEFAULT}"

OLD_VERSION="$(node -p "require('$SOURCE_DIR/package.json').version" 2>/dev/null || echo unknown)"
if [[ "$BUMP" == "none" ]]; then
	VERSION="$OLD_VERSION"
	step "version  ${SLUG} → ${VERSION}  (no bump on this env)"
else
	step "version  bump ${BUMP} for ${SLUG}"
	# `npm version ... --no-git-tag-version` updates package.json + lockfile
	# but skips the auto-commit/tag (we want a clean separation).
	(cd "$SOURCE_DIR" && npm version "$BUMP" --no-git-tag-version >/dev/null)
	VERSION="$(node -p "require('$SOURCE_DIR/package.json').version")"
	note "${OLD_VERSION} → ${VERSION}"
	note "(package.json is now dirty — \`git add package.json package-lock.json && git commit\` when you're ready)"
fi

step "3/3  build (multi-stage Dockerfile on hetzner) + ship — tag=${VERSION}"
TIME_START=$(date +%s)
mvpool-local deploy "$SLUG" \
	--from "$SOURCE_DIR" \
	--tag "$VERSION" \
	--mode tarball
TIME_END=$(date +%s)

step "done · total ${SLUG} deploy: $((TIME_END - TIME_START))s"
note "https:     https://${SLUG}.pagio.ir/      (ArvanCloud edge TLS)"
note "version:   curl -s https://${SLUG}.pagio.ir/api/version"
note "health:    curl -s https://${SLUG}.pagio.ir/health"
note "echo:      curl -s https://${SLUG}.pagio.ir/api/echo"
note "dashboard: mvpool-local ui     (opens deploy dashboard via SSH tunnel)"
note ""
note "If this was the first deploy of '${SLUG}', the ArvanCloud DNS record"
note "is still propagating (TTL 120s). Wait a minute and retry HTTPS."
