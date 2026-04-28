name: mvp-{{SLUG}}

# React + Node monorepo MVP. Two services (api + web), optional worker.
# Both images are built per-service by `mvpool-local deploy` from your repo's
# Dockerfiles and pushed to the pool registry.

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

  web:
    image: ${REGISTRY}/{{SLUG}}-web:${IMAGE_TAG}
    restart: unless-stopped
    env_file: .env
    networks:
      - edge
    depends_on:
      - api

  # Uncomment if your monorepo has a worker. Comment back out (and remove the
  # image from the registry) if you drop it.
  # worker:
  #   image: ${REGISTRY}/{{SLUG}}-worker:${IMAGE_TAG}
  #   restart: unless-stopped
  #   env_file: .env
  #   networks:
  #     - data

networks:
  edge:
    external: true
    name: mvpool_edge
  data:
    external: true
    name: mvpool_data
