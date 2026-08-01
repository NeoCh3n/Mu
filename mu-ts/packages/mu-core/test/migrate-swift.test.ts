import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import {
  inspectSwiftDatabase,
  migrateSwiftDataDirectory,
} from '../src/persistence/migrate-swift.ts'
import { SQLiteStore } from '../src/persistence/store.ts'
import { fetchProjects, fetchTasks } from '../src/persistence/domain.ts'

const SWIFT_FIXTURE = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  'fixtures/swift-synthetic.sqlite',
)

describe('Swift data migration', () => {
  it('inspects the Swift-written fixture database', () => {
    const inspection = inspectSwiftDatabase(SWIFT_FIXTURE)
    expect(inspection.schemaValid).toBe(true)
    expect(inspection.recordCount).toBeGreaterThan(0)
    expect(inspection.kinds['task']).toBe(1)
    expect(inspection.kinds['project']).toBe(1)
    expect(inspection.ledgerCount).toBeGreaterThan(0)
  })

  it('migrates the fixture into a target directory and reads it back', () => {
    const target = fs.mkdtempSync(path.join(os.tmpdir(), 'mu-migrate-'))
    try {
      const sourceDir = path.dirname(SWIFT_FIXTURE)
      const result = migrateSwiftDataDirectory({
        sourceDataDirectory: sourceDir,
        sourceFilename: 'swift-synthetic.sqlite',
        targetDataDirectory: target,
      })
      expect(result.databaseCopied).toBe(true)
      expect(result.inspection.schemaValid).toBe(true)

      // The migrated database decodes with the TypeScript store.
      const store = new SQLiteStore({ dataDirectory: target, filename: 'mu.sqlite' })
      try {
        const tasks = fetchTasks(store)
        expect(tasks).toHaveLength(1)
        expect(tasks[0]?.title).toBe('Implement widget')
        expect(tasks[0]?.status).toBe('ready')
        const projects = fetchProjects(store)
        expect(projects[0]?.displayName).toBe('Widgets')
      } finally {
        store.close()
      }
    } finally {
      fs.rmSync(target, { recursive: true, force: true })
    }
  })

  it('keeps a newer target database unless forced', () => {
    const sourceDir = path.dirname(SWIFT_FIXTURE)
    const target = fs.mkdtempSync(path.join(os.tmpdir(), 'mu-migrate2-'))
    try {
      // Seed a "newer" target database.
      fs.mkdirSync(target, { recursive: true })
      const seeded = new SQLiteStore({ dataDirectory: target, filename: 'mu.sqlite' })
      seeded.close()
      const seededStat = fs.statSync(path.join(target, 'mu.sqlite'))
      // Ensure the seeded file is strictly newer than the fixture.
      fs.utimesSync(path.join(target, 'mu.sqlite'), new Date(), new Date(Date.now() + 60_000))

      const result = migrateSwiftDataDirectory({
        sourceDataDirectory: sourceDir,
        sourceFilename: 'swift-synthetic.sqlite',
        targetDataDirectory: target,
      })
      expect(result.databaseCopied).toBe(false)
      void seededStat

      const forced = migrateSwiftDataDirectory({
        sourceDataDirectory: sourceDir,
        sourceFilename: 'swift-synthetic.sqlite',
        targetDataDirectory: target,
        force: true,
      })
      expect(forced.databaseCopied).toBe(true)
      const migrated = new SQLiteStore({ dataDirectory: target, filename: 'mu.sqlite' })
      try {
        expect(fetchTasks(migrated)).toHaveLength(1)
      } finally {
        migrated.close()
      }
    } finally {
      fs.rmSync(target, { recursive: true, force: true })
    }
  })
})
