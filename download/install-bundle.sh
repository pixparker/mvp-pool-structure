#!/usr/bin/env bash
# install-bundle.sh — server-side installer for the offline bundle.
#
# Run as root on the pool VPS:
#   bash /root/mvpool-bundle/install-bundle.sh
#
# Idempotent: re-running is safe. Skips steps that are already complete.
#
# This script handles the "restricted-network" install path:
#  - Docker is installed from a static binary tarball (no apt needed).
#  - Compose plugin is installed as a single binary.
#  - Runtime images are loaded from `docker save` tarballs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")" && pwd)"

log() { printf '\033[1;34m[install-bundle]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[install-bundle]\033[0m %s\n' "$*" >&2; }

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

# --- 1. install Docker from static binary tarball ----------------------------
if command -v docker >/dev/null 2>&1; then
	log "docker already installed: $(docker --version)"
else
	tgz=$(ls "$SCRIPT_DIR/docker"/docker-*.tgz 2>/dev/null | head -1 || true)
	[[ -n "$tgz" && -f "$tgz" ]] || { echo "ERROR: missing docker-<version>.tgz under $SCRIPT_DIR/docker/" >&2; exit 1; }
	log "installing docker engine from $(basename "$tgz")"
	tmp=$(mktemp -d)
	tar -xzf "$tgz" -C "$tmp"
	# Move every binary from the tar's docker/ dir into /usr/local/bin
	install -m 0755 "$tmp"/docker/* /usr/local/bin/
	rm -rf "$tmp"
	ok "docker binaries installed: $(ls /usr/local/bin/docker* /usr/local/bin/containerd* /usr/local/bin/runc /usr/local/bin/ctr 2>/dev/null | wc -l) files"
fi

# --- 2. install compose plugin ----------------------------------------------
COMPOSE_PLUGIN_DIR=/usr/local/lib/docker/cli-plugins
mkdir -p "$COMPOSE_PLUGIN_DIR"
if [[ -x "$COMPOSE_PLUGIN_DIR/docker-compose" ]]; then
	log "compose plugin already in place: $($COMPOSE_PLUGIN_DIR/docker-compose version --short 2>&1 || echo unknown)"
else
	compose_bin=$(ls "$SCRIPT_DIR/docker"/docker-compose-linux-x86_64 2>/dev/null || true)
	[[ -n "$compose_bin" && -f "$compose_bin" ]] || { echo "ERROR: missing docker-compose-linux-x86_64 under $SCRIPT_DIR/docker/" >&2; exit 1; }
	install -m 0755 "$compose_bin" "$COMPOSE_PLUGIN_DIR/docker-compose"
	ok "compose plugin installed: $($COMPOSE_PLUGIN_DIR/docker-compose version --short 2>&1)"
fi

# --- 3. systemd units for dockerd + containerd ------------------------------
# The static tarball has no systemd integration; we generate minimal units.
if [[ ! -f /etc/systemd/system/docker.service ]]; then
	log "creating systemd units for dockerd + containerd"
	cat > /etc/systemd/system/containerd.service <<'EOF'
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd
Type=notify
Delegate=yes
KillMode=process
Restart=always
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=1048576
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF

	cat > /etc/systemd/system/docker.service <<'EOF'
[Unit]
Description=Docker Application Container Engine
Documentation=https://docs.docker.com
After=network-online.target containerd.service
Wants=network-online.target
Requires=docker.socket containerd.service

[Service]
Type=notify
ExecStart=/usr/local/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock
ExecReload=/bin/kill -s HUP $MAINPID
TimeoutStartSec=0
RestartSec=2
Restart=always
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=1048576
TasksMax=infinity
Delegate=yes
KillMode=process
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
EOF

	cat > /etc/systemd/system/docker.socket <<'EOF'
[Unit]
Description=Docker Socket for the API

[Socket]
ListenStream=/var/run/docker.sock
SocketMode=0660
SocketUser=root
SocketGroup=docker

[Install]
WantedBy=sockets.target
EOF

	getent group docker >/dev/null 2>&1 || groupadd --system docker
	systemctl daemon-reload
	ok "systemd units created"
fi

systemctl enable --now containerd.service
systemctl enable --now docker.socket
systemctl enable --now docker.service

# wait briefly for dockerd to settle
for _ in 1 2 3 4 5 6 7 8 9 10; do
	if docker info >/dev/null 2>&1; then break; fi
	sleep 1
done
docker --version
docker compose version
ok "docker daemon up"

# --- 4. load images ---------------------------------------------------------
if [[ -d "$SCRIPT_DIR/images" && -n "$(ls "$SCRIPT_DIR/images"/*.tar 2>/dev/null || true)" ]]; then
	log "loading docker images from $SCRIPT_DIR/images"
	for tar in "$SCRIPT_DIR/images"/*.tar; do
		name=$(basename "$tar" .tar)
		docker load -i "$tar" 2>&1 | sed 's/^/  /'
	done
	ok "image load complete"
	log "images now in local docker:"
	docker images --format '  {{.Repository}}:{{.Tag}}  {{.Size}}' | sort
else
	log "no image tarballs in $SCRIPT_DIR/images — skipping"
fi

# --- 5. swap, /srv layout, mvpool symlink (the non-Docker parts of bootstrap.sh) ---
mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
mem_gb=$(( mem_kb / 1024 / 1024 ))
if (( mem_gb < 4 )) && [[ ! -f /swapfile ]]; then
	log "RAM is ${mem_gb}G (<4G); creating 2G swapfile"
	fallocate -l 2G /swapfile
	chmod 600 /swapfile
	mkswap /swapfile >/dev/null
	swapon /swapfile
	grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
	sysctl -q -w vm.swappiness=10 || true
	grep -q '^vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
	ok "swap on"
else
	log "swap: OK (RAM=${mem_gb}G)"
fi

log "ensuring /srv layout"
install -d -m 0755 /srv /srv/infra /srv/apps /srv/infra/sites /srv/infra/backups /srv/infra/state
ok "/srv ready"

# --- 6. mvpool CLI symlink ---------------------------------------------------
# The framework should already be at /opt/mvp-pool (rsynced from operator's laptop).
# install-bundle.sh lives at /opt/mvp-pool/download/install-bundle.sh, so we can
# walk up to find the framework root.
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI_SRC="$FRAMEWORK_ROOT/deploy/bin/mvpool"
if [[ -x "$CLI_SRC" ]]; then
	ln -sf "$CLI_SRC" /usr/local/bin/mvpool
	ok "installed /usr/local/bin/mvpool -> $CLI_SRC"
else
	warn "mvpool CLI not found at $CLI_SRC — install manually"
fi

# --- 7. Iran/restricted-network: patch infra files to skip the self-hosted registry --
# The default Caddyfile at infra/Caddyfile imports registry-auth/users.caddy
# and exposes registry.\${POOL_DOMAIN}. Without the registry image (we don't ship
# it on Iran VPSes), that block fails Caddy startup. Patch it out idempotently.
INFRA_DIR_FW="$FRAMEWORK_ROOT/deploy/infra"
CADDYFILE="$INFRA_DIR_FW/Caddyfile"
if [[ -f "$CADDYFILE" ]] && grep -q "registry.{\\\$POOL_DOMAIN}" "$CADDYFILE"; then
	log "patching Caddyfile: removing registry block (Iran/no-registry mode)"
	cp "$CADDYFILE" "$CADDYFILE.bak"
	# delete the registry block (registry.{$POOL_DOMAIN} { ... }) inclusive of braces
	awk '
		BEGIN { skip = 0; depth = 0 }
		/^registry\.\{\$POOL_DOMAIN\}/ { skip = 1; depth = 0 }
		skip {
			depth += gsub(/\{/, "{")
			depth -= gsub(/\}/, "}")
			if (depth <= 0 && /\}/) { skip = 0; next }
			next
		}
		{ print }
	' "$CADDYFILE.bak" > "$CADDYFILE"
	ok "Caddyfile patched (.bak kept for diff)"
fi

COMPOSE_INFRA="$INFRA_DIR_FW/compose.yaml"
if [[ -f "$COMPOSE_INFRA" ]] && grep -qE "^[[:space:]]*registry:[[:space:]]*$" "$COMPOSE_INFRA"; then
	log "patching infra/compose.yaml: removing registry service"
	cp "$COMPOSE_INFRA" "$COMPOSE_INFRA.bak"
	# strip the `registry:` service block (and its body up to the next top-level
	# service line OR end-of-services). Top-level services are 2-space-indented.
	awk '
		BEGIN { in_reg = 0 }
		/^  registry:[[:space:]]*$/ { in_reg = 1; next }
		in_reg {
			# stop dropping when we hit another 2-space-indented service or a
			# different top-level section
			if (/^[a-z]/ || /^  [a-zA-Z]/) { in_reg = 0; print; next }
			next
		}
		{ print }
	' "$COMPOSE_INFRA.bak" > "$COMPOSE_INFRA"
	ok "infra/compose.yaml patched"
fi

# --- 8. final notes ----------------------------------------------------------
ok "bundle install complete"
echo
echo "Next steps:"
echo "  bash /opt/mvp-pool/deploy/bootstrap.sh   # finishes UFW + swap + /srv layout (skips Docker, already installed)"
echo "  mvpool infra:install                     # generates /srv/infra/.env + symlinks"
echo "  \$EDITOR /srv/infra/.env                  # set ACME_EMAIL + POOL_DOMAIN"
echo "  mvpool infra:up                          # start Caddy (and Postgres/Redis if their images are present)"
