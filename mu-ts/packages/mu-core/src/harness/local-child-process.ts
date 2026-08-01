import { MuError } from '../errors.ts'
import { uuid } from '../identity.ts'
import type {
  CodexProbeResult,
  CodexTurnResult,
  TaskRecord,
} from '../models.ts'
import type { ExternalConversationCandidate } from '../conversation-history.ts'
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
  type ConversationProvider,
  providerEqual,
} from '../types.ts'
import type {
  Harness,
  HarnessArtifactRecord,
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
    onSessionStarted?: (sessionID: string) => void
    onVisibleText?: (text: string) => void
  }): Promise<ClaudeCodeTurnResult>
  interrupt(): void
}

export interface CodexClientLike {
  probe(): Promise<CodexProbeResult>
  listHistory(workspacePath: string, timeoutMs?: number): Promise<ExternalConversationCandidate[]>
  runReadOnlyTask(params: {
    task: TaskRecord
    contextPack?: ProjectContextPackRecord
    promptOverride?: string
    clientUserMessageID: string
    timeoutMs?: number
    onThreadStarted?: (threadID: string) => void
    onTurnStarted?: (threadID: string, turnID: string) => void
    onVisibleText?: (text: string) => void
  }): Promise<CodexTurnResult>
  runReadOnlyContinuation(params: {
    threadID: string
    task: TaskRecord
    prompt: string
    clientUserMessageID: string
    timeoutMs?: number
    onTurnStarted?: (threadID: string, turnID: string) => void
    onVisibleText?: (text: string) => void
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
 * One active turn at a time per harness instance — the control plane creates
 * one harness per runtime endpoint and serializes turns on it.
 */
export class LocalChildProcessHarness implements Harness {
  readonly capabilities: HarnessCapabilities

  private readonly options: LocalChildProcessHarnessOptions
  private claudeCodeClient?: ClaudeCodeClientLike
  private codexClient?: CodexClientLike
  private activeCodex?: { threadID: string; turnID: string }

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
        'One active turn per harness instance.',
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
    this.claudeCodeClient ??= new ClaudeCodeClient({ executableURL })
    return this.claudeCodeClient
  }

  private codex(): CodexClientLike {
    const injected = this.options.codexClient
    if (injected !== undefined) return injected
    const executableURL = this.options.codexExecutable
    if (executableURL === undefined || executableURL === '') {
      throw MuError.capabilityMissing('LocalChildProcessHarness: Codex executable is not configured.')
    }
    this.codexClient ??= new CodexAppServerClient({ executableURL })
    return this.codexClient
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

  async *runTurn(input: HarnessTurnInput, signal?: AbortSignal): AsyncIterable<HarnessTurnEvent> {
    const provider = input.provider
    if (provider === undefined) {
      throw MuError.invalidTransition('LocalChildProcessHarness requires an input.provider.')
    }
    if (providerEqual(provider, CLAUDE_CODE_PROVIDER)) {
      yield* this.runClaudeTurn(input, signal)
    } else if (providerEqual(provider, CODE_PROVIDER)) {
      yield* this.runCodexTurn(input, signal)
    } else {
      throw MuError.capabilityMissing(
        `LocalChildProcessHarness does not support provider '${provider.rawValue}'.`,
      )
    }
  }

  async interrupt(sessionID: string): Promise<void> {
    const active = this.activeCodex
    if (active !== undefined && sessionID === active.threadID) {
      await this.codex().interrupt(active.threadID, active.turnID)
    } else {
      // Claude mode: the client kills its own active process.
      this.claudeCode().interrupt()
    }
  }

  /** Stops long-lived clients (e.g. the Codex app-server child process). */
  stop(): void {
    this.codexClient?.stop()
  }

  async listArtifacts(_sessionID: string): Promise<HarnessArtifactRecord[]> {
    return []
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

  // -- Claude ---------------------------------------------------------------

  private async *runClaudeTurn(
    input: HarnessTurnInput,
    signal?: AbortSignal,
  ): AsyncIterable<HarnessTurnEvent> {
    const queue = new EventQueue<HarnessTurnEvent>()
    const onAbort = () => this.claudeCode().interrupt()
    signal?.addEventListener('abort', onAbort, { once: true })
    // The stream parser reports cumulative visible text per delta; normalize
    // to per-delta chunks so consumers can accumulate without duplication.
    let lastVisible = ''
    try {
      let pending: Promise<HarnessTurnResult>
      try {
        pending = this.claudeCode()
          .runReadOnlyTask({
            task: requireTask(input),
            contextPack: requireContextPack(input),
            sessionID: input.sessionID,
            resumeSessionID: input.resumeSessionID,
            promptOverride: input.promptOverride,
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
  ): AsyncIterable<HarnessTurnEvent> {
    const queue = new EventQueue<HarnessTurnEvent>()
    const client = this.codex()
    const clientUserMessageID = `mu-${uuid()}`
    let pending: Promise<CodexTurnResult>

    if (input.resumeSessionID !== undefined && input.resumeSessionID.trim() !== '') {
      pending = client.runReadOnlyContinuation({
        threadID: input.resumeSessionID.trim(),
        task: requireTask(input),
        prompt:
          input.promptOverride ?? renderedContextPackMarkdown(requireContextPack(input)),
        clientUserMessageID,
        onTurnStarted: (threadID, turnID) => {
          this.activeCodex = { threadID, turnID }
          queue.push({ kind: 'session_started', sessionID: threadID })
        },
        onVisibleText: (text) => queue.push({ kind: 'visible_text', text }),
      })
    } else {
      pending = client.runReadOnlyTask({
        task: requireTask(input),
        contextPack: requireContextPack(input),
        promptOverride: input.promptOverride,
        clientUserMessageID,
        onThreadStarted: (threadID) => queue.push({ kind: 'session_started', sessionID: threadID }),
        onTurnStarted: (threadID, turnID) => {
          this.activeCodex = { threadID, turnID }
        },
        onVisibleText: (text) => queue.push({ kind: 'visible_text', text }),
      })
    }

    const onAbort = () => {
      const active = this.activeCodex
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

export function createLocalHarness(
  options: LocalChildProcessHarnessOptions = {},
): LocalChildProcessHarness {
  return new LocalChildProcessHarness(options)
}
