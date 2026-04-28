#!/usr/bin/env bash
# Bootstraps a fresh Linux VPS to host the MVP pool.
# Idempotent: rerun any time to verify/repair. Needs sudo.
#
# What it does:
#   - verifies OS (Ubuntu 22.04/24.04 or Debian 12+)
#   - creates /srv/{infra,apps} with sane ownership
#   - installs Docker + compose plugin (official apt repo)
#   - configures UFW to allow only SSH + 80 + 443
#   - enables unattended-upgrades
#   - ensures a swapfile exists if RAM < 4 GB
#   - generates registry htpasswd on first run, prints the password once
#   - installs the `mvpool` CLI to /usr/local/bin

set -euo pipefail

log()  { printf '\033[1;34m[bootstrap]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[bootstrap]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[bootstrap]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run with sudo"

[[ -r /etc/os-release ]] || die "no /etc/os-release"
. /etc/os-release
case "$ID:$VERSION_ID" in
	ubuntu:22.04|ubuntu:24.04) log "OS: Ubuntu $VERSION_ID — OK" ;;
	ubuntu:*) warn "Ubuntu $VERSION_ID not tested; continuing" ;;
	debian:12|debian:13) warn "Debian $VERSION_ID — close enough, continuing" ;;
	*) die "unsupported OS $ID $VERSION_ID (need Ubuntu LTS or Debian 12+)" ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
[[ "$TARGET_USER" != "root" ]] || warn "running as root with no SUDO_USER — /srv/apps will be root-owned"

log "target user for /srv ownership: $TARGET_USER"

# --- packages -------------------------------------------------------------
log "apt update + base packages"
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
	ca-certificates curl gnupg ufw unattended-upgrades jq git rsync apache2-utils \
	postgresql-client-common postgresql-client

# --- docker ---------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
	log "installing Docker from official repo"
	install -m 0755 -d /etc/apt/keyrings
	# Use the appropriate repo for the distro family; both Ubuntu and Debian
	# are supported by Docker's apt repo with the matching codename.
	docker_distro="ubuntu"
	[[ "$ID" == "debian" ]] && docker_distro="debian"
	curl -fsSL "https://download.docker.com/linux/${docker_distro}/gpg" -o /etc/apt/keyrings/docker.asc
	chmod a+r /etc/apt/keyrings/docker.asc
	echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${docker_distro} $VERSION_CODENAME stable" \
		> /etc/apt/sources.list.d/docker.list
	DEBIAN_FRONTEND=noninteractive apt-get update -qq
	DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
		docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
	systemctl enable --now docker
else
	log "docker already installed ($(docker --version))"
fi

if ! getent group docker | grep -qw "$TARGET_USER"; then
	log "adding $TARGET_USER to docker group"
	usermod -aG docker "$TARGET_USER"
	warn "$TARGET_USER must log out + back in for docker group to take effect"
fi

# --- collisions with host services ----------------------------------------
# We manage Caddy + Postgres via docker-compose. If the host has them as
# systemd services, stop and disable them so port 80/443/5432 are free.
for svc in caddy postgresql; do
	if systemctl list-unit-files "$svc.service" 2>/dev/null | grep -q "$svc.service"; then
		if systemctl is-active --quiet "$svc"; then
			if [[ "$svc" == postgresql ]]; then
				pg_dump_dir="/var/backups/pg-predocker"
				install -d -o postgres -g postgres -m 0750 "$pg_dump_dir"
				log "dumping bare-metal Postgres databases -> $pg_dump_dir (safety)"
				sudo -u postgres bash -c '
					for db in $(psql -Atc "SELECT datname FROM pg_database WHERE NOT datistemplate"); do
						case "$db" in postgres|template*) continue ;; esac
						pg_dump --clean --if-exists "$db" | gzip > "'"$pg_dump_dir"'/$db-$(date +%Y%m%d-%H%M%S).sql.gz"
					done
					pg_dumpall --roles-only | gzip > "'"$pg_dump_dir"'/roles-$(date +%Y%m%d-%H%M%S).sql.gz"
				' || warn "pg_dump had issues; check $pg_dump_dir"
				log "dumps complete in $pg_dump_dir"
			fi
			log "stopping host $svc.service"
			systemctl stop "$svc"
		fi
		if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
			log "disabling host $svc.service (we run this under docker)"
			systemctl disable "$svc"
		fi
	fi
done

# --- firewall -------------------------------------------------------------
log "configuring UFW (22/tcp, 80/tcp, 443/tcp+udp)"
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'ssh'
ufw allow 80/tcp comment 'http'
ufw allow 443/tcp comment 'https'
ufw allow 443/udp comment 'http/3'
ufw --force enable

# --- unattended upgrades --------------------------------------------------
log "enabling unattended-upgrades"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
systemctl enable --now unattended-upgrades.service

# --- swap -----------------------------------------------------------------
mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
mem_gb=$(( mem_kb / 1024 / 1024 ))
if (( mem_gb < 4 )) && [[ ! -f /swapfile ]]; then
	log "RAM is ${mem_gb}G (<4G); creating 2G swapfile"
	fallocate -l 2G /swapfile
	chmod 600 /swapfile
	mkswap /swapfile >/dev/null
	swapon /swapfile
	grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
	sysctl -q -w vm.swappiness=10
	grep -q '^vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
else
	log "swap: OK (RAM=${mem_gb}G)"
fi

# --- /srv layout ----------------------------------------------------------
log "setting up /srv/{infra,apps}"
install -d -o "$TARGET_USER" -g "$TARGET_USER" -m 0755 \
	/srv/infra /srv/apps /srv/infra/sites /srv/infra/backups /srv/infra/state /srv/infra/registry-auth

# --- registry credentials -------------------------------------------------
# First-run only: generate a random password for the registry, write the
# htpasswd file, and emit a Caddy basic_auth import file. The password is
# printed once for the operator to capture; subsequent runs leave it alone.
HTPASSWD_FILE="$SCRIPT_DIR/infra/registry-auth/htpasswd"
CADDY_AUTH_FILE="$SCRIPT_DIR/infra/registry-auth/users.caddy"
if [[ ! -s "$HTPASSWD_FILE" ]]; then
	REGISTRY_USER="${REGISTRY_USER:-mvpool}"
	REGISTRY_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
	log "generating registry credentials (user=$REGISTRY_USER)"
	htpasswd -Bbn "$REGISTRY_USER" "$REGISTRY_PASSWORD" > "$HTPASSWD_FILE"
	chmod 600 "$HTPASSWD_FILE"
	# Caddy's inline basic_auth syntax expects: <user> <bcrypt-hash>
	awk -F: '{ print $1 " " $2 }' "$HTPASSWD_FILE" > "$CADDY_AUTH_FILE"
	chmod 644 "$CADDY_AUTH_FILE"
	cat <<EOF

================================================================================
  REGISTRY CREDENTIALS — WRITE THESE DOWN. They are not stored in plaintext.
  Run from your laptop after DNS + infra is up:
    docker login registry.\${POOL_DOMAIN}
      Username: $REGISTRY_USER
      Password: $REGISTRY_PASSWORD
================================================================================

EOF
else
	log "registry htpasswd already exists at $HTPASSWD_FILE — skipping (delete the file to regenerate)"
fi

# --- mvpool CLI -----------------------------------------------------------
CLI_SRC="$SCRIPT_DIR/bin/mvpool"
if [[ -x "$CLI_SRC" ]]; then
	ln -sf "$CLI_SRC" /usr/local/bin/mvpool
	log "installed /usr/local/bin/mvpool -> $CLI_SRC"
else
	warn "CLI not found at $CLI_SRC — will be installable later"
fi

log "bootstrap complete. Next:"
log "  1. cp $SCRIPT_DIR/infra/.env.example $SCRIPT_DIR/infra/.env && \$EDITOR $SCRIPT_DIR/infra/.env"
log "  2. mvpool infra:install"
log "  3. mvpool infra:up"
