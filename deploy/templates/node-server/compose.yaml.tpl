name: mvp-{{SLUG}}

# Single-process node MVP (e.g. Next.js standalone, Hono server, Express).
# The image must listen on $PORT (default 4000) and connect to shared
# Postgres at hostname `postgres` / Redis at `redis` if needed.

services:
  app:
    image: ${REGISTRY}/{{SLUG}}-app:${IMAGE_TAG}
    restart: unless-stopped
    env_file: .env
    networks:
      - edge
      - data
    # node:alpine doesn't ship wget/curl, but Node itself is guaranteed
    # present. Use the built-in http module so the healthcheck works
    # against any node-server image without forcing apk-add in user
    # Dockerfiles. Non-2xx marks the container unhealthy.
    healthcheck:
      test: ["CMD", "node", "-e",
             "require('http').get('http://localhost:'+(process.env.API_PORT||4000)+'/health',r=>process.exit(r.statusCode>=200&&r.statusCode<300?0:1)).on('error',()=>process.exit(1))"]
      interval: 30s
      timeout: 3s
      retries: 3
      start_period: 5s

networks:
  edge:
    external: true
    name: mvpool_edge
  data:
    external: true
    name: mvpool_data
