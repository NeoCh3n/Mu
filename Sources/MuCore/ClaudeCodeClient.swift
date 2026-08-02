import Foundation

public struct ClaudeCodeProbeResult:
    Codable,
    Hashable,
    Sendable
{
    public var version: String
    public var loggedIn: Bool
    public var authMethod: String
    public var apiProvider: String

    public init(
        version: String,
        loggedIn: Bool,
        authMethod: String,
        apiProvider: String
    ) {
        self.version = version
        self.loggedIn = loggedIn
        self.authMethod = authMethod
        self.apiProvider = apiProvider
    }
}

public struct ClaudeCodeTurnResult:
    Codable,
    Hashable,
    Sendable
{
    public var sessionID: String
    public var output: String
    public var status: String
    public var model: String?
    public var costUSD: Double?
    public var durationMilliseconds: Int?
    public var errorMessage: String?

    public init(
        sessionID: String,
        output: String,
        status: String,
        model: String? = nil,
        costUSD: Double? = nil,
        durationMilliseconds: Int? = nil,
        errorMessage: String? = nil
    ) {
        self.sessionID = sessionID
        self.output = output
        self.status = status
        self.model = model
        self.costUSD = costUSD
        self.durationMilliseconds = durationMilliseconds
        self.errorMessage = errorMessage
    }
}

public struct ClaudeCodeStreamState:
    Hashable,
    Sendable
{
    public var sessionID: String?
    public var model: String?
    public var visibleText: String
    public var finalResult: String?
    public var status: String?
    public var costUSD: Double?
    public var durationMilliseconds: Int?
    public var errorMessage: String?

    public init(
        sessionID: String? = nil,
        model: String? = nil,
        visibleText: String = "",
        finalResult: String? = nil,
        status: String? = nil,
        costUSD: Double? = nil,
        durationMilliseconds: Int? = nil,
        errorMessage: String? = nil
    ) {
        self.sessionID = sessionID
        self.model = model
        self.visibleText = visibleText
        self.finalResult = finalResult
        self.status = status
        self.costUSD = costUSD
        self.durationMilliseconds = durationMilliseconds
        self.errorMessage = errorMessage
    }
}

/// Parser for Claude Code's documented stream-json surface. Visible text and
/// explicit tool/file receipts are retained; private thinking text is never
/// copied into the activity detail.
public final class ClaudeCodeStreamParser:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var buffer = Data()
    private var partialText = ""
    private var assistantTexts: [String: String] = [:]
    private var assistantOrder: [String] = []
    private var state = ClaudeCodeStreamState()
    private let onVisibleText: @Sendable (String) -> Void
    private let onActivity: @Sendable (RuntimeActivityEvent) -> Void
    private var pendingActivities: [RuntimeActivityEvent] = []

    public init(
        onVisibleText: @escaping @Sendable (String) -> Void = { _ in },
        onActivity: @escaping @Sendable (RuntimeActivityEvent) -> Void = { _ in }
    ) {
        self.onVisibleText = onVisibleText
        self.onActivity = onActivity
    }

    public func consume(_ data: Data) {
        var callbacks: [String] = []
        var activities: [RuntimeActivityEvent] = []
        lock.withLock {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer.prefix(upTo: newline))
                buffer.removeSubrange(...newline)
                if let text = consumeLineUnlocked(line) {
                    callbacks.append(text)
                }
                }
            activities = pendingActivities
            pendingActivities.removeAll()
        }
        for activity in activities {
            onActivity(activity)
        }
        for text in callbacks {
            onVisibleText(text)
        }
    }

    public func finish() -> ClaudeCodeStreamState {
        var callback: String?
        var activities: [RuntimeActivityEvent] = []
        let result = lock.withLock {
            if !buffer.isEmpty {
                callback = consumeLineUnlocked(buffer)
                buffer.removeAll()
            }
            activities = pendingActivities
            pendingActivities.removeAll()
            return state
        }
        for activity in activities {
            onActivity(activity)
        }
        if let callback {
            onVisibleText(callback)
        }
        return result
    }

    @discardableResult
    public func consumeLine(_ data: Data) -> String? {
        var activities: [RuntimeActivityEvent] = []
        let callback = lock.withLock {
            let result = consumeLineUnlocked(data)
            activities = pendingActivities
            pendingActivities.removeAll()
            return result
        }
        for activity in activities {
            onActivity(activity)
        }
        if let callback {
            onVisibleText(callback)
        }
        return callback
    }

    private func consumeLineUnlocked(_ data: Data) -> String? {
        guard !data.isEmpty,
              let raw = try? JSONSerialization.jsonObject(
                  with: data
              ),
              let object = raw as? [String: Any],
              let type = object["type"] as? String else {
            return nil
        }
        if let sessionID = Self.nonempty(
            object["session_id"]
        ) {
            state.sessionID = sessionID
        }
        if let model = Self.nonempty(object["model"]) {
            state.model = model
        }

        switch type {
        case "system":
            if let model = Self.nonempty(object["model"]) {
                state.model = model
            }
            return nil

        case "stream_event":
            guard let event = object["event"] as? [String: Any] else {
                return nil
            }
            if event["type"] as? String == "content_block_start",
               let block = event["content_block"] as? [String: Any],
               let activity = Self.runtimeActivity(
                   from: block,
                   status: "started"
               ) {
                pendingActivities.append(activity)
                return nil
            }
            guard event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  let text = delta["text"] as? String,
                  !text.isEmpty else {
                return nil
            }
            partialText += text
            return updateVisibleTextUnlocked()

        case "assistant":
            guard let message = object["message"]
                as? [String: Any] else {
                return nil
            }
            if let model = Self.nonempty(message["model"]) {
                state.model = model
            }
            if let blocks = message["content"] as? [[String: Any]] {
                for block in blocks {
                    if let activity = Self.runtimeActivity(
                        from: block,
                        status: "updated"
                    ) {
                        pendingActivities.append(activity)
                    }
                }
            }
            let messageID =
                Self.nonempty(message["id"])
                ?? "assistant-\(assistantOrder.count)"
            let text = Self.visibleText(
                from: message["content"]
            )
            guard !text.isEmpty else { return nil }
            if assistantTexts[messageID] == nil {
                assistantOrder.append(messageID)
            }
            assistantTexts[messageID] = text
            partialText = ""
            return updateVisibleTextUnlocked()

        case "user":
            if let message = object["message"] as? [String: Any],
               let blocks = message["content"] as? [[String: Any]] {
                for block in blocks {
                    if let activity = Self.runtimeActivity(
                        from: block,
                        status: "completed"
                    ) {
                        pendingActivities.append(activity)
                    }
                }
            }
            return nil

        case "result":
            let isError = object["is_error"] as? Bool == true
            let subtype =
                Self.nonempty(object["subtype"])
                ?? (isError ? "error" : "success")
            let result = Self.nonempty(object["result"])
            state.finalResult = result
            state.status = isError ? "failed" : subtype
            state.costUSD = Self.double(object["total_cost_usd"])
            state.durationMilliseconds = Self.integer(
                object["duration_ms"]
            )
            state.errorMessage =
                Self.nonempty(object["error"])
                ?? (isError ? result : nil)
            if let result {
                state.visibleText = result
                return result
            }
            return nil

        default:
            // Unknown provider events stay private.
            return nil
        }
    }

    private static func runtimeActivity(
        from block: [String: Any],
        status: String
    ) -> RuntimeActivityEvent? {
        let type = nonempty(block["type"])
        let id = nonempty(block["id"])
        if type == "thinking" {
            return RuntimeActivityEvent(
                id: id,
                phase: "thinking",
                status: status,
                title: "Agent reasoning",
                detail: "Claude Code reported a reasoning phase; private reasoning text is not copied into Mu."
            )
        }
        guard type == "tool_use" || type == "tool_result" else {
            return nil
        }
        let toolName = nonempty(block["name"]) ?? "tool"
        let input = (block["input"] as? [String: Any])
            ?? (block["content"] as? [String: Any])
        let path = nonempty(
            input?["file_path"]
                ?? input?["path"]
                ?? input?["filePath"]
                ?? input?["pattern"]
        ).map(Self.safeActivityText)
        let command = nonempty(input?["command"] ?? input?["cmd"])
            .map(Self.safeActivityText)
        let fileTool = [
            "read", "glob", "grep", "edit", "write", "multiedit", "notebook"
        ].contains { toolName.lowercased().hasPrefix($0) }
        let phase = fileTool ? "file" : "tool"
        let verb: String
        if status == "completed" {
            verb = fileTool ? "Read" : "Used"
        } else if status == "failed" {
            verb = "Failed"
        } else {
            verb = fileTool ? "Reading" : "Using"
        }
        let target = path ?? (command.map { "`\($0)`" } ?? toolName)
        return RuntimeActivityEvent(
            id: nonempty(block["tool_use_id"]) ?? id,
            phase: phase,
            status: status,
            title: verb + " " + target,
            detail: command ?? (path == nil ? "Tool: " + toolName : nil),
            toolName: toolName,
            path: path,
            command: command
        )
    }

    private static func safeActivityText(_ value: String) -> String {
        let redacted = value
            .replacingOccurrences(
                of: #"(?i)(sk|key|token|secret)[-_][A-Za-z0-9._-]+"#,
                with: "[redacted]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)Bearer\s+[A-Za-z0-9._-]+"#,
                with: "Bearer [redacted]",
                options: .regularExpression
            )
        return redacted.count > 240
            ? String(redacted.prefix(237)) + "…"
            : redacted
    }

    private func updateVisibleTextUnlocked() -> String? {
        let completed = assistantOrder.compactMap {
            assistantTexts[$0]
        }.filter { !$0.isEmpty }
        let text: String
        if completed.isEmpty {
            text = partialText
        } else {
            text = completed.joined(separator: "\n\n")
                + (partialText.isEmpty ? "" : "\n\n\(partialText)")
        }
        guard text != state.visibleText else { return nil }
        state.visibleText = text
        return text
    }

    private static func visibleText(from value: Any?) -> String {
        if let text = value as? String {
            return text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        }
        guard let blocks = value as? [Any] else { return "" }
        return blocks.compactMap { block -> String? in
            guard let object = block as? [String: Any],
                  object["type"] as? String == "text",
                  let text = object["text"] as? String else {
                return nil
            }
            return text
        }.filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonempty(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let text = value as? String {
            return Double(text)
        }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let text = value as? String {
            return Int(text)
        }
        return nil
    }
}

public final class ClaudeCodeClient:
    @unchecked Sendable
{
    public let executableURL: URL

    private let lock = NSLock()
    private var activeProcess: Process?
    private var wasInterrupted = false

    public init(executableURL: URL) {
        self.executableURL = executableURL
    }

    public func probe() throws -> ClaudeCodeProbeResult {
        guard FileManager.default.isExecutableFile(
            atPath: executableURL.path
        ) else {
            throw MuError.commandFailed(
                "Claude Code executable is unavailable at "
                    + executableURL.path
            )
        }
        let versionCapture = try ProcessCapture.run(
            executableURL: executableURL,
            arguments: ["--version"]
        )
        guard versionCapture.terminationStatus == 0 else {
            throw MuError.commandFailed(
                Self.errorText(
                    capture: versionCapture,
                    fallback: "Claude Code --version failed."
                )
            )
        }
        let versionText = String(
            decoding: versionCapture.standardOutput,
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let version = versionText.split(separator: " ").first.map(
            String.init
        ) ?? versionText

        let authCapture = try ProcessCapture.run(
            executableURL: executableURL,
            arguments: ["auth", "status", "--json"]
        )
        let authData = authCapture.standardOutput.isEmpty
            ? authCapture.standardError
            : authCapture.standardOutput
        let authObject =
            (try? JSONSerialization.jsonObject(
                with: authData
            )) as? [String: Any]
        let loggedIn = authObject?["loggedIn"] as? Bool ?? false
        return ClaudeCodeProbeResult(
            version: version.isEmpty ? "unknown" : version,
            loggedIn: loggedIn,
            authMethod:
                authObject?["authMethod"] as? String
                ?? "unknown",
            apiProvider:
                authObject?["apiProvider"] as? String
                ?? "unknown"
        )
    }

    public func runReadOnlyTask(
        task: TaskRecord,
        contextPack: ProjectContextPackRecord,
        sessionID: String = UUID().uuidString.lowercased(),
        resumeSessionID: String? = nil,
        promptOverride: String? = nil,
        onSessionStarted:
            @escaping @Sendable (String) throws -> Void = { _ in },
        onVisibleText:
            @escaping @Sendable (String) -> Void = { _ in },
        onActivity:
            @escaping @Sendable (RuntimeActivityEvent) -> Void = { _ in }
    ) throws -> ClaudeCodeTurnResult {
        guard FileManager.default.isExecutableFile(
            atPath: executableURL.path
        ) else {
            throw MuError.commandFailed(
                "Claude Code executable is unavailable at "
                    + executableURL.path
            )
        }
        let normalizedSessionID =
            (resumeSessionID ?? sessionID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: normalizedSessionID) != nil else {
            throw MuError.invalidTransition(
                "Claude Code requires a valid native session UUID."
            )
        }

        let process = Process()
        process.executableURL = executableURL
        process.currentDirectoryURL = URL(
            fileURLWithPath: task.repositoryPath,
            isDirectory: true
        )
        process.arguments = Self.arguments(
            task: task,
            contextPack: contextPack,
            sessionID: sessionID,
            resumeSessionID: resumeSessionID,
            promptOverride: promptOverride
        )
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let parser = ClaudeCodeStreamParser(
            onVisibleText: onVisibleText,
            onActivity: onActivity
        )
        let errorData = LockedClaudeData()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let handle = outputPipe.fileHandleForReading
            while true {
                let data = handle.availableData
                guard !data.isEmpty else { break }
                parser.consume(data)
            }
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            errorData.store(
                errorPipe.fileHandleForReading.readDataToEndOfFile()
            )
            readers.leave()
        }

        lock.withLock {
            activeProcess = process
            wasInterrupted = false
        }
        do {
            try process.run()
            try onSessionStarted(normalizedSessionID)
        } catch {
            lock.withLock {
                activeProcess = nil
            }
            throw error
        }
        process.waitUntilExit()
        readers.wait()
        let stream = parser.finish()
        let interrupted = lock.withLock {
            let value = wasInterrupted
            activeProcess = nil
            return value
        }
        let stderr = String(
            decoding: errorData.value,
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let finalSessionID =
            stream.sessionID ?? normalizedSessionID
        let output =
            stream.finalResult
            ?? stream.visibleText
        if interrupted {
            return ClaudeCodeTurnResult(
                sessionID: finalSessionID,
                output: output,
                status: "cancelled",
                model: stream.model,
                costUSD: stream.costUSD,
                durationMilliseconds:
                    stream.durationMilliseconds,
                errorMessage: "Interrupted in Mu."
            )
        }
        guard process.terminationStatus == 0,
              stream.status != "failed" else {
            let errorMessage =
                stream.errorMessage
                ?? (stderr.isEmpty
                    ? "Claude Code exited with status "
                        + "\(process.terminationStatus)."
                    : stderr)
            throw MuError.commandFailed(errorMessage)
        }
        guard !output.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw MuError.commandFailed(
                "Claude Code completed without a visible response."
            )
        }
        return ClaudeCodeTurnResult(
            sessionID: finalSessionID,
            output: output,
            status: stream.status ?? "success",
            model: stream.model,
            costUSD: stream.costUSD,
            durationMilliseconds:
                stream.durationMilliseconds,
            errorMessage: stream.errorMessage
        )
    }

    public func interrupt() {
        lock.withLock {
            wasInterrupted = true
            if activeProcess?.isRunning == true {
                activeProcess?.terminate()
            }
        }
    }

    public static func arguments(
        task: TaskRecord,
        contextPack: ProjectContextPackRecord,
        sessionID: String,
        resumeSessionID: String?,
        promptOverride: String?
    ) -> [String] {
        var values = [
            "--print",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-mode", "plan",
            "--tools", "Read,Glob,Grep",
            "--disallowedTools",
            "Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch",
            "--append-system-prompt",
            "You are an Agent Actor working through Mu. "
                + "Treat the supplied Context Pack as the bounded Project "
                + "contract. Stay read-only, do not use external network, "
                + "do not expose private thinking, and return a reviewable "
                + "result with evidence.",
            "--name", "Mu · \(task.title)"
        ]
        if let resumeSessionID {
            values.append(contentsOf: [
                "--resume",
                resumeSessionID
            ])
        } else {
            values.append(contentsOf: [
                "--session-id",
                sessionID
            ])
        }
        let prompt = promptOverride
            ?? contextPack.renderedMarkdown
        values.append(prompt)
        return values
    }

    private static func errorText(
        capture: ProcessCapture,
        fallback: String
    ) -> String {
        let stderr = String(
            decoding: capture.standardError,
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = String(
            decoding: capture.standardOutput,
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        if !stdout.isEmpty { return stdout }
        return fallback
    }
}

public enum ClaudeCodeDiscovery {
    public static func executableURL(
        environment: [String: String] =
            ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        let explicitKeys = [
            "MU_CLAUDE_EXECUTABLE",
            "CLAUDE_CODE_EXECUTABLE"
        ]
        for key in explicitKeys {
            if let value = environment[key]?
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
               !value.isEmpty,
               fileManager.isExecutableFile(atPath: value) {
                return URL(fileURLWithPath: value)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
            }
        }

        let home = fileManager.homeDirectoryForCurrentUser
        var candidates = [
            home.appendingPathComponent(
                ".local/bin/claude"
            ).path,
            home.appendingPathComponent(
                ".claude/local/claude"
            ).path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(
                    fileURLWithPath: String($0),
                    isDirectory: true
                ).appendingPathComponent("claude").path
            })
        }
        var seen = Set<String>()
        for candidate in candidates
            where seen.insert(candidate).inserted {
            guard fileManager.isExecutableFile(
                atPath: candidate
            ) else {
                continue
            }
            return URL(fileURLWithPath: candidate)
                .standardizedFileURL
                .resolvingSymlinksInPath()
        }
        return nil
    }
}

private final class LockedClaudeData:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storage = Data()

    var value: Data {
        lock.withLock { storage }
    }

    func store(_ data: Data) {
        lock.withLock {
            storage = data
        }
    }
}
