import Foundation

/// The shared collaboration surface. A Space describes who works together and
/// what collaboration content is visible; it is deliberately not a Project
/// or a Runtime execution boundary.
public enum CollaborationSpaceStatus: String, Codable, CaseIterable, Sendable {
    case active
    case archived
}

/// Records that participate in collaboration optimistic locking expose one
/// shared version contract. The version is incremented only after a write that
/// matched the caller's expected version.
public protocol CollaborationVersionedRecord: Codable, Sendable {
    var id: UUID { get }
    var version: Int64 { get set }
    var updatedAt: Date { get set }
}

public struct CollaborationSpaceRecord:
    Identifiable,
    Codable,
    Hashable,
    Sendable,
    CollaborationVersionedRecord
{
    public var id: UUID
    public var organizationID: UUID?
    public var displayName: String
    public var description: String
    public var createdByActorID: UUID?
    public var status: CollaborationSpaceStatus
    public var version: Int64
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        organizationID: UUID? = nil,
        displayName: String,
        description: String = "",
        createdByActorID: UUID? = nil,
        status: CollaborationSpaceStatus = .active,
        version: Int64 = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.organizationID = organizationID
        self.displayName = displayName
        self.description = description
        self.createdByActorID = createdByActorID
        self.status = status
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum SpaceThreadStatus: String, Codable, CaseIterable, Sendable {
    case active
    case resolved
    case archived
}

/// A durable discussion scope inside a Collaboration Space. A Thread may be
/// linked to a Project, but it can also remain project-free while a team is
/// deciding what work to do.
public struct SpaceThreadRecord:
    Identifiable,
    Codable,
    Hashable,
    Sendable,
    CollaborationVersionedRecord
{
    public var id: UUID
    public var spaceID: UUID
    public var projectID: UUID?
    public var title: String
    public var status: SpaceThreadStatus
    public var createdByActorID: UUID?
    public var version: Int64
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        spaceID: UUID,
        projectID: UUID? = nil,
        title: String = "New Thread",
        status: SpaceThreadStatus = .active,
        createdByActorID: UUID? = nil,
        version: Int64 = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.spaceID = spaceID
        self.projectID = projectID
        self.title = title
        self.status = status
        self.createdByActorID = createdByActorID
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum SpaceProjectVisibility: String, Codable, CaseIterable, Sendable {
    case metadata
    case artifacts
    case files
    case full
}

/// A many-to-many link. Joining a Space never implicitly grants Project access.
public struct SpaceProjectLinkRecord:
    Identifiable,
    Codable,
    Hashable,
    Sendable,
    CollaborationVersionedRecord
{
    public var id: UUID
    public var spaceID: UUID
    public var projectID: UUID
    public var visibility: SpaceProjectVisibility
    public var allowedResourceKinds: [String]
    public var defaultPermission: String
    public var version: Int64
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        spaceID: UUID,
        projectID: UUID,
        visibility: SpaceProjectVisibility = .metadata,
        allowedResourceKinds: [String] = [],
        defaultPermission: String = "view",
        version: Int64 = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.spaceID = spaceID
        self.projectID = projectID
        self.visibility = visibility
        self.allowedResourceKinds = allowedResourceKinds
        self.defaultPermission = defaultPermission
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum WorkItemStatus: String, Codable, CaseIterable, Sendable {
    case draft
    case ready
    case inProgress = "in_progress"
    case blocked
    case completed
    case cancelled
    case archived
}

public enum WorkItemPriority: String, Codable, CaseIterable, Sendable {
    case low
    case normal
    case high
    case urgent
}

/// A goal and its acceptance contract. It is intentionally separate from a
/// Thread (discussion) and an Agent Run (one execution attempt).
public struct WorkItemRecord:
    Identifiable,
    Codable,
    Hashable,
    Sendable,
    CollaborationVersionedRecord
{
    public var id: UUID
    public var spaceID: UUID
    public var threadID: UUID?
    public var projectID: UUID?
    public var title: String
    public var objective: String
    public var acceptanceCriteria: [String]
    public var status: WorkItemStatus
    public var priority: WorkItemPriority
    public var createdByActorID: UUID?
    public var assignedActorID: UUID?
    public var version: Int64
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        spaceID: UUID,
        threadID: UUID? = nil,
        projectID: UUID? = nil,
        title: String,
        objective: String = "",
        acceptanceCriteria: [String] = [],
        status: WorkItemStatus = .draft,
        priority: WorkItemPriority = .normal,
        createdByActorID: UUID? = nil,
        assignedActorID: UUID? = nil,
        version: Int64 = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.spaceID = spaceID
        self.threadID = threadID
        self.projectID = projectID
        self.title = title
        self.objective = objective
        self.acceptanceCriteria = acceptanceCriteria
        self.status = status
        self.priority = priority
        self.createdByActorID = createdByActorID
        self.assignedActorID = assignedActorID
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum SharedBlockType: String, Codable, CaseIterable, Sendable {
    case message
    case comment
    case plan
    case decision
    case workItemReference = "work_item_reference"
    case agentRunReference = "agent_run_reference"
    case artifactReference = "artifact_reference"
    case systemEvent = "system_event"
}

/// A presentation-level block in the shared canvas. Entity-backed blocks keep
/// only a typed reference; the referenced Work Item, Agent Run, or Artifact is
/// the sole authority for business state.
public struct SharedBlockRecord:
    Identifiable,
    Codable,
    Hashable,
    Sendable,
    CollaborationVersionedRecord
{
    public var id: UUID
    public var spaceID: UUID
    public var threadID: UUID?
    public var blockType: SharedBlockType
    public var authorActorID: UUID?
    public var entityReferenceType: String?
    public var entityReferenceID: UUID?
    public var presentationText: String?
    public var positionKey: String
    public var version: Int64
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        spaceID: UUID,
        threadID: UUID? = nil,
        blockType: SharedBlockType,
        authorActorID: UUID? = nil,
        entityReferenceType: String? = nil,
        entityReferenceID: UUID? = nil,
        presentationText: String? = nil,
        positionKey: String = "",
        version: Int64 = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.spaceID = spaceID
        self.threadID = threadID
        self.blockType = blockType
        self.authorActorID = authorActorID
        self.entityReferenceType = entityReferenceType
        self.entityReferenceID = entityReferenceID
        self.presentationText = presentationText
        self.positionKey = positionKey
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A read-only scope passed to workspace tools. Tools can inspect the same
/// repository as the selected Thread, but they must retain enough provenance
/// to show which Agent Run (if any) they describe. This is UI/tool context;
/// RunRecord and RuntimeSessionBinding remain the authorities for execution
/// state.
public struct WorkspaceToolBinding: Codable, Hashable, Sendable {
    public var taskID: UUID
    public var spaceID: UUID?
    public var threadID: UUID?
    public var workItemID: UUID?
    public var projectID: UUID?
    public var workspaceID: UUID?
    public var runID: UUID?
    public var runtimeSessionBindingID: UUID?
    public var endpointID: UUID?
    public var repositoryPath: String
    public var runLabel: String?

    public init(
        taskID: UUID,
        spaceID: UUID? = nil,
        threadID: UUID? = nil,
        workItemID: UUID? = nil,
        projectID: UUID? = nil,
        workspaceID: UUID? = nil,
        runID: UUID? = nil,
        runtimeSessionBindingID: UUID? = nil,
        endpointID: UUID? = nil,
        repositoryPath: String,
        runLabel: String? = nil
    ) {
        self.taskID = taskID
        self.spaceID = spaceID
        self.threadID = threadID
        self.workItemID = workItemID
        self.projectID = projectID
        self.workspaceID = workspaceID
        self.runID = runID
        self.runtimeSessionBindingID = runtimeSessionBindingID
        self.endpointID = endpointID
        self.repositoryPath = repositoryPath
        self.runLabel = runLabel
    }

    public var scopeLabel: String {
        if let runLabel, !runLabel.isEmpty {
            return "Run · \(runLabel)"
        }
        if let runID {
            return "Run · \(runID.uuidString.lowercased().prefix(8))"
        }
        return "Workspace · no active Run"
    }

    public var nativeBindingLabel: String? {
        guard let runtimeSessionBindingID else { return nil }
        return "Session · \(runtimeSessionBindingID.uuidString.lowercased().prefix(8))"
    }
}

/// Durable collaboration events are scoped to a Space/Thread. They describe
/// shared product state (messages, comments, work-item changes, membership)
/// and are intentionally separate from high-frequency Runtime receipts.
public struct SpaceEventRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var spaceID: UUID
    public var threadID: UUID?
    public var actorID: UUID?
    public var principalID: UUID?
    public var sequence: Int64
    public var eventType: String
    public var payload: [String: String]
    public var idempotencyKey: String?
    public var occurredAt: Date

    public init(
        id: UUID = UUID(),
        spaceID: UUID,
        threadID: UUID? = nil,
        actorID: UUID? = nil,
        principalID: UUID? = nil,
        sequence: Int64,
        eventType: String,
        payload: [String: String] = [:],
        idempotencyKey: String? = nil,
        occurredAt: Date = Date()
    ) {
        self.id = id
        self.spaceID = spaceID
        self.threadID = threadID
        self.actorID = actorID
        self.principalID = principalID
        self.sequence = sequence
        self.eventType = eventType
        self.payload = payload
        self.idempotencyKey = idempotencyKey
        self.occurredAt = occurredAt
    }
}

/// A Runtime event is an observable receipt, not a second authority for Run
/// state and never a persistence format for hidden chain-of-thought. Tool
/// calls, file references, approvals and visible output can be represented by
/// eventType/payload while RunRecord remains the state authority.
public struct RuntimeEventRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var runID: UUID
    public var bindingID: UUID?
    public var endpointID: UUID?
    public var sequence: Int64
    public var eventType: String
    public var summary: String
    public var payload: [String: String]
    public var occurredAt: Date

    public init(
        id: UUID = UUID(),
        runID: UUID,
        bindingID: UUID? = nil,
        endpointID: UUID? = nil,
        sequence: Int64,
        eventType: String,
        summary: String,
        payload: [String: String] = [:],
        occurredAt: Date = Date()
    ) {
        self.id = id
        self.runID = runID
        self.bindingID = bindingID
        self.endpointID = endpointID
        self.sequence = sequence
        self.eventType = eventType
        self.summary = summary
        self.payload = payload
        self.occurredAt = occurredAt
    }
}

public enum PresenceState: String, Codable, CaseIterable, Sendable {
    case online
    case idle
    case offline
}

/// Presence is deliberately short-lived and is not a collaboration event.
/// A server/client can expire it without rewriting durable Space history.
public struct PresenceSessionRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var spaceID: UUID
    public var actorID: UUID
    public var clientInstanceID: String
    public var displayName: String
    public var state: PresenceState
    public var lastSeenAt: Date
    public var expiresAt: Date

    public init(
        id: UUID = UUID(),
        spaceID: UUID,
        actorID: UUID,
        clientInstanceID: String,
        displayName: String,
        state: PresenceState = .online,
        lastSeenAt: Date = Date(),
        expiresAt: Date
    ) {
        self.id = id
        self.spaceID = spaceID
        self.actorID = actorID
        self.clientInstanceID = clientInstanceID
        self.displayName = displayName
        self.state = state
        self.lastSeenAt = lastSeenAt
        self.expiresAt = expiresAt
    }

    public func isExpired(at date: Date = Date()) -> Bool {
        expiresAt <= date
    }
}

public enum CollaborationOutboxState: String, Codable, CaseIterable, Sendable {
    case queued
    case sending
    case sent
    case failed
}

/// A local durable command waiting for a future shared Space transport. The
/// stream + idempotencyKey pair is the deduplication identity; retries must not
/// create a second shared event.
public struct CollaborationOutboxRecord:
    Identifiable,
    Codable,
    Hashable,
    Sendable,
    CollaborationVersionedRecord
{
    public var id: UUID
    public var spaceID: UUID
    public var actorID: UUID?
    public var stream: String
    public var idempotencyKey: String
    public var operation: String
    public var payload: [String: String]
    public var state: CollaborationOutboxState
    public var attempts: Int
    public var lastError: String?
    public var version: Int64
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        spaceID: UUID,
        actorID: UUID? = nil,
        stream: String,
        idempotencyKey: String,
        operation: String,
        payload: [String: String] = [:],
        state: CollaborationOutboxState = .queued,
        attempts: Int = 0,
        lastError: String? = nil,
        version: Int64 = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.spaceID = spaceID
        self.actorID = actorID
        self.stream = stream
        self.idempotencyKey = idempotencyKey
        self.operation = operation
        self.payload = payload
        self.state = state
        self.attempts = attempts
        self.lastError = lastError
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
