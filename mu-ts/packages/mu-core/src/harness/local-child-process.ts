import { MuError } from '../errors.ts'
import { uuid } from '../identity.ts'
import type {
  CodexProbeResult,
  CodexTurnResult,
  TaskRecord,
} from '../models.ts'
import type {
  ExternalConversationCandidate,
  ExternalConversationMessage,
} from '../conversation-history.ts'
import type { ProjectContextPackRecord } from '../project-kernel/index.ts'
import { renderedContextPackMarkdown } from '../project-kernel/index.ts'
import {
  ClaudeCodeClient,
  type ClaudeCodeProbeResult,
  type ClaudeCodeTurnResult,
} from '../runtime-clients/claude-code.ts'
import { CodexAppServerClient } from '../runtime-clients/codex.ts'
import {
  CLAUDE_CODE_PROVIDER,
  CODE_PROVIDER,
  type AgentRuntimeEndpointScope,
  type ConversationProvider,
  providerEqual,
} from '../types.ts'
import type {
  Harness,
  HarnessArtifactRecord,
  HarnessActivityEvent,
  HarnessCapabilities,
  HarnessProbeResult,
  HarnessTurnEvent,
  HarnessTurnInput,
  HarnessTurnResult,
} from './types.ts'

// ---------------------------------------------------------------------------
// Structural client contracts (injectable in tests — a fake replaces the
// child process, per the Phase 4 test strategy).
// ---------------------------------------------------------------------------

export interface ClaudeCodeClientLike {
  probe(): ClaudeCodeProbeResult
  runReadOnlyTask(params: {
    task: TaskRecord
    contextPack: ProjectContextPackRecord
    sessionID?: string
    resumeSessionID?: string
    promptOverride?: string
    reasoningEffort?: string
    onSessionStarted?: (sessionID: string) => void
    onVisibleText?: (text: string) => void
    onActivity?: (activity: HarnessActivityEvent) => void
  }): Promise<ClaudeCodeTurnResult>
  interrupt(): void
}

export interface CodexClientLike {
  probe(): Promise<CodexProbeResult>
  /** Starts the persistent app-server without creating a thread. */
  warm?(): Promise<void>
  listHistory(workspacePath: string, timeoutMs?: number): Promise<ExternalConversationCandidate[]>
  readHistory?(
    sessionID: string,
    workspacePath: string,
    timeoutMs?: number,
  ): Promise<ExternalConversationMessage[]>
  runReadOnlyTask(params: {
    task: TaskRecord
    contextPack?: ProjectContextPackRecord
    promptOverride?: string
    reasoningEffort?: string
    clientUserMessageID: string
    timeoutMs?: number
    onThreadStarted?: (threadID: string) => void
    onTurnStarted?: (threadID: string, turnID: string) => void
    onVisibleText?: (text: string) => void
    onActivity?: (activity: HarnessActivityEvent) => void
  }): Promise<CodexTurnResult>
  runReadOnlyContinuation(params: {
    threadID: string
    task: TaskRecord
    prompt: string
    clientUserMessageID: string
    reasoningEffort?: string
    timeoutMs?: number
    onTurnStarted?: (threadID: string, turnID: string) => void
    onVisibleText?: (text: string) => void
    onActivity?: (activity: HarnessActivityEvent) => void
  }): Promise<CodexTurnResult>
  interrupt(threadID: string, turnID: string): Promise<void>
  stop(): void
}

export interface LocalChildProcessHarnessOptions {
  readonly claudeCodeExecutable?: string
  readonly codexExecutable?: string
  /** Injectable fakes for tests; production constructs real clients lazily. */
  readonly claudeCodeClient?: ClaudeCodeClientLike
  readonly codexClient?: CodexClientLike
}

// ---------------------------------------------------------------------------
// Async event queue — client callbacks push, the generator pulls.
// ---------------------------------------------------------------------------

class EventQueue<T> {
  private items: T[] = []
  private waiters: Array<() => void> = []

  push(item: T): void {
    this.items.push(item)
    this.waiters.shift()?.()
  }

  async next(): Promise<T> {
    if (this.items.length > 0) return this.items.shift() as T
    await new Promise<void>((resolve) => this.waiters.push(resolve))
    return this.items.shift() as T
  }
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/**
 * Local mode: drives the Phase 3 runtime clients as child processes.
 * Endpoint-scoped clients keep separate Codex app-server processes and Claude
 * session state for distinct stable instance keys.
 */
export class LocalChildProcessHarness implements Harness {
  readonly capabilities: HarnessCapabilities

  private readonly options: LocalChildProcessHarnessOptions
  private readonly claudeCodeClients = new Map<string, ClaudeCodeClientLike>()
  private readonly codexClients = new Map<string, CodexClientLike>()
  private readonly activeCodex = new Map<string, { threadID: string; turnID: string }>()

  constructor(options: LocalChildProcessHarnessOptions = {}) {
    this.options = options
    const providers: ConversationProvider[] = []
    if (this.hasClaudeCode()) providers.push(CLAUDE_CODE_PROVIDER)
    if (this.hasCodex()) providers.push(CODE_PROVIDER)
    this.capabilities = {
      mode: 'local',
      providers,
      controlMode: 'managed',
      observationFidelity: 'native_stream',
      supportsInterrupt: true,
      supportsArtifacts: false,
      supportsEventStream: true,
      notes: [
        'Runs Agent CLI executables as child processes.',
        'Endpoint-scoped clients keep terminal/app-server state isolated.',
        'Artifact listing arrives with the Phase 5 control plane.',
      ],
    }
  }

  private hasClaudeCode(): boolean {
    return this.options.claudeCodeClient !== undefined || this.options.claudeCodeExecutable !== undefined
  }

  private hasCodex(): boolean {
    return this.options.codexClient !== undefined || this.options.codexExecutable !== undefined
  }

  private claudeCode(): ClaudeCodeClientLike {
    const injected = this.options.claudeCodeClient
    if (injected !== undefined) return injected
    const executableURL = this.options.claudeCodeExecutable
    if (executableURL === undefined || executableURL === '') {
      throw MuError.capabilityMissing('LocalChildProcessHarness: Claude Code executable is not configured.')
    }
    const key = 'default'
    let client = this.claudeCodeClients.get(key)
    if (client === undefined) {
      client = new ClaudeCodeClient({ executableURL })
      this.claudeCodeClients.set(key, client)
    }
    return client
  }

  private codex(): CodexClientLike {
    const injected = this.options.codexClient
    if (injected !== undefined) return injected
    const executableURL = this.options.codexExecutable
    if (executableURL === undefined || executableURL === '') {
      throw MuError.capabilityMissing('LocalChildProcessHarness: Codex executable is not configured.')
    }
    const key = 'default'
    let client = this.codexClients.get(key)
    if (client === undefined) {
      client = new CodexAppServerClient({ executableURL })
      this.codexClients.set(key, client)
    }
    return client
  }

  private endpointKey(scope: AgentRuntimeEndpointScope): string {
    return scope.instanceIdentity.stableInstanceKey.trim() || scope.endpointID
  }

  private claudeCodeFor(scope: AgentRuntimeEndpointScope): ClaudeCodeClientLike {
    const injected = this.options.claudeCodeClient
    if (injected !== undefined) return injected
    const executableURL = this.options.claudeCodeExecutable
    if (executableURL === undefined || executableURL === '') {
      throw MuError.capabilityMissing('LocalChildProcessHarness: Claude Code executable is not configured.')
    }
    const key = this.endpointKey(scope)
    let client = this.claudeCodeClients.get(key)
    if (client === undefined) {
      client = new ClaudeCodeClient({ executableURL })
      this.claudeCodeClients.set(key, client)
    }
    return client
  }

  private codexFor(scope: AgentRuntimeEndpointScope): CodexClientLike {
    const injected = this.options.codexClient
    if (injected !== undefined) return injected
    const executableURL = this.options.codexExecutable
    if (executableURL === undefined || executableURL === '') {
      throw MuError.capabilityMissing('LocalChildProcessHarness: Codex executable is not configured.')
    }
    const key = this.endpointKey(scope)
    let client = this.codexClients.get(key)
    if (client === undefined) {
      client = new CodexAppServerClient({ executableURL })
      this.codexClients.set(key, client)
    }
    return client
  }

  async warmEndpoint(scope: AgentRuntimeEndpointScope): Promise<void> {
    if (!providerEqual(scope.instanceIdentity.provider, CODE_PROVIDER)) return
    if (!this.hasCodex()) return
    await this.codexFor(scope).warm?.()
  }

  async probe(): Promise<HarnessProbeResult> {
    const startedAt = Date.now()
    if (this.capabilities.providers.length === 0) {
      return {
        ok: false,
        mode: 'local',
        message: 'No runtime executables are configured for the local harness.',
        latencyMilliseconds: Date.now() - startedAt,
      }
    }
    const reports: string[] = []
    let loggedIn = false
    let runtimeVersion: string | undefined
    if (this.hasClaudeCode()) {
      try {
        const result = this.claudeCode().probe()
        reports.push(`Claude Code ${result.version} (logged in: ${result.loggedIn})`)
        loggedIn = loggedIn || result.loggedIn
        runtimeVersion = result.version
      } catch (error) {
        reports.push(`Claude Code unavailable: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
    if (this.hasCodex()) {
      try {
        const result = await this.codex().probe()
        reports.push(`Codex ${result.userAgent} (signed in: ${result.signedIn})`)
        loggedIn = loggedIn || result.signedIn
      } catch (error) {
        reports.push(`Codex unavailable: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
    return {
      ok: reports.some((r) => !r.includes('unavailable')),
      mode: 'local',
      runtimeVersion,
      loggedIn,
      message: reports.join('; '),
      latencyMilliseconds: Date.now() - startedAt,
    }
  }

  /** Probe only the runtime represented by this endpoint. */
  async probeEndpoint(scope: AgentRuntimeEndpointScope): Promise<HarnessProbeResult> {
    const startedAt = Date.now()
    const provider = scope.instanceIdentity.provider
    try {
      if (providerEqual(provider, CLAUDE_CODE_PROVIDER)) {
        if (!this.hasClaudeCode()) {
          return {
            ok: false,
            mode: 'local',
            message: 'Claude Code executable is unavailable for this endpoint.',
            latencyMilliseconds: Date.now() - startedAt,
          }
        }
        const result = this.claudeCodeFor(scope).probe()
        return {
          ok: result.loggedIn,
          mode: 'local',
          runtimeVersion: result.version,
          loggedIn: result.loggedIn,
          message: `Claude Code ${result.version} (logged in: ${result.loggedIn}).`,
          latencyMilliseconds: Date.now() - startedAt,
        }
      }
      if (providerEqual(provider, CODE_PROVIDER)) {
        if (!this.hasCodex()) {
          return {
            ok: false,
            mode: 'local',
            message: 'Codex executable is unavailable for this endpoint.',
            latencyMilliseconds: Date.now() - startedAt,
          }
        }
        const result = await this.codexFor(scope).probe()
        return {
          ok: result.signedIn,
          mode: 'local',
          runtimeVersion: result.userAgent,
          loggedIn: result.signedIn,
          message: `Codex ${result.userAgent} (signed in: ${result.signedIn}).`,
          latencyMilliseconds: Date.now() - startedAt,
        }
      }
      return {
        ok: false,
        mode: 'local',
        message: `Provider '${provider.rawValue}' is not supported by the local harness.`,
        latencyMilliseconds: Date.now() - startedAt,
      }
    } catch (error) {
      return {
        ok: false,
        mode: 'local',
        message: error instanceof Error ? error.message : String(error),
        latencyMilliseconds: Date.now() - startedAt,
      }
    }
  }

  async *runTurn(input: HarnessTurnInput, signal?: AbortSignal): AsyncIterable<HarnessTurnEvent> {
    const provider = input.provider
    if (provider === undefined) {
      throw MuError.invalidTransition('LocalChildProcessHarness requires an input.provider.')
    }
    if (providerEqual(provider, CLAUDE_CODE_PROVIDER)) {
      yield* this.runClaudeTurn(input, signal, this.claudeCode(), 'default')
    } else if (providerEqual(provider, CODE_PROVIDER)) {
      yield* this.runCodexTurn(input, signal, this.codex(), 'default')
    } else {
      throw MuError.capabilityMissing(
        `LocalChildProcessHarness does not support provider '${provider.rawValue}'.`,
      )
    }
  }

  async *runTurnForEndpoint(
    scope: AgentRuntimeEndpointScope,
    input: HarnessTurnInput,
    signal?: AbortSignal,
  ): AsyncIterable<HarnessTurnEvent> {
    const provider = scope.instanceIdentity.provider
    if (input.provider !== undefined && !providerEqual(input.provider, provider)) {
      throw MuError.invalidTransition(
        `Endpoint ${scope.endpointID} is bound to '${provider.rawValue}', not '${input.provider.rawValue}'.`,
      )
    }
    const key = this.endpointKey(scope)
    if (providerEqual(provider, CLAUDE_CODE_PROVIDER)) {
      yield* this.runClaudeTurn({ ...input, provider }, signal, this.claudeCodeFor(scope), key)
    } else if (providerEqual(provider, CODE_PROVIDER)) {
      yield* this.runCodexTurn({ ...input, provider }, signal, this.codexFor(scope), key)
    } else {
      throw MuError.capabilityMissing(`Local harness does not support '${provider.rawValue}'.`)
    }
  }

  async interrupt(sessionID: string): Promise<void> {
    const active = this.activeCodex.get('default')
    if (active !== undefined && sessionID === active.threadID) {
      await this.codex().interrupt(active.threadID, active.turnID)
    } else {
      // Claude mode: the client kills its own active process.
      this.claudeCode().interrupt()
    }
  }

  async interruptForEndpoint(scope: AgentRuntimeEndpointScope, sessionID: string): Promise<void> {
    const provider = scope.instanceIdentity.provider
    const key = this.endpointKey(scope)
    if (providerEqual(provider, CODE_PROVIDER)) {
      const active = this.activeCodex.get(key)
      if (active === undefined || sessionID !== active.threadID) {
        throw MuError.invalidTransition(`No active Codex turn belongs to endpoint ${scope.endpointID}.`)
      }
      await this.codexFor(scope).interrupt(active.threadID, active.turnID)
      return
    }
    if (providerEqual(provider, CLAUDE_CODE_PROVIDER)) {
      this.claudeCodeFor(scope).interrupt()
      return
    }
    throw MuError.capabilityMissing(`Local harness cannot interrupt '${provider.rawValue}'.`)
  }

  /** Stops long-lived clients (e.g. the Codex app-server child process). */
  stop(): void {
    const clients = new Set(this.codexClients.values())
    for (const client of clients) client.stop()
  }

  async listArtifacts(_sessionID: string): Promise<HarnessArtifactRecord[]> {
    return []
  }

  async listArtifactsForEndpoint(
    scope: AgentRuntimeEndpointScope,
    sessionID: string,
  ): Promise<HarnessArtifactRecord[]> {
    if (!providerEqual(scope.instanceIdentity.provider, CODE_PROVIDER)
      && !providerEqual(scope.instanceIdentity.provider, CLAUDE_CODE_PROVIDER)) {
      throw MuError.capabilityMissing(`Local harness cannot list artifacts for '${scope.instanceIdentity.provider.rawValue}'.`)
    }
    return this.listArtifacts(sessionID)
  }

  /**
   * History discovery uses the host's own client process: Codex threads are
   * only visible to the app-server process that created them, so a fresh
   * client would see nothing (verified in real acceptance). Claude Code
   * history is not yet exposed here.
   */
  async discoverHistory(workspacePath: string) {
    if (this.hasCodex()) {
      return this.codex().listHistory(workspacePath, 30_000)
    }
    return []
  }

  async discoverHistoryForEndpoint(
    scope: AgentRuntimeEndpointScope,
    workspacePath: string,
  ): Promise<ExternalConversationCandidate[]> {
    if (!providerEqual(scope.instanceIdentity.provider, CODE_PROVIDER)) return []
    if (!this.hasCodex()) return []
    return this.codexFor(scope).listHistory(workspacePath, 30_000)
  }

  async hydrateHistoryForEndpoint(
    scope: AgentRuntimeEndpointScope,
    candidate: ExternalConversationCandidate,
  ): Promise<ExternalConversationCandidate> {
    if (!providerEqual(scope.instanceIdentity.provider, CODE_PROVIDER)) {
      throw MuError.capabilityMissing(
        `History hydration is not available for '${scope.instanceIdentity.provider.rawValue}'.`,
      )
    }
    const client = this.codexFor(scope)
    const readHistory = client.readHistory
    if (readHistory === undefined) {
      throw MuError.capabilityMissing('Codex history hydration is not available for this client.')
    }
    const messages = await readHistory.call(
      client,
      candidate.nativeSessionID,
      candidate.canonicalWorkspacePath,
      30_000,
    )
    return {
      ...candidate,
      messages,
      discoveredMessageCount: messages.length,
      runtimeInstanceIdentity: scope.instanceIdentity,
    }
  }

  // -- Claude ---------------------------------------------------------------

  private async *runClaudeTurn(
    input: HarnessTurnInput,
    signal?: AbortSignal,
    client: ClaudeCodeClientLike = this.claudeCode(),
    _endpointKey = 'default',
  ): AsyncIterable<HarnessTurnEvent> {
    const queue = new EventQueue<HarnessTurnEvent>()
    const onAbort = () => client.interrupt()
    signal?.addEventListener('abort', onAbort, { once: true })
    // The stream parser reports cumulative visible text per delta; normalize
    // to per-delta chunks so consumers can accumulate without duplication.
    let lastVisible = ''
    try {
      let pending: Promise<HarnessTurnResult>
      try {
        pending = client
          .runReadOnlyTask({
            task: requireTask(input),
            contextPack: requireContextPack(input),
            sessionID: input.sessionID,
            resumeSessionID: input.resumeSessionID,
            promptOverride: input.promptOverride,
            reasoningEffort: input.reasoningEffort,
            onSessionStarted: (sessionID) =>
              queue.push({ kind: 'session_started', sessionID }),
            onVisibleText: (text) => {
              if (text !== lastVisible) {
                if (text.length > lastVisible.length && text.startsWith(lastVisible)) {
                  queue.push({ kind: 'visible_text', text: text.slice(lastVisible.length) })
                } else {
                  // Replacement (e.g. an assistant message overriding partial
                  // deltas): emit the growth relative to the previous text.
                  queue.push({ kind: 'visible_text', text: text })
                }
              }
              lastVisible = text
            },
            onActivity: (activity) => queue.push({ kind: 'activity', activity }),
          })
          .then(mapClaudeResult)
      } catch (error) {
        queue.push({ kind: 'failed', errorMessage: errorMessage(error) })
        yield* this.drain(queue)
        return
      }
      // Client callbacks push stream events; the settled promise pushes the
      // terminal event. The client runs concurrently, so queue order is
      // preserved: stream events precede the terminal event.
      pending.then(
        (result) =>
          queue.push(
            result.status === 'cancelled'
              ? { kind: 'cancelled' }
              : { kind: 'completed', result },
          ),
        (error) => queue.push({ kind: 'failed', errorMessage: errorMessage(error) }),
      )
      yield* this.drain(queue)
    } finally {
      signal?.removeEventListener('abort', onAbort)
    }
  }

  private async *drain(queue: EventQueue<HarnessTurnEvent>): AsyncIterable<HarnessTurnEvent> {
    while (true) {
      const event = await queue.next()
      yield event
      if (event.kind === 'completed' || event.kind === 'failed' || event.kind === 'cancelled') return
    }
  }

  // -- Codex ----------------------------------------------------------------

  private async *runCodexTurn(
    input: HarnessTurnInput,
    signal?: AbortSignal,
    client: CodexClientLike = this.codex(),
    endpointKey = 'default',
  ): AsyncIterable<HarnessTurnEvent> {
    const queue = new EventQueue<HarnessTurnEvent>()
    const clientUserMessageID = `mu-${uuid()}`
    let pending: Promise<CodexTurnResult>
    const onVisibleText = (text: string) => queue.push({ kind: 'visible_text', text })
    const onActivity = (activity: HarnessActivityEvent) => queue.push({ kind: 'activity', activity })

    if (input.resumeSessionID !== undefined && input.resumeSessionID.trim() !== '') {
      const continuation = client.runReadOnlyContinuation({
        threadID: input.resumeSessionID.trim(),
        task: requireTask(input),
        prompt:
          input.promptOverride ?? renderedContextPackMarkdown(requireContextPack(input)),
        reasoningEffort: input.reasoningEffort,
        clientUserMessageID,
        onTurnStarted: (threadID, turnID) => {
          this.activeCodex.set(endpointKey, { threadID, turnID })
          queue.push({ kind: 'session_started', sessionID: threadID })
        },
        onVisibleText,
        onActivity,
      })
      pending = continuation.catch((error) => {
        if (!isMissingCodexThreadError(error)) throw error

        // A persisted native thread may disappear when the Codex App Server
        // restarts or its state database changes. Recreate one thread once and
        // replay the same bounded Project prompt; the service persists the new
        // session_started event and binding identity through the normal path.
        return client.runReadOnlyTask({
          task: requireTask(input),
          contextPack: requireContextPack(input),
          promptOverride: input.promptOverride,
          reasoningEffort: input.reasoningEffort,
          clientUserMessageID,
          onThreadStarted: (threadID) => queue.push({ kind: 'session_started', sessionID: threadID }),
          onTurnStarted: (threadID, turnID) => {
            this.activeCodex.set(endpointKey, { threadID, turnID })
          },
          onVisibleText,
          onActivity,
        })
      })
    } else {
      pending = client.runReadOnlyTask({
        task: requireTask(input),
        contextPack: requireContextPack(input),
        promptOverride: input.promptOverride,
        reasoningEffort: input.reasoningEffort,
        clientUserMessageID,
        onThreadStarted: (threadID) => queue.push({ kind: 'session_started', sessionID: threadID }),
        onTurnStarted: (threadID, turnID) => {
          this.activeCodex.set(endpointKey, { threadID, turnID })
        },
        onVisibleText: (text) => queue.push({ kind: 'visible_text', text }),
        onActivity: (activity) => queue.push({ kind: 'activity', activity }),
      })
    }

    const onAbort = () => {
      const active = this.activeCodex.get(endpointKey)
      if (active !== undefined) {
        void client.interrupt(active.threadID, active.turnID).catch(() => undefined)
      }
    }
    signal?.addEventListener('abort', onAbort, { once: true })

    let result: CodexTurnResult | undefined
    let failure: string | undefined
    try {
      result = await pending
    } catch (error) {
      failure = error instanceof Error ? error.message : String(error)
    } finally {
      signal?.removeEventListener('abort', onAbort)
      this.activeCodex.delete(endpointKey)
    }

    // Flush any events the callbacks pushed before the turn settled.
    if (failure !== undefined) {
      queue.push({ kind: 'failed', errorMessage: failure })
    } else if (result !== undefined) {
      const mapped = mapCodexResult(result)
      queue.push(
        mapped.status === 'cancelled'
          ? { kind: 'cancelled' }
          : { kind: 'completed', result: mapped },
      )
    } else if (signal?.aborted === true) {
      queue.push({ kind: 'cancelled' })
    }
    yield* this.drain(queue)
  }
}

// ---------------------------------------------------------------------------
// Mapping helpers
// ---------------------------------------------------------------------------

function requireTask(input: HarnessTurnInput): TaskRecord {
  if (input.task === undefined) {
    throw MuError.invalidTransition('LocalChildProcessHarness requires input.task in local mode.')
  }
  return input.task
}

function requireContextPack(input: HarnessTurnInput): ProjectContextPackRecord {
  if (input.contextPack === undefined) {
    throw MuError.invalidTransition(
      'LocalChildProcessHarness requires input.contextPack in local mode.',
    )
  }
  return input.contextPack
}

function mapClaudeResult(result: ClaudeCodeTurnResult): HarnessTurnResult {
  return {
    status: result.status === 'cancelled' ? 'cancelled' : result.status === 'failed' ? 'failed' : 'success',
    sessionID: result.sessionID,
    output: result.output,
    model: result.model,
    costUSD: result.costUSD,
    durationMilliseconds: result.durationMilliseconds,
    errorMessage: result.errorMessage,
  }
}

function mapCodexResult(result: CodexTurnResult): HarnessTurnResult {
  const interrupted = result.status === 'interrupted'
  const failed = result.status === 'failed'
  return {
    status: interrupted ? 'cancelled' : failed ? 'failed' : 'success',
    sessionID: result.threadID,
    output: result.output,
    errorMessage: result.errorMessage,
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function isMissingCodexThreadError(error: unknown): boolean {
  const message = errorMessage(error).toLowerCase()
  return message.includes('thread not found')
    || message.includes('thread_not_found')
    || message.includes('unknown thread')
}

export function createLocalHarness(
  options: LocalChildProcessHarnessOptions = {},
): LocalChildProcessHarness {
  return new LocalChildProcessHarness(options)
}
