import fs from 'node:fs'
import path from 'node:path'
import Database from 'better-sqlite3'
import { MuError } from '../errors.ts'

// ---------------------------------------------------------------------------
// Swift Mu data migration helper (Phase 8).
//
// The TypeScript rewrite is schema-compatible with the Swift SQLiteStore, so
// migrating a Swift data directory is: validate the database, copy the file
// and the CAS tree, and verify the copy decodes. No transformation is needed.
// ---------------------------------------------------------------------------

export interface SwiftDatabaseInspection {
  readonly sourcePath: string
  readonly schemaValid: boolean
  readonly recordCount: number
  readonly kinds: Record<string, number>
  readonly ledgerCount: number
  readonly hasCasTree: boolean
  readonly casFileCount: number
  readonly warnings: readonly string[]
}

/** Validates a Swift-written mu.sqlite and counts its records (read-only). */
export function inspectSwiftDatabase(sourcePath: string): SwiftDatabaseInspection {
  if (!fs.existsSync(sourcePath)) {
    throw MuError.database(`Swift database not found at ${sourcePath}.`)
  }
  const db = new Database(sourcePath, { readonly: true })
  try {
    const tables = (db.prepare(
      `SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name;`,
    ).all() as Array<{ name: string }>).map((row) => row.name)
    const schemaValid = tables.includes('records') && tables.includes('ledger')

    const recordRows = db.prepare(
      'SELECT kind, COUNT(*) AS count FROM records GROUP BY kind ORDER BY kind;',
    ).all() as Array<{ kind: string; count: number }>
    const kinds: Record<string, number> = {}
    let recordCount = 0
    for (const row of recordRows) {
      kinds[row.kind] = row.count
      recordCount += row.count
    }
    const ledgerCount = (db.prepare('SELECT COUNT(*) AS count FROM ledger;').get() as { count: number }).count

    const warnings: string[] = []
    if (!schemaValid) warnings.push('Database is missing the records/ledger tables — not a Mu database.')
    if (!tables.includes('context_records')) warnings.push('Context tables missing; context history cannot be migrated.')

    return {
      sourcePath,
      schemaValid,
      recordCount,
      kinds,
      ledgerCount,
      hasCasTree: false,
      casFileCount: 0,
      warnings,
    }
  } finally {
    db.close()
  }
}

/** Counts CAS artifacts under <dataDirectory>/cas/sha256. */
export function inspectCasTree(dataDirectory: string): { hasCasTree: boolean; casFileCount: number } {
  const casRoot = path.join(dataDirectory, 'cas', 'sha256')
  if (!fs.existsSync(casRoot)) return { hasCasTree: false, casFileCount: 0 }
  let count = 0
  for (const entry of fs.readdirSync(casRoot, { withFileTypes: true })) {
    if (entry.isFile()) count += 1
  }
  return { hasCasTree: true, casFileCount: count }
}

export interface MigrateSwiftDataOptions {
  readonly sourceDataDirectory: string
  readonly targetDataDirectory: string
  /** Source database filename (default 'mu.sqlite'). */
  readonly sourceFilename?: string
  /** Overwrite an existing target database (default: keep the newer file). */
  readonly force?: boolean
}

export interface MigrateSwiftDataResult {
  readonly inspection: SwiftDatabaseInspection
  readonly databaseCopied: boolean
  readonly casCopied: number
  readonly targetDatabasePath: string
}

/**
 * Migrates a Swift Mu data directory into a TypeScript-format directory:
 * validates, copies mu.sqlite, and mirrors the cas/sha256 tree. If a target
 * database already exists and is newer, it is kept unless force is set.
 */
export function migrateSwiftDataDirectory(
  options: MigrateSwiftDataOptions,
): MigrateSwiftDataResult {
  const sourceDatabase = path.join(options.sourceDataDirectory, options.sourceFilename ?? 'mu.sqlite')
  const inspection = inspectSwiftDatabase(sourceDatabase)
  if (!inspection.schemaValid) {
    throw MuError.database(`Source database is not a valid Mu database: ${sourceDatabase}.`)
  }

  fs.mkdirSync(options.targetDataDirectory, { recursive: true })
  const targetDatabase = path.join(options.targetDataDirectory, 'mu.sqlite')

  const sourceStat = fs.statSync(sourceDatabase)
  let databaseCopied = true
  if (fs.existsSync(targetDatabase)) {
    const targetStat = fs.statSync(targetDatabase)
    if (!options.force && targetStat.mtimeMs >= sourceStat.mtimeMs) {
      databaseCopied = false
    }
  }
  if (databaseCopied) {
    fs.copyFileSync(sourceDatabase, targetDatabase)
  }

  // Mirror the CAS tree.
  const sourceCas = path.join(options.sourceDataDirectory, 'cas', 'sha256')
  const targetCas = path.join(options.targetDataDirectory, 'cas', 'sha256')
  let casCopied = 0
  if (fs.existsSync(sourceCas)) {
    fs.mkdirSync(targetCas, { recursive: true })
    for (const entry of fs.readdirSync(sourceCas, { withFileTypes: true })) {
      if (!entry.isFile()) continue
      fs.copyFileSync(path.join(sourceCas, entry.name), path.join(targetCas, entry.name))
      casCopied += 1
    }
  }

  return {
    inspection,
    databaseCopied,
    casCopied,
    targetDatabasePath: targetDatabase,
  }
}
