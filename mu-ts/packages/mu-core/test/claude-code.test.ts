import { describe, expect, it } from 'vitest'
import { uuid } from '../src/identity.ts'
import { createTaskRecord } from '../src/models.ts'
import { createProjectContextPackRecord } from '../src/project-kernel/index.ts'
import {
  ClaudeCodeStreamParser,
  claudeCodeArguments,
} from '../src/runtime-clients/claude-code.ts'

function line(object: Record<string, unknown>): string {
  return `${JSON.stringify(object)}\n`
}

function streamEvent(text: string): string {
  return line({
    type: 'stream_event',
    event: { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text } },
  })
}

function assistantMessage(text: string, id = 'msg_123'): string {
  return line({
    type: 'assistant',
    message: { id, model: 'claude-sonnet-5', content: [{ type: 'text', text }] },
  })
}

describe('ClaudeCodeStreamParser', () => {
  it('captures session_id and model from any event', () => {
    const parser = new ClaudeCodeStreamParser()
    parser.consume(line({ type: 'system', session_id: 'abc-123', model: 'claude-opus-5' }))
    const state = parser.finish()
    expect(state.sessionID).toBe('abc-123')
    expect(state.model).toBe('claude-opus-5')
    expect(state.visibleText).toBe('')
  })

  it('accumulates partial text from content_block_delta events', () => {
    const seen: string[] = []
    const parser = new ClaudeCodeStreamParser((t) => seen.push(t))
    parser.consume(streamEvent('Hel'))
    parser.consume(streamEvent('lo, '))
    parser.consume(streamEvent('world'))
    expect(seen).toEqual(['Hel', 'Hello, ', 'Hello, world'])
    expect(parser.finish().visibleText).toBe('Hello, world')
  })

  it('handles chunked input spanning multiple deltas', () => {
    const seen: string[] = []
    const parser = new ClaudeCodeStreamParser((t) => seen.push(t))
    // Multiple lines in a single chunk, plus a partial line at the end.
    parser.consume(`${streamEvent('First ')}${streamEvent('line')}\n${streamEvent('Second')}`)
    // Swift semantics: partialText accumulates deltas without separators.
    expect(seen).toEqual(['First ', 'First line', 'First lineSecond'])
    const state = parser.finish()
    expect(state.visibleText).toBe('First lineSecond')
  })

  it('assistant messages override streamed partial text', () => {
    const parser = new ClaudeCodeStreamParser()
    parser.consume(streamEvent('partial'))
    parser.consume(assistantMessage('Authoritative answer'))
    expect(parser.finish().visibleText).toBe('Authoritative answer')
    expect(parser.finish().model).toBe('claude-sonnet-5')
  })

  it('joins multiple assistant messages with blank lines', () => {
    const parser = new ClaudeCodeStreamParser()
    parser.consume(assistantMessage('First block', 'msg_1'))
    parser.consume(assistantMessage('Second block', 'msg_2'))
    expect(parser.finish().visibleText).toBe('First block\n\nSecond block')
  })

  it('result events capture terminal receipts', () => {
    const parser = new ClaudeCodeStreamParser()
    parser.consume(line({
      type: 'result',
      subtype: 'success',
      result: 'Done!',
      is_error: false,
      total_cost_usd: 0.42,
      duration_ms: 1234,
      session_id: 'final-session',
    }))
    const state = parser.finish()
    expect(state.finalResult).toBe('Done!')
    expect(state.status).toBe('success')
    expect(state.costUSD).toBe(0.42)
    expect(state.durationMilliseconds).toBe(1234)
    expect(state.sessionID).toBe('final-session')
    expect(state.visibleText).toBe('Done!')
  })

  it('result events with is_error map to failed status', () => {
    const parser = new ClaudeCodeStreamParser()
    parser.consume(line({
      type: 'result',
      is_error: true,
      result: 'something broke',
      error: 'boom',
    }))
    const state = parser.finish()
    expect(state.status).toBe('failed')
    expect(state.errorMessage).toBe('boom')
  })

  it('ignores tool, thinking, and hook events', () => {
    const parser = new ClaudeCodeStreamParser()
    parser.consume(line({
      type: 'assistant',
      message: {
        id: 'msg_tool',
        content: [{ type: 'tool_use', id: 'tool_1', name: 'Bash', input: { command: 'rm -rf' } }],
      },
    }))
    parser.consume(line({ type: 'stream_event', event: { type: 'content_block_start' } }))
    parser.consume(line({ type: 'thinking', thinking: 'secret' }))
    parser.consume(line({ type: 'hook', hook_event_name: 'PostToolUse' }))
    expect(parser.finish().visibleText).toBe('')
  })

  it('emits safe activity receipts without copying private thinking text', () => {
    const activities: Array<{ phase: string; title: string; detail?: string }> = []
    const parser = new ClaudeCodeStreamParser(() => {}, (activity) => activities.push(activity))
    parser.consume(line({
      type: 'assistant',
      message: {
        id: 'msg_activity',
        content: [
          { type: 'tool_use', id: 'tool_read', name: 'Read', input: { file_path: 'Sources/App.swift' } },
          { type: 'thinking', thinking: 'private reasoning that must not be copied' },
        ],
      },
    }))
    expect(activities.some((activity) => activity.phase === 'file' && activity.title.includes('Sources/App.swift'))).toBe(true)
    const reasoning = activities.find((activity) => activity.phase === 'thinking')
    expect(reasoning?.detail).not.toContain('private reasoning that must not be copied')
  })

  it('tolerates malformed lines', () => {
    const parser = new ClaudeCodeStreamParser()
    parser.consume('not json\n')
    parser.consume('\n')
    parser.consume('{"type":123}\n')
    expect(parser.finish().visibleText).toBe('')
  })
})

describe('claudeCodeArguments', () => {
  const task = createTaskRecord({
    title: 'Fix widget',
    objective: 'Fix the renderer',
    repositoryPath: '/tmp/repo',
  })
  const pack = createProjectContextPackRecord({
    projectID: uuid('a1b2c3d4-e5f6-4789-abcd-ef0123456789'),
    taskID: uuid('d1d2d3d4-d5d6-d7d8-d9da-dbdcdddedfe0'),
    workspaceID: uuid('c9d0e1f2-a3b4-4c5d-8e6f-7a8b9c0d1e2f'),
    objective: 'Fix the renderer',
    contentSHA256: 'c'.padEnd(64, '0'),
  })

  it('builds the exact Swift argument list for a fresh session', () => {
    const args = claudeCodeArguments({
      task,
      contextPack: pack,
      sessionID: '01234567-89ab-4cde-8f01-23456789abcd',
    })
    expect(args.slice(0, 6)).toEqual(['--print', '--output-format', 'stream-json', '--verbose', '--include-partial-messages', '--permission-mode'])
    expect(args).toContain('plan')
    expect(args).toContain('Read,Glob,Grep')
    expect(args).toContain('Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch')
    expect(args).toContain(`Mu · ${task.title}`)
    expect(args).toContain('--session-id')
    expect(args[args.indexOf('--session-id')! + 1]).toBe('01234567-89ab-4cde-8f01-23456789abcd')
    expect(args.at(-1)).toContain('# Mu Project Context Pack')
    expect(args).not.toContain('--resume')
  })

  it('uses --resume when a resume session is given', () => {
    const args = claudeCodeArguments({
      task,
      contextPack: pack,
      sessionID: '01234567-89ab-4cde-8f01-23456789abcd',
      resumeSessionID: 'aaaa-bbbb-cccc',
    })
    expect(args).toContain('--resume')
    expect(args[args.indexOf('--resume')! + 1]).toBe('aaaa-bbbb-cccc')
    expect(args).not.toContain('--session-id')
  })

  it('uses the prompt override when provided', () => {
    const args = claudeCodeArguments({
      task,
      contextPack: pack,
      sessionID: '01234567-89ab-4cde-8f01-23456789abcd',
      promptOverride: 'custom prompt',
    })
    expect(args.at(-1)).toBe('custom prompt')
  })
})
