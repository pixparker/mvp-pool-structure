# react-app — sample React MVP for performance testing the pipeline

A real Vite + React + TypeScript app, deployed via the build-on-Hetzner
pipeline as a `node-server`-typed MVP. Use it to measure end-to-end
deploy times for projects with a real npm install + bundle step
(harder than the trivial `static-html` demo).

## Stack

- **Vite + React 18 + TypeScript** for the bundle
- **Hono on Node 22** for the runtime server (~5 KB framework, serves
  the dist folder + exposes `/health`, `/api/version`, `/api/echo`)
- **Multi-stage Dockerfile** (deps → build → server-deps → runtime)
- **No Tailwind / no UI lib** — just one stylesheet, keeps build fast and
  obvious

## Layout

```
react-app/
├── README.md                ← you are here
├── package.json             ← deps + scripts
├── tsconfig.{json,app,node}.json
├── vite.config.ts
├── index.html               ← Vite entry
├── src/
│   ├── main.tsx
│   ├── App.tsx              ← shows tag, build time, page perf, /api/echo round-trip
│   └── index.css
├── server/
│   └── index.ts             ← Hono server: serves dist/, /health, /api/*
├── Dockerfile               ← multi-stage; runs the whole build chain on Hetzner
├── .dockerignore
├── .gitignore
├── deploy-core.sh           ← shared deploy logic (parameterised by SLUG)
├── deploy-prod.sh           ← thin wrapper, SLUG=react-app
└── deploy-lab.sh            ← thin wrapper, SLUG=lab-react-app
```

## First deploy

```bash
# 1) Make sure dependencies install locally so package-lock.json exists.
#    (Hetzner uses `npm ci` against this lockfile for deterministic builds.)
cd ~/repo/mvp/mvp-pool/demo/react-app
npm install

# 2) Deploy to prod (commit first if you want a clean git-sha tag).
bash deploy-prod.sh

# Or fire-and-forget — terminal returns in <1s, watch via dashboard.
bash deploy-prod.sh --bg

# 3) Open the deployed site
open https://react-app.pagio.ir
```

## What to expect on the wire

Numbers below are rough — your runs will differ depending on Iran ↔ DE
peering quality at the time. They're the order-of-magnitude estimates
to compare against.

| Step | First run | Warm (buildx cache hit) |
|---|---|---|
| Source rsync laptop → Hetzner | <2 s (~50 KB diff) | <1 s |
| `npm ci` on Hetzner (deps stage) | 30–60 s | cached in 0 s |
| `vite build` on Hetzner | 5–10 s | usually re-runs (source changed) |
| `npm ci --omit=dev` (server-deps) | 15–30 s | cached |
| Final image build + commit | 2–5 s | 2–5 s |
| `docker save | zstd` on Hetzner | 3–5 s | 3–5 s |
| Tarball Hetzner → laptop | depends on your VPN; usually 30 s–2 min for ~80 MB | same |
| Tarball laptop → pagio | 1–3 min over Iran ISP | same |
| `docker load` on pagio | 5–10 s | same |
| `compose up -d` + Caddy reload | ~5 s | ~5 s |
| **Total cold** | **~3–7 min** | |
| **Total warm (no source change)** | | **~2–4 min** |

The dominant costs are the **two rsyncs through the laptop** — that's the
Iran-side network bottleneck, not the build itself. Build on Hetzner is
fast.

## Reading the deploy

While running, watch in the dashboard:

```bash
bash ../static-html/dashboard.sh
```

Three rows will appear in "recent activity" for the deploy: `pending →
delivering → live`. The "currently live" row updates with the new tag
when the last step lands.

After completion, hit the URL:

- `https://react-app.pagio.ir/` — page renders, shows tag + build time
  + uptime + page TTFB / loaded times
- `/api/version` — JSON with the same metadata
- `/api/echo` — server-side roundtrip, click the button on the page to
  measure end-to-end RTT

## Multi-env

```bash
bash deploy-lab.sh           # ships to https://lab-react-app.pagio.ir
```

Lab gets its own slug, its own Caddy site, its own ArvanCloud DNS record,
its own compose stack. Same source, two completely independent
deployments.

## Iterating quickly

The buildx cache layer (`/srv/build/react-app/.buildx-cache/` on Hetzner)
makes iterative deploys fast IF you only change source files (not
dependencies):

- Editing `src/App.tsx` → only the `build` stage re-runs (~10 s)
- Adding a dep in `package.json` → `deps` and `server-deps` stages
  re-run (`npm ci` is the slow step)
- Touching `server/index.ts` → final image rebuild only (~2 s)

To measure a clean build for benchmarking, blow the cache first:

```bash
ssh hetzner "rm -rf /srv/build/react-app/.buildx-cache"
bash deploy-prod.sh
```

## Tearing it down

```bash
mvpool-local mvp:remove react-app --yes
mvpool-local mvp:remove lab-react-app --yes
```

That stops the containers, drops the Caddy site, removes the slug from
`/projects.json`. ArvanCloud DNS records stay (clean those up in the
panel if you care — they're harmless if left).

## Local dev

```bash
npm install
npm run dev
# open http://localhost:5173
```

For the prod-shape sanity check (Vite build + Hono server, no Docker):

```bash
npm run build
npm start          # serves dist/ on localhost:4000
```
