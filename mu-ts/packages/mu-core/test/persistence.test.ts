import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { MuError } from '../src/errors.ts'
import { uuid } from '../src/identity.ts'
import { createChatEntry, createLedgerEvent, createTaskRecord } from '../src/models.ts'
import { ArtifactStore } from '../src/persistence/artifact-store.ts'
import { SQLiteStore } from '../src/persistence/store.ts'
import { fetchChatEntries, fetchTasks, upsertTask } from '../src/persistence/domain.ts'

let tmpDir: string

beforeEach(() => {
  tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'mu-ts-'))
})

afterEach(() => {
  fs.rmSync(tmpDir, { recursive: true, force: true })
})

describe('SQLiteStore', () => {
  it('creates the full Swift-compatible schema', () => {
    const store = new SQLiteStore({ dataDirectory: tmpDir })
    const tables = store
      .prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
      .all()
      .map((r) => (r as { name: string }).name)
    expect(tables).toEqual([
      'context_access_policies',
      'context_conflict_records',
      'context_conflicts',
      'context_deliveries',
      'context_import_jobs',
      'context_pack_items',
      'context_packs',
      'context_records',
      'context_relations',
      'context_snapshots',
      'context_sources',
      'context_transitions',
      'imported_conversations',
      'imported_messages',
      'ledger',
      'maintenance',
      'records',
      'sqlite_sequence',
      'task_context_sources',
    ])
    const journalMode = store.prepare('PRAGMA journal_mode;').get() as { journal_mode: string }
    expect(journalMode.journal_mode).toBe('wal')
  })

  it('round-trips records with Date fields', () => {
    const store = new SQLiteStore({ dataDirectory: tmpDir, filename: ':memory:' })
    const task = createTaskRecord({
      title: 'T',
      objective: 'O',
      repositoryPath: '/tmp/x',
      createdAt: new Date(1_752_433_665_000),
      updatedAt: new Date(1_752_433_700_000),
    })
    upsertTask(store, task)
    const fetched = fetchTaskById(store, task.id)
    expect(fetched).toBeDefined()
    expect(fetched!.title).toBe('T')
    expect(fetched!.createdAt).toEqual(new Date(1_752_433_665_000))
    expect(fetched!.updatedAt).toEqual(new Date(1_752_433_700_000))
    expect(fetched!.status).toBe('ready')

    // Upsert overwrites.
    upsertTask(store, { ...task, title: 'T2', updatedAt: new Date(1_752_433_800_000) })
    const updated = fetchTaskById(store, task.id)
    expect(updated!.title).toBe('T2')
    expect(updated!.updatedAt).toEqual(new Date(1_752_433_800_000))
    expect(fetchTasks(store)).toHaveLength(1)
    store.close()
  })

  it('stores ledger events with monotonic sequences', () => {
    const store = new SQLiteStore({ dataDirectory: tmpDir, filename: ':memory:' })
    const taskID = uuid('d1d2d3d4-d5d6-d7d8-d9da-dbdcdddedfe0')
    const e1 = createLedgerEvent({ taskID, type: 'task.created', summary: 'created' })
    const e2 = createLedgerEvent({ taskID, type: 'task.started', summary: 'started' })
    const s1 = store.appendEvent(e1)
    const s2 = store.appendEvent(e2)
    expect(s1).toBe(1)
    expect(s2).toBe(2)

    const events = store.fetchEvents(taskID)
    expect(events).toHaveLength(2)
    expect(events[0]!.sequence).toBe(2)
    expect(events[0]!.type).toBe('task.started')
    expect(events[0]!.taskID).toBe(taskID)
    expect(events[1]!.sequence).toBe(1)
    store.close()
  })

  it('rolls back transactions on error', () => {
    const store = new SQLiteStore({ dataDirectory: tmpDir, filename: ':memory:' })
    const task = createTaskRecord({ title: 'T', objective: 'O', repositoryPath: '/tmp/x' })
    expect(() =>
      store.withTransaction(() => {
        upsertTask(store, task)
        throw new Error('boom')
      }),
    ).toThrow('boom')
    expect(fetchTasks(store)).toHaveLength(0)
    store.close()
  })

  it('supports maintenance markers and scrub', () => {
    const store = new SQLiteStore({ dataDirectory: tmpDir })
    expect(store.hasMaintenanceMarker('migrate.context_v2')).toBe(false)
    store.setMaintenanceMarker('migrate.context_v2')
    expect(store.hasMaintenanceMarker('migrate.context_v2')).toBe(true)
    store.scrubVacatedContent()
    expect(store.hasMaintenanceMarker('migrate.context_v2')).toBe(true)
    store.close()
  })

  it('persists chat entries per task', () => {
    const store = new SQLiteStore({ dataDirectory: tmpDir, filename: ':memory:' })
    const taskID = uuid('d1d2d3d4-d5d6-d7d8-d9da-dbdcdddedfe0')
    const a = createChatEntry({ taskID, authorKind: 'user', authorName: 'U', text: 'hi' })
    const b = createChatEntry({ taskID, authorKind: 'agent', authorName: 'A', text: 'hello' })
    const insert = store.prepare(
      'INSERT INTO records(kind, id, task_id, sort_at, json) VALUES (?, ?, ?, ?, ?)',
    )
    insert.run('chat_entry', a.id, taskID, '2025-07-13T19:07:45Z', JSON.stringify(a))
    insert.run('chat_entry', b.id, taskID, '2025-07-13T19:07:50Z', JSON.stringify(b))
    const entries = fetchChatEntries(store, taskID)
    expect(entries).toHaveLength(2)
    expect(entries[0]!.text).toBe('hello')
    store.close()
  })
})

describe('ArtifactStore (CAS)', () => {
  it('stores, dedupes, and verifies content', () => {
    const store = new ArtifactStore({ dataDirectory: tmpDir })
    const data = Buffer.from('hello world')
    const a = store.put(data)
    const b = store.put(data)
    expect(a.uri).toBe(b.uri)
    expect(a.sha256).toBe('b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9')
    expect(store.get(a.uri)?.toString()).toBe('hello world')
    expect(store.verify(a.uri, a.sha256)).toBe(true)
    expect(store.verify(a.uri, '0'.repeat(64))).toBe(false)
    expect(store.get('local-cas://sha256/nope')).toBeUndefined()
  })

  it('rejects content-address collisions', () => {
    const store = new ArtifactStore({ dataDirectory: tmpDir })
    const uri = store.put(Buffer.from('first')).uri
    // Corrupt the CAS object: the file at 'first'-hash now holds 'second'.
    const filePath = path.join(tmpDir, 'cas', 'sha256', uri.slice('local-cas://sha256/'.length))
    fs.chmodSync(filePath, 0o644)
    fs.writeFileSync(filePath, Buffer.from('second'))
    // Putting 'first' again must detect the hash mismatch.
    expect(() => store.put(Buffer.from('first'))).toThrow(MuError)
  })
})

function fetchTaskById(store: SQLiteStore, id: string) {
  return store.fetchRecord<ReturnType<typeof createTaskRecord>>('task', id as never)
}
