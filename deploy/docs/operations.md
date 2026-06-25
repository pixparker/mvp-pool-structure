# Operations

Runbooks for the day-2 stuff: backups, restores, rollback, framework upgrades, Cloudflare, disaster recovery.

## Framework upgrades (`mvpool self-update`)

The framework lives at `/opt/mvp-pool` on the server (a `git clone` of this repo). To pick up upstream changes:

```bash
mvpool-local self-update
# = ssh user@pool-vps "cd /opt/mvp-pool && git pull && mvpool infra:install && mvpool infra:up"
```

This re-applies any changes to `infra/compose.yaml`, `infra/Caddyfile`, and the templates. It's a no-op if nothing material changed. Pin to a release tag for predictable upgrades:

```bash
ssh user@pool-vps "cd /opt/mvp-pool && git fetch --tags && git checkout deploy-v0.2"
mvpool-local infra:up
```

## Backups (Postgres)

Per-MVP, on demand:

```bash
mvpool-local db:backup <slug>
# writes /srv/apps/<slug>/backups/<dbname>-<timestamp>.sql.gz
```

Restore:

```bash
mvpool-local db:restore <slug> /srv/apps/<slug>/backups/<file>.sql.gz
```

Cron a nightly backup (run on the server):

```cron
# /etc/cron.d/mvpool-backups (root)
15 3 * * *  yourdeploy   /usr/local/bin/mvpool db:backup <slug>
```

For multiple MVPs, a wrapper that loops over `mvpool list` is easy to add later.

### Off-site copies

The framework doesn't ship an off-site backup driver yet. Two approaches:

- `rsync` `/srv/apps/*/backups/` to S3/B2 in cron.
- Mount a remote storage volume (Hetzner Storage Box, etc.) under `/srv/infra/backups-remote/` and point cron there.

## Rollback

```bash
mvpool-local rollback <slug> <prior-tag>
```

Both registry-mode and tarball-mode rollbacks work the same way: set IMAGE_TAG, `compose pull` (no-op in tarball), `compose up -d`. The prior tag must exist (in the registry, or in the local Docker daemon for tarball deploys).

If the rollback target is a schema-incompatible version, restore the matching DB backup first:

```bash
mvpool-local db:restore <slug> /srv/apps/<slug>/backups/<pre-bad-deploy>.sql.gz
mvpool-local rollback <slug> <pre-bad-deploy-tag>
```

## Cloudflare (orange cloud)

Two supported modes:

### DNS-only (grey cloud) — default

Cloudflare just hosts your DNS; traffic goes laptop → DNS resolver → VPS. Caddy issues real Let's Encrypt certs via HTTP-01. This is what `bootstrap.sh` + the default Caddyfile assume. Nothing to configure.

### Proxied (orange cloud)

If you turn on the orange cloud, Cloudflare terminates TLS and the public-facing cert is Cloudflare's edge cert. Caddy still needs *some* cert to talk to Cloudflare on the origin side. Two options:

- **Full (strict) with Origin CA cert**: generate a 15-year origin cert in the Cloudflare dashboard, drop it at `/srv/infra/origin-tls/{cert.pem,key.pem}`, and tell Caddy to use it instead of ACME for that site:
  ```caddy
  example.com {
      tls /etc/caddy/origin-tls/cert.pem /etc/caddy/origin-tls/key.pem
      ...
  }
  ```
- **DNS-01 ACME** (still real Let's Encrypt): use Caddy's Cloudflare DNS plugin and provide a CF API token. Heavier setup; usually unnecessary.

Recommended baseline: keep the registry endpoint (`registry.${POOL_DOMAIN}`) on **DNS-only** (grey) — Cloudflare proxies have request-size limits that conflict with `docker push`. Per-MVP sites can be either.

## Disaster recovery

If the VPS is gone but you have backups + the pool repo:

1. Provision a new VPS, point DNS at it.
2. `git clone` this repo to `/opt/mvp-pool`, run `bootstrap.sh`.
3. `mvpool infra:install`, edit `/srv/infra/.env`, `mvpool infra:up`.
4. For each MVP: `mvpool mvp:add <slug> --type <same-as-before> --domain <same-as-before>`.
5. `mvpool db:restore <slug> <backup-file>` for each.
6. `mvpool-local deploy <slug> --from <repo>` to push fresh images.

## Removing an MVP

```bash
mvpool-local mvp:remove <slug> --yes
```

This:

1. Stops the stack.
2. Removes the Caddy site file and reloads Caddy.
3. (If the MVP has a DB) backs up the database to `/srv/infra/backups/<dbname>-removed-<ts>.sql.gz`.
4. Drops the database + role.
5. Removes `/srv/apps/<slug>/`.

Images are NOT removed from the registry; that's manual:

```bash
ssh user@pool-vps "docker images | grep <slug>"
# delete by tag in the registry's storage volume, then run garbage-collect
```

## Disk cleanup (`mvpool-local cleanup`)

Build hosts (Hetzner et al.) and pool VPSes accumulate disk over time:
old image tags from previous deploys, stale buildx cache layers, interrupted
ship tarballs in `/tmp`, failed-build `ingest/` dirs. Left alone, a 38 GB
build host will hit "no space left on device" mid-build every couple of
weeks of active deployment (see Mizro's lessons-learned §11 + §22).

The framework ships a unified cleanup command — single source of truth, no
per-project scripts to maintain:

```bash
# Both hosts, dry-run first to see what would be deleted (no changes):
mvpool-local cleanup --dry-run

# Apply (default: --keep-days 7, both hosts):
mvpool-local cleanup

# Only the build host, more aggressive (keep 3 days):
mvpool-local cleanup build --keep-days 3

# Only the pool host:
mvpool-local cleanup pool
```

### What it touches

**Build host (Hetzner-side, via `MVPOOL_BUILD_HOST`):**
- `/srv/build/.ship/*.tar.zst` older than `--keep-days N` → deleted
- `/srv/build/*/.buildx-cache/ingest/*` dirs older than 60 minutes → deleted (these are remnants of failed cache exports; never useful)
- `docker buildx prune --filter until=Nh` → reclaims buildkit's own cache
- `docker image prune -a --filter until=Nh` → reclaims dangling + old tagged images

**Pool host (`MVPOOL_HOST`):**
- `docker image prune -a --filter until=Nh` → reclaims old image tags (auto-respects images referenced by running containers, so the live deploy is never touched)
- `/tmp/*-*.tar.zst` older than 1 day → deletes interrupted-ship leftovers
- `docker volume prune -f` → deletes only unreferenced volumes (no live data lost)

### Safety guarantees

- **Idempotent.** Re-running has no extra effect.
- **Active containers protected.** Docker prune's behaviour: images referenced by ANY container (running or stopped) are never deleted. The N-day filter additionally skips anything recent.
- **Rollback window preserved.** `--keep-days 7` keeps the last week's image tags; `mvpool rollback <slug> <tag>` continues to work for any tag within that window.
- **Dry-run first when in doubt.** `--dry-run` lists candidates without touching anything.

### Cadence

Recommended cadence: **weekly**, before the deploy backlog starts to bite. Two options:

**Manual:** Run from your laptop as part of Monday-morning housekeeping.

**Cron (host-side):** drop a snippet onto either host. Example for the pool host's `/etc/cron.weekly/mvpool-cleanup`:

```bash
#!/bin/sh
# Weekly mvpool cleanup — keep last 7 days of images.
docker image prune -af --filter "until=168h" >/var/log/mvpool-cleanup.log 2>&1
docker volume prune -f >>/var/log/mvpool-cleanup.log 2>&1
find /tmp -maxdepth 1 -name '*-*.tar.zst' -mtime +1 -delete
```

Mirror to the build host. The CLI `mvpool-local cleanup` is the human-driven version; cron is the unattended version (mirrors the same operations).

### When NOT to run cleanup

- **Mid-deploy.** A deploy in flight has a freshly-loaded image not yet attached to a container. Wait until `mvpool status` shows the new tag as active.
- **Right before a rollback investigation.** If you've lost trust in the current deploy and might roll back to a 7+ day-old tag, raise `--keep-days` before cleanup or skip cleanup until you've decided.

## Batched deploys (`--load-only` + `cutover`)

Most slugs deploy independently, but when you ship several at once (e.g.
a daily multi-app release), letting each deploy go fully end-to-end means
the user-facing surfaces are in a mixed-version state during the run:
api on tag N, web-panel still on N-1, etc. for ~10-30 min while builds
and ships chain through.

The framework supports a two-phase pattern that keeps the cutover window
tight (~5s × number of slugs) by separating ship-the-image from
swap-the-container:

**Phase A — build, ship, load (per slug, but never recreate):**
```bash
mvpool-local deploy <slug> --from <path> --type <T> --tag <TAG> --load-only [other flags]
```
Same as a normal `deploy`, except the final `mvpool deploy` (which writes
`IMAGE_TAG` to `/srv/apps/<slug>/.env` + recreates the containers) is
skipped. The new image is `docker load`-ed onto the pool but no container
is using it yet. Production is unaffected.

Run this once per slug in your batch. Any failure here is non-destructive:
the previously-deployed containers keep running on their old tags.

**Phase B — atomic cutover (once every slug in the batch has loaded):**
```bash
mvpool-local cutover <slug> --tag <TAG>
```
Single short SSH call. Updates `IMAGE_TAG` + `docker compose up -d`
(which recreates any container whose image reference changed). ~5s
per slug; usable in tight succession to swap many slugs in ~25-30s
total.

### When NOT to use this pattern

- Single-slug deploys — the normal `mvpool-local deploy` is simpler.
- When phase-A might fail mid-batch but you want partial progress —
  you'd rather use the normal per-slug deploy so each commit cuts over
  as soon as it's ready.
- When the new image requires a corresponding migration that must run
  BEFORE the cutover. Run migrations explicitly between A and B (the
  api's `migrate` container, or your project's equivalent).

### Example: digital-menu's `deploy-prod-quick.sh`

Mizro's daily prod-deploy wrapper uses this pattern. See
`digital-menu/deploy/deploy-prod-quick.sh` for a reference orchestrator
that:

1. SSH-discovers each slug's currently-deployed tag
2. Diffs HEAD against each tag → builds a "what changed" plan
3. Confirms with the operator
4. Runs phase A serially across changed apps (build serializes on the
   single buildkit instance anyway, so parallel doesn't help)
5. Runs phase B in api → web order to keep downstream apps happy
6. Verifies all surfaces respond healthy

## Health checks

`mvpool status` is the single-screen overview:

- Infra services + their health (Caddy, Postgres, Redis, Registry).
- All registered MVPs, their type, domain, and current image tag.
- Last 10 deploys (from `state/deployments.jsonl`).
- Disk usage on `/srv`.

Run periodically (manual or via cron + alerting). Each per-MVP compose has its own healthcheck for the web/api containers — failures show up in `docker compose ps`.

## Suspecting a silent-success bug?

When a deploy claims ✅ but the served app didn't change, OR when smoke passes but customers report stale behaviour, you're in silent-success territory. Read [silent-success-patterns.md](silent-success-patterns.md) — twenty defensive rules from real incidents, each with the anti-pattern and the fix. Apply Rule 4 (version-baked smoke) first; it catches the most cases.
