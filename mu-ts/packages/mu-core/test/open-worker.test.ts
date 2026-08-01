import { createServer, type Server } from 'node:http'
import type { AddressInfo } from 'node:net'
import { WebSocketServer, type WebSocket } from 'ws'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { MuError } from '../src/errors.ts'
import {
  applyOpenWorkerLiveTextEvent,
  createOpenWorkerClientConfiguration,
  createOpenWorkerLiveTextState,
  decodeOpenWorkerEvent,
  jsonString,
  jsonValueFromUnknown,
  jsonValueString,
  openWorkerEventReady,
  openWorkerEventSummary,
  openWorkerMessageText,
  OpenWorkerHTTPClient,
  OpenWorkerSessionBridge,
  parseOpenWorkerBaseURL,
} from '../src/runtime-clients/open-worker.ts'

// ---------------------------------------------------------------------------
// Pure logic
// ---------------------------------------------------------------------------

describe('OpenWorker event decoding', () => {
  it('decodes string frames with object data', () => {
    const event = decodeOpenWorkerEvent(
      JSON.stringify({ type: 'assistant_delta', data: { text: 'Hello' } }),
    )
    expect(event.type).toBe('assistant_delta')
    expect(jsonValueString(event.data['text']!)).toBe('Hello')
  })

  it('rejects malformed frames', () => {
    expect(() => decodeOpenWorkerEvent('not json')).toThrow(MuError)
    expect(() => decodeOpenWorkerEvent('{"data":{}}')).toThrow(MuError)
  })

  it('summarizes events', () => {
    expect(openWorkerEventSummary({ type: 'ready', data: {} })).toBe('Connected to OpenWorker session.')
    expect(
      openWorkerEventSummary({ type: 'tool_proposed', data: { name: jsonString('Bash') } }),
    ).toBe('OpenWorker proposed Bash.')
    expect(
      openWorkerEventSummary({ type: 'permission_required', data: { name: jsonString('write') } }),
    ).toBe('Approval required for write.')
    expect(
      openWorkerEventSummary({ type: 'error', data: { error: jsonString('boom') } }),
    ).toBe('OpenWorker: boom')
    expect(openWorkerEventSummary({ type: 'mystery_event', data: {} })).toBe(
      'OpenWorker event: mystery event.',
    )
  })

  it('extracts ready payloads', () => {
    const event = decodeOpenWorkerEvent(
      JSON.stringify({
        type: 'ready',
        data: { session_id: 's1', agent: 'cowork', model: 'm', mode: 'interactive', workspace: '/w' },
      }),
    )
    expect(openWorkerEventReady(event)).toEqual({
      sessionID: 's1',
      agent: 'cowork',
      model: 'm',
      mode: 'interactive',
      workspace: '/w',
    })
    expect(openWorkerEventReady({ type: 'turn_start', data: {} })).toBeUndefined()
  })
})

describe('OpenWorkerLiveTextState', () => {
  it('accumulates deltas and finalizes on assistant_message', () => {
    let state = createOpenWorkerLiveTextState()
    state = applyOpenWorkerLiveTextEvent(state, { type: 'turn_start', data: {} })
    state = applyOpenWorkerLiveTextEvent(state, { type: 'assistant_delta', data: { text: jsonString('Hel') } })
    state = applyOpenWorkerLiveTextEvent(state, { type: 'assistant_delta', data: { text: jsonString('lo') } })
    expect(state.text).toBe('Hello')
    expect(state.isFinalized).toBe(false)
    state = applyOpenWorkerLiveTextEvent(state, {
      type: 'assistant_message',
      data: { text: jsonString('Hello world') },
    })
    expect(state.text).toBe('Hello world')
    expect(state.isFinalized).toBe(true)
    // Deltas after finalization are rejected.
    state = applyOpenWorkerLiveTextEvent(state, { type: 'assistant_delta', data: { text: jsonString('!') } })
    expect(state.text).toBe('Hello world')
  })

  it('finalizes on terminal events', () => {
    let state = createOpenWorkerLiveTextState()
    state = applyOpenWorkerLiveTextEvent(state, { type: 'assistant_delta', data: { text: jsonString('x') } })
    state = applyOpenWorkerLiveTextEvent(state, { type: 'turn_done', data: {} })
    expect(state.isFinalized).toBe(true)
  })
})

describe('OpenWorker message text', () => {
  it('extracts text from string, array, and notice messages', () => {
    expect(openWorkerMessageText({ role: 'user', content: jsonString('hi') })).toBe('hi')
    expect(
      openWorkerMessageText({
        role: 'assistant',
        content: {
          type: 'array',
          value: [
            { type: 'object', value: { text: jsonString('line one') } },
            { type: 'object', value: { text: jsonString('line two') } },
          ],
        },
      }),
    ).toBe('line one\nline two')
    expect(
      openWorkerMessageText({ role: 'notice', content: { type: 'null' }, kind: 'permission_denied' }),
    ).toBe('OpenWorker permission denied.')
    expect(
      openWorkerMessageText({ role: 'notice', content: { type: 'null' }, text: 'explicit notice' }),
    ).toBe('explicit notice')
  })
})

describe('OpenWorker config validation', () => {
  it('requires loopback http with a port', () => {
    expect(() => createOpenWorkerClientConfiguration({ baseURL: 'https://example.com' })).toThrow(MuError)
    expect(() => createOpenWorkerClientConfiguration({ baseURL: 'http://127.0.0.1' })).toThrow(MuError)
    expect(
      createOpenWorkerClientConfiguration({ baseURL: 'http://127.0.0.1:8080' }).baseURL,
    ).toBe('http://127.0.0.1:8080')
  })

  it('restricts tokenless access to 127.0.0.1', () => {
    expect(() =>
      createOpenWorkerClientConfiguration({ baseURL: 'http://localhost:8080' }),
    ).toThrow(MuError)
    expect(
      createOpenWorkerClientConfiguration({ baseURL: 'http://localhost:8080', token: 't' }).token,
    ).toBe('t')
    expect(
      createOpenWorkerClientConfiguration({ baseURL: 'http://127.0.0.1:8080' }).token,
    ).toBeUndefined()
  })
})

describe('parseOpenWorkerBaseURL', () => {
  it('extracts the last Uvicorn URL', () => {
    const log = [
      'INFO: Started server process [1]',
      'INFO: Uvicorn running on http://127.0.0.1:8080 (Press CTRL+C to quit)',
      'INFO: Application startup complete.',
      'INFO: Uvicorn running on http://127.0.0.1:8081 (Press CTRL+C to quit)',
    ].join('\n')
    expect(parseOpenWorkerBaseURL(log)).toBe('http://127.0.0.1:8081')
    expect(parseOpenWorkerBaseURL('no server here')).toBeUndefined()
  })
})

// ---------------------------------------------------------------------------
// HTTP client against a mock server
// ---------------------------------------------------------------------------

describe('OpenWorkerHTTPClient', () => {
  let server: Server
  let baseURL: string

  beforeEach(async () => {
    server = createServer((req, res) => {
      const url = req.url ?? ''
      res.setHeader('Content-Type', 'application/json')
      if (url.startsWith('/v1/health')) {
        res.end(JSON.stringify({ status: 'ok', default_workspace: '/workspace', model: 'm1' }))
      } else if (url.startsWith('/v1/agents')) {
        res.end(JSON.stringify({ agents: [{ name: 'coder', default: true }, { name: 'cowork' }] }))
      } else if (url.startsWith('/v1/sessions/s1/messages')) {
        res.end(JSON.stringify({ messages: [{ role: 'user', content: 'hello' }] }))
      } else if (url.startsWith('/v1/sessions/s1/artifacts')) {
        res.end(JSON.stringify({ artifacts: [{ path: 'out.txt', name: 'out.txt', kind: 'file', size: 3, modified_at: 123 }] }))
      } else if (url.startsWith('/v1/sessions')) {
        res.end(JSON.stringify({
          sessions: [
            { session_id: 's1', workspace: '/w', agent: 'coder', model: 'm1', mode: 'interactive', messages: 2, updated_at: '2025-07-13T19:07:45Z' },
          ],
        }))
      } else if (url.startsWith('/v1/sessions')) {
        res.end(JSON.stringify({
          sessions: [
            { session_id: 's1', workspace: '/w', agent: 'coder', model: 'm1', mode: 'interactive', messages: 2, updated_at: '2025-07-13T19:07:45Z' },
          ],
        }))
      } else if (url.startsWith('/v1/inbox') && req.method === 'GET') {
        res.end(JSON.stringify({ items: [{ id: 'i1', session_id: 's1', kind: 'permission', title: '', body: 'b', state: 'pending', visibility: 'inbox', options: [], allow_text: true, multi: false, data: {} }] }))
      } else if (url.startsWith('/v1/inbox/i1/resolve') && req.method === 'POST') {
        res.end(JSON.stringify({ ok: true }))
      } else {
        res.statusCode = 404
        res.end('{}')
      }
    })
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
    baseURL = `http://127.0.0.1:${(server.address() as AddressInfo).port}`
  })

  afterEach(() => {
    server.close()
  })

  it('probes health, agents, and sessions', async () => {
    const client = new OpenWorkerHTTPClient(createOpenWorkerClientConfiguration({ baseURL }))
    const result = await client.probe()
    expect(result.status).toBe('ok')
    expect(result.defaultWorkspace).toBe('/workspace')
    expect(result.defaultAgent).toBe('coder')
    expect(result.sessionCount).toBe(1)
  })

  it('reads messages, artifacts, and resolves inbox items', async () => {
    const client = new OpenWorkerHTTPClient(createOpenWorkerClientConfiguration({ baseURL }))
    const messages = await client.messages('s1')
    expect(openWorkerMessageText(messages[0]!)).toBe('hello')
    const artifacts = await client.artifacts('s1')
    expect(artifacts[0]!.path).toBe('out.txt')
    const inbox = await client.pendingInbox('s1')
    expect(inbox[0]!.id).toBe('i1')
    expect(inboxTitleForTest(inbox[0]!)).toBe('permission')
    expect(await client.resolveInbox('i1', 'approved')).toBe(true)
  })
})

function inboxTitleForTest(item: { kind: string; title: string }): string {
  return item.title === '' ? item.kind : item.title
}

// ---------------------------------------------------------------------------
// WebSocket bridge against a mock WS server
// ---------------------------------------------------------------------------

describe('OpenWorkerSessionBridge', () => {
  let wss: WebSocketServer
  let port: number
  let received: Array<Record<string, unknown>> = []

  beforeEach(async () => {
    received = []
    wss = new WebSocketServer({ port: 0, host: '127.0.0.1' })
    await new Promise<void>((resolve) => wss.once('listening', resolve))
    port = (wss.address() as AddressInfo).port
    wss.on('connection', (socket: WebSocket) => {
      socket.on('message', (data) => {
        received.push(JSON.parse(data.toString()))
      })
      // Acknowledge the session immediately.
      socket.send(JSON.stringify({
        type: 'ready',
        data: { session_id: 's1', agent: 'cowork', model: 'm', mode: 'interactive', workspace: '/workspace' },
      }))
    })
  })

  afterEach(async () => {
    for (const client of wss.clients) {
      client.terminate()
    }
    await new Promise<void>((resolve) => wss.close(() => resolve()))
  })

  it('connects, streams batched deltas, and receives the final message', async () => {
    const events: Array<{ type: string; text?: string }> = []
    const bridge = new OpenWorkerSessionBridge(
      createOpenWorkerClientConfiguration({ baseURL: `http://127.0.0.1:${port}` }),
      's1',
      '/workspace',
    )
    const ready = await bridge.connect((event) => {
      const text = event.data['text']
      events.push({
        type: event.type,
        text: text !== undefined && text.type === 'string' ? text.value : undefined,
      })
    })
    expect(ready.sessionID).toBe('s1')
    expect(events[0]?.type).toBe('ready')

    const serverSocket = [...wss.clients][0]!
    // Emit a stream of deltas, then the authoritative final.
    for (const chunk of ['Hello ', 'cruel ', 'world']) {
      serverSocket.send(JSON.stringify({ type: 'assistant_delta', data: { text: chunk } }))
    }
    await new Promise((resolve) => setTimeout(resolve, 120))
    serverSocket.send(JSON.stringify({
      type: 'assistant_message',
      data: { text: 'Hello world' },
    }))

    await new Promise((resolve) => setTimeout(resolve, 120))
    expect(events.filter((e) => e.type === 'assistant_delta')).toHaveLength(1)
    expect(events.find((e) => e.type === 'assistant_message')?.text).toBe('Hello world')
    bridge.disconnect()
  })

  it('sends user messages and approvals', async () => {
    const bridge = new OpenWorkerSessionBridge(
      createOpenWorkerClientConfiguration({ baseURL: `http://127.0.0.1:${port}` }),
      's1',
      '/workspace',
    )
    await bridge.connect(() => {})
    await bridge.sendUserMessage('do the thing')
    await bridge.approveOnce()
    await bridge.interrupt()
    // send() is fire-and-forget; give the server a moment to receive.
    await new Promise((resolve) => setTimeout(resolve, 50))
    expect(received).toEqual([
      { type: 'user_message', text: 'do the thing' },
      { type: 'approval', decision: 'once' },
      { type: 'interrupt' },
    ])
    bridge.disconnect()
  })

  it('rejects a different workspace in the handshake', async () => {
    const bridge = new OpenWorkerSessionBridge(
      createOpenWorkerClientConfiguration({ baseURL: `http://127.0.0.1:${port}` }),
      's1',
      '/other',
    )
    await expect(bridge.connect(() => {})).rejects.toThrow(MuError)
  })
})

describe('jsonValueFromUnknown', () => {
  it('converts plain JSON to tagged values', () => {
    const value = jsonValueFromUnknown({ a: 1, b: [true, null], c: 'x' })
    expect(value).toEqual({
      type: 'object',
      value: {
        a: { type: 'number', value: 1 },
        b: { type: 'array', value: [{ type: 'bool', value: true }, { type: 'null' }] },
        c: { type: 'string', value: 'x' },
      },
    })
  })
})
