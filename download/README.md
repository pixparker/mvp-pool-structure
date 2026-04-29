# mvp-pool/download — offline bundle for restricted networks

When the pool VPS sits in a restricted network (Iran, air-gapped, etc.) and can't reach `archive.ubuntu.com`, Docker Hub, or Let's Encrypt, the operator's laptop becomes the bridge: download everything once into this folder, then ship it to the server.

## What's here

```
download/
├── README.md           ← this file
├── refresh.sh          ← (re-)download all artifacts (run on a laptop with global internet)
├── install-bundle.sh   ← server-side installer (dpkg + docker load); shipped along with the bundle
├── debs/               ← Ubuntu .deb packages for docker.io + plugins + tools
└── images/             ← `docker save` tarballs of the runtime images
```

The `debs/` and `images/` folders are **gitignored** because they're large (~800 MB total). Anyone on a fresh laptop can rebuild them with `./refresh.sh`.

## Refresh (laptop with global internet)

```bash
cd /Users/pixparker/repo/mvp/mvp-pool/download
./refresh.sh
```

The script:
- Pulls a transient `ubuntu:24.04` container, `apt-get install --download-only`s the right packages, copies `/var/cache/apt/archives/*.deb` out to `debs/`.
- `docker pull`s + `docker save`s the runtime images (caddy, nginx, postgres, redis, registry) into `images/*.tar`.

Total time: 5–15 min depending on link. Output: ~800 MB.

## Ship to a restricted server

```bash
rsync -avh /Users/pixparker/repo/mvp/mvp-pool/download/ root@<server>:/root/mvpool-bundle/
ssh root@<server> 'bash /root/mvpool-bundle/install-bundle.sh'
```

The installer runs `dpkg -i` for the .debs, `docker load` for the images, then `systemctl enable --now docker`. After that, you can run the rest of `bootstrap.sh` normally (it skips Docker install when Docker is already present).

## Refresh schedule

Run `refresh.sh` whenever:
- A new MVP needs an image not in the cache (extend `IMAGES` in the script).
- Ubuntu/Docker security updates are needed.
- A new pool VPS is being provisioned.

## What's NOT in the bundle

- **TLS certs.** Each pool generates its own (Let's Encrypt where reachable, Cloudflare Origin CA otherwise).
- **Per-MVP images.** Those are built per-deploy by `mvpool-local` and shipped via `--mode tarball`.
- **Anything that needs to be unique per pool** (admin passwords, JWT secrets, etc.) — those are generated on the server at `mvpool infra:install` / `mvpool mvp:add` time.
