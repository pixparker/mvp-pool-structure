#!/usr/bin/env bash
# 01-base — OS hardening + tools the rest of the bootstrap needs.
# Idempotent: detects existing state and skips work it doesn't need to do.

set -euo pipefail

note() { printf '   %s\n' "$*"; }

# Time sync (matters for TLS validation and cron scheduling)
if ! systemctl is-active systemd-timesyncd >/dev/null 2>&1 \
   && ! systemctl is-active chrony >/dev/null 2>&1 \
   && ! systemctl is-active ntp >/dev/null 2>&1; then
    note "enabling systemd-timesyncd"
    timedatectl set-ntp true
else
    note "time sync: ok"
fi

# apt baseline — only the small handful of packages we genuinely need.
APT_PKGS=(curl ca-certificates gnupg rsync ufw zstd jq)
MISSING=()
for p in "${APT_PKGS[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || MISSING+=("$p")
done
if (( ${#MISSING[@]} > 0 )); then
    note "apt install: ${MISSING[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${MISSING[@]}"
else
    note "apt: all required packages present"
fi

# UFW — default deny inbound, allow ssh + http(s) + the VPN port.
if ! ufw status | grep -q '^Status: active'; then
    note "enabling UFW with default-deny inbound"
    ufw --force default deny incoming
    ufw --force default allow outgoing
    ufw --force enable
fi

ufw_allow() {
    local rule="$1" comment="$2"
    if ufw status verbose | grep -qE "^${rule%/*}/${rule##*/}\s"; then
        note "ufw rule ${rule} already present"
    else
        note "ufw allow ${rule} (${comment})"
        ufw allow "$rule" comment "$comment"
    fi
}
ufw_allow "22/tcp"    "ssh"
ufw_allow "80/tcp"    "http (caddy / lets-encrypt)"
ufw_allow "443/tcp"   "https"
ufw_allow "443/udp"   "http3 (caddy)"
ufw_allow "${VPN_PORT}/tcp" "xray vless reality"

# Ensure the build user exists and has SSH (best-effort: don't fight existing setup)
if id "$BUILD_USER" >/dev/null 2>&1; then
    note "user $BUILD_USER: exists"
else
    note "creating user $BUILD_USER"
    useradd -m -s /bin/bash -G sudo,docker "$BUILD_USER" 2>/dev/null || \
        useradd -m -s /bin/bash -G sudo "$BUILD_USER"
fi
