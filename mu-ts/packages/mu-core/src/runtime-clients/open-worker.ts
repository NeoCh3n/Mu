import fs from 'node:fs'
import { MuError } from '../errors.ts'
import { canonicalPath } from '../paths.ts'

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

export interface OpenWorkerClientConfiguration {
  readonly baseURL: string
  readonly token?: string
}

export function createOpenWorkerClientConfiguration(params: {
  baseURL: string
  token?: string
}): OpenWorkerClientConfiguration {
  const url = new URL(params.baseURL)
  if (url.protocol !== 'http:') {
    throw MuError.commandFailed('OpenWorker must use an explicit http:// loopback endpoint.')
  }
  const host = url.hostname.toLowerCase()
  if (!['127.0.0.1', 'localhost', '::1'].includes(host)) {
    throw MuError.commandFailed('OpenWorker must use an explicit http:// loopback endpoint.')
  }
  if (url.port === '') {
    throw MuError.commandFailed('OpenWorker must use an explicit http:// loopback endpoint.')
  }
  if ((params.token === undefined || params.token === '') && host !== '127.0.0.1') {
    throw MuError.commandFailed('Tokenless OpenWorker compatibility is restricted to 127.0.0.1.')
  }
  return {
    baseURL: params.baseURL.replace(/\/$/, ''),
    token: params.token === undefined || params.token === '' ? undefined : params.token,
  }
}

// ---------------------------------------------------------------------------
// JSON value
// ---------------------------------------------------------------------------

export type OpenWorkerJSONValue =
  | { type: 'string'; value: string }
  | { type: 'number'; value: number }
  | { type: 'bool'; value: boolean }
  | { type: 'object'; value: Record<string, OpenWorkerJSONValue> }
  | { type: 'array'; value: OpenWorkerJSONValue[] }
  | { type: 'null' }

export function jsonString(value: string): OpenWorkerJSONValue {
  return { type: 'string', value }
}

export function jsonValueFromUnknown(value: unknown): OpenWorkerJSONValue {
  if (value === null) return { type: 'null' }
  if (typeof value === 'boolean') return { type: 'bool', value }
  if (typeof value === 'number') return { type: 'number', value }
  if (typeof value === 'string') return { type: 'string', value }
  if (Array.isArray(value)) return { type: 'array', value: value.map(jsonValueFromUnknown) }
  if (typeof value === 'object') {
    const out: Record<string, OpenWorkerJSONValue> = {}
    for (const [key, nested] of Object.entries(value as Record<string, unknown>)) {
      out[key] = jsonValueFromUnknown(nested)
    }
    return { type: 'object', value: out }
  }
  return { type: 'null' }
}

/** Converts a raw JSON value (string/array/object) into the tagged form. */
function normalizeContent(value: unknown): OpenWorkerJSONValue {
  if (typeof value === 'string') return jsonString(value)
  return jsonValueFromUnknown(value)
}

export function jsonValueString(value: OpenWorkerJSONValue): string | undefined {
  switch (value.type) {
    case 'string':
      return value.value
    case 'number':
      return String(value.value)
    case 'bool':
      return String(value.value)
    default:
      return undefined
  }
}

export function jsonValueObject(value: OpenWorkerJSONValue): Record<string, OpenWorkerJSONValue> | undefined {
  return value.type === 'object' ? value.value : undefined
}

export function jsonValueArray(value: OpenWorkerJSONValue): OpenWorkerJSONValue[] | undefined {
  return value.type === 'array' ? value.value : undefined
}

export function jsonValueCompact(value: OpenWorkerJSONValue): string {
  return JSON.stringify(valueToPlain(value))
}

function valueToPlain(value: OpenWorkerJSONValue): unknown {
  switch (value.type) {
    case 'string':
      return value.value
    case 'number':
      return value.value
    case 'bool':
      return value.value
    case 'object': {
      const out: Record<string, unknown> = {}
      for (const [key, nested] of Object.entries(value.value)) out[key] = valueToPlain(nested)
      return out
    }
    case 'array':
      return value.value.map(valueToPlain)
    case 'null':
      return null
  }
}

// ---------------------------------------------------------------------------
// Wire types
// ---------------------------------------------------------------------------

export interface OpenWorkerSessionSummary {
  readonly session_id: string
  readonly title?: string
  readonly workspace: string
  readonly agent: string
  readonly model: string
  readonly mode: string
  readonly updated_at?: string
  readonly messages: number
  readonly pinned?: boolean
  readonly archived?: boolean
  readonly origin?: string
  readonly origin_label?: string
  readonly attention?: number
  readonly liveness?: string
  readonly subscriptions?: string[]
}

export interface OpenWorkerMessage {
  readonly role: string
  readonly content: OpenWorkerJSONValue
  readonly ts?: number
  readonly reasoning?: string
  readonly kind?: string
  readonly text?: string
}

export function openWorkerMessageText(message: OpenWorkerMessage): string {
  if (message.role === 'notice') {
    return message.text ?? (message.kind === undefined ? '' : `OpenWorker ${message.kind.replace(/_/g, ' ')}.`)
  }
  switch (message.content.type) {
    case 'string':
      return message.content.value
    case 'array':
      return message.content.value
        .map((value) => {
          if (value.type === 'object') {
            const text = jsonValueString(value.value['text'] ?? { type: 'null' })
            if (text !== undefined) return text
          }
          return jsonValueString(value) ?? ''
        })
        .join('\n')
    default:
      return jsonValueCompact(message.content)
  }
}

export interface OpenWorkerArtifactInfo {
  readonly path: string
  readonly abs_path?: string
  readonly name: string
  readonly kind: string
  readonly size: number
  readonly modified_at: number
}

export interface OpenWorkerInboxItem {
  readonly id: string
  readonly session_id: string
  readonly kind: string
  readonly title: string
  readonly body: string
  readonly state: string
  readonly resolution?: string
  readonly visibility: string
  readonly tool_call_id?: string
  readonly options: readonly string[]
  readonly allow_text: boolean
  readonly multi: boolean
  readonly data: Record<string, OpenWorkerJSONValue>
  readonly created_at?: string
  readonly resolved_at?: string
  readonly session_title?: string
  readonly session_agent?: string
  readonly session_workspace?: string
  readonly session_exists?: boolean
}

export function inboxTitle(item: OpenWorkerInboxItem): string {
  return item.title === '' ? item.kind : item.title
}

export interface OpenWorkerProbeResult {
  readonly baseURL: string
  readonly status: string
  readonly defaultWorkspace?: string
  readonly model: string
  readonly defaultAgent: string
  readonly sessionCount: number
  readonly requiresToken: boolean
}

export interface OpenWorkerReady {
  readonly sessionID: string
  readonly agent: string
  readonly model: string
  readonly mode: string
  readonly workspace: string
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

export interface OpenWorkerEvent {
  readonly type: string
  readonly data: Record<string, OpenWorkerJSONValue>
}

export function openWorkerEventSummary(event: OpenWorkerEvent): string {
  switch (event.type) {
    case 'ready':
      return 'Connected to OpenWorker session.'
    case 'turn_start':
      return 'OpenWorker started a turn.'
    case 'assistant_delta':
    case 'reasoning_delta':
      return 'OpenWorker is responding.'
    case 'assistant_message':
      return 'OpenWorker returned a message.'
    case 'tool_proposed': {
      const name = jsonValueString(event.data['name'] ?? { type: 'null' }) ?? 'tool'
      return `OpenWorker proposed ${name}.`
    }
    case 'permission_required': {
      const name = jsonValueString(event.data['name'] ?? { type: 'null' }) ?? 'an action'
      return `Approval required for ${name}.`
    }
    case 'directory_requested':
      return 'OpenWorker requested another folder.'
    case 'plan_proposed':
      return 'OpenWorker proposed a plan.'
    case 'question_requested':
      return 'OpenWorker asked a question.'
    case 'tool_started': {
      const name = jsonValueString(event.data['name'] ?? { type: 'null' }) ?? 'tool'
      return `OpenWorker started ${name}.`
    }
    case 'tool_finished': {
      const name = jsonValueString(event.data['name'] ?? { type: 'null' }) ?? 'tool'
      return `OpenWorker finished ${name}.`
    }
    case 'model_changed': {
      const model = jsonValueString(event.data['model'] ?? { type: 'null' })
      return model === undefined ? 'OpenWorker changed models.' : `OpenWorker switched to ${model}.`
    }
    case 'interrupted':
      return 'OpenWorker was interrupted.'
    case 'turn_done':
      return 'OpenWorker finished the turn.'
    case 'error':
    case 'input_rejected': {
      const error = jsonValueString(event.data['error'] ?? { type: 'null' })
      return error === undefined ? 'OpenWorker reported an error.' : `OpenWorker: ${error}`
    }
    case 'connection_closed': {
      const error = jsonValueString(event.data['error'] ?? { type: 'null' })
      return error === undefined ? 'OpenWorker connection closed.' : `Connection closed: ${error}`
    }
    default:
      return `OpenWorker event: ${event.type.replace(/_/g, ' ')}.`
  }
}

export function openWorkerEventReady(event: OpenWorkerEvent): OpenWorkerReady | undefined {
  if (event.type !== 'ready') return undefined
  const sessionID = jsonValueString(event.data['session_id'] ?? { type: 'null' })
  if (sessionID === undefined) return undefined
  return {
    sessionID,
    agent: jsonValueString(event.data['agent'] ?? { type: 'null' }) ?? 'cowork',
    model: jsonValueString(event.data['model'] ?? { type: 'null' }) ?? '',
    mode: jsonValueString(event.data['mode'] ?? { type: 'null' }) ?? '',
    workspace: jsonValueString(event.data['workspace'] ?? { type: 'null' }) ?? '',
  }
}

/** Decodes a WebSocket text/data frame into an OpenWorkerEvent. */
export function decodeOpenWorkerEvent(
  message: string | Uint8Array | ArrayBuffer,
): OpenWorkerEvent {
  let text: string
  if (typeof message === 'string') {
    text = message
  } else if (message instanceof Uint8Array) {
    text = Buffer.from(message).toString('utf8')
  } else {
    text = Buffer.from(message).toString('utf8')
  }
  let envelope: unknown
  try {
    envelope = JSON.parse(text)
  } catch {
    throw MuError.commandFailed('OpenWorker returned an unsupported WebSocket frame.')
  }
  if (typeof envelope !== 'object' || envelope === null) {
    throw MuError.commandFailed('OpenWorker returned an unsupported WebSocket frame.')
  }
  const type = (envelope as Record<string, unknown>)['type']
  if (typeof type !== 'string') {
    throw MuError.commandFailed('OpenWorker returned an unsupported WebSocket frame.')
  }
  const rawData = (envelope as Record<string, unknown>)['data']
  if (typeof rawData !== 'object' || rawData === null) {
    return { type, data: {} }
  }
  return { type, data: jsonValueObject(jsonValueFromUnknown(rawData)) ?? {} }
}

// ---------------------------------------------------------------------------
// Live text state machine
// ---------------------------------------------------------------------------

export interface OpenWorkerLiveTextState {
  readonly text: string
  readonly isFinalized: boolean
}

export function createOpenWorkerLiveTextState(): OpenWorkerLiveTextState {
  return { text: '', isFinalized: false }
}

/** Applies an event; returns true when the state changed. */
export function applyOpenWorkerLiveTextEvent(
  state: OpenWorkerLiveTextState,
  event: OpenWorkerEvent,
): OpenWorkerLiveTextState {
  switch (event.type) {
    case 'turn_start':
      return { text: '', isFinalized: false }
    case 'assistant_delta': {
      if (state.isFinalized) return state
      const delta = jsonValueString(event.data['text'] ?? { type: 'null' })
      if (delta === undefined || delta === '') return state
      return { ...state, text: state.text + delta }
    }
    case 'assistant_message': {
      const text = jsonValueString(event.data['text'] ?? { type: 'null' })
      return { text: text ?? '', isFinalized: true }
    }
    case 'turn_done':
    case 'input_rejected':
    case 'connection_closed':
      return { ...state, isFinalized: true }
    default:
      return state
  }
}

// ---------------------------------------------------------------------------
// HTTP client
// ---------------------------------------------------------------------------

export class OpenWorkerHTTPClient {
  private readonly configuration: OpenWorkerClientConfiguration

  constructor(configuration: OpenWorkerClientConfiguration) {
    this.configuration = configuration
  }

  async probe(): Promise<OpenWorkerProbeResult> {
    const health = await this.get<Record<string, unknown>>('v1/health')
    const agents = await this.get<{ agents?: Array<{ name: string; default?: boolean }> }>('v1/agents')
    const sessions = await this.sessions()
    const defaultAgent =
      agents.agents?.find((a) => a.default === true)?.name
      ?? agents.agents?.[0]?.name
      ?? 'cowork'
    return {
      baseURL: this.configuration.baseURL,
      status: typeof health['status'] === 'string' ? health['status'] : 'unknown',
      defaultWorkspace: typeof health['default_workspace'] === 'string' ? health['default_workspace'] : undefined,
      model: typeof health['model'] === 'string' ? health['model'] : '',
      defaultAgent,
      sessionCount: sessions.length,
      requiresToken: this.configuration.token !== undefined,
    }
  }

  async sessions(workspace?: string): Promise<OpenWorkerSessionSummary[]> {
    const query = workspace === undefined || workspace === '' ? '' : `?workspace=${encodeURIComponent(workspace)}`
    const response = await this.get<{ sessions: OpenWorkerSessionSummary[] }>(`v1/sessions${query}`)
    return response.sessions
  }

  async messages(sessionID: string): Promise<OpenWorkerMessage[]> {
    const response = await this.get<{ messages: Array<Record<string, unknown>> }>(
      `v1/sessions/${encodeURIComponent(sessionID)}/messages`,
    )
    return response.messages.map((m) => ({
      role: typeof m['role'] === 'string' ? m['role'] : 'notice',
      content: normalizeContent(m['content']),
      ts: typeof m['ts'] === 'number' ? m['ts'] : undefined,
      reasoning: typeof m['reasoning'] === 'string' ? m['reasoning'] : undefined,
      kind: typeof m['kind'] === 'string' ? m['kind'] : undefined,
      text: typeof m['text'] === 'string' ? m['text'] : undefined,
    }))
  }

  async artifacts(sessionID: string): Promise<OpenWorkerArtifactInfo[]> {
    const response = await this.get<{ artifacts: OpenWorkerArtifactInfo[] }>(
      `v1/sessions/${encodeURIComponent(sessionID)}/artifacts`,
    )
    return response.artifacts
  }

  async pendingInbox(sessionID: string): Promise<OpenWorkerInboxItem[]> {
    const response = await this.get<{ items: OpenWorkerInboxItem[] }>(
      `v1/inbox?session_id=${encodeURIComponent(sessionID)}&state=pending`,
    )
    return response.items
  }

  async resolveInbox(itemID: string, resolution: string): Promise<boolean> {
    const response = await this.post<{ ok: boolean }>(
      `v1/inbox/${encodeURIComponent(itemID)}/resolve`,
      { resolution },
    )
    return response.ok
  }

  private async get<T>(path: string): Promise<T> {
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), 15_000)
    try {
      const response = await fetch(`${this.configuration.baseURL}/${path}`, {
        signal: controller.signal,
        headers: this.headers(),
      })
      return await this.perform<T>(response)
    } finally {
      clearTimeout(timer)
    }
  }

  private async post<T>(path: string, body: Record<string, string>): Promise<T> {
    const controller = new AbortController()
    // Inbox resolution may trigger a durable agent resume before the server
    // replies; the caller reconciles the Inbox after any timeout.
    const timer = setTimeout(() => controller.abort(), 20_000)
    try {
      const response = await fetch(`${this.configuration.baseURL}/${path}`, {
        method: 'POST',
        headers: { ...this.headers(), 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
        signal: controller.signal,
      })
      return await this.perform<T>(response)
    } finally {
      clearTimeout(timer)
    }
  }

  private headers(): Record<string, string> {
    return this.configuration.token === undefined
      ? {}
      : { 'X-OpenWorker-Token': this.configuration.token }
  }

  private async perform<T>(response: Response): Promise<T> {
    if (!response.ok) {
      const detail = (await response.text()).slice(0, 1024)
      if (response.status === 401) {
        throw MuError.commandFailed(
          'OpenWorker requires a sidecar token that Mu has not been given.',
        )
      }
      throw MuError.commandFailed(`OpenWorker HTTP ${response.status}: ${detail}`)
    }
    try {
      return (await response.json()) as T
    } catch {
      throw MuError.commandFailed('OpenWorker returned an incompatible response.')
    }
  }
}

// ---------------------------------------------------------------------------
// WebSocket session bridge
// ---------------------------------------------------------------------------

export type OpenWorkerEventHandler = (event: OpenWorkerEvent) => Promise<void> | void

const ASSISTANT_DELTA_FLUSH_INTERVAL_MS = 80

/**
 * Live bridge to an OpenWorker sidecar session WebSocket. Deltas are batched
 * at 80 ms so per-token frames do not trail the completed native turn.
 */
export class OpenWorkerSessionBridge {
  private readonly configuration: OpenWorkerClientConfiguration
  private readonly sessionID: string
  private readonly workspace: string
  private readonly agent: string
  private socket?: WebSocket
  private receiveLoopRunning = false
  private assistantDeltaFlushTimer?: ReturnType<typeof setTimeout>
  private pendingAssistantDelta = ''
  private readyValue?: OpenWorkerReady
  private handler?: OpenWorkerEventHandler
  private intentionallyClosed = false

  constructor(
    configuration: OpenWorkerClientConfiguration,
    sessionID: string,
    workspace: string,
    agent = 'cowork',
  ) {
    this.configuration = configuration
    this.sessionID = sessionID
    this.workspace = workspace
    this.agent = agent
  }

  async connect(handler: OpenWorkerEventHandler): Promise<OpenWorkerReady> {
    if (this.readyValue !== undefined) {
      this.handler = handler
      return this.readyValue
    }
    this.handler = handler
    this.intentionallyClosed = false

    const url = this.webSocketURL()
    const socket = this.configuration.token === undefined
      ? new WebSocket(url)
      : new WebSocket(url, ['openworker', this.configuration.token])
    this.socket = socket

    const first = await this.receiveReady(socket)
    const ready = openWorkerEventReady(first)
    if (ready === undefined || ready.sessionID !== this.sessionID) {
      closeSocket(socket, 1002)
      this.socket = undefined
      throw MuError.commandFailed(
        `OpenWorker did not acknowledge native session ${this.sessionID}.`,
      )
    }
    if (ready.workspace !== '' && !sameWorkspace(ready.workspace, this.workspace)) {
      closeSocket(socket, 1008)
      this.socket = undefined
      throw MuError.invalidTransition(
        'OpenWorker acknowledged a different workspace. Relink the intended native session.',
      )
    }
    this.readyValue = ready
    await this.handler?.(first)
    this.startReceiveLoop()
    return ready
  }

  async sendUserMessage(text: string, model?: string): Promise<void> {
    const trimmed = text.trim()
    if (trimmed === '') {
      throw MuError.invalidTransition('OpenWorker message cannot be empty.')
    }
    const payload: Record<string, unknown> = { type: 'user_message', text: trimmed }
    if (model !== undefined && model !== '') payload['model'] = model
    await this.send(payload)
  }

  async approveOnce(): Promise<void> {
    await this.send({ type: 'approval', decision: 'once' })
  }

  async denyApproval(): Promise<void> {
    await this.send({ type: 'approval', decision: 'deny' })
  }

  async respondToPlan(approved: boolean, mode = 'interactive'): Promise<void> {
    await this.send({ type: 'plan_response', approved, mode })
  }

  async answerQuestion(answer: string): Promise<void> {
    await this.send({ type: 'question_response', answer })
  }

  async interrupt(): Promise<void> {
    await this.send({ type: 'interrupt' })
  }

  disconnect(): void {
    this.intentionallyClosed = true
    this.receiveLoopRunning = false
    this.clearDeltaFlush()
    closeSocket(this.socket, 1001)
    this.socket = undefined
    this.readyValue = undefined
  }

  // -------------------------------------------------------------------------

  private startReceiveLoop(): void {
    const socket = this.socket
    if (socket === undefined) return
    this.receiveLoopRunning = true
    socket.onmessage = async (event) => {
      let decoded: OpenWorkerEvent
      try {
        decoded = decodeOpenWorkerEvent(event.data)
      } catch {
        return
      }
      await this.deliver(decoded)
    }
    socket.onclose = () => {
      if (this.intentionallyClosed || !this.receiveLoopRunning) return
      this.clearDeltaFlush()
      this.readyValue = undefined
      this.socket = undefined
      void this.handler?.({
        type: 'connection_closed',
        data: { error: { type: 'string', value: 'OpenWorker connection closed.' } },
      })
    }
    socket.onerror = () => {
      // onclose follows with the terminal event.
    }
  }

  private async deliver(event: OpenWorkerEvent): Promise<void> {
    if (event.type === 'assistant_delta') {
      const text = jsonValueString(event.data['text'] ?? { type: 'null' }) ?? ''
      if (text === '') return
      this.pendingAssistantDelta += text
      this.scheduleDeltaFlush()
      return
    }
    if (event.type === 'assistant_message') {
      // assistant_message is the authoritative final; unflushed deltas are
      // a prefix of it and must never be delivered after the replacement.
      this.clearDeltaFlush()
    } else if (event.type === 'turn_done') {
      await this.flushAssistantDelta()
    }
    await this.handler?.(event)
  }

  private scheduleDeltaFlush(): void {
    if (this.assistantDeltaFlushTimer !== undefined) return
    this.assistantDeltaFlushTimer = setTimeout(() => {
      void this.flushAssistantDelta()
    }, ASSISTANT_DELTA_FLUSH_INTERVAL_MS)
  }

  private async flushAssistantDelta(): Promise<void> {
    this.clearDeltaFlush()
    if (this.pendingAssistantDelta === '') return
    const text = this.pendingAssistantDelta
    this.pendingAssistantDelta = ''
    await this.handler?.({
      type: 'assistant_delta',
      data: { text: { type: 'string', value: text } },
    })
  }

  private clearDeltaFlush(): void {
    if (this.assistantDeltaFlushTimer !== undefined) {
      clearTimeout(this.assistantDeltaFlushTimer)
      this.assistantDeltaFlushTimer = undefined
    }
  }

  /** Waits for the ready event with a 12-second handshake timeout. */
  private receiveReady(socket: WebSocket): Promise<OpenWorkerEvent> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        socket.close(1001)
        reject(MuError.commandFailed('Timed out waiting for the OpenWorker session handshake.'))
      }, 12_000)
      socket.onmessage = (event) => {
        let decoded: OpenWorkerEvent
        try {
          decoded = decodeOpenWorkerEvent(event.data)
        } catch {
          return
        }
        clearTimeout(timer)
        resolve(decoded)
      }
      socket.onerror = () => {
        clearTimeout(timer)
        reject(MuError.commandFailed('OpenWorker closed before acknowledging the native session.'))
      }
      socket.onclose = () => {
        clearTimeout(timer)
        reject(MuError.commandFailed('OpenWorker closed before acknowledging the native session.'))
      }
    })
  }

  private async send(payload: Record<string, unknown>): Promise<void> {
    const socket = this.socket
    if (socket === undefined || this.readyValue === undefined) {
      throw MuError.commandFailed('OpenWorker session is not connected.')
    }
    socket.send(JSON.stringify(payload))
  }

  private webSocketURL(): string {
    const base = new URL(this.configuration.baseURL)
    const scheme = base.protocol === 'https:' ? 'wss' : 'ws'
    return `${scheme}://${base.host}/ws/session/${encodeURIComponent(this.sessionID)}?workspace=${encodeURIComponent(this.workspace)}&agent=${encodeURIComponent(this.agent)}`
  }
}

function sameWorkspace(lhs: string, rhs: string): boolean {
  return canonicalPath(lhs) === canonicalPath(rhs)
}

function closeSocket(socket: WebSocket | undefined, code: number): void {
  if (socket === undefined) return
  try {
    if (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING) {
      socket.close(code)
    }
  } catch {
    // The socket may already be closing; ignore.
  }
}

// ---------------------------------------------------------------------------
// Sidecar discovery
// ---------------------------------------------------------------------------

/** Finds the OpenWorker sidecar base URL from its server log. */
export function discoverOpenWorkerBaseURL(logPath?: string): string | undefined {
  const source = logPath ?? `${process.env.HOME}/.config/coworker/logs/openworker-server.log`
  let content: string
  try {
    const stats = fs.statSync(source)
    let data: Buffer
    if (stats.size <= 16 * 1024 * 1024) {
      data = fs.readFileSync(source)
    } else {
      const fd = fs.openSync(source, 'r')
      try {
        const head = Buffer.alloc(1024 * 1024)
        const headLen = fs.readSync(fd, head, 0, head.length, 0)
        const tailLen = Math.min(8 * 1024 * 1024, stats.size)
        const tail = Buffer.alloc(tailLen)
        const tailRead = fs.readSync(fd, tail, 0, tailLen, stats.size - tailLen)
        data = Buffer.concat([head.subarray(0, headLen), Buffer.from('\n'), tail.subarray(0, tailRead)])
      } finally {
        fs.closeSync(fd)
      }
    }
    content = data.toString('utf8')
  } catch {
    return undefined
  }
  return parseOpenWorkerBaseURL(content)
}

/** Extracts the Uvicorn base URL from server log text. */
export function parseOpenWorkerBaseURL(log: string): string | undefined {
  const pattern = /Uvicorn running on http:\/\/(127\.0\.0\.1|localhost|\[::1\]):([0-9]{2,5})/g
  let match: RegExpExecArray | null
  let last: RegExpExecArray | null = null
  while ((match = pattern.exec(log)) !== null) {
    last = match
  }
  if (last === null) return undefined
  const host = last[1]!
  const port = Number(last[2])
  if (!Number.isInteger(port) || port < 1 || port > 65_535) return undefined
  return `http://${host}:${port}`
}
