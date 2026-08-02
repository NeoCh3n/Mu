import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import { createTaskRecord } from '../src/models.ts'
import {
  CodexAppServerClient,
  nativeThreadSource,
  parseHistoryMessages,
  taskPrompt,
} from '../src/runtime-clients/codex.ts'

const MOCK_SERVER = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  'support/mock-codex-server.mjs',
)

function client(): CodexAppServerClient {
  return new CodexAppServerClient({ executableURL: MOCK_SERVER })
}

describe('CodexAppServerClient protocol', () => {
  it('warms the app-server once and shares it with the first turn', async () => {
    const codex = client()
    const task = createTaskRecord({
      title: 'Warm endpoint',
      objective: 'Verify the warmed app-server path',
      repositoryPath: '/tmp/repo',
    })
    try {
      await Promise.all([
        codex.warm(),
        codex.runReadOnlyTask({ task, clientUserMessageID: 'mu-warm' }),
      ])
      const candidates = await codex.listHistory('/tmp/repo')
      expect(candidates).toHaveLength(1)
    } finally {
      codex.stop()
    }
  })

  it('probes the mock server', async () => {
    const codex = client()
    const result = await codex.probe()
    expect(result.userAgent).toBe('codex-app-server/0.1.0')
    expect(result.signedIn).toBe(true)
    expect(result.observedThreadCount).toBe(0)
    codex.stop()
  })

  it('runs a read-only task with streamed deltas and history reconciliation', async () => {
    const codex = client()
    const task = createTaskRecord({
      title: 'Inspect widget',
      objective: 'Review the renderer',
      repositoryPath: '/tmp/repo',
    })
    const visible: string[] = []
    const started: Array<[string, string]> = []
    const result = await codex.runReadOnlyTask({
      task,
      clientUserMessageID: 'mu-1',
      onVisibleText: (text) => visible.push(text),
      onTurnStarted: (threadID, turnID) => started.push([threadID, turnID]),
    })
    expect(result.status).toBe('completed')
    expect(result.historyReconciled).toBe(true)
    expect(result.output).toContain('Mock analysis complete')
    expect(result.threadID).toMatch(/^thread-\d+$/)
    expect(result.turnID).toMatch(/^turn-\d+$/)
    expect(started).toHaveLength(1)
    expect(started[0]![0]).toBe(result.threadID)
    expect(visible.length).toBeGreaterThan(1)
    expect(visible.at(-1)).toContain('Recommendation')
    codex.stop()
  })

  it('lists and reads thread history', async () => {
    const codex = client()
    const task = createTaskRecord({
      title: 'Seed thread',
      objective: 'Create a thread for history',
      repositoryPath: '/tmp/repo',
    })
    await codex.runReadOnlyTask({ task, clientUserMessageID: 'mu-seed' })

    const candidates = await codex.listHistory('/tmp/repo')
    expect(candidates.length).toBeGreaterThanOrEqual(1)
    const candidate = candidates[0]!
    expect(candidate.nativeSessionID).toMatch(/^thread-\d+$/)
    expect(candidate.title).toMatch(/^Codex task /)
    expect(candidate.resumability).toBe('resumable')

    const messages = await codex.readHistory(candidate.nativeSessionID, '/tmp/repo')
    expect(messages.length).toBeGreaterThanOrEqual(1)
    const agentMessage = messages.find((m) => m.role === 'assistant')
    expect(agentMessage?.text).toContain('Mock analysis complete')
    expect(agentMessage?.phase).toBe('final_answer')
    codex.stop()
  })

  it('rejects history reads from the wrong workspace', async () => {
    const codex = client()
    await expect(codex.readHistory('thread-123', '/other/workspace')).rejects.toThrow()
    codex.stop()
  })
})

describe('parseHistoryMessages (pure)', () => {
  it('extracts visible user and assistant messages in order', () => {
    const response = {
      thread: {
        id: 'thread-1',
        turns: [
          {
            id: 'turn-1',
            startedAt: 1_752_433_665_000,
            completedAt: 1_752_433_700_000,
            items: [
              { id: 'u1', type: 'userMessage', content: [{ type: 'text', text: 'Do the thing' }] },
              {
                id: 'a1',
                type: 'agentMessage',
                phase: 'commentary',
                text: 'Investigating…',
              },
              {
                id: 'a2',
                type: 'agentMessage',
                phase: 'final_answer',
                text: 'Done. Evidence: logs show success.',
              },
              { id: 't1', type: 'toolCall', tool: 'Bash', input: { command: 'ls' } },
              { id: 'r1', type: 'reasoning', text: 'secret chain of thought' },
            ],
          },
          {
            id: 'turn-2',
            items: [
              {
                id: 'a3',
                type: 'agentMessage',
                text: 'Legacy phase-less answer',
              },
            ],
          },
        ],
      },
    }
    const messages = parseHistoryMessages(response, 'thread-1')
    expect(messages).toHaveLength(4)
    expect(messages[0]).toMatchObject({ role: 'user', text: 'Do the thing' })
    expect(messages[1]).toMatchObject({ role: 'assistant', phase: 'commentary', text: 'Investigating…' })
    expect(messages[2]).toMatchObject({ role: 'assistant', phase: 'final_answer' })
    expect(messages[2]!.text).toContain('Done. Evidence')
    // Legacy phase-less assistant messages become final answers.
    expect(messages[3]).toMatchObject({ role: 'assistant', phase: 'final_answer', text: 'Legacy phase-less answer' })
  })

  it('skips empty and internal items', () => {
    const response = {
      thread: {
        turns: [
          { id: 't1', items: [
            { id: 'x1', type: 'userMessage', content: '   ' },
            { id: 'x2', type: 'agentMessage', phase: 'draft', text: 'internal phase' },
            { id: 'x3', type: 'systemMessage', text: 'system' },
          ] },
        ],
      },
    }
    expect(parseHistoryMessages(response, 't')).toHaveLength(0)
  })
})

describe('nativeThreadSource', () => {
  it('accepts strings, tagged objects, and arrays', () => {
    expect(nativeThreadSource('cli')).toBe('cli')
    expect(nativeThreadSource({ type: 'vscode' })).toBe('vscode')
    expect(nativeThreadSource({ appServer: true })).toBe('appServer')
    expect(nativeThreadSource({ onlyKey: 1 })).toBe('onlyKey')
    expect(nativeThreadSource(['exec'])).toBe('exec')
    expect(nativeThreadSource(undefined)).toBeUndefined()
  })
})

describe('taskPrompt', () => {
  it('renders the Swift prompt template', () => {
    const task = createTaskRecord({
      title: 'T',
      objective: 'O',
      successCriteria: ['a', 'b'],
      constraints: [],
      pendingSteps: ['step'],
      repositoryPath: '/repo',
    })
    const prompt = taskPrompt(task)
    expect(prompt).toContain('Title: T')
    expect(prompt).toContain('- a\n- b')
    expect(prompt).toContain('- None specified')
    expect(prompt).toContain('Repository root: /repo')
  })
})
