import { useEffect, useState } from 'react'

interface Version {
  tag: string
  build_time: string
  node_version: string
  uptime_s: number
}

interface EchoResp {
  ok: boolean
  ts: string
  rtt_ms: number
}

export default function App() {
  const [version, setVersion] = useState<Version | null>(null)
  const [count, setCount] = useState(0)
  const [echo, setEcho] = useState<{ rtt_ms: number; ok: boolean } | null>(null)
  const [echoing, setEchoing] = useState(false)
  const [perf, setPerf] = useState<{ ttfb: number; loaded: number } | null>(null)

  useEffect(() => {
    fetch('/api/version').then(r => r.json()).then(setVersion).catch(() => {})

    if (typeof window !== 'undefined' && window.performance) {
      const nav = performance.getEntriesByType('navigation')[0] as PerformanceNavigationTiming | undefined
      if (nav) {
        setPerf({
          ttfb: Math.round(nav.responseStart - nav.requestStart),
          loaded: Math.round(nav.loadEventEnd - nav.startTime),
        })
      }
    }
  }, [])

  const ping = async () => {
    setEchoing(true)
    const t0 = performance.now()
    try {
      const r = await fetch('/api/echo')
      const data: EchoResp = await r.json()
      const rtt = Math.round(performance.now() - t0)
      setEcho({ rtt_ms: rtt, ok: data.ok })
    } catch {
      setEcho({ rtt_ms: -1, ok: false })
    } finally {
      setEchoing(false)
    }
  }

  return (
    <main>
      <header>
        <span className="kbd">mvp-pool · react-app</span>
        <h1>React on <em>mvp-pool</em></h1>
        <p className="lede">
          Vite + React + TypeScript + Hono, deployed via the build-on-Hetzner
          pipeline. Reload to see fresh numbers after each deploy.
        </p>
      </header>

      <section className="card">
        <h2>build info</h2>
        {!version && <p className="muted">loading…</p>}
        {version && (
          <dl>
            <dt>tag</dt><dd className="mono">{version.tag}</dd>
            <dt>built</dt><dd className="mono">{version.build_time}</dd>
            <dt>node</dt><dd className="mono">{version.node_version}</dd>
            <dt>uptime</dt><dd className="mono">{Math.round(version.uptime_s)}s</dd>
          </dl>
        )}
      </section>

      <section className="card">
        <h2>page perf (this load)</h2>
        {!perf && <p className="muted">no navigation timing available</p>}
        {perf && (
          <dl>
            <dt>TTFB</dt><dd className="mono">{perf.ttfb} ms</dd>
            <dt>loaded</dt><dd className="mono">{perf.loaded} ms</dd>
          </dl>
        )}
      </section>

      <section className="card">
        <h2>react alive?</h2>
        <p className="muted">click the button to confirm hooks/state work end-to-end.</p>
        <button onClick={() => setCount(c => c + 1)}>count is {count}</button>
      </section>

      <section className="card">
        <h2>server roundtrip</h2>
        <p className="muted">
          fetch <code>/api/echo</code> from the React bundle. Hits the in-container
          Hono server. Numbers reflect Iran-VPS↔visitor network, not just
          local rendering.
        </p>
        <button onClick={ping} disabled={echoing}>
          {echoing ? 'pinging…' : 'ping /api/echo'}
        </button>
        {echo && (
          <p className={echo.ok ? 'ok' : 'err'}>
            {echo.ok ? '✓' : '✗'} rtt = <span className="mono">{echo.rtt_ms === -1 ? 'failed' : echo.rtt_ms + ' ms'}</span>
          </p>
        )}
      </section>

      <footer>
        <a href="/api/version">/api/version</a>
        <span>·</span>
        <a href="/health">/health</a>
        <span>·</span>
        <a href="/api/echo">/api/echo</a>
      </footer>
    </main>
  )
}
