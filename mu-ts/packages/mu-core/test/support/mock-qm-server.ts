import { createHmac } from 'node:crypto'
import http from 'node:http'
import type { AddressInfo } from 'node:net'

// ---------------------------------------------------------------------------
// Mock QM server for harness and control-plane tests. Verifies the source
// HMAC signature (x-timestamp + x-signature over the raw body) and serves
// the /v1/turns, /v1/runs, and /v1/session-state/events endpoints.
// ---------------------------------------------------------------------------

export interface MockQMServerOptions {
  readonly secret: string
  turnHandler?: (body: unknown) => { status: number; body: unknown }
  signalHandler?: (runID: string, body: unknown) => { status: number; body: unknown }
  runsStatus?: number
  sseEvents?: string[]
}

export interface MockQMServer {
  readonly baseURL: string
  readonly signals: Array<{ runID: string; body: unknown }>
  readonly requests: string[]
  readonly close: () => Promise<void>
}

export function startMockQMServer(options: MockQMServerOptions): Promise<MockQMServer> {
  const signals: Array<{ runID: string; body: unknown }> = []
  const requests: string[] = []
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      const url = new URL(req.url ?? '/', 'http://localhost')
      const pathWithQuery = `${url.pathname}${url.search}`
      requests.push(`${req.method} ${pathWithQuery}`)
      const chunks: Buffer[] = []
      req.on('data', (chunk: Buffer) => chunks.push(chunk))
      req.on('end', () => {
        const body = Buffer.concat(chunks).toString('utf8')

        // Verify source auth: headers + signature over the raw body.
        const timestamp = Number(req.headers['x-timestamp'] ?? 0)
        const signature = String(req.headers['x-signature'] ?? '')
        const canonical = `${req.method ?? 'GET'}\n${pathWithQuery}\n${body}`
        const expected = `v0=${createHmac('sha256', options.secret)
          .update(`v0:${timestamp}:${canonical}`)
          .digest('hex')}`
        const authOK =
          Number.isFinite(timestamp)
          && Math.abs(Date.now() - timestamp * 1000) <= 5 * 60_000
          && signature === expected

        const send = (status: number, payload: unknown, headers: Record<string, string> = {}) => {
          res.writeHead(status, { 'content-type': 'application/json', ...headers })
          res.end(JSON.stringify(payload))
        }

        if (!authOK) {
          return send(401, { error: 'unauthorized', message: 'missing, invalid, or stale source-auth headers' })
        }

        if (req.method === 'GET' && url.pathname === '/v1/runs') {
          return send(options.runsStatus ?? 400, { error: 'bad_request', message: 'threadRef required' })
        }

        if (req.method === 'POST' && url.pathname === '/v1/turns') {
          let parsed: unknown = null
          try {
            parsed = JSON.parse(body)
          } catch {
            // fall through
          }
          const outcome = options.turnHandler?.(parsed)
          if (outcome !== undefined) return send(outcome.status, outcome.body)
          return send(200, { status: 'ok', reply: 'Hello from mock QM.', runId: 'run-1', sessionId: 'sess-1' })
        }

        const signalMatch = url.pathname.match(/^\/v1\/runs\/([^/]+)\/signal$/)
        if (req.method === 'POST' && signalMatch !== null) {
          let parsed: unknown = null
          try {
            parsed = JSON.parse(body)
          } catch {
            // fall through
          }
          signals.push({ runID: signalMatch[1]!, body: parsed })
          const outcome = options.signalHandler?.(signalMatch[1]!, parsed)
          if (outcome !== undefined) return send(outcome.status, outcome.body)
          return send(200, { ok: true })
        }

        if (req.method === 'GET' && url.pathname === '/v1/session-state/events') {
          res.writeHead(200, { 'content-type': 'text/event-stream; charset=utf-8', 'cache-control': 'no-cache' })
          res.write(': open\n\n')
          const events = options.sseEvents ?? []
          events.forEach((event, index) => {
            setTimeout(() => {
              if (res.writableEnded) return
              res.write(`${event}\n\n`)
              if (index === events.length - 1) res.end()
            }, 20 * (index + 1))
          })
          if (events.length === 0) setTimeout(() => res.end(), 20)
          return
        }

        send(404, { error: 'not_found' })
      })
    })
    server.listen(0, '127.0.0.1', () => {
      const address = server.address() as AddressInfo
      resolve({
        baseURL: `http://127.0.0.1:${address.port}`,
        signals,
        requests,
        close: () => new Promise<void>((res2, rej) => server.close((e) => (e ? rej(e) : res2()))),
      })
    })
  })
}
