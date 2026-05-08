// Tiny Hono server that:
//   - serves the Vite-built React bundle from /app/dist (with sane cache
//     headers — long for hashed assets, none for index.html)
//   - exposes /health for the framework's compose healthcheck
//   - exposes /api/version + /api/echo for the React app to call
//
// Image: node:22-alpine. Listens on PORT (default 4000).
//
// IMAGE_TAG and BUILD_TIME baked in via the Dockerfile from
// `mvpool-local --build-on hetzner`, so the React app can render them.

import { Hono } from 'hono'
import { serve } from '@hono/node-server'
import { readFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { extname } from 'node:path'

const PORT       = Number(process.env.PORT ?? process.env.API_PORT ?? 4000)
const HOST       = process.env.HOST ?? '0.0.0.0'
const DIST       = process.env.DIST_DIR ?? '/app/dist'
const STARTED_AT = Date.now()
const TAG        = process.env.IMAGE_TAG ?? 'unversioned'
const BUILD_TIME = process.env.BUILD_TIME ?? ''

const MIME: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js':   'application/javascript; charset=utf-8',
  '.mjs':  'application/javascript; charset=utf-8',
  '.css':  'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg':  'image/svg+xml',
  '.png':  'image/png',
  '.jpg':  'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif':  'image/gif',
  '.ico':  'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.txt':  'text/plain; charset=utf-8',
}

const app = new Hono()

app.get('/health', (c) => c.text('ok', 200))

app.get('/api/version', (c) =>
  c.json({
    tag: TAG,
    build_time: BUILD_TIME,
    node_version: process.version,
    platform: `${process.platform}/${process.arch}`,
    uptime_s: (Date.now() - STARTED_AT) / 1000,
  }))

app.get('/api/echo', (c) =>
  c.json({
    ok: true,
    ts: new Date().toISOString(),
    remote: c.req.header('x-real-ip') ?? c.req.header('x-forwarded-for') ?? '',
  }))

// Long-cache hashed assets (Vite emits files like /assets/index-a1b2c3.js).
app.get('/assets/*', async (c) => serveFile(c, c.req.path, true))

// Anything else: try the requested file, fall back to index.html for SPA routes.
app.get('*', async (c) => {
  // Specific file first (favicon, robots.txt, etc.)
  const direct = await tryFile(`${DIST}${c.req.path}`)
  if (direct) {
    return new Response(toUint8Array(direct), {
      headers: {
        'Content-Type': MIME[extname(c.req.path)] ?? 'application/octet-stream',
        'Cache-Control': 'no-cache',
      },
    })
  }
  // SPA fallback
  const indexPath = `${DIST}/index.html`
  if (!existsSync(indexPath)) return c.text('build artifacts missing', 500)
  const html = await readFile(indexPath, 'utf8')
  return c.html(html)
})

async function tryFile(path: string): Promise<Buffer | null> {
  if (!existsSync(path)) return null
  try { return await readFile(path) } catch { return null }
}

// Buffer -> Uint8Array view that Response accepts everywhere (Node + edge).
function toUint8Array(buf: Buffer): Uint8Array {
  return new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength)
}

async function serveFile(c: any, urlPath: string, immutable: boolean) {
  const buf = await tryFile(`${DIST}${urlPath}`)
  if (!buf) return c.notFound()
  return new Response(toUint8Array(buf), {
    headers: {
      'Content-Type': MIME[extname(urlPath)] ?? 'application/octet-stream',
      'Cache-Control': immutable
        ? 'public, max-age=31536000, immutable'
        : 'no-cache',
    },
  })
}

console.log(`react-app server listening on http://${HOST}:${PORT}`)
console.log(`  tag=${TAG}  build_time=${BUILD_TIME}  dist=${DIST}`)

serve({ fetch: app.fetch, port: PORT, hostname: HOST })
