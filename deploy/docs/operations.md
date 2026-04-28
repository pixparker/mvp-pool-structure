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

## Health checks

`mvpool status` is the single-screen overview:

- Infra services + their health (Caddy, Postgres, Redis, Registry).
- All registered MVPs, their type, domain, and current image tag.
- Last 10 deploys (from `state/deployments.jsonl`).
- Disk usage on `/srv`.

Run periodically (manual or via cron + alerting). Each per-MVP compose has its own healthcheck for the web/api containers — failures show up in `docker compose ps`.
