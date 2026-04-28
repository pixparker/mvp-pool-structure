name: mvp-{{SLUG}}

# Full-stack queue MVP — api + web + worker, all backed by shared Postgres and Redis.
# Mirrors the hotel-message-system shape. Pick this when you have a
# background-job worker and want the same isolation HMS uses.

services:
  api:
    image: ${REGISTRY}/{{SLUG}}-api:${IMAGE_TAG}
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

  worker:
    image: ${REGISTRY}/{{SLUG}}-worker:${IMAGE_TAG}
    restart: unless-stopped
    env_file: .env
    networks:
      - data
    depends_on:
      - api

  web:
    image: ${REGISTRY}/{{SLUG}}-web:${IMAGE_TAG}
    restart: unless-stopped
    env_file: .env
    networks:
      - edge
    depends_on:
      - api

networks:
  edge:
    external: true
    name: mvpool_edge
  data:
    external: true
    name: mvpool_data
