# `full-stack-queue` template

For MVPs with the same shape as `hotel-message-system`: an API, a background-job worker (BullMQ / Sidekiq / etc.), and a web SPA, all sharing one database and one Redis.

## What the framework provides

- A compose file pulling three per-service images: `<slug>-api`, `<slug>-worker`, `<slug>-web`.
- Caddy routes `/api/*` and `/health` to `api:${API_PORT}`; everything else to `web:80`.
- Shared Postgres database/role and a dedicated Redis DB index for queue isolation.

## What you bring (in your MVP repo)

- `Dockerfile.api`, `Dockerfile.worker`, `Dockerfile.web` (or pass `--api-dockerfile` / `--worker-dockerfile` / `--web-dockerfile` to override).
- A migration entry point — by default `mvpool deploy` runs the `api` image with `node packages/db/dist/migrate.js` (or `tsx packages/db/src/migrate.ts` if `--migrate-cmd` overrides). Tweak in `/srv/apps/<slug>/.meta` if your migration command differs.
- A `/health` endpoint on the API.

## Deploy

```bash
mvpool-local deploy <slug> --from /path/to/your/repo
```
