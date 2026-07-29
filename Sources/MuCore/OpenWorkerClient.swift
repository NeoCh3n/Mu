import Foundation

public struct OpenWorkerClientConfiguration: Hashable, Sendable {
    public var baseURL: URL
    public var token: String?

    public init(baseURL: URL, token: String? = nil) throws {
        guard Self.isSafeLoopbackURL(baseURL) else {
            throw MuError.commandFailed(
                "OpenWorker must use an explicit http:// loopback endpoint."
            )
        }
        if token?.isEmpty != false, baseURL.host?.lowercased() != "127.0.0.1" {
            throw MuError.commandFailed(
                "Tokenless OpenWorker compatibility is restricted to 127.0.0.1."
            )
        }
        self.baseURL = baseURL
        self.token = token?.isEmpty == false ? token : nil
    }

    public static func isSafeLoopbackURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased(),
              url.port != nil else {
            return false
        }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}

public struct OpenWorkerProbeResult: Hashable, Sendable {
    public var baseURL: URL
    public var status: String
    public var defaultWorkspace: String?
    public var model: String
    public var defaultAgent: String
    public var sessionCount: Int
    public var requiresToken: Bool

    public init(
        baseURL: URL,
        status: String,
        defaultWorkspace: String?,
        model: String,
        defaultAgent: String,
        sessionCount: Int,
        requiresToken: Bool
    ) {
        self.baseURL = baseURL
        self.status = status
        self.defaultWorkspace = defaultWorkspace
        self.model = model
        self.defaultAgent = defaultAgent
        self.sessionCount = sessionCount
        self.requiresToken = requiresToken
    }
}

public struct OpenWorkerSessionSummary: Codable, Hashable, Sendable, Identifiable {
    public var sessionID: String
    public var title: String?
    public var workspace: String
    public var agent: String
    public var model: String
    public var mode: String
    public var updatedAt: String?
    public var messages: Int
    public var pinned: Bool?
    public var archived: Bool?
    public var origin: String?
    public var originLabel: String?
    public var attention: Int?
    public var liveness: String?
    public var subscriptions: [String]?

    public var id: String { sessionID }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case title
        case workspace
        case agent
        case model
        case mode
        case updatedAt = "updated_at"
        case messages
        case pinned
        case archived
        case origin
        case originLabel = "origin_label"
        case attention
        case liveness
        case subscriptions
    }
}

public struct OpenWorkerMessage: Decodable, Hashable, Sendable {
    public var role: String
    public var content: OpenWorkerJSONValue
    public var timestamp: Double?
    public var reasoning: String?
    public var kind: String?
    public var noticeText: String?

    public var text: String {
        if role == "notice" {
            return noticeText
                ?? kind.map { "OpenWorker \($0.replacingOccurrences(of: "_", with: " "))." }
                ?? ""
        }
        switch content {
        case .string(let value):
            return value
        case .array(let values):
            return values.compactMap { value -> String? in
                if case .object(let object) = value {
                    return object["text"]?.stringValue
                }
                return value.stringValue
            }.joined(separator: "\n")
        default:
            return content.compactDescription
        }
    }

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case timestamp = "ts"
        case reasoning
        case kind
        case noticeText = "text"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? "notice"
        content = try container.decodeIfPresent(
            OpenWorkerJSONValue.self,
            forKey: .content
        ) ?? .null
        timestamp = try container.decodeIfPresent(Double.self, forKey: .timestamp)
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        noticeText = try container.decodeIfPresent(String.self, forKey: .noticeText)
    }
}

public struct OpenWorkerArtifactInfo: Codable, Hashable, Sendable, Identifiable {
    public var path: String
    public var absolutePath: String?
    public var name: String
    public var kind: String
    public var size: Int64
    public var modifiedAt: Double

    public var id: String { path }

    enum CodingKeys: String, CodingKey {
        case path
        case absolutePath = "abs_path"
        case name
        case kind
        case size
        case modifiedAt = "modified_at"
    }
}

public struct OpenWorkerInboxItem: Decodable, Hashable, Sendable, Identifiable {
    public var id: String
    public var sessionID: String
    public var kind: String
    public var title: String
    public var body: String
    public var state: String
    public var resolution: String?
    public var visibility: String
    public var toolCallID: String?
    public var options: [String]
    public var allowText: Bool
    public var multi: Bool
    public var data: [String: OpenWorkerJSONValue]
    public var createdAt: String?
    public var resolvedAt: String?
    public var sessionTitle: String?
    public var sessionAgent: String?
    public var sessionWorkspace: String?
    public var sessionExists: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case kind
        case title
        case body
        case state
        case resolution
        case visibility
        case toolCallID = "tool_call_id"
        case options
        case allowText = "allow_text"
        case multi
        case data
        case createdAt = "created_at"
        case resolvedAt = "resolved_at"
        case sessionTitle = "session_title"
        case sessionAgent = "session_agent"
        case sessionWorkspace = "session_workspace"
        case sessionExists = "session_exists"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        kind = try container.decode(String.self, forKey: .kind)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? kind
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? "pending"
        resolution = try container.decodeIfPresent(String.self, forKey: .resolution)
        visibility = try container.decodeIfPresent(String.self, forKey: .visibility) ?? "inbox"
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
        options = try container.decodeIfPresent([String].self, forKey: .options) ?? []
        allowText = try container.decodeIfPresent(Bool.self, forKey: .allowText) ?? true
        multi = try container.decodeIfPresent(Bool.self, forKey: .multi) ?? false
        data = try container.decodeIfPresent(
            [String: OpenWorkerJSONValue].self,
            forKey: .data
        ) ?? [:]
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        resolvedAt = try container.decodeIfPresent(String.self, forKey: .resolvedAt)
        sessionTitle = try container.decodeIfPresent(String.self, forKey: .sessionTitle)
        sessionAgent = try container.decodeIfPresent(String.self, forKey: .sessionAgent)
        sessionWorkspace = try container.decodeIfPresent(
            String.self,
            forKey: .sessionWorkspace
        )
        sessionExists = try container.decodeIfPresent(Bool.self, forKey: .sessionExists)
    }
}

public struct OpenWorkerReady: Hashable, Sendable {
    public var sessionID: String
    public var agent: String
    public var model: String
    public var mode: String
    public var workspace: String
}

public struct OpenWorkerEvent: Hashable, Sendable {
    public var type: String
    public var data: [String: OpenWorkerJSONValue]

    public init(type: String, data: [String: OpenWorkerJSONValue] = [:]) {
        self.type = type
        self.data = data
    }

    public var summary: String {
        switch type {
        case "ready":
            return "Connected to OpenWorker session."
        case "turn_start":
            return "OpenWorker started a turn."
        case "assistant_delta", "reasoning_delta":
            return "OpenWorker is responding."
        case "assistant_message":
            return "OpenWorker returned a message."
        case "tool_proposed":
            let name = data["name"]?.stringValue ?? "tool"
            return "OpenWorker proposed \(name)."
        case "permission_required":
            let name = data["name"]?.stringValue ?? "an action"
            return "Approval required for \(name)."
        case "directory_requested":
            return "OpenWorker requested another folder."
        case "plan_proposed":
            return "OpenWorker proposed a plan."
        case "question_requested":
            return "OpenWorker asked a question."
        case "tool_started":
            let name = data["name"]?.stringValue ?? "tool"
            return "OpenWorker started \(name)."
        case "tool_finished":
            let name = data["name"]?.stringValue ?? "tool"
            return "OpenWorker finished \(name)."
        case "model_changed":
            return data["model"]?.stringValue.map {
                "OpenWorker switched to \($0)."
            } ?? "OpenWorker changed models."
        case "interrupted":
            return "OpenWorker was interrupted."
        case "turn_done":
            return "OpenWorker finished the turn."
        case "error", "input_rejected":
            return data["error"]?.stringValue.map { "OpenWorker: \($0)" }
                ?? "OpenWorker reported an error."
        case "connection_closed":
            return data["error"]?.stringValue.map { "Connection closed: \($0)" }
                ?? "OpenWorker connection closed."
        default:
            return "OpenWorker event: \(type.replacingOccurrences(of: "_", with: " "))."
        }
    }

    public var ready: OpenWorkerReady? {
        guard type == "ready",
              let sessionID = data["session_id"]?.stringValue else {
            return nil
        }
        return OpenWorkerReady(
            sessionID: sessionID,
            agent: data["agent"]?.stringValue ?? "cowork",
            model: data["model"]?.stringValue ?? "",
            mode: data["mode"]?.stringValue ?? "",
            workspace: data["workspace"]?.stringValue ?? ""
        )
    }

    static func decode(_ message: URLSessionWebSocketTask.Message) throws -> OpenWorkerEvent {
        let bytes: Data
        switch message {
        case .string(let value):
            bytes = Data(value.utf8)
        case .data(let value):
            bytes = value
        @unknown default:
            throw MuError.commandFailed("OpenWorker returned an unsupported WebSocket frame.")
        }
        let envelope = try MuCoding.makeDecoder().decode(EventEnvelope.self, from: bytes)
        guard case .object(let data) = envelope.data else {
            return OpenWorkerEvent(type: envelope.type)
        }
        return OpenWorkerEvent(type: envelope.type, data: data)
    }

    private struct EventEnvelope: Decodable {
        var type: String
        var data: OpenWorkerJSONValue
    }
}

public struct OpenWorkerLiveTextState: Hashable, Sendable {
    public private(set) var text: String
    public private(set) var isFinalized: Bool

    public init(text: String = "", isFinalized: Bool = false) {
        self.text = text
        self.isFinalized = isFinalized
    }

    @discardableResult
    public mutating func apply(_ event: OpenWorkerEvent) -> Bool {
        let previous = self
        switch event.type {
        case "turn_start":
            text = ""
            isFinalized = false
        case "assistant_delta":
            guard !isFinalized else { return false }
            if let delta = event.data["text"]?.stringValue,
               !delta.isEmpty {
                text.append(delta)
            }
        case "assistant_message":
            // The native final replaces its streamed prefix. An empty/missing
            // final intentionally clears the transient row.
            text = event.data["text"]?.stringValue ?? ""
            isFinalized = true
        case "turn_done", "input_rejected", "connection_closed":
            // Reject any delayed batch that races with the terminal event.
            isFinalized = true
        default:
            break
        }
        return self != previous
    }
}

public enum OpenWorkerJSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: OpenWorkerJSONValue])
    case array([OpenWorkerJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: OpenWorkerJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([OpenWorkerJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported OpenWorker JSON value."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var stringValue: String? {
        switch self {
        case .string(let value): value
        case .number(let value): String(value)
        case .bool(let value): String(value)
        default: nil
        }
    }

    public var objectValue: [String: OpenWorkerJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var arrayValue: [OpenWorkerJSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var compactDescription: String {
        guard let data = try? MuCoding.makeEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

public final class OpenWorkerHTTPClient: @unchecked Sendable {
    public let configuration: OpenWorkerClientConfiguration
    private let session: URLSession

    public init(
        configuration: OpenWorkerClientConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
    }

    public func probe() async throws -> OpenWorkerProbeResult {
        let health: HealthEnvelope = try await get(pathComponents: ["v1", "health"])
        let agents: AgentsEnvelope = try await get(pathComponents: ["v1", "agents"])
        let sessions = try await sessions()
        let defaultAgent = agents.agents.first(where: { $0.defaultValue == true })?.name
            ?? agents.agents.first?.name
            ?? "cowork"
        return OpenWorkerProbeResult(
            baseURL: configuration.baseURL,
            status: health.status,
            defaultWorkspace: health.defaultWorkspace,
            model: health.model ?? "",
            defaultAgent: defaultAgent,
            sessionCount: sessions.count,
            requiresToken: configuration.token != nil
        )
    }

    public func sessions(workspace: String? = nil) async throws -> [OpenWorkerSessionSummary] {
        var components = URLComponents(
            url: endpoint(pathComponents: ["v1", "sessions"]),
            resolvingAgainstBaseURL: false
        )
        if let workspace, !workspace.isEmpty {
            components?.queryItems = [URLQueryItem(name: "workspace", value: workspace)]
        }
        guard let url = components?.url else {
            throw MuError.commandFailed("Could not construct the OpenWorker sessions URL.")
        }
        let response: SessionsEnvelope = try await get(url: url)
        return response.sessions
    }

    public func messages(sessionID: String) async throws -> [OpenWorkerMessage] {
        let response: MessagesEnvelope = try await get(
            pathComponents: ["v1", "sessions", sessionID, "messages"]
        )
        return response.messages
    }

    public func artifacts(sessionID: String) async throws -> [OpenWorkerArtifactInfo] {
        let response: ArtifactsEnvelope = try await get(
            pathComponents: ["v1", "sessions", sessionID, "artifacts"]
        )
        return response.artifacts
    }

    public func pendingInbox(sessionID: String) async throws -> [OpenWorkerInboxItem] {
        var components = URLComponents(
            url: endpoint(pathComponents: ["v1", "inbox"]),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "session_id", value: sessionID),
            URLQueryItem(name: "state", value: "pending")
        ]
        guard let url = components?.url else {
            throw MuError.commandFailed("Could not construct the OpenWorker Inbox URL.")
        }
        let response: InboxEnvelope = try await get(url: url)
        return response.items
    }

    @discardableResult
    public func resolveInbox(itemID: String, resolution: String) async throws -> Bool {
        let response: ResolveInboxEnvelope = try await post(
            pathComponents: ["v1", "inbox", itemID, "resolve"],
            body: ["resolution": resolution]
        )
        return response.ok
    }

    private func get<T: Decodable>(pathComponents: [String]) async throws -> T {
        try await get(url: endpoint(pathComponents: pathComponents))
    }

    private func get<T: Decodable>(url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.httpMethod = "GET"
        if let token = configuration.token {
            request.setValue(token, forHTTPHeaderField: "X-OpenWorker-Token")
        }
        return try await perform(request)
    }

    private func post<T: Decodable>(
        pathComponents: [String],
        body: [String: String]
    ) async throws -> T {
        var request = URLRequest(url: endpoint(pathComponents: pathComponents))
        // Inbox resolution may trigger a durable agent resume before the server replies.
        // The caller reconciles the Inbox after any timeout instead of treating it as unsent.
        request.timeoutInterval = 20
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = configuration.token {
            request.setValue(token, forHTTPHeaderField: "X-OpenWorker-Token")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await perform(request)
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MuError.commandFailed("OpenWorker returned no HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(decoding: data.prefix(1_024), as: UTF8.self)
            if http.statusCode == 401 {
                throw MuError.commandFailed(
                    "OpenWorker requires a sidecar token that Mu has not been given."
                )
            }
            throw MuError.commandFailed(
                "OpenWorker HTTP \(http.statusCode): \(detail)"
            )
        }
        do {
            return try MuCoding.makeDecoder().decode(T.self, from: data)
        } catch {
            throw MuError.commandFailed(
                "OpenWorker returned an incompatible response: \(error.localizedDescription)"
            )
        }
    }

    private func endpoint(pathComponents: [String]) -> URL {
        pathComponents.reduce(configuration.baseURL) { url, component in
            url.appending(path: component)
        }
    }

    private struct HealthEnvelope: Decodable {
        var status: String
        var defaultWorkspace: String?
        var model: String?

        enum CodingKeys: String, CodingKey {
            case status
            case defaultWorkspace = "default_workspace"
            case model
        }
    }

    private struct AgentEnvelope: Decodable {
        var name: String
        var defaultValue: Bool?

        enum CodingKeys: String, CodingKey {
            case name
            case defaultValue = "default"
        }
    }

    private struct AgentsEnvelope: Decodable {
        var agents: [AgentEnvelope]
    }

    private struct SessionsEnvelope: Decodable {
        var sessions: [OpenWorkerSessionSummary]
    }

    private struct MessagesEnvelope: Decodable {
        var messages: [OpenWorkerMessage]
    }

    private struct ArtifactsEnvelope: Decodable {
        var artifacts: [OpenWorkerArtifactInfo]
    }

    private struct InboxEnvelope: Decodable {
        var items: [OpenWorkerInboxItem]
    }

    private struct ResolveInboxEnvelope: Decodable {
        var ok: Bool
    }
}

public actor OpenWorkerSessionBridge {
    public typealias EventHandler = @Sendable (OpenWorkerEvent) async -> Void

    public let configuration: OpenWorkerClientConfiguration
    public let sessionID: String
    public let workspace: String
    public let agent: String

    private let urlSession: URLSession
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var assistantDeltaFlushTask: Task<Void, Never>?
    private var pendingAssistantDelta = ""
    private var readyValue: OpenWorkerReady?
    private var handler: EventHandler?
    private var intentionallyClosed = false

    // A native agent can emit one WebSocket frame per token. Forwarding each
    // frame through a MainActor UI handler makes the receive loop trail the
    // already-completed native turn. A short batch still feels live while
    // keeping final/control events close to real time.
    private static let assistantDeltaFlushInterval = Duration.milliseconds(80)

    public init(
        configuration: OpenWorkerClientConfiguration,
        sessionID: String,
        workspace: String,
        agent: String = "cowork",
        urlSession: URLSession = .shared
    ) {
        self.configuration = configuration
        self.sessionID = sessionID
        self.workspace = workspace
        self.agent = agent
        self.urlSession = urlSession
    }

    @discardableResult
    public func connect(handler: @escaping EventHandler) async throws -> OpenWorkerReady {
        if let readyValue {
            self.handler = handler
            return readyValue
        }
        self.handler = handler
        intentionallyClosed = false

        let url = try webSocketURL()
        let task: URLSessionWebSocketTask
        if let token = configuration.token {
            task = urlSession.webSocketTask(
                with: url,
                protocols: ["openworker", token]
            )
        } else {
            // Passing an empty protocols array emits an invalid empty
            // Sec-WebSocket-Protocol header in URLSession and Uvicorn rejects it with 400.
            task = urlSession.webSocketTask(with: url)
        }
        socket = task
        task.resume()

        let first: OpenWorkerEvent
        do {
            first = try await Self.receiveReady(from: task)
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            socket = nil
            throw error
        }
        guard let ready = first.ready, ready.sessionID == sessionID else {
            task.cancel(with: .protocolError, reason: nil)
            socket = nil
            throw MuError.commandFailed(
                "OpenWorker did not acknowledge native session \(sessionID)."
            )
        }
        if !ready.workspace.isEmpty,
           !Self.sameWorkspace(ready.workspace, workspace) {
            task.cancel(with: .policyViolation, reason: nil)
            socket = nil
            throw MuError.invalidTransition(
                "OpenWorker acknowledged a different workspace. Relink the intended native session."
            )
        }
        readyValue = ready
        await handler(first)
        receiveTask = Task { [weak self] in
            await self?.receiveContinuously()
        }
        return ready
    }

    public func sendUserMessage(_ text: String, model: String? = nil) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MuError.invalidTransition("OpenWorker message cannot be empty.")
        }
        var payload: [String: Any] = [
            "type": "user_message",
            "text": trimmed
        ]
        if let model, !model.isEmpty {
            payload["model"] = model
        }
        try await send(payload)
    }

    public func approveOnce() async throws {
        try await send(["type": "approval", "decision": "once"])
    }

    public func denyApproval() async throws {
        try await send(["type": "approval", "decision": "deny"])
    }

    public func respondToPlan(approved: Bool, mode: String = "interactive") async throws {
        try await send([
            "type": "plan_response",
            "approved": approved,
            "mode": mode
        ])
    }

    public func answerQuestion(_ answer: String) async throws {
        try await send(["type": "question_response", "answer": answer])
    }

    public func interrupt() async throws {
        try await send(["type": "interrupt"])
    }

    public func disconnect() {
        intentionallyClosed = true
        receiveTask?.cancel()
        receiveTask = nil
        assistantDeltaFlushTask?.cancel()
        assistantDeltaFlushTask = nil
        pendingAssistantDelta = ""
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        readyValue = nil
    }

    private func receiveContinuously() async {
        guard let socket else { return }
        do {
            while !Task.isCancelled {
                let event = try await receive(from: socket)
                await deliver(event)
            }
        } catch {
            guard !intentionallyClosed, !Task.isCancelled else { return }
            assistantDeltaFlushTask?.cancel()
            assistantDeltaFlushTask = nil
            pendingAssistantDelta = ""
            readyValue = nil
            self.socket = nil
            if let handler {
                await handler(
                    OpenWorkerEvent(
                        type: "connection_closed",
                        data: ["error": .string(error.localizedDescription)]
                    )
                )
            }
        }
    }

    private func deliver(_ event: OpenWorkerEvent) async {
        if event.type == "assistant_delta" {
            let text = event.data["text"]?.stringValue ?? ""
            guard !text.isEmpty else { return }
            pendingAssistantDelta.append(text)
            scheduleAssistantDeltaFlush()
            return
        }

        if event.type == "assistant_message" {
            // assistant_message is the authoritative native final. Any
            // unflushed deltas are a prefix of it and must never be delivered
            // after the final replacement.
            assistantDeltaFlushTask?.cancel()
            assistantDeltaFlushTask = nil
            pendingAssistantDelta = ""
        } else if event.type == "turn_done" {
            // Some compatible OpenWorker builds omit assistant_message. Flush
            // their last partial batch before the terminal event so Mu can
            // reconcile the durable REST transcript without losing text.
            await flushAssistantDelta()
        }

        if let handler {
            await handler(event)
        }
    }

    private func scheduleAssistantDeltaFlush() {
        guard assistantDeltaFlushTask == nil else { return }
        assistantDeltaFlushTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.assistantDeltaFlushInterval)
            } catch {
                return
            }
            await self?.flushAssistantDelta()
        }
    }

    private func flushAssistantDelta() async {
        assistantDeltaFlushTask?.cancel()
        assistantDeltaFlushTask = nil
        guard !pendingAssistantDelta.isEmpty else { return }
        let text = pendingAssistantDelta
        pendingAssistantDelta = ""
        if let handler {
            await handler(
                OpenWorkerEvent(
                    type: "assistant_delta",
                    data: ["text": .string(text)]
                )
            )
        }
    }

    private func receive(from socket: URLSessionWebSocketTask) async throws -> OpenWorkerEvent {
        try await OpenWorkerEvent.decode(socket.receive())
    }

    private static func receiveReady(
        from socket: URLSessionWebSocketTask
    ) async throws -> OpenWorkerEvent {
        try await withThrowingTaskGroup(of: OpenWorkerEvent.self) { group in
            group.addTask {
                try await OpenWorkerEvent.decode(socket.receive())
            }
            group.addTask {
                try await Task.sleep(for: .seconds(12))
                socket.cancel(with: .goingAway, reason: nil)
                throw MuError.commandFailed(
                    "Timed out waiting for the OpenWorker session handshake."
                )
            }
            guard let first = try await group.next() else {
                throw MuError.commandFailed(
                    "OpenWorker closed before acknowledging the native session."
                )
            }
            group.cancelAll()
            return first
        }
    }

    private static func sameWorkspace(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath().path
            == URL(fileURLWithPath: rhs, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath().path
    }

    private func send(_ payload: [String: Any]) async throws {
        guard let socket, readyValue != nil else {
            throw MuError.commandFailed("OpenWorker session is not connected.")
        }
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw MuError.commandFailed("Could not encode the OpenWorker message.")
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func webSocketURL() throws -> URL {
        var components = URLComponents(
            url: configuration.baseURL
                .appending(path: "ws")
                .appending(path: "session")
                .appending(path: sessionID),
            resolvingAgainstBaseURL: false
        )
        components?.scheme = configuration.baseURL.scheme == "https" ? "wss" : "ws"
        components?.queryItems = [
            URLQueryItem(name: "workspace", value: workspace),
            URLQueryItem(name: "agent", value: agent)
        ]
        guard let url = components?.url else {
            throw MuError.commandFailed("Could not construct the OpenWorker WebSocket URL.")
        }
        return url
    }
}

public enum OpenWorkerSidecarLocator {
    public static func discoverBaseURL(
        logURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        let source = logURL ?? fileManager.homeDirectoryForCurrentUser
            .appending(path: ".config")
            .appending(path: "coworker")
            .appending(path: "logs")
            .appending(path: "openworker-server.log")
        guard let handle = try? FileHandle(forReadingFrom: source) else {
            return nil
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let sample: Data
        if size <= 16 * 1_024 * 1_024 {
            try? handle.seek(toOffset: 0)
            sample = (try? handle.readToEnd()) ?? Data()
        } else {
            try? handle.seek(toOffset: 0)
            let head = (try? handle.read(upToCount: 1 * 1_024 * 1_024)) ?? Data()
            try? handle.seek(toOffset: size - UInt64(8 * 1_024 * 1_024))
            let tail = (try? handle.readToEnd()) ?? Data()
            sample = head + Data("\n".utf8) + tail
        }
        return parseBaseURL(from: String(decoding: sample, as: UTF8.self))
    }

    public static func parseBaseURL(from log: String) -> URL? {
        let pattern = #"Uvicorn running on http://(127\.0\.0\.1|localhost|\[::1\]):([0-9]{2,5})"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(log.startIndex..<log.endIndex, in: log)
        guard let match = expression.matches(in: log, range: range).last,
              let hostRange = Range(match.range(at: 1), in: log),
              let portRange = Range(match.range(at: 2), in: log),
              let port = Int(log[portRange]),
              (1...65_535).contains(port) else {
            return nil
        }
        let rawHost = String(log[hostRange])
        let host = rawHost == "[::1]" ? "[::1]" : rawHost
        return URL(string: "http://\(host):\(port)")
    }
}
