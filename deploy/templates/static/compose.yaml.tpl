name: mvp-{{SLUG}}

# Static-site MVP stack. One nginx-alpine container serving prebuilt files.
# Image is built by `mvpool-local deploy` and pushed to ${REGISTRY} (or loaded
# from a tarball in air-gapped mode); `docker compose up` here just starts it.

services:
  web:
    image: ${REGISTRY}/{{SLUG}}-web:${IMAGE_TAG}
    restart: unless-stopped
    networks:
      - edge
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost/"]
      interval: 30s
      timeout: 3s
      retries: 3

networks:
  edge:
    external: true
    name: mvpool_edge
