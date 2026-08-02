import Foundation
import SQLite3

private let muSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class SQLiteStore {
    public let databaseURL: URL

    private var database: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var transactionDepth = 0

    public init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open database."
            if let database { sqlite3_close(database) }
            database = nil
            throw MuError.database(message)
        }

        sqlite3_busy_timeout(database, 3_000)
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA secure_delete = ON;")
        try migrate()
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    public static func defaultDataDirectory() throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw MuError.database("Application Support directory is unavailable.")
        }
        return applicationSupport.appending(path: "Mu", directoryHint: .isDirectory)
    }

    private func migrate() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS records (
                kind TEXT NOT NULL,
                id TEXT NOT NULL,
                task_id TEXT,
                sort_at TEXT NOT NULL,
                json TEXT NOT NULL,
                PRIMARY KEY (kind, id)
            );
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS records_kind_sort
            ON records(kind, sort_at DESC);
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS records_task
            ON records(task_id, kind, sort_at DESC);
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS ledger (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                event_id TEXT NOT NULL UNIQUE,
                task_id TEXT,
                run_id TEXT,
                type TEXT NOT NULL,
                occurred_at TEXT NOT NULL,
                json TEXT NOT NULL
            );
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS ledger_task_sequence
            ON ledger(task_id, sequence DESC);
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS imported_conversations (
                id TEXT PRIMARY KEY,
                task_id TEXT NOT NULL,
                provider TEXT NOT NULL,
                provider_instance_key TEXT NOT NULL,
                native_session_id TEXT NOT NULL,
                canonical_workspace_path TEXT NOT NULL,
                sort_at TEXT NOT NULL,
                json TEXT NOT NULL,
                UNIQUE(
                    task_id,
                    provider_instance_key,
                    native_session_id,
                    canonical_workspace_path
                )
            );
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS imported_conversations_task
            ON imported_conversations(task_id, sort_at DESC);
            """
        )
        try execute(
            """
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
                FOREIGN KEY(conversation_id)
                    REFERENCES imported_conversations(id)
                    ON DELETE CASCADE
            );
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS imported_messages_conversation
            ON imported_messages(conversation_id, source_ordinal ASC);
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS imported_messages_conversation_recent
            ON imported_messages(
                conversation_id,
                sort_at DESC,
                source_ordinal DESC
            );
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS task_context_sources (
                task_id TEXT NOT NULL,
                conversation_id TEXT NOT NULL,
                enabled INTEGER NOT NULL,
                sort_order INTEGER NOT NULL,
                json TEXT NOT NULL,
                PRIMARY KEY(task_id, conversation_id),
                FOREIGN KEY(conversation_id)
                    REFERENCES imported_conversations(id)
                    ON DELETE CASCADE
            );
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS task_context_sources_task
            ON task_context_sources(task_id, enabled DESC, sort_order ASC);
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS context_snapshots (
                id TEXT PRIMARY KEY,
                task_id TEXT NOT NULL,
                target_binding_id TEXT NOT NULL,
                selection_fingerprint TEXT NOT NULL,
                created_at TEXT NOT NULL,
                json TEXT NOT NULL
            );
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS context_snapshots_binding
            ON context_snapshots(target_binding_id, selection_fingerprint, created_at DESC);
            """
        )
        try execute(
            """
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
                    ON DELETE RESTRICT
                    DEFERRABLE INITIALLY DEFERRED
            );
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS context_sources_project
            ON context_sources(project_id, sort_at DESC);
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS context_sources_checksum
            ON context_sources(project_id, source_checksum);
            """
        )
        try execute(
            """
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
                FOREIGN KEY(project_id, source_id)
                    REFERENCES context_sources(project_id, id)
                    ON DELETE RESTRICT,
                FOREIGN KEY(project_id, access_policy_id)
                    REFERENCES context_access_policies(project_id, id)
                    ON DELETE RESTRICT
                    DEFERRABLE INITIALLY DEFERRED
            );
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS context_records_project_status
            ON context_records(project_id, status, sort_at DESC);
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS context_records_subject
            ON context_records(project_id, subject, status);
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS context_relations (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                from_record_id TEXT NOT NULL,
                to_record_id TEXT NOT NULL,
                relation_type TEXT NOT NULL,
                sort_at TEXT NOT NULL,
                json TEXT NOT NULL,
                UNIQUE(project_id, id),
                UNIQUE(
                    project_id,
                    from_record_id,
                    to_record_id,
                    relation_type
                ),
                FOREIGN KEY(project_id, from_record_id)
                    REFERENCES context_records(project_id, id)
                    ON DELETE RESTRICT,
                FOREIGN KEY(project_id, to_record_id)
                    REFERENCES context_records(project_id, id)
                    ON DELETE RESTRICT
            );
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS context_relations_project
            ON context_relations(project_id, sort_at DESC);
            """
        )
        try execute(
            """
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
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS context_conflicts_project_status
            ON context_conflicts(project_id, status, sort_at DESC);
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS context_conflict_records (
                project_id TEXT NOT NULL,
                conflict_id TEXT NOT NULL,
                record_id TEXT NOT NULL,
                PRIMARY KEY(project_id, conflict_id, record_id),
                FOREIGN KEY(project_id, conflict_id)
                    REFERENCES context_conflicts(project_id, id)
                    ON DELETE CASCADE,
                FOREIGN KEY(project_id, record_id)
                    REFERENCES context_records(project_id, id)
                    ON DELETE RESTRICT
            );
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS context_conflict_records_project
            ON context_conflict_records(project_id, record_id);
            """
        )
        try execute(
            """
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
                UNIQUE(
                    project_id,
                    family_id,
                    version
                ),
                UNIQUE(
                    project_id,
                    subject_kind,
                    subject_id,
                    version
                ),
                FOREIGN KEY(project_id, supersedes_policy_id)
                    REFERENCES context_access_policies(project_id, id)
                    ON DELETE RESTRICT,
                FOREIGN KEY(project_id, source_id)
                    REFERENCES context_sources(project_id, id)
                    ON DELETE RESTRICT,
                FOREIGN KEY(project_id, record_id)
                    REFERENCES context_records(project_id, id)
                    ON DELETE RESTRICT,
                FOREIGN KEY(project_id, pack_id)
                    REFERENCES context_packs(project_id, id)
                    ON DELETE RESTRICT,
                CHECK(
                    (subject_kind = 'source'
                        AND source_id IS NOT NULL
                        AND record_id IS NULL
                        AND pack_id IS NULL)
                    OR (subject_kind = 'record'
                        AND record_id IS NOT NULL
                        AND source_id IS NULL
                        AND pack_id IS NULL)
                    OR (subject_kind = 'pack'
                        AND pack_id IS NOT NULL
                        AND source_id IS NULL
                        AND record_id IS NULL)
                    OR (subject_kind = 'artifact'
                        AND source_id IS NULL
                        AND record_id IS NULL
                        AND pack_id IS NULL)
                )
            );
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS context_access_policies_project
            ON context_access_policies(project_id, sort_at DESC);
            """
        )
        try execute(
            """
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
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS context_packs_project_task
            ON context_packs(project_id, task_id, sort_at DESC);
            """
        )
        try execute(
            """
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
                FOREIGN KEY(project_id, pack_id)
                    REFERENCES context_packs(project_id, id)
                    ON DELETE RESTRICT,
                FOREIGN KEY(project_id, record_id)
                    REFERENCES context_records(project_id, id)
                    ON DELETE RESTRICT,
                FOREIGN KEY(project_id, conflict_id)
                    REFERENCES context_conflicts(project_id, id)
                    ON DELETE RESTRICT,
                CHECK(
                    (item_kind = 'record'
                        AND record_id IS NOT NULL
                        AND conflict_id IS NULL)
                    OR (item_kind = 'conflict'
                        AND conflict_id IS NOT NULL
                        AND record_id IS NULL)
                    OR (item_kind IN ('artifact', 'project_fact')
                        AND record_id IS NULL
                        AND conflict_id IS NULL)
                )
            );
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS context_pack_items_project_pack
            ON context_pack_items(project_id, pack_id, ordinal ASC);
            """
        )
        try execute(
            """
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
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS context_import_jobs_project
            ON context_import_jobs(project_id, sort_at DESC);
            """
        )
        try execute(
            """
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
                UNIQUE(
                    project_id,
                    aggregate_kind,
                    aggregate_id,
                    new_revision
                )
            );
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS context_transitions_aggregate
            ON context_transitions(
                project_id,
                aggregate_kind,
                aggregate_id,
                new_revision ASC
            );
            """
        )
        try execute(
            """
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
                UNIQUE(
                    project_id,
                    runtime_binding_id,
                    run_id,
                    status
                ),
                FOREIGN KEY(project_id, context_pack_id)
                    REFERENCES context_packs(project_id, id)
                    ON DELETE RESTRICT
            );
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS context_deliveries_task
            ON context_deliveries(project_id, task_id, prepared_at DESC);
            """
        )
        try execute(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS
                context_deliveries_one_terminal
            ON context_deliveries(
                project_id,
                runtime_binding_id,
                run_id
            )
            WHERE status IN ('delivered', 'failed');
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS maintenance (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """
        )
    }

    public func hasMaintenanceMarker(_ key: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(
            "SELECT 1 FROM maintenance WHERE key = ? LIMIT 1;"
        )
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    public func setMaintenanceMarker(
        _ key: String,
        value: String = "complete"
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(
            """
            INSERT INTO maintenance(key, value)
            VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, in: statement)
        bind(value, at: 2, in: statement)
        try stepDone(statement)
    }

    public func scrubVacatedContent() throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("PRAGMA wal_checkpoint(TRUNCATE);")
        try execute("VACUUM;")
        try execute("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    public func withTransaction<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        if transactionDepth > 0 {
            transactionDepth += 1
            defer { transactionDepth -= 1 }
            return try operation()
        }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        transactionDepth = 1
        do {
            let result = try operation()
            try execute("COMMIT;")
            transactionDepth = 0
            return result
        } catch {
            try? execute("ROLLBACK;")
            transactionDepth = 0
            throw error
        }
    }

    public func fetchTasks() throws -> [TaskRecord] {
        try fetchRecords(kind: "task", as: TaskRecord.self)
    }

    public func fetchTask(id: UUID) throws -> TaskRecord? {
        try fetchRecord(kind: "task", id: id, as: TaskRecord.self)
    }

    public func upsertTask(_ task: TaskRecord) throws {
        try upsertRecord(kind: "task", id: task.id, taskID: task.id, sortAt: task.updatedAt, value: task)
    }

    public func fetchProjectPreferences() throws -> [ProjectPreference] {
        try fetchRecords(
            kind: "project_preference",
            as: ProjectPreference.self
        )
    }

    public func upsertProjectPreference(
        _ preference: ProjectPreference
    ) throws {
        try upsertRecord(
            kind: "project_preference",
            id: preference.id,
            taskID: nil,
            sortAt: preference.updatedAt,
            value: preference
        )
    }

    public func fetchProjects() throws -> [ProjectRecord] {
        try fetchRecords(kind: "project", as: ProjectRecord.self)
    }

    public func fetchProject(id: UUID) throws -> ProjectRecord? {
        try fetchRecord(
            kind: "project",
            id: id,
            as: ProjectRecord.self
        )
    }

    public func fetchProject(
        repositoryPath: String
    ) throws -> ProjectRecord? {
        let canonicalPath = WorkspacePathIdentity.canonicalPath(
            repositoryPath
        )
        return try fetchProjects().first {
            $0.repositoryPath.map {
                WorkspacePathIdentity.isExactMatch(
                    $0,
                    canonicalPath
                )
            } == true
        }
    }

    public func upsertProject(_ project: ProjectRecord) throws {
        try upsertRecord(
            kind: "project",
            id: project.id,
            taskID: nil,
            sortAt: project.updatedAt,
            value: project
        )
    }

    // MARK: - Collaboration surface records

    public func fetchCollaborationSpaces() throws -> [CollaborationSpaceRecord] {
        try fetchRecords(
            kind: "collaboration_space",
            as: CollaborationSpaceRecord.self
        )
    }

    public func fetchCollaborationSpace(
        id: UUID
    ) throws -> CollaborationSpaceRecord? {
        try fetchRecord(
            kind: "collaboration_space",
            id: id,
            as: CollaborationSpaceRecord.self
        )
    }

    public func upsertCollaborationSpace(
        _ space: CollaborationSpaceRecord
    ) throws {
        try upsertRecord(
            kind: "collaboration_space",
            id: space.id,
            taskID: nil,
            sortAt: space.updatedAt,
            value: space
        )
    }

    public func fetchSpaceThreads(
        spaceID: UUID? = nil
    ) throws -> [SpaceThreadRecord] {
        let threads = try fetchRecords(
            kind: "space_thread",
            as: SpaceThreadRecord.self
        )
        guard let spaceID else { return threads }
        return threads.filter { $0.spaceID == spaceID }
    }

    public func fetchSpaceThread(
        id: UUID
    ) throws -> SpaceThreadRecord? {
        try fetchRecord(
            kind: "space_thread",
            id: id,
            as: SpaceThreadRecord.self
        )
    }

    public func upsertSpaceThread(
        _ thread: SpaceThreadRecord
    ) throws {
        try upsertRecord(
            kind: "space_thread",
            id: thread.id,
            taskID: nil,
            sortAt: thread.updatedAt,
            value: thread
        )
    }

    public func fetchSpaceProjectLinks(
        spaceID: UUID? = nil,
        projectID: UUID? = nil
    ) throws -> [SpaceProjectLinkRecord] {
        let links = try fetchRecords(
            kind: "space_project_link",
            as: SpaceProjectLinkRecord.self
        )
        return links.filter { link in
            (spaceID == nil || link.spaceID == spaceID)
                && (projectID == nil || link.projectID == projectID)
        }
    }

    public func fetchSpaceProjectLink(
        id: UUID
    ) throws -> SpaceProjectLinkRecord? {
        try fetchRecord(
            kind: "space_project_link",
            id: id,
            as: SpaceProjectLinkRecord.self
        )
    }

    public func upsertSpaceProjectLink(
        _ link: SpaceProjectLinkRecord
    ) throws {
        try upsertRecord(
            kind: "space_project_link",
            id: link.id,
            taskID: nil,
            sortAt: link.updatedAt,
            value: link
        )
    }

    public func fetchWorkItems(
        spaceID: UUID? = nil,
        threadID: UUID? = nil,
        projectID: UUID? = nil
    ) throws -> [WorkItemRecord] {
        let items = try fetchRecords(
            kind: "work_item",
            as: WorkItemRecord.self
        )
        return items.filter { item in
            (spaceID == nil || item.spaceID == spaceID)
                && (threadID == nil || item.threadID == threadID)
                && (projectID == nil || item.projectID == projectID)
        }
    }

    public func fetchWorkItem(id: UUID) throws -> WorkItemRecord? {
        try fetchRecord(kind: "work_item", id: id, as: WorkItemRecord.self)
    }

    public func upsertWorkItem(_ item: WorkItemRecord) throws {
        try upsertRecord(
            kind: "work_item",
            id: item.id,
            taskID: nil,
            sortAt: item.updatedAt,
            value: item
        )
    }

    public func fetchSharedBlocks(
        spaceID: UUID? = nil,
        threadID: UUID? = nil
    ) throws -> [SharedBlockRecord] {
        let blocks = try fetchRecords(
            kind: "shared_block",
            as: SharedBlockRecord.self
        )
        return blocks
            .filter { block in
                (spaceID == nil || block.spaceID == spaceID)
                    && (threadID == nil || block.threadID == threadID)
            }
            .sorted {
                if $0.positionKey != $1.positionKey {
                    return $0.positionKey < $1.positionKey
                }
                return $0.createdAt < $1.createdAt
            }
    }

    public func fetchSharedBlock(id: UUID) throws -> SharedBlockRecord? {
        try fetchRecord(
            kind: "shared_block",
            id: id,
            as: SharedBlockRecord.self
        )
    }

    public func upsertSharedBlock(_ block: SharedBlockRecord) throws {
        try upsertRecord(
            kind: "shared_block",
            id: block.id,
            taskID: nil,
            sortAt: block.updatedAt,
            value: block
        )
    }

    // MARK: - Collaboration event streams

    public func fetchSpaceEvents(
        spaceID: UUID,
        threadID: UUID? = nil
    ) throws -> [SpaceEventRecord] {
        try fetchRecords(
            kind: "space_event",
            as: SpaceEventRecord.self
        )
        .filter {
            $0.spaceID == spaceID
                && (threadID == nil || $0.threadID == threadID)
        }
        .sorted {
            if $0.sequence != $1.sequence {
                return $0.sequence < $1.sequence
            }
            return $0.occurredAt < $1.occurredAt
        }
    }

    public func fetchSpaceEvent(id: UUID) throws -> SpaceEventRecord? {
        try fetchRecord(kind: "space_event", id: id, as: SpaceEventRecord.self)
    }

    public func upsertSpaceEvent(_ event: SpaceEventRecord) throws {
        try upsertRecord(
            kind: "space_event",
            id: event.id,
            taskID: nil,
            sortAt: event.occurredAt,
            value: event
        )
    }

    public func fetchRuntimeEvents(
        runID: UUID,
        bindingID: UUID? = nil
    ) throws -> [RuntimeEventRecord] {
        try fetchRecords(
            kind: "runtime_event",
            as: RuntimeEventRecord.self
        )
        .filter {
            $0.runID == runID
                && (bindingID == nil || $0.bindingID == bindingID)
        }
        .sorted {
            if $0.sequence != $1.sequence {
                return $0.sequence < $1.sequence
            }
            return $0.occurredAt < $1.occurredAt
        }
    }

    public func fetchRuntimeEvent(id: UUID) throws -> RuntimeEventRecord? {
        try fetchRecord(kind: "runtime_event", id: id, as: RuntimeEventRecord.self)
    }

    public func upsertRuntimeEvent(_ event: RuntimeEventRecord) throws {
        try upsertRecord(
            kind: "runtime_event",
            id: event.id,
            taskID: nil,
            sortAt: event.occurredAt,
            value: event
        )
    }

    public func fetchPresenceSessions(
        spaceID: UUID,
        includingExpired: Bool = false,
        now: Date = Date()
    ) throws -> [PresenceSessionRecord] {
        try fetchRecords(
            kind: "presence_session",
            as: PresenceSessionRecord.self
        )
        .filter {
            $0.spaceID == spaceID
                && (includingExpired || !$0.isExpired(at: now))
        }
        .sorted {
            if $0.state != $1.state {
                return $0.state == .online
            }
            return $0.lastSeenAt > $1.lastSeenAt
        }
    }

    public func fetchPresenceSession(id: UUID) throws -> PresenceSessionRecord? {
        try fetchRecord(
            kind: "presence_session",
            id: id,
            as: PresenceSessionRecord.self
        )
    }

    public func upsertPresenceSession(_ session: PresenceSessionRecord) throws {
        try upsertRecord(
            kind: "presence_session",
            id: session.id,
            taskID: nil,
            sortAt: session.lastSeenAt,
            value: session
        )
    }

    // MARK: - Collaboration optimistic writes

    public func updateCollaborationSpace(
        _ space: CollaborationSpaceRecord,
        expectedVersion: Int64
    ) throws {
        try upsertVersionedRecord(
            kind: "collaboration_space",
            id: space.id,
            sortAt: space.updatedAt,
            value: space,
            expectedVersion: expectedVersion
        )
    }

    public func updateSpaceThread(
        _ thread: SpaceThreadRecord,
        expectedVersion: Int64
    ) throws {
        try upsertVersionedRecord(
            kind: "space_thread",
            id: thread.id,
            sortAt: thread.updatedAt,
            value: thread,
            expectedVersion: expectedVersion
        )
    }

    public func updateSpaceProjectLink(
        _ link: SpaceProjectLinkRecord,
        expectedVersion: Int64
    ) throws {
        try upsertVersionedRecord(
            kind: "space_project_link",
            id: link.id,
            sortAt: link.updatedAt,
            value: link,
            expectedVersion: expectedVersion
        )
    }

    public func updateWorkItem(
        _ item: WorkItemRecord,
        expectedVersion: Int64
    ) throws {
        try upsertVersionedRecord(
            kind: "work_item",
            id: item.id,
            sortAt: item.updatedAt,
            value: item,
            expectedVersion: expectedVersion
        )
    }

    public func updateSharedBlock(
        _ block: SharedBlockRecord,
        expectedVersion: Int64
    ) throws {
        try upsertVersionedRecord(
            kind: "shared_block",
            id: block.id,
            sortAt: block.updatedAt,
            value: block,
            expectedVersion: expectedVersion
        )
    }

    // MARK: - Collaboration outbox

    public func fetchOutbox(
        spaceID: UUID? = nil,
        state: CollaborationOutboxState? = nil
    ) throws -> [CollaborationOutboxRecord] {
        try fetchRecords(
            kind: "collaboration_outbox",
            as: CollaborationOutboxRecord.self
        )
        .filter {
            (spaceID == nil || $0.spaceID == spaceID)
                && (state == nil || $0.state == state)
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    public func fetchOutbox(id: UUID) throws -> CollaborationOutboxRecord? {
        try fetchRecord(
            kind: "collaboration_outbox",
            id: id,
            as: CollaborationOutboxRecord.self
        )
    }

    public func fetchOutbox(
        spaceID: UUID,
        stream: String,
        idempotencyKey: String
    ) throws -> CollaborationOutboxRecord? {
        try fetchOutbox(spaceID: spaceID).first {
            $0.stream == stream && $0.idempotencyKey == idempotencyKey
        }
    }

    public func upsertOutbox(_ record: CollaborationOutboxRecord) throws {
        try upsertRecord(
            kind: "collaboration_outbox",
            id: record.id,
            taskID: nil,
            sortAt: record.updatedAt,
            value: record
        )
    }

    /// Returns the existing record for a repeated command instead of creating
    /// a second pending command. This makes reconnect/retry safe before a
    /// remote transport is introduced.
    @discardableResult
    public func enqueueOutbox(
        _ record: CollaborationOutboxRecord
    ) throws -> CollaborationOutboxRecord {
        if let existing = try fetchOutbox(
            spaceID: record.spaceID,
            stream: record.stream,
            idempotencyKey: record.idempotencyKey
        ) {
            return existing
        }
        try upsertOutbox(record)
        return record
    }

    public func updateOutbox(
        _ record: CollaborationOutboxRecord,
        expectedVersion: Int64
    ) throws {
        try upsertVersionedRecord(
            kind: "collaboration_outbox",
            id: record.id,
            sortAt: record.updatedAt,
            value: record,
            expectedVersion: expectedVersion
        )
    }

    public func fetchPrincipals() throws -> [PrincipalRecord] {
        try fetchRecords(kind: "principal", as: PrincipalRecord.self)
    }

    public func fetchPrincipal(id: UUID) throws -> PrincipalRecord? {
        try fetchRecord(
            kind: "principal",
            id: id,
            as: PrincipalRecord.self
        )
    }

    public func upsertPrincipal(_ principal: PrincipalRecord) throws {
        try upsertRecord(
            kind: "principal",
            id: principal.id,
            taskID: nil,
            sortAt: principal.updatedAt,
            value: principal
        )
    }

    public func fetchProjectActors() throws -> [ProjectActorRecord] {
        try fetchRecords(
            kind: "project_actor",
            as: ProjectActorRecord.self
        )
    }

    public func fetchProjectActor(
        id: UUID
    ) throws -> ProjectActorRecord? {
        try fetchRecord(
            kind: "project_actor",
            id: id,
            as: ProjectActorRecord.self
        )
    }

    public func upsertProjectActor(
        _ actor: ProjectActorRecord
    ) throws {
        try upsertRecord(
            kind: "project_actor",
            id: actor.id,
            taskID: nil,
            sortAt: actor.updatedAt,
            value: actor
        )
    }

    public func fetchProjectMemberships(
        projectID: UUID? = nil
    ) throws -> [ProjectMembershipRecord] {
        let values = try fetchRecords(
            kind: "project_membership",
            as: ProjectMembershipRecord.self
        )
        guard let projectID else { return values }
        return values.filter { $0.projectID == projectID }
    }

    public func upsertProjectMembership(
        _ membership: ProjectMembershipRecord
    ) throws {
        try upsertRecord(
            kind: "project_membership",
            id: membership.id,
            taskID: nil,
            sortAt: membership.updatedAt,
            value: membership
        )
    }

    public func fetchDelegations(
        projectID: UUID? = nil,
        agentActorID: UUID? = nil,
        taskID: UUID? = nil
    ) throws -> [DelegationRecord] {
        try fetchRecords(
            kind: "delegation",
            as: DelegationRecord.self
        ).filter {
            (projectID == nil || $0.projectID == projectID)
                && (agentActorID == nil
                    || $0.agentActorID == agentActorID)
                && (taskID == nil
                    || $0.taskID == nil
                    || $0.taskID == taskID)
        }
    }

    public func upsertDelegation(
        _ delegation: DelegationRecord
    ) throws {
        try upsertRecord(
            kind: "delegation",
            id: delegation.id,
            taskID: delegation.taskID,
            sortAt: delegation.updatedAt,
            value: delegation
        )
    }

    public func fetchProjectWorkspaces(
        projectID: UUID? = nil,
        taskID: UUID? = nil
    ) throws -> [ProjectWorkspaceRecord] {
        try fetchRecords(
            kind: "project_workspace",
            taskID: taskID,
            as: ProjectWorkspaceRecord.self
        ).filter {
            projectID == nil || $0.projectID == projectID
        }
    }

    public func fetchProjectWorkspace(
        id: UUID
    ) throws -> ProjectWorkspaceRecord? {
        try fetchRecord(
            kind: "project_workspace",
            id: id,
            as: ProjectWorkspaceRecord.self
        )
    }

    public func upsertProjectWorkspace(
        _ workspace: ProjectWorkspaceRecord
    ) throws {
        try upsertRecord(
            kind: "project_workspace",
            id: workspace.id,
            taskID: workspace.taskID,
            sortAt: workspace.updatedAt,
            value: workspace
        )
    }

    public func fetchTaskProjectLinks() throws -> [TaskProjectLink] {
        try fetchRecords(
            kind: "task_project_link",
            as: TaskProjectLink.self
        )
    }

    public func fetchTaskProjectLink(
        taskID: UUID
    ) throws -> TaskProjectLink? {
        try fetchRecord(
            kind: "task_project_link",
            id: taskID,
            as: TaskProjectLink.self
        )
    }

    public func upsertTaskProjectLink(
        _ link: TaskProjectLink
    ) throws {
        try upsertRecord(
            kind: "task_project_link",
            id: link.id,
            taskID: link.taskID,
            sortAt: link.updatedAt,
            value: link
        )
    }

    public func fetchTaskLeases(
        taskID: UUID? = nil
    ) throws -> [TaskLeaseRecord] {
        try fetchRecords(
            kind: "task_lease",
            taskID: taskID,
            as: TaskLeaseRecord.self
        )
    }

    public func fetchTaskLease(id: UUID) throws -> TaskLeaseRecord? {
        try fetchRecord(
            kind: "task_lease",
            id: id,
            as: TaskLeaseRecord.self
        )
    }

    public func upsertTaskLease(_ lease: TaskLeaseRecord) throws {
        try upsertRecord(
            kind: "task_lease",
            id: lease.id,
            taskID: lease.taskID,
            sortAt: lease.lastHeartbeatAt,
            value: lease
        )
    }

    public func claimTaskLease(
        projectID: UUID,
        taskID: UUID,
        agentActorID: UUID,
        endpointID: UUID,
        runtimeBindingID: UUID? = nil,
        duration: TimeInterval = 15 * 60,
        now: Date = Date()
    ) throws -> TaskLeaseRecord {
        try withTransaction {
            var leases = try fetchTaskLeases(taskID: taskID)
            for index in leases.indices
                where leases[index].state == .active
                    && !leases[index].isActive(at: now) {
                leases[index].state = .expired
                leases[index].releasedAt = now
                leases[index].lastHeartbeatAt = now
                try upsertTaskLease(leases[index])
            }
            if let active = leases.first(where: { $0.isActive(at: now) }) {
                if active.agentActorID == agentActorID,
                   active.endpointID == endpointID {
                    if let runtimeBindingID,
                       active.runtimeBindingID == nil {
                        var bound = active
                        bound.runtimeBindingID =
                            runtimeBindingID
                        bound.lastHeartbeatAt = now
                        try upsertTaskLease(bound)
                        return bound
                    }
                    guard runtimeBindingID == nil
                            || active.runtimeBindingID
                                == runtimeBindingID else {
                        throw MuError.invalidTransition(
                            "The active Task lease is fenced to another Runtime binding."
                        )
                    }
                    return active
                }
                throw MuError.invalidTransition(
                    "Task already has an active lease held by another Agent."
                )
            }
            let nextFencingToken =
                (leases.map(\.fencingToken).max() ?? 0) + 1
            let lease = TaskLeaseRecord(
                projectID: projectID,
                taskID: taskID,
                agentActorID: agentActorID,
                endpointID: endpointID,
                runtimeBindingID: runtimeBindingID,
                fencingToken: nextFencingToken,
                issuedAt: now,
                expiresAt: now.addingTimeInterval(
                    max(30, duration)
                ),
                lastHeartbeatAt: now
            )
            try upsertTaskLease(lease)
            return lease
        }
    }

    public func renewTaskLease(
        id: UUID,
        duration: TimeInterval = 15 * 60,
        now: Date = Date()
    ) throws -> TaskLeaseRecord {
        try withTransaction {
            guard var lease = try fetchTaskLease(id: id),
                  lease.isActive(at: now) else {
                throw MuError.invalidTransition(
                    "The Task lease is no longer active."
                )
            }
            lease.lastHeartbeatAt = now
            lease.expiresAt = now.addingTimeInterval(
                max(30, duration)
            )
            try upsertTaskLease(lease)
            return lease
        }
    }

    public func releaseTaskLease(
        id: UUID,
        state: TaskLeaseState = .released,
        now: Date = Date()
    ) throws -> TaskLeaseRecord {
        try withTransaction {
            guard var lease = try fetchTaskLease(id: id) else {
                throw MuError.recordNotFound("Task lease \(id)")
            }
            if lease.state == .active {
                lease.state = state
                lease.releasedAt = now
                lease.lastHeartbeatAt = now
                try upsertTaskLease(lease)
            }
            return lease
        }
    }

    public func fetchProjectArtifacts(
        projectID: UUID? = nil,
        taskID: UUID? = nil
    ) throws -> [ProjectArtifactRecord] {
        try fetchRecords(
            kind: "project_artifact",
            taskID: taskID,
            as: ProjectArtifactRecord.self
        ).filter {
            projectID == nil || $0.projectID == projectID
        }
    }

    public func fetchProjectArtifact(
        id: UUID
    ) throws -> ProjectArtifactRecord? {
        try fetchRecord(
            kind: "project_artifact",
            id: id,
            as: ProjectArtifactRecord.self
        )
    }

    public func upsertProjectArtifact(
        _ artifact: ProjectArtifactRecord
    ) throws {
        try upsertRecord(
            kind: "project_artifact",
            id: artifact.id,
            taskID: artifact.taskID,
            sortAt: artifact.updatedAt,
            value: artifact
        )
    }

    public func fetchProjectReviews(
        projectID: UUID? = nil,
        taskID: UUID? = nil
    ) throws -> [ProjectReviewRecord] {
        try fetchRecords(
            kind: "project_review",
            taskID: taskID,
            as: ProjectReviewRecord.self
        ).filter {
            projectID == nil || $0.projectID == projectID
        }
    }

    public func upsertProjectReview(
        _ review: ProjectReviewRecord
    ) throws {
        try upsertRecord(
            kind: "project_review",
            id: review.id,
            taskID: review.taskID,
            sortAt: review.resolvedAt ?? review.createdAt,
            value: review
        )
    }

    public func fetchProjectApprovals(
        projectID: UUID? = nil,
        taskID: UUID? = nil
    ) throws -> [ProjectApprovalRecord] {
        try fetchRecords(
            kind: "project_approval",
            taskID: taskID,
            as: ProjectApprovalRecord.self
        ).filter {
            projectID == nil || $0.projectID == projectID
        }
    }

    public func upsertProjectApproval(
        _ approval: ProjectApprovalRecord
    ) throws {
        try upsertRecord(
            kind: "project_approval",
            id: approval.id,
            taskID: approval.taskID,
            sortAt: approval.resolvedAt ?? approval.createdAt,
            value: approval
        )
    }

    public func fetchProjectContextPacks(
        projectID: UUID,
        taskID: UUID? = nil
    ) throws -> [ProjectContextPackRecord] {
        if let taskID {
            return try fetchScopedContextRows(
                table: "context_packs",
                projectID: projectID,
                predicate: "task_id = ?",
                values: [taskID.uuidString],
                as: ProjectContextPackRecord.self
            )
        }
        return try fetchScopedContextRows(
            table: "context_packs",
            projectID: projectID,
            as: ProjectContextPackRecord.self
        )
    }

    public func fetchProjectContextPack(
        projectID: UUID,
        id: UUID
    ) throws -> ProjectContextPackRecord? {
        try fetchScopedContextRow(
            table: "context_packs",
            projectID: projectID,
            predicate: "id = ?",
            values: [id.uuidString],
            as: ProjectContextPackRecord.self
        )
    }

    public func insertProjectContextPack(
        _ contextPack: ProjectContextPackRecord
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard contextPack.contentSHA256
            == Data(contextPack.renderedMarkdown.utf8).muSHA256 else {
            throw MuError.invalidTransition(
                "Context Pack rendered receipt does not match its content."
            )
        }
        if contextPack.selectionPolicyVersion != nil {
            guard contextPack.actorID != nil,
                  contextPack.principalID != nil,
                  contextPack.runtimeEndpointID != nil,
                  contextPack.runtimeBindingID != nil,
                  contextPack.taskLeaseID != nil,
                  contextPack.leaseFencingToken != nil,
                  contextPack.tokenBudget.map({
                      (1_024...64_000).contains($0)
                  }) == true,
                  contextPack.contextRevision?.isEmpty == false,
                  contextPack.taskRevision?.isEmpty == false,
                  contextPack.policyRevision?.isEmpty == false,
                  contextPack.itemSetFingerprint?.isEmpty
                    == false,
                  contextPack.budgetEstimatorVersion?.isEmpty
                    == false,
                  contextPack.canonicalizationVersion
                    == ProjectContextValue
                    .canonicalizationVersion,
                  contextPack.includedContextRecordIDs
                    != nil,
                  contextPack.unresolvedContextConflictIDs
                    != nil,
                  contextPack.contextPackItemIDs?.isEmpty
                    == false,
                  contextPack.renderedArtifactURI?.isEmpty
                    == false else {
                throw MuError.invalidTransition(
                    "Governed Context Pack is missing an immutable binding, revision, policy, budget, or item receipt."
                )
            }
        }
        let statement = try prepare(
            """
            INSERT INTO context_packs(
                id,
                project_id,
                task_id,
                workspace_id,
                context_revision,
                policy_revision,
                content_sha256,
                sort_at,
                json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(contextPack.id.uuidString, at: 1, in: statement)
        bind(contextPack.projectID.uuidString, at: 2, in: statement)
        bind(contextPack.taskID.uuidString, at: 3, in: statement)
        bind(contextPack.workspaceID.uuidString, at: 4, in: statement)
        bind(
            contextPack.contextRevision ?? "legacy-context-v1",
            at: 5,
            in: statement
        )
        bind(
            contextPack.policyRevision ?? "legacy-policy-v1",
            at: 6,
            in: statement
        )
        bind(contextPack.contentSHA256, at: 7, in: statement)
        bind(Self.dateString(contextPack.createdAt), at: 8, in: statement)
        bind(try encode(contextPack), at: 9, in: statement)
        try stepDone(statement)
    }

    public func fetchRuntimeAdapterRegistrations()
        throws -> [RuntimeAdapterRegistration]
    {
        try fetchRecords(
            kind: "runtime_adapter_registration",
            as: RuntimeAdapterRegistration.self
        )
    }

    public func upsertRuntimeAdapterRegistration(
        _ registration: RuntimeAdapterRegistration
    ) throws {
        try upsertRecord(
            kind: "runtime_adapter_registration",
            id: registration.id,
            taskID: nil,
            sortAt: registration.probedAt,
            value: registration
        )
    }

    public func fetchAgents() throws -> [AgentIdentity] {
        try fetchRecords(kind: "agent_identity", as: AgentIdentity.self)
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }

    public func fetchAgent(id: UUID) throws -> AgentIdentity? {
        try fetchRecord(kind: "agent_identity", id: id, as: AgentIdentity.self)
    }

    public func upsertAgent(_ agent: AgentIdentity) throws {
        try upsertRecord(
            kind: "agent_identity",
            id: agent.id,
            taskID: nil,
            sortAt: agent.createdAt,
            value: agent
        )
    }

    public func deleteAgent(id: UUID) throws {
        try deleteRecord(kind: "agent_identity", id: id)
    }

    public func fetchRegistryTombstones() throws -> [RegistryTombstone] {
        try fetchRecords(kind: "registry_tombstone", as: RegistryTombstone.self)
    }

    public func upsertRegistryTombstone(_ tombstone: RegistryTombstone) throws {
        try upsertRecord(
            kind: "registry_tombstone",
            id: tombstone.id,
            taskID: nil,
            sortAt: tombstone.deletedAt,
            value: tombstone
        )
    }

    public func fetchChatEntries(taskID: UUID? = nil) throws -> [ChatEntry] {
        try fetchRecords(kind: "chat_entry", taskID: taskID, as: ChatEntry.self)
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func fetchChatEntry(id: UUID) throws -> ChatEntry? {
        try fetchRecord(kind: "chat_entry", id: id, as: ChatEntry.self)
    }

    public func insertChatEntry(_ entry: ChatEntry) throws {
        try insertImmutableRecord(
            kind: "chat_entry",
            id: entry.id,
            taskID: entry.taskID,
            sortAt: entry.createdAt,
            value: entry
        )
    }

    public func upsertChatEntry(_ entry: ChatEntry) throws {
        try upsertRecord(
            kind: "chat_entry",
            id: entry.id,
            taskID: entry.taskID,
            sortAt: entry.createdAt,
            value: entry
        )
    }

    public func deleteChatEntry(id: UUID) throws {
        try deleteRecord(kind: "chat_entry", id: id)
    }

    public func fetchImportedConversations(
        taskID: UUID? = nil
    ) throws -> [ImportedConversation] {
        lock.lock()
        defer { lock.unlock() }
        let sql = taskID == nil
            ? "SELECT json FROM imported_conversations ORDER BY sort_at DESC;"
            : """
              SELECT json FROM imported_conversations
              WHERE task_id = ?
              ORDER BY sort_at DESC;
              """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        if let taskID {
            bind(taskID.uuidString, at: 1, in: statement)
        }
        var values: [ImportedConversation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let pointer = sqlite3_column_text(statement, 0) else { continue }
            values.append(
                try decode(String(cString: pointer), as: ImportedConversation.self)
            )
        }
        return values
    }

    public func fetchImportedConversation(id: UUID) throws -> ImportedConversation? {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(
            "SELECT json FROM imported_conversations WHERE id = ?;"
        )
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, at: 1, in: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW,
              let pointer = sqlite3_column_text(statement, 0) else {
            throw lastError()
        }
        return try decode(
            String(cString: pointer),
            as: ImportedConversation.self
        )
    }

    public func upsertImportedConversation(
        _ conversation: ImportedConversation
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(
            """
            INSERT INTO imported_conversations(
                id,
                task_id,
                provider,
                provider_instance_key,
                native_session_id,
                canonical_workspace_path,
                sort_at,
                json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                task_id = excluded.task_id,
                provider = excluded.provider,
                provider_instance_key = excluded.provider_instance_key,
                native_session_id = excluded.native_session_id,
                canonical_workspace_path = excluded.canonical_workspace_path,
                sort_at = excluded.sort_at,
                json = excluded.json;
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(conversation.id.uuidString, at: 1, in: statement)
        bind(conversation.taskID.uuidString, at: 2, in: statement)
        bind(conversation.provider.rawValue, at: 3, in: statement)
        bind(conversation.providerInstanceKey, at: 4, in: statement)
        bind(conversation.nativeSessionID, at: 5, in: statement)
        bind(conversation.canonicalWorkspacePath, at: 6, in: statement)
        bind(
            Self.dateString(
                conversation.sourceUpdatedAt ?? conversation.lastRefreshedAt
            ),
            at: 7,
            in: statement
        )
        bind(try encode(conversation), at: 8, in: statement)
        try stepDone(statement)
    }

    public func deleteImportedConversation(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(
            "DELETE FROM imported_conversations WHERE id = ?;"
        )
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, at: 1, in: statement)
        try stepDone(statement)
    }

    public func fetchImportedConversationMessages(
        conversationID: UUID
    ) throws -> [ImportedConversationMessage] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(
            """
            SELECT json FROM imported_messages
            WHERE conversation_id = ?
            ORDER BY source_ordinal ASC;
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(conversationID.uuidString, at: 1, in: statement)
        var values: [ImportedConversationMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let pointer = sqlite3_column_text(statement, 0) else { continue }
            values.append(
                try decode(
                    String(cString: pointer),
                    as: ImportedConversationMessage.self
                )
            )
        }
        return values
    }

    public func fetchImportedConversationContextWindow(
        conversationID: UUID,
        recentLimit: Int,
        maximumRetainedTextBytes: Int
    ) throws -> (
        anchor: ImportedConversationMessage?,
        recent: [ImportedConversationMessage]
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard recentLimit > 0, maximumRetainedTextBytes > 0 else {
            return (nil, [])
        }
        let eligibility =
            """
            conversation_id = ?
            AND COALESCE(json_extract(json, '$.contextEligible'), 1) = 1
            AND length(COALESCE(json_extract(json, '$.text'), '')) > 0
            """

        func decodeBounded(
            _ pointer: UnsafePointer<UInt8>
        ) throws -> ImportedConversationMessage {
            var message = try decode(
                String(cString: pointer),
                as: ImportedConversationMessage.self
            )
            let data = Data(message.text.utf8)
            if data.count > maximumRetainedTextBytes {
                var count = maximumRetainedTextBytes
                while true {
                    if let prefix = String(
                        data: data.prefix(count),
                        encoding: .utf8
                    ) {
                        message.text = prefix + "…"
                        break
                    }
                    guard count > 0 else {
                        message.text = "…"
                        break
                    }
                    count -= 1
                }
            }
            return message
        }

        let anchorStatement = try prepare(
            """
            SELECT json FROM imported_messages
            WHERE \(eligibility)
              AND json_extract(json, '$.role') = 'user'
            ORDER BY source_ordinal ASC
            LIMIT 1;
            """
        )
        defer { sqlite3_finalize(anchorStatement) }
        bind(conversationID.uuidString, at: 1, in: anchorStatement)
        let anchor: ImportedConversationMessage?
        let anchorResult = sqlite3_step(anchorStatement)
        if anchorResult == SQLITE_ROW,
           let pointer = sqlite3_column_text(anchorStatement, 0) {
            anchor = try decodeBounded(pointer)
        } else if anchorResult == SQLITE_DONE {
            anchor = nil
        } else {
            throw lastError()
        }

        let recentStatement = try prepare(
            """
            SELECT json FROM imported_messages
            WHERE \(eligibility)
            ORDER BY sort_at DESC, source_ordinal DESC
            LIMIT ?;
            """
        )
        defer { sqlite3_finalize(recentStatement) }
        bind(conversationID.uuidString, at: 1, in: recentStatement)
        sqlite3_bind_int64(recentStatement, 2, Int64(recentLimit))
        var recent: [ImportedConversationMessage] = []
        while sqlite3_step(recentStatement) == SQLITE_ROW {
            guard let pointer = sqlite3_column_text(recentStatement, 0) else {
                continue
            }
            recent.append(try decodeBounded(pointer))
        }
        return (anchor, recent)
    }

    public func upsertImportedConversationMessage(
        _ message: ImportedConversationMessage
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(
            """
            INSERT INTO imported_messages(
                id,
                task_id,
                conversation_id,
                native_item_id,
                source_ordinal,
                sort_at,
                json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                task_id = excluded.task_id,
                conversation_id = excluded.conversation_id,
                native_item_id = excluded.native_item_id,
                source_ordinal = excluded.source_ordinal,
                sort_at = excluded.sort_at,
                json = excluded.json;
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(message.id.uuidString, at: 1, in: statement)
        bind(message.taskID.uuidString, at: 2, in: statement)
        bind(message.conversationID.uuidString, at: 3, in: statement)
        bind(message.nativeItemID, at: 4, in: statement)
        sqlite3_bind_int64(statement, 5, Int64(message.sourceOrdinal))
        bind(
            Self.dateString(message.createdAt ?? Date.distantPast),
            at: 6,
            in: statement
        )
        bind(try encode(message), at: 7, in: statement)
        try stepDone(statement)
    }

    public func deleteImportedConversationMessage(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(
            "DELETE FROM imported_messages WHERE id = ?;"
        )
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, at: 1, in: statement)
        try stepDone(statement)
    }

    public func fetchTaskContextSources(
        taskID: UUID
    ) throws -> [TaskContextSource] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(
            """
            SELECT json FROM task_context_sources
            WHERE task_id = ?
            ORDER BY sort_order ASC;
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(taskID.uuidString, at: 1, in: statement)
        var values: [TaskContextSource] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let pointer = sqlite3_column_text(statement, 0) else { continue }
            values.append(
                try decode(String(cString: pointer), as: TaskContextSource.self)
            )
        }
        return values
    }

    public func fetchEnabledTaskContextSources(
        taskID: UUID,
        limit: Int
    ) throws -> [TaskContextSource] {
        lock.lock()
        defer { lock.unlock() }
        guard limit > 0 else { return [] }
        let statement = try prepare(
            """
            SELECT json FROM task_context_sources
            WHERE task_id = ? AND enabled = 1
            ORDER BY sort_order DESC
            LIMIT ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(taskID.uuidString, at: 1, in: statement)
        sqlite3_bind_int64(statement, 2, Int64(limit))
        var values: [TaskContextSource] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let pointer = sqlite3_column_text(statement, 0) else {
                continue
            }
            values.append(
                try decode(
                    String(cString: pointer),
                    as: TaskContextSource.self
                )
            )
        }
        return values
    }

    public func upsertTaskContextSource(_ source: TaskContextSource) throws {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(
            """
            INSERT INTO task_context_sources(
                task_id,
                conversation_id,
                enabled,
                sort_order,
                json
            )
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(task_id, conversation_id) DO UPDATE SET
                enabled = excluded.enabled,
                sort_order = excluded.sort_order,
                json = excluded.json;
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(source.taskID.uuidString, at: 1, in: statement)
        bind(source.conversationID.uuidString, at: 2, in: statement)
        sqlite3_bind_int(statement, 3, source.enabled ? 1 : 0)
        sqlite3_bind_int64(statement, 4, Int64(source.sortOrder))
        bind(try encode(source), at: 5, in: statement)
        try stepDone(statement)
    }

    public func deleteTaskContextSource(
        taskID: UUID,
        conversationID: UUID
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(
            """
            DELETE FROM task_context_sources
            WHERE task_id = ? AND conversation_id = ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(taskID.uuidString, at: 1, in: statement)
        bind(conversationID.uuidString, at: 2, in: statement)
        try stepDone(statement)
    }

    public func fetchContextSnapshots(
        taskID: UUID? = nil,
        bindingID: UUID? = nil
    ) throws -> [ContextSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        let sql: String
        if taskID != nil {
            sql = """
                SELECT json FROM context_snapshots
                WHERE task_id = ?
                ORDER BY created_at DESC;
                """
        } else if bindingID != nil {
            sql = """
                SELECT json FROM context_snapshots
                WHERE target_binding_id = ?
                ORDER BY created_at DESC;
                """
        } else {
            sql = "SELECT json FROM context_snapshots ORDER BY created_at DESC;"
        }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        if let taskID {
            bind(taskID.uuidString, at: 1, in: statement)
        } else if let bindingID {
            bind(bindingID.uuidString, at: 1, in: statement)
        }
        var values: [ContextSnapshot] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let pointer = sqlite3_column_text(statement, 0) else { continue }
            values.append(
                try decode(String(cString: pointer), as: ContextSnapshot.self)
            )
        }
        return values
    }

    public func insertContextSnapshot(_ snapshot: ContextSnapshot) throws {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(
            """
            INSERT INTO context_snapshots(
                id,
                task_id,
                target_binding_id,
                selection_fingerprint,
                created_at,
                json
            )
            VALUES (?, ?, ?, ?, ?, ?);
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(snapshot.id.uuidString, at: 1, in: statement)
        bind(snapshot.taskID.uuidString, at: 2, in: statement)
        bind(snapshot.targetBindingID.uuidString, at: 3, in: statement)
        bind(snapshot.selectionFingerprint, at: 4, in: statement)
        bind(Self.dateString(snapshot.createdAt), at: 5, in: statement)
        bind(try encode(snapshot), at: 6, in: statement)
        try stepDone(statement)
    }

    public func redactContextSnapshotContent(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        let json: String? = try {
            let select = try prepare(
                "SELECT json FROM context_snapshots WHERE id = ?;"
            )
            defer { sqlite3_finalize(select) }
            bind(id.uuidString, at: 1, in: select)
            let result = sqlite3_step(select)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW,
                  let pointer = sqlite3_column_text(select, 0) else {
                throw lastError()
            }
            return String(cString: pointer)
        }()
        guard let json else { return }
        var snapshot = try decode(
            json,
            as: ContextSnapshot.self
        )
        guard !snapshot.content.isEmpty else { return }
        snapshot.content = ""
        let update = try prepare(
            "UPDATE context_snapshots SET json = ? WHERE id = ?;"
        )
        defer { sqlite3_finalize(update) }
        bind(try encode(snapshot), at: 1, in: update)
        bind(id.uuidString, at: 2, in: update)
        try stepDone(update)
    }

    // MARK: - Project Context Kernel

    public func fetchContextSources(
        projectID: UUID
    ) throws -> [ContextSourceRecord] {
        try fetchScopedContextRows(
            table: "context_sources",
            projectID: projectID,
            as: ContextSourceRecord.self
        )
    }

    public func fetchContextSourceAccessHeaders(
        projectID: UUID
    ) throws -> [ContextSourceAccessHeader] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(
            """
            SELECT
                id,
                source_actor_id,
                source_principal_id,
                access_policy_id,
                state
            FROM context_sources
            WHERE project_id = ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(projectID.uuidString, at: 1, in: statement)
        var headers: [ContextSourceAccessHeader] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = uuidColumn(statement, index: 0),
                  let actorID = uuidColumn(statement, index: 1),
                  let policyID = uuidColumn(statement, index: 3),
                  let stateText = stringColumn(
                    statement,
                    index: 4
                  ),
                  let state = ContextSourceState(
                    rawValue: stateText
                  ) else {
                throw MuError.database(
                    "Invalid Context Source access metadata."
                )
            }
            headers.append(
                ContextSourceAccessHeader(
                    id: id,
                    projectID: projectID,
                    sourceActorID: actorID,
                    sourcePrincipalID:
                        uuidColumn(statement, index: 2),
                    accessPolicyID: policyID,
                    state: state
                )
            )
        }
        return headers
    }

    public func fetchContextSource(
        projectID: UUID,
        id: UUID
    ) throws -> ContextSourceRecord? {
        try fetchScopedContextRow(
            table: "context_sources",
            projectID: projectID,
            predicate: "id = ?",
            values: [id.uuidString],
            as: ContextSourceRecord.self
        )
    }

    public func fetchContextSources(
        projectID: UUID,
        checksum: String
    ) throws -> [ContextSourceRecord] {
        try fetchScopedContextRows(
            table: "context_sources",
            projectID: projectID,
            predicate: "source_checksum = ?",
            values: [checksum],
            as: ContextSourceRecord.self
        )
    }

    public func insertContextSource(
        _ source: ContextSourceRecord,
        transition: ContextTransitionRecord
    ) throws {
        try withTransaction {
            try validateContextTransition(
                transition,
                projectID: source.projectID,
                aggregateKind: .source,
                aggregateID: source.id,
                fromState: nil,
                toState: source.state.rawValue,
                expectedRevision: 0,
                newRevision: source.revision,
                requiresHuman: false,
                taskID: nil
            )
            guard transition.actorID == source.sourceActorID,
                  transition.transitionKind == .created else {
                throw MuError.invalidTransition(
                    "Context Source creation actor does not match authenticated provenance."
                )
            }
            try insertContextSourceProjection(source)
            try insertContextTransition(transition)
        }
    }

    private func insertContextSourceProjection(
        _ source: ContextSourceRecord
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard source.state == .active,
              source.revision == 1,
              source.accessPolicyID != nil else {
            throw MuError.invalidTransition(
                "A Context Source must start active at revision 1."
            )
        }
        let statement = try prepare(
            """
            INSERT INTO context_sources(
                id,
                project_id,
                source_actor_id,
                source_principal_id,
                access_policy_id,
                source_checksum,
                external_ref,
                state,
                revision,
                sort_at,
                json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(source.id.uuidString, at: 1, in: statement)
        bind(source.projectID.uuidString, at: 2, in: statement)
        bind(source.sourceActorID.uuidString, at: 3, in: statement)
        bind(source.sourcePrincipalID?.uuidString, at: 4, in: statement)
        bind(source.accessPolicyID?.uuidString, at: 5, in: statement)
        bind(source.sourceChecksum, at: 6, in: statement)
        bind(source.externalRef, at: 7, in: statement)
        bind(source.state.rawValue, at: 8, in: statement)
        sqlite3_bind_int64(statement, 9, Int64(source.revision))
        bind(Self.dateString(source.importedAt), at: 10, in: statement)
        bind(try encode(source), at: 11, in: statement)
        try stepDone(statement)
    }

    /// Only lifecycle state may change. Provenance and raw-source identity are
    /// append-only once inserted.
    public func updateContextSourceState(
        _ source: ContextSourceRecord,
        transition: ContextTransitionRecord
    ) throws {
        try withTransaction {
            guard let existing = try fetchContextSource(
                projectID: source.projectID,
                id: source.id
            ) else {
                throw MuError.recordNotFound(
                    "Context source \(source.id)"
                )
            }
            try validateContextTransition(
                transition,
                projectID: source.projectID,
                aggregateKind: .source,
                aggregateID: source.id,
                fromState: existing.state.rawValue,
                toState: source.state.rawValue,
                expectedRevision: existing.revision,
                newRevision: source.revision,
                requiresHuman: true,
                taskID: nil
            )
            try updateContextSourceProjection(source)
            try insertContextTransition(transition)
        }
    }

    private func updateContextSourceProjection(
        _ source: ContextSourceRecord
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let existing = try fetchContextSource(
            projectID: source.projectID,
            id: source.id
        ) else {
            throw MuError.recordNotFound(
                "Context source \(source.id)"
            )
        }
        guard existing.state.allowsTransition(to: source.state),
              source.revision == existing.revision + 1 else {
            throw MuError.invalidTransition(
                "Invalid Context Source transition or stale revision."
            )
        }
        guard contextSourceImmutableFieldsMatch(
            existing,
            source
        ) else {
            throw MuError.invalidTransition(
                "Context Source provenance is immutable after import."
            )
        }
        let statement = try prepare(
            """
            UPDATE context_sources
            SET state = ?, revision = ?, json = ?
            WHERE project_id = ? AND id = ? AND revision = ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(source.state.rawValue, at: 1, in: statement)
        sqlite3_bind_int64(statement, 2, Int64(source.revision))
        bind(try encode(source), at: 3, in: statement)
        bind(source.projectID.uuidString, at: 4, in: statement)
        bind(source.id.uuidString, at: 5, in: statement)
        sqlite3_bind_int64(statement, 6, Int64(existing.revision))
        try stepDone(statement)
        guard sqlite3_changes(database) == 1 else {
            throw MuError.invalidTransition(
                "Context Source changed concurrently."
            )
        }
    }

    public func fetchContextRecords(
        projectID: UUID,
        status: ContextRecordStatus? = nil
    ) throws -> [ContextRecord] {
        guard let status else {
            return try fetchScopedContextRows(
                table: "context_records",
                projectID: projectID,
                as: ContextRecord.self
            )
        }
        return try fetchScopedContextRows(
            table: "context_records",
            projectID: projectID,
            predicate: "status = ?",
            values: [status.rawValue],
            as: ContextRecord.self
        )
    }

    public func fetchContextRecordAccessHeaders(
        projectID: UUID,
        statuses: Set<ContextRecordStatus>? = nil
    ) throws -> [ContextRecordAccessHeader] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(
            """
            SELECT
                id,
                source_id,
                access_policy_id,
                status,
                scope_task_id,
                sensitivity
            FROM context_records
            WHERE project_id = ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(projectID.uuidString, at: 1, in: statement)
        var headers: [ContextRecordAccessHeader] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = uuidColumn(statement, index: 0),
                  let sourceID = uuidColumn(statement, index: 1),
                  let policyID = uuidColumn(statement, index: 2),
                  let statusText = stringColumn(
                    statement,
                    index: 3
                  ),
                  let status = ContextRecordStatus(
                    rawValue: statusText
                  ),
                  let sensitivityText = stringColumn(
                    statement,
                    index: 5
                  ),
                  let sensitivity = ContextSensitivity(
                    rawValue: sensitivityText
                  ) else {
                throw MuError.database(
                    "Invalid Context Record access metadata."
                )
            }
            if let statuses, !statuses.contains(status) {
                continue
            }
            headers.append(
                ContextRecordAccessHeader(
                    id: id,
                    projectID: projectID,
                    sourceID: sourceID,
                    accessPolicyID: policyID,
                    status: status,
                    scopeTaskID:
                        uuidColumn(statement, index: 4),
                    sensitivity: sensitivity
                )
            )
        }
        return headers
    }

    public func fetchContextRecord(
        projectID: UUID,
        id: UUID
    ) throws -> ContextRecord? {
        try fetchScopedContextRow(
            table: "context_records",
            projectID: projectID,
            predicate: "id = ?",
            values: [id.uuidString],
            as: ContextRecord.self
        )
    }

    public func fetchContextRecord(
        projectID: UUID,
        sourceID: UUID,
        externalID: String
    ) throws -> ContextRecord? {
        try fetchScopedContextRow(
            table: "context_records",
            projectID: projectID,
            predicate: "source_id = ? AND external_id = ?",
            values: [sourceID.uuidString, externalID],
            as: ContextRecord.self
        )
    }

    public func fetchContextRecord(
        projectID: UUID,
        sourceID: UUID,
        immutableFingerprint: String
    ) throws -> ContextRecord? {
        try fetchScopedContextRow(
            table: "context_records",
            projectID: projectID,
            predicate:
                "source_id = ? AND immutable_fingerprint = ?",
            values: [
                sourceID.uuidString,
                immutableFingerprint
            ],
            as: ContextRecord.self
        )
    }

    public func insertContextRecord(
        _ record: ContextRecord,
        transition: ContextTransitionRecord
    ) throws {
        try withTransaction {
            try validateContextTransition(
                transition,
                projectID: record.projectID,
                aggregateKind: .record,
                aggregateID: record.id,
                fromState: nil,
                toState: record.status.rawValue,
                expectedRevision: 0,
                newRevision: record.revision,
                requiresHuman: false,
                taskID: record.scope.taskID
            )
            guard transition.actorID
                == record.createdByActorID,
            transition.transitionKind == .created else {
                throw MuError.invalidTransition(
                    "Context Record creation actor does not match its provenance."
                )
            }
            try insertContextRecordProjection(record)
            try insertContextTransition(transition)
        }
    }

    private func insertContextRecordProjection(
        _ record: ContextRecord
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try record.validateImmutableReceipt()
        guard record.status == .candidate,
              record.revision == 1,
              record.accessPolicyID != nil,
              record.statusUpdatedAt == record.createdAt,
              record.statusUpdatedByActorID == nil,
              record.supersededByRecordID == nil else {
            throw MuError.invalidTransition(
                "A Context Record must start as an unreviewed candidate at revision 1."
            )
        }
        guard try fetchContextSource(
            projectID: record.projectID,
            id: record.sourceID
        ) != nil else {
            throw MuError.invalidTransition(
                "Context Record source is outside the Project boundary."
            )
        }
        let statement = try prepare(
            """
            INSERT INTO context_records(
                id,
                project_id,
                source_id,
                external_id,
                content_sha256,
                immutable_fingerprint,
                kind,
                status,
                scope_task_id,
                sensitivity,
                access_policy_id,
                revision,
                subject,
                sort_at,
                json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(record.id.uuidString, at: 1, in: statement)
        bind(record.projectID.uuidString, at: 2, in: statement)
        bind(record.sourceID.uuidString, at: 3, in: statement)
        bind(record.externalID, at: 4, in: statement)
        bind(record.contentSHA256, at: 5, in: statement)
        bind(record.immutableFingerprint, at: 6, in: statement)
        bind(record.kind.rawValue, at: 7, in: statement)
        bind(record.status.rawValue, at: 8, in: statement)
        bind(record.scope.taskID?.uuidString, at: 9, in: statement)
        bind(record.sensitivity.rawValue, at: 10, in: statement)
        bind(record.accessPolicyID?.uuidString, at: 11, in: statement)
        sqlite3_bind_int64(statement, 12, Int64(record.revision))
        bind(record.subject, at: 13, in: statement)
        bind(Self.dateString(record.createdAt), at: 14, in: statement)
        bind(try encode(record), at: 15, in: statement)
        try stepDone(statement)
    }

    /// Payload, source, scope, authority, and attribution are immutable.
    /// The append-only transition receipt is written by the service in the
    /// same transaction as this CAS-protected current projection.
    public func updateContextRecordLifecycle(
        _ record: ContextRecord,
        transition: ContextTransitionRecord
    ) throws {
        try withTransaction {
            guard let existing = try fetchContextRecord(
                projectID: record.projectID,
                id: record.id
            ) else {
                throw MuError.recordNotFound(
                    "Context record \(record.id)"
                )
            }
            let requiresHuman = record.status != .disputed
            try validateContextTransition(
                transition,
                projectID: record.projectID,
                aggregateKind: .record,
                aggregateID: record.id,
                fromState: existing.status.rawValue,
                toState: record.status.rawValue,
                expectedRevision: existing.revision,
                newRevision: record.revision,
                requiresHuman: requiresHuman,
                taskID: record.scope.taskID
            )
            guard record.statusUpdatedByActorID
                == transition.actorID,
            record.statusUpdatedAt
                == transition.occurredAt else {
                throw MuError.invalidTransition(
                    "Context Record lifecycle metadata does not match its transition receipt."
                )
            }
            try updateContextRecordProjection(record)
            try insertContextTransition(transition)
        }
    }

    private func updateContextRecordProjection(
        _ record: ContextRecord
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let existing = try fetchContextRecord(
            projectID: record.projectID,
            id: record.id
        ) else {
            throw MuError.recordNotFound(
                "Context record \(record.id)"
            )
        }
        guard existing.status.allowsTransition(to: record.status),
              record.revision == existing.revision + 1 else {
            throw MuError.invalidTransition(
                "Invalid Context Record transition or stale revision."
            )
        }
        if record.status == .superseded {
            guard record.supersededByRecordID != nil else {
                throw MuError.invalidTransition(
                    "A superseded Context Record must name its replacement."
                )
            }
        } else if record.supersededByRecordID != nil {
            throw MuError.invalidTransition(
                "Only a superseded Context Record may point to a replacement."
            )
        }
        guard contextRecordImmutableFieldsMatch(
            existing,
            record
        ), (try? record.validateImmutableReceipt()) != nil else {
            throw MuError.invalidTransition(
                "Context Record payload and provenance are immutable."
            )
        }
        let statement = try prepare(
            """
            UPDATE context_records
            SET status = ?, revision = ?, json = ?
            WHERE project_id = ? AND id = ? AND revision = ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(record.status.rawValue, at: 1, in: statement)
        sqlite3_bind_int64(statement, 2, Int64(record.revision))
        bind(try encode(record), at: 3, in: statement)
        bind(record.projectID.uuidString, at: 4, in: statement)
        bind(record.id.uuidString, at: 5, in: statement)
        sqlite3_bind_int64(statement, 6, Int64(existing.revision))
        try stepDone(statement)
        guard sqlite3_changes(database) == 1 else {
            throw MuError.invalidTransition(
                "Context Record changed concurrently."
            )
        }
    }

    public func fetchContextRelations(
        projectID: UUID
    ) throws -> [ContextRelationRecord] {
        try fetchScopedContextRows(
            table: "context_relations",
            projectID: projectID,
            as: ContextRelationRecord.self
        )
    }

    public func insertContextRelation(
        _ relation: ContextRelationRecord
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard relation.fromRecordID != relation.toRecordID else {
            throw MuError.invalidTransition(
                "A Context Relation cannot reference itself."
            )
        }
        guard try fetchContextRecord(
            projectID: relation.projectID,
            id: relation.fromRecordID
        ) != nil,
        try fetchContextRecord(
            projectID: relation.projectID,
            id: relation.toRecordID
        ) != nil else {
            throw MuError.invalidTransition(
                "Context Relation records must belong to the same Project."
            )
        }
        if relation.relationType == .supersedes,
           try wouldCreateContextSupersessionCycle(relation) {
            throw MuError.invalidTransition(
                "A Context supersession relation cannot create a cycle."
            )
        }
        let statement = try prepare(
            """
            INSERT INTO context_relations(
                id,
                project_id,
                from_record_id,
                to_record_id,
                relation_type,
                sort_at,
                json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(relation.id.uuidString, at: 1, in: statement)
        bind(relation.projectID.uuidString, at: 2, in: statement)
        bind(relation.fromRecordID.uuidString, at: 3, in: statement)
        bind(relation.toRecordID.uuidString, at: 4, in: statement)
        bind(relation.relationType.rawValue, at: 5, in: statement)
        bind(Self.dateString(relation.createdAt), at: 6, in: statement)
        bind(try encode(relation), at: 7, in: statement)
        try stepDone(statement)
    }

    public func fetchContextConflicts(
        projectID: UUID,
        status: ContextConflictStatus? = nil
    ) throws -> [ContextConflictRecord] {
        guard let status else {
            return try fetchScopedContextRows(
                table: "context_conflicts",
                projectID: projectID,
                as: ContextConflictRecord.self
            )
        }
        return try fetchScopedContextRows(
            table: "context_conflicts",
            projectID: projectID,
            predicate: "status = ?",
            values: [status.rawValue],
            as: ContextConflictRecord.self
        )
    }

    public func fetchContextConflict(
        projectID: UUID,
        id: UUID
    ) throws -> ContextConflictRecord? {
        try fetchScopedContextRow(
            table: "context_conflicts",
            projectID: projectID,
            predicate: "id = ?",
            values: [id.uuidString],
            as: ContextConflictRecord.self
        )
    }

    public func insertContextConflict(
        _ conflict: ContextConflictRecord,
        transition: ContextTransitionRecord
    ) throws {
        try withTransaction {
            try validateContextTransition(
                transition,
                projectID: conflict.projectID,
                aggregateKind: .conflict,
                aggregateID: conflict.id,
                fromState: nil,
                toState: conflict.status.rawValue,
                expectedRevision: 0,
                newRevision: conflict.revision,
                requiresHuman: false,
                taskID: nil
            )
            guard transition.transitionKind == .created else {
                throw MuError.invalidTransition(
                    "A Context Conflict must begin with a creation receipt."
                )
            }
            try insertContextConflictProjection(conflict)
            try insertContextTransition(transition)
        }
    }

    private func insertContextConflictProjection(
        _ conflict: ContextConflictRecord
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard conflict.recordIDs.count >= 2,
              !conflict.subject.isEmpty,
              conflict.status == .unresolved,
              conflict.acceptedRecordIDs.isEmpty,
              conflict.resolvedByActorID == nil,
              conflict.resolvedAt == nil,
              conflict.revision == 1 else {
            throw MuError.invalidTransition(
                "A Context Conflict must start unresolved with at least two records."
            )
        }
        for recordID in conflict.recordIDs {
            guard try fetchContextRecord(
                projectID: conflict.projectID,
                id: recordID
            ) != nil else {
                throw MuError.invalidTransition(
                    "Context Conflict records must belong to the same Project."
                )
            }
        }
        let statement = try prepare(
            """
            INSERT INTO context_conflicts(
                id,
                project_id,
                subject,
                status,
                revision,
                sort_at,
                json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(conflict.id.uuidString, at: 1, in: statement)
        bind(conflict.projectID.uuidString, at: 2, in: statement)
        bind(conflict.subject, at: 3, in: statement)
        bind(conflict.status.rawValue, at: 4, in: statement)
        sqlite3_bind_int64(statement, 5, Int64(conflict.revision))
        bind(Self.dateString(conflict.createdAt), at: 6, in: statement)
        bind(try encode(conflict), at: 7, in: statement)
        try stepDone(statement)
        try replaceContextConflictRecordLinks(conflict)
    }

    public func updateContextConflictLifecycle(
        _ conflict: ContextConflictRecord,
        transition: ContextTransitionRecord
    ) throws {
        try withTransaction {
            guard let existing = try fetchContextConflict(
                projectID: conflict.projectID,
                id: conflict.id
            ) else {
                throw MuError.recordNotFound(
                    "Context conflict \(conflict.id)"
                )
            }
            try validateContextTransition(
                transition,
                projectID: conflict.projectID,
                aggregateKind: .conflict,
                aggregateID: conflict.id,
                fromState: existing.status.rawValue,
                toState: conflict.status.rawValue,
                expectedRevision: existing.revision,
                newRevision: conflict.revision,
                requiresHuman: true,
                taskID: nil
            )
            guard conflict.resolvedByActorID
                == transition.actorID,
            conflict.resolvedAt == transition.occurredAt else {
                throw MuError.invalidTransition(
                    "Context Conflict resolution metadata does not match its receipt."
                )
            }
            try updateContextConflictProjection(conflict)
            try insertContextTransition(transition)
        }
    }

    private func updateContextConflictProjection(
        _ conflict: ContextConflictRecord
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let existing = try fetchContextConflict(
            projectID: conflict.projectID,
            id: conflict.id
        ) else {
            throw MuError.recordNotFound(
                "Context conflict \(conflict.id)"
            )
        }
        guard existing.status.allowsTransition(to: conflict.status),
              conflict.revision == existing.revision + 1,
              conflict.resolvedByActorID != nil,
              conflict.resolvedAt != nil,
              conflict.resolutionNote?
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty == false else {
            throw MuError.invalidTransition(
                "Invalid Context Conflict resolution or stale revision."
            )
        }
        switch conflict.status {
        case .resolved:
            guard !conflict.acceptedRecordIDs.isEmpty else {
                throw MuError.invalidTransition(
                    "A resolved conflict must identify the accepted record."
                )
            }
        case .acceptedMultiple:
            guard conflict.acceptedRecordIDs.count >= 2 else {
                throw MuError.invalidTransition(
                    "Accepted-multiple resolution requires at least two records."
                )
            }
        case .unresolved:
            throw MuError.invalidTransition(
                "A resolved conflict cannot return to unresolved."
            )
        }
        guard contextConflictImmutableFieldsMatch(
            existing,
            conflict
        ),
              Set(conflict.acceptedRecordIDs)
                .isSubset(of: Set(conflict.recordIDs)) else {
            throw MuError.invalidTransition(
                "Context Conflict membership is immutable."
            )
        }
        let statement = try prepare(
            """
            UPDATE context_conflicts
            SET status = ?, revision = ?, json = ?
            WHERE project_id = ? AND id = ? AND revision = ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(conflict.status.rawValue, at: 1, in: statement)
        sqlite3_bind_int64(statement, 2, Int64(conflict.revision))
        bind(try encode(conflict), at: 3, in: statement)
        bind(conflict.projectID.uuidString, at: 4, in: statement)
        bind(conflict.id.uuidString, at: 5, in: statement)
        sqlite3_bind_int64(statement, 6, Int64(existing.revision))
        try stepDone(statement)
        guard sqlite3_changes(database) == 1 else {
            throw MuError.invalidTransition(
                "Context Conflict changed concurrently."
            )
        }
    }

    public func fetchContextAccessPolicies(
        projectID: UUID
    ) throws -> [ContextAccessPolicyRecord] {
        try fetchScopedContextRows(
            table: "context_access_policies",
            projectID: projectID,
            as: ContextAccessPolicyRecord.self
        )
    }

    public func fetchContextAccessPolicy(
        projectID: UUID,
        id: UUID
    ) throws -> ContextAccessPolicyRecord? {
        try fetchScopedContextRow(
            table: "context_access_policies",
            projectID: projectID,
            predicate: "id = ?",
            values: [id.uuidString],
            as: ContextAccessPolicyRecord.self
        )
    }

    public func fetchCurrentContextAccessPolicy(
        projectID: UUID,
        subjectKind: ContextPolicySubjectKind,
        subjectID: UUID
    ) throws -> ContextAccessPolicyRecord? {
        try fetchScopedContextRow(
            table: "context_access_policies",
            projectID: projectID,
            predicate: "subject_kind = ? AND subject_id = ?",
            values: [
                subjectKind.rawValue,
                subjectID.uuidString
            ],
            orderBy: "version DESC",
            as: ContextAccessPolicyRecord.self
        )
    }

    public func insertContextAccessPolicy(
        _ policy: ContextAccessPolicyRecord
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let policyActor = try fetchProjectActor(
            id: policy.createdByActorID
        ) else {
            throw MuError.recordNotFound(
                "Context policy Actor \(policy.createdByActorID)"
            )
        }
        try validateContextActor(
            projectID: policy.projectID,
            actorID: policy.createdByActorID,
            principalID: policyActor.principalID,
            requiresHuman: true,
            taskID: nil
        )
        try policy.validateImmutableReceipt()
        let expectedFamilyID = MuStableIdentity.uuid(
            namespace: "mu.context-policy-family",
            components: [
                policy.projectID.uuidString.lowercased(),
                policy.subjectKind.rawValue,
                policy.subjectID.uuidString.lowercased()
            ]
        )
        guard policy.familyID == expectedFamilyID else {
            throw MuError.invalidTransition(
                "Context Access Policy family does not match its subject."
            )
        }
        let current = try fetchCurrentContextAccessPolicy(
            projectID: policy.projectID,
            subjectKind: policy.subjectKind,
            subjectID: policy.subjectID
        )
        if let current {
            guard policy.version == current.version + 1,
                  policy.supersedesPolicyID == current.id else {
                throw MuError.invalidTransition(
                    "A new Context Access Policy must supersede the current version."
                )
            }
        } else {
            guard policy.version == 1,
                  policy.supersedesPolicyID == nil else {
                throw MuError.invalidTransition(
                    "The first Context Access Policy must be version 1."
                )
            }
        }
        var sourceID: UUID?
        var recordID: UUID?
        var packID: UUID?
        switch policy.subjectKind {
        case .source:
            guard try fetchContextSource(
                projectID: policy.projectID,
                id: policy.subjectID
            ) != nil else {
                throw MuError.invalidTransition(
                    "Context policy Source is outside the Project."
                )
            }
            sourceID = policy.subjectID
        case .record:
            guard try fetchContextRecord(
                projectID: policy.projectID,
                id: policy.subjectID
            ) != nil else {
                throw MuError.invalidTransition(
                    "Context policy Record is outside the Project."
                )
            }
            recordID = policy.subjectID
        case .artifact:
            guard let artifact = try fetchProjectArtifact(
                id: policy.subjectID
            ), artifact.projectID == policy.projectID else {
                throw MuError.invalidTransition(
                    "Context policy Artifact is outside the Project."
                )
            }
        case .pack:
            guard try fetchProjectContextPack(
                projectID: policy.projectID,
                id: policy.subjectID
            ) != nil else {
                throw MuError.invalidTransition(
                    "Context policy Pack is outside the Project."
                )
            }
            packID = policy.subjectID
        }
        let statement = try prepare(
            """
            INSERT INTO context_access_policies(
                id,
                project_id,
                subject_kind,
                subject_id,
                source_id,
                record_id,
                pack_id,
                family_id,
                version,
                supersedes_policy_id,
                policy_sha256,
                sort_at,
                json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(policy.id.uuidString, at: 1, in: statement)
        bind(policy.projectID.uuidString, at: 2, in: statement)
        bind(policy.subjectKind.rawValue, at: 3, in: statement)
        bind(policy.subjectID.uuidString, at: 4, in: statement)
        bind(sourceID?.uuidString, at: 5, in: statement)
        bind(recordID?.uuidString, at: 6, in: statement)
        bind(packID?.uuidString, at: 7, in: statement)
        bind(policy.familyID.uuidString, at: 8, in: statement)
        sqlite3_bind_int64(statement, 9, Int64(policy.version))
        bind(policy.supersedesPolicyID?.uuidString, at: 10, in: statement)
        bind(policy.policySHA256, at: 11, in: statement)
        bind(Self.dateString(policy.createdAt), at: 12, in: statement)
        bind(try encode(policy), at: 13, in: statement)
        try stepDone(statement)
    }

    public func fetchContextPackItems(
        projectID: UUID,
        packID: UUID
    ) throws -> [ContextPackItemRecord] {
        try fetchScopedContextRows(
            table: "context_pack_items",
            projectID: projectID,
            predicate: "pack_id = ?",
            values: [packID.uuidString],
            orderBy: "ordinal ASC",
            as: ContextPackItemRecord.self
        )
    }

    public func insertContextPackItem(
        _ item: ContextPackItemRecord
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let contextPack = try fetchProjectContextPack(
            projectID: item.projectID,
            id: item.packID
        ) else {
            throw MuError.invalidTransition(
                "Context Pack Item pack is outside the Project."
            )
        }
        guard !item.policyReceipts.isEmpty else {
            throw MuError.invalidTransition(
                "Context Pack Item must pin its effective policy versions."
            )
        }
        for receipt in item.policyReceipts {
            guard let policy = try fetchContextAccessPolicy(
                projectID: item.projectID,
                id: receipt.policyID
            ), policy.subjectKind == receipt.subjectKind,
            policy.subjectID == receipt.subjectID,
            policy.version == receipt.version,
            policy.policySHA256 == receipt.policySHA256,
            policy.sensitivity == receipt.sensitivity else {
                throw MuError.invalidTransition(
                    "Context Pack Item contains an invalid policy receipt."
                )
            }
        }
        guard item.policyReceipts.contains(where: {
            $0.subjectKind == .pack
                && $0.subjectID == item.packID
        }) else {
            throw MuError.invalidTransition(
                "Context Pack Item is missing its Pack policy receipt."
            )
        }
        var recordID: UUID?
        var conflictID: UUID?
        switch item.itemKind {
        case .record:
            guard let record = try fetchContextRecord(
                projectID: item.projectID,
                id: item.referencedID
            ), record.immutableFingerprint
                == item.referencedSHA256,
            item.policyReceipts.contains(where: {
                $0.subjectKind == .source
                    && $0.subjectID == record.sourceID
            }),
            item.policyReceipts.contains(where: {
                $0.subjectKind == .record
                    && $0.subjectID == record.id
            }) else {
                throw MuError.invalidTransition(
                    "Context Pack Record item is not fully policy-pinned."
                )
            }
            recordID = record.id
        case .artifact:
            guard let artifact = try fetchProjectArtifact(
                id: item.referencedID
            ), artifact.projectID == item.projectID,
            artifact.version == item.referencedVersion,
            artifact.sha256 == item.referencedSHA256,
            artifact.uri == item.referencedURI,
            item.policyReceipts.contains(where: {
                $0.subjectKind == .artifact
                    && $0.subjectID == artifact.id
            }) else {
                throw MuError.invalidTransition(
                    "Context Pack Artifact item is not fully version-pinned."
                )
            }
        case .conflict:
            guard let conflict = try fetchContextConflict(
                projectID: item.projectID,
                id: item.referencedID
            ) else {
                throw MuError.invalidTransition(
                    "Context Pack Conflict is outside the Project."
                )
            }
            let visibleRecordIDs = Set(
                item.policyReceipts.compactMap {
                    $0.subjectKind == .record
                        ? $0.subjectID
                        : nil
                }
            )
            guard visibleRecordIDs.count >= 2,
                  visibleRecordIDs.isSubset(
                    of: Set(conflict.recordIDs)
                  ) else {
                throw MuError.invalidTransition(
                    "Context Pack Conflict item must pin at least two visible member policies."
                )
            }
            for recordID in visibleRecordIDs {
                guard let record = try fetchContextRecord(
                    projectID: item.projectID,
                    id: recordID
                ), item.policyReceipts.contains(where: {
                    $0.subjectKind == .record
                        && $0.subjectID == record.id
                }), item.policyReceipts.contains(where: {
                    $0.subjectKind == .source
                        && $0.subjectID == record.sourceID
                }) else {
                    throw MuError.invalidTransition(
                        "Context Pack Conflict item is missing a visible member policy receipt."
                    )
                }
            }
            conflictID = item.referencedID
        case .projectFact:
            guard item.referencedID == contextPack.taskID,
                  item.referencedSHA256
                    == contextPack.taskRevision else {
                throw MuError.invalidTransition(
                    "Context Pack Project Fact does not match its Task revision."
                )
            }
        }
        let statement = try prepare(
            """
            INSERT INTO context_pack_items(
                id,
                project_id,
                pack_id,
                ordinal,
                item_kind,
                referenced_id,
                record_id,
                conflict_id,
                json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(item.id.uuidString, at: 1, in: statement)
        bind(item.projectID.uuidString, at: 2, in: statement)
        bind(item.packID.uuidString, at: 3, in: statement)
        sqlite3_bind_int64(statement, 4, Int64(item.ordinal))
        bind(item.itemKind.rawValue, at: 5, in: statement)
        bind(item.referencedID.uuidString, at: 6, in: statement)
        bind(recordID?.uuidString, at: 7, in: statement)
        bind(conflictID?.uuidString, at: 8, in: statement)
        bind(try encode(item), at: 9, in: statement)
        try stepDone(statement)
    }

    public func fetchContextImportJobs(
        projectID: UUID
    ) throws -> [ContextImportJobRecord] {
        try fetchScopedContextRows(
            table: "context_import_jobs",
            projectID: projectID,
            as: ContextImportJobRecord.self
        )
    }

    public func fetchContextImportJob(
        projectID: UUID,
        id: UUID
    ) throws -> ContextImportJobRecord? {
        try fetchScopedContextRow(
            table: "context_import_jobs",
            projectID: projectID,
            predicate: "id = ?",
            values: [id.uuidString],
            as: ContextImportJobRecord.self
        )
    }

    public func fetchContextImportJob(
        projectID: UUID,
        sourceActorID: UUID,
        idempotencyKey: String
    ) throws -> ContextImportJobRecord? {
        try fetchScopedContextRow(
            table: "context_import_jobs",
            projectID: projectID,
            predicate:
                "source_actor_id = ? AND idempotency_key = ?",
            values: [
                sourceActorID.uuidString,
                idempotencyKey
            ],
            as: ContextImportJobRecord.self
        )
    }

    public func upsertContextImportJob(
        _ job: ContextImportJobRecord,
        transition: ContextTransitionRecord
    ) throws {
        try withTransaction {
            let existing = try fetchContextImportJob(
                projectID: job.projectID,
                id: job.id
            )
            try validateContextTransition(
                transition,
                projectID: job.projectID,
                aggregateKind: .importJob,
                aggregateID: job.id,
                fromState: existing?.status.rawValue,
                toState: job.status.rawValue,
                expectedRevision: existing?.revision ?? 0,
                newRevision: job.revision,
                requiresHuman: false,
                taskID: nil
            )
            if existing == nil {
                guard transition.actorID
                    == job.sourceActorID,
                transition.transitionKind == .created else {
                    throw MuError.invalidTransition(
                        "Context Import creation actor must match the authenticated source Actor."
                    )
                }
            }
            guard job.updatedAt == transition.occurredAt else {
                throw MuError.invalidTransition(
                    "Context Import metadata does not match its transition receipt."
                )
            }
            try upsertContextImportJobProjection(job)
            try insertContextTransition(transition)
        }
    }

    private func upsertContextImportJobProjection(
        _ job: ContextImportJobRecord
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let keyed = try fetchContextImportJob(
            projectID: job.projectID,
            sourceActorID: job.sourceActorID,
            idempotencyKey: job.idempotencyKey
        )
        if let keyed, keyed.id != job.id {
            if keyed.bundleChecksum != job.bundleChecksum {
                throw MuError.invalidTransition(
                    "The authenticated Actor reused an idempotency key for different Context bytes."
                )
            }
            throw MuError.invalidTransition(
                "An idempotent replay must reuse its original Import Job."
            )
        }
        if let existing = try fetchContextImportJob(
            projectID: job.projectID,
            id: job.id
        ) {
            guard existing.status.allowsTransition(to: job.status),
                  job.revision == existing.revision + 1,
                  job.progress >= existing.progress else {
                throw MuError.invalidTransition(
                    "Invalid Context Import transition, progress regression, or stale revision."
                )
            }
            guard contextImportJobImmutableFieldsMatch(
                existing,
                job
            ) else {
                throw MuError.invalidTransition(
                    "Context Import Job identity is immutable."
                )
            }
        } else {
            guard job.status == .received,
                  job.progress == 0,
                  job.revision == 1,
                  job.sourceID == nil,
                  job.recordIDs.isEmpty,
                  job.completedAt == nil else {
                throw MuError.invalidTransition(
                    "A Context Import Job must start received at revision 1."
                )
            }
        }
        let statement = try prepare(
            """
            INSERT INTO context_import_jobs(
                id,
                project_id,
                source_actor_id,
                idempotency_key,
                status,
                progress,
                revision,
                sort_at,
                json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                status = excluded.status,
                progress = excluded.progress,
                revision = excluded.revision,
                sort_at = excluded.sort_at,
                json = excluded.json
            WHERE context_import_jobs.revision
                = excluded.revision - 1;
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(job.id.uuidString, at: 1, in: statement)
        bind(job.projectID.uuidString, at: 2, in: statement)
        bind(job.sourceActorID.uuidString, at: 3, in: statement)
        bind(job.idempotencyKey, at: 4, in: statement)
        bind(job.status.rawValue, at: 5, in: statement)
        sqlite3_bind_double(statement, 6, job.progress)
        sqlite3_bind_int64(statement, 7, Int64(job.revision))
        bind(Self.dateString(job.updatedAt), at: 8, in: statement)
        bind(try encode(job), at: 9, in: statement)
        try stepDone(statement)
        guard sqlite3_changes(database) == 1 else {
            throw MuError.invalidTransition(
                "Context Import Job changed concurrently."
            )
        }
    }

    public func fetchContextTransitions(
        projectID: UUID,
        aggregateKind: ContextTransitionAggregateKind? = nil,
        aggregateID: UUID? = nil
    ) throws -> [ContextTransitionRecord] {
        if let aggregateKind, let aggregateID {
            return try fetchScopedContextRows(
                table: "context_transitions",
                projectID: projectID,
                predicate:
                    "aggregate_kind = ? AND aggregate_id = ?",
                values: [
                    aggregateKind.rawValue,
                    aggregateID.uuidString
                ],
                orderBy: "new_revision ASC",
                as: ContextTransitionRecord.self
            )
        }
        return try fetchScopedContextRows(
            table: "context_transitions",
            projectID: projectID,
            orderBy: "occurred_at ASC",
            as: ContextTransitionRecord.self
        )
    }

    public func insertContextTransition(
        _ transition: ContextTransitionRecord
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard transition.newRevision
            == transition.expectedRevision + 1 else {
            throw MuError.invalidTransition(
                "Context transition revision is not contiguous."
            )
        }
        let previous = try fetchContextTransitions(
            projectID: transition.projectID,
            aggregateKind: transition.aggregateKind,
            aggregateID: transition.aggregateID
        ).last
        if let previous {
            guard previous.newRevision
                == transition.expectedRevision,
            previous.toState == transition.fromState else {
                throw MuError.invalidTransition(
                    "Context transition does not continue the aggregate history."
                )
            }
        } else {
            guard transition.expectedRevision == 0,
                  transition.fromState == nil,
                  transition.transitionKind == .created else {
                throw MuError.invalidTransition(
                    "A Context aggregate must begin with a creation receipt."
                )
            }
        }
        let statement = try prepare(
            """
            INSERT INTO context_transitions(
                id,
                project_id,
                aggregate_kind,
                aggregate_id,
                from_state,
                to_state,
                expected_revision,
                new_revision,
                occurred_at,
                json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(transition.id.uuidString, at: 1, in: statement)
        bind(transition.projectID.uuidString, at: 2, in: statement)
        bind(transition.aggregateKind.rawValue, at: 3, in: statement)
        bind(transition.aggregateID.uuidString, at: 4, in: statement)
        bind(transition.fromState, at: 5, in: statement)
        bind(transition.toState, at: 6, in: statement)
        sqlite3_bind_int64(
            statement,
            7,
            Int64(transition.expectedRevision)
        )
        sqlite3_bind_int64(
            statement,
            8,
            Int64(transition.newRevision)
        )
        bind(Self.dateString(transition.occurredAt), at: 9, in: statement)
        bind(try encode(transition), at: 10, in: statement)
        try stepDone(statement)
    }

    public func fetchContextDeliveries(
        projectID: UUID,
        taskID: UUID? = nil
    ) throws -> [ContextDeliveryReceipt] {
        if let taskID {
            return try fetchScopedContextRows(
                table: "context_deliveries",
                projectID: projectID,
                predicate: "task_id = ?",
                values: [taskID.uuidString],
                orderBy: "prepared_at DESC",
                as: ContextDeliveryReceipt.self
            )
        }
        return try fetchScopedContextRows(
            table: "context_deliveries",
            projectID: projectID,
            orderBy: "prepared_at DESC",
            as: ContextDeliveryReceipt.self
        )
    }

    public func insertContextDelivery(
        _ receipt: ContextDeliveryReceipt
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let pack = try fetchProjectContextPack(
            projectID: receipt.projectID,
            id: receipt.contextPackID
        ), pack.taskID == receipt.taskID,
        pack.workspaceID == receipt.workspaceID,
        pack.actorID == receipt.actorID,
        pack.principalID == receipt.principalID,
        pack.runtimeEndpointID == receipt.endpointID,
        pack.runtimeBindingID == receipt.runtimeBindingID,
        pack.taskLeaseID == receipt.taskLeaseID,
        pack.leaseFencingToken == receipt.leaseFencingToken,
        pack.contextRevision == receipt.contextRevision,
        pack.policyRevision == receipt.policyRevision,
        pack.contentSHA256 == receipt.packContentSHA256 else {
            throw MuError.invalidTransition(
                "Context Delivery does not match its immutable Pack."
            )
        }
        guard let binding = try fetchRuntimeSessionBinding(
            id: receipt.runtimeBindingID
        ), binding.projectID == receipt.projectID,
        binding.taskID == receipt.taskID,
        binding.contextPackID == receipt.contextPackID,
        binding.runID == receipt.runID,
        binding.endpointID == receipt.endpointID,
        binding.actorID == receipt.actorID,
        binding.principalID == receipt.principalID,
        binding.workspaceID == receipt.workspaceID,
        binding.taskLeaseID == receipt.taskLeaseID,
        let run = try fetchRun(id: receipt.runID),
        run.projectID == receipt.projectID,
        run.taskID == receipt.taskID,
        run.contextPackID == receipt.contextPackID,
        run.endpointID == receipt.endpointID,
        run.actorID == receipt.actorID,
        run.principalID == receipt.principalID,
        run.workspaceID == receipt.workspaceID,
        run.taskLeaseID == receipt.taskLeaseID else {
            throw MuError.invalidTransition(
                "Context Delivery Runtime binding is outside the Pack boundary."
            )
        }
        switch receipt.status {
        case .prepared:
            guard receipt.completedAt == nil,
                  receipt.adapterReceiptSHA256 == nil,
                  receipt.failureCode == nil else {
                throw MuError.invalidTransition(
                    "A prepared Context Delivery cannot contain a completion receipt."
                )
            }
        case .delivered:
            guard receipt.completedAt != nil,
                  receipt.adapterReceiptSHA256 != nil,
                  receipt.failureCode == nil else {
                throw MuError.invalidTransition(
                    "A delivered Context Pack requires an adapter receipt."
                )
            }
        case .failed:
            guard receipt.completedAt != nil,
                  receipt.failureCode != nil else {
                throw MuError.invalidTransition(
                    "A failed Context Delivery requires a failure code."
                )
            }
        }
        let statement = try prepare(
            """
            INSERT INTO context_deliveries(
                id,
                project_id,
                task_id,
                context_pack_id,
                runtime_binding_id,
                run_id,
                status,
                prepared_at,
                json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(receipt.id.uuidString, at: 1, in: statement)
        bind(receipt.projectID.uuidString, at: 2, in: statement)
        bind(receipt.taskID.uuidString, at: 3, in: statement)
        bind(receipt.contextPackID.uuidString, at: 4, in: statement)
        bind(receipt.runtimeBindingID.uuidString, at: 5, in: statement)
        bind(receipt.runID.uuidString, at: 6, in: statement)
        bind(receipt.status.rawValue, at: 7, in: statement)
        bind(Self.dateString(receipt.preparedAt), at: 8, in: statement)
        bind(try encode(receipt), at: 9, in: statement)
        try stepDone(statement)
    }

    public func fetchRuns(taskID: UUID? = nil) throws -> [RunRecord] {
        try fetchRecords(kind: "run", taskID: taskID, as: RunRecord.self)
    }

    public func fetchRun(id: UUID) throws -> RunRecord? {
        try fetchRecord(kind: "run", id: id, as: RunRecord.self)
    }

    public func upsertRun(_ run: RunRecord) throws {
        try upsertRecord(kind: "run", id: run.id, taskID: run.taskID, sortAt: run.updatedAt, value: run)
    }

    public func fetchRuntimeSessionBindings(
        taskID: UUID? = nil
    ) throws -> [RuntimeSessionBinding] {
        try fetchRecords(
            kind: "runtime_session_binding",
            taskID: taskID,
            as: RuntimeSessionBinding.self
        )
    }

    public func fetchRuntimeSessionBinding(id: UUID) throws -> RuntimeSessionBinding? {
        try fetchRecord(
            kind: "runtime_session_binding",
            id: id,
            as: RuntimeSessionBinding.self
        )
    }

    public func upsertRuntimeSessionBinding(_ binding: RuntimeSessionBinding) throws {
        try upsertRecord(
            kind: "runtime_session_binding",
            id: binding.id,
            taskID: binding.taskID,
            sortAt: binding.updatedAt,
            value: binding
        )
    }

    public func fetchRuntimeInteractions(
        taskID: UUID? = nil
    ) throws -> [RuntimeInteractionRequest] {
        try fetchRecords(
            kind: "runtime_interaction",
            taskID: taskID,
            as: RuntimeInteractionRequest.self
        )
    }

    public func fetchRuntimeInteraction(id: UUID) throws -> RuntimeInteractionRequest? {
        try fetchRecord(
            kind: "runtime_interaction",
            id: id,
            as: RuntimeInteractionRequest.self
        )
    }

    public func upsertRuntimeInteraction(_ request: RuntimeInteractionRequest) throws {
        try upsertRecord(
            kind: "runtime_interaction",
            id: request.id,
            taskID: request.taskID,
            sortAt: request.resolvedAt ?? request.createdAt,
            value: request
        )
    }

    public func fetchRuntimeArtifacts(
        taskID: UUID? = nil
    ) throws -> [RuntimeArtifactRecord] {
        try fetchRecords(
            kind: "runtime_artifact",
            taskID: taskID,
            as: RuntimeArtifactRecord.self
        )
    }

    public func upsertRuntimeArtifact(_ artifact: RuntimeArtifactRecord) throws {
        try upsertRecord(
            kind: "runtime_artifact",
            id: artifact.id,
            taskID: artifact.taskID,
            sortAt: artifact.modifiedAt,
            value: artifact
        )
    }

    public func fetchEndpoints() throws -> [RuntimeEndpoint] {
        try fetchRecords(kind: "endpoint", as: RuntimeEndpoint.self)
    }

    public func fetchEndpoint(id: UUID) throws -> RuntimeEndpoint? {
        try fetchRecord(kind: "endpoint", id: id, as: RuntimeEndpoint.self)
    }

    public func fetchRegisteredEndpoints() throws -> [RuntimeEndpoint] {
        lock.lock()
        defer { lock.unlock() }
        let removedIDs = Set(
            try fetchRegistryTombstones()
                .filter { $0.entityKind == .runtimeEndpoint }
                .map(\.id)
        )
        return try fetchEndpoints().filter { !removedIDs.contains($0.id) }
    }

    public func fetchRegisteredEndpoint(id: UUID) throws -> RuntimeEndpoint? {
        lock.lock()
        defer { lock.unlock() }
        let wasRemoved = try fetchRegistryTombstones().contains {
            $0.id == id && $0.entityKind == .runtimeEndpoint
        }
        guard !wasRemoved else { return nil }
        return try fetchEndpoint(id: id)
    }

    public func upsertEndpoint(_ endpoint: RuntimeEndpoint) throws {
        try upsertRecord(
            kind: "endpoint",
            id: endpoint.id,
            taskID: nil,
            sortAt: endpoint.lastProbedAt,
            value: endpoint
        )
    }

    public func insertCheckpoint(_ checkpoint: CheckpointRecord) throws {
        try insertImmutableRecord(
            kind: "checkpoint",
            id: checkpoint.id,
            taskID: checkpoint.taskID,
            sortAt: checkpoint.createdAt,
            value: checkpoint
        )
    }

    public func fetchCheckpoints(taskID: UUID? = nil) throws -> [CheckpointRecord] {
        try fetchRecords(kind: "checkpoint", taskID: taskID, as: CheckpointRecord.self)
    }

    public func fetchCheckpoint(id: UUID) throws -> CheckpointRecord? {
        try fetchRecord(kind: "checkpoint", id: id, as: CheckpointRecord.self)
    }

    public func upsertHandoff(_ handoff: HandoffRecord) throws {
        try upsertRecord(
            kind: "handoff",
            id: handoff.id,
            taskID: handoff.taskID,
            sortAt: handoff.resolvedAt ?? handoff.createdAt,
            value: handoff
        )
    }

    public func fetchHandoffs(taskID: UUID? = nil) throws -> [HandoffRecord] {
        try fetchRecords(kind: "handoff", taskID: taskID, as: HandoffRecord.self)
    }

    @discardableResult
    public func appendEvent(_ event: LedgerEvent) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }

        let data = try MuCoding.makeEncoder().encode(event)
        guard let json = String(data: data, encoding: .utf8) else {
            throw MuError.database("Could not encode ledger event.")
        }
        let sql =
            """
            INSERT INTO ledger(event_id, task_id, run_id, type, occurred_at, json)
            VALUES (?, ?, ?, ?, ?, ?);
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        bind(event.id.uuidString, at: 1, in: statement)
        bind(event.taskID?.uuidString, at: 2, in: statement)
        bind(event.runID?.uuidString, at: 3, in: statement)
        bind(event.type, at: 4, in: statement)
        bind(Self.dateString(event.occurredAt), at: 5, in: statement)
        bind(json, at: 6, in: statement)
        try stepDone(statement)
        return sqlite3_last_insert_rowid(database)
    }

    public func fetchEvents(taskID: UUID? = nil, limit: Int = 500) throws -> [LedgerEvent] {
        lock.lock()
        defer { lock.unlock() }

        let sql: String
        if taskID == nil {
            sql = "SELECT sequence, json FROM ledger ORDER BY sequence DESC LIMIT ?;"
        } else {
            sql = "SELECT sequence, json FROM ledger WHERE task_id = ? ORDER BY sequence DESC LIMIT ?;"
        }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        if let taskID {
            bind(taskID.uuidString, at: 1, in: statement)
            sqlite3_bind_int(statement, 2, Int32(limit))
        } else {
            sqlite3_bind_int(statement, 1, Int32(limit))
        }

        var events: [LedgerEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let sequence = sqlite3_column_int64(statement, 0)
            guard let pointer = sqlite3_column_text(statement, 1) else { continue }
            let json = String(cString: pointer)
            guard let data = json.data(using: .utf8) else { continue }
            var event = try MuCoding.makeDecoder().decode(LedgerEvent.self, from: data)
            event.sequence = sequence
            events.append(event)
        }
        return events
    }

    public func ledgerEventCount() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("SELECT COUNT(*) FROM ledger;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw lastError()
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func fetchScopedContextRows<T: Decodable>(
        table: String,
        projectID: UUID,
        predicate: String? = nil,
        values: [String] = [],
        orderBy: String = "sort_at DESC",
        as type: T.Type
    ) throws -> [T] {
        lock.lock()
        defer { lock.unlock() }
        let whereClause = predicate.map {
            " AND \($0)"
        } ?? ""
        let statement = try prepare(
            """
            SELECT json
            FROM \(table)
            WHERE project_id = ?\(whereClause)
            ORDER BY \(orderBy);
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(projectID.uuidString, at: 1, in: statement)
        for (offset, value) in values.enumerated() {
            bind(
                value,
                at: Int32(offset + 2),
                in: statement
            )
        }
        var rows: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let pointer = sqlite3_column_text(
                statement,
                0
            ) else {
                continue
            }
            rows.append(
                try decode(
                    String(cString: pointer),
                    as: type
                )
            )
        }
        return rows
    }

    private func fetchScopedContextRow<T: Decodable>(
        table: String,
        projectID: UUID,
        predicate: String,
        values: [String],
        orderBy: String = "sort_at DESC",
        as type: T.Type
    ) throws -> T? {
        try fetchScopedContextRows(
            table: table,
            projectID: projectID,
            predicate: predicate,
            values: values,
            orderBy: orderBy,
            as: type
        ).first
    }

    private func replaceContextConflictRecordLinks(
        _ conflict: ContextConflictRecord
    ) throws {
        let delete = try prepare(
            """
            DELETE FROM context_conflict_records
            WHERE project_id = ? AND conflict_id = ?;
            """
        )
        defer { sqlite3_finalize(delete) }
        bind(conflict.projectID.uuidString, at: 1, in: delete)
        bind(conflict.id.uuidString, at: 2, in: delete)
        try stepDone(delete)
        for recordID in conflict.recordIDs {
            let insert = try prepare(
                """
                INSERT INTO context_conflict_records(
                    project_id,
                    conflict_id,
                    record_id
                )
                VALUES (?, ?, ?);
                """
            )
            bind(conflict.projectID.uuidString, at: 1, in: insert)
            bind(conflict.id.uuidString, at: 2, in: insert)
            bind(recordID.uuidString, at: 3, in: insert)
            do {
                try stepDone(insert)
                sqlite3_finalize(insert)
            } catch {
                sqlite3_finalize(insert)
                throw error
            }
        }
    }

    private func wouldCreateContextSupersessionCycle(
        _ candidate: ContextRelationRecord
    ) throws -> Bool {
        let relations = try fetchContextRelations(
            projectID: candidate.projectID
        ).filter {
            $0.relationType == .supersedes
        }
        var adjacency: [UUID: Set<UUID>] = [:]
        for relation in relations {
            adjacency[relation.fromRecordID, default: []]
                .insert(relation.toRecordID)
        }
        adjacency[candidate.fromRecordID, default: []]
            .insert(candidate.toRecordID)
        var visited: Set<UUID> = []
        var pending = [candidate.toRecordID]
        while let current = pending.popLast() {
            if current == candidate.fromRecordID {
                return true
            }
            guard visited.insert(current).inserted else {
                continue
            }
            pending.append(contentsOf: adjacency[current] ?? [])
        }
        return false
    }

    private func validateContextTransition(
        _ transition: ContextTransitionRecord,
        projectID: UUID,
        aggregateKind: ContextTransitionAggregateKind,
        aggregateID: UUID,
        fromState: String?,
        toState: String,
        expectedRevision: Int,
        newRevision: Int,
        requiresHuman: Bool,
        taskID: UUID?
    ) throws {
        guard transition.projectID == projectID,
              transition.aggregateKind == aggregateKind,
              transition.aggregateID == aggregateID,
              transition.fromState == fromState,
              transition.toState == toState,
              transition.expectedRevision == expectedRevision,
              transition.newRevision == newRevision else {
            throw MuError.invalidTransition(
                "Context transition does not match its aggregate projection."
            )
        }
        try validateContextActor(
            projectID: projectID,
            actorID: transition.actorID,
            principalID: transition.principalID,
            requiresHuman: requiresHuman,
            taskID: taskID
        )
    }

    private func contextSourceImmutableFieldsMatch(
        _ lhs: ContextSourceRecord,
        _ rhs: ContextSourceRecord
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.projectID == rhs.projectID
            && lhs.sourceType == rhs.sourceType
            && lhs.sourceActorID == rhs.sourceActorID
            && lhs.sourcePrincipalID == rhs.sourcePrincipalID
            && lhs.runtimeEndpointID == rhs.runtimeEndpointID
            && lhs.runtimeProvider == rhs.runtimeProvider
            && lhs.runtimeSessionID == rhs.runtimeSessionID
            && lhs.externalRef == rhs.externalRef
            && lhs.sourceChecksum == rhs.sourceChecksum
            && lhs.checksumAlgorithm == rhs.checksumAlgorithm
            && lhs.sourceSchemaVersion == rhs.sourceSchemaVersion
            && lhs.rawArtifactURI == rhs.rawArtifactURI
            && lhs.accessPolicyID == rhs.accessPolicyID
            && datesMatch(
                lhs.originalTimestamp,
                rhs.originalTimestamp
            )
            && datesMatch(lhs.importedAt, rhs.importedAt)
    }

    private func contextRecordImmutableFieldsMatch(
        _ lhs: ContextRecord,
        _ rhs: ContextRecord
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.projectID == rhs.projectID
            && lhs.sourceID == rhs.sourceID
            && lhs.externalID == rhs.externalID
            && lhs.kind == rhs.kind
            && lhs.subject == rhs.subject
            && lhs.value == rhs.value
            && lhs.contentSHA256 == rhs.contentSHA256
            && lhs.immutableFingerprint
                == rhs.immutableFingerprint
            && lhs.canonicalizationVersion
                == rhs.canonicalizationVersion
            && lhs.authority == rhs.authority
            && lhs.scope == rhs.scope
            && lhs.sensitivity == rhs.sensitivity
            && lhs.accessPolicyID == rhs.accessPolicyID
            && lhs.confidence == rhs.confidence
            && datesMatch(lhs.validFrom, rhs.validFrom)
            && datesMatch(lhs.validUntil, rhs.validUntil)
            && lhs.createdByActorID == rhs.createdByActorID
            && datesMatch(lhs.createdAt, rhs.createdAt)
    }

    private func contextConflictImmutableFieldsMatch(
        _ lhs: ContextConflictRecord,
        _ rhs: ContextConflictRecord
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.projectID == rhs.projectID
            && lhs.subject == rhs.subject
            && lhs.recordIDs == rhs.recordIDs
            && lhs.conflictType == rhs.conflictType
            && datesMatch(lhs.createdAt, rhs.createdAt)
    }

    private func contextImportJobImmutableFieldsMatch(
        _ lhs: ContextImportJobRecord,
        _ rhs: ContextImportJobRecord
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.projectID == rhs.projectID
            && lhs.sourceActorID == rhs.sourceActorID
            && lhs.sourcePrincipalID == rhs.sourcePrincipalID
            && lhs.runtimeProvider == rhs.runtimeProvider
            && lhs.runtimeSessionID == rhs.runtimeSessionID
            && lhs.externalBundleID == rhs.externalBundleID
            && lhs.bundleChecksum == rhs.bundleChecksum
            && lhs.idempotencyKey == rhs.idempotencyKey
            && datesMatch(lhs.createdAt, rhs.createdAt)
    }

    private func datesMatch(
        _ lhs: Date?,
        _ rhs: Date?
    ) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            true
        case (.some(let lhs), .some(let rhs)):
            Self.dateString(lhs) == Self.dateString(rhs)
        default:
            false
        }
    }

    private func validateContextActor(
        projectID: UUID,
        actorID: UUID,
        principalID: UUID,
        requiresHuman: Bool,
        taskID: UUID?
    ) throws {
        guard let actor = try fetchProjectActor(id: actorID),
              actor.status == .active,
              actor.principalID == principalID,
              let principal = try fetchPrincipal(id: principalID),
              principal.status == .active,
              let membership = try fetchProjectMemberships(
                projectID: projectID
              ).first(where: {
                  $0.actorID == actorID && $0.isActive()
              }) else {
            throw MuError.invalidTransition(
                "Context transition Actor is not an active Project member in scope."
            )
        }
        let isInTaskScope = membership.taskScope.isEmpty
            || (taskID.map {
                membership.taskScope.contains($0)
            } ?? true)
        guard isInTaskScope else {
            throw MuError.invalidTransition(
                "Context transition Actor is outside the Membership Task scope."
            )
        }
        if requiresHuman {
            guard actor.kind == .human else {
                throw MuError.invalidTransition(
                    "An Agent may propose or dispute Context but cannot review canonical state."
                )
            }
        } else if actor.kind == .agent {
            let canPropose = try fetchDelegations(
                projectID: projectID,
                agentActorID: actorID,
                taskID: taskID
            ).contains {
                $0.principalID == principalID
                    && $0.isActive()
                    && $0.permissions.contains(.proposeContext)
            }
            guard canPropose else {
                throw MuError.invalidTransition(
                    "Agent lacks an active context.propose delegation."
                )
            }
        }
    }

    private func upsertVersionedRecord<T: CollaborationVersionedRecord>(
        kind: String,
        id: UUID,
        sortAt: Date,
        value: T,
        expectedVersion: Int64
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        let existingStatement = try prepare(
            "SELECT json FROM records WHERE kind = ? AND id = ? COLLATE NOCASE;"
        )
        defer { sqlite3_finalize(existingStatement) }
        bind(kind, at: 1, in: existingStatement)
        bind(id.uuidString, at: 2, in: existingStatement)
        let result = sqlite3_step(existingStatement)
        guard result == SQLITE_ROW,
              let jsonPointer = sqlite3_column_text(existingStatement, 0) else {
            if result != SQLITE_DONE {
                throw lastError()
            }
            guard expectedVersion == 0, value.version == 1 else {
                throw MuError.invalidTransition(
                    "Cannot create \(kind) \(id) with expected version \(expectedVersion)."
                )
            }
            try insertVersionedRecord(
                kind: kind,
                id: id,
                sortAt: sortAt,
                value: value
            )
            return
        }

        let existing = try decode(
            String(cString: jsonPointer),
            as: T.self
        )
        guard existing.version == expectedVersion else {
            throw MuError.invalidTransition(
                "Stale \(kind) \(id): expected version \(expectedVersion), "
                    + "found \(existing.version)."
            )
        }
        guard value.version == expectedVersion + 1 else {
            throw MuError.invalidTransition(
                "\(kind) \(id) must advance to version \(expectedVersion + 1)."
            )
        }

        let json = try encode(value)
        let statement = try prepare(
            """
            UPDATE records
            SET sort_at = ?, json = ?
            WHERE kind = ? AND id = ? COLLATE NOCASE;
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(Self.dateString(sortAt), at: 1, in: statement)
        bind(json, at: 2, in: statement)
        bind(kind, at: 3, in: statement)
        bind(id.uuidString, at: 4, in: statement)
        try stepDone(statement)
        guard sqlite3_changes(database) == 1 else {
            throw MuError.invalidTransition(
                "Concurrent update rejected for \(kind) \(id)."
            )
        }
    }

    private func insertVersionedRecord<T: CollaborationVersionedRecord>(
        kind: String,
        id: UUID,
        sortAt: Date,
        value: T
    ) throws {
        let statement = try prepare(
            "INSERT INTO records(kind, id, task_id, sort_at, json) VALUES (?, ?, NULL, ?, ?);"
        )
        defer { sqlite3_finalize(statement) }
        bind(kind, at: 1, in: statement)
        bind(id.uuidString, at: 2, in: statement)
        bind(Self.dateString(sortAt), at: 3, in: statement)
        bind(try encode(value), at: 4, in: statement)
        try stepDone(statement)
    }

    private func upsertRecord<T: Encodable>(
        kind: String,
        id: UUID,
        taskID: UUID?,
        sortAt: Date,
        value: T
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let json = try encode(value)
        let sql =
            """
            INSERT INTO records(kind, id, task_id, sort_at, json)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(kind, id) DO UPDATE SET
                task_id = excluded.task_id,
                sort_at = excluded.sort_at,
                json = excluded.json;
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(kind, at: 1, in: statement)
        bind(id.uuidString, at: 2, in: statement)
        bind(taskID?.uuidString, at: 3, in: statement)
        bind(Self.dateString(sortAt), at: 4, in: statement)
        bind(json, at: 5, in: statement)
        try stepDone(statement)
    }

    private func insertImmutableRecord<T: Encodable>(
        kind: String,
        id: UUID,
        taskID: UUID?,
        sortAt: Date,
        value: T
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let json = try encode(value)
        let statement = try prepare(
            "INSERT INTO records(kind, id, task_id, sort_at, json) VALUES (?, ?, ?, ?, ?);"
        )
        defer { sqlite3_finalize(statement) }
        bind(kind, at: 1, in: statement)
        bind(id.uuidString, at: 2, in: statement)
        bind(taskID?.uuidString, at: 3, in: statement)
        bind(Self.dateString(sortAt), at: 4, in: statement)
        bind(json, at: 5, in: statement)
        try stepDone(statement)
    }

    private func deleteRecord(kind: String, id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        // UUIDs written by the TS control plane historically used lowercase
        // strings while Swift's UUID.uuidString is uppercase. SQLite's
        // default BINARY comparison made those records readable in a list but
        // impossible to fetch or remove by UUID. Keep record identity
        // case-insensitive at this boundary so both clients share the same
        // persisted store.
        let statement = try prepare(
            "DELETE FROM records WHERE kind = ? AND id = ? COLLATE NOCASE;"
        )
        defer { sqlite3_finalize(statement) }
        bind(kind, at: 1, in: statement)
        bind(id.uuidString, at: 2, in: statement)
        try stepDone(statement)
    }

    private func fetchRecord<T: Decodable>(kind: String, id: UUID, as type: T.Type) throws -> T? {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(
            "SELECT json FROM records WHERE kind = ? AND id = ? COLLATE NOCASE;"
        )
        defer { sqlite3_finalize(statement) }
        bind(kind, at: 1, in: statement)
        bind(id.uuidString, at: 2, in: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let pointer = sqlite3_column_text(statement, 0) else {
            throw lastError()
        }
        return try decode(String(cString: pointer), as: type)
    }

    private func fetchRecords<T: Decodable>(
        kind: String,
        taskID: UUID? = nil,
        as type: T.Type
    ) throws -> [T] {
        lock.lock()
        defer { lock.unlock() }
        let sql = taskID == nil
            ? "SELECT id, json FROM records WHERE kind = ? ORDER BY sort_at DESC;"
            : "SELECT id, json FROM records WHERE kind = ? AND task_id = ? ORDER BY sort_at DESC;"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(kind, at: 1, in: statement)
        if let taskID {
            bind(taskID.uuidString, at: 2, in: statement)
        }

        var values: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idPointer = sqlite3_column_text(statement, 0),
                  let jsonPointer = sqlite3_column_text(statement, 1) else {
                continue
            }
            let id = String(cString: idPointer)
            do {
                values.append(try decode(String(cString: jsonPointer), as: type))
            } catch {
                throw MuError.database(
                    "Could not decode "
                        + kind
                        + " record "
                        + id
                        + ": "
                        + error.localizedDescription
                )
            }
        }
        return values
    }

    private func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "SQLite execution failed."
            sqlite3_free(errorPointer)
            throw MuError.database(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw lastError()
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError()
        }
    }

    private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, muSQLiteTransient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func stringColumn(
        _ statement: OpaquePointer,
        index: Int32
    ) -> String? {
        guard sqlite3_column_type(statement, index)
            != SQLITE_NULL,
        let pointer = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: pointer)
    }

    private func uuidColumn(
        _ statement: OpaquePointer,
        index: Int32
    ) -> UUID? {
        stringColumn(statement, index: index)
            .flatMap(UUID.init(uuidString:))
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try MuCoding.makeEncoder().encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw MuError.database("Could not encode record.")
        }
        return string
    }

    private func decode<T: Decodable>(_ json: String, as type: T.Type) throws -> T {
        guard let data = json.data(using: .utf8) else {
            throw MuError.database("Could not decode record bytes.")
        }
        return try MuCoding.makeDecoder().decode(type, from: data)
    }

    private func lastError() -> MuError {
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error."
        return .database(message)
    }

    private static func dateString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
