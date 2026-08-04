import Foundation
@testable import MuCore
import Testing

@Suite(.serialized)
struct CollaborationHTTPClientTests {
    @Test
    func nativeClientUsesSharedHeadersAndRoundTripsSpaceState() async throws {
        let identity = CollaborationClientIdentity(
            actorID: UUID(uuidString: "00000000-0000-4000-8000-0000000000a1")!,
            clientInstanceID: "mac-test-1",
            displayName: "Alice"
        )
        let config = try CollaborationHTTPClientConfiguration(
            baseURL: URL(string: "http://127.0.0.1:4000")!,
            identity: identity
        )
        let spaceID = UUID(uuidString: "00000000-0000-4000-8000-0000000000b2")!
        let threadID = UUID(uuidString: "00000000-0000-4000-8000-0000000000c3")!
        let event = SpaceEventRecord(
            spaceID: spaceID,
            threadID: threadID,
            actorID: identity.actorID,
            clientInstanceID: identity.clientInstanceID,
            sequence: 1,
            eventType: "chat.message",
            payload: ["text": "Hello from Swift"],
            idempotencyKey: "swift-1",
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let space = CollaborationSpaceRecord(
            id: spaceID,
            displayName: "Shared room",
            createdAt: event.occurredAt,
            updatedAt: event.occurredAt
        )
        let presence = PresenceSessionRecord(
            spaceID: spaceID,
            actorID: identity.actorID,
            clientInstanceID: identity.clientInstanceID,
            displayName: identity.displayName,
            lastSeenAt: event.occurredAt,
            expiresAt: event.occurredAt.addingTimeInterval(45)
        )
        let encoder = MuCoding.makeEncoder()
        let spaceData = try encoder.encode(space)
        let eventData = try encoder.encode(event)
        let presenceData = try encoder.encode(presence)

        CollaborationURLProtocolFixture.install { request in
            #expect(request.value(forHTTPHeaderField: "x-mu-actor-id") == identity.actorID.uuidString.lowercased())
            #expect(request.value(forHTTPHeaderField: "x-mu-client-instance-id") == identity.clientInstanceID)
            #expect(request.value(forHTTPHeaderField: "x-mu-display-name") == identity.displayName)
            let path = request.url?.path ?? ""
            switch (request.httpMethod ?? "GET", path) {
            case ("GET", "/spaces"):
                return (200, try! JSONSerialization.data(withJSONObject: [
                    "spaces": [try! JSONSerialization.jsonObject(with: spaceData)]
                ]))
            case ("PUT", "/spaces/\(spaceID.uuidString.lowercased())"):
                return (200, try! JSONSerialization.data(withJSONObject: [
                    "space": try! JSONSerialization.jsonObject(with: spaceData),
                    "created": false
                ]))
            case ("GET", "/spaces/\(spaceID.uuidString.lowercased())/sync"):
                return (200, try! JSONSerialization.data(withJSONObject: [
                    "spaceID": spaceID.uuidString.lowercased(),
                    "afterSequence": 0,
                    "nextSequence": 1,
                    "events": [try! JSONSerialization.jsonObject(with: eventData)],
                    "presence": [try! JSONSerialization.jsonObject(with: presenceData)],
                    "hasMore": false
                ]))
            case ("POST", "/spaces/\(spaceID.uuidString.lowercased())/events"):
                return (201, try! JSONSerialization.data(withJSONObject: [
                    "event": try! JSONSerialization.jsonObject(with: eventData),
                    "deduplicated": false
                ]))
            case ("PUT", "/spaces/\(spaceID.uuidString.lowercased())/presence"):
                return (200, try! JSONSerialization.data(withJSONObject: [
                    "presence": try! JSONSerialization.jsonObject(with: presenceData)
                ]))
            case ("DELETE", "/spaces/\(spaceID.uuidString.lowercased())/presence"):
                return (200, Data(#"{"removed":true}"#.utf8))
            default:
                return (404, Data(#"{"message":"fixture route missing"}"#.utf8))
            }
        }
        defer { CollaborationURLProtocolFixture.reset() }

        let client = CollaborationHTTPClient(
            configuration: config,
            session: CollaborationURLProtocolFixture.makeSession()
        )
        #expect(try await client.listSpaces() == [space])
        #expect(try await client.ensureSpace(id: spaceID, displayName: "Shared room") == space)
        let sync = try await client.syncSpace(id: spaceID)
        #expect(sync.events == [event])
        #expect(sync.presence == [presence])
        #expect(try await client.appendEvent(
            spaceID: spaceID,
            threadID: threadID,
            eventType: event.eventType,
            payload: event.payload,
            idempotencyKey: event.idempotencyKey ?? "swift-1"
        ) == event)
        #expect(try await client.heartbeatPresence(spaceID: spaceID) == presence)
        try await client.removePresence(spaceID: spaceID)

        let requests = CollaborationURLProtocolFixture.requests()
        #expect(requests.count == 6)
        #expect(requests.map { $0.httpMethod ?? "" } == ["GET", "PUT", "GET", "POST", "PUT", "DELETE"])
    }

    @Test
    func localIdentityKeepsActorStableButSeparatesClientInstances() {
        let suiteName = "mu-collaboration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = CollaborationClientIdentity.local(userDefaults: defaults)
        let second = CollaborationClientIdentity.local(userDefaults: defaults)
        #expect(first.actorID == second.actorID)
        #expect(first.clientInstanceID != second.clientInstanceID)
        #expect(!first.displayName.isEmpty)
    }

    @Test
    func liveServerAcceptsTwoNativeInstancesWhenConfigured() async throws {
        guard let rawURL = ProcessInfo.processInfo.environment["MU_SPACE_ACCEPTANCE_URL"],
              let baseURL = URL(string: rawURL) else {
            // The normal unit suite has no server dependency. The acceptance
            // command sets this variable to turn the same test into a real
            // two-client loopback verification.
            return
        }
        let spaceID = UUID()
        let actorA = CollaborationClientIdentity(
            actorID: UUID(),
            clientInstanceID: "acceptance-mac-a-\(UUID().uuidString.lowercased())",
            displayName: "Acceptance A"
        )
        let actorB = CollaborationClientIdentity(
            actorID: UUID(),
            clientInstanceID: "acceptance-mac-b-\(UUID().uuidString.lowercased())",
            displayName: "Acceptance B"
        )
        let clientA = CollaborationHTTPClient(
            configuration: try CollaborationHTTPClientConfiguration(
                baseURL: baseURL,
                identity: actorA
            )
        )
        let clientB = CollaborationHTTPClient(
            configuration: try CollaborationHTTPClientConfiguration(
                baseURL: baseURL,
                identity: actorB
            )
        )

        _ = try await clientA.ensureSpace(
            id: spaceID,
            displayName: "Swift dual-instance acceptance"
        )
        _ = try await clientB.ensureSpace(
            id: spaceID,
            displayName: "A second client must not rename the room"
        )
        _ = try await clientA.appendEvent(
            spaceID: spaceID,
            eventType: "chat.message",
            payload: ["taskID": UUID().uuidString.lowercased(), "text": "hello from A"],
            idempotencyKey: "acceptance-a"
        )
        _ = try await clientB.appendEvent(
            spaceID: spaceID,
            eventType: "chat.message",
            payload: ["taskID": UUID().uuidString.lowercased(), "text": "hello from B"],
            idempotencyKey: "acceptance-b"
        )
        _ = try await clientA.heartbeatPresence(spaceID: spaceID)
        _ = try await clientB.heartbeatPresence(spaceID: spaceID)
        let replay = try await clientB.syncSpace(id: spaceID, afterSequence: 0)
        #expect(replay.events.map { $0.payload["text"] } == ["hello from A", "hello from B"])
        #expect(Set(replay.presence.map(\.displayName)) == ["Acceptance A", "Acceptance B"])
        try await clientA.removePresence(spaceID: spaceID)
        try await clientB.removePresence(spaceID: spaceID)
    }

    @Test
    func liveServerSSEReachesNativeClientWhenConfigured() async throws {
        guard let rawURL = ProcessInfo.processInfo.environment["MU_SPACE_ACCEPTANCE_URL"],
              let baseURL = URL(string: rawURL) else { return }
        let spaceID = UUID()
        let clientA = CollaborationHTTPClient(
            configuration: try CollaborationHTTPClientConfiguration(
                baseURL: baseURL,
                identity: CollaborationClientIdentity(
                    actorID: UUID(),
                    clientInstanceID: "acceptance-sse-a-\(UUID().uuidString.lowercased())",
                    displayName: "SSE A"
                )
            )
        )
        let clientB = CollaborationHTTPClient(
            configuration: try CollaborationHTTPClientConfiguration(
                baseURL: baseURL,
                identity: CollaborationClientIdentity(
                    actorID: UUID(),
                    clientInstanceID: "acceptance-sse-b-\(UUID().uuidString.lowercased())",
                    displayName: "SSE B"
                )
            )
        )
        _ = try await clientA.ensureSpace(id: spaceID, displayName: "SSE acceptance")
        // Race the live receiver against a bounded timeout. The receiver is
        // only cancelled after it has observed the frame (or the timeout has
        // expired), so cancellation cannot discard a complete SSE envelope.
        enum RaceResult: Sendable {
            case received
            case published
            case timedOut
        }
        let received = await withTaskGroup(of: RaceResult.self, returning: Bool.self) { group in
            group.addTask {
                do {
                    for try await envelope in clientB.streamEvents(spaceID: spaceID) {
                        if case .spaceEvent(let event) = envelope,
                           event.payload["text"] == "sse hello" {
                            return .received
                        }
                    }
                } catch {
                    return .timedOut
                }
                return .timedOut
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(750))
                _ = try? await clientA.appendEvent(
                    spaceID: spaceID,
                    eventType: "chat.message",
                    payload: ["text": "sse hello"],
                    idempotencyKey: "acceptance-sse"
                )
                return .published
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return .timedOut
            }
            while let result = await group.next() {
                switch result {
                case .received:
                    group.cancelAll()
                    return true
                case .published:
                    continue
                case .timedOut:
                    group.cancelAll()
                    return false
                }
            }
            return false
        }
        #expect(received)
    }
}

private final class CollaborationURLProtocolFixture: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> (Int, Data))?
    private static var recordedRequests: [URLRequest] = []

    static func install(handler: @escaping (URLRequest) -> (Int, Data)) {
        lock.withLock {
            self.handler = handler
            recordedRequests.removeAll()
        }
    }

    static func reset() {
        lock.withLock {
            handler = nil
            recordedRequests.removeAll()
        }
    }

    static func requests() -> [URLRequest] {
        lock.withLock { recordedRequests }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let result: (Int, Data)? = Self.lock.withLock {
            Self.recordedRequests.append(request)
            return Self.handler?(request)
        }
        guard let result,
              let response = HTTPURLResponse(
                  url: request.url!,
                  statusCode: result.0,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: MuError.commandFailed("fixture route missing"))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
