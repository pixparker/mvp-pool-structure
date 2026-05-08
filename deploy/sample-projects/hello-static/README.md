# hello-static — sample MVP for practising deploys

A minimal static-site project shaped exactly like the `static` template
expects. Use it to practise the `mvp:add` + `deploy --build-on hetzner`
flow end-to-end without touching a real project.

## Layout

```
hello-static/
├── README.md          ← you are here
└── prototype/         ← the static-root: gets COPYed into nginx:html
    ├── index.html
    ├── style.css
    └── app.js
```

The `prototype/` subdir matches `--static-root prototype` (the convention
the framework uses for HTML/CSS/JS prototypes that aren't pre-built).
After a deploy, the page is served at `https://hello-static.${POOL_DOMAIN}`.
The bottom of the page renders the `IMAGE_TAG` and `BUILD_TIME` baked into
the image — so you can see *exactly* which build is live.

## End-to-end deploy walkthrough

```bash
# 1) one-time per env: register the slug on the pool VPS
mvpool-local mvp:add hello-static --type static --no-db --no-redis

# 2) deploy with build-on-Hetzner (default if MVPOOL_BUILD_HOST is set)
mvpool-local deploy hello-static \
  --from ~/repo/mvp/mvp-pool/deploy/sample-projects/hello-static \
  --static-root prototype \
  --mode tarball

# 3) browse it
open https://hello-static.pagio.ir
# expect to see: "hello from mvp-pool" + the deploy tag and timestamp

# 4) verify via the metadata endpoint
curl -s https://hello-static.pagio.ir/version.txt
# tag=<sha>
# build_time=<iso>
# cache_mode=no-cache

# 5) practise rollback — first deploy a small change to get a new tag
echo '<!-- bump -->' >> prototype/index.html
git add prototype/index.html && git commit -m "bump"
mvpool-local deploy hello-static \
  --from . --static-root prototype --mode tarball
# now /version.txt shows the new tag

# 6) roll back to the previous tag
mvpool-local rollback hello-static <previous-tag>

# 7) practise multi-env — the lab variant gets its own DB role / Redis index
#    / domain prefix. Same source, different slug.
mvpool-local mvp:add lab-hello-static --type static --no-db --no-redis
mvpool-local deploy lab-hello-static \
  --from ~/repo/mvp/mvp-pool/deploy/sample-projects/hello-static \
  --static-root prototype --mode tarball
open https://lab-hello-static.pagio.ir
```

## What to look for in the dashboard

After step 2, open the dashboard:

```bash
ssh -fNL 8080:localhost:3030 hetzner
open http://localhost:8080
```

You should see:

- **Currently live** → one row, `hello-static`, [PROD] badge, the tag from step 2
- **Recent activity** → three rows for that deploy: `pending → delivering → live`

After step 7 (lab variant), there should be **two rows under base "hello-static"**: one with [PROD] (red) and one with [LAB] (slate), each with its own current tag.

## Tips

- Edit `prototype/index.html` and re-deploy to feel how fast the buildx cache makes iterative deploys.
- Try forcing a failure: rename `prototype/index.html` to nothing and re-deploy — the dashboard should show a `failed` event.
- The `--cache-mode no-cache` default is correct for raw HTML/CSS/JS. If you ever pre-build with hashed asset names (Vite, Astro, etc.), pass `--cache-mode immutable` instead.
