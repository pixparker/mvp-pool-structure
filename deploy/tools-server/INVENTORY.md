# tools-server — inventory of the resulting state

Read this to understand **what the bootstrap leaves on the box** without
running it. If something here doesn't match what's actually on a server
you've bootstrapped, that's a drift you should fix (re-run the relevant
module, or update this doc to match reality).

Last verified: 2026-05-08 against Ubuntu 24.04.4 LTS on Hetzner CX23.

## Packages (apt)

| package | source | why |
|---|---|---|
| `curl`, `ca-certificates`, `gnupg`, `rsync` | Ubuntu archive | base ops |
| `ufw` | Ubuntu archive | host firewall |
| `zstd` | Ubuntu archive | image-tarball compression for `mvpool-local --build-on` |
| `jq` | Ubuntu archive | JSON poking in scripts |
| `docker-ce`, `docker-ce-cli`, `containerd.io` | docker.com apt repo | container runtime |
| `docker-buildx-plugin` | docker.com apt repo | builds for `--build-on` |
| `docker-compose-plugin` | docker.com apt repo | per-MVP compose stacks |

## Users / groups

| user | groups | shell | purpose |
|---|---|---|---|
| `${BUILD_USER}` (default `ali`) | `sudo`, `docker` | `/bin/bash` | runs the dashboard, owns `/srv/build`, used by `mvpool-local` over SSH |

The bootstrap **does not** create `${BUILD_USER}` if one already exists;
it just adjusts group membership. SSH keys are out of scope (handled by
`ssh-copy-id` from your laptop).

## Filesystem

```
/etc/
├── cron.weekly/
│   └── mvpool-build-prune              ← weekly buildx + image prune
├── sysctl.d/
│   └── 99-mvpool-tools-server.conf     ← BBR + buffer tuning
└── systemd/system/
    └── mvpool-dashboard.service        ← Bun + Hono UI

/root/
├── .tools-server.env                   ← MODE 600. Reality keys, UUID,
│                                          shortId. Back this up.
└── xray-vpn-credentials.txt            ← MODE 600. Pre-rendered client URI.

/srv/
└── build/                              ← MODE 0755, owned by ${BUILD_USER}
    ├── .deploys/
    │   └── deployments.jsonl           ← append-only deploy log
    ├── .ship/                          ← scratch dir for image tarballs
    ├── .gitignore                      ← belt-and-braces
    ├── dashboard/                      ← code + node_modules (rsync target)
    └── <slug>/                         ← created by mvpool-local on first deploy
        ├── source/                     ← rsync target
        ├── .buildx-cache/              ← persistent buildkit cache
        └── img-…tar.zst                ← built image awaiting ship

/usr/local/
├── bin/xray                            ← Xray binary (XTLS official installer)
├── etc/xray/config.json                ← MODE 640 root:nogroup. VLESS+Reality.
└── share/xray/                         ← geoip + geosite data
```

## Ports

| port | listen | purpose |
|---|---|---|
| `22/tcp` | `0.0.0.0` | ssh (UFW allow) |
| `80/tcp` | only if other Caddy/nginx is bound | http (UFW allow) |
| `443/tcp` + `443/udp` | only if Caddy is bound | https + http3 (UFW allow) |
| `${VPN_PORT}/tcp` (default `2053`) | `0.0.0.0` | xray VLESS+Reality (UFW allow) |
| `${DASHBOARD_PORT}/tcp` (default `3030`) | `127.0.0.1` only | dashboard (no UFW exposure; access via SSH tunnel) |

Anything else listening (e.g. a clientora-style Caddy/Postgres stack on
the same host) is **untouched** by this bootstrap. The build user just
needs the docker socket and `/srv/build`.

## Systemd services managed by this bootstrap

| service | binary | runs as | listens |
|---|---|---|---|
| `xray.service` | `/usr/local/bin/xray` | `nobody` | `0.0.0.0:${VPN_PORT}` |
| `mvpool-dashboard.service` | `${BUILD_USER}/.bun/bin/bun run server.ts` | `${BUILD_USER}` | `127.0.0.1:${DASHBOARD_PORT}` |

Existing services (Docker, ssh, the host's Caddy if any) are unmanaged by
this bootstrap.

## Sysctl

```
net.core.default_qdisc        = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max             = 16777216
net.core.wmem_max             = 16777216
net.ipv4.tcp_fastopen         = 3
```

Raises throughput on long-haul TCP (DE↔IR), helps both the VPN and
image-tarball transfers.

## Swap

`/swapfile` of `${SWAP_SIZE_GB}G` (default 2 GB), enabled in `/etc/fstab`.
Defensive against webpack/Vite OOM during builds.

## Buildx

- Builder name: `mvpool-builder`
- Driver: `docker-container` (default)
- Cache: per-slug at `/srv/build/<slug>/.buildx-cache/`, zstd-compressed
- Owner: `${BUILD_USER}` (lives in `~/.docker/buildx/`)

## Secrets

Everything secret lives in **one** file: `/root/.tools-server.env`, mode 600.

```
REALITY_PRIVATE_KEY=…
REALITY_PUBLIC_KEY=…
VLESS_UUID=…
REALITY_SHORT_ID=…
```

The bootstrap reads these on every run and only generates new ones if a
key is missing. To rotate: delete the relevant lines and re-run module
`04`. To migrate without rotating clients: copy this file verbatim to
the new VPS before running bootstrap there.

## What is NOT in this inventory (out of scope)

These belong to other layers and are **not** managed here:

- Per-MVP application stacks (`/srv/apps/<slug>/`) — these are pool-VPS
  concerns, on a different host.
- Caddy/Postgres/Redis if you're running a clientora-style application
  layer on the same host — that's a separate compose stack with its own
  source of truth (its own README + compose.yaml).
- DNS records — manage at the registrar / ArvanCloud panel.
- Cloud-provider firewall (Hetzner Cloud Firewall etc.) — manage in the
  provider's panel.
- Backups of `/srv/apps/<slug>/...` data — `mvpool db:backup` / restore.
