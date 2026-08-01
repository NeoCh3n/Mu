import Foundation
import MuCore
import Testing

@Suite(.serialized)
struct MuCoreTests {
@Test
func checkpointHashIsDeterministic() throws {
        let endpointID = UUID(uuidString: "7DDA46AF-32B4-4F75-A051-0A5A02B15D01")!
        let taskID = UUID(uuidString: "9B8B9D46-E57B-4D85-B94C-6FE0643C5144")!
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let content = CheckpointContent(
            taskID: taskID,
            sourceRunID: nil,
            sourceEndpointID: endpointID,
            objective: "Build Mu",
            successCriteria: ["Compiles"],
            pendingSteps: ["Test"],
            constraints: ["Local only"],
            repository: RepositorySnapshot(
                path: "/tmp/mu",
                isGitRepository: true,
                branch: "main",
                baseCommit: "abc",
                headCommit: "abc"
            ),
            createdAt: date
        )

        #expect(try CheckpointHasher.hash(content) == CheckpointHasher.hash(content))
        #expect(try CheckpointHasher.hash(content).hasPrefix("sha256:"))
    }

    @Test
    func fullCrossRuntimeHandoffCreatesReplanAndLedger() throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }

        let service = try ControlPlaneService(
            dataDirectory: fixture.root.appending(path: "mu-data", directoryHint: .isDirectory)
        )
        let endpoints = try service.store.fetchEndpoints()
        let source = try #require(
            endpoints.first { $0.runtimeTypeID == "mu.synthetic/runtime-a" }
        )
        let receiver = try #require(
            endpoints.first { $0.runtimeTypeID == "mu.synthetic/runtime-b" }
        )
        let forge = try #require(
            try service.store.fetchAgent(id: ControlPlaneService.forgeAgentID)
        )

        let task = try service.createTask(
            title: "Continue Mu",
            objective: "Move implementation to an independent runtime.",
            successCriteria: ["Tests pass", "No critical constraint omitted"],
            constraints: ["Keep data local", "Do not rewrite ledger history"],
            pendingSteps: ["Inspect transferred state", "Run verification"],
            repositoryPath: fixture.repository.path,
            sourceEndpointID: source.id,
            agentIdentityID: forge.id
        )

        try "changed after commit\n".write(
            to: fixture.repository.appending(path: "README.md"),
            atomically: true,
            encoding: .utf8
        )
        try "portable evidence\n".write(
            to: fixture.repository.appending(path: "notes.txt"),
            atomically: true,
            encoding: .utf8
        )

        let checkpoint = try service.captureCheckpoint(taskID: task.id)
        #expect(checkpoint.content.repository.isDirty)
        #expect(checkpoint.content.repository.trackedPatchSHA256 != nil)
        #expect(checkpoint.content.repository.untrackedFiles == ["notes.txt"])
        #expect(checkpoint.contentHash.hasPrefix("sha256:"))

        let handoff = try service.proposeHandoff(
            taskID: task.id,
            checkpointID: checkpoint.id,
            receiverEndpointID: receiver.id
        )
        #expect(try service.store.fetchTask(id: task.id)?.status == .handoffPending)

        let receivingRun = try service.acceptHandoff(id: handoff.id)
        #expect(receivingRun.purpose == .replan)
        #expect(receivingRun.endpointID == receiver.id)
        #expect(receivingRun.agentIdentityID == forge.id)
        #expect(receivingRun.actorName == forge.displayName)
        #expect(receivingRun.plan.contains { $0.contains("Keep data local") })
        #expect(receivingRun.plan.contains { $0.contains("Run verification") })

        let updatedTaskValue = try service.store.fetchTask(id: task.id)
        let updatedTask = try #require(updatedTaskValue)
        #expect(updatedTask.status == .running)
        #expect(updatedTask.currentEndpointID == receiver.id)
        #expect(updatedTask.currentRunID == receivingRun.id)
        #expect(updatedTask.assignedAgentIdentityID == forge.id)

        let resolvedValue = try service.store.fetchHandoffs(taskID: task.id)
            .first { $0.id == handoff.id }
        let resolved = try #require(resolvedValue)
        #expect(resolved.status == .accepted)

        let eventTypes = try service.store.fetchEvents(taskID: task.id).map(\.type)
        #expect(eventTypes.contains("checkpoint.validated"))
        #expect(eventTypes.contains("handoff.proposed"))
        #expect(eventTypes.contains("handoff.accepted"))
        #expect(eventTypes.contains("replan.created"))
    }

    @Test
    func runtimeIndependentAgentIdentitiesCreateTaskAndPersistWorkspaceChat() throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let service = try ControlPlaneService(
            dataDirectory: fixture.root.appending(path: "mu-data", directoryHint: .isDirectory)
        )

        let agents = try service.store.fetchAgents()
        #expect(agents.count == 5)
        #expect(Set(agents.map(\.id)) == Set([
            ControlPlaneService.atlasAgentID,
            ControlPlaneService.forgeAgentID,
            ControlPlaneService.lensAgentID,
            ControlPlaneService.scoutAgentID,
            ControlPlaneService.relayAgentID
        ]))

        let forge = try #require(
            agents.first { $0.id == ControlPlaneService.forgeAgentID }
        )
        let source = try #require(
            try service.store.fetchEndpoint(id: ControlPlaneService.syntheticEndpointAID)
        )
        let task = try service.createTask(
            title: "Mu Workspace Smoke Test",
            objective: "Verify a runtime-independent agent workspace.",
            successCriteria: ["Identity and runtime are both persisted"],
            constraints: ["Keep the workspace local"],
            pendingSteps: ["Inspect files", "Capture evidence"],
            repositoryPath: fixture.repository.path,
            sourceEndpointID: source.id,
            agentIdentityID: forge.id
        )

        #expect(task.assignedAgentIdentityID == forge.id)
        let currentRunID = try #require(task.currentRunID)
        let run = try #require(try service.store.fetchRun(id: currentRunID))
        #expect(run.agentIdentityID == forge.id)
        #expect(run.endpointID == source.id)
        #expect(run.actorName == "Forge")

        let initialChat = try service.store.fetchChatEntries(taskID: task.id)
        #expect(initialChat.count == 1)
        #expect(initialChat.first?.authorKind == .system)
        #expect(initialChat.first?.text.contains("runtime message dispatch is explicit") == true)

        _ = try service.appendChatEntry(
            taskID: task.id,
            agentIdentityID: forge.id,
            authorKind: .user,
            authorName: "Acceptance",
            text: "Verify Files, Chat, Browser, Terminal, and Artifacts."
        )
        let chat = try service.store.fetchChatEntries(taskID: task.id)
        #expect(chat.count == 2)
        #expect(chat.last?.text.contains("Artifacts") == true)
        #expect(
            try service.store.fetchEvents(taskID: task.id)
                .contains { $0.type == "chat.note_added" }
        )
    }

    @Test
    func agentRegistrySupportsCreateDeleteUnassignAndPersistentStarterDeletion() throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let dataDirectory = fixture.root.appending(
            path: "mu-data",
            directoryHint: .isDirectory
        )
        let service = try ControlPlaneService(dataDirectory: dataDirectory)
        let source = try #require(
            try service.store.fetchEndpoint(id: ControlPlaneService.syntheticEndpointAID)
        )

        let custom = try service.createAgentIdentity(
            displayName: "Maya",
            shortName: "",
            role: .researcher,
            summary: "Researches a bounded question.",
            preferredEndpointID: source.id,
            capabilityTags: ["research", "Research", "evidence"],
            accentHex: "#2F80ED"
        )
        #expect(custom.shortName == "MA")
        #expect(custom.capabilityTags == ["research", "evidence"])

        let task = try service.createTask(
            title: "Agent deletion fixture",
            objective: "Preserve history while removing a reusable identity.",
            successCriteria: ["Task becomes unassigned"],
            constraints: [],
            pendingSteps: [],
            repositoryPath: fixture.repository.path,
            sourceEndpointID: source.id,
            agentIdentityID: custom.id
        )
        let runID = try #require(task.currentRunID)
        try service.deleteAgentIdentity(id: custom.id)
        #expect(try service.store.fetchAgent(id: custom.id) == nil)
        #expect(try service.store.fetchTask(id: task.id)?.assignedAgentIdentityID == nil)
        #expect(try service.store.fetchRun(id: runID)?.agentIdentityID == nil)

        try service.deleteAgentIdentity(id: ControlPlaneService.lensAgentID)
        #expect(try service.store.fetchAgent(id: ControlPlaneService.lensAgentID) == nil)
        let restarted = try ControlPlaneService(dataDirectory: dataDirectory)
        #expect(try restarted.store.fetchAgent(id: ControlPlaneService.lensAgentID) == nil)
        #expect(
            try restarted.store.fetchRegistryTombstones().contains {
                $0.id == ControlPlaneService.lensAgentID
                    && $0.entityKind == .agentIdentity
            }
        )
    }

    @Test
    func runtimeRegistrySupportsManualCRUDTombstonesAndReferencePreservation() throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let dataDirectory = fixture.root.appending(
            path: "mu-data",
            directoryHint: .isDirectory
        )
        let service = try ControlPlaneService(dataDirectory: dataDirectory)

        let manual = try service.registerManualEndpoint(
            displayName: "Pi RPC",
            runtimeTypeID: "earendil.pi/coding-agent-rpc",
            location: .local,
            provenance: .vendorProtocol,
            permissionModel: .none,
            executablePath: "/usr/local/bin/pi",
            notes: "User-managed installation."
        )
        #expect(manual.status == .offline)
        #expect(manual.capabilities.isEmpty)
        #expect(manual.nativeConfiguration?["executable"] == "/usr/local/bin/pi")
        let manualSnapshotValue = try service.store.fetchEndpoint(id: manual.id)
        let manualSnapshot = try #require(manualSnapshotValue)
        try service.deleteEndpoint(id: manual.id)
        #expect(try service.store.fetchEndpoint(id: manual.id) == manualSnapshot)
        #expect(try service.store.fetchRegisteredEndpoint(id: manual.id) == nil)

        // One provider/runtime type can represent multiple separately named
        // CLI or desktop instances. Removing one registration must not block
        // a fresh, independently identified instance.
        let restoredInstance = try service.registerManualEndpoint(
            displayName: "Pi RPC restored",
            runtimeTypeID: "earendil.pi/coding-agent-rpc",
            location: .local,
            provenance: .vendorProtocol,
            permissionModel: .none,
            executablePath: nil,
            notes: ""
        )
        #expect(restoredInstance.id != manual.id)
        #expect(restoredInstance.runtimeTypeID == manual.runtimeTypeID)
        let registeredRestoredInstance = try service.store
            .fetchRegisteredEndpoint(id: restoredInstance.id)
        #expect(registeredRestoredInstance?.displayName == "Pi RPC restored")

        let source = try #require(
            try service.store.fetchRegisteredEndpoint(
                id: ControlPlaneService.syntheticEndpointAID
            )
        )
        let receiver = try #require(
            try service.store.fetchRegisteredEndpoint(
                id: ControlPlaneService.syntheticEndpointBID
            )
        )
        let task = try service.createTask(
            title: "Referenced runtime",
            objective: "Preserve history while removing this Runtime from the registry.",
            successCriteria: [],
            constraints: [],
            pendingSteps: [],
            repositoryPath: fixture.repository.path,
            sourceEndpointID: source.id,
            agentIdentityID: ControlPlaneService.forgeAgentID
        )
        let checkpoint = try service.captureCheckpoint(taskID: task.id)
        let runID = try #require(task.currentRunID)
        let proposedHandoff = try service.proposeHandoff(
            taskID: task.id,
            checkpointID: checkpoint.id,
            receiverEndpointID: receiver.id
        )
        let proposedHandoffSnapshotValue = try service.store.fetchHandoffs(taskID: task.id)
            .first { $0.id == proposedHandoff.id }
        let proposedHandoffSnapshot = try #require(proposedHandoffSnapshotValue)

        try service.deleteEndpoint(id: receiver.id)
        #expect(try service.store.fetchEndpoint(id: receiver.id) == receiver)
        #expect(try service.store.fetchRegisteredEndpoint(id: receiver.id) == nil)
        #expect(
            try service.store.fetchHandoffs(taskID: task.id)
                .first { $0.id == proposedHandoff.id } == proposedHandoffSnapshot
        )

        do {
            _ = try service.acceptHandoff(id: proposedHandoff.id)
            Issue.record("A removed receiver Runtime must not accept a Handoff.")
        } catch {
            #expect(error.localizedDescription.contains("Handoff inputs"))
        }
        #expect(
            try service.store.fetchHandoffs(taskID: task.id)
                .first { $0.id == proposedHandoff.id } == proposedHandoffSnapshot
        )

        try service.rejectHandoff(
            id: proposedHandoff.id,
            reason: "Receiver was removed from the registry."
        )
        do {
            _ = try service.proposeHandoff(
                taskID: task.id,
                checkpointID: checkpoint.id,
                receiverEndpointID: receiver.id
            )
            Issue.record("A removed Runtime must not receive a new Handoff.")
        } catch {
            #expect(error.localizedDescription.contains("Receiver endpoint"))
        }

        let taskBeforeRemovalValue = try service.store.fetchTask(id: task.id)
        let taskBeforeRemoval = try #require(taskBeforeRemovalValue)
        let runBeforeRemovalValue = try service.store.fetchRun(id: runID)
        let runBeforeRemoval = try #require(runBeforeRemovalValue)
        let checkpointBeforeRemovalValue = try service.store.fetchCheckpoint(
            id: checkpoint.id
        )
        let checkpointBeforeRemoval = try #require(
            checkpointBeforeRemovalValue
        )
        let handoffBeforeRemovalValue = try service.store.fetchHandoffs(taskID: task.id)
            .first { $0.id == proposedHandoff.id }
        let handoffBeforeRemoval = try #require(
            handoffBeforeRemovalValue
        )

        try service.deleteEndpoint(id: source.id)

        #expect(try service.store.fetchEndpoint(id: source.id) == source)
        #expect(try service.store.fetchRegisteredEndpoint(id: source.id) == nil)
        #expect(try service.store.fetchTask(id: task.id) == taskBeforeRemoval)
        #expect(try service.store.fetchRun(id: runID) == runBeforeRemoval)
        #expect(
            try service.store.fetchCheckpoint(id: checkpoint.id) == checkpointBeforeRemoval
        )
        #expect(
            try service.store.fetchHandoffs(taskID: task.id)
                .first { $0.id == proposedHandoff.id } == handoffBeforeRemoval
        )
        #expect(
            try service.store.fetchAgent(id: ControlPlaneService.forgeAgentID)?
                .preferredEndpointID == nil
        )

        do {
            _ = try service.createTask(
                title: "Removed Runtime",
                objective: "Must not start.",
                successCriteria: [],
                constraints: [],
                pendingSteps: [],
                repositoryPath: fixture.repository.path,
                sourceEndpointID: source.id
            )
            Issue.record("A removed Runtime must not start a new Task.")
        } catch {
            #expect(error.localizedDescription.contains("Source endpoint"))
        }
        do {
            _ = try service.captureCheckpoint(taskID: task.id)
            Issue.record("A removed current Runtime must not capture a Checkpoint.")
        } catch {
            #expect(error.localizedDescription.contains("Current runtime endpoint"))
        }

        let removalEvent = try service.store.fetchEvents().first {
            $0.type == "endpoint.deleted"
                && $0.payload["endpoint_id"] == source.id.uuidString
        }
        #expect(removalEvent?.payload["preserved_references"] == "4")
        #expect(removalEvent?.payload["task_references"] == "1")
        #expect(removalEvent?.payload["run_references"] == "1")
        #expect(removalEvent?.payload["checkpoint_references"] == "1")
        #expect(removalEvent?.payload["handoff_references"] == "1")
        #expect(
            try service.store.fetchRegistryTombstones().contains {
                $0.id == source.id && $0.entityKind == .runtimeEndpoint
            }
        )

        let restarted = try ControlPlaneService(dataDirectory: dataDirectory)
        #expect(try restarted.store.fetchEndpoint(id: source.id) == source)
        #expect(try restarted.store.fetchRegisteredEndpoint(id: source.id) == nil)
        #expect(try restarted.store.fetchRegisteredEndpoint(id: receiver.id) == nil)
        #expect(try restarted.store.fetchTask(id: task.id) == taskBeforeRemoval)
        #expect(try restarted.store.fetchRun(id: runID) == runBeforeRemoval)
        #expect(
            try restarted.store.fetchCheckpoint(id: checkpoint.id) == checkpointBeforeRemoval
        )
        #expect(
            try restarted.store.fetchHandoffs(taskID: task.id)
                .first { $0.id == proposedHandoff.id } == handoffBeforeRemoval
        )
    }

    @Test
    func bootstrapMigratesConflatedProjectTerminologyInCodexGuarantee() throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let dataDirectory = fixture.root.appending(
            path: "mu-data",
            directoryHint: .isDirectory
        )
        let service = try ControlPlaneService(dataDirectory: dataDirectory)
        let legacyEndpoint = RuntimeEndpoint(
            id: ControlPlaneService.codexEndpointID,
            runtimeTypeID: ControlPlaneService.codexRuntimeTypeID,
            displayName: "Codex App Server",
            adapterVersion: "0.4.0",
            runtimeVersion: "fixture",
            location: .local,
            provenance: .vendorProtocol,
            permissionModel: .fineGrained,
            capabilities: ControlPlaneService.codexImplementedCapabilities,
            status: .active,
            guaranteeNote:
                "Live official App Server connection verified. "
                + "Initial read-only Project runs and receiving Replans create "
                + "persistent native threads and turns.",
            nativeConfiguration: [
                "executable":
                    "/Applications/Codex.app/Contents/Resources/codex"
            ]
        )
        try service.store.upsertEndpoint(legacyEndpoint)

        let restarted = try ControlPlaneService(dataDirectory: dataDirectory)
        let migrated = try #require(
            try restarted.store.fetchRegisteredEndpoint(
                id: ControlPlaneService.codexEndpointID
            )
        )

        #expect(
            !migrated.guaranteeNote.localizedCaseInsensitiveContains(
                "project run"
            )
        )
        #expect(migrated.guaranteeNote.contains("Task runs"))
    }

    @Test
    func workspaceFilesAndReadOnlyTerminalStayInsideRepository() throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let service = WorkspaceService()

        let sources = fixture.repository.appending(path: "Sources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "print(\"Mu\")\n".write(
            to: sources.appending(path: "main.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "root\n".write(
            to: fixture.repository.appending(path: "Z-notes.txt"),
            atomically: true,
            encoding: .utf8
        )

        let files = try service.files(at: fixture.repository.path)
        #expect(files.contains { $0.relativePath == "README.md" && !$0.isDirectory })
        let sourcesIndex = try #require(files.firstIndex { $0.relativePath == "Sources" })
        let sourceFileIndex = try #require(files.firstIndex { $0.relativePath == "Sources/main.swift" })
        let rootNoteIndex = try #require(files.firstIndex { $0.relativePath == "Z-notes.txt" })
        #expect(sourcesIndex < sourceFileIndex)
        #expect(sourceFileIndex < rootNoteIndex)
        let readme = try service.readTextFile(
            rootPath: fixture.repository.path,
            relativePath: "README.md"
        )
        #expect(readme == "initial\n")

        let status = try service.run(.status, at: fixture.repository.path)
        #expect(status.exitCode == 0)
        #expect(status.output.contains("main"))

        let outside = fixture.root.appending(path: "outside.txt")
        try "outside\n".write(to: outside, atomically: true, encoding: .utf8)
        let link = fixture.repository.appending(path: "outside-link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        do {
            _ = try service.readTextFile(
                rootPath: fixture.repository.path,
                relativePath: "outside-link.txt"
            )
            Issue.record("A symlink outside the workspace should not be readable.")
        } catch {
            #expect(error.localizedDescription.contains("outside"))
        }
    }

    @Test
    func terminalDrainsOutputLargerThanAPipeBuffer() throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }

        for index in 0..<2_500 {
            let name = String(format: "untracked-%04d-with-a-long-name.txt", index)
            FileManager.default.createFile(
                atPath: fixture.repository.appending(path: name).path,
                contents: Data()
            )
        }

        let status = try WorkspaceService().run(.status, at: fixture.repository.path)
        #expect(status.exitCode == 0)
        #expect(status.output.utf8.count > 65_536)
        #expect(status.output.contains("untracked-2499-with-a-long-name.txt"))
    }

    @Test
    func bundledWorkspaceSmokeFixtureLoadsAsTwoFiles() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workspace = projectRoot
            .appending(path: "Fixtures", directoryHint: .isDirectory)
            .appending(path: "WorkspaceSmoke", directoryHint: .isDirectory)
        let files = try WorkspaceService().files(at: workspace.path)
        #expect(files.map(\.relativePath).sorted() == ["README.md", "acceptance.txt"])
    }

    @Test
    func rejectionKeepsSourceOwnership() throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }

        let service = try ControlPlaneService(
            dataDirectory: fixture.root.appending(path: "mu-data", directoryHint: .isDirectory)
        )
        let endpoints = try service.store.fetchEndpoints()
        let source = try #require(
            endpoints.first { $0.runtimeTypeID == "mu.synthetic/runtime-a" }
        )
        let receiver = try #require(
            endpoints.first { $0.runtimeTypeID == "mu.synthetic/runtime-b" }
        )
        let task = try service.createTask(
            title: "Reject fixture",
            objective: "Prove rejection retains ownership.",
            successCriteria: ["Sender remains owner"],
            constraints: [],
            pendingSteps: [],
            repositoryPath: fixture.repository.path,
            sourceEndpointID: source.id
        )
        let checkpoint = try service.captureCheckpoint(taskID: task.id)
        let handoff = try service.proposeHandoff(
            taskID: task.id,
            checkpointID: checkpoint.id,
            receiverEndpointID: receiver.id
        )

        try service.rejectHandoff(id: handoff.id, reason: "Receiver needs another constraint.")
        let updatedTaskValue = try service.store.fetchTask(id: task.id)
        let updatedTask = try #require(updatedTaskValue)
        #expect(updatedTask.status == .running)
        #expect(updatedTask.currentEndpointID == source.id)
        #expect(updatedTask.currentRunID == task.currentRunID)
    }

    @Test
    func codexAppServerProbeUsesNegotiatedProtocol() throws {
        let fake = try FakeCodexExecutable(
            script:
                """
                #!/bin/sh
                while IFS= read -r line; do
                  case "$line" in
                    *'"method":"initialize"'*)
                      printf '%s\n' '{"id":1,"result":{"userAgent":"Codex Desktop/9.9.9 (test)","codexHome":"/tmp/codex","platformFamily":"unix","platformOs":"macos"}}'
                      ;;
                    *account*read*)
                      printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt"},"requiresOpenaiAuth":true}}'
                      ;;
                    *thread*list*)
                      printf '%s\n' '{"id":3,"result":{"data":[{"id":"thread-1"}],"nextCursor":null,"backwardsCursor":null}}'
                      ;;
                  esac
                done
                """
        )
        defer { fake.remove() }

        let client = CodexAppServerClient(executableURL: fake.url)
        defer { client.stop() }
        let result = try client.probe()
        #expect(result.userAgent.contains("9.9.9"))
        #expect(result.platformOS == "macos")
        #expect(result.signedIn)
        #expect(result.observedThreadCount == 1)
    }

    @Test
    func codexReadOnlyReplanCapturesNativeIdentityAndOutput() throws {
        let fake = try FakeCodexExecutable(
            script:
                """
                #!/bin/sh
                while IFS= read -r line; do
                  case "$line" in
                    *'"method":"initialize"'*)
                      printf '%s\n' '{"id":1,"result":{"userAgent":"Codex Desktop/9.9.9 (test)","codexHome":"/tmp/codex","platformFamily":"unix","platformOs":"macos"}}'
                      ;;
                    *'"id":2'*)
                      printf '%s\n' '{"id":2,"result":{"thread":{"id":"native-thread"}}}'
                      ;;
                    *'"id":3'*)
                      printf '%s\n' '{"id":3,"result":{"turn":{"id":"native-turn"}}}'
                      printf '%s\n' '{"method":"item/completed","params":{"threadId":"native-thread","turnId":"native-turn","item":{"type":"agentMessage","id":"item-1","text":"1. Preserve every constraint.\\n2. Run verification."},"completedAtMs":1}}'
                      printf '%s\n' '{"method":"turn/completed","params":{"threadId":"native-thread","turn":{"id":"native-turn","status":"completed"}}}'
                      ;;
                  esac
                done
                """
        )
        defer { fake.remove() }

        let taskID = UUID()
        let endpointID = UUID()
        let task = TaskRecord(
            id: taskID,
            title: "Native replan",
            objective: "Verify Codex integration.",
            successCriteria: ["Plan returned"],
            constraints: ["Read only"],
            pendingSteps: ["Verify"],
            repositoryPath: "/tmp",
            currentEndpointID: endpointID
        )
        let content = CheckpointContent(
            taskID: taskID,
            sourceRunID: nil,
            sourceEndpointID: endpointID,
            objective: task.objective,
            successCriteria: task.successCriteria,
            pendingSteps: task.pendingSteps,
            constraints: task.constraints,
            repository: RepositorySnapshot(path: "/tmp", isGitRepository: true)
        )
        let checkpoint = CheckpointRecord(
            taskID: taskID,
            sourceEndpointID: endpointID,
            contentHash: try CheckpointHasher.hash(content),
            content: content
        )

        let client = CodexAppServerClient(executableURL: fake.url)
        defer { client.stop() }
        let result = try client.runReadOnlyReplan(
            checkpoint: checkpoint,
            task: task,
            timeout: 5
        )
        #expect(result.threadID == "native-thread")
        #expect(result.turnID == "native-turn")
        #expect(result.status == "completed")
        #expect(result.output.contains("Run verification"))
    }
}

private final class GitFixture {
    let root: URL
    let repository: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "mu-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        repository = root.appending(path: "repo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try runGit(["init", "--initial-branch=main"])
        try runGit(["config", "user.email", "mu-tests@example.invalid"])
        try runGit(["config", "user.name", "Mu Tests"])
        try "initial\n".write(
            to: repository.appending(path: "README.md"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "README.md"])
        try runGit(["commit", "-m", "Initial fixture"])
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private func runGit(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repository.path] + arguments
        let errorPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(
                decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            throw MuError.commandFailed(message)
        }
    }
}

private final class FakeCodexExecutable {
    let root: URL
    let url: URL

    init(script: String) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "mu-fake-codex-\(UUID().uuidString)", directoryHint: .isDirectory)
        url = root.appending(path: "codex")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
