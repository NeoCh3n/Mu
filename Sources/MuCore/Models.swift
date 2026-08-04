import Foundation

public enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case draft
    case ready
    case running
    case handoffPending = "handoff_pending"
    case blocked
    case completed
    case failed
    case cancelled

    public var displayName: String {
        switch self {
        case .draft: "Draft"
        case .ready: "Ready"
        case .running: "Running"
        case .handoffPending: "Handoff pending"
        case .blocked: "Blocked"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    public var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }
}

public enum RunState: String, Codable, CaseIterable, Sendable {
    case created
    case starting
    case active
    case checkpointed
    case blocked
    case degraded
    case ambiguous
    case completed
    case failed
    case cancelled
}

public enum RunPurpose: String, Codable, Sendable {
    case execution
    case delegation
    case replan
    case review
}

public enum HandoffStatus: String, Codable, CaseIterable, Sendable {
    case proposed
    case validating
    case accepted
    case rejected
    case expired
    case cancelled
}

public enum EndpointStatus: String, Codable, CaseIterable, Sendable {
    case discovered
    case probing
    case active
    case degraded
    case quarantined
    case offline
}

public enum EndpointLocation: String, Codable, CaseIterable, Sendable {
    case local
    case hosted
    case remote
}

public enum IntegrationProvenance: String, Codable, CaseIterable, Sendable {
    case synthetic
    case vendorProtocol = "vendor_protocol"
    case vendorSDK = "vendor_sdk"
    case vendorCLI = "vendor_cli"
    case artifactOnly = "artifact_only"

    public var displayName: String {
        switch self {
        case .synthetic: "Synthetic fixture"
        case .vendorProtocol: "Vendor protocol"
        case .vendorSDK: "Vendor SDK"
        case .vendorCLI: "Vendor CLI"
        case .artifactOnly: "Artifact only"
        }
    }
}

public enum PermissionModel: String, Codable, CaseIterable, Sendable {
    case fineGrained = "fine_grained"
    case promptGate = "prompt_gate"
    case allOrNothing = "all_or_nothing"
    case none
    case unknown

    public var displayName: String {
        switch self {
        case .fineGrained: "Fine-grained"
        case .promptGate: "Prompt gate"
        case .allOrNothing: "All or nothing"
        case .none: "No permissions"
        case .unknown: "Runtime-defined"
        }
    }
}

public enum RuntimeCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case start
    case continueRun = "continue"
    case replan
    case cancel
    case streamEvents = "stream_events"
    case contributeCheckpointEvidence = "contribute_checkpoint_evidence"
    case discoverGitArtifacts = "discover_git_artifacts"
    case approvalIntent = "approval_intent"

    public var displayName: String {
        rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

public enum AgentRole: String, Codable, CaseIterable, Sendable {
    case orchestrator
    case builder
    case researcher
    case reviewer

    public var displayName: String {
        rawValue.capitalized
    }
}

public enum AgentAvailability: String, Codable, CaseIterable, Sendable {
    case available
    case busy
    case offline
}

public struct AgentIdentity: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var displayName: String
    public var shortName: String
    public var role: AgentRole
    public var summary: String
    public var preferredEndpointID: UUID?
    public var capabilityTags: [String]
    public var accentHex: String
    public var availability: AgentAvailability
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        displayName: String,
        shortName: String,
        role: AgentRole,
        summary: String,
        preferredEndpointID: UUID? = nil,
        capabilityTags: [String] = [],
        accentHex: String,
        availability: AgentAvailability = .available,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.shortName = shortName
        self.role = role
        self.summary = summary
        self.preferredEndpointID = preferredEndpointID
        self.capabilityTags = capabilityTags
        self.accentHex = accentHex
        self.availability = availability
        self.createdAt = createdAt
    }
}

public enum RegistryEntityKind: String, Codable, Sendable {
    case agentIdentity = "agent_identity"
    case runtimeEndpoint = "runtime_endpoint"
}

public struct RegistryTombstone: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var entityKind: RegistryEntityKind
    public var displayName: String
    public var deletedAt: Date

    public init(
        id: UUID,
        entityKind: RegistryEntityKind,
        displayName: String,
        deletedAt: Date = Date()
    ) {
        self.id = id
        self.entityKind = entityKind
        self.displayName = displayName
        self.deletedAt = deletedAt
    }
}

public enum ChatAuthorKind: String, Codable, Sendable {
    case user
    case agent
    case system
}

public enum ChatDeliveryState: String, Codable, Sendable {
    case local
    case awaitingSession = "awaiting_session"
    case queued
    case routing
    case sending
    case delivered
    case mirrored
    case failed
    case ambiguous
    case cancelled
}

public struct ChatEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var taskID: UUID
    /// Optional collaboration references keep legacy Task-backed chat JSON
    /// readable while allowing a Thread to become the durable UI scope.
    public var spaceID: UUID?
    public var threadID: UUID?
    public var workItemID: UUID?
    public var agentIdentityID: UUID?
    public var targetAgentIdentityID: UUID?
    public var targetEndpointID: UUID?
    public var runID: UUID?
    public var runtimeSessionBindingID: UUID?
    public var nativeMessageIndex: Int?
    public var nativeMessageIndexLowerBound: Int?
    /// Optional per-message model override chosen in the Project composer.
    /// The endpoint default remains authoritative when this is nil.
    public var requestedModel: String?
    public var deliveryState: ChatDeliveryState?
    public var routedText: String?
    public var contextFreeRoutedText: String?
    public var contextSnapshotID: UUID?
    public var authorKind: ChatAuthorKind
    public var authorName: String
    public var text: String
    public var createdAt: Date
    public var updatedAt: Date?

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        spaceID: UUID? = nil,
        threadID: UUID? = nil,
        workItemID: UUID? = nil,
        agentIdentityID: UUID? = nil,
        targetAgentIdentityID: UUID? = nil,
        targetEndpointID: UUID? = nil,
        runID: UUID? = nil,
        runtimeSessionBindingID: UUID? = nil,
        nativeMessageIndex: Int? = nil,
        nativeMessageIndexLowerBound: Int? = nil,
        requestedModel: String? = nil,
        deliveryState: ChatDeliveryState? = nil,
        routedText: String? = nil,
        contextFreeRoutedText: String? = nil,
        contextSnapshotID: UUID? = nil,
        authorKind: ChatAuthorKind,
        authorName: String,
        text: String,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.spaceID = spaceID
        self.threadID = threadID
        self.workItemID = workItemID
        self.agentIdentityID = agentIdentityID
        self.targetAgentIdentityID = targetAgentIdentityID
        self.targetEndpointID = targetEndpointID
        self.runID = runID
        self.runtimeSessionBindingID = runtimeSessionBindingID
        self.nativeMessageIndex = nativeMessageIndex
        self.nativeMessageIndexLowerBound = nativeMessageIndexLowerBound
        self.requestedModel = requestedModel
        self.deliveryState = deliveryState
        self.routedText = routedText
        self.contextFreeRoutedText = contextFreeRoutedText
        self.contextSnapshotID = contextSnapshotID
        self.authorKind = authorKind
        self.authorName = authorName
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum RuntimeSessionState: String, Codable, CaseIterable, Sendable {
    case connecting
    case idle
    case working
    case awaitingApproval = "awaiting_approval"
    case completed
    case failed
    case disconnected
    case detached

    public var displayName: String {
        switch self {
        case .connecting: "Connecting"
        case .idle: "Ready"
        case .working: "Working"
        case .awaitingApproval: "Needs approval"
        case .completed: "Completed"
        case .failed: "Failed"
        case .disconnected: "Disconnected"
        case .detached: "Detached"
        }
    }
}

public struct RuntimeSessionBinding: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var taskID: UUID
    public var spaceID: UUID?
    public var threadID: UUID?
    public var workItemID: UUID?
    public var projectID: UUID?
    public var workspaceID: UUID?
    public var actorID: UUID?
    public var principalID: UUID?
    public var taskLeaseID: UUID?
    public var runID: UUID?
    public var contextPackID: UUID?
    public var endpointID: UUID
    public var agentIdentityID: UUID?
    public var nativeSessionID: String
    public var nativeAgentName: String
    public var workspacePath: String
    public var model: String?
    public var connectionMode: String
    public var origin: String
    public var state: RuntimeSessionState
    public var lastSyncedMessageCount: Int
    public var lastActivitySummary: String
    public var lastError: String?
    public var version: Int64?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        spaceID: UUID? = nil,
        threadID: UUID? = nil,
        workItemID: UUID? = nil,
        projectID: UUID? = nil,
        workspaceID: UUID? = nil,
        actorID: UUID? = nil,
        principalID: UUID? = nil,
        taskLeaseID: UUID? = nil,
        runID: UUID? = nil,
        contextPackID: UUID? = nil,
        endpointID: UUID,
        agentIdentityID: UUID? = nil,
        nativeSessionID: String,
        nativeAgentName: String,
        workspacePath: String,
        model: String? = nil,
        connectionMode: String,
        origin: String = "created_by_mu",
        state: RuntimeSessionState = .connecting,
        lastSyncedMessageCount: Int = 0,
        lastActivitySummary: String = "Connecting to the native session.",
        lastError: String? = nil,
        version: Int64? = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.spaceID = spaceID
        self.threadID = threadID
        self.workItemID = workItemID
        self.projectID = projectID
        self.workspaceID = workspaceID
        self.actorID = actorID
        self.principalID = principalID
        self.taskLeaseID = taskLeaseID
        self.runID = runID
        self.contextPackID = contextPackID
        self.endpointID = endpointID
        self.agentIdentityID = agentIdentityID
        self.nativeSessionID = nativeSessionID
        self.nativeAgentName = nativeAgentName
        self.workspacePath = workspacePath
        self.model = model
        self.connectionMode = connectionMode
        self.origin = origin
        self.state = state
        self.lastSyncedMessageCount = lastSyncedMessageCount
        self.lastActivitySummary = lastActivitySummary
        self.lastError = lastError
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum RuntimeInteractionKind: String, Codable, Sendable {
    case approval
    case directory
    case plan
    case question
}

public enum RuntimeInteractionState: String, Codable, Sendable {
    case pending
    case approved
    case denied
    case answered
    case superseded
}

public struct RuntimeInteractionRequest: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var taskID: UUID
    public var projectApprovalID: UUID?
    public var bindingID: UUID
    public var endpointID: UUID
    public var nativeSessionID: String
    public var nativeRequestID: String?
    public var kind: RuntimeInteractionKind
    public var title: String
    public var detail: String
    public var payload: [String: String]
    public var state: RuntimeInteractionState
    public var createdAt: Date
    public var resolvedAt: Date?

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        projectApprovalID: UUID? = nil,
        bindingID: UUID,
        endpointID: UUID,
        nativeSessionID: String,
        nativeRequestID: String? = nil,
        kind: RuntimeInteractionKind,
        title: String,
        detail: String = "",
        payload: [String: String] = [:],
        state: RuntimeInteractionState = .pending,
        createdAt: Date = Date(),
        resolvedAt: Date? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.projectApprovalID = projectApprovalID
        self.bindingID = bindingID
        self.endpointID = endpointID
        self.nativeSessionID = nativeSessionID
        self.nativeRequestID = nativeRequestID
        self.kind = kind
        self.title = title
        self.detail = detail
        self.payload = payload
        self.state = state
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
    }
}

public struct RuntimeArtifactRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var taskID: UUID
    public var projectArtifactID: UUID?
    public var bindingID: UUID
    public var endpointID: UUID
    public var nativeSessionID: String
    public var relativePath: String
    public var absolutePath: String?
    public var name: String
    public var kind: String
    public var byteCount: Int64
    public var modifiedAt: Date
    public var observedAt: Date

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        projectArtifactID: UUID? = nil,
        bindingID: UUID,
        endpointID: UUID,
        nativeSessionID: String,
        relativePath: String,
        absolutePath: String? = nil,
        name: String,
        kind: String,
        byteCount: Int64,
        modifiedAt: Date,
        observedAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.projectArtifactID = projectArtifactID
        self.bindingID = bindingID
        self.endpointID = endpointID
        self.nativeSessionID = nativeSessionID
        self.relativePath = relativePath
        self.absolutePath = absolutePath
        self.name = name
        self.kind = kind
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
        self.observedAt = observedAt
    }
}

public struct TaskRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// Collaboration references are optional during the migration from the
    /// legacy Task-centric local model.
    public var spaceID: UUID?
    public var threadID: UUID?
    public var workItemID: UUID?
    public var projectID: UUID?
    public var workspaceID: UUID?
    public var requestedByActorID: UUID?
    public var assignedActorID: UUID?
    public var title: String
    public var objective: String
    public var successCriteria: [String]
    public var constraints: [String]
    public var pendingSteps: [String]
    public var repositoryPath: String
    public var status: TaskStatus
    public var currentEndpointID: UUID?
    public var currentRunID: UUID?
    public var assignedAgentIdentityID: UUID?
    public var version: Int64?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        spaceID: UUID? = nil,
        threadID: UUID? = nil,
        workItemID: UUID? = nil,
        projectID: UUID? = nil,
        workspaceID: UUID? = nil,
        requestedByActorID: UUID? = nil,
        assignedActorID: UUID? = nil,
        title: String,
        objective: String,
        successCriteria: [String],
        constraints: [String],
        pendingSteps: [String],
        repositoryPath: String,
        status: TaskStatus = .ready,
        currentEndpointID: UUID? = nil,
        currentRunID: UUID? = nil,
        assignedAgentIdentityID: UUID? = nil,
        version: Int64? = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.spaceID = spaceID
        self.threadID = threadID
        self.workItemID = workItemID
        self.projectID = projectID
        self.workspaceID = workspaceID
        self.requestedByActorID = requestedByActorID
        self.assignedActorID = assignedActorID
        self.title = title
        self.objective = objective
        self.successCriteria = successCriteria
        self.constraints = constraints
        self.pendingSteps = pendingSteps
        self.repositoryPath = repositoryPath
        self.status = status
        self.currentEndpointID = currentEndpointID
        self.currentRunID = currentRunID
        self.assignedAgentIdentityID = assignedAgentIdentityID
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct RunRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var taskID: UUID
    public var spaceID: UUID?
    public var threadID: UUID?
    public var workItemID: UUID?
    public var projectID: UUID?
    public var workspaceID: UUID?
    public var actorID: UUID?
    public var principalID: UUID?
    public var taskLeaseID: UUID?
    public var contextPackID: UUID?
    public var endpointID: UUID
    public var actorName: String
    public var purpose: RunPurpose
    public var state: RunState
    public var plan: [String]
    public var nativeThreadID: String?
    public var nativeTurnID: String?
    public var nativeOutput: String?
    public var agentIdentityID: UUID?
    public var version: Int64?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        spaceID: UUID? = nil,
        threadID: UUID? = nil,
        workItemID: UUID? = nil,
        projectID: UUID? = nil,
        workspaceID: UUID? = nil,
        actorID: UUID? = nil,
        principalID: UUID? = nil,
        taskLeaseID: UUID? = nil,
        contextPackID: UUID? = nil,
        endpointID: UUID,
        actorName: String,
        purpose: RunPurpose,
        state: RunState,
        plan: [String] = [],
        nativeThreadID: String? = nil,
        nativeTurnID: String? = nil,
        nativeOutput: String? = nil,
        agentIdentityID: UUID? = nil,
        version: Int64? = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.spaceID = spaceID
        self.threadID = threadID
        self.workItemID = workItemID
        self.projectID = projectID
        self.workspaceID = workspaceID
        self.actorID = actorID
        self.principalID = principalID
        self.taskLeaseID = taskLeaseID
        self.contextPackID = contextPackID
        self.endpointID = endpointID
        self.actorName = actorName
        self.purpose = purpose
        self.state = state
        self.plan = plan
        self.nativeThreadID = nativeThreadID
        self.nativeTurnID = nativeTurnID
        self.nativeOutput = nativeOutput
        self.agentIdentityID = agentIdentityID
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct RuntimeEndpoint: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var runtimeTypeID: String
    public var displayName: String
    public var adapterVersion: String
    public var runtimeVersion: String
    public var location: EndpointLocation
    public var provenance: IntegrationProvenance
    public var permissionModel: PermissionModel
    public var capabilities: Set<RuntimeCapability>
    public var status: EndpointStatus
    public var guaranteeNote: String
    public var lastProbedAt: Date
    public var nativeConfiguration: [String: String]?
    public var instanceIdentity: AgentRuntimeInstanceIdentity?

    public init(
        id: UUID = UUID(),
        runtimeTypeID: String,
        displayName: String,
        adapterVersion: String,
        runtimeVersion: String,
        location: EndpointLocation,
        provenance: IntegrationProvenance,
        permissionModel: PermissionModel,
        capabilities: Set<RuntimeCapability>,
        status: EndpointStatus,
        guaranteeNote: String,
        lastProbedAt: Date = Date(),
        nativeConfiguration: [String: String]? = nil,
        instanceIdentity: AgentRuntimeInstanceIdentity? = nil
    ) {
        self.id = id
        self.runtimeTypeID = runtimeTypeID
        self.displayName = displayName
        self.adapterVersion = adapterVersion
        self.runtimeVersion = runtimeVersion
        self.location = location
        self.provenance = provenance
        self.permissionModel = permissionModel
        self.capabilities = capabilities
        self.status = status
        self.guaranteeNote = guaranteeNote
        self.lastProbedAt = lastProbedAt
        self.nativeConfiguration = nativeConfiguration
        self.instanceIdentity = instanceIdentity
    }
}

public struct CodexProbeResult: Codable, Hashable, Sendable {
    public var userAgent: String
    public var platformOS: String
    public var signedIn: Bool
    public var observedThreadCount: Int

    public init(
        userAgent: String,
        platformOS: String,
        signedIn: Bool,
        observedThreadCount: Int
    ) {
        self.userAgent = userAgent
        self.platformOS = platformOS
        self.signedIn = signedIn
        self.observedThreadCount = observedThreadCount
    }
}

public struct CodexReplanResult: Codable, Hashable, Sendable {
    public var threadID: String
    public var turnID: String
    public var output: String
    public var status: String

    public init(threadID: String, turnID: String, output: String, status: String) {
        self.threadID = threadID
        self.turnID = turnID
        self.output = output
        self.status = status
    }
}

public struct CodexTurnResult: Codable, Hashable, Sendable {
    public var threadID: String
    public var turnID: String
    public var output: String
    public var status: String
    public var errorMessage: String?
    public var historyReconciled: Bool

    public init(
        threadID: String,
        turnID: String,
        output: String,
        status: String,
        errorMessage: String? = nil,
        historyReconciled: Bool = false
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.output = output
        self.status = status
        self.errorMessage = errorMessage
        self.historyReconciled = historyReconciled
    }
}

public struct RepositorySnapshot: Codable, Hashable, Sendable {
    public var path: String
    public var isGitRepository: Bool
    public var branch: String
    public var baseCommit: String
    public var headCommit: String
    public var isDirty: Bool
    public var trackedPatchURI: String?
    public var trackedPatchSHA256: String?
    public var untrackedManifestURI: String?
    public var untrackedManifestSHA256: String?
    public var untrackedFiles: [String]

    public init(
        path: String,
        isGitRepository: Bool,
        branch: String = "",
        baseCommit: String = "",
        headCommit: String = "",
        isDirty: Bool = false,
        trackedPatchURI: String? = nil,
        trackedPatchSHA256: String? = nil,
        untrackedManifestURI: String? = nil,
        untrackedManifestSHA256: String? = nil,
        untrackedFiles: [String] = []
    ) {
        self.path = path
        self.isGitRepository = isGitRepository
        self.branch = branch
        self.baseCommit = baseCommit
        self.headCommit = headCommit
        self.isDirty = isDirty
        self.trackedPatchURI = trackedPatchURI
        self.trackedPatchSHA256 = trackedPatchSHA256
        self.untrackedManifestURI = untrackedManifestURI
        self.untrackedManifestSHA256 = untrackedManifestSHA256
        self.untrackedFiles = untrackedFiles
    }
}

public struct CheckpointContent: Codable, Hashable, Sendable {
    public var schemaVersion: String
    public var workspaceID: String
    public var taskID: UUID
    public var sourceRunID: UUID?
    public var sourceEndpointID: UUID
    public var objective: String
    public var successCriteria: [String]
    public var completedSteps: [String]
    public var pendingSteps: [String]
    public var acceptedDecisions: [String]
    public var rejectedAlternatives: [String]
    public var constraints: [String]
    public var permissionIntents: [String]
    public var repository: RepositorySnapshot
    public var verificationChecks: [String]
    public var openQuestions: [String]
    public var blockers: [String]
    public var recommendedSemantic: String
    public var createdAt: Date

    public init(
        schemaVersion: String = "0.1",
        workspaceID: String = "local",
        taskID: UUID,
        sourceRunID: UUID?,
        sourceEndpointID: UUID,
        objective: String,
        successCriteria: [String],
        completedSteps: [String] = [],
        pendingSteps: [String],
        acceptedDecisions: [String] = [],
        rejectedAlternatives: [String] = [],
        constraints: [String],
        permissionIntents: [String] = ["filesystem.workspace_write"],
        repository: RepositorySnapshot,
        verificationChecks: [String] = [],
        openQuestions: [String] = [],
        blockers: [String] = [],
        recommendedSemantic: String = "replan",
        createdAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.workspaceID = workspaceID
        self.taskID = taskID
        self.sourceRunID = sourceRunID
        self.sourceEndpointID = sourceEndpointID
        self.objective = objective
        self.successCriteria = successCriteria
        self.completedSteps = completedSteps
        self.pendingSteps = pendingSteps
        self.acceptedDecisions = acceptedDecisions
        self.rejectedAlternatives = rejectedAlternatives
        self.constraints = constraints
        self.permissionIntents = permissionIntents
        self.repository = repository
        self.verificationChecks = verificationChecks
        self.openQuestions = openQuestions
        self.blockers = blockers
        self.recommendedSemantic = recommendedSemantic
        self.createdAt = createdAt
    }
}

public struct CheckpointRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var taskID: UUID
    public var sourceEndpointID: UUID
    public var contentHash: String
    public var content: CheckpointContent
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        sourceEndpointID: UUID,
        contentHash: String,
        content: CheckpointContent,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.sourceEndpointID = sourceEndpointID
        self.contentHash = contentHash
        self.content = content
        self.createdAt = createdAt
    }
}

public struct HandoffRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var taskID: UUID
    public var checkpointID: UUID
    public var sourceEndpointID: UUID
    public var receiverEndpointID: UUID
    public var status: HandoffStatus
    public var validationMessage: String
    public var rejectionReason: String?
    public var createdAt: Date
    public var resolvedAt: Date?

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        checkpointID: UUID,
        sourceEndpointID: UUID,
        receiverEndpointID: UUID,
        status: HandoffStatus = .proposed,
        validationMessage: String = "",
        rejectionReason: String? = nil,
        createdAt: Date = Date(),
        resolvedAt: Date? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.checkpointID = checkpointID
        self.sourceEndpointID = sourceEndpointID
        self.receiverEndpointID = receiverEndpointID
        self.status = status
        self.validationMessage = validationMessage
        self.rejectionReason = rejectionReason
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
    }
}

public struct LedgerEvent: Identifiable, Codable, Hashable, Sendable {
    public var sequence: Int64
    public var id: UUID
    public var schemaVersion: String?
    public var projectID: UUID?
    public var actorID: UUID?
    public var principalID: UUID?
    public var workspaceID: UUID?
    public var artifactID: UUID?
    public var reviewID: UUID?
    public var approvalID: UUID?
    public var commandID: UUID?
    public var correlationID: UUID?
    public var taskID: UUID?
    public var runID: UUID?
    public var type: String
    public var summary: String
    public var payload: [String: String]
    public var causalParentID: UUID?
    public var occurredAt: Date

    public init(
        sequence: Int64 = 0,
        id: UUID = UUID(),
        schemaVersion: String? = "1.0",
        projectID: UUID? = nil,
        actorID: UUID? = nil,
        principalID: UUID? = nil,
        workspaceID: UUID? = nil,
        artifactID: UUID? = nil,
        reviewID: UUID? = nil,
        approvalID: UUID? = nil,
        commandID: UUID? = nil,
        correlationID: UUID? = nil,
        taskID: UUID? = nil,
        runID: UUID? = nil,
        type: String,
        summary: String,
        payload: [String: String] = [:],
        causalParentID: UUID? = nil,
        occurredAt: Date = Date()
    ) {
        self.sequence = sequence
        self.id = id
        self.schemaVersion = schemaVersion
        self.projectID = projectID
        self.actorID = actorID
        self.principalID = principalID
        self.workspaceID = workspaceID
        self.artifactID = artifactID
        self.reviewID = reviewID
        self.approvalID = approvalID
        self.commandID = commandID
        self.correlationID = correlationID
        self.taskID = taskID
        self.runID = runID
        self.type = type
        self.summary = summary
        self.payload = payload
        self.causalParentID = causalParentID
        self.occurredAt = occurredAt
    }
}

/// Safe, provider-neutral progress emitted by a native runtime. This is a
/// receipt timeline, not a transcript of private chain-of-thought.
public struct RuntimeActivityEvent: Codable, Hashable, Sendable {
    public var id: String?
    public var phase: String
    public var status: String
    public var title: String
    public var detail: String?
    public var toolName: String?
    public var path: String?
    public var command: String?
    public var requestID: String?
    public var artifactID: String?

    public init(
        id: String? = nil,
        phase: String,
        status: String,
        title: String,
        detail: String? = nil,
        toolName: String? = nil,
        path: String? = nil,
        command: String? = nil,
        requestID: String? = nil,
        artifactID: String? = nil
    ) {
        self.id = id
        self.phase = phase
        self.status = status
        self.title = title
        self.detail = detail
        self.toolName = toolName
        self.path = path
        self.command = command
        self.requestID = requestID
        self.artifactID = artifactID
    }
}

public enum MuError: LocalizedError, Equatable {
    case database(String)
    case invalidRepository(String)
    case commandFailed(String)
    case recordNotFound(String)
    case invalidTransition(String)
    case capabilityMissing(String)
    case artifactWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .database(let message): "Database error: \(message)"
        case .invalidRepository(let message): "Repository is not ready: \(message)"
        case .commandFailed(let message): "Command failed: \(message)"
        case .recordNotFound(let message): "Record not found: \(message)"
        case .invalidTransition(let message): "Invalid transition: \(message)"
        case .capabilityMissing(let message): "Capability requirement failed: \(message)"
        case .artifactWriteFailed(let message): "Could not write evidence: \(message)"
        }
    }
}

public enum MuCoding {
    public static func makeEncoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
