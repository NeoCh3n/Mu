import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import { createLocalHarness, LocalChildProcessHarness } from '../src/harness/local-child-process.ts'
import type {
  ClaudeCodeClientLike,
  CodexClientLike,
} from '../src/harness/local-child-process.ts'
import type { HarnessTurnResult } from '../src/harness/types.ts'
import { uuid } from '../src/identity.ts'
import { createTaskRecord, type TaskRecord } from '../src/models.ts'
import { createProjectContextPackRecord } from '../src/project-kernel/index.ts'
import { CLAUDE_CODE_PROVIDER, CODE_PROVIDER } from '../src/types.ts'

const FAKE_CLAUDE = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  'support/fake-claude.mjs',
)

function task(): TaskRecord {
  return createTaskRecord({
    title: 'Inspect widget',
    objective: 'Review the renderer',
    repositoryPath: '/tmp/repo',
  })
}

function contextPack() {
  return createProjectContextPackRecord({
    projectID: uuid(),
    taskID: uuid(),
    workspaceID: uuid(),
    objective: 'Review the renderer',
    contentSHA256: '0'.repeat(64),
  })
}

// ---------------------------------------------------------------------------
// Fake clients (the "fake process" per the Phase 4 test strategy)
// ---------------------------------------------------------------------------

function fakeClaudeClient(overrides: Partial<ClaudeCodeClientLike> = {}): ClaudeCodeClientLike {
  return {
    probe: () => ({ version: '0.1.0-fake', loggedIn: true, authMethod: 'oauth', apiProvider: 'anthropic' }),
    async runReadOnlyTask(params) {
      params.onSessionStarted?.('fake-session-0001')
      params.onVisibleText?.('The renderer ')
      params.onVisibleText?.('reads frames from the queue.')
      return {
        sessionID: 'fake-session-0001',
        output: 'The renderer reads frames from the queue.',
        status: 'success',
        model: 'claude-sonnet-5',
        costUSD: 0.01,
        durationMilliseconds: 120,
      }
    },
    interrupt: () => undefined,
    ...overrides,
  }
}

function fakeCodexClient(overrides: Partial<CodexClientLike> = {}): CodexClientLike & {
  interrupted: () => string[]
} {
  const interrupted: string[] = []
  return {
    interrupted: () => interrupted,
    async probe() {
      return { userAgent: 'codex-app-server/0.1.0', platformOS: 'darwin', signedIn: true, observedThreadCount: 0 }
    },
    async listHistory() {
      return []
    },
    async runReadOnlyTask(params) {
      params.onThreadStarted?.('thread-1')
      params.onTurnStarted?.('thread-1', 'turn-1')
      params.onVisibleText?.('Mock analysis ')
      params.onVisibleText?.('complete.')
      return { threadID: 'thread-1', turnID: 'turn-1', output: 'Mock analysis complete.', status: 'completed', historyReconciled: true }
    },
    async runReadOnlyContinuation(params) {
      params.onTurnStarted?.(params.threadID, 'turn-2')
      params.onVisibleText?.('Continued analysis.')
      return { threadID: params.threadID, turnID: 'turn-2', output: 'Continued analysis.', status: 'completed', historyReconciled: true }
    },
    async interrupt(threadID, turnID) {
      interrupted.push(`${threadID}:${turnID}`)
    },
    stop: () => undefined,
    ...overrides,
  }
}

async function collect(harness: LocalChildProcessHarness, input: Parameters<LocalChildProcessHarness['runTurn']>[0]) {
  const events = []
  for await (const event of harness.runTurn(input)) {
    events.push(event)
  }
  return events
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('LocalChildProcessHarness', () => {
  it('streams a Claude turn through a fake client', async () => {
    const harness = createLocalHarness({ claudeCodeClient: fakeClaudeClient() })
    const events = await collect(harness, { provider: CLAUDE_CODE_PROVIDER, task: task(), contextPack: contextPack() })

    expect(events[0]).toEqual({ kind: 'session_started', sessionID: 'fake-session-0001' })
    expect(events[1]).toEqual({ kind: 'visible_text', text: 'The renderer ' })
    expect(events[2]).toEqual({ kind: 'visible_text', text: 'reads frames from the queue.' })
    const terminal = events.at(-1)
    expect(terminal?.kind).toBe('completed')
    const result = (terminal as { result: HarnessTurnResult }).result
    expect(result.status).toBe('success')
    expect(result.sessionID).toBe('fake-session-0001')
    expect(result.output).toContain('renderer')
    expect(result.model).toBe('claude-sonnet-5')
  })

  it('surfaces a Claude client failure as a failed event', async () => {
    const harness = createLocalHarness({
      claudeCodeClient: fakeClaudeClient({
        async runReadOnlyTask() {
          throw new Error('Claude Code exited with status 1.')
        },
      }),
    })
    const events = await collect(harness, { provider: CLAUDE_CODE_PROVIDER, task: task(), contextPack: contextPack() })
    expect(events.at(-1)).toEqual({ kind: 'failed', errorMessage: 'Claude Code exited with status 1.' })
  })

  it('maps an interrupted Claude turn to a cancelled event', async () => {
    const harness = createLocalHarness({
      claudeCodeClient: fakeClaudeClient({
        async runReadOnlyTask(params) {
          params.onSessionStarted?.('fake-session-0001')
          return {
            sessionID: 'fake-session-0001',
            output: '',
            status: 'cancelled',
            errorMessage: 'Interrupted in Mu.',
          }
        },
      }),
    })
    const events = await collect(harness, { provider: CLAUDE_CODE_PROVIDER, task: task(), contextPack: contextPack() })
    expect(events.at(-1)).toEqual({ kind: 'cancelled' })
  })

  it('forwards interrupt() to the active Claude client', async () => {
    let interrupted = false
    let interrupts = 0
    const client = fakeClaudeClient({
      async runReadOnlyTask(params) {
        params.onSessionStarted?.('fake-session-0001')
        while (!interrupted) {
          await new Promise((resolve) => setTimeout(resolve, 5))
        }
        return {
          sessionID: 'fake-session-0001',
          output: '',
          status: 'cancelled',
          errorMessage: 'Interrupted in Mu.',
        }
      },
      interrupt: () => {
        interrupts += 1
        interrupted = true
      },
    })
    const harness = createLocalHarness({ claudeCodeClient: client })
    const run = harness.runTurn(
      { provider: CLAUDE_CODE_PROVIDER, task: task(), contextPack: contextPack() },
    )
    const events = []
    for await (const event of run) {
      events.push(event)
      if (event.kind === 'session_started') {
        await harness.interrupt('fake-session-0001')
      }
    }
    expect(interrupts).toBe(1)
    expect(events.at(-1)?.kind).toBe('cancelled')
  })

  it('streams a Codex turn and tracks thread identity', async () => {
    const harness = createLocalHarness({ codexClient: fakeCodexClient() })
    const events = await collect(harness, { provider: CODE_PROVIDER, task: task(), contextPack: contextPack() })

    expect(events[0]).toEqual({ kind: 'session_started', sessionID: 'thread-1' })
    expect(events.some((e) => e.kind === 'visible_text' && e.text === 'Mock analysis ')).toBe(true)
    const terminal = events.at(-1) as { kind: 'completed'; result: HarnessTurnResult }
    expect(terminal.kind).toBe('completed')
    expect(terminal.result.status).toBe('success')
    expect(terminal.result.sessionID).toBe('thread-1')
  })

  it('resumes a Codex thread when resumeSessionID is present', async () => {
    const harness = createLocalHarness({ codexClient: fakeCodexClient() })
    const events = await collect(harness, {
      provider: CODE_PROVIDER,
      task: task(),
      contextPack: contextPack(),
      resumeSessionID: 'thread-1',
    })
    expect(events[0]).toEqual({ kind: 'session_started', sessionID: 'thread-1' })
    const terminal = events.at(-1) as { kind: 'completed'; result: HarnessTurnResult }
    expect(terminal.result.status).toBe('success')
  })

  it('recreates a Codex thread when a persisted continuation is missing', async () => {
    let continuationAttempts = 0
    let replacementThreads = 0
    const client = fakeCodexClient({
      async runReadOnlyContinuation() {
        continuationAttempts += 1
        throw new Error('Command failed: turn/start: thread not found: stale-thread')
      },
      async runReadOnlyTask(params) {
        replacementThreads += 1
        params.onThreadStarted?.('thread-replacement')
        params.onTurnStarted?.('thread-replacement', 'turn-replacement')
        params.onVisibleText?.('Recovered analysis.')
        return {
          threadID: 'thread-replacement',
          turnID: 'turn-replacement',
          output: 'Recovered analysis.',
          status: 'completed',
          historyReconciled: true,
        }
      },
    })
    const harness = createLocalHarness({ codexClient: client })
    const events = await collect(harness, {
      provider: CODE_PROVIDER,
      task: task(),
      contextPack: contextPack(),
      resumeSessionID: 'stale-thread',
    })

    expect(continuationAttempts).toBe(1)
    expect(replacementThreads).toBe(1)
    expect(events[0]).toEqual({ kind: 'session_started', sessionID: 'thread-replacement' })
    const terminal = events.at(-1) as { kind: 'completed'; result: HarnessTurnResult }
    expect(terminal.kind).toBe('completed')
    expect(terminal.result.status).toBe('success')
    expect(terminal.result.sessionID).toBe('thread-replacement')
  })

  it('maps an interrupted Codex turn to cancelled', async () => {
    const harness = createLocalHarness({
      codexClient: fakeCodexClient({
        async runReadOnlyTask(params) {
          params.onThreadStarted?.('thread-9')
          params.onTurnStarted?.('thread-9', 'turn-9')
          return { threadID: 'thread-9', turnID: 'turn-9', output: '', status: 'interrupted', historyReconciled: false }
        },
      }),
    })
    const events = await collect(harness, { provider: CODE_PROVIDER, task: task(), contextPack: contextPack() })
    expect(events.at(-1)).toEqual({ kind: 'cancelled' })
  })

  it('probes both runtimes and reports availability', async () => {
    const harness = createLocalHarness({
      claudeCodeClient: fakeClaudeClient(),
      codexClient: fakeCodexClient(),
    })
    const result = await harness.probe()
    expect(result.ok).toBe(true)
    expect(result.message).toContain('Claude Code 0.1.0-fake')
    expect(result.message).toContain('Codex codex-app-server/0.1.0')
    expect(result.loggedIn).toBe(true)
  })

  it('probe fails when no runtimes are configured', async () => {
    const harness = createLocalHarness()
    const result = await harness.probe()
    expect(result.ok).toBe(false)
    expect(result.message).toContain('No runtime executables')
  })

  it('listArtifacts is unsupported in local mode', async () => {
    const harness = createLocalHarness({ claudeCodeClient: fakeClaudeClient() })
    expect(await harness.listArtifacts('session-1')).toEqual([])
    expect(harness.capabilities.supportsArtifacts).toBe(false)
  })
})

// ---------------------------------------------------------------------------
// Real fake-process test: ClaudeCodeClient driven against fake-claude.mjs
// ---------------------------------------------------------------------------

describe('LocalChildProcessHarness with a real fake process', () => {
  it('streams NDJSON from the fake Claude executable', async () => {
    fs.chmodSync(FAKE_CLAUDE, 0o755)
    const repositoryPath = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'mu-harness-'))
    try {
      const harness = createLocalHarness({ claudeCodeExecutable: FAKE_CLAUDE })
      const probe = await harness.probe()
      expect(probe.ok).toBe(true)
      expect(probe.runtimeVersion).toBe('0.1.0-fake')

      const events = await collect(harness, {
        provider: CLAUDE_CODE_PROVIDER,
        task: createTaskRecord({
          title: 'Inspect widget',
          objective: 'Review the renderer',
          repositoryPath,
        }),
        contextPack: contextPack(),
      })
    const terminal = events.at(-1) as { kind: 'completed'; result: HarnessTurnResult }
    expect(terminal.kind).toBe('completed')
    expect(terminal.result.status).toBe('success')
    expect(terminal.result.sessionID).toBe('fake-session-0001')
    expect(terminal.result.output).toBe('The renderer reads frames from the queue.')
    expect(terminal.result.costUSD).toBe(0.01)
    } finally {
      fs.rmSync(repositoryPath, { recursive: true, force: true })
    }
  })
})
