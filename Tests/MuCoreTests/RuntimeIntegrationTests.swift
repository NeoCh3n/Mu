import Foundation
import MuCore
import Testing

@Suite(.serialized)
struct RuntimeIntegrationTests {
    @Test
    func openWorkerDiscoveryReadsAValidApplicationBundle() throws {
        let fixture = try OpenWorkerApplicationFixture(
            version: "9.8.7",
            bundleID: "com.example.openworker-test",
            executableName: "openworker-test",
            createExecutable: true
        )
        defer { fixture.remove() }

        let result = try #require(OpenWorkerDiscovery.discover(at: fixture.appURL))

        #expect(result.appURL == fixture.appURL.standardizedFileURL)
        #expect(result.version == "9.8.7")
        #expect(result.bundleID == "com.example.openworker-test")
        #expect(result.executableURL == fixture.executableURL.standardizedFileURL)
    }

    @Test
    func openWorkerDiscoveryRejectsAMissingExecutable() throws {
        let fixture = try OpenWorkerApplicationFixture(
            version: "1.0.0",
            bundleID: "com.example.openworker-test",
            executableName: "missing-openworker",
            createExecutable: false
        )
        defer { fixture.remove() }

        #expect(OpenWorkerDiscovery.discover(at: fixture.appURL) == nil)
    }

    @Test
    func openWorkerDiscoveryRejectsAnUnsafeExecutableName() throws {
        let fixture = try OpenWorkerApplicationFixture(
            version: "1.0.0",
            bundleID: "com.example.openworker-test",
            executableName: "../outside-openworker",
            createExecutable: false
        )
        defer { fixture.remove() }

        #expect(OpenWorkerDiscovery.discover(at: fixture.appURL) == nil)
    }

    @Test
    func codexReadOnlyTaskStagesIdentityAndReconcilesFinalAnswer() throws {
        let fake = try RuntimeFakeCodexAppServer(
            threadID: "thread-staged",
            turnID: "turn-staged",
            streamedFinalAnswer: "STREAM_FINAL",
            persistedFinalAnswer: "PERSISTED_FINAL"
        )
        defer { fake.remove() }

        let endpointID = UUID()
        let task = TaskRecord(
            title: "Codex staged identity",
            objective: "Verify the App Server contract.",
            successCriteria: ["Final answer reconciled"],
            constraints: ["Read only"],
            pendingSteps: ["Inspect protocol receipt"],
            repositoryPath: fake.root.path,
            currentEndpointID: endpointID
        )
        let clientUserMessageID = "mu-run-\(UUID().uuidString)"
        var stagedCallbacks: [String] = []

        let client = CodexAppServerClient(executableURL: fake.executableURL)
        defer { client.stop() }
        let result = try client.runReadOnlyTask(
            task: task,
            agent: nil,
            clientUserMessageID: clientUserMessageID,
            timeout: 5,
            model: "gpt-codex-configured",
            onThreadStarted: { threadID in
                stagedCallbacks.append("thread:\(threadID)")
            },
            onTurnStarted: { threadID, turnID in
                stagedCallbacks.append("turn:\(threadID):\(turnID)")
            }
        )

        #expect(stagedCallbacks == [
            "thread:thread-staged",
            "turn:thread-staged:turn-staged"
        ])
        #expect(result.threadID == "thread-staged")
        #expect(result.turnID == "turn-staged")
        #expect(result.status == "completed")
        #expect(result.historyReconciled)
        #expect(result.output == "PERSISTED_FINAL")

        let requests = try fake.requests()
        let turnRequest = try #require(requests.first {
            $0["method"] as? String == "turn/start"
        })
        let turnParams = try #require(turnRequest["params"] as? [String: Any])
        #expect(turnParams["clientUserMessageId"] as? String == clientUserMessageID)
        #expect(turnParams["threadId"] as? String == "thread-staged")
        #expect(turnParams["model"] as? String == "gpt-codex-configured")
        let sandboxPolicy = try #require(
            turnParams["sandboxPolicy"] as? [String: Any]
        )
        #expect(sandboxPolicy["type"] as? String == "readOnly")
        #expect(sandboxPolicy["networkAccess"] as? Bool == false)

        let nameRequest = try #require(requests.first {
            $0["method"] as? String == "thread/name/set"
        })
        let nameParams = try #require(nameRequest["params"] as? [String: Any])
        #expect(nameParams["threadId"] as? String == "thread-staged")
        #expect(nameParams["name"] as? String == task.title)

        let threadRead = try #require(requests.first {
            $0["method"] as? String == "thread/read"
        })
        let readParams = try #require(threadRead["params"] as? [String: Any])
        #expect(readParams["threadId"] as? String == "thread-staged")
        #expect(readParams["includeTurns"] as? Bool == true)
        #expect(requests.filter {
            $0["method"] as? String == "thread/read"
        }.count == 1)
    }

    @Test
    func codexReadOnlyTaskMirrorsOnlyAgentMessageTextAndReconcilesFinalReceipt() throws {
        let fake = try RuntimeFakeCodexAppServer(
            threadID: "thread-visible-text",
            turnID: "turn-visible-text",
            streamedFinalAnswer: "STREAM_VISIBLE_FINAL",
            persistedFinalAnswer: "PERSISTED_VISIBLE_FINAL",
            emitsVisibleTextDeltas: true
        )
        defer { fake.remove() }

        let task = TaskRecord(
            title: "Codex visible text",
            objective: "Mirror native visible text only.",
            successCriteria: ["Use the persisted final receipt"],
            constraints: ["Read only"],
            pendingSteps: ["Observe the native stream"],
            repositoryPath: fake.root.path,
            currentEndpointID: UUID()
        )
        let callbacks = VisibleTextCollector()
        let client = CodexAppServerClient(executableURL: fake.executableURL)
        defer { client.stop() }

        let result = try client.runReadOnlyTask(
            task: task,
            agent: nil,
            clientUserMessageID: "mu-visible-\(UUID().uuidString)",
            timeout: 5,
            onVisibleText: { text in
                callbacks.append(text)
            }
        )

        let observedCallbacks = callbacks.values
        #expect(Array(observedCallbacks.prefix(3)) == [
            "Visible ",
            "Visible stream",
            "STREAM_VISIBLE_FINAL"
        ])
        #expect(observedCallbacks.allSatisfy { !$0.contains("PRIVATE") })
        #expect(result.status == "completed")
        #expect(result.historyReconciled)
        #expect(result.output == "PERSISTED_VISIBLE_FINAL")
    }

    @Test(arguments: ["completed", "failed", "interrupted", "cancelled"])
    func codexReadOnlyTaskFallsBackToPersistedTerminalTurnState(
        nativeStatus: String
    ) throws {
        let expectedStatus = nativeStatus == "cancelled"
            ? "interrupted"
            : nativeStatus
        let errorMessage = nativeStatus == "completed"
            ? nil
            : "Fixture \(nativeStatus) terminal state."
        let fake = try RuntimeFakeCodexAppServer(
            threadID: "thread-fallback-\(nativeStatus)",
            turnID: "turn-fallback-\(nativeStatus)",
            streamedFinalAnswer: "STREAM_\(nativeStatus)",
            persistedFinalAnswer: "PERSISTED_\(nativeStatus)",
            completionNotificationStatus: nil,
            persistedTurnStatus: nativeStatus,
            persistedErrorMessage: errorMessage
        )
        defer { fake.remove() }

        let task = TaskRecord(
            title: "Codex \(nativeStatus) fallback",
            objective: "Converge from persisted native state.",
            successCriteria: ["Return before the overall timeout"],
            constraints: ["Read only"],
            pendingSteps: ["Read the terminal turn"],
            repositoryPath: fake.root.path,
            currentEndpointID: UUID()
        )
        let client = CodexAppServerClient(executableURL: fake.executableURL)
        defer { client.stop() }

        let result = try client.runReadOnlyTask(
            task: task,
            agent: nil,
            clientUserMessageID: "mu-fallback-\(UUID().uuidString)",
            timeout: 6
        )

        #expect(result.status == expectedStatus)
        #expect(result.errorMessage == errorMessage)
        #expect(result.output == "PERSISTED_\(nativeStatus)")
        #expect(result.historyReconciled)

        let requests = try fake.requests()
        #expect(requests.filter {
            $0["method"] as? String == "thread/read"
        }.count == 2)
    }

    @Test
    func controlPlaneDispatchCodexTaskPersistsNativeReceiptAndCASOutput() throws {
        let fake = try RuntimeFakeCodexAppServer(
            threadID: "thread-e2e",
            turnID: "turn-e2e",
            streamedFinalAnswer: "STREAM_E2E",
            persistedFinalAnswer: "MU_CODEX_E2E_OK"
        )
        defer { fake.remove() }

        let dataDirectory = fake.root.appending(
            path: "mu-data",
            directoryHint: .isDirectory
        )
        let repository = fake.root.appending(
            path: "workspace",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: repository,
            withIntermediateDirectories: true
        )
        let service = try ControlPlaneService(dataDirectory: dataDirectory)

        var endpoint =
            try service.store.fetchRegisteredEndpoint(id: ControlPlaneService.codexEndpointID)
            ?? RuntimeEndpoint(
                id: ControlPlaneService.codexEndpointID,
                runtimeTypeID: ControlPlaneService.codexRuntimeTypeID,
                displayName: "Codex App Server Test",
                adapterVersion: "test",
                runtimeVersion: "fake",
                location: .local,
                provenance: .vendorProtocol,
                permissionModel: .fineGrained,
                capabilities: ControlPlaneService.codexImplementedCapabilities,
                status: .active,
                guaranteeNote: "Test fixture only.",
                nativeConfiguration: ["executable": fake.executableURL.path]
            )
        endpoint.status = .active
        endpoint.capabilities = ControlPlaneService.codexImplementedCapabilities
        endpoint.nativeConfiguration = ["executable": fake.executableURL.path]
        try service.store.upsertEndpoint(endpoint)

        let task = try service.createTask(
            title: "Native Codex E2E",
            objective: "Return the integration receipt.",
            successCriteria: ["MU_CODEX_E2E_OK"],
            constraints: ["Read only"],
            pendingSteps: ["Reconcile persisted history"],
            repositoryPath: repository.path,
            sourceEndpointID: endpoint.id,
            agentIdentityID: ControlPlaneService.relayAgentID
        )
        let runID = try #require(task.currentRunID)

        let result = try service.dispatchCodexTask(runID: runID)

        #expect(result.output == "MU_CODEX_E2E_OK")
        #expect(result.historyReconciled)

        let completedTask = try #require(try service.store.fetchTask(id: task.id))
        let completedRun = try #require(try service.store.fetchRun(id: runID))
        #expect(completedTask.status == .completed)
        #expect(completedRun.state == .completed)
        #expect(completedRun.nativeThreadID == "thread-e2e")
        #expect(completedRun.nativeTurnID == "turn-e2e")
        #expect(completedRun.nativeOutput == "MU_CODEX_E2E_OK")
        let binding = try #require(
            try service.store.fetchRuntimeSessionBindings(
                taskID: task.id
            ).first
        )
        let contextPackID = try #require(
            completedRun.contextPackID
        )
        #expect(binding.contextPackID == contextPackID)
        #expect(binding.runID == completedRun.id)
        #expect(binding.nativeSessionID == "thread-e2e")
        let kernel = try service.projectKernelContext(
            taskID: task.id
        )
        let deliveryReceipts =
            try service.store.fetchContextDeliveries(
                projectID: kernel.project.id,
                taskID: task.id
            ).filter {
                $0.contextPackID == contextPackID
                    && $0.runtimeBindingID == binding.id
                    && $0.runID == completedRun.id
            }
        #expect(
            deliveryReceipts.contains {
                $0.status == .prepared
            }
        )
        #expect(
            deliveryReceipts.contains {
                $0.status == .delivered
                    && $0.adapterReceiptSHA256 != nil
            }
        )
        #expect(
            deliveryReceipts.contains {
                $0.status == .failed
            } == false
        )

        let chat = try service.store.fetchChatEntries(taskID: task.id)
        let agentReply = try #require(chat.last(where: { $0.authorKind == .agent }))
        #expect(agentReply.text == "MU_CODEX_E2E_OK")
        #expect(agentReply.agentIdentityID == ControlPlaneService.relayAgentID)

        let events = try service.store.fetchEvents(taskID: task.id)
        #expect(events.contains { $0.type == "codex.thread.started" })
        #expect(events.contains { $0.type == "codex.turn.started" })
        let completion = try #require(events.first {
            $0.type == "codex.turn.completed"
        })
        let outputSHA256 = try #require(completion.payload["output_sha256"])
        let outputURI = try #require(completion.payload["output_uri"])
        #expect(outputSHA256 == Data("MU_CODEX_E2E_OK".utf8).muSHA256)
        #expect(
            service.artifactStore.verify(
                uri: outputURI,
                expectedSHA256: outputSHA256
            )
        )
    }
}

private final class VisibleTextCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ text: String) {
        lock.lock()
        storage.append(text)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class OpenWorkerApplicationFixture {
    let root: URL
    let appURL: URL
    let executableURL: URL

    init(
        version: String,
        bundleID: String,
        executableName: String,
        createExecutable: Bool
    ) throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "mu-openworker-discovery-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        appURL = root.appending(
            path: "OpenWorker.app",
            directoryHint: .isDirectory
        )
        let contentsURL = appURL.appending(
            path: "Contents",
            directoryHint: .isDirectory
        )
        let macOSURL = contentsURL.appending(
            path: "MacOS",
            directoryHint: .isDirectory
        )
        executableURL = macOSURL.appending(path: executableName)

        try FileManager.default.createDirectory(
            at: macOSURL,
            withIntermediateDirectories: true
        )
        let info: [String: Any] = [
            "CFBundleShortVersionString": version,
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": executableName
        ]
        let plist = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .binary,
            options: 0
        )
        try plist.write(
            to: contentsURL.appending(path: "Info.plist"),
            options: .atomic
        )

        if createExecutable {
            try Data("#!/bin/sh\nexit 0\n".utf8).write(
                to: executableURL,
                options: .atomic
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executableURL.path
            )
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class RuntimeFakeCodexAppServer {
    let root: URL
    let executableURL: URL
    let requestsURL: URL

    init(
        threadID: String,
        turnID: String,
        streamedFinalAnswer: String,
        persistedFinalAnswer: String,
        completionNotificationStatus: String? = "completed",
        persistedTurnStatus: String = "completed",
        persistedErrorMessage: String? = nil,
        emitsVisibleTextDeltas: Bool = false
    ) throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "mu-runtime-fake-codex-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        executableURL = root.appending(path: "codex")
        requestsURL = root.appending(path: "requests.jsonl")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let requestPath = Self.shellQuote(requestsURL.path)
        let responseThreadID = Self.jsonString(threadID)
        let responseTurnID = Self.jsonString(turnID)
        let streamFinal = Self.jsonString(streamedFinalAnswer)
        let persistedFinal = Self.jsonString(persistedFinalAnswer)
        let persistedStatus = Self.jsonString(persistedTurnStatus)
        let persistedErrorField = persistedErrorMessage.map {
            ",\"error\":{\"message\":\(Self.jsonString($0))}"
        } ?? ""
        let completionNotification: String
        if let completionNotificationStatus {
            let notificationStatus = Self.jsonString(completionNotificationStatus)
            completionNotification =
                """
                printf '%s\\n' '{"method":"turn/completed","params":{"threadId":\(responseThreadID),"turn":{"id":\(responseTurnID),"status":\(notificationStatus)}}}'
                """
        } else {
            completionNotification = ":"
        }
        let visibleTextNotifications: String
        if emitsVisibleTextDeltas {
            visibleTextNotifications =
                """
                sleep 0.1
                printf '%s\\n' '{"method":"item/reasoning/delta","params":{"threadId":\(responseThreadID),"turnId":\(responseTurnID),"itemId":"reasoning-1","delta":"PRIVATE_REASONING"}}'
                printf '%s\\n' '{"method":"item/tool/call","params":{"threadId":\(responseThreadID),"turnId":\(responseTurnID),"item":{"type":"toolCall","id":"tool-1","name":"PRIVATE_TOOL"}}}'
                printf '%s\\n' '{"method":"item/agentMessage/delta","params":{"threadId":\(responseThreadID),"turnId":\(responseTurnID),"itemId":"stream-final","delta":"Visible "}}'
                printf '%s\\n' '{"method":"item/agentMessage/delta","params":{"threadId":\(responseThreadID),"turnId":\(responseTurnID),"itemId":"stream-final","delta":"stream"}}'
                """
        } else {
            visibleTextNotifications = ""
        }
        let script =
            """
            #!/bin/sh
            request_log=\(requestPath)
            while IFS= read -r line; do
              printf '%s\\n' "$line" >> "$request_log"
              case "$line" in
                *'"method":"initialize"'*)
                  printf '%s\\n' '{"id":1,"result":{"userAgent":"Codex Runtime Test/1.0","platformOs":"macos"}}'
                  ;;
                *'"id":2'*)
                  printf '%s\\n' '{"id":2,"result":{"thread":{"id":\(responseThreadID)}}}'
                  ;;
                *'"id":3'*)
                  printf '%s\\n' '{"id":3,"result":{}}'
                  ;;
                *'"id":4'*)
                  printf '%s\\n' '{"id":4,"result":{"turn":{"id":\(responseTurnID)}}}'
                  \(visibleTextNotifications)
                  printf '%s\\n' '{"method":"item/completed","params":{"threadId":\(responseThreadID),"turnId":\(responseTurnID),"item":{"type":"agentMessage","id":"stream-final","text":\(streamFinal),"phase":"final_answer"}}}'
                  printf '%s\\n' '{"method":"item/completed","params":{"threadId":\(responseThreadID),"turnId":\(responseTurnID),"item":{"type":"agentMessage","id":"stream-tail","text":"STREAM_TAIL","phase":"commentary"}}}'
                  \(completionNotification)
                  ;;
                *'"id":5'*)
                  printf '%s\\n' '{"id":5,"result":{"thread":{"id":\(responseThreadID),"turns":[{"id":\(responseTurnID),"status":\(persistedStatus)\(persistedErrorField),"items":[{"type":"agentMessage","id":"persisted-final","text":\(persistedFinal),"phase":"final_answer"},{"type":"agentMessage","id":"persisted-tail","text":"PERSISTED_TAIL","phase":"commentary"}]}]}}}'
                  ;;
                *'"id":6'*)
                  printf '%s\\n' '{"id":6,"result":{"thread":{"id":\(responseThreadID),"turns":[{"id":\(responseTurnID),"status":\(persistedStatus)\(persistedErrorField),"items":[{"type":"agentMessage","id":"persisted-final","text":\(persistedFinal),"phase":"final_answer"},{"type":"agentMessage","id":"persisted-tail","text":"PERSISTED_TAIL","phase":"commentary"}]}]}}}'
                  ;;
              esac
            done
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

    func requests() throws -> [[String: Any]] {
        let data = try Data(contentsOf: requestsURL)
        return try String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { line in
                let object = try JSONSerialization.jsonObject(
                    with: Data(line.utf8)
                )
                guard let request = object as? [String: Any] else {
                    throw MuError.commandFailed("Fake Codex request was not an object.")
                }
                return request
            }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func jsonString(_ value: String) -> String {
        let encoded = try! JSONSerialization.data(
            withJSONObject: [value],
            options: []
        )
        let array = String(decoding: encoded, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}
