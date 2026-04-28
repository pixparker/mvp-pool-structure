# `react-node-monorepo` template

Most common MVP shape: a monorepo with at least an `api` (Node) and a `web` (React/Vite/Next-static) app, optionally a `worker`.

## What the framework provides

- A compose file pulling 2 (or 3) per-service images from the pool registry: `<slug>-api`, `<slug>-web`, optionally `<slug>-worker`.
- Caddy routes `/api/*` and `/health` to `api:${API_PORT}`; everything else to `web:80`.
- The shared Postgres database/role and Redis DB index are auto-provisioned at `mvp:add`; their URLs are written to the per-MVP `.env`.

## What you bring (in your MVP repo)

- `Dockerfile.api` — builds an image that listens on `$API_PORT` (default 4000) and connects to `postgres:5432` / `redis:6379`.
- `Dockerfile.web` — builds an image that serves the SPA on port 80 (typically nginx-alpine + your built `dist/`).
- (Optional) `Dockerfile.worker` — builds the worker image; uncomment the `worker` service in your generated `/srv/apps/<slug>/compose.yaml` if you have one.

`mvpool-local deploy <slug> --from /path/to/repo` builds all three from the standard filenames; override with `--api-dockerfile`, `--web-dockerfile`, `--worker-dockerfile` if your repo uses different names.

## Deploy

```bash
mvpool-local deploy <slug> --from /path/to/your/repo
```
