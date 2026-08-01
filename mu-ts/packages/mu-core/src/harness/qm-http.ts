import { createHmac } from 'node:crypto'
import { MuError } from '../errors.ts'
import { provider } from '../types.ts'
import { qmTurnRequestForMu } from './qm-mapping.ts'
import type {
  Harness,
  HarnessArtifactRecord,
  HarnessCapabilities,
  HarnessPendingApproval,
  HarnessProbeResult,
  HarnessTurnEvent,
  HarnessTurnInput,
  HarnessTurnResult,
} from './types.ts'

// ---------------------------------------------------------------------------
// QM source authentication (byte-compatible with QM's source-auth-sign.ts:
//   signature = v0=hex(hmac-sha256(secret, "v0:<timestampSec>:<canonical>"))
//   canonical = "<method>\n<pathWithQuery>\n<body>"
// Headers: x-timestamp (unix seconds), x-signature. Replay window: 5 minutes.
// ---------------------------------------------------------------------------

export const SOURCE_AUTH_REPLAY_WINDOW_MS = 5 * 60_000
export const MIN_SIGNING_SECRET_LENGTH = 32

export function canonicalPayload(method: string, pathWithQuery: string, body: string): string {
  return `${method}\n${pathWithQuery}\n${body}`
}

export function signRequest(
  secret: string,
  timestampSec: number,
  canonical: string,
): string {
  return `v0=${createHmac('sha256', secret)
    .update(`v0:${timestampSec}:${canonical}`)
    .digest('hex')}`
}

export function signedRequestHeaders(
  secret: string,
  method: string,
  pathWithQuery: string,
  body = '',
  nowSec = Math.floor(Date.now() / 1000),
): Record<string, string> {
  const canonical = canonicalPayload(method, pathWithQuery, body)
  return {
    'x-timestamp': String(nowSec),
    'x-signature': signRequest(secret, nowSec, canonical),
  }
}

export function isStrongSigningSecret(secret: string | undefined): secret is string {
  return (secret?.trim().length ?? 0) >= MIN_SIGNING_SECRET_LENGTH
}

// ---------------------------------------------------------------------------
// QM wire types (subset of QM's TurnRequest / TurnResult / OutgoingAttachment)
// ---------------------------------------------------------------------------

export interface QMTurnRequestWire {
  readonly surface: string
  readonly actor: { externalId: string; displayName?: string; isBot?: boolean }
  readonly conversation: {
    readonly kind: string
    readonly threadRef: string
    readonly channelRef?: string
    readonly channelName?: string
    readonly isPrivate?: boolean
  }
  readonly text: string
  readonly origin?: { kind: 'automation'; screenData?: string }
  readonly model?: string
  readonly readOnly?: boolean
  readonly fastMode?: boolean
  readonly async?: boolean
  readonly idempotencyKey?: string
}

export interface QMTurnResultWire {
  readonly status: 'ok' | 'refused' | 'failed' | 'pending_approval' | 'queued' | 'silent' | 'react'
  readonly sessionId?: string
  readonly reply?: string
  readonly reason?: string
  readonly runId?: string
  readonly stopped?: boolean
  readonly pendingApprovals?: Array<{
    requestId: string
    command: string
    reason: string
    purpose?: string
    summary?: string
    blocksInput?: boolean
  }>
  readonly attachments?: Array<{
    name: string
    mimetype: string
    sizeBytes: number
    blobId?: string
    artifactId?: string
  }>
}

export interface QMSessionStateEvent {
  readonly sessionID?: string
  readonly state?: string
  readonly payload: Readonly<Record<string, unknown>>
}

// ---------------------------------------------------------------------------
// SSE parser (event:/data: blocks; comments and heartbeats ignored)
// ---------------------------------------------------------------------------

export class QMSSEParser {
  private buffer = ''
  private dataLines: string[] = []

  /** Consume a chunk; returns any complete events terminated by a blank line. */
  consume(chunk: Buffer | string): QMSessionStateEvent[] {
    this.buffer += typeof chunk === 'string' ? chunk : chunk.toString('utf8')
    const events: QMSessionStateEvent[] = []
    let separator: number
    while ((separator = this.buffer.search(/\r?\n\r?\n/)) !== -1) {
      const block = this.buffer.slice(0, separator)
      this.buffer = this.buffer.slice(separator + this.blockLength(separator))
      const event = this.parseBlock(block)
      if (event !== undefined) events.push(event)
    }
    return events
  }

  /** Flush a trailing partial block (missing final blank line). */
  finish(): QMSessionStateEvent[] {
    const rest = this.buffer
    this.buffer = ''
    if (rest.trim() === '') return []
    const event = this.parseBlock(rest)
    return event === undefined ? [] : [event]
  }

  private blockLength(separatorIndex: number): number {
    return this.buffer[separatorIndex + 1] === '\n' ? 2 : 1
  }

  private parseBlock(block: string): QMSessionStateEvent | undefined {
    this.dataLines = []
    for (const rawLine of block.split(/\r?\n/)) {
      const line = rawLine.startsWith(':') ? '' : rawLine // SSE comment
      if (line === '') continue
      if (line.startsWith('data:')) {
        this.dataLines.push(line.slice('data:'.length).trim())
      }
    }
    if (this.dataLines.length === 0) return undefined
    const data = this.dataLines.join('\n')
    let payload: Record<string, unknown>
    try {
      const parsed: unknown = JSON.parse(data)
      if (typeof parsed === 'object' && parsed !== null) {
        payload = parsed as Record<string, unknown>
      } else {
        payload = { raw: data }
      }
    } catch {
      // Non-JSON data payloads are surfaced as raw text.
      payload = { raw: data }
    }
    const sessionID = typeof payload['sessionId'] === 'string' ? payload['sessionId'] : undefined
    const state = typeof payload['state'] === 'string' ? payload['state'] : undefined
    return {
      ...(sessionID !== undefined ? { sessionID } : {}),
      ...(state !== undefined ? { state } : {}),
      payload,
    }
  }
}

// ---------------------------------------------------------------------------
// QM HTTP harness
// ---------------------------------------------------------------------------

export interface QMHTTPHarnessOptions {
  readonly baseURL: string
  readonly sourceSecret: string
  /** Default QM surface name. */
  readonly surface?: string
  /** Injectable fetch for tests. */
  readonly fetchImpl?: (input: string, init?: RequestInit) => Promise<Response>
  /** Injectable clock (unix seconds) for tests. */
  readonly nowSec?: () => number
}

export class QMHTTPHarness implements Harness {
  readonly capabilities: HarnessCapabilities

  private readonly baseURL: string
  private readonly sourceSecret: string
  private readonly surface: string
  private readonly fetchImpl: (input: string, init?: RequestInit) => Promise<Response>
  private readonly nowSec: () => number
  private readonly attachmentsBySession = new Map<string, QMTurnResultWire['attachments']>()

  constructor(options: QMHTTPHarnessOptions) {
    this.baseURL = options.baseURL.replace(/\/+$/, '')
    this.sourceSecret = options.sourceSecret
    this.surface = options.surface ?? 'mu'
    this.fetchImpl = options.fetchImpl ?? ((input, init) => fetch(input, init))
    this.nowSec = options.nowSec ?? (() => Math.floor(Date.now() / 1000))
    this.capabilities = {
      mode: 'qm',
      providers: [provider('qm')],
      controlMode: 'managed_limited',
      observationFidelity: 'mirrored_stream',
      supportsInterrupt: true,
      supportsArtifacts: true,
      supportsEventStream: true,
      notes: [
        'Executes turns through a QM server over HMAC-signed HTTP.',
        'interrupt(sessionID) addresses the QM run ID.',
        'Artifacts are the attachments returned by the latest turn.',
      ],
    }
  }

  private headers(method: string, pathWithQuery: string, body = ''): Record<string, string> {
    return {
      'content-type': 'application/json',
      ...signedRequestHeaders(this.sourceSecret, method, pathWithQuery, body, this.nowSec()),
    }
  }

  private url(pathWithQuery: string): string {
    return `${this.baseURL}${pathWithQuery}`
  }

  async probe(): Promise<HarnessProbeResult> {
    const startedAt = Date.now()
    const latency = () => Date.now() - startedAt
    if (!isStrongSigningSecret(this.sourceSecret)) {
      return {
        ok: false,
        mode: 'qm',
        message: `Signing secret must be at least ${MIN_SIGNING_SECRET_LENGTH} characters.`,
        latencyMilliseconds: latency(),
      }
    }
    // A signed GET without threadRef passes auth (→ 400) or fails auth (→ 401).
    try {
      const response = await this.fetchImpl(this.url('/v1/runs'), {
        method: 'GET',
        headers: this.headers('GET', '/v1/runs'),
      })
      if (response.status === 401 || response.status === 403) {
        return {
          ok: false,
          mode: 'qm',
          message: 'QM endpoint rejected the source signature (401/403).',
          latencyMilliseconds: latency(),
        }
      }
      return {
        ok: true,
        mode: 'qm',
        message: `QM endpoint reachable and source auth verified (status ${response.status}).`,
        latencyMilliseconds: latency(),
      }
    } catch (error) {
      return {
        ok: false,
        mode: 'qm',
        message: `QM endpoint unreachable: ${error instanceof Error ? error.message : String(error)}`,
        latencyMilliseconds: latency(),
      }
    }
  }

  async *runTurn(
    input: HarnessTurnInput,
    signal?: AbortSignal,
  ): AsyncIterable<HarnessTurnEvent> {
    let qm = input.qm
    if (qm === undefined) {
      // Phase 8 mapping: derive the QM turn request from Mu's task, bounded
      // Context Pack, and user text.
      if (input.task === undefined || input.contextPack === undefined || input.text === undefined) {
        throw MuError.invalidTransition(
          'QMHTTPHarness requires input.qm, or task + contextPack + text in QM mode.',
        )
      }
      qm = qmTurnRequestForMu({
        surface: this.surface,
        task: input.task,
        contextPack: input.contextPack,
        text: input.text,
        agentName: 'Mu Agent',
        actorExternalID: 'mu',
        threadRef: input.sessionID,
        model: input.qm?.model,
        readOnly: true,
        idempotencyKey: input.qm?.idempotencyKey,
      })
    }
    if (!isStrongSigningSecret(this.sourceSecret)) {
      yield { kind: 'failed', errorMessage: `QM signing secret must be at least ${MIN_SIGNING_SECRET_LENGTH} characters.` }
      return
    }
    if (isAborted(signal)) {
      yield { kind: 'cancelled' }
      return
    }

    const body: QMTurnRequestWire = {
      surface: qm.surface,
      actor: qm.actor,
      conversation: qm.conversation,
      text: qm.text,
      ...(qm.origin !== undefined ? { origin: qm.origin } : {}),
      ...(qm.model !== undefined ? { model: qm.model } : {}),
      ...(qm.readOnly !== undefined ? { readOnly: qm.readOnly } : {}),
      ...(qm.fastMode !== undefined ? { fastMode: qm.fastMode } : {}),
      ...(qm.async !== undefined ? { async: qm.async } : {}),
      ...(qm.idempotencyKey !== undefined ? { idempotencyKey: qm.idempotencyKey } : {}),
    }
    const bodyText = JSON.stringify(body)

    let response: Response
    try {
      response = await this.fetchImpl(this.url('/v1/turns'), {
        method: 'POST',
        headers: this.headers('POST', '/v1/turns', bodyText),
        body: bodyText,
      })
    } catch (error) {
      if (isAborted(signal)) {
        yield { kind: 'cancelled' }
        return
      }
      yield { kind: 'failed', errorMessage: `QM /v1/turns request failed: ${errorMessage(error)}` }
      return
    }

    if (isAborted(signal)) {
      yield { kind: 'cancelled' }
      return
    }

    let resultText = ''
    try {
      resultText = await response.text()
    } catch {
      // Continue with an empty body; status handling below still applies.
    }
    let wire: QMTurnResultWire | undefined
    try {
      const parsed: unknown = JSON.parse(resultText)
      if (typeof parsed === 'object' && parsed !== null) {
        wire = parsed as QMTurnResultWire
      }
    } catch {
      wire = undefined
    }

    // Refused turns arrive as HTTP 403 with a valid TurnResult body — dispatch
    // on the wire status first; only treat 401/403 as auth failure when the
    // body is not a recognizable turn result.
    if (wire === undefined || !isKnownTurnStatus(wire.status)) {
      if (response.status === 401 || response.status === 403) {
        yield { kind: 'failed', errorMessage: 'QM source authentication rejected (401/403).' }
        return
      }
      if (response.status === 400 || response.status === 404) {
        yield { kind: 'failed', errorMessage: wire?.reason ?? `QM returned HTTP ${response.status}.` }
        return
      }
      yield { kind: 'failed', errorMessage: `QM returned HTTP ${response.status} with an unparseable body.` }
      return
    }

    const runID = wire.runId ?? wire.sessionId ?? ''
    if (runID !== '') {
      this.attachmentsBySession.set(runID, wire.attachments)
    }

    switch (wire.status) {
      case 'queued': {
        if (runID !== '') yield { kind: 'session_started', sessionID: runID }
        yield { kind: 'completed', result: this.result({ status: 'queued', sessionID: runID || 'queued', output: '', runID: wire.runId }) }
        return
      }
      case 'pending_approval': {
        if (runID !== '') yield { kind: 'session_started', sessionID: runID }
        const approvals = mapApprovals(wire.pendingApprovals ?? [])
        yield { kind: 'pending_approval', approvals }
        yield {
          kind: 'completed',
          result: this.result({
            status: 'pending_approval',
            sessionID: runID,
            output: wire.reply ?? '',
            pendingApprovals: approvals,
            runID: wire.runId,
          }),
        }
        return
      }
      case 'refused': {
        if (runID !== '') yield { kind: 'session_started', sessionID: runID }
        yield {
          kind: 'completed',
          result: this.result({
            status: 'failed',
            sessionID: runID,
            output: wire.reply ?? '',
            errorMessage: wire.reason ?? 'Turn refused by QM.',
            runID: wire.runId,
          }),
        }
        return
      }
      case 'failed': {
        if (runID !== '') yield { kind: 'session_started', sessionID: runID }
        yield {
          kind: 'completed',
          result: this.result({
            status: 'failed',
            sessionID: runID,
            output: wire.reply ?? '',
            errorMessage: wire.reason ?? 'QM turn failed.',
            runID: wire.runId,
          }),
        }
        return
      }
      case 'silent':
      case 'react':
      case 'ok':
      default: {
        if (runID !== '') yield { kind: 'session_started', sessionID: runID }
        const output = wire.reply ?? ''
        if (output !== '') yield { kind: 'visible_text', text: output }
        yield {
          kind: 'completed',
          result: this.result({
            status: 'success',
            sessionID: runID,
            output,
            runID: wire.runId,
          }),
        }
      }
    }
  }

  /** In QM mode the session identifier is the run ID. */
  async interrupt(runID: string): Promise<void> {
    if (runID.trim() === '') {
      throw MuError.invalidTransition('QMHTTPHarness.interrupt requires a run ID.')
    }
    const path = `/v1/runs/${encodeURIComponent(runID)}/signal`
    const body = JSON.stringify({ kind: 'abort' })
    const response = await this.fetchImpl(this.url(path), {
      method: 'POST',
      headers: this.headers('POST', path, body),
      body,
    })
    if (response.status === 404) {
      throw MuError.recordNotFound(`QM run ${runID} was not found.`)
    }
    if (response.status !== 200 && response.status !== 202 && response.status !== 409) {
      throw MuError.commandFailed(`QM abort signal failed with HTTP ${response.status}.`)
    }
  }

  async listArtifacts(sessionID: string): Promise<HarnessArtifactRecord[]> {
    const attachments = this.attachmentsBySession.get(sessionID)
    if (attachments === undefined || attachments.length === 0) return []
    return attachments.map((attachment) => ({
      name: attachment.name,
      relativePath: attachment.name,
      kind: attachment.mimetype,
      byteCount: attachment.sizeBytes,
      nativeRef: attachment.artifactId ?? attachment.blobId,
    }))
  }

  /**
   * Subscribes to QM session-state SSE events. The stream is authenticated
   * with the same source signature; comments and heartbeats are ignored.
   */
  async *subscribeSessionStates(signal?: AbortSignal): AsyncIterable<QMSessionStateEvent> {
    if (isAborted(signal)) return
    const response = await this.fetchImpl(this.url('/v1/session-state/events'), {
      method: 'GET',
      headers: this.headers('GET', '/v1/session-state/events'),
      signal,
    })
    if (response.status !== 200 || response.body === null) {
      throw MuError.commandFailed(`QM SSE stream failed with HTTP ${response.status}.`)
    }
    const parser = new QMSSEParser()
    try {
      for await (const chunk of response.body as unknown as AsyncIterable<Uint8Array>) {
        if (isAborted(signal)) break
        for (const event of parser.consume(Buffer.from(chunk))) {
          yield event
        }
      }
    } catch (error) {
      // Aborting the request destroys the body stream; swallow that and stop.
      if (!isAborted(signal)) throw error
    }
    if (!isAborted(signal)) {
      for (const event of parser.finish()) {
        yield event
      }
    }
  }

  private result(params: {
    status: HarnessTurnResult['status']
    sessionID: string
    output: string
    errorMessage?: string
    pendingApprovals?: readonly HarnessPendingApproval[]
    runID?: string
  }): HarnessTurnResult {
    return {
      status: params.status,
      sessionID: params.sessionID,
      output: params.output,
      errorMessage: params.errorMessage,
      pendingApprovals: params.pendingApprovals,
      runID: params.runID,
    }
  }
}

function mapApprovals(
  approvals: NonNullable<QMTurnResultWire['pendingApprovals']>,
): HarnessPendingApproval[] {
  return approvals.map((approval) => ({
    requestID: approval.requestId,
    command: approval.command,
    reason: approval.reason,
    purpose: approval.purpose,
    summary: approval.summary,
    blocksInput: approval.blocksInput,
  }))
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function isAborted(signal?: AbortSignal): boolean {
  return signal?.aborted === true
}

const KNOWN_TURN_STATUSES = new Set([
  'ok',
  'refused',
  'failed',
  'pending_approval',
  'queued',
  'silent',
  'react',
])

function isKnownTurnStatus(status: unknown): status is QMTurnResultWire['status'] {
  return typeof status === 'string' && KNOWN_TURN_STATUSES.has(status)
}

export function createQMHarness(options: QMHTTPHarnessOptions): QMHTTPHarness {
  return new QMHTTPHarness(options)
}
