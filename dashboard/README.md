# mvpool-dashboard

Read-only deploy dashboard for the mvp-pool framework. Reads `mvpool-local`'s
append-only deploy log and renders a single page showing what's currently
live, recent activity, and per-slug history with copy-paste rollback /
redeploy commands.

## What it shows

- **Currently live** — most recent successful deploy per (slug, env), grouped by base name
- **Recent activity** — last 20 deploy events across all slugs (pending/delivering/live/failed)
- **Per-slug drawer** (click any row) — last 20 events for that slug, each with two buttons that pop open a modal with the literal `mvpool-local rollback` / `mvpool-local deploy --tag …` command for you to copy and run on your laptop

The dashboard does **not** execute remote actions — Hetzner can't reach the Iran VPS, so the laptop is the only machine that can act. v1 surfaces ready-to-run commands; v1.5 may add a laptop-side polling agent for one-click execution.

## Where it runs

Designed to run on the **build host** (Hetzner CX23 in this deployment), reading
`/srv/build/.deploys/deployments.jsonl` (written by `mvpool-local` after each
deploy). It binds to `127.0.0.1:3030` by default — expose via SSH tunnel or
front with Caddy basic_auth.

## Run locally (dev)

```bash
bun install
MVPOOL_DEPLOYS_JSONL=./fixtures/sample-log.jsonl bun --watch server.ts
open http://localhost:3030
```

## Install on the build host

The `tools-server` bootstrap (`deploy/tools-server/bootstrap.sh`) installs
Bun, rsyncs **this folder** (repo-root `dashboard/`) to
`/srv/build/dashboard/`, runs `bun install`, and registers the systemd
unit `mvpool-dashboard.service`. After bootstrap:

```bash
ssh hetzner "systemctl status mvpool-dashboard"
ssh -fNL 8080:localhost:3030 hetzner    # one-time per session
open http://localhost:8080
```

To re-deploy after editing dashboard code, re-run the bootstrap module:

```bash
ssh hetzner "sudo bash /srv/tools-server/modules/05-dashboard.sh"
```

## Env vars

| var | default | purpose |
|---|---|---|
| `PORT` | `3030` | listen port |
| `HOST` | `127.0.0.1` | bind address (loopback only by default) |
| `MVPOOL_DEPLOYS_JSONL` | `/srv/build/.deploys/deployments.jsonl` | deploy log to read |

## Log format

Each line in `deployments.jsonl` is one JSON object:

```jsonc
{
  "ts": "2026-05-08T14:22:11Z",
  "slug": "demo-faraward",
  "env": "prod",                  // derived from slug prefix
  "base": "demo-faraward",        // slug minus env prefix
  "tag": "a1b2c3d",
  "status": "live",               // pending | delivering | live | failed
  "actor": "ali@laptop",
  "mode": "tarball",
  "build_host": "hetzner",
  "target_host": "pagio"
}
```

Records are appended by `mvpool-local`'s `deploy_record()` helper at three
transitions per deploy: `pending` → `delivering` → `live`. A trap rewrites
the last status to `failed` if the deploy exits non-zero before reaching
`live`.

## API

| route | returns |
|---|---|
| `GET /api/slugs` | currently-live snapshot, one row per (slug, env) |
| `GET /api/deploys?limit=N` | recent deploys, newest first (default 50, max 500) |
| `GET /api/slugs/:slug/history?limit=N` | per-slug history (default 20, max 200) |
| `GET /api/meta` | log path, mtime, size, server time |
| `GET /healthz` | `ok` |
