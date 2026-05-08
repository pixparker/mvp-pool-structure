#!/usr/bin/env bash
# 02-docker — install Docker Engine + Compose plugin if not present.
# Idempotent: skips entirely if docker is already runnable.

set -euo pipefail
note() { printf '   %s\n' "$*"; }

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    note "docker already installed: $(docker --version)"
    note "buildx: $(docker buildx version 2>/dev/null | head -1 || echo 'missing')"
    if ! docker buildx version >/dev/null 2>&1; then
        note "installing docker-buildx-plugin (missing on this box)"
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends docker-buildx-plugin
    fi
    # Ensure BUILD_USER is in docker group
    if ! id -nG "$BUILD_USER" | grep -qw docker; then
        note "adding $BUILD_USER to docker group"
        usermod -aG docker "$BUILD_USER"
    fi
    exit 0
fi

note "installing docker-ce + plugins from docker.com apt repo"
install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
fi

. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker

if ! id -nG "$BUILD_USER" | grep -qw docker; then
    note "adding $BUILD_USER to docker group"
    usermod -aG docker "$BUILD_USER"
fi

note "docker: $(docker --version)"
note "compose: $(docker compose version)"
note "buildx: $(docker buildx version | head -1)"
