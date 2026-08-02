import { createHmac } from 'node:crypto'
import http from 'node:http'
import type { AddressInfo } from 'node:net'
import { describe, expect, it } from 'vitest'
import { createHarness } from '../src/harness/index.ts'
import { QMHTTPHarness, QMSSEParser, canonicalPayload, signRequest } from '../src/harness/qm-http.ts'
import type { QMTurnResultWire } from '../src/harness/qm-http.ts'
import type { HarnessTurnEvent, QMHarnessTurnInput } from '../src/harness/types.ts'
import { MuError } from '../src/errors.ts'
import { startMockQMServer } from './support/mock-qm-server.ts'

const SECRET = 'test-source-secret-abcdefghijklmnopqrstuvwxyz-0123456789'

function harnessFor(baseURL: string, overrides: Partial<ConstructorParameters<typeof QMHTTPHarness>[0]> = {}): QMHTTPHarness {
  return new QMHTTPHarness({ baseURL, sourceSecret: SECRET, surface: 'mu', ...overrides })
}

function qmInput(overrides: Partial<QMHarnessTurnInput> = {}): QMHarnessTurnInput {
  return {
    surface: 'mu',
    actor: { externalId: 'actor-1', displayName: 'Mu Agent', isBot: true },
    conversation: { kind: 'direct', threadRef: 'mu-thread-1' },
    text: 'Analyze the renderer.',
    ...overrides,
  }
}

async function collect(harness: QMHTTPHarness, input: QMHarnessTurnInput) {
  const events: HarnessTurnEvent[] = []
  for await (const event of harness.runTurn({ qm: input })) {
    events.push(event)
  }
  return events
}

// ---------------------------------------------------------------------------
// Signature
// ---------------------------------------------------------------------------

describe('QM source signature', () => {
  it('produces v0=hex(hmac-sha256(secret, "v0:ts:method\\npath?query\\nbody"))', () => {
    const secret = SECRET
    const timestamp = 1_700_000_000
    const canonical = 'POST\n/v1/turns\n{"text":"hi"}'
    const expected = createHmac('sha256', secret)
      .update(`v0:${timestamp}:${canonical}`)
      .digest('hex')
    expect(signRequest(secret, timestamp, canonical)).toBe(`v0=${expected}`)
    expect(canonicalPayload('POST', '/v1/turns', '{"text":"hi"}')).toBe(canonical)
  })
})

// ---------------------------------------------------------------------------
// QMSSEParser
// ---------------------------------------------------------------------------

describe('QMSSEParser', () => {
  it('parses event/data blocks and ignores comments and heartbeats', () => {
    const parser = new QMSSEParser()
    const events = parser.consume(Buffer.from(': open\n\nevent: session_state\ndata: {"sessionId":"run-1","state":"working"}\n\n: ping\n\n'))
    expect(events).toHaveLength(1)
    expect(events[0]?.sessionID).toBe('run-1')
    expect(events[0]?.state).toBe('working')
    expect(parser.finish()).toEqual([])
  })

  it('handles CRLF and chunked blocks', () => {
    const parser = new QMSSEParser()
    const first = parser.consume('event: session_state\r\ndata: {"sessionId":"run-2"}\r\n\r\nevent: ses')
    expect(first).toHaveLength(1)
    expect(first[0]?.sessionID).toBe('run-2')
    const rest = parser.consume('sion_state\ndata: {"state":"completed"}\n\n')
    expect(rest).toHaveLength(1)
    expect(rest[0]?.state).toBe('completed')
  })

  it('flushes a trailing block on finish', () => {
    const parser = new QMSSEParser()
    expect(parser.consume('event: session_state\ndata: {"sessionId":"run-3"}')).toEqual([])
    const flushed = parser.finish()
    expect(flushed).toHaveLength(1)
    expect(flushed[0]?.sessionID).toBe('run-3')
  })

  it('surfaces non-JSON data as raw payload', () => {
    const parser = new QMSSEParser()
    const events = parser.consume('event: note\ndata: plain text\n\n')
    expect(events[0]?.payload).toEqual({ raw: 'plain text' })
  })
})

// ---------------------------------------------------------------------------
// QMHTTPHarness
// ---------------------------------------------------------------------------

describe('QMHTTPHarness', () => {
  it('probe verifies reachability and source auth', async () => {
    const mock = await startMockQMServer({ secret: SECRET })
    try {
      const harness = harnessFor(mock.baseURL)
      const result = await harness.probe()
      expect(result.ok).toBe(true)
      expect(result.message).toContain('source auth verified')
      expect(mock.requests).toContain('GET /v1/runs')
    } finally {
      await mock.close()
    }
  })

  it('probe fails when the server rejects the signature', async () => {
    const mock = await startMockQMServer({ secret: 'another-secret-that-does-not-match-000000' })
    try {
      const harness = harnessFor(mock.baseURL)
      const result = await harness.probe()
      expect(result.ok).toBe(false)
      expect(result.message).toContain('401/403')
    } finally {
      await mock.close()
    }
  })

  it('probe fails on a weak signing secret', async () => {
    const harness = harnessFor('http://127.0.0.1:1', { sourceSecret: 'short' })
    const result = await harness.probe()
    expect(result.ok).toBe(false)
    expect(result.message).toContain('32 characters')
  })

  it('streams a successful turn with reply text', async () => {
    const mock = await startMockQMServer({
      secret: SECRET,
      turnHandler: () => ({ status: 200, body: { status: 'ok', reply: 'The renderer is fine.', runId: 'run-42', sessionId: 'sess-42' } }),
    })
    try {
      const harness = harnessFor(mock.baseURL)
      const events = await collect(harness, qmInput())
      expect(events[0]).toEqual({ kind: 'session_started', sessionID: 'run-42' })
      expect(events[1]).toEqual({ kind: 'visible_text', text: 'The renderer is fine.' })
      const terminal = events.at(-1)
      expect(terminal?.kind).toBe('completed')
      if (terminal?.kind === 'completed') {
        expect(terminal.result.status).toBe('success')
        expect(terminal.result.output).toBe('The renderer is fine.')
        expect(terminal.result.sessionID).toBe('run-42')
        expect(terminal.result.runID).toBe('run-42')
      }
      expect(mock.requests).toContain('POST /v1/turns')
    } finally {
      await mock.close()
    }
  })

  it('maps refused turns to a failed result with the reason', async () => {
    const mock = await startMockQMServer({
      secret: SECRET,
      turnHandler: () => ({ status: 403, body: { status: 'refused', reason: 'security quarantine' } }),
    })
    try {
      const harness = harnessFor(mock.baseURL)
      const events = await collect(harness, qmInput())
      const terminal = events.at(-1)
      expect(terminal?.kind).toBe('completed')
      if (terminal?.kind === 'completed') {
        expect(terminal.result.status).toBe('failed')
        expect(terminal.result.errorMessage).toBe('security quarantine')
      }
    } finally {
      await mock.close()
    }
  })

  it('emits pending_approval events for approval-requiring turns', async () => {
    const mock = await startMockQMServer({
      secret: SECRET,
      turnHandler: () => ({
        status: 200,
        body: {
          status: 'pending_approval',
          runId: 'run-7',
          reply: 'Needs approval',
          pendingApprovals: [{ requestId: 'req-1', command: 'Bash', reason: 'command execution' }],
        },
      }),
    })
    try {
      const harness = harnessFor(mock.baseURL)
      const events = await collect(harness, qmInput())
      expect(events.some((e) => e.kind === 'pending_approval')).toBe(true)
      const terminal = events.at(-1)
      expect(terminal?.kind).toBe('completed')
      if (terminal?.kind === 'completed') {
        expect(terminal.result.status).toBe('pending_approval')
        expect(terminal.result.pendingApprovals?.[0]).toEqual({
          requestID: 'req-1',
          command: 'Bash',
          reason: 'command execution',
          purpose: undefined,
          summary: undefined,
          blocksInput: undefined,
        })
      }
    } finally {
      await mock.close()
    }
  })

  it('handles async queued turns', async () => {
    const mock = await startMockQMServer({
      secret: SECRET,
      turnHandler: () => ({ status: 202, body: { status: 'queued', runId: 'run-queued' } }),
    })
    try {
      const harness = harnessFor(mock.baseURL)
      const events = await collect(harness, qmInput({ async: true }))
      const terminal = events.at(-1)
      expect(terminal?.kind).toBe('completed')
      if (terminal?.kind === 'completed') {
        expect(terminal.result.status).toBe('queued')
        expect(terminal.result.runID).toBe('run-queued')
      }
    } finally {
      await mock.close()
    }
  })

  it('rejects source-auth failures on turns', async () => {
    const mock = await startMockQMServer({ secret: 'wrong-secret-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' })
    try {
      const harness = harnessFor(mock.baseURL)
      const events = await collect(harness, qmInput())
      expect(events.at(-1)).toEqual({ kind: 'failed', errorMessage: 'QM source authentication rejected (401/403).' })
    } finally {
      await mock.close()
    }
  })

  it('requires qm input in QM mode', async () => {
    const harness = harnessFor('http://127.0.0.1:1')
    await expect(
      (async () => {
        for await (const _event of harness.runTurn({})) {
          // never reached
        }
      })(),
    ).rejects.toThrow(MuError)
  })

  it('interrupt sends an abort signal to the run', async () => {
    const mock = await startMockQMServer({ secret: SECRET })
    try {
      const harness = harnessFor(mock.baseURL)
      await harness.interrupt('run-99')
      expect(mock.signals).toEqual([{ runID: 'run-99', body: { kind: 'abort' } }])
    } finally {
      await mock.close()
    }
  })

  it('interrupt fails for an unknown run', async () => {
    const mock = await startMockQMServer({
      secret: SECRET,
      signalHandler: () => ({ status: 404, body: { error: 'not_found' } }),
    })
    try {
      const harness = harnessFor(mock.baseURL)
      await expect(harness.interrupt('run-missing')).rejects.toThrow(MuError)
    } finally {
      await mock.close()
    }
  })

  it('listArtifacts maps turn attachments', async () => {
    const mock = await startMockQMServer({
      secret: SECRET,
      turnHandler: () => ({
        status: 200,
        body: {
          status: 'ok',
          runId: 'run-art',
          reply: 'Done',
          attachments: [
            { name: 'report.md', mimetype: 'text/markdown', sizeBytes: 42, artifactId: 'art-1' },
          ],
        } satisfies QMTurnResultWire,
      }),
    })
    try {
      const harness = harnessFor(mock.baseURL)
      await collect(harness, qmInput())
      const artifacts = await harness.listArtifacts('run-art')
      expect(artifacts).toEqual([
        { name: 'report.md', relativePath: 'report.md', kind: 'text/markdown', byteCount: 42, nativeRef: 'art-1' },
      ])
    } finally {
      await mock.close()
    }
  })

  it('subscribes to session-state SSE events', async () => {
    const mock = await startMockQMServer({
      secret: SECRET,
      sseEvents: [
        'event: session_state\ndata: {"sessionId":"run-1","state":"working"}',
        'event: session_state\ndata: {"sessionId":"run-1","state":"completed"}',
      ],
    })
    try {
      const harness = harnessFor(mock.baseURL)
      const abort = new AbortController()
      const events = []
      for await (const event of harness.subscribeSessionStates(abort.signal)) {
        events.push(event)
        if (events.length === 2) abort.abort()
      }
      expect(events).toHaveLength(2)
      expect(events[0]?.sessionID).toBe('run-1')
      expect(events[0]?.state).toBe('working')
      expect(events[1]?.state).toBe('completed')
    } finally {
      await mock.close()
    }
  })
})

// ---------------------------------------------------------------------------
// createHarness dispatcher
// ---------------------------------------------------------------------------

describe('createHarness', () => {
  it('builds a QM harness from configuration', () => {
    const harness = createHarness({ mode: 'qm', qm: { baseURL: 'http://localhost:8080', sourceSecret: SECRET } })
    expect(harness).toBeInstanceOf(QMHTTPHarness)
    expect(harness.capabilities.mode).toBe('qm')
  })

  it('builds a local harness from configuration', () => {
    const harness = createHarness({ mode: 'local' })
    expect(harness.capabilities.mode).toBe('local')
  })

  it('rejects a QM configuration without qm options', () => {
    expect(() => createHarness({ mode: 'qm' })).toThrow(MuError)
  })
})
