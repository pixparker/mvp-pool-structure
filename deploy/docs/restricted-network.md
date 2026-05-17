# Restricted-network mode (Iran, air-gapped, behind censorship)

When the pool VPS sits in a network where Docker Hub, Ubuntu archives, or Let's Encrypt are blocked or DPI-interfered with, the default flow (apt-install Docker → pull images → Caddy ACME) breaks. This page documents the workarounds the framework supports and the sequence to bring up such a server.

## What breaks (verified empirically on an Iran VPS, 2026-04-28)

| Default behavior | Failure mode |
|---|---|
| `apt-get update` | `archive.ubuntu.com:80` blocked outbound |
| `apt-get update` over HTTPS | TLS handshake DPI-interfered (`Could not handshake: Error in the pull function`) |
| `docker pull <image>` | `auth.docker.io` DNS censored; some Cloudflare-fronted endpoints block |
| `docker pull` from server | Outbound SNI to Docker Hub gets DPI-reset mid-blob |
| Caddy auto-HTTPS via Let's Encrypt | LE endpoints are Cloudflare-anycast → SNI-blocked |
| `git clone github.com/...` | DPI-blocks Git over HTTPS sometimes; reliable on raw IPs only |

What does work (also verified):

- HTTPS to non-Cloudflare hosts on 443 is generally reachable.
- Inbound traffic to the VPS (port 80/443) is fine; only outbound is censored.
- SSH from the operator's laptop into the VPS works (laptop is in-country too); long-running SSH sessions can drop, so use `ControlMaster` and tolerate retries.

## Strategy: laptop is the bridge

Operator's laptop has working internet (e.g. via a v2ray proxy). Server stays purely on the in-country network. The operator's laptop downloads everything and ships it to the server.

```
[laptop, with global access]                   [VPS in Iran]
─────────────────────────────                   ───────────────
download Docker static binaries  ──scp──>      install
pull Docker images (via crane)   ──scp──>      docker load
build per-MVP image              ──scp──>      docker load
                                                docker compose up
```

## Tooling

The framework ships a [`download/`](../../download/) folder with three things:

1. **`refresh.sh`** — laptop-side script that pulls the offline bundle:
   - Downloads Docker static binaries (`docker-<version>.tgz`) and the Compose plugin from `download.docker.com` and `github.com/docker/compose/releases` (both reachable via laptop's working network).
   - Pulls runtime images (`caddy`, `nginx`, `postgres`, `redis`) using `crane` instead of Docker Desktop, since Docker Desktop's proxy integration tends to fail under restricted networks.
2. **`install-bundle.sh`** — server-side installer that:
   - Extracts the Docker static tarball into `/usr/local/bin/`
   - Installs the Compose plugin under `/usr/local/lib/docker/cli-plugins/`
   - Generates minimal `docker.service` / `containerd.service` / `docker.socket` systemd units (the static tarball ships none)
   - Creates a 2 GB swapfile if RAM < 4 GB
   - Sets up `/srv/{infra,apps}` and the `mvpool` symlink
   - **Patches `infra/Caddyfile` and `infra/compose.yaml`** to remove the `registry.${POOL_DOMAIN}` block and the `registry:2` service — there's no self-hosted registry on a restricted-network VPS, so we use **tarball-mode deploys** for everything.
3. **`download/tools/crane`** — a single Go binary for pulling images without Docker daemon. Works through the laptop's transparent proxy more reliably than `docker pull`.

## TLS strategy: Cloudflare Flexible (recommended for prototypes)

Let's Encrypt is unreachable from inside the restricted network, so Caddy can't run ACME. Instead:

- The pool's domain is **proxied by Cloudflare in orange-cloud mode**.
- Cloudflare presents a real public TLS cert at the edge (browsers see HTTPS).
- Cloudflare → origin is plain HTTP (Cloudflare's "Flexible SSL" mode).
- Origin Caddy serves the per-MVP site as `http://<slug>.${POOL_DOMAIN}`, no cert needed.

For end-to-end encryption (browser ↔ CF ↔ origin), use **Cloudflare Origin CA cert** instead — generated in Cloudflare dashboard, valid for 15 years, drop on the server, point Caddy at it. Slightly more setup; recommended for production. See [operations.md → Cloudflare](operations.md#cloudflare-orange-cloud).

### Per-MVP Caddy site override for Flexible mode

By default `mvp:add` writes a site file like:

```
demo-faraward.pagio.ir {
    ...
}
```

Caddy treats that as wanting auto-HTTPS, which fails behind a censored network. After `mvp:add`, prefix the host with `http://`:

```
http://demo-faraward.pagio.ir {
    ...
}
```

That tells Caddy to serve HTTP only on port 80. Cloudflare in front does the public-facing TLS termination.

## SSH considerations

- The pool's SSH login may resolve through the laptop's local proxy (e.g. Shadowrocket fakedns IPs in `198.18.0.0/15`). Long sessions get killed mid-stream. **Connect via the server's real IP** (e.g. `Host pagio` alias in `~/.ssh/config` pointing at the bare IP) and add SSH `ControlMaster` to multiplex commands over a single TCP session:
  ```
  Host pagio
      HostName 94.182.93.28
      User root
      ServerAliveInterval 15
      ServerAliveCountMax 8
      ControlMaster auto
      ControlPath ~/.ssh/cm-%r@%h:%p
      ControlPersist 10m
  ```
- For long-running operations on the server (apt install, install-bundle, etc.) prefer `setsid nohup ... > /var/log/foo.log 2>&1 &` and poll the log over short SSH commands. SSH session drops then don't kill the work.
- For file transfer, **rsync's `--partial`** is necessary; long single-stream transfers get cut. If a single rsync drop loses progress repeatedly, fall back to per-file `scp` with a retry loop and a size check after each attempt.

## Operator-laptop VPN/proxy config — direct rules for Iranian services

If the operator's laptop runs a foreign-exit VPN (v2ray, Shadowrocket, Clash, …) to reach blocked resources, **every Iran-hosted resource must be on a DIRECT (no-proxy) rule**. Otherwise traffic exits abroad and Iran-side services (Arvan edges, the ArvanCloud panel, the pool VPS itself) reject the foreign-IP return path. Symptoms look like server faults (`SSL_ERROR_SYSCALL`, TCP timeouts, empty 200 responses, SSH exit code 255) but the server is fine — the laptop is the problem.

**Minimum DIRECT-rule list (add before any DevOps work on the pool):**

- Domain suffixes: `<pool-domain>` + every per-MVP brand domain hosted on the pool (e.g. `pagio.ir`, `mizro.ir`, `mizit.ir`, `farawand.ir`), plus `arvancloud.ir` (panel + API).
- Bare IPs: the pool VPS public IP (e.g. `94.182.93.28` for `pagio.ir`). Without this, `ssh pagio` and any direct-IP curl will fail.
- Simpler alternative: CIDR rules covering Iranian allocations (`94.182.0.0/16` for the pool host's range, `185.143.232.0/22` for ArvanCloud edge anycast observed in the field).

**Fakedns is a separate gotcha — DIRECT alone isn't enough.** Even with a `DOMAIN-SUFFIX,…,DIRECT` rule, Shadowrocket's fakedns still hijacks DNS lookups (returns `198.18.0.x`) and routes connections through its local TCP handler. Apps appear to "work" while never reaching the real server — `dig` returns fake IPs, `bash </dev/tcp/…>` connects to the fake IP, browser HTTPS may return empty 200s from Shadowrocket itself rather than from the real origin.

**Verification recipe (use this before debugging any "Arvan/cert/Caddy is broken" report):**

```bash
# Get the real edge IP via authoritative NS, bypassing system DNS:
REAL_IP=$(dig +short <host>.<pool-domain> @v.ns.arvancdn.ir | head -1)

# Probe via --resolve to bypass system DNS entirely:
curl -sI --resolve "<host>.<pool-domain>:443:${REAL_IP}" "https://<host>.<pool-domain>/"
```

A real Arvan edge response includes `server: ArvanCloud` and `x-request-id: …` headers. Anything else (empty body, missing those headers) means the system-DNS path was intercepted by Shadowrocket. **If `--resolve` succeeds but plain curl fails, the laptop is misconfigured — don't tweak Caddy, Arvan, or certs.**

To fully bypass Shadowrocket for browser-based UX testing: add `,no-resolve` to the rule (raw config; some UIs don't expose this), switch Settings → DNS from Fake-IP to Direct mode, or quit Shadowrocket entirely while testing.

## End-to-end bring-up sequence (restricted network)

```bash
# 0. (laptop) refresh the offline bundle
cd ~/repo/mvp/mvp-pool/download
./refresh.sh

# 1. (laptop) rsync the framework + bundle to the server
rsync -avh --partial \
    --exclude='.git' --exclude='.DS_Store' --exclude='*.crdownload' \
    --exclude='download/tools/' \
    ~/repo/mvp/mvp-pool/  pagio:/opt/mvp-pool/

# 2. (server) install Docker, swap, /srv layout, mvpool symlink, Iran patches
ssh pagio 'bash /opt/mvp-pool/download/install-bundle.sh'

# 3. (server) generate /srv/infra/{compose.yaml symlink, Caddyfile symlink, .env}
ssh pagio 'mvpool infra:install'

# 4. (server) edit /srv/infra/.env to set POOL_DOMAIN + ACME_EMAIL
ssh pagio 'sed -i "s|^POOL_DOMAIN=.*|POOL_DOMAIN=<your-domain>|; s|^ACME_EMAIL=.*|ACME_EMAIL=<your-email>|" /srv/infra/.env'

# 5. (server) start the infra (Caddy + Postgres + Redis; no registry)
ssh pagio 'mvpool infra:up'

# 6. (laptop or server) register the MVP
mvpool-local mvp:add <slug> --type static [--no-db --no-redis]

# 7. (server) patch the generated site file for Cloudflare Flexible (HTTP-only origin)
ssh pagio "sed -i 's|^<slug>.<pool>|http://<slug>.<pool>|' /srv/infra/sites/<slug>.caddy && mvpool infra:reload-caddy"

# 8. (operator dashboard) turn on orange cloud + Flexible SSL on the slug's hostname

# 9. (laptop) build & ship the MVP image via tarball mode
mvpool-local deploy <slug> --mode tarball --from /path/to/repo --static-root prototype

# 10. verify
curl -I https://<slug>.<your-domain>
```

## What's lost vs the unrestricted-network flow

- No self-hosted registry → tarball mode for every deploy. Layer dedup is gone; expect full image transfers each time.
- No `mvpool self-update` via `git pull` on the server (it can't reach GitHub). Updates = re-rsync from operator's laptop.
- Caddy auto-HTTPS unavailable → relying on Cloudflare for public TLS.
- Bundle must be refreshed on the laptop and re-rsynced when image versions change.

## When the network situation improves

If outbound network restrictions ease in the future (or the VPS is migrated to a less-restricted host), the same VPS can be flipped back to the default flow:

1. Restore the registry block in `/opt/mvp-pool/deploy/infra/compose.yaml` and `/opt/mvp-pool/deploy/infra/Caddyfile` from the `.bak` files.
2. Add the `registry:2` image to the bundle (or pull it directly).
3. Run `mvpool infra:up` to start the registry container.
4. Re-add Caddy auto-HTTPS by removing `http://` prefixes from per-MVP site files.
5. From laptop: `mvpool-local login` and switch from `--mode tarball` to default registry deploys.

---

## Field findings — Iran VPS bring-up, 2026-04-28/29

Concrete issues hit during the first real Iran deployment, with their root cause and fix. Skim before bringing up a new Iran VPS — most of these are cheaper to dodge than to debug live.

### 1. SSH sessions drop mid-command via the public hostname

**Symptom:** `ssh user@<hostname>` works for short commands, drops `Connection closed by 198.18.0.x port 22` for anything that runs more than a few seconds. The IP `198.18.0.x` is in RFC 6890 TEST-NET-1, which Shadowrocket and similar Mac proxies use as **fakedns**.

**Root cause:** The local proxy intercepts DNS for the hostname (even with a "bypass" rule), routes the SSH session through itself, and kills idle/long-lived TCP.

**Fix:** Use a direct-IP SSH alias plus `ControlMaster` for connection multiplexing. Sample `~/.ssh/config`:
```
Host pagio
    HostName 94.182.93.28
    User root
    ServerAliveInterval 15
    ServerAliveCountMax 8
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 10m
```

For long-running server-side tasks (apt install, docker pulls), wrap them in `setsid nohup ... > /var/log/foo.log 2>&1 &` and poll the log file via short SSH commands. SSH drops then don't kill the work.

### 2. apt-get update fails — even over HTTPS

**Symptom:** `apt-get update` fails with mixed errors: `Connection failed [IP: ... 80]` (HTTP/80 outright blocked) AND `Could not handshake: Error in the pull function` (TLS DPI'd to specific hosts) AND `Temporary failure resolving 'archive.ubuntu.com'` (DNS censorship).

**Root cause:** Iran blocks outbound port 80 entirely; HTTPS/443 to Canonical's archive hosts gets TLS-fingerprint-blocked by DPI. Some package mirrors are also DNS-censored.

**Fix:** Don't try to install via apt on the server. Use the static Docker tarball + the `download/install-bundle.sh` flow. **No apt activity required on the server at all.** Static binaries cover dockerd, docker CLI, containerd, runc, ctr, docker-init, docker-proxy. The compose plugin is a separate single binary.

### 3. Docker Desktop's "Manual proxy" config silently overridden

**Symptom:** You set `Docker Desktop → Settings → Resources → Proxies → Manual proxy: http://host.docker.internal:1082`, click Apply & Restart. `docker info` *still* shows `HTTP Proxy: http.docker.internal:3128` (Docker Desktop's built-in cache proxy). `docker pull ubuntu:24.04` fails with `Bad Request` or `EOF` from `registry-1.docker.io`.

**Root cause:** Docker Desktop's `http.docker.internal:3128` is its built-in Hub Cache. It's auto-configured and overrides user-set proxy settings unless explicitly disabled.

**Fix that worked:** Skip Docker Desktop for image pulls. Use `crane` (single static binary from `github.com/google/go-containerregistry/releases`) which goes through the laptop's transparent proxy correctly. With retries, mid-sized images (~50 MB compressed) succeed within 1–3 attempts.

### 4. `crane pull` drops mid-blob (~15–25 MB transferred)

**Symptom:** `crane pull caddy:2-alpine /tmp/caddy.tar` fails partway with `unexpected EOF` after ~20 MB. Tiny images (alpine, 3 MB) pull fine; mid-sized images fail.

**Root cause:** Iran's network has aggressive idle-timeout and rate-limit at the TCP layer (or DPI throttles long TLS sessions to specific destinations). Single-shot pulls of any non-trivial size hit it.

**Fix:** Wrap `crane pull` in a retry loop (5–10 attempts). Each retry restarts from scratch; eventually one full transfer slips through.

### 5. Cloudflare orange-cloud is wrong for Iran-to-Iran traffic

**Symptom:** Origin works server-side. Orange-cloud the hostname → browser/curl in Iran fails with `ERR_CONNECTION_CLOSED` / `SSL_ERROR_SYSCALL`. Visitors abroad see the site fine.

**Root cause:** With orange-cloud, DNS resolves to CF anycast (`104.x` / `188.x`). Iran's DPI blocks the laptop→CF TLS handshake. Even a Shadowrocket-bypass rule for the apex domain doesn't help because Shadowrocket still routes the TCP through itself, then encounters the same DPI on the way out via the bypass path.

**Fix:** For pools with **Iran-resident audiences**, do NOT use Cloudflare in front. Use either grey-cloud direct-to-origin (if HTTP-only is acceptable) or an Iran-based CDN like ArvanCloud. See the [ArvanCloud migration runbook](#arvancloud-migration-recommended-for-iran-audiences) below.

### 6. CF DNS lookups intermittently fail from Iran ISPs

**Symptom:** With Shadowrocket OFF on the operator's laptop, `dig demo-faraward.pagio.ir` may not resolve. Real Iran visitors (no VPN) report "site not found" / DNS failure, not just connection failure.

**Root cause:** Cloudflare's authoritative nameservers (`*.ns.cloudflare.com`) are on CF anycast IPs that are partially blocked from Iran. Iran ISP recursive resolvers can't reliably reach them.

**Fix:** Move DNS hosting to an Iran-based provider (ArvanCloud, Hostiran). The zone records stay the same; only the NS records at the registrar change. Visitors' Iran ISPs reach the new nameservers reliably because they're inside Iran's network.

### 7. Bare HTTP `Host`-header URL filtering is intermittent, not deterministic

**Symptom:** `/dashboard.html`, `/login.html`, `/kpi.html` returned `Empty reply from server` from the operator's laptop while `/games.html`, `/landing.html`, `/wizard.html` worked. Looked like keyword DPI. Different runs failed *different* paths.

**Root cause:** Not URL-keyword filtering — random TCP drops under DPI/connection-tracker rate limits. The cleartext HTTP path triggers more aggressive throttling than HTTPS would.

**Fix:** Get TLS at origin (or at an Iran CDN edge in front). HTTPS hides the URL path from DPI and reduces the connection-level interference. Until then, treat any one failed request as flake; retry once.

### 8. rsync of a directory drops mid-tree; per-file scp is more robust

**Symptom:** Single `rsync -av source/ host:dest/` fails partway with `Connection closed by ... port 22` after ~150 MB. `--partial` keeps work but the next rsync attempt sometimes resumes incorrectly under macOS BSD rsync. `--append-verify` not supported in BSD rsync.

**Fix:** For large bundle transfers, loop per-file scp with explicit size verification:
```bash
for f in big-files/*; do
  for try in 1 2 3 4 5; do
    scp "$f" pagio:dest/ 2>&1
    [ "$(ssh pagio "stat -c %s dest/$(basename "$f")")" = "$(stat -f %z "$f")" ] && break
  done
done
```

### 9. Compose `infra:up` pulls services it doesn't need on a static-only pool

**Symptom:** First `mvpool infra:up` on a static-only pool tries to `docker pull postgres:16-alpine` and `redis:7-alpine` and hangs / fails because those images aren't in the offline bundle.

**Fix (now in framework):** `infra/compose.yaml` gates postgres, redis, registry behind compose `profiles: ["data"]` / `profiles: ["registry"]`. Default `mvpool infra:up` starts Caddy alone. Bring data services up explicitly only when an MVP needs them.

### 10. Browser shows ERR_CONNECTION_CLOSED on a working origin

**Symptom:** `curl http://<host>/` from server returns 200; from operator's browser, browser shows `ERR_CONNECTION_CLOSED`.

**Root cause:** Combination of Shadowrocket's fakedns intercepting the hostname, the bypass-rule routing the connection back through Iran's network, and DPI dropping the connection at the syscall layer. The origin is fine; the path from this specific browser is the problem.

**Diagnosis quick-test:** Curl the origin **by IP with `-H "Host: <hostname>"`**. If that returns 200, the deploy is good — the issue is Shadowrocket / Iran-network intermittence, not your stack.

---

## ArvanCloud migration (recommended for Iran audiences)

When the pool's visitors are in Iran, host DNS (and ideally TLS-CDN) inside Iran. ArvanCloud is the obvious choice — Cloudflare-equivalent product, infrastructure inside Iran, free tier sufficient for prototype/early-stage MVPs.

### What you get

- **DNS** hosted in Iran → reliable resolution from Iran ISPs, no VPN needed for visitors.
- **CDN with TLS at the edge** (optional) → real public TLS cert visible in the browser (lock icon), Iran-to-Iran routing throughout. Free tier covers small/medium prototype traffic.
- **Caching, basic DDoS protection** as bonus.

### Migration steps (per zone, ~15 min + DNS propagation)

1. **Sign up for ArvanCloud** at <https://panel.arvancloud.ir>. Verification needs an Iranian phone number.
2. **Add the zone** (`pagio.ir` or `farawand.ir`) in ArvanCloud panel → CDN → Domains. ArvanCloud will start a DNS scan to import existing records.
3. **Verify imported records.** Check the A records, MX, TXT, CNAMEs. Add anything missing (compare against the current Cloudflare zone).
4. **Decide CDN proxy per record.** For each subdomain like `demo-faraward`:
    - **DNS-only (cloud OFF)** — visitor connects directly to your origin. HTTP only (no TLS at origin in our current setup).
    - **Cloud ON** — ArvanCloud terminates TLS at the edge using a real public cert; origin can stay HTTP. **Recommended.** Same model as Cloudflare orange-cloud, but inside Iran.
5. **Get the ArvanCloud nameservers** from the panel — they look like `ns1.arvancdn.ir`, `ns2.arvancdn.ir`.
6. **Update NS records at your domain registrar.** For `.ir` domains this is the IRNIC panel (or your registrar's portal). Replace the current Cloudflare nameservers with ArvanCloud's. Save.
7. **Wait for NS propagation** (1–24 hr typical, often <1 hr). Test with `dig +trace pagio.ir` from outside; once the trace ends at ArvanCloud's NS, you're switched.
8. **Once stable**, you can leave the Cloudflare zone in CF as a no-op (NS records at registrar overrule it) or delete the CF zone.

### Things to know before flipping

- **DNS TTL during migration:** lower CF TTLs to 5 min ~24 hr **before** the NS switch so Iran ISP caches expire quickly.
- **Email records (MX, SPF, DKIM):** make sure they're identically populated in ArvanCloud before flipping NS. Otherwise outbound mail breaks during propagation.
- **Per-MVP Caddy site files:** if ArvanCloud Cloud is ON for the site (Flexible-equivalent mode), keep Caddy site files as `http://<host>` — origin serves HTTP, ArvanCloud handles edge TLS. If Cloud is OFF, the visitor hits origin directly and you'll want a real cert at origin or accept HTTP-only.
- **The framework is agnostic** to which DNS host you use. `mvpool` and per-MVP compose don't care; only the per-MVP Caddy site file (and `POOL_DOMAIN` in `/srv/infra/.env`) reference the hostname.

### Field findings — pagio.ir on ArvanCloud (2026-04-29)

Items learned during the actual migration. Worth knowing before the next zone:

11. **Free tier doesn't allow proxied wildcards.** A `*` A record on ArvanCloud's free plan is forced to "DNS only" — you cannot turn the cloud icon on for it. **Implication:** every MVP that should be CDN-proxied (TLS, caching) needs its own specific A record in the panel. The framework's `mvpool mvp:add` should create the record per-MVP (manually in the panel for now, or via the ArvanCloud API once we wire it up). For a small pool with 5–10 MVPs this is an annoyance, not a blocker.

12. **The wildcard is still useful as a fallback.** Add `*` A → origin IP, DNS-only. Future subdomains that haven't been registered specifically still resolve and reach the origin (cleartext HTTP, no TLS at edge for them). Specific records take precedence and get the proxy benefits.

13. **NS records for ArvanCloud:** `v.ns.arvancdn.ir` + `e.ns.arvancdn.ir`. Set both at the registrar (IRNIC for `.ir` domains).

14. **`ssh.<pool-domain>` should always stay DNS-only.** No reason to route SSH through a CDN; the CDN doesn't even handle non-HTTP protocols. Keep that record proxy-off.

15. **Per-MVP record naming convention.** Standardize on `<slug>` as the record name (i.e. `demo-faraward` for `demo-faraward.pagio.ir`). The framework's templates already match `<slug>.${POOL_DOMAIN}`, so the panel just needs the slug.

16. **Expected ArvanCloud free-plan limits to watch for** (from public docs): traffic cap per month (typically a few hundred GB on free tier), no custom SSL upload, basic-tier WAF only. Plenty for a prototype/early-MVP pool. Upgrade plan (or hop to a different Iran CDN) when traffic outgrows it.

### After migration

Update `deploy/docs/operations.md` Cloudflare references where appropriate. For Iran-pool VPSes, the recommended default becomes **ArvanCloud DNS + Cloud ON per record**. Cloudflare remains a fine option for non-Iran pools.

### Done as of 2026-05-08

- **`mvpool-local` now creates the ArvanCloud DNS record automatically** when the laptop's `~/.config/mvpool/config` has `MVPOOL_ARVANCLOUD_API_TOKEN`, `MVPOOL_ARVANCLOUD_DOMAIN`, and `MVPOOL_ARVANCLOUD_ORIGIN_IP`. The helper is idempotent: it queries existing records first, only POSTs if absent. Use the explicit subcommand `mvpool-local arvan:ensure <slug>` for ad-hoc record creation; `cmd_deploy` calls it implicitly before each ship. The token must be kept off-repo (`~/.config/mvpool/config` mode 600).

  Concretely, for the **pagio.ir pool** (which runs on the **ArvanCloud free tier**):
    ```bash
    # ~/.config/mvpool/config (mode 600, never committed)
    MVPOOL_HOST=pagio
    POOL_DOMAIN=pagio.ir
    MVPOOL_BUILD_HOST=hetzner
    MVPOOL_ARVANCLOUD_API_TOKEN=<your token>
    MVPOOL_ARVANCLOUD_DOMAIN=pagio.ir
    MVPOOL_ARVANCLOUD_ORIGIN_IP=94.182.93.28
    ```

  After this is set, the per-MVP manual step at <https://panel.arvancloud.ir> goes away — `mvpool-local mvp:add <slug>` followed by `mvpool-local deploy <slug>` is enough end-to-end.

### Still pending (P2/P3)

- **Auto-prefix Caddy site files with `http://`** at `mvp:add` time when running on a restricted-network pool. Until this lands, the manual edit (or a wrapper script — see `demo/static-html/deploy-prod.sh`) is required after each `mvp:add`.
- **Document the wildcard fallback explicitly** in `deploy/docs/adding-an-mvp.md` so operators know that `<new-slug>.<pool-domain>` resolves out of the box for HTTP-only access, even if they forgot to add the specific proxied record.

---

## Field findings — Mizro per-app slug buildout (2026-05-12)

Stood up four Mizro slugs on the pagio.ir pool (lab-prototype, lab-web-public, lab-web-panel, lab-api) over a few sessions. Field findings that affect the framework, not just Mizro:

### 11. `mvpool-local` reports `exit 0` when ship/migrate fails mid-stream

When the rsync from Hetzner → laptop drops (Iran link), or the SSH connection to Hetzner closes between `docker save` → `rsync`, **the script can return `exit 0` while leaving the deploy half-done**: image saved on the build host but never loaded on the pool; compose up never triggered. Dashboard records "live" but the slug is stale.

**Workaround:** every wrapper should verify post-deploy via `/version.txt` or another tag-bearing endpoint, AND check `docker ps` on the pool, before reporting success.

**Framework fix:** propagate `set -e` discipline through `ship_tarball_via_build_host`'s per-image loop so partial failures bubble up to the script's exit code. The `--partial` flag on rsync should also be retried in-loop (n=3) before giving up, since Iran-link drops are routine.

### 12. `--from .` rsync grabs the working tree, not git HEAD

When two developers are active on the same app, deploying while the other dev is mid-edit picks up a half-saved file. We hit this twice — TS errors that didn't exist on disk one minute later. The deploy fails inscrutably.

**Workaround:** commit before deploying. Yes, this means git is a de-facto deploy precondition.

**Framework fix:** add a `--from-git HEAD` (or default) mode that uses `git archive HEAD | tar -x` for the build context, so deploys always reflect a known commit. Today's behavior stays available as `--from <path>` for explicit override.

### 13. `full-stack-queue` template builds images you may not need

The `full-stack-queue` build path unconditionally builds api + web + worker. For projects that route web through a separate slug (Mizro splits `web-public` and `web-panel` into their own node-server slugs), the `web` image is built, shipped, and never referenced — pure waste (~80 MB per deploy on a slim build, more on a fat one).

**Framework fix:** add `--services api,worker` (or similar) to `mvpool-local deploy` for `full-stack-queue` and `react-node-monorepo` types, so operators can build a subset. Defaults to all-services for backwards compat.

### 14. Container-name collision on shared `mvpool_edge` network

Multiple node-server slugs default their compose service name to `app` (matching the template). When two slugs share `mvpool_edge`, Docker DNS for `app` resolves ambiguously — Caddy's `reverse_proxy app:80` can hit the wrong slug's container. We hit this with `lab-prototype` serving on `lab-web-public.mizro.ir`.

**Workaround:** every Mizro slug sets `container_name: <unique-name>` in its compose override and the Caddy snippet uses that unique name. Documented inline.

**Framework fix:** the `node-server` template should default to `container_name: mvp-{{SLUG}}-app` (already implicit via compose's project naming, but worth making explicit so operators don't accidentally write `app:80` in their Caddy snippets). Even better: the rendered Caddy snippet should auto-reference the container name.

### 15. Fat runtime images break Hetzner disk on multi-MVP buildout

Operator-laptop builds on Iran-VPN had to skip `pnpm deploy --prod` (the npm-metadata fetch was unreliable). The fat-runtime workaround `COPY --from=build /app /app` ships the entire workspace including dev deps. With 4 Mizro slugs × 1.3 GB images × 5x the buildx cache, Hetzner's 38 GB filled at 99% and builds failed with `no space left on device`.

**The fix:** on Hetzner (or any build host with clean npm reach), always use `pnpm deploy --prod` in the build stage and `COPY --from=build /pruned /app` in the runtime. Mizro images dropped 1.3 GB → 214 MB (~6x). Tarballs 285 MB → 65 MB. Bridge transfer reliability also went up dramatically (smaller payload = fewer drop windows).

**Framework fix:** the `node-server`, `react-node-monorepo`, and `full-stack-queue` Dockerfile templates (currently operator-provided per-project) could ship reference slim Dockerfiles operators copy. Today each project writes its own; results vary.

### 16. Iran-link rsync drops correlate with tarball size

Empirically: tarballs > ~200 MB drop ~50% of the time on the Hetzner ↔ laptop leg over Shadowrocket'd VPN. Tarballs < ~80 MB succeed first try ~95% of the time. Slim images are the fix; until then, multiple retries via `--partial` are routine.

**Framework follow-up:** mvpool-local could implement in-script retry with backoff (3 attempts) for both rsync legs. Currently the operator has to re-run the whole `mvpool-local deploy` after a drop. The `--partial` flag means the second-run rsync resumes (so retries are cheap), but the operator has to notice the drop first.

### 17. `mvpool mvp:add --type full-stack-queue` JWT env naming

The framework template generates `JWT_ACCESS_SECRET` + `JWT_REFRESH_SECRET` in `.env`. Mizro's `@mizro/config` package expects `JWT_SECRET` (singular). Naming gap; operator has to add the missing key by hand.

**Resolution:** project-level concern, not framework. Documented for Mizro in [`digital-menu/deploy/docs/lessons-learned.md`](../../../digital-menu/deploy/docs/lessons-learned.md). The framework's choice is fine; project schemas should align (or vice versa). Noted here so future projects know to check.

### 18. Slug-aware build cache pruning

Per-slug buildx cache lives at `/srv/build/<slug>/.buildx-cache/`. With many slugs, this grows. The weekly cron prune is fine for steady-state; during heavy initial buildouts (when each retry adds layers), more aggressive pruning is needed.

**Operator command for "free disk now":**

```bash
ssh hetzner '
  docker buildx prune -af
  docker system prune -af --volumes
  rm -f /srv/build/.ship/*.tar.zst  # stale tarballs
'
```

**Framework follow-up:** `mvpool-local deploy` could prune `.ship/` tarballs older than 7 days at the start of each deploy. Already runs on a weekly cron; this would tighten the window for active development.

---

These findings inform the next round of framework changes. Items 11, 12, 13, 16, 18 are framework-level patches; 14, 15 are template improvements; 17 is per-project schema discipline.

---

## Field findings — Mizro Demo 1 prod-slug provisioning (2026-05-17)

Provisioned the bundled production slug `mizro` on pagio.ir for Phase B of Demo 1 cutover prep. Three new framework patterns worth surfacing:

### 19. `mvp:add` generates auto-HTTPS Caddy snippet that triggers ACME on unreachable hosts

`mvpool mvp:add <slug> --type full-stack-queue --domain <host>` writes `/srv/infra/sites/<slug>.caddy` containing:

```caddy
<host> {                # no http:// prefix → automatic HTTPS
    ...
    reverse_proxy mvp-<slug>-api-1:4000
    ...
}
```

Caddy parses this and **immediately** attempts ACME provisioning on next reload. If the slug's DNS doesn't exist yet (Mizro's case: we provisioned the slug during Phase B prep with DNS deferred to Phase 5), ACME repeatedly fails to reach `<host>:80`, generating log noise and small ACME budget burn.

**Operator workaround (post-provision):**

```bash
ssh pagio "rm /srv/infra/sites/${SLUG}.caddy && mvpool infra:reload-caddy"
```

The real Caddy snippet from `deploy/caddy/` gets staged at deploy time. Until then, no `<slug>.caddy` = no ACME attempts.

**Framework follow-up:** `mvpool mvp:add` could accept `--no-caddy` (skip snippet generation), or write `http://<host> { ... }` by default (explicit HTTP, no ACME). The current default is sensible when operators are doing `mvp:add` + `mvp:deploy` back-to-back; less sensible for staged prep flows.

### 20. `mvp:remove` doesn't clean up orphan containers from hardcoded compose-project names

When the slug's compose.yaml hardcodes `name: mvp-<custom>` (not derived from the slug name), `mvpool mvp:remove <slug>` looks for compose project `mvp-<slug>` — finds nothing, returns success — leaves the actual `mvp-<custom>` containers orphaned.

Hit this on the Mizro legacy `mizro-staging` slug, whose compose.yaml had `name: mvp-mizro` (set up before the per-app slug migration consolidated naming). Output:

```
[mvpool] stopping stack
Warning: No resource found to remove for project "mvp-mizro-staging".
...
✓ MVP 'mizro-staging' removed.

# But docker ps still showed 5 mvp-mizro-*-1 containers running.
```

**Operator workaround:** after every `mvp:remove`, explicitly check for orphans by slug fragment, then down by project name:

```bash
docker compose ls -a | grep "${SLUG_FRAGMENT}"
docker compose -p mvp-<orphan-project> down
```

**Framework follow-up:** `mvp:remove` could read the compose's `name:` field (if present) and use that as the project filter for the cleanup `docker compose down`. Falls back to slug-derived name otherwise. One-line change in the cleanup helper.

### 21. `.env` files lack trailing newlines — `echo X >> .env` corrupts the last line

Patching env vars on an existing slug `.env` via `echo VAR=value >> .env` jams the new line onto the prior one if the file lacks a trailing newline:

```
SECRETS_ENCRYPTION_KEY=iiWT1Mu...QaoJWT_SECRET=3yR1LRE...
                                ^^^^^^^^ append jammed onto prior line
```

Caught in the wild patching `JWT_SECRET` (the singular alias `@mizro/config` requires per field-finding #17) into Mizro's lab-web-publish slug `.env`.

**Operator workaround:** defensive newline check before any `.env` append:

```bash
[ -z "$(tail -c 1 /srv/apps/${SLUG}/.env)" ] || echo "" >> /srv/apps/${SLUG}/.env
echo "NEW_VAR=value" >> /srv/apps/${SLUG}/.env
```

Or use `printf "\nNEW_VAR=value\n" >>` which is robust either way.

**Framework follow-up:** `mvp:add` could write `.env` files with a guaranteed trailing newline. One-line change in the template renderer. Costs nothing, eliminates the gotcha.

---

These three (#19, #20, #21) are framework-level patches when convenient. None block Mizro's Demo 1 cutover; workarounds documented in `digital-menu/deploy/docs/lessons-learned.md §9-12`. Field-finding #17 (`JWT_SECRET` naming) is now 3-strikes on the Mizro side — repeated enough to be worth a framework-vs-project alignment discussion.
