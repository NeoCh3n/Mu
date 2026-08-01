import { spawn } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { MuError } from '../errors.ts'
import { uuid, type UUID } from '../identity.ts'
import type { TaskRecord } from '../models.ts'
import type { ProjectContextPackRecord } from '../project-kernel/index.ts'
import { renderedContextPackMarkdown } from '../project-kernel/index.ts'
import { runProcess } from '../persistence/process-capture.ts'

// ---------------------------------------------------------------------------
// Result types
// ---------------------------------------------------------------------------

export interface ClaudeCodeProbeResult {
  readonly version: string
  readonly loggedIn: boolean
  readonly authMethod: string
  readonly apiProvider: string
}

export interface ClaudeCodeTurnResult {
  readonly sessionID: string
  readonly output: string
  readonly status: string
  readonly model?: string
  readonly costUSD?: number
  readonly durationMilliseconds?: number
  readonly errorMessage?: string
}

export interface ClaudeCodeStreamState {
  readonly sessionID?: string
  readonly model?: string
  readonly visibleText: string
  readonly finalResult?: string
  readonly status?: string
  readonly costUSD?: number
  readonly durationMilliseconds?: number
  readonly errorMessage?: string
}

// ---------------------------------------------------------------------------
// Stream parser
// ---------------------------------------------------------------------------

type JsonObject = Record<string, unknown>

function nonempty(value: unknown): string | undefined {
  if (typeof value !== 'string') return undefined
  const trimmed = value.trim()
  return trimmed === '' ? undefined : trimmed
}

function asNumber(value: unknown): number | undefined {
  if (typeof value === 'number') return value
  if (typeof value === 'string') {
    const n = Number(value)
    return Number.isFinite(n) ? n : undefined
  }
  return undefined
}

function asInteger(value: unknown): number | undefined {
  const n = asNumber(value)
  return n === undefined ? undefined : Math.trunc(n)
}

/** Visible text from an assistant message's `content` field. */
function visibleText(from: unknown): string {
  if (typeof from === 'string') {
    return from.trim()
  }
  if (!Array.isArray(from)) return ''
  return from
    .flatMap((block) => {
      if (typeof block !== 'object' || block === null) return []
      const object = block as JsonObject
      if (object['type'] !== 'text') return []
      const text = object['text']
      return typeof text === 'string' ? [text] : []
    })
    .filter((t) => t !== '')
    .join('\n')
    .trim()
}

/**
 * Parser for Claude Code's documented stream-json surface. Only visible text
 * and terminal receipts are retained; thinking and tool internals are ignored.
 * Byte-compatible with the Swift ClaudeCodeStreamParser.
 */
export class ClaudeCodeStreamParser {
  private buffer = ''
  private partialText = ''
  private assistantTexts = new Map<string, string>()
  private assistantOrder: string[] = []
  private state: ClaudeCodeStreamState = { visibleText: '' }
  private readonly onVisibleText: (text: string) => void

  constructor(onVisibleText: (text: string) => void = () => {}) {
    this.onVisibleText = onVisibleText
  }

  /** Consume a chunk of NDJSON bytes, invoking onVisibleText for each delta. */
  consume(data: Buffer | string): void {
    this.buffer += typeof data === 'string' ? data : data.toString('utf8')
    let newline: number
    while ((newline = this.buffer.indexOf('\n')) !== -1) {
      const line = this.buffer.slice(0, newline)
      this.buffer = this.buffer.slice(newline + 1)
      const text = this.consumeLine(line)
      if (text !== undefined) this.onVisibleText(text)
    }
  }

  /** Flush any remaining buffered line and return the final state. */
  finish(): ClaudeCodeStreamState {
    let callback: string | undefined
    if (this.buffer.trim() !== '') {
      callback = this.consumeLine(this.buffer)
      this.buffer = ''
    }
    if (callback !== undefined) this.onVisibleText(callback)
    return this.state
  }

  /** Process a single NDJSON line; returns the visible-text delta if any. */
  consumeLine(raw: string): string | undefined {
    if (raw.trim() === '') return undefined
    let object: JsonObject
    try {
      const parsed: unknown = JSON.parse(raw)
      if (typeof parsed !== 'object' || parsed === null) return undefined
      object = parsed as JsonObject
    } catch {
      return undefined
    }
    const type = object['type']
    if (typeof type !== 'string') return undefined

    const sessionID = nonempty(object['session_id'])
    if (sessionID !== undefined) {
      this.state = { ...this.state, sessionID }
    }
    const model = nonempty(object['model'])
    if (model !== undefined) {
      this.state = { ...this.state, model }
    }

    switch (type) {
      case 'system':
        return undefined

      case 'stream_event': {
        const event = object['event']
        if (typeof event !== 'object' || event === null) return undefined
        const eventObject = event as JsonObject
        if (eventObject['type'] !== 'content_block_delta') return undefined
        const delta = eventObject['delta']
        if (typeof delta !== 'object' || delta === null) return undefined
        const text = (delta as JsonObject)['text']
        if (typeof text !== 'string' || text === '') return undefined
        this.partialText += text
        return this.updateVisibleText()
      }

      case 'assistant': {
        const message = object['message']
        if (typeof message !== 'object' || message === null) return undefined
        const messageObject = message as JsonObject
        const messageModel = nonempty(messageObject['model'])
        if (messageModel !== undefined) {
          this.state = { ...this.state, model: messageModel }
        }
        const messageID = nonempty(messageObject['id']) ?? `assistant-${this.assistantOrder.length}`
        const text = visibleText(messageObject['content'])
        if (text === '') return undefined
        if (!this.assistantTexts.has(messageID)) {
          this.assistantOrder.push(messageID)
        }
        this.assistantTexts.set(messageID, text)
        this.partialText = ''
        return this.updateVisibleText()
      }

      case 'result': {
        const isError = object['is_error'] === true
        const subtype = nonempty(object['subtype']) ?? (isError ? 'error' : 'success')
        const result = nonempty(object['result'])
        this.state = {
          ...this.state,
          finalResult: result,
          status: isError ? 'failed' : subtype,
          costUSD: asNumber(object['total_cost_usd']),
          durationMilliseconds: asInteger(object['duration_ms']),
          errorMessage: nonempty(object['error']) ?? (isError ? result : undefined),
        }
        if (result !== undefined) {
          this.state = { ...this.state, visibleText: result }
          return result
        }
        return undefined
      }

      default:
        // Tool, thinking, hook, and internal protocol events stay private.
        return undefined
    }
  }

  private updateVisibleText(): string | undefined {
    const completed = this.assistantOrder
      .map((id) => this.assistantTexts.get(id))
      .filter((text): text is string => text !== undefined && text !== '')
    const text = completed.length === 0
      ? this.partialText
      : completed.join('\n\n') + (this.partialText === '' ? '' : `\n\n${this.partialText}`)
    if (text === this.state.visibleText) return undefined
    this.state = { ...this.state, visibleText: text }
    return text
  }
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

export interface ClaudeCodeClientOptions {
  executableURL: string
}

/** Child-process client for Claude Code, mirroring ClaudeCodeClient.swift. */
export class ClaudeCodeClient {
  readonly executableURL: string
  private activeProcess?: ReturnType<typeof spawn>
  private wasInterrupted = false

  constructor(options: ClaudeCodeClientOptions) {
    this.executableURL = options.executableURL
  }

  probe(): ClaudeCodeProbeResult {
    if (!isExecutableFile(this.executableURL)) {
      throw MuError.commandFailed(
        `Claude Code executable is unavailable at ${this.executableURL}`,
      )
    }
    const versionCapture = runProcess({
      executableURL: this.executableURL,
      arguments: ['--version'],
    })
    if (versionCapture.terminationStatus !== 0) {
      throw MuError.commandFailed(
        errorText(versionCapture, 'Claude Code --version failed.'),
      )
    }
    const versionText = versionCapture.standardOutput.toString('utf8').trim()
    const version = versionText.split(' ')[0] ?? versionText

    const authCapture = runProcess({
      executableURL: this.executableURL,
      arguments: ['auth', 'status', '--json'],
    })
    const authData = authCapture.standardOutput.length === 0
      ? authCapture.standardError
      : authCapture.standardOutput
    let authObject: JsonObject = {}
    try {
      const parsed: unknown = JSON.parse(authData.toString('utf8'))
      if (typeof parsed === 'object' && parsed !== null) {
        authObject = parsed as JsonObject
      }
    } catch {
      // unparseable auth status -> defaults
    }
    return {
      version: version === '' ? 'unknown' : version,
      loggedIn: authObject['loggedIn'] === true,
      authMethod: nonempty(authObject['authMethod']) ?? 'unknown',
      apiProvider: nonempty(authObject['apiProvider']) ?? 'unknown',
    }
  }

  /** Runs a read-only turn, streaming visible text via the parser. */
  async runReadOnlyTask(params: {
    task: TaskRecord
    contextPack: ProjectContextPackRecord
    sessionID?: string
    resumeSessionID?: string
    promptOverride?: string
    onSessionStarted?: (sessionID: string) => void
    onVisibleText?: (text: string) => void
  }): Promise<ClaudeCodeTurnResult> {
    if (!isExecutableFile(this.executableURL)) {
      throw MuError.commandFailed(
        `Claude Code executable is unavailable at ${this.executableURL}`,
      )
    }
    const sessionID = params.sessionID ?? uuid()
    const normalizedSessionID = (params.resumeSessionID ?? sessionID).trim()
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(normalizedSessionID)) {
      throw MuError.invalidTransition(
        'Claude Code requires a valid native session UUID.',
      )
    }

    const args = claudeCodeArguments({
      task: params.task,
      contextPack: params.contextPack,
      sessionID,
      resumeSessionID: params.resumeSessionID,
      promptOverride: params.promptOverride,
    })
    const process = spawn(this.executableURL, args, {
      cwd: params.task.repositoryPath,
      stdio: ['ignore', 'pipe', 'pipe'],
    })

    const parser = new ClaudeCodeStreamParser(params.onVisibleText)
    const stderrChunks: Buffer[] = []
    process.stdout.on('data', (data: Buffer) => parser.consume(data))
    process.stderr.on('data', (data: Buffer) => stderrChunks.push(data))

    this.activeProcess = process
    this.wasInterrupted = false
    params.onSessionStarted?.(normalizedSessionID)

    const exitCode = await new Promise<number>((resolve) => {
      process.on('exit', (code) => resolve(code ?? -1))
    })
    if (this.activeProcess === process) {
      this.activeProcess = undefined
    }
    const interrupted = this.wasInterrupted
    const stream = parser.finish()
    const stderr = Buffer.concat(stderrChunks).toString('utf8').trim()
    const finalSessionID = stream.sessionID ?? normalizedSessionID
    const output = stream.finalResult ?? stream.visibleText

    if (interrupted) {
      return {
        sessionID: finalSessionID,
        output,
        status: 'cancelled',
        model: stream.model,
        costUSD: stream.costUSD,
        durationMilliseconds: stream.durationMilliseconds,
        errorMessage: 'Interrupted in Mu.',
      }
    }
    if (exitCode !== 0 || stream.status === 'failed') {
      const message =
        stream.errorMessage ??
        (stderr === '' ? `Claude Code exited with status ${exitCode}.` : stderr)
      throw MuError.commandFailed(message)
    }
    if (output.trim() === '') {
      throw MuError.commandFailed('Claude Code completed without a visible response.')
    }
    return {
      sessionID: finalSessionID,
      output,
      status: stream.status ?? 'success',
      model: stream.model,
      costUSD: stream.costUSD,
      durationMilliseconds: stream.durationMilliseconds,
      errorMessage: stream.errorMessage,
    }
  }

  interrupt(): void {
    this.wasInterrupted = true
    if (this.activeProcess !== undefined && !this.activeProcess.killed) {
      this.activeProcess.kill()
    }
  }
}

/** CLI argument construction, byte-identical to the Swift static helper. */
export function claudeCodeArguments(params: {
  task: TaskRecord
  contextPack: ProjectContextPackRecord
  sessionID: string
  resumeSessionID?: string
  promptOverride?: string
}): string[] {
  const values: string[] = [
    '--print',
    '--output-format', 'stream-json',
    '--verbose',
    '--include-partial-messages',
    '--permission-mode', 'plan',
    '--tools', 'Read,Glob,Grep',
    '--disallowedTools',
    'Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch',
    '--append-system-prompt',
    'You are an Agent Actor working through Mu. Treat the supplied Context Pack as the bounded Project contract. Stay read-only, do not use external network, do not expose private thinking, and return a reviewable result with evidence.',
    '--name', `Mu · ${params.task.title}`,
  ]
  if (params.resumeSessionID !== undefined) {
    values.push('--resume', params.resumeSessionID)
  } else {
    values.push('--session-id', params.sessionID)
  }
  const prompt = params.promptOverride ?? renderedContextPackMarkdown(params.contextPack)
  values.push(prompt)
  return values
}

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

/** Finds the Claude Code executable, mirroring ClaudeCodeDiscovery.swift. */
export function claudeCodeExecutableURL(
  environment: NodeJS.ProcessEnv = process.env,
): string | undefined {
  for (const key of ['MU_CLAUDE_EXECUTABLE', 'CLAUDE_CODE_EXECUTABLE']) {
    const value = environment[key]?.trim()
    if (value !== undefined && value !== '' && isExecutableFile(value)) {
      return canonicalize(value)
    }
  }
  const home = os.homedir()
  const candidates = [
    path.join(home, '.local/bin/claude'),
    path.join(home, '.claude/local/claude'),
    '/opt/homebrew/bin/claude',
    '/usr/local/bin/claude',
  ]
  const pathEnv = environment['PATH'] ?? ''
  for (const dir of pathEnv.split(':')) {
    if (dir !== '') candidates.push(path.join(dir, 'claude'))
  }
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

function isExecutableFile(p: string): boolean {
  try {
    fs.accessSync(p, fs.constants.X_OK)
    return fs.statSync(p).isFile()
  } catch {
    return false
  }
}

function canonicalize(p: string): string {
  return fs.realpathSync(p)
}

function errorText(capture: { standardError: Buffer; standardOutput: Buffer }, fallback: string): string {
  const stderr = capture.standardError.toString('utf8').trim()
  const stdout = capture.standardOutput.toString('utf8').trim()
  if (stderr !== '') return stderr
  if (stdout !== '') return stdout
  return fallback
}
