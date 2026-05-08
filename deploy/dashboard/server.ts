/**
 * mvpool-dashboard — read-only deploy dashboard.
 *
 * Reads /srv/build/.deploys/deployments.jsonl (append-only, written by
 * mvpool-local on each deploy) and serves a small HTML+Alpine UI plus a
 * thin JSON API. Listens on 127.0.0.1 by default — expose via SSH tunnel
 * (`ssh -L 8080:localhost:3030 hetzner`) or front with Caddy basic_auth.
 *
 * Run:   bun server.ts
 * Env:   MVPOOL_DEPLOYS_JSONL  override log path (default /srv/build/.deploys/deployments.jsonl)
 *        PORT                  default 3030
 *        HOST                  default 127.0.0.1
 */

import { Hono } from 'hono'
import { existsSync } from 'node:fs'
import { stat } from 'node:fs/promises'

const LOG_PATH = process.env.MVPOOL_DEPLOYS_JSONL ?? '/srv/build/.deploys/deployments.jsonl'
const PORT     = Number(process.env.PORT ?? 3030)
const HOST     = process.env.HOST ?? '127.0.0.1'
const PUBLIC   = `${import.meta.dir}/public`

type Status = 'pending' | 'delivering' | 'live' | 'failed'

interface DeployRecord {
  ts: string
  slug: string
  env: string
  base: string
  tag: string
  status: Status
  actor?: string
  mode?: string
  build_host?: string
  target_host?: string
  url?: string
  job_id?: string
}

async function readDeploys(): Promise<DeployRecord[]> {
  if (!existsSync(LOG_PATH)) return []
  const text = await Bun.file(LOG_PATH).text()
  const out: DeployRecord[] = []
  for (const raw of text.split('\n')) {
    const line = raw.trim()
    if (!line) continue
    try { out.push(JSON.parse(line) as DeployRecord) } catch { /* skip malformed */ }
  }
  return out
}

const ENV_ORDER: Record<string, number> = { prod: 0, staging: 1, qa: 2, lab: 3 }

function liveSnapshot(records: DeployRecord[]) {
  const bySlug = new Map<string, DeployRecord[]>()
  for (const r of records) {
    let arr = bySlug.get(r.slug)
    if (!arr) { arr = []; bySlug.set(r.slug, arr) }
    arr.push(r)
  }

  const rows: Array<{
    slug: string
    base: string
    env: string
    live_tag: string | null
    live_ts: string | null
    live_actor: string | null
    url: string | null
    inflight: DeployRecord | null
  }> = []

  for (const [slug, history] of bySlug) {
    history.sort((a, b) => a.ts.localeCompare(b.ts))
    const live = [...history].reverse().find(r => r.status === 'live') ?? null
    const last = history[history.length - 1] ?? null
    const inflight = last && last !== live && last.status !== 'live' ? last : null
    rows.push({
      slug,
      base:       live?.base   ?? last?.base   ?? slug,
      env:        live?.env    ?? last?.env    ?? 'prod',
      live_tag:   live?.tag    ?? null,
      live_ts:    live?.ts     ?? null,
      live_actor: live?.actor  ?? null,
      url:        live?.url    ?? last?.url    ?? null,
      inflight,
    })
  }

  rows.sort((a, b) =>
    a.base.localeCompare(b.base) ||
    (ENV_ORDER[a.env] ?? 9) - (ENV_ORDER[b.env] ?? 9))
  return rows
}

const app = new Hono()

app.get('/healthz', c => c.text('ok'))

app.get('/api/deploys', async c => {
  const limit = Math.max(1, Math.min(Number(c.req.query('limit') ?? 50) || 50, 500))
  const recs = await readDeploys()
  return c.json(recs.slice(-limit).reverse())
})

app.get('/api/slugs', async c => {
  const recs = await readDeploys()
  return c.json(liveSnapshot(recs))
})

app.get('/api/slugs/:slug/history', async c => {
  const slug = c.req.param('slug')
  const limit = Math.max(1, Math.min(Number(c.req.query('limit') ?? 20) || 20, 200))
  const recs = await readDeploys()
  return c.json(recs.filter(r => r.slug === slug).slice(-limit).reverse())
})

app.get('/api/meta', async _c => {
  let log_mtime: string | null = null
  let log_size = 0
  try {
    const s = await stat(LOG_PATH)
    log_mtime = s.mtime.toISOString()
    log_size  = s.size
  } catch { /* file may not exist yet */ }
  return Response.json({
    log_path: LOG_PATH,
    log_mtime,
    log_size,
    server_time: new Date().toISOString(),
  })
})

app.get('/', () =>
  new Response(Bun.file(`${PUBLIC}/index.html`), {
    headers: { 'content-type': 'text/html; charset=utf-8' }
  }))

app.get('/favicon.ico', () => new Response(null, { status: 204 }))

console.log(`mvpool-dashboard listening on http://${HOST}:${PORT} (log=${LOG_PATH})`)

export default {
  port: PORT,
  hostname: HOST,
  fetch: app.fetch,
}
