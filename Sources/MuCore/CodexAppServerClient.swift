import Foundation

public final class CodexAppServerClient {
    public let executableURL: URL

    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let condition = NSCondition()
    private let parsingQueue = DispatchQueue(label: "com.mu.codex-app-server.parser")
    private let turnReadFallbackInterval: TimeInterval = 2
    private let turnReadFallbackTimeout: TimeInterval = 2

    private var readBuffer = Data()
    private var nextRequestID = 1
    private var responses: [Int: Response] = [:]
    private var completedTurns: [String: TurnCompletion] = [:]
    private var agentMessages: [String: [String: AgentMessage]] = [:]
    private var agentMessageOrder: [String: [String]] = [:]
    private var visibleTextObservers:
        [String: @Sendable (String) -> Void] = [:]
    private var processFailure: String?
    private var initializedResult: [String: Any]?

    private struct Response {
        var result: Any?
        var error: String?
    }

    private struct TurnCompletion {
        var status: String
        var errorMessage: String?
    }

    private struct AgentMessage {
        var text: String
        var phase: String?
    }

    public init(executableURL: URL) {
        self.executableURL = executableURL
    }

    deinit {
        stop()
    }

    public func start() throws -> [String: Any] {
        guard !process.isRunning else {
            return initializedResult ?? [:]
        }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw MuError.commandFailed("Codex executable is unavailable at \(executableURL.path)")
        }

        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.parsingQueue.async {
                self?.consume(data)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { _ in
            // Drain diagnostics so the child process cannot block on a full stderr pipe.
        }
        process.terminationHandler = { [weak self] process in
            guard process.terminationStatus != 0 else { return }
            self?.condition.lock()
            self?.processFailure = "Codex App Server exited with status \(process.terminationStatus)."
            self?.condition.broadcast()
            self?.condition.unlock()
        }

        do {
            try process.run()
        } catch {
            throw MuError.commandFailed("Could not launch Codex App Server: \(error.localizedDescription)")
        }

        let initialize = try request(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "mu",
                    "title": "Mu Runtime Control Plane",
                    "version": "0.4.0"
                ],
                "capabilities": [
                    "experimentalApi": true,
                    "requestAttestation": false,
                    "mcpServerOpenaiFormElicitation": false,
                    "optOutNotificationMethods": []
                ]
            ],
            timeout: 15
        )
        initializedResult = initialize
        try notify(method: "initialized")
        return initialize
    }

    public func probe() throws -> CodexProbeResult {
        let initialize = try start()
        let account = try request(
            method: "account/read",
            params: ["refreshToken": false],
            timeout: 15
        )
        let threads = try request(
            method: "thread/list",
            params: [
                "limit": 5,
                "sortKey": "updated_at",
                "sortDirection": "desc",
                "archived": false,
                "useStateDbOnly": true
            ],
            timeout: 15
        )
        let data = threads["data"] as? [[String: Any]] ?? []
        let accountValue = account["account"]
        let signedIn = accountValue != nil && !(accountValue is NSNull)
        return CodexProbeResult(
            userAgent: initialize["userAgent"] as? String ?? "Codex App Server",
            platformOS: initialize["platformOs"] as? String ?? "unknown",
            signedIn: signedIn,
            observedThreadCount: data.count
        )
    }

    public func listHistory(
        workspacePath: String,
        timeout: TimeInterval = 30
    ) throws -> [ExternalConversationCandidate] {
        let canonicalWorkspacePath = try Self.canonicalWorkspacePath(workspacePath)
        _ = try start()

        var candidatesBySessionID: [String: ExternalConversationCandidate] = [:]
        for isArchived in [false, true] {
            let candidates = try listHistory(
                canonicalWorkspacePath: canonicalWorkspacePath,
                isArchived: isArchived,
                timeout: timeout
            )
            for candidate in candidates {
                candidatesBySessionID[candidate.nativeSessionID] = candidate
            }
        }

        return candidatesBySessionID.values.sorted { lhs, rhs in
            let lhsDate = lhs.updatedAt ?? lhs.createdAt ?? .distantPast
            let rhsDate = rhs.updatedAt ?? rhs.createdAt ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.nativeSessionID < rhs.nativeSessionID
        }
    }

    public func readHistory(
        sessionID: String,
        workspacePath: String,
        timeout: TimeInterval = 30
    ) throws -> [ExternalConversationMessage] {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else {
            throw MuError.commandFailed("A Codex session ID is required.")
        }
        let canonicalWorkspacePath = try Self.canonicalWorkspacePath(workspacePath)
        _ = try start()

        let response = try request(
            method: "thread/read",
            params: [
                "threadId": normalizedSessionID,
                "includeTurns": true
            ],
            timeout: timeout
        )
        guard let thread = response["thread"] as? [String: Any],
              let responseSessionID = thread["id"] as? String,
              responseSessionID == normalizedSessionID else {
            throw MuError.commandFailed("Codex thread/read returned a different or missing thread.")
        }
        guard let responseWorkspacePath = thread["cwd"] as? String else {
            throw MuError.commandFailed("Codex thread/read returned no workspace path.")
        }
        let canonicalResponseWorkspacePath = try Self.canonicalWorkspacePath(responseWorkspacePath)
        guard canonicalResponseWorkspacePath == canonicalWorkspacePath else {
            throw MuError.commandFailed(
                "Codex session \(normalizedSessionID) belongs to a different workspace."
            )
        }
        return Self.parseHistoryMessages(
            inThreadReadResponse: response,
            sessionID: normalizedSessionID
        )
    }

    public static func parseHistoryMessages(
        inThreadReadResponse response: [String: Any],
        sessionID: String
    ) -> [ExternalConversationMessage] {
        guard let thread = response["thread"] as? [String: Any],
              let turns = thread["turns"] as? [[String: Any]] else {
            return []
        }

        var messages: [ExternalConversationMessage] = []
        for (turnIndex, turn) in turns.enumerated() {
            let turnID = nonEmptyString(turn["id"]) ?? "turn-\(turnIndex)"
            let startedAt = date(from: turn["startedAt"])
            let completedAt = date(from: turn["completedAt"]) ?? startedAt
            guard let items = turn["items"] as? [[String: Any]] else {
                continue
            }

            for (itemIndex, item) in items.enumerated() {
                let itemID = nonEmptyString(item["id"])
                    ?? "\(sessionID):\(turnID):item-\(itemIndex)"
                switch item["type"] as? String {
                case "userMessage":
                    let text = userMessageText(from: item)
                    guard containsVisibleText(text) else { continue }
                    messages.append(
                        ExternalConversationMessage(
                            nativeItemID: itemID,
                            ordinal: messages.count,
                            role: .user,
                            text: text,
                            createdAt: startedAt
                        )
                    )
                case "agentMessage":
                    guard let text = item["text"] as? String,
                          containsVisibleText(text) else {
                        continue
                    }
                    let phase: String
                    if let rawPhase = item["phase"] as? String {
                        guard rawPhase == "commentary" || rawPhase == "final_answer" else {
                            continue
                        }
                        phase = rawPhase
                    } else {
                        // Older Codex rollouts did not persist a phase. Their visible
                        // assistant message is retained as a final answer for continuity.
                        phase = "final_answer"
                    }
                    messages.append(
                        ExternalConversationMessage(
                            nativeItemID: itemID,
                            ordinal: messages.count,
                            role: .assistant,
                            text: text,
                            phase: phase,
                            createdAt: completedAt
                        )
                    )
                default:
                    // Reasoning, tool calls/results, plans, and system-generated
                    // items are deliberately outside Mu's portable chat context.
                    continue
                }
            }
        }
        return messages
    }

    public func runReadOnlyReplan(
        checkpoint: CheckpointRecord,
        task: TaskRecord,
        timeout: TimeInterval = 600,
        onThreadStarted: (String) throws -> Void = { _ in },
        onTurnStarted: (String, String) throws -> Void = { _, _ in }
    ) throws -> CodexReplanResult {
        let result = try runReadOnlyTurn(
            task: task,
            developerInstructions:
                "You are the receiving planner in a runtime-neutral Handoff. "
                + "Do not execute commands, use tools, or mutate artifacts. "
                + "Reconstruct a plan only from the sealed portable state.",
            prompt: try replanPrompt(checkpoint: checkpoint),
            clientUserMessageID: nil,
            threadName: nil,
            reconcileHistory: false,
            timeout: timeout,
            onThreadStarted: onThreadStarted,
            onTurnStarted: onTurnStarted
        )
        guard !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MuError.commandFailed("Codex completed the Replan without an agent message.")
        }
        return CodexReplanResult(
            threadID: result.threadID,
            turnID: result.turnID,
            output: result.output,
            status: result.status
        )
    }

    public func runReadOnlyTask(
        task: TaskRecord,
        agent: AgentIdentity?,
        contextPack: ProjectContextPackRecord? = nil,
        promptOverride: String? = nil,
        clientUserMessageID: String,
        timeout: TimeInterval = 600,
        onThreadStarted: (String) throws -> Void = { _ in },
        onTurnStarted: (String, String) throws -> Void = { _, _ in },
        onVisibleText:
            @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> CodexTurnResult {
        try runReadOnlyTurn(
            task: task,
            developerInstructions: taskDeveloperInstructions(agent: agent),
            prompt:
                promptOverride
                ?? contextPack?.renderedMarkdown
                ?? taskPrompt(task),
            clientUserMessageID: clientUserMessageID,
            threadName: task.title,
            reconcileHistory: true,
            timeout: timeout,
            onThreadStarted: onThreadStarted,
            onTurnStarted: onTurnStarted,
            onVisibleText: onVisibleText
        )
    }

    /// Continues a Mu-owned persistent Codex thread without importing the
    /// thread transcript as Project state. The prompt is a bounded Project
    /// message and the official App Server remains the Runtime authority.
    public func runReadOnlyContinuation(
        threadID: String,
        task: TaskRecord,
        prompt: String,
        clientUserMessageID: String,
        timeout: TimeInterval = 600,
        onTurnStarted:
            (String, String) throws -> Void = { _, _ in },
        onVisibleText:
            @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> CodexTurnResult {
        let normalizedThreadID = threadID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedThreadID.isEmpty else {
            throw MuError.invalidTransition(
                "Codex continuation requires a native thread ID."
            )
        }
        let normalizedPrompt = prompt.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedPrompt.isEmpty else {
            throw MuError.invalidTransition(
                "Codex continuation cannot be empty."
            )
        }
        _ = try start()
        let threadRead = try request(
            method: "thread/read",
            params: [
                "threadId": normalizedThreadID,
                "includeTurns": false
            ],
            timeout: 30
        )
        guard let thread =
            threadRead["thread"] as? [String: Any],
              thread["id"] as? String
                == normalizedThreadID,
              let cwd = thread["cwd"] as? String,
              try Self.canonicalWorkspacePath(cwd)
                == Self.canonicalWorkspacePath(
                    task.repositoryPath
                ) else {
            throw MuError.invalidTransition(
                "Codex thread does not belong to the exact Project workspace."
            )
        }

        let turnResponse = try request(
            method: "turn/start",
            params: [
                "threadId": normalizedThreadID,
                "input": [[
                    "type": "text",
                    "text": normalizedPrompt,
                    "text_elements": []
                ]],
                "cwd": task.repositoryPath,
                "runtimeWorkspaceRoots": [
                    task.repositoryPath
                ],
                "approvalPolicy": "never",
                "approvalsReviewer": "user",
                "sandboxPolicy": [
                    "type": "readOnly",
                    "networkAccess": false
                ],
                "clientUserMessageId":
                    clientUserMessageID
            ],
            timeout: 30
        )
        guard let turn =
            turnResponse["turn"] as? [String: Any],
              let turnID = turn["id"] as? String else {
            throw MuError.commandFailed(
                "Codex turn/start returned no turn ID."
            )
        }
        setVisibleTextObserver(
            onVisibleText,
            for: turnID
        )
        defer {
            setVisibleTextObserver(nil, for: turnID)
        }
        try onTurnStarted(normalizedThreadID, turnID)
        let completion = try waitForTurn(
            threadID: normalizedThreadID,
            turnID: turnID,
            timeout: timeout
        )
        var output = agentMessage(for: turnID)
        var historyReconciled = false
        if let history = try? request(
            method: "thread/read",
            params: [
                "threadId": normalizedThreadID,
                "includeTurns": true
            ],
            timeout: 30
        ) {
            historyReconciled = true
            let persisted = Self.agentMessage(
                inThreadReadResponse: history,
                turnID: turnID
            )
            if !persisted.isEmpty {
                output = persisted
            }
        }
        if completion.status == "completed",
           output.trimmingCharacters(
               in: .whitespacesAndNewlines
           ).isEmpty {
            throw MuError.commandFailed(
                "Codex completed without an agent message."
            )
        }
        return CodexTurnResult(
            threadID: normalizedThreadID,
            turnID: turnID,
            output: output,
            status: completion.status,
            errorMessage: completion.errorMessage,
            historyReconciled: historyReconciled
        )
    }

    public func interrupt(
        threadID: String,
        turnID: String
    ) throws {
        _ = try start()
        _ = try request(
            method: "turn/interrupt",
            params: [
                "threadId": threadID,
                "turnId": turnID
            ],
            timeout: 15
        )
    }

    private func runReadOnlyTurn(
        task: TaskRecord,
        developerInstructions: String,
        prompt: String,
        clientUserMessageID: String?,
        threadName: String?,
        reconcileHistory: Bool,
        timeout: TimeInterval,
        onThreadStarted: (String) throws -> Void = { _ in },
        onTurnStarted: (String, String) throws -> Void = { _, _ in },
        onVisibleText:
            @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> CodexTurnResult {
        _ = try start()
        let threadResponse = try request(
            method: "thread/start",
            params: [
                "cwd": task.repositoryPath,
                "runtimeWorkspaceRoots": [task.repositoryPath],
                "approvalPolicy": "never",
                "approvalsReviewer": "user",
                "sandbox": "read-only",
                "ephemeral": false,
                "serviceName": "Mu",
                "developerInstructions": developerInstructions
            ],
            timeout: 30
        )
        guard let thread = threadResponse["thread"] as? [String: Any],
              let threadID = thread["id"] as? String else {
            throw MuError.commandFailed("Codex thread/start returned no thread ID.")
        }
        try onThreadStarted(threadID)
        if let threadName {
            let normalizedName = threadName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedName.isEmpty {
                _ = try? request(
                    method: "thread/name/set",
                    params: ["threadId": threadID, "name": normalizedName],
                    timeout: 10
                )
            }
        }

        var turnParams: [String: Any] = [
            "threadId": threadID,
            "input": [[
                "type": "text",
                "text": prompt,
                "text_elements": []
            ]],
            "cwd": task.repositoryPath,
            "runtimeWorkspaceRoots": [task.repositoryPath],
            "approvalPolicy": "never",
            "approvalsReviewer": "user",
            "sandboxPolicy": [
                "type": "readOnly",
                "networkAccess": false
            ]
        ]
        if let clientUserMessageID {
            turnParams["clientUserMessageId"] = clientUserMessageID
        }
        let turnResponse = try request(
            method: "turn/start",
            params: turnParams,
            timeout: 30
        )
        guard let turn = turnResponse["turn"] as? [String: Any],
              let turnID = turn["id"] as? String else {
            throw MuError.commandFailed("Codex turn/start returned no turn ID.")
        }
        setVisibleTextObserver(
            onVisibleText,
            for: turnID
        )
        defer {
            setVisibleTextObserver(nil, for: turnID)
        }
        try onTurnStarted(threadID, turnID)

        let completion = try waitForTurn(
            threadID: threadID,
            turnID: turnID,
            timeout: timeout
        )
        var output = agentMessage(for: turnID)
        var historyReconciled = false
        if reconcileHistory,
           let history = try? request(
               method: "thread/read",
               params: ["threadId": threadID, "includeTurns": true],
               timeout: 30
           ) {
            historyReconciled = true
            let persistedOutput = Self.agentMessage(
                inThreadReadResponse: history,
                turnID: turnID
            )
            if !persistedOutput.isEmpty {
                output = persistedOutput
            }
        }
        if completion.status == "completed",
           output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MuError.commandFailed("Codex completed without an agent message.")
        }
        return CodexTurnResult(
            threadID: threadID,
            turnID: turnID,
            output: output,
            status: completion.status,
            errorMessage: completion.errorMessage,
            historyReconciled: historyReconciled
        )
    }

    public func stop() {
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? inputPipe.fileHandleForWriting.close()
    }

    private func request(
        method: String,
        params: [String: Any]?,
        timeout: TimeInterval
    ) throws -> [String: Any] {
        condition.lock()
        let requestID = nextRequestID
        nextRequestID += 1
        condition.unlock()

        var message: [String: Any] = ["method": method, "id": requestID]
        if let params { message["params"] = params }
        try write(message)

        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while responses[requestID] == nil && processFailure == nil {
            if !condition.wait(until: deadline) { break }
        }
        if let processFailure {
            throw MuError.commandFailed(processFailure)
        }
        guard let response = responses.removeValue(forKey: requestID) else {
            throw MuError.commandFailed("Timed out waiting for \(method).")
        }
        if let error = response.error {
            throw MuError.commandFailed("\(method): \(error)")
        }
        return response.result as? [String: Any] ?? [:]
    }

    private func notify(method: String, params: [String: Any]? = nil) throws {
        var message: [String: Any] = ["method": method]
        if let params { message["params"] = params }
        try write(message)
    }

    private func write(_ message: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(message) else {
            throw MuError.commandFailed("Could not encode Codex protocol message.")
        }
        var data = try JSONSerialization.data(withJSONObject: message, options: [])
        data.append(0x0A)
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw MuError.commandFailed("Could not write to Codex App Server: \(error.localizedDescription)")
        }
    }

    private func consume(_ data: Data) {
        readBuffer.append(data)
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            let line = readBuffer.prefix(upTo: newline)
            readBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let message = object as? [String: Any] else {
                continue
            }
            handle(message)
        }
    }

    private func handle(_ message: [String: Any]) {
        if let id = Self.integerID(message["id"]), message["method"] == nil {
            let errorMessage: String?
            if let error = message["error"] as? [String: Any] {
                errorMessage = error["message"] as? String ?? String(describing: error)
            } else {
                errorMessage = nil
            }
            condition.lock()
            responses[id] = Response(result: message["result"], error: errorMessage)
            condition.broadcast()
            condition.unlock()
            return
        }

        guard let method = message["method"] as? String,
              let params = message["params"] as? [String: Any] else {
            return
        }
        if method == "item/completed",
           let turnID = params["turnId"] as? String,
           let item = params["item"] as? [String: Any],
           item["type"] as? String == "agentMessage",
           let itemID = item["id"] as? String,
           let text = item["text"] as? String {
            let callback: (@Sendable (String) -> Void)?
            let visibleText: String
            condition.lock()
            registerMessageItem(itemID, for: turnID)
            agentMessages[turnID, default: [:]][itemID] = AgentMessage(
                text: text,
                phase: item["phase"] as? String
            )
            callback = visibleTextObservers[turnID]
            visibleText = Self.preferredAgentMessage(
                (agentMessageOrder[turnID] ?? []).compactMap {
                    agentMessages[turnID]?[$0]
                }
            )
            condition.broadcast()
            condition.unlock()
            if !visibleText.isEmpty {
                callback?(visibleText)
            }
        } else if method == "item/agentMessage/delta",
                  let turnID = params["turnId"] as? String,
                  let itemID = params["itemId"] as? String,
                  let delta = params["delta"] as? String {
            let callback: (@Sendable (String) -> Void)?
            let visibleText: String
            condition.lock()
            registerMessageItem(itemID, for: turnID)
            var item = agentMessages[turnID, default: [:]][itemID]
                ?? AgentMessage(text: "", phase: nil)
            item.text.append(delta)
            agentMessages[turnID, default: [:]][itemID] = item
            callback = visibleTextObservers[turnID]
            visibleText = Self.preferredAgentMessage(
                (agentMessageOrder[turnID] ?? []).compactMap {
                    agentMessages[turnID]?[$0]
                }
            )
            condition.unlock()
            if !visibleText.isEmpty {
                callback?(visibleText)
            }
        } else if method == "turn/completed",
                  let threadID = params["threadId"] as? String,
                  let turn = params["turn"] as? [String: Any],
                  let turnID = turn["id"] as? String {
            let errorMessage = Self.turnErrorMessage(turn["error"])
            let rawStatus = turn["status"] as? String ?? "completed"
            let completion = Self.terminalCompletion(
                status: rawStatus,
                errorMessage: errorMessage
            ) ?? TurnCompletion(status: rawStatus, errorMessage: errorMessage)
            condition.lock()
            completedTurns["\(threadID):\(turnID)"] = completion
            condition.broadcast()
            condition.unlock()
        }
    }

    private func registerMessageItem(_ itemID: String, for turnID: String) {
        if !(agentMessageOrder[turnID] ?? []).contains(itemID) {
            agentMessageOrder[turnID, default: []].append(itemID)
        }
    }

    private func setVisibleTextObserver(
        _ observer: (@Sendable (String) -> Void)?,
        for turnID: String
    ) {
        condition.lock()
        visibleTextObservers[turnID] = observer
        condition.unlock()
    }

    private func waitForTurn(
        threadID: String,
        turnID: String,
        timeout: TimeInterval
    ) throws -> TurnCompletion {
        let key = "\(threadID):\(turnID)"
        let deadline = Date().addingTimeInterval(timeout)
        var nextFallbackRead = Date().addingTimeInterval(turnReadFallbackInterval)

        while true {
            condition.lock()
            if let completion = completedTurns[key] {
                condition.unlock()
                return completion
            }
            if let processFailure {
                condition.unlock()
                throw MuError.commandFailed(processFailure)
            }

            let now = Date()
            guard now < deadline else {
                condition.unlock()
                throw MuError.commandFailed("Timed out waiting for Codex turn completion.")
            }

            let nextWake = min(deadline, nextFallbackRead)
            _ = condition.wait(until: nextWake)
            if let completion = completedTurns[key] {
                condition.unlock()
                return completion
            }
            if let processFailure {
                condition.unlock()
                throw MuError.commandFailed(processFailure)
            }
            condition.unlock()

            guard Date() >= nextFallbackRead else {
                continue
            }

            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw MuError.commandFailed("Timed out waiting for Codex turn completion.")
            }

            // `turn/completed` remains the primary path. Some app-server
            // interruptions update persisted thread state without emitting that
            // notification, so inspect the authoritative thread at a low cadence.
            // Poll failures are deliberately non-fatal; the notification path can
            // still finish the turn before the caller's overall deadline.
            let response = try? request(
                method: "thread/read",
                params: ["threadId": threadID, "includeTurns": true],
                timeout: min(turnReadFallbackTimeout, remaining)
            )

            condition.lock()
            let notifiedCompletion = completedTurns[key]
            condition.unlock()
            if let notifiedCompletion {
                return notifiedCompletion
            }

            if let response,
               let persistedCompletion = Self.turnCompletion(
                   inThreadReadResponse: response,
                   threadID: threadID,
                   turnID: turnID
               ) {
                condition.lock()
                if completedTurns[key] == nil {
                    completedTurns[key] = persistedCompletion
                    condition.broadcast()
                }
                let resolvedCompletion = completedTurns[key] ?? persistedCompletion
                condition.unlock()
                return resolvedCompletion
            }

            nextFallbackRead = Date().addingTimeInterval(turnReadFallbackInterval)
        }
    }

    private static func turnCompletion(
        inThreadReadResponse response: [String: Any],
        threadID: String,
        turnID: String
    ) -> TurnCompletion? {
        guard let thread = response["thread"] as? [String: Any],
              thread["id"] as? String == threadID,
              let turns = thread["turns"] as? [[String: Any]],
              let turn = turns.first(where: { $0["id"] as? String == turnID }),
              let status = turn["status"] as? String else {
            return nil
        }
        return terminalCompletion(
            status: status,
            errorMessage: turnErrorMessage(turn["error"])
        )
    }

    private static func terminalCompletion(
        status: String,
        errorMessage: String?
    ) -> TurnCompletion? {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "completed":
            return TurnCompletion(status: "completed", errorMessage: errorMessage)
        case "failed":
            return TurnCompletion(status: "failed", errorMessage: errorMessage)
        case "interrupted":
            return TurnCompletion(status: "interrupted", errorMessage: errorMessage)
        case "cancelled", "canceled":
            // Mu's control-plane terminal model uses `interrupted` for a
            // user/runtime cancellation.
            return TurnCompletion(status: "interrupted", errorMessage: errorMessage)
        default:
            return nil
        }
    }

    private static func turnErrorMessage(_ value: Any?) -> String? {
        if let error = value as? [String: Any] {
            return error["message"] as? String ?? String(describing: error)
        }
        if let error = value as? String,
           !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return error
        }
        return nil
    }

    private func agentMessage(for turnID: String) -> String {
        condition.lock()
        defer { condition.unlock() }
        let messages = (agentMessageOrder[turnID] ?? []).compactMap {
            agentMessages[turnID]?[$0]
        }
        return Self.preferredAgentMessage(messages)
    }

    private static func preferredAgentMessage(_ messages: [AgentMessage]) -> String {
        if let final = messages.last(where: { $0.phase == "final_answer" }) {
            return final.text
        }
        if let phaseUnknown = messages.last(where: { $0.phase == nil }) {
            return phaseUnknown.text
        }
        return messages.last?.text ?? ""
    }

    private static func agentMessage(
        inThreadReadResponse response: [String: Any],
        turnID: String
    ) -> String {
        guard let thread = response["thread"] as? [String: Any],
              let turns = thread["turns"] as? [[String: Any]],
              let turn = turns.first(where: { $0["id"] as? String == turnID }),
              let items = turn["items"] as? [[String: Any]] else {
            return ""
        }
        let messages = items.compactMap { item -> AgentMessage? in
            guard item["type"] as? String == "agentMessage",
                  let text = item["text"] as? String else {
                return nil
            }
            return AgentMessage(text: text, phase: item["phase"] as? String)
        }
        return preferredAgentMessage(messages)
    }

    private func listHistory(
        canonicalWorkspacePath: String,
        isArchived: Bool,
        timeout: TimeInterval
    ) throws -> [ExternalConversationCandidate] {
        var cursor: String?
        var observedCursors = Set<String>()
        var candidates: [ExternalConversationCandidate] = []

        repeat {
            var params: [String: Any] = [
                "limit": 100,
                "sortKey": "updated_at",
                "sortDirection": "desc",
                "archived": isArchived,
                "cwd": canonicalWorkspacePath,
                "sourceKinds": ["cli", "vscode", "exec", "appServer"]
            ]
            if let cursor {
                params["cursor"] = cursor
            }
            let response = try request(
                method: "thread/list",
                params: params,
                timeout: timeout
            )
            let threads = response["data"] as? [[String: Any]] ?? []
            candidates.append(
                contentsOf: threads.compactMap {
                    Self.historyCandidate(
                        from: $0,
                        providerInstanceKey: historyProviderInstanceKey,
                        canonicalWorkspacePath: canonicalWorkspacePath,
                        isArchived: isArchived
                    )
                }
            )

            guard let nextCursor = Self.nonEmptyString(response["nextCursor"]) else {
                cursor = nil
                continue
            }
            guard nextCursor != cursor, observedCursors.insert(nextCursor).inserted else {
                throw MuError.commandFailed("Codex thread/list returned a repeated pagination cursor.")
            }
            cursor = nextCursor
        } while cursor != nil

        return candidates
    }

    private var historyProviderInstanceKey: String {
        "codex-app-server:"
            + executableURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func historyCandidate(
        from thread: [String: Any],
        providerInstanceKey: String,
        canonicalWorkspacePath: String,
        isArchived: Bool
    ) -> ExternalConversationCandidate? {
        guard let nativeSessionID = nonEmptyString(thread["id"]),
              let threadWorkspacePath = nonEmptyString(thread["cwd"]),
              let canonicalThreadWorkspacePath = try? self.canonicalWorkspacePath(
                  threadWorkspacePath
              ),
              canonicalThreadWorkspacePath == canonicalWorkspacePath else {
            return nil
        }

        let explicitName = nonEmptyString(thread["name"])
        let preview = nonEmptyString(thread["preview"])
        let title = explicitName
            ?? preview
            ?? "Codex task \(nativeSessionID.prefix(8))"
        let agentLabel = nonEmptyString(thread["agentNickname"])
            ?? nonEmptyString(thread["agentRole"])
        let sourceLocation = nonEmptyString(thread["path"])
        let providerPrefix = "codex-app-server:"
        let executablePath = providerInstanceKey.hasPrefix(providerPrefix)
            ? String(providerInstanceKey.dropFirst(providerPrefix.count))
            : nil
        let nativeSource = nativeThreadSource(thread["source"])
        return ExternalConversationCandidate(
            provider: .codex,
            providerInstanceKey: providerInstanceKey,
            nativeSessionID: nativeSessionID,
            title: title,
            canonicalWorkspacePath: canonicalWorkspacePath,
            createdAt: date(from: thread["createdAt"]),
            updatedAt: date(from: thread["updatedAt"]),
            isArchived: isArchived,
            model: nil,
            agentLabel: agentLabel,
            accessKind: .vendorProtocol,
            resumability: .resumable,
            sourceLocation: sourceLocation,
            messages: [],
            runtimeInstanceIdentity: .codexHistory(
                executablePath: executablePath,
                nativeSource: nativeSource,
                nativeSessionID: nativeSessionID,
                workspacePath: canonicalWorkspacePath,
                sourceLocation: sourceLocation
            )
        )
    }

    /// Codex App Server has represented `ThreadSource` as both a string and a
    /// tagged object across protocol revisions. Preserve the vendor tag
    /// without depending on the associated payload shape.
    static func nativeThreadSource(_ rawValue: Any?) -> String? {
        if let value = nonEmptyString(rawValue) {
            return value
        }
        if let object = rawValue as? [String: Any] {
            for key in ["type", "kind", "source", "name"] {
                if let value = nonEmptyString(object[key]) {
                    return value
                }
            }
            let knownSources = [
                "appServer",
                "app_server",
                "cli",
                "exec",
                "vscode",
                "vs_code"
            ]
            if let source = knownSources.first(where: {
                object.keys.contains($0)
            }) {
                return source
            }
            if object.count == 1 {
                return object.keys.first
            }
        }
        if let values = rawValue as? [Any] {
            return values.lazy.compactMap(nativeThreadSource).first
        }
        return nil
    }

    private static func canonicalWorkspacePath(_ rawPath: String) throws -> String {
        let expandedPath = (rawPath as NSString).expandingTildeInPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard expandedPath.hasPrefix("/") else {
            throw MuError.commandFailed("Workspace path must be absolute.")
        }
        return URL(fileURLWithPath: expandedPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func userMessageText(from item: [String: Any]) -> String {
        if let text = item["content"] as? String {
            return text
        }
        guard let content = item["content"] as? [[String: Any]] else {
            return ""
        }
        return content.compactMap { input -> String? in
            guard input["type"] as? String == "text" else {
                return nil
            }
            return input["text"] as? String
        }
        .joined(separator: "\n")
    }

    private static func containsVisibleText(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else {
            return nil
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func date(from value: Any?) -> Date? {
        if value is Bool {
            return nil
        }
        if let number = value as? NSNumber {
            let rawValue = number.doubleValue
            let seconds = abs(rawValue) >= 100_000_000_000 ? rawValue / 1_000 : rawValue
            return Date(timeIntervalSince1970: seconds)
        }
        guard let string = nonEmptyString(value) else {
            return nil
        }
        if let rawValue = TimeInterval(string) {
            let seconds = abs(rawValue) >= 100_000_000_000 ? rawValue / 1_000 : rawValue
            return Date(timeIntervalSince1970: seconds)
        }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractionalFormatter.date(from: string)
            ?? ISO8601DateFormatter().date(from: string)
    }

    private func taskDeveloperInstructions(agent: AgentIdentity?) -> String {
        let identityContract: String
        if let agent {
            let tags = agent.capabilityTags.isEmpty
                ? "none"
                : agent.capabilityTags.joined(separator: ", ")
            identityContract =
                "Act as Mu agent \(agent.displayName), role \(agent.role.rawValue). "
                + "\(agent.summary) Capability tags: \(tags). "
        } else {
            identityContract = "Act as the runtime-neutral execution agent selected by Mu. "
        }
        return identityContract
            + "This is a strictly read-only task. You may inspect files and run commands only "
            + "when they cannot mutate the workspace. Do not create, edit, rename, or delete "
            + "files; do not use network access; do not request elevated permissions; and do "
            + "not perform destructive actions. If the objective requires a mutation, explain "
            + "the blocked action instead of performing it. Return a concise final answer with "
            + "the evidence you actually observed."
    }

    private func taskPrompt(_ task: TaskRecord) -> String {
        """
        Mu created this read-only execution Task.

        Title: \(task.title)
        Objective:
        \(task.objective)

        Success criteria:
        \(Self.bullets(task.successCriteria))

        Blocking constraints:
        \(Self.bullets(task.constraints))

        Pending steps:
        \(Self.bullets(task.pendingSteps))

        Repository root: \(task.repositoryPath)

        Work only within the read-only contract and report the result.
        """
    }

    private static func bullets(_ values: [String]) -> String {
        values.isEmpty ? "- None specified" : values.map { "- \($0)" }.joined(separator: "\n")
    }

    private func replanPrompt(checkpoint: CheckpointRecord) throws -> String {
        let content = try MuCoding.makeEncoder(pretty: true).encode(checkpoint.content)
        let json = String(decoding: content, as: UTF8.self)
        return
            """
            You are receiving responsibility for a development task from another runtime.

            This is a REPLAN-ONLY turn. Do not execute commands, inspect files, call tools,
            or change artifacts. Treat the Checkpoint below as sealed portable state.

            Produce:
            1. your understanding of the objective;
            2. every blocking constraint, explicitly;
            3. repository-state risks or contradictions;
            4. a numbered execution plan;
            5. verification steps;
            6. questions that truly block execution.

            Checkpoint content hash: \(checkpoint.contentHash)

            \(json)
            """
    }

    private static func integerID(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}

public enum CodexDiscovery {
    public static func executableURL() -> URL? {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex"
        ]
        return candidates
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
