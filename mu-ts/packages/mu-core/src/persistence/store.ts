import fs from 'node:fs'
import path from 'node:path'
import Database from 'better-sqlite3'
import { MuError } from '../errors.ts'
import { encodeMuJSON, formatIso8601Date } from '../hashing.ts'
import type { UUID } from '../identity.ts'
import type { LedgerEvent } from '../models.ts'
import type { PresenceSessionRecord, SpaceEventRecord } from '../collaboration.ts'

/**
 * SQLite persistence layer, schema-compatible with the Swift SQLiteStore.
 * All JSON columns are written with encodeMuJSON (sorted keys, ISO8601 UTC
 * dates, unescaped slashes) so the same database file is readable by both
 * implementations.
 */
export interface SQLiteStoreOptions {
  /** Directory that will contain `mu.sqlite` (and the `cas/` sibling tree). */
  dataDirectory: string
  /** Override the database filename; use ':memory:' for tests. */
  filename?: string
}

const ISO8601_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/

/** Parses Swift-written JSON, reviving ISO8601 strings into Dates. */
export function decodeMuJSON<T>(json: string): T {
  return JSON.parse(json, (_key, value) => {
    if (typeof value === 'string' && ISO8601_RE.test(value)) {
      return new Date(value)
    }
    return value
  }) as T
}

export class SQLiteStore {
  private readonly db: Database.Database

  constructor(options: SQLiteStoreOptions) {
    const filename = options.filename ?? 'mu.sqlite'
    const dbPath = filename === ':memory:'
      ? ':memory:'
      : path.join(options.dataDirectory, filename)
    if (filename !== ':memory:') {
      fs.mkdirSync(path.dirname(dbPath), { recursive: true })
    }
    this.db = new Database(dbPath)
    this.db.pragma('journal_mode = WAL')
    this.db.pragma('foreign_keys = ON')
    this.db.pragma('secure_delete = ON')
    this.migrate()
  }

  close(): void {
    this.db.close()
  }

  // -------------------------------------------------------------------------
  // Schema (byte-identical to the Swift SQLiteStore.migrate())
  // -------------------------------------------------------------------------

  private migrate(): void {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS records (
        kind TEXT NOT NULL,
        id TEXT NOT NULL,
        task_id TEXT,
        sort_at TEXT NOT NULL,
        json TEXT NOT NULL,
        PRIMARY KEY (kind, id)
      );
      CREATE INDEX IF NOT EXISTS records_kind_sort
        ON records(kind, sort_at DESC);
      CREATE INDEX IF NOT EXISTS records_task
        ON records(task_id, kind, sort_at DESC);

      CREATE TABLE IF NOT EXISTS collaboration_space_events (
        space_id TEXT NOT NULL,
        sequence INTEGER NOT NULL,
        event_id TEXT PRIMARY KEY,
        thread_id TEXT,
        actor_id TEXT NOT NULL,
        client_instance_id TEXT NOT NULL,
        idempotency_key TEXT NOT NULL,
        occurred_at TEXT NOT NULL,
        json TEXT NOT NULL,
        UNIQUE(space_id, sequence),
        UNIQUE(space_id, idempotency_key)
      );
      CREATE INDEX IF NOT EXISTS collaboration_space_events_stream
        ON collaboration_space_events(space_id, sequence ASC);

      CREATE TABLE IF NOT EXISTS collaboration_presence (
        id TEXT PRIMARY KEY,
        space_id TEXT NOT NULL,
        actor_id TEXT NOT NULL,
        client_instance_id TEXT NOT NULL,
        last_seen_at TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        json TEXT NOT NULL,
        UNIQUE(space_id, actor_id, client_instance_id)
      );
      CREATE INDEX IF NOT EXISTS collaboration_presence_space
        ON collaboration_presence(space_id, expires_at DESC);

      CREATE TABLE IF NOT EXISTS ledger (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT,
        event_id TEXT NOT NULL UNIQUE,
        task_id TEXT,
        run_id TEXT,
        type TEXT NOT NULL,
        occurred_at TEXT NOT NULL,
        json TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS ledger_task_sequence
        ON ledger(task_id, sequence DESC);

      CREATE TABLE IF NOT EXISTS imported_conversations (
        id TEXT PRIMARY KEY,
        task_id TEXT NOT NULL,
        provider TEXT NOT NULL,
        provider_instance_key TEXT NOT NULL,
        native_session_id TEXT NOT NULL,
        canonical_workspace_path TEXT NOT NULL,
        sort_at TEXT NOT NULL,
        json TEXT NOT NULL,
        UNIQUE(task_id, provider_instance_key, native_session_id, canonical_workspace_path)
      );
      CREATE INDEX IF NOT EXISTS imported_conversations_task
        ON imported_conversations(task_id, sort_at DESC);

      CREATE TABLE IF NOT EXISTS imported_messages (
        id TEXT PRIMARY KEY,
        task_id TEXT NOT NULL,
        conversation_id TEXT NOT NULL,
        native_item_id TEXT NOT NULL,
        source_ordinal INTEGER NOT NULL,
        sort_at TEXT NOT NULL,
        json TEXT NOT NULL,
        UNIQUE(conversation_id, native_item_id),
        UNIQUE(conversation_id, source_ordinal),
        FOREIGN KEY(conversation_id) REFERENCES imported_conversations(id) ON DELETE CASCADE
      );
      CREATE INDEX IF NOT EXISTS imported_messages_conversation
        ON imported_messages(conversation_id, source_ordinal ASC);
      CREATE INDEX IF NOT EXISTS imported_messages_conversation_recent
        ON imported_messages(conversation_id, sort_at DESC, source_ordinal DESC);

      CREATE TABLE IF NOT EXISTS task_context_sources (
        task_id TEXT NOT NULL,
        conversation_id TEXT NOT NULL,
        enabled INTEGER NOT NULL,
        sort_order INTEGER NOT NULL,
        json TEXT NOT NULL,
        PRIMARY KEY(task_id, conversation_id),
        FOREIGN KEY(conversation_id) REFERENCES imported_conversations(id) ON DELETE CASCADE
      );
      CREATE INDEX IF NOT EXISTS task_context_sources_task
        ON task_context_sources(task_id, enabled DESC, sort_order ASC);

      CREATE TABLE IF NOT EXISTS context_snapshots (
        id TEXT PRIMARY KEY,
        task_id TEXT NOT NULL,
        target_binding_id TEXT NOT NULL,
        selection_fingerprint TEXT NOT NULL,
        created_at TEXT NOT NULL,
        json TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS context_snapshots_binding
        ON context_snapshots(target_binding_id, selection_fingerprint, created_at DESC);

      CREATE TABLE IF NOT EXISTS context_sources (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        source_actor_id TEXT NOT NULL,
        source_principal_id TEXT,
        access_policy_id TEXT NOT NULL,
        source_checksum TEXT NOT NULL,
        external_ref TEXT,
        state TEXT NOT NULL,
        revision INTEGER NOT NULL,
        sort_at TEXT NOT NULL,
        json TEXT NOT NULL,
        UNIQUE(project_id, id),
        FOREIGN KEY(project_id, access_policy_id)
          REFERENCES context_access_policies(project_id, id)
          ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED
      );
      CREATE INDEX IF NOT EXISTS context_sources_project
        ON context_sources(project_id, sort_at DESC);
      CREATE INDEX IF NOT EXISTS context_sources_checksum
        ON context_sources(project_id, source_checksum);

      CREATE TABLE IF NOT EXISTS context_records (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        source_id TEXT NOT NULL,
        external_id TEXT,
        content_sha256 TEXT NOT NULL,
        immutable_fingerprint TEXT NOT NULL,
        kind TEXT NOT NULL,
        status TEXT NOT NULL,
        scope_task_id TEXT,
        sensitivity TEXT NOT NULL,
        access_policy_id TEXT NOT NULL,
        revision INTEGER NOT NULL,
        subject TEXT,
        sort_at TEXT NOT NULL,
        json TEXT NOT NULL,
        UNIQUE(project_id, id),
        UNIQUE(project_id, source_id, external_id),
        UNIQUE(project_id, source_id, immutable_fingerprint),
        FOREIGN KEY(project_id, source_id) REFERENCES context_sources(project_id, id) ON DELETE RESTRICT,
        FOREIGN KEY(project_id, access_policy_id) REFERENCES context_access_policies(project_id, id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED
      );
      CREATE INDEX IF NOT EXISTS context_records_project_status
        ON context_records(project_id, status, sort_at DESC);
      CREATE INDEX IF NOT EXISTS context_records_subject
        ON context_records(project_id, subject, status);

      CREATE TABLE IF NOT EXISTS context_relations (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        from_record_id TEXT NOT NULL,
        to_record_id TEXT NOT NULL,
        relation_type TEXT NOT NULL,
        sort_at TEXT NOT NULL,
        json TEXT NOT NULL,
        UNIQUE(project_id, id),
        UNIQUE(project_id, from_record_id, to_record_id, relation_type),
        FOREIGN KEY(project_id, from_record_id) REFERENCES context_records(project_id, id) ON DELETE RESTRICT,
        FOREIGN KEY(project_id, to_record_id) REFERENCES context_records(project_id, id) ON DELETE RESTRICT
      );
      CREATE INDEX IF NOT EXISTS context_relations_project
        ON context_relations(project_id, sort_at DESC);

      CREATE TABLE IF NOT EXISTS context_conflicts (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        subject TEXT NOT NULL,
        status TEXT NOT NULL,
        revision INTEGER NOT NULL,
        sort_at TEXT NOT NULL,
        json TEXT NOT NULL,
        UNIQUE(project_id, id)
      );
      CREATE INDEX IF NOT EXISTS context_conflicts_project_status
        ON context_conflicts(project_id, status, sort_at DESC);

      CREATE TABLE IF NOT EXISTS context_conflict_records (
        project_id TEXT NOT NULL,
        conflict_id TEXT NOT NULL,
        record_id TEXT NOT NULL,
        PRIMARY KEY(project_id, conflict_id, record_id),
        FOREIGN KEY(project_id, conflict_id) REFERENCES context_conflicts(project_id, id) ON DELETE CASCADE,
        FOREIGN KEY(project_id, record_id) REFERENCES context_records(project_id, id) ON DELETE RESTRICT
      );
      CREATE INDEX IF NOT EXISTS context_conflict_records_project
        ON context_conflict_records(project_id, record_id);

      CREATE TABLE IF NOT EXISTS context_access_policies (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        subject_kind TEXT NOT NULL,
        subject_id TEXT NOT NULL,
        source_id TEXT,
        record_id TEXT,
        pack_id TEXT,
        family_id TEXT NOT NULL,
        version INTEGER NOT NULL,
        supersedes_policy_id TEXT,
        policy_sha256 TEXT NOT NULL,
        sort_at TEXT NOT NULL,
        json TEXT NOT NULL,
        UNIQUE(project_id, id),
        UNIQUE(project_id, family_id, version),
        UNIQUE(project_id, subject_kind, subject_id, version),
        FOREIGN KEY(project_id, supersedes_policy_id) REFERENCES context_access_policies(project_id, id) ON DELETE RESTRICT,
        FOREIGN KEY(project_id, source_id) REFERENCES context_sources(project_id, id) ON DELETE RESTRICT,
        FOREIGN KEY(project_id, record_id) REFERENCES context_records(project_id, id) ON DELETE RESTRICT,
        FOREIGN KEY(project_id, pack_id) REFERENCES context_packs(project_id, id) ON DELETE RESTRICT,
        CHECK(
          (subject_kind = 'source' AND source_id IS NOT NULL AND record_id IS NULL AND pack_id IS NULL)
          OR (subject_kind = 'record' AND record_id IS NOT NULL AND source_id IS NULL AND pack_id IS NULL)
          OR (subject_kind = 'pack' AND pack_id IS NOT NULL AND source_id IS NULL AND record_id IS NULL)
          OR (subject_kind = 'artifact' AND source_id IS NULL AND record_id IS NULL AND pack_id IS NULL)
        )
      );
      CREATE INDEX IF NOT EXISTS context_access_policies_project
        ON context_access_policies(project_id, sort_at DESC);

      CREATE TABLE IF NOT EXISTS context_packs (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        task_id TEXT NOT NULL,
        workspace_id TEXT NOT NULL,
        context_revision TEXT NOT NULL,
        policy_revision TEXT NOT NULL,
        content_sha256 TEXT NOT NULL,
        sort_at TEXT NOT NULL,
        json TEXT NOT NULL,
        UNIQUE(project_id, id)
      );
      CREATE INDEX IF NOT EXISTS context_packs_project_task
        ON context_packs(project_id, task_id, sort_at DESC);

      CREATE TABLE IF NOT EXISTS context_pack_items (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        pack_id TEXT NOT NULL,
        ordinal INTEGER NOT NULL,
        item_kind TEXT NOT NULL,
        referenced_id TEXT NOT NULL,
        record_id TEXT,
        conflict_id TEXT,
        json TEXT NOT NULL,
        UNIQUE(project_id, id),
        UNIQUE(pack_id, ordinal),
        UNIQUE(pack_id, item_kind, referenced_id),
        FOREIGN KEY(project_id, pack_id) REFERENCES context_packs(project_id, id) ON DELETE RESTRICT,
        FOREIGN KEY(project_id, record_id) REFERENCES context_records(project_id, id) ON DELETE RESTRICT,
        FOREIGN KEY(project_id, conflict_id) REFERENCES context_conflicts(project_id, id) ON DELETE RESTRICT,
        CHECK(
          (item_kind = 'record' AND record_id IS NOT NULL AND conflict_id IS NULL)
          OR (item_kind = 'conflict' AND conflict_id IS NOT NULL AND record_id IS NULL)
          OR (item_kind IN ('artifact', 'project_fact') AND record_id IS NULL AND conflict_id IS NULL)
        )
      );
      CREATE INDEX IF NOT EXISTS context_pack_items_project_pack
        ON context_pack_items(project_id, pack_id, ordinal ASC);

      CREATE TABLE IF NOT EXISTS context_import_jobs (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        source_actor_id TEXT NOT NULL,
        idempotency_key TEXT NOT NULL,
        status TEXT NOT NULL,
        progress REAL NOT NULL,
        revision INTEGER NOT NULL,
        sort_at TEXT NOT NULL,
        json TEXT NOT NULL,
        UNIQUE(project_id, id),
        UNIQUE(project_id, source_actor_id, idempotency_key)
      );
      CREATE INDEX IF NOT EXISTS context_import_jobs_project
        ON context_import_jobs(project_id, sort_at DESC);

      CREATE TABLE IF NOT EXISTS context_transitions (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        aggregate_kind TEXT NOT NULL,
        aggregate_id TEXT NOT NULL,
        from_state TEXT,
        to_state TEXT NOT NULL,
        expected_revision INTEGER NOT NULL,
        new_revision INTEGER NOT NULL,
        occurred_at TEXT NOT NULL,
        json TEXT NOT NULL,
        UNIQUE(project_id, aggregate_kind, aggregate_id, new_revision)
      );
      CREATE INDEX IF NOT EXISTS context_transitions_aggregate
        ON context_transitions(project_id, aggregate_kind, aggregate_id, new_revision ASC);

      CREATE TABLE IF NOT EXISTS context_deliveries (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        task_id TEXT NOT NULL,
        context_pack_id TEXT NOT NULL,
        runtime_binding_id TEXT NOT NULL,
        run_id TEXT NOT NULL,
        status TEXT NOT NULL,
        prepared_at TEXT NOT NULL,
        json TEXT NOT NULL,
        UNIQUE(project_id, id),
        UNIQUE(project_id, runtime_binding_id, run_id, status),
        FOREIGN KEY(project_id, context_pack_id) REFERENCES context_packs(project_id, id) ON DELETE RESTRICT
      );
      CREATE INDEX IF NOT EXISTS context_deliveries_task
        ON context_deliveries(project_id, task_id, prepared_at DESC);
      CREATE UNIQUE INDEX IF NOT EXISTS context_deliveries_one_terminal
        ON context_deliveries(project_id, runtime_binding_id, run_id)
        WHERE status IN ('delivered', 'failed');

      CREATE TABLE IF NOT EXISTS maintenance (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
    `)
  }

  // -------------------------------------------------------------------------
  // Generic records store (kind + id keyed, JSON payload)
  // -------------------------------------------------------------------------

  private encode(value: unknown): string {
    return encodeMuJSON(value)
  }

  /** Upsert a mutable record into the generic `records` table. */
  upsertRecord<T>(params: {
    kind: string
    id: UUID
    taskID?: UUID
    sortAt: Date
    value: T
  }): void {
    const stmt = this.db.prepare(
      `INSERT INTO records(kind, id, task_id, sort_at, json)
       VALUES (?, ?, ?, ?, ?)
       ON CONFLICT(kind, id) DO UPDATE SET
         task_id = excluded.task_id,
         sort_at = excluded.sort_at,
         json = excluded.json;`,
    )
    stmt.run(
      params.kind,
      params.id,
      params.taskID ?? null,
      dateString(params.sortAt),
      this.encode(params.value),
    )
  }

  /** Insert an immutable record; duplicates are rejected. */
  insertImmutableRecord<T>(params: {
    kind: string
    id: UUID
    taskID?: UUID
    sortAt: Date
    value: T
  }): void {
    const stmt = this.db.prepare(
      `INSERT INTO records(kind, id, task_id, sort_at, json) VALUES (?, ?, ?, ?, ?);`,
    )
    stmt.run(
      params.kind,
      params.id,
      params.taskID ?? null,
      dateString(params.sortAt),
      this.encode(params.value),
    )
  }

  fetchRecords<T>(kind: string): T[] {
    const rows = this.db
      .prepare('SELECT json FROM records WHERE kind = ? ORDER BY sort_at DESC;')
      .all(kind) as Array<{ json: string }>
    return rows.map((row) => decodeMuJSON<T>(row.json))
  }

  fetchRecord<T>(kind: string, id: UUID): T | undefined {
    const row = this.db
      .prepare('SELECT json FROM records WHERE kind = ? AND id = ?;')
      .get(kind, id) as { json: string } | undefined
    return row === undefined ? undefined : decodeMuJSON<T>(row.json)
  }

  fetchRecordsForTask<T>(kind: string, taskID: UUID): T[] {
    const rows = this.db
      .prepare('SELECT json FROM records WHERE task_id = ? AND kind = ? ORDER BY sort_at DESC;')
      .all(taskID, kind) as Array<{ json: string }>
    return rows.map((row) => decodeMuJSON<T>(row.json))
  }

  deleteRecord(kind: string, id: UUID): void {
    this.db.prepare('DELETE FROM records WHERE kind = ? AND id = ?;').run(kind, id)
  }

  // -------------------------------------------------------------------------
  // Shared Space transport projections
  // -------------------------------------------------------------------------

  nextSpaceEventSequence(spaceID: UUID): number {
    const row = this.db
      .prepare('SELECT COALESCE(MAX(sequence), 0) + 1 AS next FROM collaboration_space_events WHERE space_id = ?;')
      .get(spaceID) as { next: number }
    return row.next
  }

  latestSpaceEventSequence(spaceID: UUID): number {
    const row = this.db
      .prepare('SELECT COALESCE(MAX(sequence), 0) AS latest FROM collaboration_space_events WHERE space_id = ?;')
      .get(spaceID) as { latest: number }
    return row.latest
  }

  insertSpaceEvent(event: SpaceEventRecord): void {
    this.db
      .prepare(
        `INSERT INTO collaboration_space_events(
           space_id, sequence, event_id, thread_id, actor_id,
           client_instance_id, idempotency_key, occurred_at, json
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);`,
      )
      .run(
        event.spaceID,
        event.sequence,
        event.id,
        event.threadID ?? null,
        event.actorID,
        event.clientInstanceID,
        event.idempotencyKey,
        dateString(event.occurredAt),
        this.encode(event),
      )
  }

  fetchSpaceEventByIdempotency(spaceID: UUID, idempotencyKey: string): SpaceEventRecord | undefined {
    const row = this.db
      .prepare('SELECT json FROM collaboration_space_events WHERE space_id = ? AND idempotency_key = ?;')
      .get(spaceID, idempotencyKey) as { json: string } | undefined
    return row === undefined ? undefined : decodeMuJSON<SpaceEventRecord>(row.json)
  }

  fetchSpaceEvents(spaceID: UUID, afterSequence = 0, limit = 100): SpaceEventRecord[] {
    const rows = this.db
      .prepare(
        `SELECT json FROM collaboration_space_events
         WHERE space_id = ? AND sequence > ?
         ORDER BY sequence ASC LIMIT ?;`,
      )
      .all(spaceID, afterSequence, limit) as Array<{ json: string }>
    return rows.map((row) => decodeMuJSON<SpaceEventRecord>(row.json))
  }

  upsertPresenceSession(presence: PresenceSessionRecord): void {
    this.db
      .prepare(
        `INSERT INTO collaboration_presence(
           id, space_id, actor_id, client_instance_id,
           last_seen_at, expires_at, json
         ) VALUES (?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(space_id, actor_id, client_instance_id) DO UPDATE SET
           id = excluded.id,
           last_seen_at = excluded.last_seen_at,
           expires_at = excluded.expires_at,
           json = excluded.json;`,
      )
      .run(
        presence.id,
        presence.spaceID,
        presence.actorID,
        presence.clientInstanceID,
        dateString(presence.lastSeenAt),
        dateString(presence.expiresAt),
        this.encode(presence),
      )
  }

  fetchPresenceSession(
    spaceID: UUID,
    actorID: UUID,
    clientInstanceID: string,
  ): PresenceSessionRecord | undefined {
    const row = this.db
      .prepare(
        `SELECT json FROM collaboration_presence
         WHERE space_id = ? AND actor_id = ? AND client_instance_id = ?;`,
      )
      .get(spaceID, actorID, clientInstanceID) as { json: string } | undefined
    return row === undefined ? undefined : decodeMuJSON<PresenceSessionRecord>(row.json)
  }

  fetchPresenceSessions(spaceID: UUID, now = new Date()): PresenceSessionRecord[] {
    const rows = this.db
      .prepare(
        `SELECT json FROM collaboration_presence
         WHERE space_id = ? AND expires_at > ?
         ORDER BY last_seen_at DESC;`,
      )
      .all(spaceID, dateString(now)) as Array<{ json: string }>
    return rows.map((row) => decodeMuJSON<PresenceSessionRecord>(row.json))
  }

  deletePresenceSession(spaceID: UUID, actorID: UUID, clientInstanceID: string): void {
    this.db
      .prepare(
        `DELETE FROM collaboration_presence
         WHERE space_id = ? AND actor_id = ? AND client_instance_id = ?;`,
      )
      .run(spaceID, actorID, clientInstanceID)
  }

  // -------------------------------------------------------------------------
  // Ledger (append-only event log)
  // -------------------------------------------------------------------------

  appendEvent(event: LedgerEvent): number {
    const result = this.db
      .prepare(
        `INSERT INTO ledger(event_id, task_id, run_id, type, occurred_at, json)
         VALUES (?, ?, ?, ?, ?, ?);`,
      )
      .run(
        event.id,
        event.taskID ?? null,
        event.runID ?? null,
        event.type,
        dateString(event.occurredAt),
        this.encode(event),
      )
    if (typeof result.lastInsertRowid !== 'number') {
      throw MuError.database('Ledger append returned a non-numeric sequence.')
    }
    return result.lastInsertRowid
  }

  fetchEvents(taskID?: UUID, limit = 500): LedgerEvent[] {
    const rows = taskID === undefined
      ? (this.db
          .prepare('SELECT sequence, json FROM ledger ORDER BY sequence DESC LIMIT ?;')
          .all(limit) as Array<{ sequence: number; json: string }>)
      : (this.db
          .prepare('SELECT sequence, json FROM ledger WHERE task_id = ? ORDER BY sequence DESC LIMIT ?;')
          .all(taskID, limit) as Array<{ sequence: number; json: string }>)
    return rows.map((row) => ({
      ...decodeMuJSON<LedgerEvent>(row.json),
      sequence: row.sequence,
    }))
  }

  // -------------------------------------------------------------------------
  // Maintenance markers and maintenance
  // -------------------------------------------------------------------------

  hasMaintenanceMarker(key: string): boolean {
    return this.db.prepare('SELECT 1 FROM maintenance WHERE key = ? LIMIT 1;').get(key) !== undefined
  }

  setMaintenanceMarker(key: string, value = 'complete'): void {
    this.db
      .prepare(
        `INSERT INTO maintenance(key, value) VALUES (?, ?)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value;`,
      )
      .run(key, value)
  }

  scrubVacatedContent(): void {
    this.db.pragma('wal_checkpoint(TRUNCATE)')
    this.db.exec('VACUUM;')
    this.db.pragma('wal_checkpoint(TRUNCATE)')
  }

  /** Runs a closure inside an IMMEDIATE transaction (nested-safe via savepoints). */
  withTransaction<T>(operation: () => T): T {
    const nested = this.db.inTransaction
    if (nested) {
      return operation()
    }
    this.db.exec('BEGIN IMMEDIATE;')
    try {
      const result = operation()
      this.db.exec('COMMIT;')
      return result
    } catch (error) {
      this.db.exec('ROLLBACK;')
      throw error
    }
  }

  /** Raw access for custom queries (used by domain-specific stores). */
  prepare(sql: string): Database.Statement {
    return this.db.prepare(sql)
  }

  exec(sql: string): void {
    this.db.exec(sql)
  }
}

/** Swift ISO8601DateFormatter-compatible sort key. */
export function dateString(date: Date): string {
  return formatIso8601Date(date)
}
