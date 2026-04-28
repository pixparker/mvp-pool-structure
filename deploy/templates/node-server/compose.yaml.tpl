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
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:${API_PORT:-4000}/health"]
      interval: 30s
      timeout: 3s
      retries: 3

networks:
  edge:
    external: true
    name: mvpool_edge
  data:
    external: true
    name: mvpool_data
