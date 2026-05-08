#!/usr/bin/env bash
# 06-demo-deploy — build the hello-static sample and run it as a local
# container on this build host so the dashboard has real data + you have a
# deployed page to browse via SSH tunnel. Idempotent.
#
# This is a *local* demo, not a real deploy to a pool VPS. For that flow,
# from your laptop:
#   mvpool-local mvp:add hello-static --type static --no-db --no-redis
#   mvpool-local deploy hello-static --from <repo>/deploy/sample-projects/hello-static \
#       --static-root prototype --mode tarball

set -euo pipefail
note() { printf '   %s\n' "$*"; }

FRAMEWORK="$(cd "$TOOLS_SERVER_ROOT/.." && pwd)"
SAMPLE_SRC="$FRAMEWORK/sample-projects/hello-static"
TEMPLATE="$FRAMEWORK/templates/static"
DEMO_PORT="${DEMO_PORT:-8081}"
SLUG="hello-static"
TAG="demo-$(date -u +%Y%m%d-%H%M%S)"
IMAGE="mvpool-demo/${SLUG}:${TAG}"
CONTAINER="mvpool-demo-${SLUG}"

[[ -d "$SAMPLE_SRC/prototype" ]] || { echo "missing $SAMPLE_SRC/prototype" >&2; exit 1; }
[[ -f "$TEMPLATE/Dockerfile"  ]] || { echo "missing $TEMPLATE/Dockerfile"  >&2; exit 1; }

# Assemble the same build context shape that mvpool-local would, in a temp
# dir. mktemp -d as root produces a 0700 dir that BUILD_USER's `docker buildx`
# can't read, so we hand the dir over to BUILD_USER right after creation.
CTX="$(mktemp -d -t mvpool-demo.XXXXXX)"
trap "rm -rf '$CTX'" EXIT

cp "$TEMPLATE/Dockerfile"             "$CTX/Dockerfile"
cp "$TEMPLATE/nginx-no-cache.conf"    "$CTX/nginx-no-cache.conf"
cp "$TEMPLATE/nginx-immutable.conf"   "$CTX/nginx-immutable.conf"
cp -R "$SAMPLE_SRC/prototype/"        "$CTX/content"
chown -R "$BUILD_USER":"$BUILD_USER" "$CTX"
chmod 755 "$CTX"

note "building $IMAGE via mvpool-builder"
sudo -u "$BUILD_USER" docker buildx build \
    --builder mvpool-builder --platform linux/amd64 --load \
    --build-arg STATIC_ROOT=content \
    --build-arg IMAGE_TAG="$TAG" \
    --build-arg BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --build-arg CACHE_MODE=no-cache \
    -t "$IMAGE" "$CTX" >/dev/null
note "build ok: $IMAGE"

# (Re)start the demo container.
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    note "stopping previous demo container"
    docker rm -f "$CONTAINER" >/dev/null
fi
docker run -d --name "$CONTAINER" \
    --restart unless-stopped \
    -p "127.0.0.1:${DEMO_PORT}:80" \
    "$IMAGE" >/dev/null
note "demo running at 127.0.0.1:${DEMO_PORT}"

# Smoke-test it
sleep 0.5
if curl -fsS --max-time 4 "http://127.0.0.1:${DEMO_PORT}/version.txt" | grep -q "tag=$TAG"; then
    note "smoke test ok (/version.txt has tag=$TAG)"
else
    echo "WARN: demo container started but /version.txt didn't return expected tag" >&2
fi

# Append a real deploy record so the dashboard shows it as live.
HOST_SHORT="$(hostname -s 2>/dev/null || hostname)"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RECORD=$(printf '{"ts":"%s","slug":"%s","env":"prod","base":"%s","tag":"%s","status":"live","actor":"bootstrap@%s","mode":"demo","build_host":"%s","target_host":"localhost:%s"}' \
    "$TS" "$SLUG" "$SLUG" "$TAG" "$HOST_SHORT" "$HOST_SHORT" "$DEMO_PORT")

sudo -u "$BUILD_USER" mkdir -p /srv/build/.deploys
sudo -u "$BUILD_USER" tee -a /srv/build/.deploys/deployments.jsonl >/dev/null <<<"$RECORD"
note "deploy record written; dashboard will pick it up on next refresh"

cat <<MSG

  =========================================================================
   demo deploy live: $SLUG @ $TAG
  -------------------------------------------------------------------------
   browse the deployed page:
       ssh -fNL ${DEMO_PORT}:localhost:${DEMO_PORT} ${HOST_SHORT}
       open http://localhost:${DEMO_PORT}

   open the dashboard (separate tunnel):
       ssh -fNL 8080:localhost:${DASHBOARD_PORT} ${HOST_SHORT}
       open http://localhost:8080

   tear down the demo when you're done:
       docker rm -f ${CONTAINER}
  =========================================================================

MSG
