# Silent-success patterns — defensive rules for any deploy pipeline

The most dangerous bug class in deploy pipelines: a step **reports success but did nothing**. A loud failure is easy to recover from. A silent success that lies for hours/days is a customer-facing outage you don't know about + a trust break with the team.

This doc captures hard-won rules from real incidents (4 silent-success bugs in one day on a project deploying with this framework, 2026-06-02/03). They are *not* mvpool-specific — apply them to any deploy pipeline you build on top of this framework, or that calls into it.

Optimise **loudly**.

---

## Rule 1 — `tail` and `head` and `tee` at the END of a pipe ALWAYS mask upstream failures

**Anti-pattern:**
```bash
zstd -dc file.tar.zst | docker load 2>&1 | tail -3 || bail "load failed"
```
`tail` exits 0 regardless of upstream. `|| bail` reads `tail`'s exit code, never `docker load`'s. If pipefail isn't set (or even if it is, depending on bash version), upstream failures silently pass.

**Fix:**
```bash
set -o pipefail
if ! zstd -dc file | docker load | tee /dev/stderr | grep -q '^Loaded image'; then
    rc_zstd="${PIPESTATUS[0]}"; rc_load="${PIPESTATUS[1]}"
    bail "load failed (zstd rc=$rc_zstd, docker load rc=$rc_load)"
fi
# AND verify the side effect explicitly
docker image inspect "$expected_image" >/dev/null \
    || bail "docker load reported success but $expected_image is not in image store"
```

**Generalised:** Never trust a pipeline's exit code as proof the work happened. Verify the artifact exists (image present, file written, row inserted, response 200 with expected content).

---

## Rule 2 — Empty loops bypass every gate inside them

**Anti-pattern:**
```bash
for app in "${APPS_LIST[@]}"; do
    docker load ...
    cutover ...
    verify ...
    version_probe ...
done
write_status "done"   # ← reaches here with APPS_LIST=()
```

If `APPS_LIST` is somehow empty (bad parse, edge case, upstream API returned `[]`), the loop iterates zero times. **Every** safety check inside the loop is bypassed. The script writes `phase=done` over zero work.

**Fix:** A tail invariant after the loop:
```bash
if (( ${#APPS_DONE[@]} == 0 )); then
    bail "reached done with zero apps processed — gates were never exercised"
fi
```

**Generalised:** Per-item gates are necessary but not sufficient. Always add a tail invariant: *"if I claim success, at least N units of work must have happened."*

---

## Rule 3 — Bash JSON parsing/construction is fragile; use python3

**Anti-pattern (parsing):**
```bash
grep -oE '"apps":[[:space:]]*\[[^]]+\]' | grep -oE '"[^"]+"' | tr -d '"' | grep -v '^apps$'
```
Works fine for compact JSON; fails silently for pretty-printed (`json.dumps(indent=2)`) JSON. `grep` is line-bound — when `[` and `]` are on different lines, the pattern doesn't match. Returns empty → empty array → Rule 2 fires.

**Anti-pattern (construction):**
```bash
"artifacts": {
$(printf '    %s' "${ENTRIES[*]}" | sed 's/$/,/' | sed '$ s/,$//')
}
```
IFS interactions + sed line semantics + heredoc indentation = a JSON document that's "valid enough to parse" but missing entries.

**Fix:** `python3 -c "..."` for both parse and construct. Python is on every Linux distro with shell. Pipe data through stdin, get JSON in/out, assert invariants:

```bash
# parse
apps=$(echo "$json" | python3 -c 'import json,sys; [print(a) for a in json.load(sys.stdin)["apps"]]')

# construct + assert
manifest=$(... | python3 -c '
import json, sys, os
m = build_from_stdin()
missing = [a for a in m["apps"] if a not in m["artifacts"]]
if missing: sys.exit(f"missing artifacts for: {missing}")
print(json.dumps(m, indent=2))
')
```

**Generalised:** Any time you find yourself reaching for `grep`+`sed` on structured data, you're one whitespace change away from a silent regression. Use the proper parser.

---

## Rule 4 — HTTP HEAD smoke checks are theatre

**Anti-pattern:**
```bash
curl -fsI https://app.example.com/ | grep -q "^HTTP/2 200"
```
Returns 200 whether the new container or the old container is serving. **A cutover that silently no-ops still passes this smoke.**

**Fix:** Smoke must verify the DEPLOYED VERSION matches the BUILT VERSION. Every app exposes a `/version.txt` (or `/version.json`) baked at docker build time with the git SHA:

```dockerfile
ARG IMAGE_TAG=unknown
ARG BUILD_TIME=unknown
RUN printf 'tag=%s\nbuild_time=%s\n' "$IMAGE_TAG" "$BUILD_TIME" > public/version.txt
```

Smoke fetches it and compares:
```bash
served=$(curl -fsSL "$url/version.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["tag"])')
[[ "$served" == "$expected_sha" ]] || bail "served $served, expected $expected_sha"
```

If an app doesn't expose version yet, skip *silently neutral* (don't fail) until it does. The framework already does this for `mvpool-local`'s post-deploy verify hitting `/version.txt`.

**Generalised:** "App returns 200" is liveness, not deployment success. Always verify a build-time artifact that changes with the deploy.

---

## Rule 5 — Inter-host scripts must auto-sync OR loudly diverge

**Anti-pattern:** Helper scripts on a deploy target (e.g. `/usr/local/lib/<framework>/foo.sh`) installed once by a setup script and never auto-updated. Devs commit fixes to the repo, but the broken version on the target keeps running because nobody re-runs the installer.

**Lesson learned 2026-06-03:** A fix was committed to the repo and a deploy still ran the **broken version** because nobody scp'd it to the target host. The repo and the running host had silently diverged for hours.

**Fix — pick one or layer them:**
- The deploy workflow itself rsyncs/scp's any changed framework scripts to the target before each deploy (mvpool's `self-update` is this pattern; extend with your own scripts).
- The target script verifies its own md5 against a known-good source at start of every run and refuses to proceed on mismatch.
- At minimum: the script logs its own version (git rev at packaging time) at start, so the journal shows which version actually ran.

**Generalised:** Any code that runs *not* in CI/the container itself needs the same drift detection as production binaries. "Configuration" is code. Out-of-band shell scripts are the largest unmanaged surface in most deploys.

---

## Rule 6 — STATE_FILE that lies blocks future retries

**Anti-pattern:** A "deployed SHA" state file that updates on `phase=done`. When silent-success bugs (above) write `phase=done` over zero work, the state file gets the new SHA. Subsequent polls then quietly skip with `state==latest, no-op` — the bug **compounds**: not only did one deploy lie, but every poll for hours after silently "skips" a re-attempt because state matches latest.

**Fix:**
1. State updates only **after** invariants (Rule 2) hold.
2. The "already deployed, skip" path STILL logs at info level (`log info "no-op: already at $sha"`) — silent exits make incident triage 10× harder.
3. Operator escape hatch: `rm /var/lib/<framework>/deployed-sha.txt` forces a re-poll.

**Generalised:** Idempotency optimisations (skip-if-already-done) should ALWAYS log. The cost of one log line per poll is zero; the cost of "no logs at all when something is wrong" is unbounded debugging time.

---

## Rule 7 — Run-ID footers on every async notification

**Anti-pattern:** Two parallel deploys both send `✅ Deployed` and `❌ Failed` messages with no way to tell which run sent which. Operator can't distinguish today's success from yesterday's failure that arrived late.

**Fix:** Auto-inject a correlation footer like `· #41234 deploy-prod` (clickable to the run URL) at the bottom of every notification. Even more important when the CI pipeline uses `cancel-in-progress: false` for safety (any pipeline that mutates prod state should — see "Cancel-in-progress" below).

**Why cancel-in-progress: false matters:** Cancellation is a SIGTERM at runner level. If it fires *during* cutover (the window where the container swap is mid-flight), you get half-deployed prod. Better: let older runs finish, but supersede them politely with a checkpoint-based check before each expensive step.

**Generalised:** Any async notification that can interleave with another needs a correlation ID. Trivially cheap; saves hours of "which run did this come from?"

---

## Rule 8 — The service environment is not your shell

**Anti-pattern:** Code that works fine when you run it interactively but fails under systemd / docker / cron. The runtime environment differs in ways you'll never test for.

**Concrete traps that bit us 2026-06-03:**
- `/dev/stderr` doesn't exist under systemd's service environment ("No such device or address"). `tee /dev/stderr | grep -q ...` died on the open. Used to work interactively, broken under the unit.
- Env vars set in `~/.profile` aren't there. PATH may be minimal. `EnvironmentFile=` directives are NOT additive with the calling shell's exports.
- `set -e` defaults differ: a script you exercise by hand exits gracefully, the same script under cron dies on the first non-zero anywhere.

**Fix:**
- Smoke the script under the actual runtime BEFORE trusting it. For systemd: `systemctl start your-service.service` once, then `journalctl -u your-service.service -n 100` — *not* `bash your-script.sh` from your terminal.
- Don't reach for special files like `/dev/stderr` or `/dev/tty`. Use plain stdout/stderr; the journal/log driver captures both.

**Generalised:** "Works on my machine" is the deploy-pipeline form of "works in dev." Test under the real runtime.

---

## Rule 9 — `set -u` + array-index access kills the script before `bail()` runs

**Anti-pattern:**
```bash
set -uo pipefail
if ! some | pipe | thing; then
    rc_a="${PIPESTATUS[0]}"; rc_b="${PIPESTATUS[1]}"   # ← here
    bail "failed (a=$rc_a, b=$rc_b)"
fi
```
When the pipeline implodes mid-flight, `PIPESTATUS` may not be fully populated. `${PIPESTATUS[1]}` under `set -u` raises *unbound variable* and the script dies immediately — **before `bail()` runs**, so phase=failed is never written, no notification fires, the cycle just exits 1 silently.

**Fix:**
- Don't index PIPESTATUS without first checking `${#PIPESTATUS[@]}`. Or guard with `${PIPESTATUS[1]:-?}`.
- Better: drop pipefail+PIPESTATUS gymnastics entirely. Run each step separately and check `$?` of the *one* thing you care about. Even better, verify the side effect (Rule 1).

**Generalised:** Error-handling code paths must themselves be safe under the script's strict-mode settings. A `bail()` that can't even reach `bail` is worse than no bail at all.

---

## Rule 10 — Python f-strings can't escape the outer quote inside braces

**Anti-pattern:**
```python
print(f"{name}\t{info[\"key\"]}")
                      # ^^ SyntaxError on every CPython version
```
The `\"` inside the brace is parsed as f-string template, not as string content. CPython rejects it at parse time. If the bash caller has `2>/dev/null` on the python invocation, the SyntaxError is invisible — the script silently produces no output. Downstream "loop over the empty output" then quietly does nothing (Rule 2). **Real cost on 2026-06-03: hours of debugging "why is the artifacts dict empty when the manifest is perfect?"**

**Fix:** Inside braces, use the OTHER quote style:
```python
print(f"{name}\t{info['key']}")     # f"" outside, '' inside braces — fine
```
Or for complex cases, extract to a variable before the f-string:
```python
key = info["key"]
print(f"{name}\t{key}")
```

**Generalised:** When passing code through string boundaries (bash heredoc → python inline → SQL → etc), prefer alternating quote styles over backslash escaping. And NEVER muzzle stderr (`2>/dev/null`) on the inner interpreter.

---

## Rule 11 — Out-of-band scripts include their DEPENDENCIES, not just the script files

**Anti-pattern:** A target-side script (`/usr/local/lib/<framework>/foo.sh`) was bundled via an installer. The bundling step copied the script AND a framework-level lib (logging, retry). But the script also called `lib::app_field` — a function defined in the *project's* lib, **which was never bundled**. Every call returned empty. Empty value flowed through → wrong derived name → "image not in store" bail → infinite retry loop.

The script had been calling this non-existent function for weeks. Earlier failures upstream masked it. Once the upstream failures were fixed, this one surfaced.

**Fix:**
- Audit which functions a target-side script ACTUALLY calls vs which it has DEFINITIONS for. Anything called but not defined = bug-waiting-to-happen.
- Bundle dependencies too, OR inline the helpers (10 lines of awk reading a config file is cheaper than the cross-host sourcing chain).
- Mark framework vs project code clearly. If a "framework helper" only works because the project shim sources it, the framework boundary is misdrawn.

**Generalised:** When you split code across hosts, every cross-host call surface is a manifest. The host should refuse to run if its dependencies aren't satisfied; otherwise undefined calls silently return empty and you have a Rule 2 cascade.

---

## Rule 12 — Build-side and verify-side constants must come from one source

**Anti-pattern:** build-side tagged an image as `registry.foo/mizro-api:abc123` (no `-app` suffix for full-stack bundles). The verify-side gate checked `docker image inspect registry.foo/mizro-api-app:abc123` (had a guessed `-app` suffix). The image IS loaded — but under a different name than the gate looks for. The gate bails with "not in image store after load," lying about which side is wrong.

**Fix:**
- A single function (`expected_image_for(app, sha)` or similar) used by BOTH the build-and-tag step AND the verify-after-load step.
- If they have to be in separate scripts/files: write a unit test that runs both with the same input and asserts identical output.

**Generalised:** Any time a "build" side and a "verify" side compute the same value, they will drift. Either share the function or test the drift away.

---

## Rule 13 — Polling retry loops are an active bandwidth liability

**Anti-pattern:** The poller checks every 30s for new builds. When a deploy gets stuck in a "fail → retry → fail" cycle (any of Rules 1–12 above), it re-downloads the artifact every 30s, indefinitely. **Real cost 2026-06-03:** ~6 GB of object-storage→Iran-VPS downloads in 30 minutes; the carrier flagged the traffic as anomalous and threatened to throttle.

**Fix:**
- **Skip-if-already-done:** check whether the work was already performed (image present, file written) before doing it again. `docker image inspect $expected` before re-pulling.
- **Failure cooldown:** after N consecutive failed deploys of the same SHA, stop retrying for M minutes.
- **Local cache:** if you've already pulled and the artifact is on disk + valid, don't pull again.

**Generalised:** Any retry policy without backoff / cap is a denial-of-service against your own infrastructure. Especially expensive when the "infrastructure" includes carrier bandwidth allowances or per-deploy bandwidth on a remote VPS.

---

## Rule 14 — Listener-side timeout doesn't stop emitter-side retry loop

**Anti-pattern:** Two-tier async pipelines — emitter (target's poller) writes status; listener (CI's wait-script) reads + relays + judges done/failed. The listener has a 20-min timeout. When 20 min passes without `phase=done`, the listener gives up — but **the emitter keeps emitting**. The target still cycles every 30s, still pulls 80 MB tarballs, still writes status — for hours, until manual intervention.

**Fix:**
- When the listener times out, signal the emitter to stop. A "cancelled" marker file the emitter polls for; an Arvan-side marker; whatever fits the channel.
- Or: bound the emitter independently of the listener — same SHA failed N times → stop trying (Rule 13's failure cooldown).

**Generalised:** In two-tier orchestration, give-up decisions need to propagate. A timeout on one side without a stop-signal to the other = ongoing damage after the operator thinks the run is "done."

---

## Rule 15 — A gate that exists in the manual path but not the automated path is a silent-success bug

**Anti-pattern:** The manual deploy script runs N steps: load → **migrate** → recreate → verify. The automated/gated pipeline copies steps 1, 3, 4 but quietly drops step 2 (often because step 2 is conditional, app-specific, or "we'll add it later"). Every automated deploy returns 0 because every step it ran succeeded — but the work it didn't do silently accumulates. Schema drifts behind code; feature-flag tables aren't created; seed-once rows never appear. The pipeline looks healthy until a deploy ships code that references the missing artifact and prod 500s on `column "foo" does not exist`.

**Real incident (2026-06-05, Mizro):** `deploy-prod-api.sh` had a `docker compose --profile tools run --rm migrate` step between load and recreate. The automated pipeline (`pagio-pull-and-deploy.sh`) was authored after the manual script and only copied load + recreate + verify. Five migrations (0030–0035) shipped over multiple deploys, none ran on prod. The drift was invisible until a frontend feature hit `menus.variants_enabled` and notifications polled `platform_events` — both columns/tables from migrations 0030/0031. Prod 500'd; logs showed Postgres 42703/42P01. No deploy "failed"; the gap was the bug.

**Fix:**
- Audit: `diff <(grep -E '^(ssh|docker compose|run --rm)' manual.sh) <(grep -E '^(ssh|docker compose|run --rm)' auto.sh)`. Every line in manual.sh that has no twin in auto.sh is a candidate silent-gap.
- Move shared steps into a function/script that BOTH paths call. The manual path becomes a thin wrapper over the automated one (or vice versa). Single source of truth for the lifecycle.
- For each step the automated path skips: a written rationale ("auto skips seed because seed is one-time"). If no rationale exists, copy the step over.
- Bail-loud on the auto-path step's failure with state that's RECOVERABLE — e.g. run migrate BEFORE flipping IMAGE_TAG, so a migrate failure leaves prod on old code + old schema (consistent), not new code + old schema (broken).

**Generalised:** Automation that's a subset of manual operation is silent debt. Every step the manual procedure runs and the script doesn't is a future incident — the deploy keeps returning 0 right up until the drift reaches a user-visible code path. Treat the manual runbook as a test oracle: every step in it must appear in the automated path or be explicitly justified as omitted. The shape "we have a script but the human still does X afterward" is the smell.

---

## Rule 16 — Terminal failure must advance the per-host STATE_FILE just like success

**Anti-pattern:** A polling deploy script has an early-exit check: "if local `STATE_FILE` already matches `LATEST.sha`, exit 0". `STATE_FILE` is only written on success. Every terminal-failure path writes `phase=failed` to a remote status object but does NOT advance `STATE_FILE`. Next poller tick re-evaluates → `STATE_FILE.sha ≠ LATEST.sha` → re-runs the entire pull→load→cutover→smoke cycle. Indefinitely. The operator sees the red status, but the work keeps repeating because the polling loop has no way to know "this SHA is done — successfully OR otherwise."

**Real incident (2026-06-05, Mizro):** Smoke failed for 2 apps. The smoke-fail branch wrote `phase=failed` to Arvan, exited 1, and stopped — but never touched local `STATE_FILE`. The systemd timer re-fired every 30s. Telegram got 5+ rounds of "🔄 Cutover @ <sha>" messages over ~3 min before the listener's 300s stuck-detection took over. Pagio was burning Arvan bandwidth (re-downloading 200 MB tarballs) AND container churn.

**Fix:**
- Every terminal-failure path (`bail()`, smoke-fail branch, etc.) that exits 1 must ALSO write `LATEST_SHA` to `STATE_FILE`. The early-exit treats matching `STATE_FILE` as "decided — skip", regardless of which decision.
- Recovery — to retry the **same SHA** after fixing the cause: `rm STATE_FILE`. To deploy a **new SHA**: bump `LATEST.json` (re-promote) — the differing SHA breaks the early-exit guard naturally.
- An optional sibling marker file (e.g. `STATE_FILE.last-outcome`) distinguishes "deployed" from "held-after-failure" for monitoring — not required for loop correctness.

**Generalised:** A polling retry loop whose early-exit check doesn't include the failure outcome is a bandwidth liability — the twin of Rule 13. Every "should I run?" decision needs to know about BOTH success and terminal failure of the previous run. "I exited 1" is not the same as "the loop should remember I exited 1."

---

## Rule 17 — A per-app conditional in a SHARED build script silently scopes a "universal" fix

**Anti-pattern:** The build script special-cases one app for build-args / env / flags: `if [[ $app == "X" ]]; then build_args+=(--build-arg FOO=$VAL); fi`. A comment justifies it: *"only Dockerfile.X consumes FOO; other apps don't declare it."* Later, the OTHER Dockerfiles add `ARG FOO=<default>` (e.g. for parity, or to bake the value into a runtime artifact like `/version.txt`). The default ships to prod for every non-special-cased app — and the only way to find out is to inspect a downstream consumer.

**Real incident (2026-06-05, Mizro):** `build-and-upload.sh` passed `--build-arg IMAGE_TAG=$SHA` only for `web-panel`. Every other Dockerfile had `ARG IMAGE_TAG=unknown` and baked it into `/version.txt`. Prod served `tag=unknown` from api/web-public/web-publish/web-ops for weeks. Invisible until the ops Versions dashboard's version probe surfaced "liveTag: unknown" for 4 of 5 apps despite cutover succeeding.

**Fix:**
- A build-input flag (IMAGE_TAG, BUILD_TIME, RELEASE, GIT_REV) should default to "every app", not "only X". The conditional belongs INSIDE each Dockerfile (declare the ARG or don't; the runtime layer decides whether to use it).
- Audit cue: `grep -l 'ARG <flag>' deploy/Dockerfile.*` → all consumers. If the build script only emits the flag for a subset, that gap is the bug.
- Don't rely on trust-based docs ("only X consumes this"). Trust the build input; let each Dockerfile choose to consume or ignore.

**Generalised:** A build-time conditional that says "only X needs this" without enforcement decays into "X needs this AND so do Y and Z, but the script forgot." The conditional itself is the silent-success vector — pass the input universally, let the consumer choose.

---

## Rule 18 — Smoke-check paths must be authentication-bypassed (otherwise you're checking the gate, not the app)

**Anti-pattern:** A smoke check hits a path that's auth-gated at the edge (basic_auth, OAuth, mTLS, IP allowlist). Without creds, the path returns 401/403 unconditionally — every smoke run fails identically regardless of whether the app behind the gate is healthy or broken. Once that becomes the steady state, real failures hide in the same 401 noise; the smoke check provides zero useful signal.

**Real incident (2026-06-05, Mizro):** web-ops's `smoke_path` was `/login`. Caddy's `basic_auth` shielded all paths. Every deploy logged `smoke https://ops.mizro.ir/login → 401`. The deploys were healthy (Caddy + container + app all working as designed), but the smoke gate flagged every one. The fix required BOTH halves: add a `@needsAuth not path /version.txt` matcher to Caddy AND change the smoke target to `/version.txt`. Missing either half leaves the gate equivalent to no gate (always-failing or always-passing).

**Fix:**
- Use a deliberately-bypassed health/version path for smoke. Document the bypass in the auth config so it can't be removed inadvertently. Add a regression check to the auth template if rendering is mechanised.
- If no bypassable path exists (e.g. mTLS-only), provide an internal-network smoke endpoint the prober can reach without crossing the auth boundary.
- The smoke endpoint should return 200 with content reflecting the running app (the SHA, build-time, schema version) — chain this with Rule 4 (version-baked smoke). A static "OK" endpoint doesn't catch "wrong version deployed".

**Generalised:** A smoke check that returns the SAME status code for "app down" and "app up but auth-gated" tells you nothing about the app. It's checking the gate. Pick a smoke path the gate explicitly waives.

---

## Rule 19 — Systemd hardening directives silently isolate writes between services

**Anti-pattern:** Service A and Service B handshake through a shared filesystem path. Service A is sandboxed: `PrivateTmp=true`, `ProtectSystem=strict`, empty `ReadWritePaths=`. Writes from A to `/tmp/`, `/var/tmp/`, or anywhere under the protected tree go into A's private mount namespace; the write succeeds, A's view shows the file, but B's view (system filesystem) shows nothing. No error surfaces — A is "successful", B silently falls through its "file not present → default branch" path.

**Real incident (2026-06-05, Mizro):** Eager-approve handshake. Telegram bot (systemd service, `PrivateTmp=true`, empty `ReadWritePaths=`) writes `/var/tmp/mizro-preapprovals/<sha>.json` on user tap. GH-Actions runner (different uid, no systemd sandbox) reads same path at build end. First test: bot wrote to its private `/tmp/systemd-private-…/var/tmp/`; runner saw an empty dir; build fell through to manual /promote with no error in either log. Took journal-grep + `systemctl show -p ReadWritePaths` to spot.

**Fix:**
- Cross-service file channels live OUTSIDE `/tmp` + `/var/tmp` (the PrivateTmp scope). Canonical home: `/var/lib/<channel>/`.
- Explicitly grant the writer's service unit access via `ReadWritePaths=<path>`. An empty `ReadWritePaths=` (with `ProtectSystem=strict`) means "service writes nowhere" — which is correct ONLY if the service truly produces no filesystem state.
- Pre-provision the dir at install time with the correct mode (e.g. `0o1777` sticky for multi-user write). A sandboxed service can't `mkdir` outside its writable tree.
- After editing the unit, **`systemctl daemon-reload && systemctl restart <unit>`** — `ReadWritePaths` is loaded only on (re)start, not on file edit.

**Generalised:** Process isolation directives turn cross-process file IPC into a silent black hole when channel paths overlap with the isolated namespaces. ALWAYS verify visibility from the **consumer's** perspective (`ls -la /var/lib/...` from B), not just the writer's. Sandboxing makes writes more trustworthy AND more invisible.

---

## The meta-pattern: defence-in-depth catches what loud failures don't

The 2026-06-02/03 incidents all shared a shape: **one layer claimed success without doing the work; downstream layers had no way to know**. Each rule is one more independent verifier:

- Rules 1, 3, 12, 17: exit codes / parsers / constants / build-script per-app conditionals can lie → verify side effects against single sources of truth
- Rules 2, 6, 15, 16: per-item checks can be empty / gates that exist on one path only / failure state that doesn't advance the polling guard → tail invariants + log idempotent decisions + advance state on EVERY terminal outcome
- Rules 4, 18: liveness/smoke checks lie when they pass for the wrong version or hit an auth gate → version-baked + auth-bypassed smoke targets
- Rules 5, 11: configuration AND dependencies can drift silently → drift detection
- Rule 7: parallel runs interleave → correlation IDs
- Rules 8, 9, 10, 19: error-handling code paths / systemd sandbox / `set -u` array access / f-string escape — runtime environment quietly diverges from the shell that wrote the code
- Rules 13, 14: retry + cooldown + cross-tier stop signals

You will not enumerate every silent-success path up front. The defence is **layering** checks at different abstraction levels so when one layer lies, the next one catches it. A deploy pipeline with 3 independent verifiers (`docker image inspect` + `compose ps` + `/version.txt`) is dramatically more trustworthy than one with 5 sequential gates at the same layer.

The 2026-06-03/05 marathon tracked through these rule classes in order: pipe-tail-masks-rc → empty-loop-skips-all-gates → bash-JSON-fragile → silent-stderr → f-string-escape → out-of-band-deps → image-tag-drift → retry-loop-bandwidth-burn → listener-timeout-leaks-emitter → manual-script-has-step-auto-doesn't (the migrate gap) → **failure-doesn't-advance-state** (the smoke-fail retry storm) → **per-app-conditional-leaves-N-1-on-defaults** (the `tag=unknown` baked-into-images bug) → **smoke-hits-auth-gate** (web-ops `/login` always 401) → **PrivateTmp-eats-IPC-handshake** (eager-approve fell to manual). Each one masked the next. Each rule above is *one* of those bugs paid forward.

## See also

- [deploy-flows.md](deploy-flows.md) — registry vs tarball mode
- [operations.md](operations.md) — runbook for backups, rollback, recovery
- [restricted-network.md](restricted-network.md) — when the target VPS has limited outbound (every layer above gets harder, especially Rule 13)
