#!/usr/bin/env bash
# 04-vpn-xray — Xray VLESS+Reality VPN.
# Idempotent: reuses existing keys from $ENV_FILE if present, otherwise
# generates fresh ones and persists them. Always re-renders the config so
# that VPN_PORT / VPN_SNI changes take effect.

set -euo pipefail
note() { printf '   %s\n' "$*"; }

XRAY_BIN=/usr/local/bin/xray
XRAY_CONFIG=/usr/local/etc/xray/config.json

# 1) Install xray if missing (official static-binary installer).
if [[ ! -x "$XRAY_BIN" ]]; then
    note "installing xray-core (XTLS official installer)"
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
else
    note "xray already installed: $($XRAY_BIN version | head -1)"
fi

# 2) Generate or reuse Reality keys + UUID + shortId.
need_keys=0
[[ -z "${REALITY_PRIVATE_KEY:-}" ]] && need_keys=1
[[ -z "${REALITY_PUBLIC_KEY:-}"  ]] && need_keys=1
[[ -z "${VLESS_UUID:-}"          ]] && need_keys=1
[[ -z "${REALITY_SHORT_ID:-}"    ]] && need_keys=1

if (( need_keys )); then
    note "generating fresh Reality keypair, UUID, shortId"
    keys="$($XRAY_BIN x25519)"
    REALITY_PRIVATE_KEY="$(printf '%s\n' "$keys" | awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}')"
    REALITY_PUBLIC_KEY="$(printf  '%s\n' "$keys" | awk -F': *' 'tolower($1) ~ /public|password/ {print $2; exit}')"
    VLESS_UUID="$($XRAY_BIN uuid)"
    REALITY_SHORT_ID="$(openssl rand -hex 8)"
    _persist_env_var REALITY_PRIVATE_KEY "$REALITY_PRIVATE_KEY"
    _persist_env_var REALITY_PUBLIC_KEY  "$REALITY_PUBLIC_KEY"
    _persist_env_var VLESS_UUID          "$VLESS_UUID"
    _persist_env_var REALITY_SHORT_ID    "$REALITY_SHORT_ID"
    note "keys written to $ENV_FILE"
else
    note "reusing existing keys from $ENV_FILE"
fi

# 3) Render config.
mkdir -p "$(dirname "$XRAY_CONFIG")"
cat > "$XRAY_CONFIG" <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "port": ${VPN_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${VLESS_UUID}", "flow": "xtls-rprx-vision", "email": "${BUILD_USER}@personal" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${VPN_SNI}:443",
          "xver": 0,
          "serverNames": ["${VPN_SNI}"],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": ["${REALITY_SHORT_ID}"]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block",  "protocol": "blackhole" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" }
    ]
  }
}
JSON
# `nogroup` is xray's runtime group (User=nobody in the systemd unit).
chown root:nogroup "$XRAY_CONFIG"
chmod 640         "$XRAY_CONFIG"

# 4) Validate, restart, verify.
"$XRAY_BIN" -test -confdir /usr/local/etc/xray >/dev/null
systemctl enable --now xray >/dev/null 2>&1 || true
systemctl restart xray
sleep 1

if ! systemctl is-active --quiet xray; then
    echo "ERROR: xray failed to start. Check: journalctl -u xray -n 30 --no-pager" >&2
    exit 1
fi

# 5) Render client URI to /root/xray-vpn-credentials.txt for easy copy.
URI="vless://${VLESS_UUID}@${SERVER_PUBLIC_IP}:${VPN_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${VPN_SNI}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&headerType=none#${HOSTNAME%%.*}-vpn"
cat > /root/xray-vpn-credentials.txt <<TXT
# Xray VLESS+Reality client credentials. mode 600.
SERVER_IP=${SERVER_PUBLIC_IP}
PORT=${VPN_PORT}
SNI=${VPN_SNI}
UUID=${VLESS_UUID}
PUB_KEY=${REALITY_PUBLIC_KEY}
SHORT_ID=${REALITY_SHORT_ID}

CLIENT_URI=${URI}
TXT
chmod 600 /root/xray-vpn-credentials.txt
note "client URI saved to /root/xray-vpn-credentials.txt"
note "xray listening: $(ss -tlnp 2>/dev/null | grep ":${VPN_PORT} " | head -1 | awk '{print $4}')"
