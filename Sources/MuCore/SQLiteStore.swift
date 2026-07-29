import Foundation
import SQLite3

private let muSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class SQLiteStore {
    public let databaseURL: URL

    private var database: OpaquePointer?
    private let lock = NSRecursiveLock()

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
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let result = try operation()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
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
        let statement = try prepare("DELETE FROM records WHERE kind = ? AND id = ?;")
        defer { sqlite3_finalize(statement) }
        bind(kind, at: 1, in: statement)
        bind(id.uuidString, at: 2, in: statement)
        try stepDone(statement)
    }

    private func fetchRecord<T: Decodable>(kind: String, id: UUID, as type: T.Type) throws -> T? {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("SELECT json FROM records WHERE kind = ? AND id = ?;")
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
            ? "SELECT json FROM records WHERE kind = ? ORDER BY sort_at DESC;"
            : "SELECT json FROM records WHERE kind = ? AND task_id = ? ORDER BY sort_at DESC;"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(kind, at: 1, in: statement)
        if let taskID {
            bind(taskID.uuidString, at: 2, in: statement)
        }

        var values: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let pointer = sqlite3_column_text(statement, 0) else { continue }
            values.append(try decode(String(cString: pointer), as: type))
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
