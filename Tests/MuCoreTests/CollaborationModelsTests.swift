import Foundation
@testable import MuCore
import Testing

@Suite(.serialized)
struct CollaborationModelsTests {
    @Test
    func collaborationRecordsRoundTripAndSharedBlocksKeepReferencesOnly()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "mu-collaboration-models-(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SQLiteStore(
            databaseURL: root.appending(path: "mu.sqlite")
        )
        let spaceID = UUID()
        let projectID = UUID()
        let threadID = UUID()
        let workItemID = UUID()
        let runID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let space = CollaborationSpaceRecord(
            id: spaceID,
            displayName: "Shared engineering room",
            description: "Two people and local Agents.",
            version: 1,
            createdAt: now,
            updatedAt: now
        )
        let thread = SpaceThreadRecord(
            id: threadID,
            spaceID: spaceID,
            projectID: projectID,
            title: "Fix login error",
            createdAt: now,
            updatedAt: now
        )
        let item = WorkItemRecord(
            id: workItemID,
            spaceID: spaceID,
            threadID: threadID,
            projectID: projectID,
            title: "Fix login error",
            objective: "Make the login flow recover after a timeout.",
            acceptanceCriteria: ["The recovery test passes"],
            status: .ready,
            priority: .high,
            createdAt: now,
            updatedAt: now
        )
        let block = SharedBlockRecord(
            spaceID: spaceID,
            threadID: threadID,
            blockType: .agentRunReference,
            entityReferenceType: "agent_run",
            entityReferenceID: runID,
            positionKey: "0001",
            createdAt: now,
            updatedAt: now
        )

        try store.upsertCollaborationSpace(space)
        try store.upsertSpaceThread(thread)
        try store.upsertWorkItem(item)
        try store.upsertSharedBlock(block)

        #expect(try store.fetchCollaborationSpace(id: spaceID) == space)
        #expect(try store.fetchSpaceThreads(spaceID: spaceID) == [thread])
        #expect(try store.fetchWorkItems(spaceID: spaceID) == [item])

        let blocks = try store.fetchSharedBlocks(
            spaceID: spaceID,
            threadID: threadID
        )
        #expect(blocks == [block])
        #expect(blocks.first?.entityReferenceID == runID)
        #expect(blocks.first?.presentationText == nil)
    }

    @Test
    func legacyTaskAndChatRemainReadableWithoutCollaborationReferences()
        throws
    {
        let task = TaskRecord(
            title: "Legacy task",
            objective: "Keep old JSON readable.",
            successCriteria: [],
            constraints: [],
            pendingSteps: [],
            repositoryPath: "/tmp/legacy"
        )
        let chat = ChatEntry(
            taskID: task.id,
            authorKind: .user,
            authorName: "User",
            text: "Hello"
        )

        let encoder = MuCoding.makeEncoder()
        let decoder = MuCoding.makeDecoder()
        let taskData = try encoder.encode(task)
        let chatData = try encoder.encode(chat)
        let decodedTask = try decoder.decode(TaskRecord.self, from: taskData)
        let decodedChat = try decoder.decode(ChatEntry.self, from: chatData)

        #expect(decodedTask.spaceID == nil)
        #expect(decodedTask.threadID == nil)
        #expect(decodedTask.workItemID == nil)
        #expect(decodedChat.spaceID == nil)
        #expect(decodedChat.threadID == nil)
        #expect(decodedChat.workItemID == nil)
    }

    @Test
    func composerControlsComeOnlyFromEndpointCapabilitiesAndConfiguration()
        throws
    {
        let endpoint = RuntimeEndpoint(
            runtimeTypeID: ControlPlaneService.codexRuntimeTypeID,
            displayName: "Codex",
            adapterVersion: "test",
            runtimeVersion: "test",
            location: .local,
            provenance: .vendorProtocol,
            permissionModel: .fineGrained,
            capabilities: [],
            status: .active,
            guaranteeNote: "test",
            nativeConfiguration: [
                "model_options": "balanced, high, balanced",
                "permission_options": "read_only, workspace_write"
            ]
        )

        let controls = RuntimeComposerCapabilities.forEndpoint(
            endpoint,
            hasAuthorizedContext: true
        )

        #expect(controls.canSubmit)
        #expect(controls.canObserve)
        #expect(controls.canInterrupt)
        #expect(controls.canSelectContext)
        #expect(controls.canChooseModel)
        #expect(controls.modelOptions == ["balanced", "high"])
        #expect(controls.canChoosePermission)
        #expect(controls.permissionOptions == ["read_only", "workspace_write"])
    }

    @Test
    func collaborationEventStreamsAndPresenceRemainSeparated() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "mu-collaboration-events-(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SQLiteStore(
            databaseURL: root.appending(path: "mu.sqlite")
        )
        let spaceID = UUID()
        let threadID = UUID()
        let runID = UUID()
        let bindingID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try store.upsertSpaceEvent(
            SpaceEventRecord(
                spaceID: spaceID,
                threadID: threadID,
                sequence: 2,
                eventType: "work_item.updated",
                payload: ["status": "in_progress"],
                idempotencyKey: "space-2",
                occurredAt: now.addingTimeInterval(2)
            )
        )
        try store.upsertSpaceEvent(
            SpaceEventRecord(
                spaceID: spaceID,
                threadID: threadID,
                sequence: 1,
                eventType: "thread.created",
                payload: ["title": "Thread"],
                idempotencyKey: "space-1",
                occurredAt: now
            )
        )
        try store.upsertRuntimeEvent(
            RuntimeEventRecord(
                runID: runID,
                bindingID: bindingID,
                sequence: 1,
                eventType: "tool.file_read",
                summary: "Read a visible source file.",
                payload: ["path": "Sources/App.swift"],
                occurredAt: now
            )
        )
        try store.upsertPresenceSession(
            PresenceSessionRecord(
                spaceID: spaceID,
                actorID: UUID(),
                clientInstanceID: "mac-1",
                displayName: "You",
                expiresAt: now.addingTimeInterval(60)
            )
        )
        try store.upsertPresenceSession(
            PresenceSessionRecord(
                spaceID: spaceID,
                actorID: UUID(),
                clientInstanceID: "mac-expired",
                displayName: "Away",
                state: .offline,
                lastSeenAt: now.addingTimeInterval(-120),
                expiresAt: now.addingTimeInterval(-60)
            )
        )

        let spaceEvents = try store.fetchSpaceEvents(
            spaceID: spaceID,
            threadID: threadID
        )
        #expect(spaceEvents.map(\.sequence) == [1, 2])
        #expect(try store.fetchRuntimeEvents(runID: runID).count == 1)
        #expect(try store.fetchRuntimeEvents(runID: UUID()).isEmpty)
        #expect(
            try store.fetchPresenceSessions(
                spaceID: spaceID,
                now: now
            ).count == 1
        )
        #expect(
            try store.fetchPresenceSessions(
                spaceID: spaceID,
                includingExpired: true
            ).count == 2
        )
        #expect(spaceEvents.first?.eventType == "thread.created")
        #expect(spaceEvents.first?.payload["title"] == "Thread")
    }

    @Test
    func optimisticCollaborationWritesRejectStaleVersionsAndOutboxIsIdempotent()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "mu-collaboration-lock-(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SQLiteStore(
            databaseURL: root.appending(path: "mu.sqlite")
        )
        let spaceID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let initial = CollaborationSpaceRecord(
            id: spaceID,
            displayName: "Room",
            version: 1,
            createdAt: now,
            updatedAt: now
        )
        try store.upsertCollaborationSpace(initial)

        var updated = initial
        updated.displayName = "Renamed room"
        updated.version = 2
        updated.updatedAt = now.addingTimeInterval(1)
        try store.updateCollaborationSpace(updated, expectedVersion: 1)
        #expect(try store.fetchCollaborationSpace(id: spaceID) == updated)

        var stale = initial
        stale.displayName = "Stale writer"
        stale.version = 2
        stale.updatedAt = now.addingTimeInterval(2)
        #expect(throws: MuError.self) {
            try store.updateCollaborationSpace(stale, expectedVersion: 1)
        }

        let command = CollaborationOutboxRecord(
            spaceID: spaceID,
            stream: "space",
            idempotencyKey: "thread-create-1",
            operation: "thread.create",
            payload: ["title": "Thread"],
            createdAt: now,
            updatedAt: now
        )
        let first = try store.enqueueOutbox(command)
        var retry = command
        retry.id = UUID()
        retry.payload = ["title": "A different retry payload"]
        let second = try store.enqueueOutbox(retry)
        #expect(first.id == second.id)
        #expect(try store.fetchOutbox(spaceID: spaceID).count == 1)

        var sent = first
        sent.state = .sent
        sent.version = 2
        sent.updatedAt = now.addingTimeInterval(3)
        try store.updateOutbox(sent, expectedVersion: 1)
        #expect(try store.fetchOutbox(id: first.id)?.state == .sent)
    }
}
