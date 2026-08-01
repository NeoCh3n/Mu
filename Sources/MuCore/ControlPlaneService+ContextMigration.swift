import Foundation

extension ControlPlaneService {
    /// Idempotently projects legacy imported conversation snapshots into the
    /// Context Kernel as raw provenance only. A legacy transcript is not a
    /// normalized claim and therefore never creates a Context Record or
    /// becomes accepted Project truth.
    public func migrateLegacyImportedConversationsToContextSources() throws {
        let conversations = try store.fetchImportedConversations()
        guard !conversations.isEmpty else { return }

        var migratedCount = 0
        try store.withTransaction {
            for conversation in conversations {
                guard let task = try store.fetchTask(
                    id: conversation.taskID
                ) else {
                    continue
                }
                let link = try store.fetchTaskProjectLink(
                    taskID: task.id
                )
                let projectID = task.projectID ?? link?.projectID
                guard let projectID else {
                    continue
                }

                let checksum = legacyContextSourceChecksum(
                    conversation
                )
                let sourceID = MuStableIdentity.uuid(
                    namespace:
                        "mu.context-source.legacy-imported-conversation",
                    components: [
                        projectID.uuidString.lowercased(),
                        conversation.id.uuidString.lowercased(),
                        checksum
                    ]
                )
                if try store.fetchContextSource(
                    projectID: projectID,
                    id: sourceID
                ) != nil {
                    continue
                }

                let importedAt = conversation.importedAt
                let policyID = MuStableIdentity.uuid(
                    namespace: "mu.context-policy-version",
                    components: [
                        projectID.uuidString.lowercased(),
                        ContextPolicySubjectKind.source.rawValue,
                        sourceID.uuidString.lowercased(),
                        "1"
                    ]
                )
                let source = ContextSourceRecord(
                    id: sourceID,
                    projectID: projectID,
                    sourceType: .runtimeSession,
                    sourceActorID: Self.localHumanActorID,
                    sourcePrincipalID: Self.localOwnerPrincipalID,
                    runtimeEndpointID:
                        conversation.endpointID
                        ?? legacyEndpointID(
                            for: conversation.provider
                        ),
                    runtimeProvider: conversation.provider,
                    runtimeSessionID: conversation.nativeSessionID,
                    externalRef:
                        "imported-conversation:"
                        + conversation.id.uuidString.lowercased(),
                    sourceChecksum: checksum,
                    sourceSchemaVersion:
                        "mu.imported-conversation-metadata.v1",
                    accessPolicyID: policyID,
                    originalTimestamp:
                        conversation.sourceUpdatedAt,
                    importedAt: importedAt
                )
                let policy = try ContextAccessPolicyRecord(
                    id: policyID,
                    projectID: projectID,
                    subjectKind: .source,
                    subjectID: sourceID,
                    namespace: "agent-private/legacy-import",
                    sensitivity: .restricted,
                    visibility: .ownerOnly,
                    allowedActorIDs: [Self.localHumanActorID],
                    allowedPrincipalIDs: [Self.localOwnerPrincipalID],
                    allowedTaskIDs: [conversation.taskID],
                    createdByActorID: Self.localHumanActorID,
                    createdAt: importedAt
                )
                let transition = ContextTransitionRecord(
                    projectID: projectID,
                    aggregateKind: .source,
                    aggregateID: sourceID,
                    transitionKind: .created,
                    fromState: nil,
                    toState: ContextSourceState.active.rawValue,
                    actorID: Self.localHumanActorID,
                    principalID: Self.localOwnerPrincipalID,
                    reason:
                        "Projected legacy ImportedConversation metadata "
                        + "as a raw, non-canonical Context Source.",
                    expectedRevision: 0,
                    newRevision: 1,
                    occurredAt: importedAt
                )

                try store.insertContextSource(
                    source,
                    transition: transition
                )
                try store.insertContextAccessPolicy(policy)
                migratedCount += 1
            }

            if migratedCount > 0 {
                try store.appendEvent(
                    LedgerEvent(
                        actorID: Self.localHumanActorID,
                        principalID: Self.localOwnerPrincipalID,
                        type:
                            "context.legacy_imported_conversations.migrated",
                        summary:
                            "Projected \(migratedCount) legacy imported "
                            + "conversation snapshot(s) as raw Context "
                            + "Source metadata.",
                        payload: [
                            "schema_version": "1",
                            "source_count": String(migratedCount),
                            "canonical_records_created": "0",
                            "migration": "idempotent"
                        ]
                    )
                )
            }
        }
    }

    func redactLegacyImportedConversationContextSource(
        _ conversation: ImportedConversation
    ) throws {
        guard let task = try store.fetchTask(
            id: conversation.taskID
        ) else {
            return
        }
        let link = try store.fetchTaskProjectLink(
            taskID: task.id
        )
        guard let projectID =
            task.projectID ?? link?.projectID else {
            return
        }
        let checksum = legacyContextSourceChecksum(
            conversation
        )
        let sourceID = MuStableIdentity.uuid(
            namespace:
                "mu.context-source.legacy-imported-conversation",
            components: [
                projectID.uuidString.lowercased(),
                conversation.id.uuidString.lowercased(),
                checksum
            ]
        )
        guard var source = try store.fetchContextSource(
            projectID: projectID,
            id: sourceID
        ), source.state == .active else {
            return
        }
        let occurredAt = Date()
        let previousRevision = source.revision
        source.state = .redacted
        source.revision += 1
        try store.updateContextSourceState(
            source,
            transition: ContextTransitionRecord(
                projectID: projectID,
                aggregateKind: .source,
                aggregateID: source.id,
                transitionKind: .stateChanged,
                fromState:
                    ContextSourceState.active.rawValue,
                toState:
                    ContextSourceState.redacted.rawValue,
                actorID: Self.localHumanActorID,
                principalID: Self.localOwnerPrincipalID,
                reason:
                    "The user removed Mu's local imported history copy.",
                expectedRevision: previousRevision,
                newRevision: source.revision,
                occurredAt: occurredAt
            )
        )
    }

    private func legacyContextSourceChecksum(
        _ conversation: ImportedConversation
    ) -> String {
        let existing = conversation.snapshotFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if !existing.isEmpty {
            if existing.count == 64,
               existing.unicodeScalars.allSatisfy({
                   (48...57).contains($0.value)
                       || (97...102).contains($0.value)
               }) {
                return existing
            }
            return Data(existing.utf8).muSHA256
        }
        let material = [
            conversation.provider.rawValue,
            conversation.providerInstanceKey,
            conversation.nativeSessionID,
            conversation.sourceFingerprint,
            String(conversation.messageCount),
            String(conversation.skippedCount)
        ].joined(separator: "\u{1F}")
        return Data(material.utf8).muSHA256
    }

    private func legacyEndpointID(
        for provider: ConversationProvider
    ) -> UUID? {
        switch provider {
        case .codex:
            Self.codexEndpointID
        case .claudeCode:
            Self.claudeCodeEndpointID
        case .openWorker:
            Self.openWorkerEndpointID
        default:
            nil
        }
    }
}
