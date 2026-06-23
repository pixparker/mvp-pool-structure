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
   (The project slugs match the per-app `SENTRY_PROJECT` default in each
   `next.config.ts`, so source-map upload lands in the right project.)
3. Copy each project's **DSN** (Settings → Client Keys). That's what the SDK needs.

Hand the three DSNs back for the app wiring (`NEXT_PUBLIC_GLITCHTIP_DSN` per app).

> Note: `web-publish` (the published menu) is wired **server/edge-only** — no
> browser DSN is used there (hard initial-JS/LCP budget). Its project still
> receives server-side render/data errors. Only `web-panel` + `web-ops` send
> browser events.

### 6a. Disable IP storage per project — REQUIRED before founder G3 (CTO review)

The client SDK runs `sendDefaultPii: false` and our scrubber drops `user.ip_address`,
but GlitchTip still derives the **connecting IP** from the ingest request and would
store it unless told not to. For **each** project:

> Settings → **General Settings** → turn **“Store IP Addresses” OFF** → Save.

(Org owners can also set this as an org default.) Verify by triggering a test error
and confirming the event detail shows **no IP** under the user/context panel. If
this is left on, raw diner/merchant IPs reach the dashboard regardless of the
client-side config — see §9.

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
  design (DSN public-key auth). We restrict that to first-party origins at the
  **edge** — `errors.caddy` 403s any request whose `Origin` isn't `*.mizro.ir`
  (server-side events have no `Origin` and pass). So no `ADDITIONAL_CORS_ORIGINS`
  tuning is needed; to add a new first-party app, no change is required (it's
  already under `*.mizro.ir`). A non-mizro origin is rejected by design.
- Entrypoints (`./manage.py migrate`, `./bin/run-celery-with-beat.sh`) match
  current GlitchTip images; verify against the pinned tag's docs if a future bump
  changes them.
- See the app-side design + privacy policy: `digital-menu/docs/architecture/28-client-observability.md`.

## 9. Privacy gates — verify before founder G3 (CTO review)

Two infra checks beyond the app-side redaction list (`@mizro/observability`):

1. **IP not stored** — §6a done for every project. Confirm a test event shows no IP.
2. **CORS allowlist live** — after installing `errors.caddy`, confirm a foreign
   origin is rejected and a first-party one is accepted:

   ```sh
   # Foreign origin → 403
   curl -s -o /dev/null -w '%{http_code}\n' -H 'Origin: https://evil.example' \
     https://errors.mizro.ir/api/1/envelope/
   # First-party origin → NOT 403 (reaches GlitchTip; 400/401 from the app is fine)
   curl -s -o /dev/null -w '%{http_code}\n' -H 'Origin: https://panel.mizro.ir' \
     https://errors.mizro.ir/api/1/envelope/
   ```

The founder G3 deliberate-error check then confirms the dashboard payload contains
**zero** of: a real phone, a magic-link token, a phantom-user label, an IP.
