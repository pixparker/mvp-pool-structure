# mvp-pool

Multi-purpose repo. Today it contains one thing: the **MVP-pool deployment framework** under [`deploy/`](deploy/).

A single Linux VPS hosts N small projects ("MVPs"). Each gets its own database role, Redis DB index, domain, env file, and compose stack — all behind a shared Caddy that handles TLS. Operators interact with it through the `mvpool` CLI.

The framework supports two deploy flows:

- **registry mode (default)** — build images on the operator's machine, push to a self-hosted registry on the pool VPS, then `docker compose pull && up` on the server. Efficient layered transfers, clean rollback by tag.
- **tarball mode (fallback)** — `docker save | ssh "docker load"`. Works when the server has no outbound network for the registry, or no git access to the MVP source.

Future folders alongside `deploy/` may host other shared work (ops scripts, infra-as-code experiments) without disturbing the pool framework lifecycle.

## Quickstart

See [deploy/README.md](deploy/README.md). One-page TL;DR: provision a Linux VPS, point `*.<your-pool-domain>` at it, `git clone` this repo to `/opt/mvp-pool`, run `deploy/bootstrap.sh`, edit `deploy/infra/.env`, `mvpool infra:up`. Then `mvpool mvp:add <slug> --type <static|node-server|react-node-monorepo|full-stack-queue>` and `mvpool-local deploy <slug> --from <path>`.
