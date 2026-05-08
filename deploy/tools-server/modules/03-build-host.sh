#!/usr/bin/env bash
# 03-build-host — /srv/build, buildx instance, swap, weekly prune cron.
# Pure server-side prep for accepting `mvpool-local deploy --build-on <this>`.

set -euo pipefail
note() { printf '   %s\n' "$*"; }

# /srv/build/ tree owned by BUILD_USER
if [[ ! -d /srv/build ]]; then
    note "creating /srv/build"
    install -d -o "$BUILD_USER" -g "$BUILD_USER" -m 0755 /srv/build
fi
install -d -o "$BUILD_USER" -g "$BUILD_USER" -m 0755 /srv/build/.deploys
install -d -o "$BUILD_USER" -g "$BUILD_USER" -m 0755 /srv/build/.ship

# Swap (defensive against webpack OOM)
if [[ ! -f /swapfile ]] && (( SWAP_SIZE_GB > 0 )); then
    note "creating ${SWAP_SIZE_GB}G swapfile at /swapfile"
    fallocate -l "${SWAP_SIZE_GB}G" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    if ! grep -q '^/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
else
    note "swap: $(swapon --show=NAME,SIZE --noheadings | head -1 | tr -s ' ' || echo none)"
fi

# Sysctl tuning (BBR, larger buffers — also helps the VPN).
sysctl_file=/etc/sysctl.d/99-mvpool-tools-server.conf
if [[ ! -f "$sysctl_file" ]]; then
    note "writing $sysctl_file (BBR + buffer tuning)"
    cat > "$sysctl_file" <<'SYSCTL'
net.core.default_qdisc        = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max             = 16777216
net.core.wmem_max             = 16777216
net.ipv4.tcp_fastopen         = 3
SYSCTL
    sysctl --system >/dev/null
else
    note "sysctl: $sysctl_file already present"
fi

# Buildx builder dedicated to mvpool — isolated state from any future
# `docker compose build` use on this same daemon.
if sudo -u "$BUILD_USER" docker buildx inspect mvpool-builder >/dev/null 2>&1; then
    note "buildx builder mvpool-builder: present"
else
    note "creating buildx builder 'mvpool-builder'"
    sudo -u "$BUILD_USER" docker buildx create --name mvpool-builder --use --bootstrap >/dev/null
fi

# Weekly prune cron — keeps disk bounded
cron_file=/etc/cron.weekly/mvpool-build-prune
if [[ ! -f "$cron_file" ]]; then
    note "writing weekly prune cron $cron_file"
    cat > "$cron_file" <<'CRON'
#!/bin/sh
# Bounded cleanup so /srv/build doesn't grow without limit.
docker buildx prune -f --keep-storage 5GB --filter unused-for=168h 2>&1 | tail -5
docker image prune -f --filter dangling=true 2>&1 | tail -5
find /srv/build -name 'img-*.tar.zst' -mtime +14 -delete 2>/dev/null || true
find /srv/build/.ship -name '*.tar.zst' -mtime +3 -delete 2>/dev/null || true
CRON
    chmod 755 "$cron_file"
else
    note "weekly prune cron: present"
fi

# Marker .gitignore so /srv/build isn't accidentally committed if anyone runs
# `git init` here someday.
if [[ ! -f /srv/build/.gitignore ]]; then
    cat > /srv/build/.gitignore <<'EOF'
# Build server scratch space — never commit.
*
EOF
    chown "$BUILD_USER":"$BUILD_USER" /srv/build/.gitignore
fi
