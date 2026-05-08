# tools-server — reproducible provisioning for the mvp-pool tools server

This folder is the **single source of truth** for the configuration of the
machine that hosts:

1. The Xray VLESS+Reality VPN (port 2053)
2. The Docker build host for `mvpool-local deploy --build-on …`
3. The mvpool-dashboard (read-only deploy UI on `127.0.0.1:3030`)

Everything is implemented as **idempotent bash modules** orchestrated by
[`bootstrap.sh`](bootstrap.sh). Re-running on a healthy server is safe:
each module checks current state and only applies the diff. There is no
external state store — secrets persist in `/root/.tools-server.env` (mode
600) and that file is the only thing you need to back up to migrate
without rotating client URIs.

> **Why bash, not Ansible/Nix/Terraform?**
> Personal-scale, one-operator, runs on any Linux box, no learning curve,
> no extra control plane. The whole thing is ~400 lines of bash you can
> read top-to-bottom and understand. Reach for Ansible/Nix when this
> grows past 5–6 modules or 2+ servers.

## Files

```
tools-server/
├── README.md           ← this file
├── INVENTORY.md        ← declarative description of the resulting state
├── bootstrap.sh        ← orchestrator
└── modules/
    ├── 01-base.sh         apt baseline, time sync, UFW, build user
    ├── 02-docker.sh       Docker Engine + buildx + compose plugin
    ├── 03-build-host.sh   /srv/build, swap, sysctl, buildx instance, prune cron
    ├── 04-vpn-xray.sh     Xray VLESS+Reality VPN (Reality keys persisted)
    └── 05-dashboard.sh    Bun + dashboard files + systemd unit
```

Module ordering is meaningful (`01` → `05`) but each can be invoked alone
to re-apply just one concern.

## Usage

### First-time provision (fresh Ubuntu 24.04+ box)

```bash
# 1) From your laptop, push the framework checkout to the server.
rsync -a --partial --delete \
    --exclude=.git --exclude=node_modules --exclude=.DS_Store \
    ~/repo/mvp/mvp-pool/  hetzner:/srv/tools-server-source/

# 2) Run bootstrap as root.
ssh -t hetzner "sudo bash /srv/tools-server-source/deploy/tools-server/bootstrap.sh"

# 3) Done. Bootstrap prints the next steps it took, plus where the
#    client URI for the VPN landed (/root/xray-vpn-credentials.txt).
```

### Re-apply just one module

```bash
ssh -t hetzner "sudo bash /srv/tools-server-source/deploy/tools-server/bootstrap.sh 05"
# only 05-dashboard runs — useful after editing dashboard code
```

### Skip a module on re-run

```bash
ssh -t hetzner "sudo SKIP=04 bash /srv/tools-server-source/deploy/tools-server/bootstrap.sh"
# everything except VPN
```

### Override defaults

All inputs are env vars; pass them in front of the command:

```bash
sudo VPN_PORT=2083 VPN_SNI=www.microsoft.com DASHBOARD_PORT=4000 \
    bash bootstrap.sh
```

| var | default | effect |
|---|---|---|
| `VPN_PORT` | `2053` | VLESS port |
| `VPN_SNI` | `www.cloudflare.com` | Reality steal-target |
| `DASHBOARD_PORT` | `3030` | dashboard listen port (loopback only) |
| `BUILD_USER` | `ali` | unix user that owns /srv/build, runs the dashboard, is in the docker group |
| `SWAP_SIZE_GB` | `2` | swapfile size if not already present |
| `SERVER_PUBLIC_IP` | auto-detected via `api.ipify.org` | put in client URI |

## Migrating to a new vendor (full reproduction)

The discipline that makes this work: **the bootstrap is the entire setup.
Anything not in a module isn't reproducible — fix that immediately.**

To move from `vendor-A` to `vendor-B`:

```bash
# 1. (vendor-A) Back up the secrets file. This is the ONLY thing that
#    isn't in git: Reality keys, UUID, shortId. Without it, clients need
#    to re-import a new URI after migration.
ssh vendor-A "sudo cat /root/.tools-server.env" > ~/secrets/tools-server.env.bak
chmod 600 ~/secrets/tools-server.env.bak

# 2. Provision a fresh Ubuntu 24.04 VPS at vendor-B. ssh-copy-id your key.

# 3. Push the same git checkout + the secrets file.
rsync -a --partial --delete \
    --exclude=.git ~/repo/mvp/mvp-pool/  vendor-B:/srv/tools-server-source/
scp ~/secrets/tools-server.env.bak vendor-B:/tmp/tools-server.env
ssh vendor-B "sudo install -m 600 /tmp/tools-server.env /root/.tools-server.env && rm /tmp/tools-server.env"

# 4. Run bootstrap on vendor-B. It detects the existing keys and reuses
#    them; it generates fresh keys only if /root/.tools-server.env is empty.
ssh -t vendor-B "sudo bash /srv/tools-server-source/deploy/tools-server/bootstrap.sh"

# 5. Update the IP in the client URI on phones IF you didn't keep the
#    same public IP. (Reality keys + UUID + shortId stayed the same; only
#    the SERVER_IP in the URI changes.) /root/xray-vpn-credentials.txt
#    on vendor-B has the rebuilt URI ready to copy.

# 6. Update DNS records pointing to the old IP. Switch your laptop's
#    ssh config alias to point at vendor-B. Decommission vendor-A.
```

What this **does not migrate** (out of scope on purpose — they belong to
specific apps, not the tools server):

- Per-MVP application data (databases, Redis state, uploaded files).
- DNS records at the registrar / ArvanCloud panel.
- Any cloud-firewall rules at the provider's panel level (Hetzner Cloud
  Firewall, etc.) — UFW on the host *is* covered by `01-base.sh`.

For the per-MVP app data, your existing pool-side tooling (`mvpool db:backup`,
`mvpool db:restore`, app-specific dumps) is the right tool. Tools server
data is **stateless** in this design except for the deploy event log
(`/srv/build/.deploys/deployments.jsonl`), which is recreated on the next
deploy and isn't valuable to migrate.

## Coexistence with other workloads on the same host

The bootstrap is designed to slot in next to existing things on the host
without disturbing them:

- It **does not** install Docker if Docker is already runnable.
- It **does not** create the `BUILD_USER` if it already exists; it only
  ensures the `docker` group membership.
- UFW rules are added (not replaced) — anything you've already opened
  stays open.
- All filesystem state lives under `/srv/build/`, `/usr/local/etc/xray/`,
  `/etc/systemd/system/mvpool-dashboard.service`, `/etc/cron.weekly/mvpool-build-prune`,
  `/etc/sysctl.d/99-mvpool-tools-server.conf`. Anything outside that is
  someone else's, untouched.
- Removing the tools server is `systemctl disable --now xray mvpool-dashboard`,
  delete the four files above, `rm -rf /srv/build`. The host returns to
  whatever else it was running.

## Limits / known sharp edges

- BSD `sed -i` doesn't take a backup arg the same way GNU sed does; the
  bootstrap's `_persist_env_var` helper assumes GNU sed (Linux). It's
  Linux-only by design.
- First-run on a brand-new VPS may reset SSH session if UFW reloads;
  `01-base.sh` allows port 22 *before* enabling UFW so this shouldn't
  bite, but if it does, reconnect and re-run — it's idempotent.
- `04-vpn-xray.sh` always restarts xray (cheap, ~50ms downtime).
- Every module assumes apt-based Linux. RHEL/Alpine support would need
  small changes in `01-base.sh` and `02-docker.sh`.

See `INVENTORY.md` for the declarative description of the resulting state.
