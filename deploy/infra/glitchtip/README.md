# GlitchTip — self-hosted client error observability (MVP-E28-F17)

One shared GlitchTip instance for the whole pool. Sentry-protocol-compatible, so
apps use the standard `@sentry/*` SDK pointed at our DSN. Runs on our infra
(Iran-friendly), reuses the pool's shared Postgres + Redis, fronted by the shared
Caddy at `errors.mizro.ir`.

> **Scaffolded by Dev 1; deploy is operator-run** (needs VPS + DNS + secrets).
> Once it's up and you've created a project, hand the **DSN** back so the app-side
> SDK wiring (web-panel / web-ops / web-publish) can be pointed at it.

## 1. Prerequisites

- Shared infra up **with the data profile** (Postgres + Redis):
  `docker compose -f deploy/infra/compose.yaml --profile data up -d`
- DNS: an `A`/`AAAA` record for `errors.mizro.ir` → the pool VPS (Caddy gets TLS
  automatically once the record resolves).

## 2. Create the database + role

Connect to the shared Postgres as admin and create a dedicated DB + role:

```sql
CREATE ROLE glitchtip LOGIN PASSWORD '<strong-password>';
CREATE DATABASE glitchtip OWNER glitchtip;
```

(e.g. `docker compose -f deploy/infra/compose.yaml exec postgres psql -U "$POSTGRES_ADMIN_USER" -d postgres`)

## 3. Configure env

```sh
cd deploy/infra/glitchtip
cp .env.example .env && chmod 600 .env
```

Fill in `.env`:
- `DATABASE_URL` — the role/password/db from §2.
- `SECRET_KEY` — `openssl rand -hex 50`.
- `GLITCHTIP_IMAGE_TAG` — a current stable tag (check the GlitchTip releases page;
  do not use `latest`).
- Leave `REDIS_URL` on db index `3` unless it's already taken by another app.

## 4. Bring it up

```sh
docker compose --env-file .env up -d
docker compose logs -f glitchtip-migrate   # confirm migrations ran clean, then it exits 0
```

`glitchtip-web` + `glitchtip-worker` start once migrate completes. Check health:
`docker compose exec glitchtip-web wget -qO- http://localhost:8080/_health/`

## 5. Install the Caddy site

```sh
cp errors.caddy <pool>/infra/sites/errors.caddy
docker compose -f deploy/infra/compose.yaml exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Visit `https://errors.mizro.ir` — you should get the GlitchTip login page over TLS.

## 6. Create the founder account + project, get the DSN

Open registration is **disabled**, so create the first (superuser) account from the CLI:

```sh
docker compose --env-file .env exec glitchtip-web ./manage.py createsuperuser
```

Then in the dashboard:
1. Create an **Organization** (e.g. `mizro`).
2. Create a **Project per app** — `web-panel`, `web-ops`, `web-publish` (platform: `JavaScript`).
3. Copy each project's **DSN** (Settings → Client Keys). That's what the SDK needs.

Hand the three DSNs back for the app wiring (`NEXT_PUBLIC_GLITCHTIP_DSN` per app).

**Dashboard hardening (optional):** GlitchTip login already gates the dashboard.
For an extra layer, add an IP allowlist in `errors.caddy` scoped to the dashboard
paths only — never to `/api/<project>/store/`, `/api/<project>/envelope/`, or
`/api/<project>/security/`, which the browser SDKs need open.

## 7. Operations

- **Retention:** `GLITCHTIP_MAX_EVENT_LIFE_DAYS` (default 90) — the worker's beat
  schedule purges older events. No manual cleanup needed.
- **Upgrade:** bump `GLITCHTIP_IMAGE_TAG` in `.env` → `docker compose --env-file .env up -d`
  (migrate re-runs automatically).
- **Logs:** `docker compose logs -f glitchtip-web glitchtip-worker`.
- **Backups:** the `glitchtip` Postgres DB is included in the shared-Postgres
  backup; nothing GlitchTip-specific to back up beyond that.

## 8. Notes

- Ingest CORS: GlitchTip's ingest endpoints accept cross-origin browser POSTs by
  design (DSN public-key auth). If a future app origin is rejected, set
  `ADDITIONAL_CORS_ORIGINS` in `.env` and recreate.
- Entrypoints (`./manage.py migrate`, `./bin/run-celery-with-beat.sh`) match
  current GlitchTip images; verify against the pinned tag's docs if a future bump
  changes them.
- See the app-side design + privacy policy: `digital-menu/docs/architecture/27-client-observability.md`.
