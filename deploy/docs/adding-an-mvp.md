# Adding an MVP

End-to-end, from "I have a project" to "it's live at `<slug>.${POOL_DOMAIN}`".

> **DNS note for the `pagio.ir` pool:** the zone runs on **ArvanCloud free tier**. The free tier doesn't allow proxied wildcards, so each slug needs its own A record at the ArvanCloud panel with the cloud (proxy) icon ON to get edge TLS. `mvpool-local` automates this: when `MVPOOL_ARVANCLOUD_API_TOKEN` is set in `~/.config/mvpool/config`, `mvp:add` and every `deploy` will idempotently create the record via the ArvanCloud CDN 4.0 API. Without that token, you'll need to add the record by hand at <https://panel.arvancloud.ir/cdn/pagio.ir/dns>. See `deploy/docs/restricted-network.md` → ArvanCloud section for the full rationale.

## 0. Recommended project layout (the "site/ + scripts" convention)

Every project that lives in this pool should colocate its deploy wrappers next to whatever it deploys. The pattern is:

```
your-project/
├── <subproject>/                 ← one folder per deployable thing
│   ├── site/                     ← static content (for --type static)
│   │   ├── *.html
│   │   └── assets/
│   ├── deploy.sh                 ← thin wrapper around `mvpool-local deploy`
│   ├── register.sh               ← one-time `mvpool-local mvp:add` wrapper
│   └── README.md                 ← deploy notes specific to this subproject
└── <other-subproject>/           ← parallel structure if there's more than one
    └── ...
```

Why **`site/` instead of putting HTML at the subproject root**:
- `mvpool-local deploy --static-root <subproject>/site` only copies `site/` into the image. **`deploy.sh` and `register.sh` stay at the subproject root**, so they're never accidentally served at `https://<host>/deploy.sh` (which would leak ops scripts to visitors).
- Same shape works whether your subproject has one HTML file or fifty — no ad-hoc decisions about what's content vs tooling.
- `git mv` later is easy: a new subproject is just `cp -R <existing> <new>` and edit the slug.

For non-static templates (`node-server`, `react-node-monorepo`, `full-stack-queue`), the subproject is your usual repo (a `Dockerfile`, `package.json`, etc.) and `deploy.sh` lives at its root — same `cd $PROJECT_ROOT && mvpool-local deploy ...` pattern, but `--from .` and no `--static-root`.

### Real example: `gamification-faraward`

Two parallel subprojects in one repo, sharing infrastructure (the gamification design prototype + a coming-soon landing for the same brand):

```
gamification-faraward/
├── prototype/                    # design prototype → demo-faraward.pagio.ir
│   ├── site/
│   │   ├── *.html
│   │   └── assets/
│   ├── deploy.sh                 # ./prototype/deploy.sh
│   ├── register.sh
│   └── README.md
└── startup/                      # coming-soon landing → farawand.ir
    ├── site/
    │   └── index.html
    ├── deploy.sh                 # ./startup/deploy.sh
    └── register.sh
```

### Sample wrapper scripts

`<subproject>/deploy.sh`:

```bash
#!/usr/bin/env bash
# Build and ship this subproject. Default --mode tarball is appropriate
# for restricted-network pools (e.g. Iran-hosted); override with --mode
# registry on a non-restricted pool.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$PROJECT_ROOT"
exec mvpool-local deploy <slug> \
    --from . \
    --type static \
    --static-root <subproject>/site \
    --mode tarball \
    "$@"
```

`<subproject>/register.sh`:

```bash
#!/usr/bin/env bash
# One-time: register this subproject on the pool server.
set -euo pipefail
exec mvpool-local mvp:add <slug> --type static --domain <hostname-or-omit> "$@"
```

(Replace `<slug>`, `<subproject>`, and `<hostname-or-omit>` with the actual values for each subproject. Make both scripts executable: `chmod +x deploy.sh register.sh`.)

## 1. Pick a template type

| Your project shape                                 | `--type`                |
| -------------------------------------------------- | ----------------------- |
| Pure static (HTML/CSS/JS folder, no build)         | `static`                |
| Single Node binary (Next.js standalone, Hono…)     | `node-server`           |
| Monorepo with `api` + `web` (+ optional worker)    | `react-node-monorepo`   |
| Full HMS-shape: api + worker + web + db + redis    | `full-stack-queue`      |

Each template has its own README in [templates/](../templates/) with a one-page "what you bring".

## 2. Register the MVP on the server

```bash
# from the server (or via `mvpool-local mvp:add ...` from your laptop)
mvpool mvp:add <slug> --type <type> [--domain custom.example.com]
```

What this does:

- Creates `/srv/apps/<slug>/{compose.yaml,.env,.meta}` from the chosen template.
- (For non-static) Creates a Postgres role + database with a generated password, picks the next free Redis DB index (0–15), writes both into `.env`.
- Writes a Caddy site snippet at `/srv/infra/sites/<slug>.caddy` binding the domain to the MVP's containers.
- Defaults the domain to `<slug>.${POOL_DOMAIN}` (override with `--domain`).
- Whatever ends up as `DOMAIN` in `/srv/apps/<slug>/.meta` is what `mvpool-local deploy` writes into the deployment record's `url` field — i.e., what the dashboard links to and what `mvpool-local verify` curls. So if your slug is hosted on a different zone (e.g. `lab.prototype.mizro.ir` while the pool is `pagio.ir`), pass `--domain lab.prototype.mizro.ir` and the dashboard / verify will point there automatically. Don't synthesize URLs in your wrapper scripts — the framework already knows.

The MVP isn't running yet — the `IMAGE_TAG` in `.env` is the placeholder `bootstrap`, and no images exist for that tag. Move on to step 3.

## 3. Build + push from your laptop

```bash
# one-time on your laptop
echo "MVPOOL_HOST=user@pool-vps.example.com" > ~/.config/mvpool/config
ln -sf $(pwd)/deploy/bin/mvpool-local ~/.local/bin/mvpool

# log in to the registry once (uses the password printed by bootstrap.sh)
mvpool login

# deploy
mvpool deploy <slug> --from /path/to/your/project [--mode registry|tarball]
```

Per template type, `mvpool-local deploy` does this:

### `--type static`

```bash
mvpool deploy gamification \
  --from /path/to/repo \
  --static-root prototype/site
```

- Materialises a temp build context with the framework's `Dockerfile` + the chosen nginx config + your `<subproject>/site/` folder.
- Builds `<registry>/<slug>-web:<sha>`, pushes (or `docker save | ssh load` in tarball mode).
- Server pulls and starts.

> Static content lives in `<subproject>/site/` (not `<subproject>/` directly) so `deploy.sh` / `register.sh` at the subproject root don't get baked into the served image. See [layout convention](#0-recommended-project-layout-the-site--scripts-convention).

#### Cache behavior — `--cache-mode no-cache` (default) vs `immutable`

The `static` template ships two nginx configs and picks one at build time:

| `--cache-mode` | What it does | When to use |
|---|---|---|
| `no-cache` (**default**) | `Cache-Control: no-store, no-cache, must-revalidate` on **all** responses — HTML, CSS, JS, images, everything. | Raw HTML/CSS/JS folders without a build step. **The right default for `static`** because filenames don't carry content hashes, so any cached asset becomes stale on the next deploy. Without this, visitors see "I edited the CSS but it still looks the same" for up to 7 days after every deploy. |
| `immutable` | 7-day immutable cache for assets (`*.js`, `*.css`, fonts, images), no-cache for HTML. | When your `site/` *does* contain hash-versioned filenames (e.g. you pre-built a Vite/webpack bundle and committed `site/assets/index-a1b2c3.js`). Filenames change per deploy, so long-cached old files are simply unreferenced — fastest possible repeat-visit performance. |

Override at deploy time:

```bash
mvpool-local deploy <slug> --from . --type static --static-root site \
    --cache-mode immutable                                 # opt-in to long cache
```

The chosen mode is recorded in `/version.txt` (`cache_mode=...`) and as the `mvpool.cache_mode` Docker label on the image.

### `--type node-server`

```bash
mvpool deploy <slug> --from /path/to/repo
```

- Looks for `Dockerfile` in your repo (override with `--app-dockerfile`).
- Builds `<registry>/<slug>-app:<sha>`.

### `--type react-node-monorepo`

```bash
mvpool deploy <slug> --from /path/to/repo
```

- Builds three (or two) images from `Dockerfile.api`, `Dockerfile.web`, and (if present) `Dockerfile.worker`.
- Override any Dockerfile path with `--api-dockerfile`, `--web-dockerfile`, `--worker-dockerfile`.

### `--type full-stack-queue`

Same as `react-node-monorepo` but `Dockerfile.worker` is required.

## 4. What happens on the server

After `mvpool-local deploy` ships the image(s), it triggers `mvpool deploy <slug> --tag <tag>` over SSH, which:

1. Updates `IMAGE_TAG=<tag>` in `/srv/apps/<slug>/.env`.
2. `docker compose pull` (registry mode) — no-op for tarball mode since images are already loaded.
3. `docker compose up -d --remove-orphans`.
4. Reloads Caddy.
5. Updates `CURRENT_TAG=<tag>` in `/srv/apps/<slug>/.meta`.
6. Appends to `/srv/infra/state/deployments.jsonl`.

## 5. Verify

```bash
mvpool-local status                  # see infra + MVPs + last 10 deploys
mvpool-local logs <slug> [service]
curl -I https://<slug>.${POOL_DOMAIN}
```

Caddy issues a Let's Encrypt cert on first hit; allow ~10 seconds for the very first request.

## DNS prerequisites

Point a wildcard `*.${POOL_DOMAIN}` A/AAAA record at the pool VPS (or one record per MVP — wildcard is easier). Caddy needs port 80/443 reachable for ACME HTTP-01 / TLS-ALPN-01.

If you put Cloudflare in front (orange cloud), see [operations.md → Cloudflare](operations.md#cloudflare-orange-cloud) — Caddy can use Cloudflare Origin CA certs instead of public Let's Encrypt.
