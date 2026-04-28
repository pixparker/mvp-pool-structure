# `node-server` template

For MVPs that ship a single Node.js HTTP service: Next.js (standalone build), a Hono/Express API, etc.

## What the framework provides

- A compose file that pulls one image (`<slug>-app`) from the pool registry and joins the shared `mvpool_edge` and `mvpool_data` networks.
- The shared Caddy fronts the MVP at `<slug>.${POOL_DOMAIN}` and routes everything to `app:${API_PORT}` (default 4000).

## What you bring (in your MVP repo)

- A `Dockerfile` that produces an image listening on `$API_PORT` (or hardcoded 4000).
- The image's `/health` endpoint should return 200 OK; that's what the compose healthcheck pings.

## Deploy

```bash
mvpool-local deploy <slug> --from /path/to/your/repo
```

`mvpool-local` runs `docker buildx build` against your repo's Dockerfile, tags it `${REGISTRY}/<slug>-app:<sha>`, pushes (or `docker save | ssh "docker load"` in tarball mode), then SSHes to the server to run `mvpool deploy <slug> --tag <sha>`.
