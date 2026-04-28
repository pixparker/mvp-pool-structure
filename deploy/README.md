# mvpool — MVP Pool deployment framework

A thin Docker-Compose-based framework for hosting several MVPs on one Linux VPS. One VPS, N MVPs, isolated per project. Each MVP gets its own database role, Redis DB index, domain, env file, and compose stack — all behind a shared Caddy that handles TLS.

## What's shared vs dedicated

| Shared (one per server)        | Dedicated (one per MVP)                |
| ------------------------------ | -------------------------------------- |
| Caddy + TLS                    | App containers                         |
| PostgreSQL server              | Postgres **database + role**           |
| Redis server                   | Redis **DB index**                     |
| Self-hosted Docker registry    | Domain, env file, meta                 |
| Docker networks (`mvpool_*`)   | Per-MVP `compose.yaml`                 |

## Layout (on the server)

```
/srv/
├── infra/                           # shared per-server
│   ├── compose.yaml -> /opt/mvp-pool/deploy/infra/compose.yaml   (symlink)
│   ├── Caddyfile    -> /opt/mvp-pool/deploy/infra/Caddyfile      (symlink)
│   ├── registry-auth -> /opt/mvp-pool/deploy/infra/registry-auth (symlink)
│   ├── .env                          # admin creds, ACME_EMAIL, POOL_DOMAIN
│   ├── sites/<slug>.caddy            # one per MVP (auto-generated)
│   ├── state/deployments.jsonl       # append-only deploy log
│   └── backups/
└── apps/
    └── <slug>/
        ├── compose.yaml              # rendered from a template at mvp:add
        ├── .env                      # mode 600; IMAGE_TAG rewritten on each deploy
        ├── .meta                     # type, domain, db, redis, current_tag
        └── backups/                  # per-MVP pg_dump archives
```

Shared Docker networks: `mvpool_edge` (Caddy ↔ MVP web/api) and `mvpool_data` (Postgres/Redis ↔ MVP api/worker).

## First-time server setup

```bash
# 1. (one time, as root) clone this repo to /opt/mvp-pool
git clone <this-repo-url> /opt/mvp-pool

# 2. bootstrap the OS (Docker, UFW, swap, registry htpasswd, /usr/local/bin/mvpool)
sudo bash /opt/mvp-pool/deploy/bootstrap.sh
# ^ prints the registry password ONCE — copy it down.

# 3. (as your non-root user) wire /srv/infra and bring up shared infra
mvpool infra:install
$EDITOR /srv/infra/.env       # set ACME_EMAIL and POOL_DOMAIN
mvpool infra:up
```

DNS: point `*.${POOL_DOMAIN}` (a wildcard A/AAAA record) at the VPS so Caddy can issue certs for each MVP automatically. Cloudflare works in DNS-only ("grey cloud") mode. If you want orange-cloud / Cloudflare in front, see [docs/operations.md](docs/operations.md#cloudflare-orange-cloud).

## Adding an MVP

```bash
# server-side (or mvpool-local from your laptop)
mvpool mvp:add gamification --type static
#  ↳ creates /srv/apps/gamification/{compose.yaml, .env, .meta}
#  ↳ creates /srv/infra/sites/gamification.caddy → gamification.${POOL_DOMAIN}

# laptop-side
mvpool-local deploy gamification \
  --from /Users/pixparker/repo/mvp/gamification-faraward \
  --static-root prototype/
```

That's it. The CLI:

1. picks the right compose template for the type,
2. generates per-MVP `.env` + Caddy site snippet,
3. (laptop) builds images, pushes to `registry.${POOL_DOMAIN}`,
4. (server) `docker compose pull && up -d`, reload Caddy, log the deploy.

See [docs/adding-an-mvp.md](docs/adding-an-mvp.md) for the full flow per template type.

## Day-2 ops

| Need                             | Command                                     |
| -------------------------------- | ------------------------------------------- |
| live logs                        | `mvpool logs <slug> [service]`              |
| restart a service                | `mvpool restart <slug> [service]`           |
| DB shell                         | `mvpool db:psql <slug>`                     |
| manual backup                    | `mvpool db:backup <slug>`                   |
| restore dump                     | `mvpool db:restore <slug> <path>`           |
| roll back to a prior tag         | `mvpool rollback <slug> <tag>`              |
| list MVPs + current tags         | `mvpool mvp:list`                           |
| infra + last 10 deploys + disk   | `mvpool status`                             |
| pull framework updates           | `mvpool self-update`                        |

All work over SSH via `mvpool-local <subcommand>` from your laptop.

See [docs/operations.md](docs/operations.md) for backups, rollback semantics, Cloudflare modes, and disaster recovery.

## Deploy flows

Two paths supported:

- **Registry mode (default).** Operator builds locally, pushes to the self-hosted registry on the pool VPS, server pulls and starts. Efficient layered transfers; clean rollback by tag.
- **Tarball mode** (`--mode tarball`). `docker save | ssh "docker load"` — works when the server has no outbound network for the registry, or when `docker pull` is blocked.

Both flows produce the same end state (images present locally on the server with matching tags), so the same `compose.yaml` works for either. See [docs/deploy-flows.md](docs/deploy-flows.md) for details and tradeoffs.

## Templates (MVP shapes)

Pick one at `mvp:add` time with `--type`:

| Type                    | Use when…                                             | Provides            |
| ----------------------- | ----------------------------------------------------- | ------------------- |
| `static`                | pure HTML/CSS/JS prototype, design wireframe          | nginx + your files  |
| `node-server`           | Next.js standalone, Hono/Express single-binary        | one app container   |
| `react-node-monorepo`   | most common: api + web (+ optional worker)            | api + web (+ worker)|
| `full-stack-queue`      | api + worker + web with Postgres + Redis (HMS-shape)  | api + worker + web  |

Each template directory has its own README with a short "what you bring" list. See [templates/](templates/).

## Security notes

- All per-MVP `.env` and `.meta` files are mode 600.
- Postgres and Redis listen only on `127.0.0.1` plus the private Docker network.
- Registry listens only on `127.0.0.1`; Caddy fronts it with TLS + basic_auth.
- Caddy terminates TLS and sets HSTS by default.
- UFW: 22, 80, 443 inbound only.
- All secrets generated with `openssl rand` at `mvp:add`/bootstrap time, never committed.

## Extracting an MVP to dedicated infrastructure

When an MVP graduates out of the pool:

```bash
# on current pool server
mvpool db:backup <slug>
rsync -a /srv/apps/<slug>/ newhost:/srv/apps/<slug>/

# on new host, after running its own bootstrap.sh
mvpool infra:install && $EDITOR /srv/infra/.env && mvpool infra:up
mvpool db:restore <slug> /srv/apps/<slug>/backups/<latest>.sql.gz
mvpool deploy <slug> --tag <prior-tag>
```
