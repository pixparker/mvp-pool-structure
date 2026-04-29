#!/usr/bin/env bash
# Refresh the offline bundle. Run on a laptop with global internet.
#
#   cd download/
#   ./refresh.sh                      # full refresh
#   ./refresh.sh --debs-only          # only re-download .debs
#   ./refresh.sh --images-only        # only re-save docker images
#
# Output:
#   debs/*.deb                        Ubuntu noble .debs for docker.io + plugins + tools
#   images/*.tar                      docker save tarballs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")" && pwd)"
cd "$SCRIPT_DIR"

log() { printf '\033[1;34m[refresh]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m✓\033[0m %s\n' "$*"; }

# Apt packages we want pre-cached on the server.
# These get installed by install-bundle.sh via `dpkg -i`.
APT_PACKAGES=(
	docker.io
	docker-compose-v2
	docker-buildx
	ufw
	jq
	curl
	rsync
	apache2-utils
)

# Docker images we want pre-loaded on the server.
# Names must be exact (with tag) so `docker save` produces the right tarballs.
IMAGES=(
	caddy:2-alpine
	nginx:1.27-alpine
	postgres:16-alpine
	redis:7-alpine
	registry:2
)

DO_DEBS=1
DO_IMAGES=1
case "${1:-}" in
	--debs-only) DO_IMAGES=0 ;;
	--images-only) DO_DEBS=0 ;;
	"") ;;
	*) echo "usage: $0 [--debs-only|--images-only]" >&2; exit 2 ;;
esac

command -v docker >/dev/null 2>&1 || { echo "docker is required on the laptop" >&2; exit 1; }

if (( DO_DEBS )); then
	log "downloading .debs for noble (apt-get install --download-only inside ubuntu:24.04)"
	mkdir -p debs
	rm -f debs/*.deb
	# Use a transient container as a "download station": its apt cache will hold
	# every .deb required by `apt install <APT_PACKAGES>`, including transitive
	# dependencies. Then we copy them out.
	docker run --rm \
		-v "$SCRIPT_DIR/debs:/debs" \
		ubuntu:24.04 bash -c "
			set -e
			apt-get update -qq
			apt-get install -y -qq --download-only ${APT_PACKAGES[*]}
			cp /var/cache/apt/archives/*.deb /debs/
			ls /debs | wc -l
		"
	count=$(ls debs/*.deb 2>/dev/null | wc -l | tr -d ' ')
	size=$(du -sh debs | cut -f1)
	ok "debs: $count files, $size total"
fi

if (( DO_IMAGES )); then
	log "pulling + saving docker images"
	mkdir -p images
	for img in "${IMAGES[@]}"; do
		safe=$(echo "$img" | tr ':/' '__')
		out="images/${safe}.tar"
		log "  $img -> $out"
		docker pull -q "$img" >/dev/null
		docker save -o "$out" "$img"
	done
	count=$(ls images/*.tar 2>/dev/null | wc -l | tr -d ' ')
	size=$(du -sh images | cut -f1)
	ok "images: $count files, $size total"
fi

log "bundle ready in: $SCRIPT_DIR"
log "ship to server with: rsync -avh $SCRIPT_DIR/ root@<server>:/root/mvpool-bundle/"
log "then on server:      bash /root/mvpool-bundle/install-bundle.sh"
