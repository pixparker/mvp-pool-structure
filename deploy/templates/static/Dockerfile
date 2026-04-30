# Generic static-site image. The MVP source dir is mounted as the build
# context by `mvpool-local deploy`; STATIC_ROOT picks the subfolder to serve.
#
#   mvpool-local deploy <slug> --from . --static-root prototype/site
#
# CACHE_MODE picks the response-caching profile:
#   no-cache   (default) — disable cache everywhere. The right default for the
#                          `static` template because raw HTML/CSS/JS without a
#                          build step has no filename-hash cache-busting; long
#                          caching would force stale assets after every deploy.
#   immutable            — long cache (7d, public, immutable) for asset-shaped
#                          paths. Opt in via --cache-mode immutable when your
#                          static folder *does* contain hash-versioned filenames
#                          (e.g. you pre-built a Vite bundle).
#
# COPY pattern uses a build arg so the same Dockerfile works for any layout.

FROM nginx:1.27-alpine

ARG STATIC_ROOT=.
ARG IMAGE_TAG=unversioned
ARG BUILD_TIME=
ARG CACHE_MODE=no-cache

COPY ${STATIC_ROOT}/ /usr/share/nginx/html/
COPY nginx-${CACHE_MODE}.conf /etc/nginx/conf.d/default.conf

# Bake build metadata into the image so visitors can confirm what's deployed
# (curl https://<host>/version.txt) and `docker inspect` can show it via labels.
RUN printf 'tag=%s\nbuild_time=%s\ncache_mode=%s\n' "$IMAGE_TAG" "$BUILD_TIME" "$CACHE_MODE" \
        > /usr/share/nginx/html/version.txt

LABEL org.opencontainers.image.version="${IMAGE_TAG}" \
      org.opencontainers.image.created="${BUILD_TIME}" \
      mvpool.cache_mode="${CACHE_MODE}"
