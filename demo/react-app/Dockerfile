# syntax=docker/dockerfile:1.7
#
# Multi-stage build for the react-app demo.
#
# Stage 1 (deps):    install dependencies (cached layer)
# Stage 2 (build):   tsc + vite build of the React bundle
# Stage 3 (server):  install only prod deps for the Hono server
# Stage 4 (runtime): minimal node:22-alpine + dist + server
#
# IMAGE_TAG / BUILD_TIME args come from `mvpool-local --build-on hetzner`
# and end up baked into the runtime env so the React app can render them.

ARG NODE_VERSION=22-alpine

# ---------- deps -----------------------------------------------------------
FROM node:${NODE_VERSION} AS deps
WORKDIR /app
COPY package.json package-lock.json* ./
# `npm ci` if a lockfile exists (deterministic), else fall back to `npm install`
RUN --mount=type=cache,target=/root/.npm \
    if [ -f package-lock.json ]; then npm ci --no-audit --no-fund; \
    else npm install --no-audit --no-fund; fi

# ---------- build ----------------------------------------------------------
FROM node:${NODE_VERSION} AS build
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN npm run build

# ---------- server-deps ----------------------------------------------------
FROM node:${NODE_VERSION} AS server-deps
WORKDIR /app
COPY package.json package-lock.json* ./
RUN --mount=type=cache,target=/root/.npm \
    if [ -f package-lock.json ]; then npm ci --omit=dev --no-audit --no-fund; \
    else npm install --omit=dev --no-audit --no-fund; fi

# ---------- runtime --------------------------------------------------------
FROM node:${NODE_VERSION} AS runtime
WORKDIR /app

ARG IMAGE_TAG=unversioned
ARG BUILD_TIME=
ENV NODE_ENV=production
ENV PORT=4000
ENV DIST_DIR=/app/dist
ENV IMAGE_TAG=${IMAGE_TAG}
ENV BUILD_TIME=${BUILD_TIME}

# Pull in the production node_modules + built bundle + server source.
COPY --from=server-deps /app/node_modules ./node_modules
COPY --from=build       /app/dist          ./dist
COPY server                                ./server

# Drop privileges. node:alpine ships a `node` user already.
USER node

LABEL org.opencontainers.image.version="${IMAGE_TAG}" \
      org.opencontainers.image.created="${BUILD_TIME}" \
      mvpool.template="node-server"

EXPOSE 4000

# tsx gets pulled into devDependencies so it isn't here. Use --experimental-strip-types
# (Node 22+) to run server/index.ts directly without a separate build step.
CMD ["node", "--experimental-strip-types", "server/index.ts"]
