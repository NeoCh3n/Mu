import Foundation
@testable import MuCore
import Testing

@Suite(.serialized)
struct ClaudeCodeAdapterTests {
    @Test
    func claudeOutputMirrorFinishesAtomicallyWithoutReplayingThrottledDraft() throws {
        let persistence = ClaudeMirrorPersistence()
        let mirror = ClaudeCodeOutputMirror { text, force in
            persistence.append(text: text, force: force)
        }

        mirror.offer("draft")
        // This more complete draft arrives within the 100 ms coalescing
        // window. It must not be persisted later after the terminal receipt.
        mirror.offer("draft still arriving")
        mirror.finish("final answer")

        #expect(persistence.values == [
            ClaudeMirrorPersistence.Value(text: "draft", force: false),
            ClaudeMirrorPersistence.Value(text: "final answer", force: true)
        ])

        // There is deliberately no delayed timer in the mirror. Waiting past
        // the coalescing interval proves that a completed turn cannot keep
        // rendering the omitted draft character-by-character.
        Thread.sleep(forTimeInterval: 0.15)
        #expect(persistence.values == [
            ClaudeMirrorPersistence.Value(text: "draft", force: false),
            ClaudeMirrorPersistence.Value(text: "final answer", force: true)
        ])
    }

    @Test
    func claudeClientStreamsVisibleTextReturnsNativeReceiptAndLaunchesReadOnly() throws {
        let fixture = try ClaudeCodeExecutableFixture()
        defer { fixture.remove() }

        let taskID = UUID()
        let task = TaskRecord(
            id: taskID,
            title: "Claude stream fixture",
            objective: "Verify the bounded native stream contract.",
            successCriteria: ["Return the final receipt"],
            constraints: ["Read only"],
            pendingSteps: [],
            repositoryPath: fixture.root.path
        )
        let contextPack = ProjectContextPackRecord(
            projectID: UUID(),
            taskID: taskID,
            workspaceID: UUID(),
            objective: task.objective,
            constraints: task.constraints,
            permissions: [.readRepository],
            acceptanceTests: task.successCriteria,
            contentSHA256: "fixture"
        )
        let sessionID = "b48895a9-a6c6-4e65-802b-40830d603e0b"
        let resumeID = "20340e5e-fc0d-4c0f-b89c-bafc06d801d3"
        let callbacks = ClaudeStrings()
        let started = ClaudeStrings()
        let client = ClaudeCodeClient(executableURL: fixture.executableURL)

        let result = try client.runReadOnlyTask(
            task: task,
            contextPack: contextPack,
            sessionID: sessionID,
            resumeSessionID: resumeID,
            promptOverride: "EXACT_FIXTURE_PROMPT",
            onSessionStarted: { started.append($0) },
            onVisibleText: { callbacks.append($0) }
        )

        #expect(started.values == [resumeID])
        #expect(callbacks.values == [
            "Draft visible",
            "Draft visible answer",
            "Final reviewable receipt"
        ])
        #expect(result.sessionID == fixture.nativeSessionID)
        #expect(result.output == "Final reviewable receipt")
        #expect(result.status == "success")
        #expect(result.model == "claude-fixture")
        #expect(result.costUSD == 0.0025)
        #expect(result.durationMilliseconds == 42)

        let arguments = try fixture.arguments()
        #expect(arguments.contains("--print"))
        #expect(argumentValue("--output-format", in: arguments) == "stream-json")
        #expect(arguments.contains("--include-partial-messages"))
        #expect(argumentValue("--permission-mode", in: arguments) == "plan")
        #expect(argumentValue("--tools", in: arguments) == "Read,Glob,Grep")
        #expect(
            argumentValue("--disallowedTools", in: arguments)
                == "Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch"
        )
        #expect(argumentValue("--resume", in: arguments) == resumeID)
        #expect(argumentValue("--session-id", in: arguments) == nil)
        #expect(arguments.last == "EXACT_FIXTURE_PROMPT")
    }

    @Test
    func controlPlaneClaudeTurnBindsAndReceiptsGovernedContextPack()
        throws
    {
        let fixture = try ClaudeCodeExecutableFixture()
        defer { fixture.remove() }
        let service = try ControlPlaneService(
            dataDirectory: fixture.root.appending(
                path: "mu-data",
                directoryHint: .isDirectory
            )
        )
        let endpoint = RuntimeEndpoint(
            id: ControlPlaneService.claudeCodeEndpointID,
            runtimeTypeID:
                ControlPlaneService.claudeCodeRuntimeTypeID,
            displayName: "Claude Code Fixture",
            adapterVersion: "test",
            runtimeVersion: "fixture",
            location: .local,
            provenance: .vendorCLI,
            permissionModel: .promptGate,
            capabilities:
                ControlPlaneService
                .claudeCodeImplementedCapabilities,
            status: .active,
            guaranteeNote: "Test fixture only.",
            nativeConfiguration: [
                "executable": fixture.executableURL.path
            ]
        )
        try service.store.upsertEndpoint(endpoint)
        let task = try service.createTask(
            title: "Governed Claude turn",
            objective:
                "Return a reviewable native Claude receipt.",
            successCriteria: [
                "The exact Context Pack is receipted."
            ],
            constraints: ["Read only"],
            pendingSteps: ["Inspect the native receipt"],
            repositoryPath: fixture.root.path,
            sourceEndpointID: endpoint.id
        )
        let runID = try #require(task.currentRunID)

        let result = try service.dispatchClaudeCodeTask(
            runID: runID
        )

        #expect(result.output == "Final reviewable receipt")
        let run = try #require(
            try service.store.fetchRun(id: runID)
        )
        let binding = try #require(
            try service.store.fetchRuntimeSessionBindings(
                taskID: task.id
            ).first
        )
        let packID = try #require(run.contextPackID)
        #expect(binding.contextPackID == packID)
        #expect(binding.runID == run.id)
        let kernel = try service.projectKernelContext(
            taskID: task.id
        )
        let receipts =
            try service.store.fetchContextDeliveries(
                projectID: kernel.project.id,
                taskID: task.id
            ).filter {
                $0.contextPackID == packID
                    && $0.runtimeBindingID == binding.id
                    && $0.runID == run.id
            }
        #expect(receipts.contains {
            $0.status == .prepared
        })
        #expect(receipts.contains {
            $0.status == .delivered
                && $0.adapterReceiptSHA256 != nil
        })
        #expect(receipts.contains {
            $0.status == .failed
        } == false)

        let pack = try #require(
            try service.store.fetchProjectContextPack(
                projectID: kernel.project.id,
                id: packID
            )
        )
        let capturedArguments = try fixture.arguments()
        #expect(
            capturedArguments.contains(
                "# Mu Project Context Pack"
            )
        )
        #expect(
            capturedArguments.joined(separator: "\n")
                .contains(pack.objective)
        )
        #expect(
            capturedArguments.joined(separator: "\n")
                .contains("<mu_imported_context>")
                == false
        )
    }

    @Test
    func firstWorkspaceMessageStartsClaudeSessionInsteadOfRequiringResume()
        throws
    {
        let fixture = try ClaudeCodeExecutableFixture()
        defer { fixture.remove() }
        let service = try ControlPlaneService(
            dataDirectory: fixture.root.appending(
                path: "mu-data",
                directoryHint: .isDirectory
            )
        )
        let endpoint = RuntimeEndpoint(
            id: ControlPlaneService.claudeCodeEndpointID,
            runtimeTypeID: ControlPlaneService.claudeCodeRuntimeTypeID,
            displayName: "Claude Code Fixture",
            adapterVersion: "test",
            runtimeVersion: "fixture",
            location: .local,
            provenance: .vendorCLI,
            permissionModel: .promptGate,
            capabilities: ControlPlaneService.claudeCodeImplementedCapabilities,
            status: .active,
            guaranteeNote: "Test fixture only.",
            nativeConfiguration: ["executable": fixture.executableURL.path]
        )
        try service.store.upsertEndpoint(endpoint)
        let task = try service.createTask(
            title: "First Claude workspace message",
            objective: "Start Claude from the workspace composer.",
            successCriteria: ["The first message is part of the native turn."],
            constraints: ["Read only"],
            pendingSteps: [],
            repositoryPath: fixture.root.path,
            sourceEndpointID: endpoint.id
        )

        let prepared = try service.prepareWorkspaceMessage(
            taskID: task.id,
            text: "Inspect the project and summarize the entry point.",
            selectedEndpointID: endpoint.id
        )
        let route = try #require(prepared.route)
        let runID = try #require(prepared.entry.runID)
        #expect(prepared.entry.runtimeSessionBindingID == nil)
        #expect(prepared.entry.deliveryState == .awaitingSession)

        let result = try service.dispatchClaudeCodeTask(
            runID: runID,
            workspaceEntryID: prepared.entry.id
        )
        #expect(result.status == "success")
        #expect(route.prompt.contains("Inspect the project"))

        let deliveredEntry = try #require(
            try service.store.fetchChatEntry(id: prepared.entry.id)
        )
        #expect(deliveredEntry.deliveryState == .delivered)
        #expect(deliveredEntry.runtimeSessionBindingID != nil)
        #expect(
            try fixture.arguments().joined(separator: "\n")
                .contains(
                    "# Current Project message\n\nInspect the project and summarize the entry point."
                )
        )
    }

    private func argumentValue(
        _ flag: String,
        in arguments: [String]
    ) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

private final class ClaudeMirrorPersistence: @unchecked Sendable {
    struct Value: Equatable {
        let text: String
        let force: Bool
    }

    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.withLock { storage }
    }

    func append(text: String, force: Bool) {
        lock.withLock {
            storage.append(Value(text: text, force: force))
        }
    }
}

private final class ClaudeStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}

private final class ClaudeCodeExecutableFixture {
    let root: URL
    let executableURL: URL
    let argumentsURL: URL
    let nativeSessionID = "c16f699a-6e29-49bb-9ae1-6d4996eb57a5"

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "mu-claude-stream-fixture-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        executableURL = root.appending(path: "claude")
        argumentsURL = root.appending(path: "arguments.txt")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let argumentPath = Self.shellQuote(argumentsURL.path)
        let system = Self.json([
            "type": "system",
            "session_id": nativeSessionID,
            "model": "claude-fixture"
        ])
        let firstDelta = Self.json([
            "type": "stream_event",
            "event": [
                "type": "content_block_delta",
                "delta": ["type": "text_delta", "text": "Draft visible"]
            ]
        ])
        let secondDelta = Self.json([
            "type": "stream_event",
            "event": [
                "type": "content_block_delta",
                "delta": ["type": "text_delta", "text": " answer"]
            ]
        ])
        let result = Self.json([
            "type": "result",
            "session_id": nativeSessionID,
            "subtype": "success",
            "is_error": false,
            "result": "Final reviewable receipt",
            "total_cost_usd": 0.0025,
            "duration_ms": 42
        ])
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > \(argumentPath)
        printf '%s\\n' '\(system)'
        printf '%s\\n' '\(firstDelta)'
        printf '%s\\n' '\(secondDelta)'
        printf '%s\\n' '\(result)'
        """
        try script.write(
            to: executableURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
    }

    func arguments() throws -> [String] {
        String(decoding: try Data(contentsOf: argumentsURL), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast()
            .map(String.init)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func json(_ value: [String: Any]) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }
}
