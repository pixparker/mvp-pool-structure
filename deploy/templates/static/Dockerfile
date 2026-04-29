# Generic static-site image. The MVP source dir is mounted as the build
# context by `mvpool-local deploy`; STATIC_ROOT picks the subfolder to serve.
#
#   mvpool-local deploy <slug> --from . --static-root prototype/
#
# COPY pattern uses a build arg so the same Dockerfile works for any layout.

FROM nginx:1.27-alpine

ARG STATIC_ROOT=.
ARG IMAGE_TAG=unversioned
ARG BUILD_TIME=

COPY ${STATIC_ROOT}/ /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Bake build metadata into the image so visitors can confirm what's deployed
# (curl https://<host>/version.txt) and `docker inspect` can show it via labels.
RUN printf 'tag=%s\nbuild_time=%s\n' "$IMAGE_TAG" "$BUILD_TIME" \
        > /usr/share/nginx/html/version.txt

LABEL org.opencontainers.image.version="${IMAGE_TAG}" \
      org.opencontainers.image.created="${BUILD_TIME}"
