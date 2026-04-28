# Adding an MVP

End-to-end, from "I have a project" to "it's live at `<slug>.${POOL_DOMAIN}`".

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
  --static-root prototype/
```

- Materialises a temp build context with the framework's `Dockerfile` + `nginx.conf` + your `prototype/` folder.
- Builds `<registry>/<slug>-web:<sha>`, pushes (or `docker save | ssh load`).
- Server pulls and starts.

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
