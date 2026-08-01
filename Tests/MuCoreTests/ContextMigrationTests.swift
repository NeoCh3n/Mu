import Foundation
@testable import MuCore
import Testing

@Suite(.serialized)
struct ContextMigrationTests {
    @Test
    func legacyImportedConversationBecomesRawSourceOnlyAndIsIdempotent()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appending(
                path: "mu-context-migration-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let dataDirectory = root.appending(
            path: "data",
            directoryHint: .isDirectory
        )
        let service = try ControlPlaneService(
            dataDirectory: dataDirectory
        )
        let task = try service.createTask(
            title: "Legacy history migration",
            objective: "Keep imported history as raw provenance.",
            successCriteria: ["No accepted record is synthesized"],
            constraints: [],
            pendingSteps: [],
            repositoryPath: root.path,
            sourceEndpointID:
                ControlPlaneService.syntheticEndpointAID
        )
        let conversation = ImportedConversation(
            taskID: task.id,
            provider: .codex,
            providerInstanceKey: "codex:desktop",
            endpointID: ControlPlaneService.codexEndpointID,
            nativeSessionID: "thread-legacy",
            title: "Legacy Codex conversation",
            canonicalWorkspacePath: root.path,
            accessKind: .vendorProtocol,
            resumability: .resumable,
            sourceFingerprint: "source-fingerprint",
            snapshotFingerprint: "snapshot-fingerprint",
            messageCount: 4
        )
        try service.store.upsertImportedConversation(conversation)

        let migrated = try ControlPlaneService(
            dataDirectory: dataDirectory
        )
        let projectID = try #require(
            migrated.store.fetchTask(id: task.id)?.projectID
        )
        let sources = try migrated.store.fetchContextSources(
            projectID: projectID
        )
        let source = try #require(sources.first)
        #expect(sources.count == 1)
        #expect(source.sourceType == .runtimeSession)
        #expect(source.runtimeProvider == .codex)
        #expect(source.runtimeSessionID == "thread-legacy")
        #expect(source.state == .active)
        #expect(source.rawArtifactURI == nil)
        #expect(
            try migrated.store.fetchContextRecords(
                projectID: projectID
            ).isEmpty
        )

        let sourcePolicyID = try #require(source.accessPolicyID)
        let policy = try #require(
            try migrated.store.fetchContextAccessPolicy(
                projectID: projectID,
                id: sourcePolicyID
            )
        )
        #expect(policy.sensitivity == .restricted)
        #expect(policy.visibility == .ownerOnly)
        #expect(policy.allowedTaskIDs == [task.id])

        let restarted = try ControlPlaneService(
            dataDirectory: dataDirectory
        )
        #expect(
            try restarted.store.fetchContextSources(
                projectID: projectID
            ).count == 1
        )
        #expect(
            try restarted.store.fetchContextRecords(
                projectID: projectID
            ).isEmpty
        )

        try restarted.removeImportedConversation(
            taskID: task.id,
            conversationID: conversation.id
        )
        #expect(
            try restarted.store.fetchImportedConversation(
                id: conversation.id
            ) == nil
        )
        let redactedSource = try #require(
            try restarted.store.fetchContextSource(
                projectID: projectID,
                id: source.id
            )
        )
        #expect(redactedSource.state == .redacted)
        #expect(redactedSource.revision == 2)
        #expect(
            try restarted.store.fetchContextTransitions(
                projectID: projectID,
                aggregateKind: .source,
                aggregateID: source.id
            ).map(\.toState) == [
                ContextSourceState.active.rawValue,
                ContextSourceState.redacted.rawValue
            ]
        )
    }
}
