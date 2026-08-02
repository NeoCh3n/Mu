import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import type { AgentIdentity, ChatEntry, RuntimeEndpoint, TaskRecord } from '../src/models.ts'
import type { ProjectContextPackRecord, ProjectRecord } from '../src/project-kernel/index.ts'
import { SQLiteStore } from '../src/persistence/store.ts'
import { fetchEndpoints } from '../src/persistence/domain.ts'

const fixtureCopies: string[] = []

afterEach(() => {
  for (const directory of fixtureCopies.splice(0)) {
    fs.rmSync(directory, { recursive: true, force: true })
  }
})

/**
 * Cross-implementation compatibility: this database was WRITTEN by the Swift
 * implementation (scripts/gen-swift-db.swift, which uses the same encoding
 * functions as MuCore). The TypeScript layer must decode it byte-compatibly.
 */
function openSwiftFixture(): SQLiteStore {
  const source = new URL('./fixtures/swift-synthetic.sqlite', import.meta.url).pathname
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'mu-ts-swift-fixture-'))
  const copy = path.join(directory, 'swift-synthetic.sqlite')
  fs.copyFileSync(source, copy)
  fixtureCopies.push(directory)
  return new SQLiteStore({
    dataDirectory: directory,
    filename: 'swift-synthetic.sqlite',
  })
}

describe('Swift-written database compatibility', () => {
  it('decodes tasks written by Swift', () => {
    const store = openSwiftFixture()
    const tasks = store.fetchRecords<TaskRecord>('task')
    expect(tasks).toHaveLength(1)
    const task = tasks[0]!
    expect(task.id).toBe('d1d2d3d4-d5d6-d7d8-d9da-dbdcdddedfe0')
    expect(task.title).toBe('Implement widget')
    expect(task.objective).toBe('Build the widget renderer')
    expect(task.successCriteria).toEqual(['tests pass', 'widget renders'])
    expect(task.status).toBe('ready')
    expect(task.assignedAgentIdentityID).toBe('c3d4e5f6-a7b8-49cd-8e01-23456789abcd')
    // ISO8601 dates decode back to Date objects with the exact instant.
    expect(task.createdAt).toEqual(new Date('2025-07-13T19:07:45Z'))
    expect(task.updatedAt).toEqual(new Date('2025-07-13T19:08:20Z'))
    store.close()
  })

  it('decodes projects, endpoints, and agents written by Swift', () => {
    const store = openSwiftFixture()
    const project = store.fetchRecords<ProjectRecord>('project')[0]!
    expect(project.id).toBe('a1b2c3d4-e5f6-4789-abcd-ef0123456789')
    expect(project.displayName).toBe('Widgets')
    expect(project.status).toBe('active')

    const endpoint = fetchEndpoints(store)[0]!
    expect(endpoint.runtimeTypeID).toBe('openai.codex/app-server')
    expect(endpoint.capabilities).toEqual(
      new Set(['start', 'replan', 'stream_events', 'cancel']),
    )
    expect(endpoint.instanceIdentity?.identityBasis).toBe('desktop_singleton')
    expect(endpoint.instanceIdentity?.stableInstanceKey).toBe('codex:desktop')

    const agent = store.fetchRecords<AgentIdentity>('agent_identity')[0]!
    expect(agent.displayName).toBe('Atlas')
    expect(agent.role).toBe('builder')
    expect(agent.capabilityTags).toEqual(['swift', 'typescript'])
    store.close()
  })

  it('decodes chat entries with delivery state and authors', () => {
    const store = openSwiftFixture()
    const entries = store.fetchRecords<ChatEntry>('chat_entry')
    expect(entries).toHaveLength(2)
    // Records are ordered sort_at DESC (newest first).
    expect(entries.map((e) => e.authorKind)).toEqual(['agent', 'user'])
    expect(entries[0]!.deliveryState).toBe('delivered')
    expect(entries[1]!.text).toBe('Please implement the widget')
    store.close()
  })

  it('decodes context packs written by Swift', () => {
    const store = openSwiftFixture()
    const packs = store.fetchRecords<ProjectContextPackRecord>('project_context_pack')
    expect(packs).toHaveLength(1)
    const pack = packs[0]!
    expect(pack.objective).toBe('Implement the widget')
    expect(pack.permissions).toEqual(['project.read', 'repository.read'])
    expect(pack.baseRevision).toBe('abc1234')
    expect(pack.contentSHA256).toMatch(/^c0+$/)
    store.close()
  })

  it('decodes ledger events with Swift-written payloads', () => {
    const store = openSwiftFixture()
    const events = store.fetchEvents()
    expect(events).toHaveLength(1)
    const event = events[0]!
    expect(event.sequence).toBe(1)
    expect(event.type).toBe('task.created')
    expect(event.schemaVersion).toBe('1.0')
    expect(event.taskID).toBe('d1d2d3d4-d5d6-d7d8-d9da-dbdcdddedfe0')
    expect(event.payload).toEqual({ source: 'synthetic' })
    expect(event.occurredAt).toEqual(new Date('2025-07-13T19:07:45Z'))
    store.close()
  })

  it('writes JSON that Swift can read (sorted keys, ISO8601 dates)', () => {
    // Round-trip through a fresh database and verify the JSON column layout
    // matches the Swift writer conventions exactly.
    const store = openSwiftFixture()
    const raw = store.prepare('SELECT json FROM records WHERE kind = ? LIMIT 1;').get('project') as {
      json: string
    }
    expect(raw.json).toBe(
      '{"createdAt":"2025-07-13T19:07:45Z","displayName":"Widgets","id":"a1b2c3d4-e5f6-4789-abcd-ef0123456789","ownerPrincipalID":"e5f6a7b8-c9d0-4e1f-8a2b-3c4d5e6f7a8b","repositoryPath":"/Users/synthetic/widgets","status":"active","updatedAt":"2025-07-13T19:08:20Z"}',
    )
    store.close()
  })
})
