# Generic static-site image. The MVP source dir is mounted as the build
# context by `mvpool-local deploy`; STATIC_ROOT picks the subfolder to serve.
#
#   mvpool-local deploy <slug> --from . --static-root prototype/
#
# COPY pattern uses a build arg so the same Dockerfile works for any layout.

FROM nginx:1.27-alpine
ARG STATIC_ROOT=.
COPY ${STATIC_ROOT}/ /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/conf.d/default.conf
