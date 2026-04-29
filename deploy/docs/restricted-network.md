# Restricted-network mode (Iran, air-gapped, behind censorship)

When the pool VPS sits in a network where Docker Hub, Ubuntu archives, or Let's Encrypt are blocked or DPI-interfered with, the default flow (apt-install Docker → pull images → Caddy ACME) breaks. This page documents the workarounds the framework supports and the sequence to bring up such a server.

## What breaks (verified empirically on an Iran VPS, 2026-04-28)

| Default behavior | Failure mode |
|---|---|
| `apt-get update` | `archive.ubuntu.com:80` blocked outbound |
| `apt-get update` over HTTPS | TLS handshake DPI-interfered (`Could not handshake: Error in the pull function`) |
| `docker pull <image>` | `auth.docker.io` DNS censored; some Cloudflare-fronted endpoints block |
| `docker pull` from server | Outbound SNI to Docker Hub gets DPI-reset mid-blob |
| Caddy auto-HTTPS via Let's Encrypt | LE endpoints are Cloudflare-anycast → SNI-blocked |
| `git clone github.com/...` | DPI-blocks Git over HTTPS sometimes; reliable on raw IPs only |

What does work (also verified):

- HTTPS to non-Cloudflare hosts on 443 is generally reachable.
- Inbound traffic to the VPS (port 80/443) is fine; only outbound is censored.
- SSH from the operator's laptop into the VPS works (laptop is in-country too); long-running SSH sessions can drop, so use `ControlMaster` and tolerate retries.

## Strategy: laptop is the bridge

Operator's laptop has working internet (e.g. via a v2ray proxy). Server stays purely on the in-country network. The operator's laptop downloads everything and ships it to the server.

```
[laptop, with global access]                   [VPS in Iran]
─────────────────────────────                   ───────────────
download Docker static binaries  ──scp──>      install
pull Docker images (via crane)   ──scp──>      docker load
build per-MVP image              ──scp──>      docker load
                                                docker compose up
```

## Tooling

The framework ships a [`download/`](../../download/) folder with three things:

1. **`refresh.sh`** — laptop-side script that pulls the offline bundle:
   - Downloads Docker static binaries (`docker-<version>.tgz`) and the Compose plugin from `download.docker.com` and `github.com/docker/compose/releases` (both reachable via laptop's working network).
   - Pulls runtime images (`caddy`, `nginx`, `postgres`, `redis`) using `crane` instead of Docker Desktop, since Docker Desktop's proxy integration tends to fail under restricted networks.
2. **`install-bundle.sh`** — server-side installer that:
   - Extracts the Docker static tarball into `/usr/local/bin/`
   - Installs the Compose plugin under `/usr/local/lib/docker/cli-plugins/`
   - Generates minimal `docker.service` / `containerd.service` / `docker.socket` systemd units (the static tarball ships none)
   - Creates a 2 GB swapfile if RAM < 4 GB
   - Sets up `/srv/{infra,apps}` and the `mvpool` symlink
   - **Patches `infra/Caddyfile` and `infra/compose.yaml`** to remove the `registry.${POOL_DOMAIN}` block and the `registry:2` service — there's no self-hosted registry on a restricted-network VPS, so we use **tarball-mode deploys** for everything.
3. **`download/tools/crane`** — a single Go binary for pulling images without Docker daemon. Works through the laptop's transparent proxy more reliably than `docker pull`.

## TLS strategy: Cloudflare Flexible (recommended for prototypes)

Let's Encrypt is unreachable from inside the restricted network, so Caddy can't run ACME. Instead:

- The pool's domain is **proxied by Cloudflare in orange-cloud mode**.
- Cloudflare presents a real public TLS cert at the edge (browsers see HTTPS).
- Cloudflare → origin is plain HTTP (Cloudflare's "Flexible SSL" mode).
- Origin Caddy serves the per-MVP site as `http://<slug>.${POOL_DOMAIN}`, no cert needed.

For end-to-end encryption (browser ↔ CF ↔ origin), use **Cloudflare Origin CA cert** instead — generated in Cloudflare dashboard, valid for 15 years, drop on the server, point Caddy at it. Slightly more setup; recommended for production. See [operations.md → Cloudflare](operations.md#cloudflare-orange-cloud).

### Per-MVP Caddy site override for Flexible mode

By default `mvp:add` writes a site file like:

```
demo-faraward.pagio.ir {
    ...
}
```

Caddy treats that as wanting auto-HTTPS, which fails behind a censored network. After `mvp:add`, prefix the host with `http://`:

```
http://demo-faraward.pagio.ir {
    ...
}
```

That tells Caddy to serve HTTP only on port 80. Cloudflare in front does the public-facing TLS termination.

## SSH considerations

- The pool's SSH login may resolve through the laptop's local proxy (e.g. Shadowrocket fakedns IPs in `198.18.0.0/15`). Long sessions get killed mid-stream. **Connect via the server's real IP** (e.g. `Host pagio` alias in `~/.ssh/config` pointing at the bare IP) and add SSH `ControlMaster` to multiplex commands over a single TCP session:
  ```
  Host pagio
      HostName 94.182.93.28
      User root
      ServerAliveInterval 15
      ServerAliveCountMax 8
      ControlMaster auto
      ControlPath ~/.ssh/cm-%r@%h:%p
      ControlPersist 10m
  ```
- For long-running operations on the server (apt install, install-bundle, etc.) prefer `setsid nohup ... > /var/log/foo.log 2>&1 &` and poll the log over short SSH commands. SSH session drops then don't kill the work.
- For file transfer, **rsync's `--partial`** is necessary; long single-stream transfers get cut. If a single rsync drop loses progress repeatedly, fall back to per-file `scp` with a retry loop and a size check after each attempt.

## End-to-end bring-up sequence (restricted network)

```bash
# 0. (laptop) refresh the offline bundle
cd ~/repo/mvp/mvp-pool/download
./refresh.sh

# 1. (laptop) rsync the framework + bundle to the server
rsync -avh --partial \
    --exclude='.git' --exclude='.DS_Store' --exclude='*.crdownload' \
    --exclude='download/tools/' \
    ~/repo/mvp/mvp-pool/  pagio:/opt/mvp-pool/

# 2. (server) install Docker, swap, /srv layout, mvpool symlink, Iran patches
ssh pagio 'bash /opt/mvp-pool/download/install-bundle.sh'

# 3. (server) generate /srv/infra/{compose.yaml symlink, Caddyfile symlink, .env}
ssh pagio 'mvpool infra:install'

# 4. (server) edit /srv/infra/.env to set POOL_DOMAIN + ACME_EMAIL
ssh pagio 'sed -i "s|^POOL_DOMAIN=.*|POOL_DOMAIN=<your-domain>|; s|^ACME_EMAIL=.*|ACME_EMAIL=<your-email>|" /srv/infra/.env'

# 5. (server) start the infra (Caddy + Postgres + Redis; no registry)
ssh pagio 'mvpool infra:up'

# 6. (laptop or server) register the MVP
mvpool-local mvp:add <slug> --type static [--no-db --no-redis]

# 7. (server) patch the generated site file for Cloudflare Flexible (HTTP-only origin)
ssh pagio "sed -i 's|^<slug>.<pool>|http://<slug>.<pool>|' /srv/infra/sites/<slug>.caddy && mvpool infra:reload-caddy"

# 8. (operator dashboard) turn on orange cloud + Flexible SSL on the slug's hostname

# 9. (laptop) build & ship the MVP image via tarball mode
mvpool-local deploy <slug> --mode tarball --from /path/to/repo --static-root prototype

# 10. verify
curl -I https://<slug>.<your-domain>
```

## What's lost vs the unrestricted-network flow

- No self-hosted registry → tarball mode for every deploy. Layer dedup is gone; expect full image transfers each time.
- No `mvpool self-update` via `git pull` on the server (it can't reach GitHub). Updates = re-rsync from operator's laptop.
- Caddy auto-HTTPS unavailable → relying on Cloudflare for public TLS.
- Bundle must be refreshed on the laptop and re-rsynced when image versions change.

## When the network situation improves

If outbound network restrictions ease in the future (or the VPS is migrated to a less-restricted host), the same VPS can be flipped back to the default flow:

1. Restore the registry block in `/opt/mvp-pool/deploy/infra/compose.yaml` and `/opt/mvp-pool/deploy/infra/Caddyfile` from the `.bak` files.
2. Add the `registry:2` image to the bundle (or pull it directly).
3. Run `mvpool infra:up` to start the registry container.
4. Re-add Caddy auto-HTTPS by removing `http://` prefixes from per-MVP site files.
5. From laptop: `mvpool-local login` and switch from `--mode tarball` to default registry deploys.
