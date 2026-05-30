# Proposal — resumable `mvpool-local deploy`

**Status:** proposed (2026-05-25) — pending framework-dev pickup
**Driver:** Iran→Hetzner SSH flakiness causes 30-50% of Mizro deploys to fail
mid-pipeline. Today the only recovery is "re-run from step 1" — losing the
5-10 min Hetzner build every time, even when only the laptop→pagio ship
broke. See `digital-menu/deploy/docs/lessons-learned.md` §24-§26.

## What we get

A `mvpool-local deploy <slug>` that resumes from the last successful
checkpoint when re-run, as long as the source hasn't changed. Network
hiccups become cheap retries instead of full rebuilds.

## Pipeline checkpoints (full-stack-queue, tarball mode)

| # | Step | Idempotency check (skip if true) |
|---|------|---|
| 1 | Sync source laptop → Hetzner | `rsync --partial` already partial-resumes; checkpoint = source-fingerprint matches `<slug>.source.fingerprint` on Hetzner |
| 2 | Build image on Hetzner | buildx cache already resumes mid-build; checkpoint = `docker images registry.pagio.ir/<slug>:<tag>` exists on Hetzner |
| 3 | Save tarball on Hetzner | `/srv/build/<slug>/images/<tag>.tar.zst` exists with non-zero size |
| 4 | Ship Hetzner → laptop | `~/Library/Caches/mvpool-local/<slug>-<tag>.tar.zst` exists + sha256 matches Hetzner copy |
| 5 | Ship laptop → pagio | `/srv/apps/<slug>/images/<tag>.tar.zst` exists on pagio + sha256 matches |
| 6 | Load image on pagio | `docker images <slug>:<tag>` exists on pagio |
| 7 | Update compose tag on pagio | `/srv/apps/<slug>/compose.yaml` references `<tag>` for all build slug services |
| 8 | Recreate containers | all build-slug services running on `<tag>` |
| 9 | Migrate (full-stack-queue only) | always re-run — drizzle is idempotent |
| 10 | Verify final health | always re-run |

Steps 1-8 are checkpoint-gated. Steps 9-10 always run.

## Checkpoint state

Path: `~/.local/share/mvpool-local/state/<slug>.json`

```json
{
  "tag": "87c5995",
  "source_fingerprint": "<sha1 of: git rev-parse HEAD + git status --porcelain>",
  "completed_steps": ["sync_source", "build_image", "save_tarball", "ship_to_laptop"],
  "started_at": "2026-05-25T10:15:42Z",
  "last_step_at": "2026-05-25T10:21:33Z",
  "build_host": "hetzner",
  "deploy_host": "pagio"
}
```

Each step writes its checkpoint **after** its idempotency check passes
(not just "ran without error" — the file/container must actually exist).

## Invalidation rules

- `source_fingerprint` doesn't match current source → **restart from step 1**
- `tag` doesn't match what would-be-computed → **restart from step 1**
- `last_step_at` > 24h ago → warn + prompt "resume or fresh?"
- Step's idempotency check fails (file deleted, image removed) → silently re-run that step + write checkpoint

The source-fingerprint covers the user's explicit ask: *"resume if source
unchanged, restart on local edits or branch update."*

## CLI surface

```bash
mvpool-local deploy <slug>             # auto: resume if valid checkpoint, else fresh
mvpool-local deploy <slug> --fresh     # ignore checkpoint, restart from step 1
mvpool-local deploy <slug> --from <N>  # manual skip-ahead (debugging escape hatch)
mvpool-local status <slug>             # show checkpoint state + next step on retry
```

`status` prints:
```
slug: mizro
tag: 87c5995
source: clean (HEAD=87c5995, dirty=false)
fingerprint: match (resume eligible)
completed: sync_source, build_image, save_tarball, ship_to_laptop
next on retry: ship_to_pagio
last activity: 4m ago
```

## Source fingerprint — scope decision

The fingerprint must reflect whatever influences the build. Two options:

- **Whole repo** (simple, conservative): `sha1(git HEAD + git status --porcelain)`. Any uncommitted change anywhere invalidates the checkpoint. Safe but over-eager for monorepos.
- **Build-context subtree** (precise): fingerprint only the dirs declared in the slug's build context (e.g. Mizro api builds from `apps/api/` + `packages/*`). Skips false-positive invalidation when an unrelated dir changes.

**Recommendation:** ship "whole repo" first. Monorepo precision is a Phase 2 enhancement when someone hits the false-positive case. Don't gold-plate.

## Concurrent deploys

Lock file at `~/.local/share/mvpool-local/state/<slug>.lock` (PID + start time). If a second `deploy` of the same slug starts while one is running:
- Default: **fail loudly** with "deploy <pid> already running, started <X>m ago — kill with `mvpool-local cancel <slug>` or wait."
- `--force` flag removes the lock (escape hatch for stale locks after crashes).

## Out of scope

- Multi-host parallel deploys (one slug, two pool hosts) — not a current pattern
- Atomic rollback on partial failure — separate proposal
- `seed` cmd resumability — only run once per deploy; not worth checkpointing
- Builds from sources other than git (tarball-of-source) — current mvpool design assumes git

## Implementation hand-up

Roughly a 1-2 day senior task in `deploy/bin/mvpool-local`:
1. Add `state/` module: read/write JSON, compute fingerprint, lock file
2. Wrap each existing pipeline step in `with_checkpoint(step_name) { ... }` that runs the idempotency check first
3. Add `--fresh`, `--from`, `status` subcommand
4. Backwards compatible: missing state file → behaves like today (fresh deploy)

Reference incident log: `/Users/pixparker/repo/mvp/digital-menu/deploy/docs/lessons-learned.md` §24-§26.
