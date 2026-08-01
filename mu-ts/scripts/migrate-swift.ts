#!/usr/bin/env -S node --experimental-strip-types
// Swift Mu data directory migration helper.
//
//   node scripts/migrate-swift.ts --source ~/Library/Application\ Support/Mu \
//                                  --target ./mu-data
//
// Validates the Swift-written mu.sqlite, copies it plus the CAS tree into the
// target directory, and prints a per-kind record summary.

import { inspectSwiftDatabase, inspectCasTree, migrateSwiftDataDirectory } from '../packages/mu-core/src/persistence/migrate-swift.ts'

function arg(name: string): string | undefined {
  const index = process.argv.indexOf(`--${name}`)
  return index === -1 ? undefined : process.argv[index + 1]
}

const source = arg('source')
const target = arg('target')
if (source === undefined || target === undefined) {
  console.error('Usage: node scripts/migrate-swift.ts --source <swift-data-dir> --target <target-dir> [--force]')
  process.exit(2)
}

const sourceDatabase = `${source}/mu.sqlite`
try {
  const inspection = inspectSwiftDatabase(sourceDatabase)
  const cas = inspectCasTree(source)
  console.log(`Source:      ${sourceDatabase}`)
  console.log(`Schema:      ${inspection.schemaValid ? 'valid (Swift-compatible tables)' : 'INVALID'}`)
  console.log(`Records:     ${inspection.recordCount}`)
  for (const [kind, count] of Object.entries(inspection.kinds)) {
    console.log(`  ${kind.padEnd(32)} ${count}`)
  }
  console.log(`Ledger:      ${inspection.ledgerCount} events`)
  console.log(`CAS tree:    ${cas.hasCasTree ? `${cas.casFileCount} artifacts` : 'absent'}`)
  for (const warning of inspection.warnings) console.warn(`Warning:     ${warning}`)

  const result = migrateSwiftDataDirectory({
    sourceDataDirectory: source,
    targetDataDirectory: target,
    force: process.argv.includes('--force'),
  })
  console.log(`Database:    ${result.databaseCopied ? 'copied' : 'kept existing (target is newer)'} → ${result.targetDatabasePath}`)
  console.log(`CAS copied:  ${result.casCopied} files`)
  console.log('Migration complete — the TypeScript Mu server can open this directory.')
} catch (error) {
  console.error(`Migration failed: ${error instanceof Error ? error.message : String(error)}`)
  process.exit(1)
}
