import Foundation

/// Identity is split into a durable person id and an ephemeral client id.
/// Two Mu processes can therefore represent one person while retaining
/// independent presence sessions (and two people get different actor ids).
public struct CollaborationClientIdentity: Codable, Hashable, Sendable {
    public var actorID: UUID
    public var clientInstanceID: String
    public var displayName: String

    public init(
        actorID: UUID,
        clientInstanceID: String,
        displayName: String
    ) {
        self.actorID = actorID
        self.clientInstanceID = clientInstanceID
        self.displayName = displayName
    }

    public static func local(
        displayName: String? = nil,
        userDefaults: UserDefaults = .standard
    ) -> CollaborationClientIdentity {
        let actorKey = "mu.collaboration.actor-id.v1"
        let actorID: UUID
        if let stored = userDefaults.string(forKey: actorKey),
           let parsed = UUID(uuidString: stored) {
            actorID = parsed
        } else {
            actorID = UUID()
            userDefaults.set(actorID.uuidString.lowercased(), forKey: actorKey)
        }

        let configuredName = displayName?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let storedName = userDefaults.string(
            forKey: "mu.collaboration.display-name.v1"
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostName = Host.current().localizedName
            ?? ProcessInfo.processInfo.hostName
        let resolvedName = (configuredName?.isEmpty == false
            ? configuredName
            : storedName?.isEmpty == false
                ? storedName
                : hostName)
            ?? "Local user"
        if configuredName?.isEmpty == false {
            userDefaults.set(configuredName, forKey: "mu.collaboration.display-name.v1")
        }

        // Never persist this value: every launched process needs a distinct
        // presence row even when it belongs to the same local user.
        let clientInstanceID = "mac-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.lowercased())"
        return CollaborationClientIdentity(
            actorID: actorID,
            clientInstanceID: String(clientInstanceID.prefix(160)),
            displayName: String(resolvedName.prefix(160))
        )
    }
}

public struct CollaborationHTTPClientConfiguration: Hashable, Sendable {
    public var baseURL: URL
    public var identity: CollaborationClientIdentity
    public var requestTimeout: TimeInterval

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:4000")!,
        identity: CollaborationClientIdentity = .local(),
        requestTimeout: TimeInterval = 20
    ) throws {
        guard let scheme = baseURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              baseURL.host != nil else {
            throw MuError.commandFailed(
                "Shared Space requires an http:// or https:// server URL."
            )
        }
        guard !identity.clientInstanceID.isEmpty,
              identity.clientInstanceID.utf8.count <= 160,
              !identity.displayName.isEmpty,
              identity.displayName.utf8.count <= 160 else {
            throw MuError.commandFailed("Shared Space identity is invalid.")
        }
        self.baseURL = baseURL
        self.identity = identity
        self.requestTimeout = max(1, requestTimeout)
    }
}

public enum CollaborationSSEEnvelope: Hashable, Sendable {
    case spaceEvent(SpaceEventRecord)
    case presence(PresenceSessionRecord)
}

public struct CollaborationSpaceSyncBatch: Codable, Hashable, Sendable {
    public var spaceID: UUID
    public var afterSequence: Int64
    public var nextSequence: Int64
    public var events: [SpaceEventRecord]
    public var presence: [PresenceSessionRecord]
    public var hasMore: Bool

    public init(
        spaceID: UUID,
        afterSequence: Int64,
        nextSequence: Int64,
        events: [SpaceEventRecord],
        presence: [PresenceSessionRecord],
        hasMore: Bool
    ) {
        self.spaceID = spaceID
        self.afterSequence = afterSequence
        self.nextSequence = nextSequence
        self.events = events
        self.presence = presence
        self.hasMore = hasMore
    }
}

/// Native macOS transport for the same Space protocol used by the TS client.
/// Durable state remains ordered by `sequence`; SSE is only an invalidation
/// signal, so reconnects always recover through the idempotent sync endpoint.
public final class CollaborationHTTPClient: @unchecked Sendable {
    public let configuration: CollaborationHTTPClientConfiguration
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        configuration: CollaborationHTTPClientConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
        self.encoder = MuCoding.makeEncoder()
        self.decoder = MuCoding.makeDecoder()
    }

    public func listSpaces() async throws -> [CollaborationSpaceRecord] {
        struct Response: Decodable { var spaces: [CollaborationSpaceRecord] }
        return try await request(
            path: "spaces",
            method: "GET",
            body: Optional<EmptyBody>.none,
            decode: Response.self
        ).spaces
    }

    /// Ensures a deterministic Project-backed Space exists on the server.
    /// This is what lets a native local store join a room before its first
    /// message, without replacing the local Project id with a random id.
    @discardableResult
    public func ensureSpace(
        id: UUID,
        displayName: String,
        description: String = ""
    ) async throws -> CollaborationSpaceRecord {
        struct Body: Encodable {
            var displayName: String
            var description: String
        }
        struct Response: Decodable { var space: CollaborationSpaceRecord }
        return try await request(
            path: "spaces/\(id.uuidString.lowercased())",
            method: "PUT",
            body: Body(displayName: displayName, description: description),
            decode: Response.self
        ).space
    }

    public func syncSpace(
        id: UUID,
        afterSequence: Int64 = 0,
        limit: Int = 100
    ) async throws -> CollaborationSpaceSyncBatch {
        try await request(
            path: "spaces/\(id.uuidString.lowercased())/sync?after=\(max(0, afterSequence))&limit=\(min(500, max(1, limit)))",
            method: "GET",
            body: Optional<EmptyBody>.none,
            decode: CollaborationSpaceSyncBatch.self
        )
    }

    @discardableResult
    public func appendEvent(
        spaceID: UUID,
        threadID: UUID? = nil,
        eventType: String,
        payload: [String: String] = [:],
        idempotencyKey: String = UUID().uuidString.lowercased()
    ) async throws -> SpaceEventRecord {
        struct Body: Encodable {
            var threadID: String?
            var eventType: String
            var payload: [String: String]
            var idempotencyKey: String
        }
        struct Response: Decodable { var event: SpaceEventRecord }
        return try await request(
            path: "spaces/\(spaceID.uuidString.lowercased())/events",
            method: "POST",
            body: Body(
                threadID: threadID?.uuidString.lowercased(),
                eventType: eventType,
                payload: payload,
                idempotencyKey: idempotencyKey
            ),
            decode: Response.self
        ).event
    }

    @discardableResult
    public func heartbeatPresence(
        spaceID: UUID,
        state: PresenceState = .online,
        ttlSeconds: Int = 45
    ) async throws -> PresenceSessionRecord {
        struct Body: Encodable {
            var displayName: String
            var state: PresenceState
            var ttlSeconds: Int
        }
        struct Response: Decodable { var presence: PresenceSessionRecord }
        return try await request(
            path: "spaces/\(spaceID.uuidString.lowercased())/presence",
            method: "PUT",
            body: Body(
                displayName: configuration.identity.displayName,
                state: state,
                ttlSeconds: ttlSeconds
            ),
            decode: Response.self
        ).presence
    }

    public func removePresence(spaceID: UUID) async throws {
        struct Response: Decodable { var removed: Bool }
        _ = try await request(
            path: "spaces/\(spaceID.uuidString.lowercased())/presence",
            method: "DELETE",
            body: Optional<EmptyBody>.none,
            decode: Response.self
        )
    }

    /// Opens the server's filtered SSE stream. Frames are deliberately
    /// decoded as receipts and never treated as the authoritative state.
    public func streamEvents(
        spaceID: UUID
    ) -> AsyncThrowingStream<CollaborationSSEEnvelope, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [session, configuration, decoder] in
                var eventName = "message"
                var dataLines: [String] = []
                func emitPendingEvent() {
                    guard !dataLines.isEmpty else { return }
                    let data = dataLines.joined(separator: "\n").data(using: .utf8) ?? Data()
                    if let envelope = Self.decodeSSE(
                        eventName: eventName,
                        data: data,
                        decoder: decoder
                    ) {
                        continuation.yield(envelope)
                    }
                    eventName = "message"
                    dataLines.removeAll(keepingCapacity: true)
                }

                do {
                    var request = URLRequest(
                        url: try Self.url(
                            baseURL: configuration.baseURL,
                            path: "api/events?spaceID=\(spaceID.uuidString.lowercased())"
                        )
                    )
                    request.httpMethod = "GET"
                    request.timeoutInterval = .greatestFiniteMagnitude
                    Self.applyHeaders(
                        &request,
                        identity: configuration.identity,
                        includeContentType: false
                    )
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode) else {
                        throw MuError.commandFailed(
                            "Shared Space SSE returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)."
                        )
                    }

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if line.hasPrefix(":") { continue }
                        if line.isEmpty {
                            emitPendingEvent()
                        } else if line.hasPrefix("event:") {
                            // URLSession.AsyncBytes.lines may omit the empty
                            // separator line from an SSE frame. Flush the
                            // previous data when the next event header arrives
                            // so native clients remain compatible with both
                            // line implementations.
                            emitPendingEvent()
                            eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            dataLines.append(
                                String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                            )
                            // Mu's server serializes each JSON envelope on a
                            // single data line. URLSession.AsyncBytes.lines
                            // does not expose the blank frame separator, so
                            // decode the complete one-line payload immediately
                            // while retaining the normal separator handling
                            // for other SSE implementations.
                            emitPendingEvent()
                        }
                    }
                    emitPendingEvent()
                    continuation.finish()
                } catch {
                    // Cancellation can interrupt AsyncBytes.lines before it
                    // returns the final separator. Preserve a complete frame
                    // that was already received instead of dropping it.
                    emitPendingEvent()
                    print("Mu Space SSE error: \(error)")
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func request<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body?,
        decode: Response.Type
    ) async throws -> Response {
        var request = URLRequest(
            url: try Self.url(baseURL: configuration.baseURL, path: path)
        )
        request.httpMethod = method
        request.timeoutInterval = configuration.requestTimeout
        Self.applyHeaders(
            &request,
            identity: configuration.identity,
            includeContentType: body != nil
        )
        if let body {
            request.httpBody = try encoder.encode(body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MuError.commandFailed("Shared Space returned no HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? decoder.decode(ErrorResponse.self, from: data))?.message
                ?? String(data: data, encoding: .utf8)
                ?? "HTTP \(http.statusCode)"
            throw MuError.commandFailed("Shared Space HTTP \(http.statusCode): \(message)")
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw MuError.commandFailed(
                "Shared Space response could not be decoded: \(error.localizedDescription)"
            )
        }
    }

    private struct ErrorResponse: Decodable {
        var message: String?
    }

    private struct EmptyBody: Encodable {}

    private static func url(baseURL: URL, path: String) throws -> URL {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw MuError.commandFailed("Shared Space URL is invalid.")
        }
        return url
    }

    private static func applyHeaders(
        _ request: inout URLRequest,
        identity: CollaborationClientIdentity,
        includeContentType: Bool
    ) {
        if includeContentType {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue(identity.actorID.uuidString.lowercased(), forHTTPHeaderField: "x-mu-actor-id")
        request.setValue(identity.clientInstanceID, forHTTPHeaderField: "x-mu-client-instance-id")
        request.setValue(identity.displayName, forHTTPHeaderField: "x-mu-display-name")
    }

    private static func decodeSSE(
        eventName: String,
        data: Data,
        decoder: JSONDecoder
    ) -> CollaborationSSEEnvelope? {
        switch eventName {
        case "space_event":
            guard let event = try? decoder.decode(SpaceEventRecord.self, from: data) else {
                return nil
            }
            return .spaceEvent(event)
        case "presence":
            guard let presence = try? decoder.decode(PresenceSessionRecord.self, from: data) else {
                return nil
            }
            return .presence(presence)
        default:
            return nil
        }
    }
}
