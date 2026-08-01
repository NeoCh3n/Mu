#!/usr/bin/env node
// Mock Codex App Server speaking the stdio JSON-RPC protocol, for tests.
// Reads newline-delimited JSON from stdin; writes responses to stdout.

import readline from 'node:readline'

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity })
let nextID = 1000
const threads = new Map()

function send(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`)
}

function reply(id, result) {
  send({ id, result })
}

function notify(method, params) {
  send({ method, params })
}

rl.on('line', (line) => {
  if (line.trim() === '') return
  let message
  try {
    message = JSON.parse(line)
  } catch {
    return
  }
  const method = message.method
  const id = message.id
  const params = message.params ?? {}

  switch (method) {
    case 'initialize':
      reply(id, {
        userAgent: 'codex-app-server/0.1.0',
        platformOs: 'darwin',
        capabilities: {},
      })
      break

    case 'initialized':
      break

    case 'account/read':
      reply(id, { account: { id: 'mock-user' } })
      break

    case 'thread/list': {
      const data = []
      for (const thread of threads.values()) {
        if (thread.archived === params.archived) {
          data.push({
            id: thread.id,
            cwd: thread.cwd,
            name: thread.name,
            preview: thread.preview,
            source: 'cli',
            updatedAt: thread.updatedAt,
            createdAt: thread.createdAt,
          })
        }
      }
      reply(id, { data })
      break
    }

    case 'thread/start': {
      const thread = {
        id: `thread-${nextID++}`,
        cwd: params.cwd,
        name: null,
        preview: null,
        archived: false,
        turns: [],
        updatedAt: Date.now(),
        createdAt: Date.now(),
      }
      threads.set(thread.id, thread)
      reply(id, { thread: { id: thread.id } })
      break
    }

    case 'thread/name/set':
      reply(id, { ok: true })
      break

    case 'thread/read': {
      const thread = threads.get(params.threadId) ?? {
        id: params.threadId,
        cwd: '/tmp/repo',
        name: null,
        preview: null,
        turns: [],
        updatedAt: Date.now(),
        createdAt: Date.now(),
      }
      threads.set(thread.id, thread)
      reply(id, { thread })
      break
    }

    case 'turn/start': {
      const thread = threads.get(params.threadId)
      const turnID = `turn-${nextID++}`
      const turn = { id: turnID, status: 'in_progress', items: [] }
      if (thread) thread.turns.push(turn)
      reply(id, { turn: { id: turnID } })

      // Stream the mock agent response as notifications.
      const text = 'Mock analysis complete.\n\nRecommendation: refactor the widget.'
      const itemID = `item-${nextID++}`
      const chunks = text.match(/.{1,8}/gs) ?? []
      chunks.forEach((chunk, index) => {
        setTimeout(() => {
          notify('item/agentMessage/delta', { turnId: turnID, itemId: itemID, delta: chunk })
        }, 5 * (index + 1))
      })
      setTimeout(() => {
        notify('item/completed', {
          turnId: turnID,
          item: { id: itemID, type: 'agentMessage', phase: 'final_answer', text },
        })
        if (thread) {
          const t = thread.turns.find((x) => x.id === turnID)
          if (t) {
            t.status = 'completed'
            t.completedAt = Date.now()
            t.items = [{ id: itemID, type: 'agentMessage', phase: 'final_answer', text }]
          }
        }
        notify('turn/completed', {
          threadId: params.threadId,
          turn: { id: turnID, status: 'completed' },
        })
      }, 40)
      break
    }

    case 'turn/interrupt':
      reply(id, { ok: true })
      break

    default:
      reply(id, { ok: true })
      break
  }
})
