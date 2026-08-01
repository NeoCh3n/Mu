import { spawn, type ChildProcess } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { MuError } from '../errors.ts'
import type { CodexProbeResult, CodexReplanResult, CodexTurnResult, TaskRecord } from '../models.ts'
import type { ProjectContextPackRecord } from '../project-kernel/index.ts'
import { renderedContextPackMarkdown } from '../project-kernel/index.ts'
import type {
  ExternalConversationCandidate,
  ExternalConversationMessage,
} from '../conversation-history.ts'
import { canonicalWorkspacePath } from '../conversation-history.ts'
import { encodeMuJSON } from '../hashing.ts'

// ---------------------------------------------------------------------------
// Internal protocol types
// ---------------------------------------------------------------------------

interface CodexResponse {
  result?: Record<string, unknown>
  error?: string
}

interface TurnCompletion {
  status: string
  errorMessage?: string
}

interface AgentMessage {
  text: string
  phase?: string
}

type JsonObject = Record<string, unknown>

const TURN_READ_FALLBACK_INTERVAL_MS = 2000
const TURN_READ_FALLBACK_TIMEOUT_MS = 2000

/**
 * Child-process client for the Codex App Server (`codex app-server --stdio`),
 * speaking newline-delimited JSON-RPC. Mirrors CodexAppServerClient.swift.
 */
export class CodexAppServerClient {
  readonly executableURL: string

  private process?: ChildProcess
  private input?: NodeJS.WritableStream
  private readBuffer = ''
  private nextRequestID = 1
  private responses = new Map<number, { resolve: (r: CodexResponse) => void; reject: (e: Error) => void }>()
  private completedTurns = new Map<string, TurnCompletion>()
  private agentMessages = new Map<string, Map<string, AgentMessage>>()
  private agentMessageOrder = new Map<string, string[]>()
  private visibleTextObservers = new Map<string, (text: string) => void>()
  private processFailure?: string
  private initializedResult?: Record<string, unknown>
  private stopped = false

  constructor(options: { executableURL: string }) {
    this.executableURL = options.executableURL
  }

  async start(): Promise<Record<string, unknown>> {
    if (this.process !== undefined && this.process.exitCode === null) {
      return this.initializedResult ?? {}
    }
    if (!isExecutableFile(this.executableURL)) {
      throw MuError.commandFailed(`Codex executable is unavailable at ${this.executableURL}`)
    }

    const process = spawn(this.executableURL, ['app-server', '--stdio'], {
      stdio: ['pipe', 'pipe', 'pipe'],
    })
    this.process = process
    this.input = process.stdin
    this.stopped = false

    process.stdout.setEncoding('utf8')
    process.stdout.on('data', (data: string) => {
      this.consume(data)
    })
    process.stderr.on('data', () => {
      // Drain diagnostics so the child cannot block on a full stderr pipe.
    })
    process.on('exit', (code) => {
      if (code !== 0 && this.stopped === false) {
        this.processFailure = `Codex App Server exited with status ${code}.`
        this.rejectAllPending(this.processFailure)
      }
    })

    const initialize = await this.request(
      'initialize',
      {
        clientInfo: {
          name: 'mu',
          title: 'Mu Runtime Control Plane',
          version: '0.4.0',
        },
        capabilities: {
          experimentalApi: true,
          requestAttestation: false,
          mcpServerOpenaiFormElicitation: false,
          optOutNotificationMethods: [],
        },
      },
      15_000,
    )
    this.initializedResult = initialize
    await this.notify('initialized')
    return initialize
  }

  async probe(): Promise<CodexProbeResult> {
    const initialize = await this.start()
    const account = await this.request('account/read', { refreshToken: false }, 15_000)
    const threads = await this.request(
      'thread/list',
      {
        limit: 5,
        sortKey: 'updated_at',
        sortDirection: 'desc',
        archived: false,
        useStateDbOnly: true,
      },
      15_000,
    )
    const data = asArray(threads['data'])
    const accountValue = account['account']
    return {
      userAgent: nonEmptyString(initialize['userAgent']) ?? 'Codex App Server',
      platformOS: nonEmptyString(initialize['platformOs']) ?? 'unknown',
      signedIn: accountValue !== undefined && accountValue !== null,
      observedThreadCount: data.length,
    }
  }

  async listHistory(workspacePath: string, timeoutMs = 30_000): Promise<ExternalConversationCandidate[]> {
    const canonical = canonicalWorkspacePath(workspacePath)
    await this.start()

    const bySessionID = new Map<string, ExternalConversationCandidate>()
    for (const isArchived of [false, true]) {
      const candidates = await this.listHistoryPage(canonical, isArchived, timeoutMs)
      for (const candidate of candidates) {
        bySessionID.set(candidate.nativeSessionID, candidate)
      }
    }
    return [...bySessionID.values()].sort((lhs, rhs) => {
      const lhsDate = lhs.updatedAt ?? lhs.createdAt
      const rhsDate = rhs.updatedAt ?? rhs.createdAt
      if (lhsDate !== undefined && rhsDate !== undefined && lhsDate.getTime() !== rhsDate.getTime()) {
        return rhsDate.getTime() - lhsDate.getTime()
      }
      if (lhsDate !== undefined && rhsDate === undefined) return -1
      if (lhsDate === undefined && rhsDate !== undefined) return 1
      return lhs.nativeSessionID < rhs.nativeSessionID ? -1 : 1
    })
  }

  async readHistory(
    sessionID: string,
    workspacePath: string,
    timeoutMs = 30_000,
  ): Promise<ExternalConversationMessage[]> {
    const normalized = sessionID.trim()
    if (normalized === '') {
      throw MuError.commandFailed('A Codex session ID is required.')
    }
    const canonical = canonicalWorkspacePath(workspacePath)
    await this.start()

    const response = await this.request(
      'thread/read',
      { threadId: normalized, includeTurns: true },
      timeoutMs,
    )
    const thread = asObject(response['thread'])
    const responseSessionID = nonEmptyString(thread['id'])
    if (responseSessionID !== normalized) {
      throw MuError.commandFailed('Codex thread/read returned a different or missing thread.')
    }
    const responseWorkspacePath = nonEmptyString(thread['cwd'])
    if (responseWorkspacePath === undefined) {
      throw MuError.commandFailed('Codex thread/read returned no workspace path.')
    }
    if (canonicalWorkspacePath(responseWorkspacePath) !== canonical) {
      throw MuError.commandFailed(
        `Codex session ${normalized} belongs to a different workspace.`,
      )
    }
    return parseHistoryMessages(response, normalized)
  }

  async runReadOnlyTask(params: {
    task: TaskRecord
    agent?: { displayName: string; role: string; summary: string; capabilityTags: readonly string[] }
    contextPack?: ProjectContextPackRecord
    promptOverride?: string
    clientUserMessageID: string
    timeoutMs?: number
    onThreadStarted?: (threadID: string) => void
    onTurnStarted?: (threadID: string, turnID: string) => void
    onVisibleText?: (text: string) => void
  }): Promise<CodexTurnResult> {
    return this.runReadOnlyTurn({
      task: params.task,
      developerInstructions: taskDeveloperInstructions(params.agent),
      prompt:
        params.promptOverride
        ?? (params.contextPack === undefined ? undefined : renderedContextPackMarkdown(params.contextPack))
        ?? taskPrompt(params.task),
      clientUserMessageID: params.clientUserMessageID,
      threadName: params.task.title,
      reconcileHistory: true,
      timeoutMs: params.timeoutMs ?? 600_000,
      onThreadStarted: params.onThreadStarted,
      onTurnStarted: params.onTurnStarted,
      onVisibleText: params.onVisibleText,
    })
  }

  async runReadOnlyContinuation(params: {
    threadID: string
    task: TaskRecord
    prompt: string
    clientUserMessageID: string
    timeoutMs?: number
    onTurnStarted?: (threadID: string, turnID: string) => void
    onVisibleText?: (text: string) => void
  }): Promise<CodexTurnResult> {
    const normalizedThreadID = params.threadID.trim()
    if (normalizedThreadID === '') {
      throw MuError.invalidTransition('Codex continuation requires a native thread ID.')
    }
    const normalizedPrompt = params.prompt.trim()
    if (normalizedPrompt === '') {
      throw MuError.invalidTransition('Codex continuation cannot be empty.')
    }
    await this.start()
    const threadRead = await this.request(
      'thread/read',
      { threadId: normalizedThreadID, includeTurns: false },
      30_000,
    )
    const thread = asObject(threadRead['thread'])
    if (
      nonEmptyString(thread['id']) !== normalizedThreadID
      || nonEmptyString(thread['cwd']) === undefined
      || canonicalWorkspacePath(nonEmptyString(thread['cwd'])!) !== canonicalWorkspacePath(params.task.repositoryPath)
    ) {
      throw MuError.invalidTransition(
        'Codex thread does not belong to the exact Project workspace.',
      )
    }

    const turnResponse = await this.request(
      'turn/start',
      {
        threadId: normalizedThreadID,
        input: [{ type: 'text', text: normalizedPrompt, text_elements: [] }],
        cwd: params.task.repositoryPath,
        runtimeWorkspaceRoots: [params.task.repositoryPath],
        approvalPolicy: 'never',
        approvalsReviewer: 'user',
        sandboxPolicy: { type: 'readOnly', networkAccess: false },
        clientUserMessageId: params.clientUserMessageID,
      },
      30_000,
    )
    const turn = asObject(turnResponse['turn'])
    const turnID = nonEmptyString(turn['id'])
    if (turnID === undefined) {
      throw MuError.commandFailed('Codex turn/start returned no turn ID.')
    }
    this.setVisibleTextObserver(params.onVisibleText, turnID)
    try {
      params.onTurnStarted?.(normalizedThreadID, turnID)
      const completion = await this.waitForTurn(normalizedThreadID, turnID, params.timeoutMs ?? 600_000)
      return this.finishTurn(normalizedThreadID, turnID, completion, true)
    } finally {
      this.setVisibleTextObserver(undefined, turnID)
    }
  }

  async interrupt(threadID: string, turnID: string): Promise<void> {
    await this.start()
    await this.request('turn/interrupt', { threadId: threadID, turnId: turnID }, 15_000)
  }

  stop(): void {
    this.stopped = true
    if (this.process !== undefined && this.process.exitCode === null) {
      this.process.kill()
    }
    this.input?.end()
    this.process = undefined
    this.input = undefined
  }

  // -------------------------------------------------------------------------
  // Private: turns
  // -------------------------------------------------------------------------

  private async runReadOnlyTurn(params: {
    task: TaskRecord
    developerInstructions: string
    prompt: string
    clientUserMessageID?: string
    threadName?: string
    reconcileHistory: boolean
    timeoutMs: number
    onThreadStarted?: (threadID: string) => void
    onTurnStarted?: (threadID: string, turnID: string) => void
    onVisibleText?: (text: string) => void
  }): Promise<CodexTurnResult> {
    await this.start()
    const threadResponse = await this.request(
      'thread/start',
      {
        cwd: params.task.repositoryPath,
        runtimeWorkspaceRoots: [params.task.repositoryPath],
        approvalPolicy: 'never',
        approvalsReviewer: 'user',
        sandbox: 'read-only',
        ephemeral: false,
        serviceName: 'Mu',
        developerInstructions: params.developerInstructions,
      },
      30_000,
    )
    const thread = asObject(threadResponse['thread'])
    const threadID = nonEmptyString(thread['id'])
    if (threadID === undefined) {
      throw MuError.commandFailed('Codex thread/start returned no thread ID.')
    }
    params.onThreadStarted?.(threadID)
    if (params.threadName !== undefined && params.threadName.trim() !== '') {
      try {
        await this.request(
          'thread/name/set',
          { threadId: threadID, name: params.threadName.trim() },
          10_000,
        )
      } catch {
        // Name setting is best-effort.
      }
    }

    const turnParams: JsonObject = {
      threadId: threadID,
      input: [{ type: 'text', text: params.prompt, text_elements: [] }],
      cwd: params.task.repositoryPath,
      runtimeWorkspaceRoots: [params.task.repositoryPath],
      approvalPolicy: 'never',
      approvalsReviewer: 'user',
      sandboxPolicy: { type: 'readOnly', networkAccess: false },
    }
    if (params.clientUserMessageID !== undefined) {
      turnParams['clientUserMessageId'] = params.clientUserMessageID
    }
    const turnResponse = await this.request('turn/start', turnParams, 30_000)
    const turn = asObject(turnResponse['turn'])
    const turnID = nonEmptyString(turn['id'])
    if (turnID === undefined) {
      throw MuError.commandFailed('Codex turn/start returned no turn ID.')
    }
    this.setVisibleTextObserver(params.onVisibleText, turnID)
    try {
      params.onTurnStarted?.(threadID, turnID)
      const completion = await this.waitForTurn(threadID, turnID, params.timeoutMs)
      return this.finishTurn(threadID, turnID, completion, params.reconcileHistory)
    } finally {
      this.setVisibleTextObserver(undefined, turnID)
    }
  }

  private async finishTurn(
    threadID: string,
    turnID: string,
    completion: TurnCompletion,
    reconcileHistory: boolean,
  ): Promise<CodexTurnResult> {
    let output = this.agentMessageFor(turnID)
    let historyReconciled = false
    if (reconcileHistory) {
      try {
        const history = await this.request(
          'thread/read',
          { threadId: threadID, includeTurns: true },
          30_000,
        )
        historyReconciled = true
        const persisted = agentMessageInThreadReadResponse(history, turnID)
        if (persisted !== '') {
          output = persisted
        }
      } catch {
        // Reconciliation is best-effort.
      }
    }
    if (completion.status === 'completed' && output.trim() === '') {
      throw MuError.commandFailed('Codex completed without an agent message.')
    }
    return {
      threadID,
      turnID,
      output,
      status: completion.status,
      errorMessage: completion.errorMessage,
      historyReconciled,
    }
  }

  private async waitForTurn(
    threadID: string,
    turnID: string,
    timeoutMs: number,
  ): Promise<TurnCompletion> {
    const key = `${threadID}:${turnID}`
    const deadline = Date.now() + timeoutMs
    let nextFallbackRead = Date.now() + TURN_READ_FALLBACK_INTERVAL_MS

    while (true) {
      const notified = this.completedTurns.get(key)
      if (notified !== undefined) return notified
      if (this.processFailure !== undefined) {
        throw MuError.commandFailed(this.processFailure)
      }
      const now = Date.now()
      if (now >= deadline) {
        throw MuError.commandFailed('Timed out waiting for Codex turn completion.')
      }

      const nextWake = Math.min(deadline, nextFallbackRead)
      await sleep(Math.max(0, nextWake - now))
      const afterSleep = this.completedTurns.get(key)
      if (afterSleep !== undefined) return afterSleep
      if (this.processFailure !== undefined) {
        throw MuError.commandFailed(this.processFailure)
      }
      if (Date.now() < nextFallbackRead) continue

      const remaining = deadline - Date.now()
      if (remaining <= 0) {
        throw MuError.commandFailed('Timed out waiting for Codex turn completion.')
      }

      // turn/completed remains the primary path. Poll the authoritative thread
      // at a low cadence to catch interruptions that skip the notification.
      let response: Record<string, unknown> | undefined
      try {
        response = await this.request(
          'thread/read',
          { threadId: threadID, includeTurns: true },
          Math.min(TURN_READ_FALLBACK_TIMEOUT_MS, remaining),
        )
      } catch {
        // Poll failures are non-fatal; the notification path can still finish.
      }

      const notifiedAgain = this.completedTurns.get(key)
      if (notifiedAgain !== undefined) return notifiedAgain
      if (response !== undefined) {
        const persisted = turnCompletionInThreadReadResponse(response, threadID, turnID)
        if (persisted !== undefined) {
          if (this.completedTurns.get(key) === undefined) {
            this.completedTurns.set(key, persisted)
          }
          return this.completedTurns.get(key) ?? persisted
        }
      }
      nextFallbackRead = Date.now() + TURN_READ_FALLBACK_INTERVAL_MS
    }
  }

  // -------------------------------------------------------------------------
  // Private: JSON-RPC transport
  // -------------------------------------------------------------------------

  private async request(
    method: string,
    params: JsonObject | undefined,
    timeoutMs: number,
  ): Promise<Record<string, unknown>> {
    const requestID = this.nextRequestID
    this.nextRequestID += 1
    const message: JsonObject = { method, id: requestID }
    if (params !== undefined) message['params'] = params
    this.write(message)

    return new Promise<Record<string, unknown>>((resolve, reject) => {
      this.responses.set(requestID, {
        resolve: (response) => {
          if (response.error !== undefined) {
            reject(MuError.commandFailed(`${method}: ${response.error}`))
          } else {
            resolve(response.result ?? {})
          }
        },
        reject,
      })
      setTimeout(() => {
        if (this.responses.delete(requestID)) {
          reject(MuError.commandFailed(`Timed out waiting for ${method}.`))
        }
      }, timeoutMs)
    })
  }

  private async notify(method: string, params?: JsonObject): Promise<void> {
    const message: JsonObject = { method }
    if (params !== undefined) message['params'] = params
    this.write(message)
  }

  private write(message: JsonObject): void {
    if (this.input === undefined) {
      throw MuError.commandFailed('Could not write to Codex App Server: pipe is closed.')
    }
    try {
      this.input.write(`${encodeMuJSON(message)}\n`)
    } catch (error) {
      throw MuError.commandFailed(
        `Could not write to Codex App Server: ${(error as Error).message}`,
      )
    }
  }

  private consume(data: string): void {
    this.readBuffer += data
    let newline: number
    while ((newline = this.readBuffer.indexOf('\n')) !== -1) {
      const line = this.readBuffer.slice(0, newline)
      this.readBuffer = this.readBuffer.slice(newline + 1)
      if (line.trim() === '') continue
      let message: JsonObject
      try {
        const parsed: unknown = JSON.parse(line)
        if (typeof parsed !== 'object' || parsed === null) continue
        message = parsed as JsonObject
      } catch {
        continue
      }
      this.handle(message)
    }
  }

  private handle(message: JsonObject): void {
    const id = integerID(message['id'])
    if (id !== undefined && message['method'] === undefined) {
      const errorMessage = errorDescription(message['error'])
      const pending = this.responses.get(id)
      if (pending !== undefined) {
        this.responses.delete(id)
        pending.resolve({ result: asObject(message['result']), error: errorMessage })
      }
      return
    }

    const method = message['method']
    if (typeof method !== 'string') return
    const params = asObject(message['params'])

    if (method === 'item/completed') {
      const turnID = nonEmptyString(params['turnId'])
      const item = asObject(params['item'])
      if (turnID !== undefined && item['type'] === 'agentMessage') {
        const itemID = nonEmptyString(item['id'])
        const text = nonEmptyString(item['text'])
        if (itemID !== undefined && text !== undefined) {
          this.registerMessageItem(itemID, turnID)
          const map = new Map(this.agentMessages.get(turnID) ?? [])
          map.set(itemID, { text, phase: nonEmptyString(item['phase']) })
          this.agentMessages.set(turnID, map)
          const visible = this.preferredAgentMessage(turnID)
          if (visible !== '') this.visibleTextObservers.get(turnID)?.(visible)
        }
      }
    } else if (method === 'item/agentMessage/delta') {
      const turnID = nonEmptyString(params['turnId'])
      const itemID = nonEmptyString(params['itemId'])
      const delta = nonEmptyString(params['delta'])
      if (turnID !== undefined && itemID !== undefined && delta !== undefined) {
        this.registerMessageItem(itemID, turnID)
        const existing = this.agentMessages.get(turnID)?.get(itemID) ?? { text: '', phase: undefined }
        const map = new Map(this.agentMessages.get(turnID) ?? [])
        map.set(itemID, { ...existing, text: existing.text + delta })
        this.agentMessages.set(turnID, map)
        const visible = this.preferredAgentMessage(turnID)
        if (visible !== '') this.visibleTextObservers.get(turnID)?.(visible)
      }
    } else if (method === 'turn/completed') {
      const threadID = nonEmptyString(params['threadId'])
      const turn = asObject(params['turn'])
      const turnID = nonEmptyString(turn['id'])
      if (threadID !== undefined && turnID !== undefined) {
        const errorMessage = turnErrorMessage(turn['error'])
        const rawStatus = nonEmptyString(turn['status']) ?? 'completed'
        const completion = terminalCompletion(rawStatus, errorMessage)
        this.completedTurns.set(`${threadID}:${turnID}`, completion ?? { status: rawStatus, errorMessage })
      }
    }
  }

  private registerMessageItem(itemID: string, turnID: string): void {
    const order = this.agentMessageOrder.get(turnID) ?? []
    if (!order.includes(itemID)) {
      this.agentMessageOrder.set(turnID, [...order, itemID])
    }
  }

  private setVisibleTextObserver(
    observer: ((text: string) => void) | undefined,
    turnID: string,
  ): void {
    if (observer === undefined) {
      this.visibleTextObservers.delete(turnID)
    } else {
      this.visibleTextObservers.set(turnID, observer)
    }
  }

  private agentMessageFor(turnID: string): string {
    return preferredAgentMessageList(
      (this.agentMessageOrder.get(turnID) ?? []).flatMap((id) => {
        const message = this.agentMessages.get(turnID)?.get(id)
        return message === undefined ? [] : [message]
      }),
    )
  }

  private preferredAgentMessage(turnID: string): string {
    return this.agentMessageFor(turnID)
  }

  private rejectAllPending(reason: string): void {
    for (const [, pending] of this.responses) {
      pending.reject(MuError.commandFailed(reason))
    }
    this.responses.clear()
  }

  // -------------------------------------------------------------------------
  // Private: history
  // -------------------------------------------------------------------------

  private async listHistoryPage(
    canonicalWorkspacePathValue: string,
    isArchived: boolean,
    timeoutMs: number,
  ): Promise<ExternalConversationCandidate[]> {
    let cursor: string | undefined
    const observedCursors = new Set<string>()
    const candidates: ExternalConversationCandidate[] = []

    do {
      const params: JsonObject = {
        limit: 100,
        sortKey: 'updated_at',
        sortDirection: 'desc',
        archived: isArchived,
        cwd: canonicalWorkspacePathValue,
        sourceKinds: ['cli', 'vscode', 'exec', 'appServer'],
      }
      if (cursor !== undefined) params['cursor'] = cursor
      const response = await this.request('thread/list', params, timeoutMs)
      const threads = asArray(response['data'])
      for (const rawThread of threads) {
        const candidate = historyCandidate(
          asObject(rawThread),
          this.historyProviderInstanceKey,
          canonicalWorkspacePathValue,
          isArchived,
        )
        if (candidate !== undefined) candidates.push(candidate)
      }
      const nextCursor = nonEmptyString(response['nextCursor'])
      if (nextCursor === undefined) {
        cursor = undefined
        continue
      }
      if (nextCursor !== cursor && !observedCursors.has(nextCursor)) {
        observedCursors.add(nextCursor)
        cursor = nextCursor
      } else {
        throw MuError.commandFailed('Codex thread/list returned a repeated pagination cursor.')
      }
    } while (cursor !== undefined)

    return candidates
  }

  private get historyProviderInstanceKey(): string {
    return `codex-app-server:${fs.realpathSync(this.executableURL)}`
  }
}

// ---------------------------------------------------------------------------
// Pure helpers (mirroring the Swift static functions)
// ---------------------------------------------------------------------------

/** Parses visible user/assistant messages from a thread/read response. */
export function parseHistoryMessages(
  response: Record<string, unknown>,
  sessionID: string,
): ExternalConversationMessage[] {
  const thread = asObject(response['thread'])
  const turns = asArray(thread['turns'])
  const messages: ExternalConversationMessage[] = []
  for (let turnIndex = 0; turnIndex < turns.length; turnIndex++) {
    const turn = asObject(turns[turnIndex])
    const turnID = nonEmptyString(turn['id']) ?? `turn-${turnIndex}`
    const startedAt = codexDate(turn['startedAt'])
    const completedAt = codexDate(turn['completedAt']) ?? startedAt
    const items = asArray(turn['items'])
    for (let itemIndex = 0; itemIndex < items.length; itemIndex++) {
      const item = asObject(items[itemIndex])
      const itemID = nonEmptyString(item['id']) ?? `${sessionID}:${turnID}:item-${itemIndex}`
      switch (item['type']) {
        case 'userMessage': {
          const text = userMessageText(item)
          if (text.trim() === '') continue
          messages.push({
            nativeItemID: itemID,
            ordinal: messages.length,
            role: 'user',
            text,
            createdAt: startedAt,
          })
          break
        }
        case 'agentMessage': {
          const text = nonEmptyString(item['text'])
          if (text === undefined || text.trim() === '') continue
          let phase: string
          const rawPhase = nonEmptyString(item['phase'])
          if (rawPhase !== undefined) {
            if (rawPhase !== 'commentary' && rawPhase !== 'final_answer') continue
            phase = rawPhase
          } else {
            phase = 'final_answer'
          }
          messages.push({
            nativeItemID: itemID,
            ordinal: messages.length,
            role: 'assistant',
            text,
            phase,
            createdAt: completedAt,
          })
          break
        }
        default:
          // Reasoning, tool calls/results, plans, and system items stay out.
          break
      }
    }
  }
  return messages
}

function historyCandidate(
  thread: JsonObject,
  providerInstanceKey: string,
  canonicalWorkspacePathValue: string,
  isArchived: boolean,
): ExternalConversationCandidate | undefined {
  const nativeSessionID = nonEmptyString(thread['id'])
  const threadWorkspacePath = nonEmptyString(thread['cwd'])
  if (nativeSessionID === undefined || threadWorkspacePath === undefined) return undefined
  let canonicalThread: string
  try {
    canonicalThread = canonicalWorkspacePath(threadWorkspacePath)
  } catch {
    return undefined
  }
  if (canonicalThread !== canonicalWorkspacePathValue) return undefined

  const explicitName = nonEmptyString(thread['name'])
  const preview = nonEmptyString(thread['preview'])
  const title = explicitName ?? preview ?? `Codex task ${nativeSessionID.slice(0, 8)}`
  const agentLabel = nonEmptyString(thread['agentNickname']) ?? nonEmptyString(thread['agentRole'])
  const sourceLocation = nonEmptyString(thread['path'])
  const providerPrefix = 'codex-app-server:'
  const executablePath = providerInstanceKey.startsWith(providerPrefix)
    ? providerInstanceKey.slice(providerPrefix.length)
    : undefined
  return {
    provider: { rawValue: 'codex' },
    providerInstanceKey,
    nativeSessionID,
    title,
    canonicalWorkspacePath: canonicalWorkspacePathValue,
    createdAt: codexDate(thread['createdAt']),
    updatedAt: codexDate(thread['updatedAt']),
    isArchived,
    model: undefined,
    agentLabel,
    accessKind: 'vendor_protocol',
    resumability: 'resumable',
    sourceLocation,
    warnings: [],
    messages: [],
    runtimeInstanceIdentity: undefined,
  }
}

/** Codex represents ThreadSource as both a string and a tagged object. */
export function nativeThreadSource(rawValue: unknown): string | undefined {
  const asString = nonEmptyString(rawValue)
  if (asString !== undefined) return asString
  if (typeof rawValue === 'object' && rawValue !== null && !Array.isArray(rawValue)) {
    const object = rawValue as JsonObject
    for (const key of ['type', 'kind', 'source', 'name']) {
      const value = nonEmptyString(object[key])
      if (value !== undefined) return value
    }
    const knownSources = ['appServer', 'app_server', 'cli', 'exec', 'vscode', 'vs_code']
    const found = knownSources.find((source) => object[source] !== undefined)
    if (found !== undefined) return found
    if (Object.keys(object).length === 1) return Object.keys(object)[0]
  }
  if (Array.isArray(rawValue)) {
    for (const nested of rawValue) {
      const value = nativeThreadSource(nested)
      if (value !== undefined) return value
    }
  }
  return undefined
}

function userMessageText(item: JsonObject): string {
  if (typeof item['content'] === 'string') return item['content']
  const content = asArray(item['content'])
  return content
    .flatMap((input) => {
      const object = asObject(input)
      if (object['type'] !== 'text') return []
      const text = object['text']
      return typeof text === 'string' ? [text] : []
    })
    .join('\n')
}

function terminalCompletion(
  status: string,
  errorMessage?: string,
): TurnCompletion | undefined {
  switch (status.trim().toLowerCase()) {
    case 'completed':
      return { status: 'completed', errorMessage }
    case 'failed':
      return { status: 'failed', errorMessage }
    case 'interrupted':
      return { status: 'interrupted', errorMessage }
    case 'cancelled':
    case 'canceled':
      return { status: 'interrupted', errorMessage }
    default:
      return undefined
  }
}

function turnErrorMessage(value: unknown): string | undefined {
  if (typeof value === 'object' && value !== null) {
    const message = nonEmptyString((value as JsonObject)['message'])
    if (message !== undefined) return message
    return JSON.stringify(value)
  }
  if (typeof value === 'string' && value.trim() !== '') return value
  return undefined
}

function turnCompletionInThreadReadResponse(
  response: JsonObject,
  threadID: string,
  turnID: string,
): TurnCompletion | undefined {
  const thread = asObject(response['thread'])
  if (nonEmptyString(thread['id']) !== threadID) return undefined
  const turns = asArray(thread['turns'])
  const turn = turns
    .map(asObject)
    .find((t) => nonEmptyString(t['id']) === turnID)
  if (turn === undefined) return undefined
  const status = nonEmptyString(turn['status'])
  if (status === undefined) return undefined
  return terminalCompletion(status, turnErrorMessage(turn['error']))
}

function agentMessageInThreadReadResponse(response: JsonObject, turnID: string): string {
  const thread = asObject(response['thread'])
  const turns = asArray(thread['turns'])
  const turn = turns.map(asObject).find((t) => nonEmptyString(t['id']) === turnID)
  if (turn === undefined) return ''
  const items = asArray(turn['items'])
  const messages = items.flatMap((item) => {
    const object = asObject(item)
    if (object['type'] !== 'agentMessage') return []
    const text = nonEmptyString(object['text'])
    return text === undefined ? [] : [{ text, phase: nonEmptyString(object['phase']) }]
  })
  return preferredAgentMessageList(messages)
}

function preferredAgentMessageList(messages: readonly AgentMessage[]): string {
  const final = [...messages].reverse().find((m) => m.phase === 'final_answer')
  if (final !== undefined) return final.text
  const unknownPhase = [...messages].reverse().find((m) => m.phase === undefined)
  if (unknownPhase !== undefined) return unknownPhase.text
  return messages.at(-1)?.text ?? ''
}

function taskDeveloperInstructions(
  agent?: { displayName: string; role: string; summary: string; capabilityTags: readonly string[] },
): string {
  const identityContract = agent === undefined
    ? 'Act as the runtime-neutral execution agent selected by Mu. '
    : `Act as Mu agent ${agent.displayName}, role ${agent.role}. ${agent.summary} Capability tags: ${agent.capabilityTags.length === 0 ? 'none' : agent.capabilityTags.join(', ')}. `
  return (
    identityContract
    + 'This is a strictly read-only task. You may inspect files and run commands only '
    + 'when they cannot mutate the workspace. Do not create, edit, rename, or delete '
    + 'files; do not use network access; do not request elevated permissions; and do '
    + 'not perform destructive actions. If the objective requires a mutation, explain '
    + 'the blocked action instead of performing it. Return a concise final answer with '
    + 'the evidence you actually observed.'
  )
}

export function taskPrompt(task: TaskRecord): string {
  return [
    'Mu created this read-only execution Task.',
    '',
    `Title: ${task.title}`,
    'Objective:',
    task.objective,
    '',
    'Success criteria:',
    bullets(task.successCriteria),
    '',
    'Blocking constraints:',
    bullets(task.constraints),
    '',
    'Pending steps:',
    bullets(task.pendingSteps),
    '',
    `Repository root: ${task.repositoryPath}`,
    '',
    'Work only within the read-only contract and report the result.',
  ].join('\n')
}

function bullets(values: readonly string[]): string {
  return values.length === 0 ? '- None specified' : values.map((v) => `- ${v}`).join('\n')
}

/** Codex dates: ms epoch when >= 1e11, else seconds; also ISO8601 strings. */
function codexDate(value: unknown): Date | undefined {
  if (typeof value === 'boolean') return undefined
  if (typeof value === 'number') {
    const seconds = Math.abs(value) >= 100_000_000_000 ? value / 1000 : value
    return new Date(seconds * 1000)
  }
  if (typeof value === 'string') {
    const numeric = Number(value)
    if (Number.isFinite(numeric)) {
      const seconds = Math.abs(numeric) >= 100_000_000_000 ? numeric / 1000 : numeric
      return new Date(seconds * 1000)
    }
    const date = new Date(value)
    return Number.isNaN(date.getTime()) ? undefined : date
  }
  return undefined
}

function errorDescription(value: unknown): string | undefined {
  if (typeof value === 'object' && value !== null) {
    const message = nonEmptyString((value as JsonObject)['message'])
    return message ?? JSON.stringify(value)
  }
  return undefined
}

function nonEmptyString(value: unknown): string | undefined {
  if (typeof value !== 'string') return undefined
  const trimmed = value.trim()
  return trimmed === '' ? undefined : trimmed
}

function integerID(value: unknown): number | undefined {
  return typeof value === 'number' ? value : undefined
}

function asObject(value: unknown): JsonObject {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as JsonObject)
    : {}
}

function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : []
}

function isExecutableFile(p: string): boolean {
  try {
    fs.accessSync(p, fs.constants.X_OK)
    return fs.statSync(p).isFile()
  } catch {
    return false
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

/**
 * Codex executable discovery, mirroring CodexDiscovery.swift. Prefers an
 * explicitly configured executable, then standalone Codex builds on PATH or
 * in standard install locations, and only falls back to the Codex binary
 * bundled inside the ChatGPT desktop app (its app-server stdio handshake is
 * known to hang, so it is a last resort rather than the primary discovery).
 */
export function codexExecutableURL(
  environment: NodeJS.ProcessEnv = process.env,
): string | undefined {
  for (const key of ['MU_CODEX_EXECUTABLE', 'CODEX_EXECUTABLE']) {
    const value = environment[key]?.trim()
    if (value !== undefined && value !== '' && isExecutableFile(value)) {
      return canonicalize(value)
    }
  }
  const home = os.homedir()
  const candidates = [
    path.join(home, '.codex/bin/codex'),
    '/opt/homebrew/bin/codex',
    '/usr/local/bin/codex',
    '/usr/bin/codex',
  ]
  const pathEnv = environment['PATH'] ?? ''
  for (const dir of pathEnv.split(':')) {
    if (dir !== '') candidates.push(path.join(dir, 'codex'))
  }
  candidates.push(
    '/Applications/Codex.app/Contents/Resources/codex',
    '/Applications/ChatGPT.app/Contents/Resources/codex',
  )
  const seen = new Set<string>()
  for (const candidate of candidates) {
    if (seen.has(candidate)) continue
    seen.add(candidate)
    if (isExecutableFile(candidate)) {
      return canonicalize(candidate)
    }
  }
  return undefined
}

function canonicalize(p: string): string {
  return fs.realpathSync(p)
}
