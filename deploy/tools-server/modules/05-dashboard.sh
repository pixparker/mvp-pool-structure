#!/usr/bin/env bash
# 05-dashboard — install Bun, deploy the dashboard files, register systemd unit.
# Idempotent. Re-running picks up dashboard code changes.

set -euo pipefail
note() { printf '   %s\n' "$*"; }

DASHBOARD_SRC="$(cd "$TOOLS_SERVER_ROOT/.." && pwd)/dashboard"
DASHBOARD_DST=/srv/build/dashboard
USER_HOME="$(getent passwd "$BUILD_USER" | cut -d: -f6)"
BUN_BIN="$USER_HOME/.bun/bin/bun"
SERVICE_NAME=mvpool-dashboard.service

# 0) Sanity
[[ -d "$DASHBOARD_SRC" ]] || { echo "missing dashboard source at $DASHBOARD_SRC" >&2; exit 1; }

# 1) Install Bun for BUILD_USER (skip if present).
if [[ ! -x "$BUN_BIN" ]]; then
    note "installing bun for $BUILD_USER"
    sudo -u "$BUILD_USER" bash -c 'curl -fsSL https://bun.sh/install | bash >/dev/null'
else
    note "bun present: $("$BUN_BIN" --version)"
fi

# 2) Sync dashboard files to /srv/build/dashboard
note "syncing dashboard source -> $DASHBOARD_DST"
install -d -o "$BUILD_USER" -g "$BUILD_USER" -m 0755 "$DASHBOARD_DST"
rsync -a --delete \
    --exclude=node_modules --exclude=.DS_Store \
    "$DASHBOARD_SRC/" "$DASHBOARD_DST/"
chown -R "$BUILD_USER":"$BUILD_USER" "$DASHBOARD_DST"

# 3) Install dashboard deps via bun
note "bun install"
sudo -u "$BUILD_USER" -H bash -c "cd $DASHBOARD_DST && $BUN_BIN install --production --silent"

# 4) Systemd unit
unit_file="/etc/systemd/system/$SERVICE_NAME"
desired_unit="$(cat <<UNIT
[Unit]
Description=mvpool deploy dashboard (Bun + Hono)
After=network.target
Documentation=https://github.com/your-org/mvp-pool

[Service]
Type=simple
User=${BUILD_USER}
Group=${BUILD_USER}
WorkingDirectory=${DASHBOARD_DST}
Environment=PORT=${DASHBOARD_PORT}
Environment=HOST=127.0.0.1
Environment=MVPOOL_DEPLOYS_JSONL=/srv/build/.deploys/deployments.jsonl
ExecStart=${BUN_BIN} run server.ts
Restart=on-failure
RestartSec=2
LimitNOFILE=65536
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=${DASHBOARD_DST}
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
)"

if [[ ! -f "$unit_file" ]] || ! cmp -s <(printf '%s' "$desired_unit") "$unit_file"; then
    note "writing $unit_file"
    printf '%s' "$desired_unit" > "$unit_file"
    systemctl daemon-reload
fi

systemctl enable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
systemctl restart "$SERVICE_NAME"
sleep 1

if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "ERROR: $SERVICE_NAME failed to start. Check: journalctl -u $SERVICE_NAME -n 30 --no-pager" >&2
    exit 1
fi

# 5) Smoke test
if curl -fsS --max-time 4 "http://127.0.0.1:${DASHBOARD_PORT}/healthz" | grep -q ok; then
    note "dashboard healthy at http://127.0.0.1:${DASHBOARD_PORT}"
else
    echo "WARN: dashboard healthz didn't return ok" >&2
fi
