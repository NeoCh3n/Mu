import Foundation

/// The product-level integration path. Runtime control details are described
/// separately so an attached desktop sidecar is never presented as a process
/// that Mu fully owns.
public enum AgentConnectionKind:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case managedRuntime = "managed_runtime"
    case connectedAgent = "connected_agent"
    case toolHost = "tool_host"
}

public enum RuntimeControlMode:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case managed
    case managedLimited = "managed_limited"
    case attached
    case historyOnly = "history_only"
    case submitOnly = "submit_only"
}

public enum AgentTrustLevel:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case managed
    case connected
    case submitOnly = "submit_only"
}

public enum RuntimeGatewayOperation:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Sendable
{
    case discoverHistory = "history.discover"
    case readHistory = "history.read"
    case createSession = "session.create"
    case attachSession = "session.attach"
    case submitInput = "input.submit"
    case observeEvents = "events.observe"
    case interrupt
    case resume
    case resolveApproval = "approval.resolve"
    case listArtifacts = "artifact.list"
    case submitArtifact = "artifact.submit"
    case acceptTaskLease = "task_lease.accept"
    case renewTaskLease = "task_lease.renew"
    case publishProjectEvent = "project_event.publish"
    case completeTask = "task.complete"
    case failTask = "task.fail"
    case searchContext = "context.search"
    case getContextRecord = "context.get_record"

    public var displayName: String {
        switch self {
        case .discoverHistory: "Discover history"
        case .readHistory: "Read history"
        case .createSession: "Create session"
        case .attachSession: "Attach session"
        case .submitInput: "Submit input"
        case .observeEvents: "Observe events"
        case .interrupt: "Interrupt"
        case .resume: "Resume"
        case .resolveApproval: "Resolve approval"
        case .listArtifacts: "List artifacts"
        case .submitArtifact: "Submit artifact"
        case .acceptTaskLease: "Accept Task lease"
        case .renewTaskLease: "Renew Task lease"
        case .publishProjectEvent: "Publish Project event"
        case .completeTask: "Complete Task"
        case .failTask: "Fail Task"
        case .searchContext: "Search Context"
        case .getContextRecord: "Get Context record"
        }
    }
}

public enum RuntimeOperationSupport:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case supported
    case conditional
    case unsupported
}

public enum RuntimeObservationFidelity:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case nativeStream = "native_stream"
    case mirroredStream = "mirrored_stream"
    case polling
    case snapshot
    case none

    public var displayName: String {
        switch self {
        case .nativeStream: "Native stream"
        case .mirroredStream: "Mirrored stream"
        case .polling: "Polling"
        case .snapshot: "Snapshot"
        case .none: "None"
        }
    }
}

public struct RuntimeGatewayOperationDeclaration:
    Codable,
    Hashable,
    Sendable
{
    public var operation: RuntimeGatewayOperation
    public var support: RuntimeOperationSupport
    public var condition: String?

    public init(
        operation: RuntimeGatewayOperation,
        support: RuntimeOperationSupport,
        condition: String? = nil
    ) {
        self.operation = operation
        self.support = support
        self.condition = condition
    }
}

/// A probeable, provider-neutral capability statement. It is deliberately
/// more precise than the legacy RuntimeCapability summary used by older UI.
public struct RuntimeGatewayManifest:
    Codable,
    Hashable,
    Sendable
{
    public var contractVersion: Int
    public var adapterID: String
    public var provider: ConversationProvider
    public var connectionKind: AgentConnectionKind
    public var controlMode: RuntimeControlMode
    public var trustLevel: AgentTrustLevel
    public var observationFidelity: RuntimeObservationFidelity
    public var operations: [RuntimeGatewayOperationDeclaration]
    public var instanceIdentity: AgentRuntimeInstanceIdentity
    public var notes: [String]

    public init(
        contractVersion: Int = 1,
        adapterID: String,
        provider: ConversationProvider,
        connectionKind: AgentConnectionKind,
        controlMode: RuntimeControlMode,
        trustLevel: AgentTrustLevel,
        observationFidelity: RuntimeObservationFidelity,
        operations: [RuntimeGatewayOperationDeclaration],
        instanceIdentity: AgentRuntimeInstanceIdentity,
        notes: [String] = []
    ) {
        self.contractVersion = contractVersion
        self.adapterID = adapterID
        self.provider = provider
        self.connectionKind = connectionKind
        self.controlMode = controlMode
        self.trustLevel = trustLevel
        self.observationFidelity = observationFidelity
        self.operations = operations.sorted {
            $0.operation.rawValue < $1.operation.rawValue
        }
        self.instanceIdentity = instanceIdentity
        self.notes = notes
    }

    public func support(
        for operation: RuntimeGatewayOperation
    ) -> RuntimeOperationSupport {
        operations.first { $0.operation == operation }?.support
            ?? .unsupported
    }

    public func condition(
        for operation: RuntimeGatewayOperation
    ) -> String? {
        operations.first { $0.operation == operation }?.condition
    }

    public func supports(
        _ operation: RuntimeGatewayOperation,
        endpointIsActive: Bool
    ) -> Bool {
        switch support(for: operation) {
        case .supported:
            true
        case .conditional:
            endpointIsActive
        case .unsupported:
            false
        }
    }
}

/// Persisted probe snapshot. The endpoint UUID is the registration identity so
/// a manifest survives app restart without inventing a second Runtime.
public struct RuntimeAdapterRegistration:
    Identifiable,
    Codable,
    Hashable,
    Sendable
{
    public var id: UUID
    public var endpointID: UUID
    public var manifest: RuntimeGatewayManifest
    public var probedAt: Date

    public init(
        endpointID: UUID,
        manifest: RuntimeGatewayManifest,
        probedAt: Date = Date()
    ) {
        self.id = endpointID
        self.endpointID = endpointID
        self.manifest = manifest
        self.probedAt = probedAt
    }
}

/// Extension point for a compiled local adapter or a future remote BYOA
/// connector. History is an optional facet rather than proof of live control.
public protocol RuntimeGatewayAdapter: Sendable {
    var adapterID: String { get }
    var provider: ConversationProvider { get }

    func manifest(for endpoint: RuntimeEndpoint) -> RuntimeGatewayManifest
}

public struct BuiltinRuntimeGatewayAdapter:
    RuntimeGatewayAdapter,
    Sendable
{
    public var adapterID: String
    public var provider: ConversationProvider
    public var connectionKind: AgentConnectionKind
    public var controlMode: RuntimeControlMode
    public var trustLevel: AgentTrustLevel
    public var observationFidelity: RuntimeObservationFidelity
    public var declarations: [RuntimeGatewayOperationDeclaration]
    public var notes: [String]

    public init(
        adapterID: String,
        provider: ConversationProvider,
        connectionKind: AgentConnectionKind,
        controlMode: RuntimeControlMode,
        trustLevel: AgentTrustLevel,
        observationFidelity: RuntimeObservationFidelity,
        declarations: [RuntimeGatewayOperationDeclaration],
        notes: [String] = []
    ) {
        self.adapterID = adapterID
        self.provider = provider
        self.connectionKind = connectionKind
        self.controlMode = controlMode
        self.trustLevel = trustLevel
        self.observationFidelity = observationFidelity
        self.declarations = declarations
        self.notes = notes
    }

    public func manifest(
        for endpoint: RuntimeEndpoint
    ) -> RuntimeGatewayManifest {
        RuntimeGatewayManifest(
            adapterID: adapterID,
            provider: provider,
            connectionKind: connectionKind,
            controlMode: controlMode,
            trustLevel: trustLevel,
            observationFidelity: observationFidelity,
            operations: declarations,
            instanceIdentity: endpoint.resolvedInstanceIdentity,
            notes: notes
        )
    }
}

public enum RuntimeGatewayRegistry {
    public static let codex = BuiltinRuntimeGatewayAdapter(
        adapterID: "mu.runtime.codex-app-server",
        provider: .codex,
        connectionKind: .managedRuntime,
        controlMode: .managedLimited,
        trustLevel: .managed,
        observationFidelity: .mirroredStream,
        declarations: [
            supported(.discoverHistory),
            supported(.readHistory),
            conditional(
                .createSession,
                "Requires an active official App Server probe."
            ),
            conditional(
                .submitInput,
                "Requires an active thread in the exact Project workspace."
            ),
            conditional(
                .observeEvents,
                "Mu mirrors visible assistant output; reasoning stays private."
            ),
            conditional(
                .interrupt,
                "Requires a recorded native thread and active turn."
            ),
            conditional(
                .resume,
                "Requires a recorded persistent native thread."
            ),
            unsupported(.resolveApproval),
            unsupported(.listArtifacts),
            supported(.submitArtifact),
            conditional(.acceptTaskLease, "Requires an active endpoint."),
            conditional(.renewTaskLease, "Requires an active endpoint."),
            supported(.publishProjectEvent),
            supported(.completeTask),
            supported(.failTask),
            conditional(
                .searchContext,
                "Requires the exact active Runtime binding and Run, plus a "
                    + "governed Context Pack with a delivered receipt."
            ),
            conditional(
                .getContextRecord,
                "Requires the exact active Runtime binding and Run, plus a "
                    + "governed Context Pack with a delivered receipt."
            )
        ],
        notes: [
            "Mu starts the official App Server process.",
            "Initial runs and continuations use a read-only sandbox with approvals disabled."
        ]
    )

    public static let claudeCode = BuiltinRuntimeGatewayAdapter(
        adapterID: "mu.runtime.claude-code-cli",
        provider: .claudeCode,
        connectionKind: .managedRuntime,
        controlMode: .managedLimited,
        trustLevel: .managed,
        observationFidelity: .mirroredStream,
        declarations: [
            supported(.discoverHistory),
            supported(.readHistory),
            conditional(
                .createSession,
                "Requires a verified, signed-in Claude Code CLI."
            ),
            unsupported(.attachSession),
            conditional(
                .submitInput,
                "Requires an active exact-workspace CLI session."
            ),
            conditional(
                .observeEvents,
                "Visible stream-json text is mirrored; thinking and tool internals are excluded."
            ),
            conditional(
                .interrupt,
                "Available while the Mu-launched CLI process is active."
            ),
            conditional(
                .resume,
                "Requires a persisted Claude Code session ID."
            ),
            unsupported(.resolveApproval),
            unsupported(.listArtifacts),
            supported(.submitArtifact),
            conditional(.acceptTaskLease, "Requires an active endpoint."),
            conditional(.renewTaskLease, "Requires an active endpoint."),
            supported(.publishProjectEvent),
            supported(.completeTask),
            supported(.failTask),
            conditional(
                .searchContext,
                "Requires the exact active Runtime binding and Run, plus a "
                    + "governed Context Pack with a delivered receipt."
            ),
            conditional(
                .getContextRecord,
                "Requires the exact active Runtime binding and Run, plus a "
                    + "governed Context Pack with a delivered receipt."
            )
        ],
        notes: [
            "Mu launches Claude Code print mode with structured stream-json output.",
            "The initial safety profile is read-only and never bypasses permission checks."
        ]
    )

    public static let openWorker = BuiltinRuntimeGatewayAdapter(
        adapterID: "mu.runtime.openworker-sidecar",
        provider: .openWorker,
        connectionKind: .connectedAgent,
        controlMode: .attached,
        trustLevel: .connected,
        observationFidelity: .nativeStream,
        declarations: [
            supported(.discoverHistory),
            supported(.readHistory),
            conditional(
                .createSession,
                "Requires a verified loopback sidecar."
            ),
            conditional(
                .attachSession,
                "Requires an exact-workspace native session."
            ),
            conditional(.submitInput, "Requires an idle linked session."),
            conditional(
                .observeEvents,
                "Requires a verified session WebSocket."
            ),
            conditional(.interrupt, "Requires a live linked session."),
            conditional(.resume, "Requires a persistent native session."),
            conditional(
                .resolveApproval,
                "Requires a pending native Inbox request."
            ),
            conditional(
                .listArtifacts,
                "Requires a verified exact-workspace session."
            ),
            supported(.submitArtifact),
            conditional(.acceptTaskLease, "Requires an active endpoint."),
            conditional(.renewTaskLease, "Requires a live binding heartbeat."),
            supported(.publishProjectEvent),
            supported(.completeTask),
            supported(.failTask),
            conditional(
                .searchContext,
                "Requires the exact active Runtime binding and Run, plus a "
                    + "governed Context Pack with a delivered receipt."
            ),
            conditional(
                .getContextRecord,
                "Requires the exact active Runtime binding and Run, plus a "
                    + "governed Context Pack with a delivered receipt."
            )
        ],
        notes: [
            "OpenWorker Desktop owns its process; Mu attaches to the verified local sidecar.",
            "Workspace, session identity, approvals, and artifacts are validated before use."
        ]
    )

    public static func adapter(
        for endpoint: RuntimeEndpoint
    ) -> (any RuntimeGatewayAdapter)? {
        switch endpoint.runtimeTypeID {
        case ControlPlaneService.codexRuntimeTypeID:
            codex
        case ControlPlaneService.claudeCodeRuntimeTypeID:
            claudeCode
        case ControlPlaneService.openWorkerRuntimeTypeID:
            openWorker
        default:
            nil
        }
    }

    public static func manifest(
        for endpoint: RuntimeEndpoint
    ) -> RuntimeGatewayManifest {
        if let adapter = adapter(for: endpoint) {
            return adapter.manifest(for: endpoint)
        }
        let provider = endpoint.resolvedInstanceIdentity.provider
        let operations = RuntimeGatewayOperation.allCases.map {
            RuntimeGatewayOperationDeclaration(
                operation: $0,
                support: .unsupported
            )
        }
        return RuntimeGatewayManifest(
            adapterID: "mu.runtime.unimplemented",
            provider: provider,
            connectionKind: .toolHost,
            controlMode: endpoint.provenance == .artifactOnly
                ? .submitOnly
                : .historyOnly,
            trustLevel: .submitOnly,
            observationFidelity: .none,
            operations: operations,
            instanceIdentity: endpoint.resolvedInstanceIdentity,
            notes: [
                "No compiled Gateway adapter is registered for this endpoint."
            ]
        )
    }

    public static func require(
        _ operation: RuntimeGatewayOperation,
        endpoint: RuntimeEndpoint
    ) throws {
        let manifest = manifest(for: endpoint)
        guard manifest.supports(
            operation,
            endpointIsActive: endpoint.status == .active
        ) else {
            let condition = manifest.condition(for: operation).map {
                " \($0)"
            } ?? ""
            throw MuError.capabilityMissing(
                "\(endpoint.displayName) does not currently support "
                    + "\(operation.displayName).\(condition)"
            )
        }
    }

    private static func supported(
        _ operation: RuntimeGatewayOperation
    ) -> RuntimeGatewayOperationDeclaration {
        RuntimeGatewayOperationDeclaration(
            operation: operation,
            support: .supported
        )
    }

    private static func conditional(
        _ operation: RuntimeGatewayOperation,
        _ condition: String
    ) -> RuntimeGatewayOperationDeclaration {
        RuntimeGatewayOperationDeclaration(
            operation: operation,
            support: .conditional,
            condition: condition
        )
    }

    private static func unsupported(
        _ operation: RuntimeGatewayOperation
    ) -> RuntimeGatewayOperationDeclaration {
        RuntimeGatewayOperationDeclaration(
            operation: operation,
            support: .unsupported
        )
    }
}

public extension RuntimeEndpoint {
    var gatewayManifest: RuntimeGatewayManifest {
        RuntimeGatewayRegistry.manifest(for: self)
    }
}
