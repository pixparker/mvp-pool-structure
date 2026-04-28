# Appended to the per-MVP .env when the chosen template includes an API service.
# Generic API/web/worker stacks (node-server, react-node-monorepo, full-stack-queue)
# expect these to be present.

API_PUBLIC_URL=https://{{DOMAIN}}
WEB_ORIGIN=https://{{DOMAIN}}
API_PORT=4000

# Connects to shared Postgres/Redis via the `mvpool_data` Docker network.
DATABASE_URL=postgres://{{DB_USER}}:{{DB_PASSWORD}}@postgres:5432/{{DB_NAME}}
REDIS_URL=redis://redis:6379/{{REDIS_DB_INDEX}}

# Auth — generate fresh per deploy target
JWT_ACCESS_SECRET={{JWT_ACCESS_SECRET}}
JWT_REFRESH_SECRET={{JWT_REFRESH_SECRET}}
JWT_ACCESS_TTL=900
JWT_REFRESH_TTL=2592000
SECRETS_ENCRYPTION_KEY={{SECRETS_ENCRYPTION_KEY}}
