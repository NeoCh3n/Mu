import Foundation

/// Stable identifiers for Mu-owned records that are derived from an existing
/// local identity. This keeps legacy migrations idempotent across launches.
public enum MuStableIdentity {
    public static func uuid(
        namespace: String,
        components: [String]
    ) -> UUID {
        let material = ([namespace] + components).joined(separator: "\u{1F}")
        var hex = String(Data(material.utf8).muSHA256.prefix(32))
        let versionIndex = hex.index(hex.startIndex, offsetBy: 12)
        hex.replaceSubrange(
            versionIndex...versionIndex,
            with: "5"
        )
        let variantIndex = hex.index(hex.startIndex, offsetBy: 16)
        let variantValue = Int(String(hex[variantIndex]), radix: 16) ?? 0
        hex.replaceSubrange(
            variantIndex...variantIndex,
            with: String(format: "%x", (variantValue & 0x3) | 0x8)
        )
        let value =
            String(hex.prefix(8)) + "-"
            + String(hex.dropFirst(8).prefix(4)) + "-"
            + String(hex.dropFirst(12).prefix(4)) + "-"
            + String(hex.dropFirst(16).prefix(4)) + "-"
            + String(hex.dropFirst(20).prefix(12))
        return UUID(uuidString: value)!
    }
}

public enum ProjectStatus: String, Codable, CaseIterable, Sendable {
    case active
    case archived
}

/// The Mu-owned identity of a Project. A Project can exist without Tasks or an
/// online Runtime; external conversation databases never become its source of
/// truth.
public struct ProjectRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var displayName: String
    public var repositoryPath: String?
    public var ownerPrincipalID: UUID
    public var status: ProjectStatus
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        displayName: String,
        repositoryPath: String? = nil,
        ownerPrincipalID: UUID,
        status: ProjectStatus = .active,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.repositoryPath = repositoryPath.map(
            WorkspacePathIdentity.canonicalPath
        )
        self.ownerPrincipalID = ownerPrincipalID
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func stableID(repositoryPath: String) -> UUID {
        MuStableIdentity.uuid(
            namespace: "mu.project.repository",
            components: [
                WorkspacePathIdentity.canonicalPath(repositoryPath)
            ]
        )
    }
}

public enum PrincipalKind: String, Codable, CaseIterable, Sendable {
    case person
    case organization
    case project
}

public enum PrincipalStatus: String, Codable, CaseIterable, Sendable {
    case active
    case suspended
}

/// A person or organization that remains accountable for an Actor.
public struct PrincipalRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var kind: PrincipalKind
    public var displayName: String
    public var status: PrincipalStatus
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        kind: PrincipalKind,
        displayName: String,
        status: PrincipalStatus = .active,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum ProjectActorKind: String, Codable, CaseIterable, Sendable {
    case human
    case agent
}

public enum ProjectActorStatus: String, Codable, CaseIterable, Sendable {
    case active
    case suspended
    case retired
}

/// A first-class Project participant. Runtime instance identity remains
/// separate and can change without changing this durable Actor identity.
public struct ProjectActorRecord:
    Identifiable,
    Codable,
    Hashable,
    Sendable
{
    public var id: UUID
    public var principalID: UUID
    public var kind: ProjectActorKind
    public var displayName: String
    public var agentIdentityID: UUID?
    public var runtimeEndpointID: UUID?
    public var status: ProjectActorStatus
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        principalID: UUID,
        kind: ProjectActorKind,
        displayName: String,
        agentIdentityID: UUID? = nil,
        runtimeEndpointID: UUID? = nil,
        status: ProjectActorStatus = .active,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.principalID = principalID
        self.kind = kind
        self.displayName = displayName
        self.agentIdentityID = agentIdentityID
        self.runtimeEndpointID = runtimeEndpointID
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func stableRuntimeActorID(endpointID: UUID) -> UUID {
        MuStableIdentity.uuid(
            namespace: "mu.actor.runtime",
            components: [endpointID.uuidString.lowercased()]
        )
    }

    public static func stableAgentIdentityActorID(
        agentIdentityID: UUID
    ) -> UUID {
        MuStableIdentity.uuid(
            namespace: "mu.actor.agent-identity",
            components: [agentIdentityID.uuidString.lowercased()]
        )
    }
}

public enum ProjectMembershipRole:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case owner
    case lead
    case contributor
    case reviewer
    case externalAgent = "external_agent"
}

public enum ProjectMembershipStatus:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case invited
    case active
    case suspended
    case revoked
    case expired
}

public struct ProjectMembershipRecord:
    Identifiable,
    Codable,
    Hashable,
    Sendable
{
    public var id: UUID
    public var projectID: UUID
    public var actorID: UUID
    public var role: ProjectMembershipRole
    public var taskScope: [UUID]
    public var status: ProjectMembershipStatus
    public var expiresAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        actorID: UUID,
        role: ProjectMembershipRole,
        taskScope: [UUID] = [],
        status: ProjectMembershipStatus = .active,
        expiresAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.actorID = actorID
        self.role = role
        self.taskScope = taskScope
        self.status = status
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func stableID(projectID: UUID, actorID: UUID) -> UUID {
        MuStableIdentity.uuid(
            namespace: "mu.project-membership",
            components: [
                projectID.uuidString.lowercased(),
                actorID.uuidString.lowercased()
            ]
        )
    }

    public func isActive(at date: Date = Date()) -> Bool {
        status == .active && (expiresAt == nil || expiresAt! > date)
    }
}

public enum ProjectPermission:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Sendable
{
    case readProjectState = "project.read"
    case readRepository = "repository.read"
    case writeWorkspace = "workspace.write"
    case runCommands = "command.run"
    case runTests = "test.run"
    case useNetwork = "network.use"
    case acceptTask = "task.accept"
    case renewLease = "task.lease.renew"
    case publishEvent = "event.publish"
    case requestApproval = "approval.request"
    case submitArtifact = "artifact.submit"
    case completeTask = "task.complete"
    case manageTasks = "task.manage"
    case manageMembers = "membership.manage"
    case mergeAcceptedState = "project.merge"
    case readContext = "context.read"
    case readRestrictedContext = "context.restricted.read"
    case proposeContext = "context.propose"
    case reviewContext = "context.review"
    case manageContext = "context.manage"
    case declassifyContext = "context.declassify"
}

public enum DelegationStatus: String, Codable, CaseIterable, Sendable {
    case active
    case revoked
    case expired
}

/// A Principal's explicit, Project-scoped authority grant to an Agent Actor.
public struct DelegationRecord:
    Identifiable,
    Codable,
    Hashable,
    Sendable
{
    public var id: UUID
    public var projectID: UUID
    public var principalID: UUID
    public var delegatedByActorID: UUID
    public var agentActorID: UUID
    public var taskID: UUID?
    public var permissions: Set<ProjectPermission>
    public var restrictions: [String]
    public var status: DelegationStatus
    public var expiresAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        principalID: UUID,
        delegatedByActorID: UUID,
        agentActorID: UUID,
        taskID: UUID? = nil,
        permissions: Set<ProjectPermission>,
        restrictions: [String] = [],
        status: DelegationStatus = .active,
        expiresAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.principalID = principalID
        self.delegatedByActorID = delegatedByActorID
        self.agentActorID = agentActorID
        self.taskID = taskID
        self.permissions = permissions
        self.restrictions = restrictions
        self.status = status
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func stableID(
        projectID: UUID,
        agentActorID: UUID,
        taskID: UUID?
    ) -> UUID {
        MuStableIdentity.uuid(
            namespace: "mu.delegation",
            components: [
                projectID.uuidString.lowercased(),
                agentActorID.uuidString.lowercased(),
                taskID?.uuidString.lowercased() ?? "project"
            ]
        )
    }

    public func isActive(at date: Date = Date()) -> Bool {
        status == .active && (expiresAt == nil || expiresAt! > date)
    }
}

public enum WorkspaceIsolationKind:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case sharedProjectFolder = "shared_project_folder"
    case gitWorktree = "git_worktree"
    case documentVersion = "document_version"
    case externalSandbox = "external_sandbox"
}

public enum ProjectWorkspaceStatus:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case preparing
    case active
    case quiesced
    case closed
    case failed
}

public struct ProjectWorkspaceRecord:
    Identifiable,
    Codable,
    Hashable,
    Sendable
{
    public var id: UUID
    public var projectID: UUID
    public var taskID: UUID?
    public var repositoryPath: String
    public var worktreePath: String?
    public var branch: String?
    public var baseRevision: String?
    public var isolationKind: WorkspaceIsolationKind
    public var status: ProjectWorkspaceStatus
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        taskID: UUID? = nil,
        repositoryPath: String,
        worktreePath: String? = nil,
        branch: String? = nil,
        baseRevision: String? = nil,
        isolationKind: WorkspaceIsolationKind,
        status: ProjectWorkspaceStatus = .active,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.taskID = taskID
        self.repositoryPath = WorkspacePathIdentity.canonicalPath(
            repositoryPath
        )
        self.worktreePath = worktreePath.map(
            WorkspacePathIdentity.canonicalPath
        )
        self.branch = branch
        self.baseRevision = baseRevision
        self.isolationKind = isolationKind
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func stableID(taskID: UUID) -> UUID {
        MuStableIdentity.uuid(
            namespace: "mu.workspace.task",
            components: [taskID.uuidString.lowercased()]
        )
    }
}

/// Compatibility bridge while legacy Task JSON continues to use
/// `repositoryPath` as its embedded workspace reference.
public struct TaskProjectLink:
    Identifiable,
    Codable,
    Hashable,
    Sendable
{
    public var id: UUID
    public var taskID: UUID
    public var projectID: UUID
    public var workspaceID: UUID?
    public var requestedByActorID: UUID?
    public var assignedToActorID: UUID?
    public var reviewerActorID: UUID?
    public var approvalOwnerActorID: UUID?
    public var costOwnerPrincipalID: UUID?
    public var dependencyTaskIDs: [UUID]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID? = nil,
        taskID: UUID,
        projectID: UUID,
        workspaceID: UUID? = nil,
        requestedByActorID: UUID? = nil,
        assignedToActorID: UUID? = nil,
        reviewerActorID: UUID? = nil,
        approvalOwnerActorID: UUID? = nil,
        costOwnerPrincipalID: UUID? = nil,
        dependencyTaskIDs: [UUID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id ?? taskID
        self.taskID = taskID
        self.projectID = projectID
        self.workspaceID = workspaceID
        self.requestedByActorID = requestedByActorID
        self.assignedToActorID = assignedToActorID
        self.reviewerActorID = reviewerActorID
        self.approvalOwnerActorID = approvalOwnerActorID
        self.costOwnerPrincipalID = costOwnerPrincipalID
        self.dependencyTaskIDs = dependencyTaskIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum TaskLeaseState: String, Codable, CaseIterable, Sendable {
    case active
    case released
    case expired
    case revoked
}

public struct TaskLeaseRecord:
    Identifiable,
    Codable,
    Hashable,
    Sendable
{
    public var id: UUID
    public var projectID: UUID
    public var taskID: UUID
    public var agentActorID: UUID
    public var endpointID: UUID
    public var runtimeBindingID: UUID?
    public var fencingToken: Int64
    public var state: TaskLeaseState
    public var issuedAt: Date
    public var expiresAt: Date
    public var lastHeartbeatAt: Date
    public var releasedAt: Date?

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        taskID: UUID,
        agentActorID: UUID,
        endpointID: UUID,
        runtimeBindingID: UUID? = nil,
        fencingToken: Int64,
        state: TaskLeaseState = .active,
        issuedAt: Date = Date(),
        expiresAt: Date,
        lastHeartbeatAt: Date = Date(),
        releasedAt: Date? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.taskID = taskID
        self.agentActorID = agentActorID
        self.endpointID = endpointID
        self.runtimeBindingID = runtimeBindingID
        self.fencingToken = fencingToken
        self.state = state
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.lastHeartbeatAt = lastHeartbeatAt
        self.releasedAt = releasedAt
    }

    public func isActive(at date: Date = Date()) -> Bool {
        state == .active && expiresAt > date && releasedAt == nil
    }
}

public enum ProjectArtifactKind:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case contextPack = "context_pack"
    case runtimeOutput = "runtime_output"
    case patch
    case document
    case dataset
    case testResult = "test_result"
    case decision
    case checkpoint
}

public enum ProjectArtifactStatus:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case draft
    case submitted
    case accepted
    case rejected
    case superseded
}

public struct ProjectArtifactRecord:
    Identifiable,
    Codable,
    Hashable,
    Sendable
{
    public var id: UUID
    public var projectID: UUID
    public var taskID: UUID?
    public var producerActorID: UUID?
    public var kind: ProjectArtifactKind
    public var title: String
    public var uri: String
    public var sha256: String
    public var version: Int
    public var status: ProjectArtifactStatus
    public var sourceArtifactIDs: [UUID]
    public var metadata: [String: String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        taskID: UUID? = nil,
        producerActorID: UUID? = nil,
        kind: ProjectArtifactKind,
        title: String,
        uri: String,
        sha256: String,
        version: Int = 1,
        status: ProjectArtifactStatus = .submitted,
        sourceArtifactIDs: [UUID] = [],
        metadata: [String: String] = [:],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.taskID = taskID
        self.producerActorID = producerActorID
        self.kind = kind
        self.title = title
        self.uri = uri
        self.sha256 = sha256
        self.version = version
        self.status = status
        self.sourceArtifactIDs = sourceArtifactIDs
        self.metadata = metadata
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum ProjectReviewVerdict:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case pending
    case approved
    case changesRequested = "changes_requested"
    case rejected
}

public struct ProjectReviewRecord:
    Identifiable,
    Codable,
    Hashable,
    Sendable
{
    public var id: UUID
    public var projectID: UUID
    public var taskID: UUID?
    public var artifactID: UUID?
    public var reviewerActorID: UUID
    public var verdict: ProjectReviewVerdict
    public var findings: [String]
    public var createdAt: Date
    public var resolvedAt: Date?

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        taskID: UUID? = nil,
        artifactID: UUID? = nil,
        reviewerActorID: UUID,
        verdict: ProjectReviewVerdict = .pending,
        findings: [String] = [],
        createdAt: Date = Date(),
        resolvedAt: Date? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.taskID = taskID
        self.artifactID = artifactID
        self.reviewerActorID = reviewerActorID
        self.verdict = verdict
        self.findings = findings
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
    }
}

public enum ProjectApprovalDecision:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case pending
    case granted
    case denied
    case expired
    case revoked
}

public struct ProjectApprovalRecord:
    Identifiable,
    Codable,
    Hashable,
    Sendable
{
    public var id: UUID
    public var projectID: UUID
    public var taskID: UUID?
    public var runtimeInteractionID: UUID?
    public var requestedByActorID: UUID
    public var approverActorID: UUID?
    public var scope: String
    public var decision: ProjectApprovalDecision
    public var reason: String?
    public var createdAt: Date
    public var resolvedAt: Date?
    public var expiresAt: Date?

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        taskID: UUID? = nil,
        runtimeInteractionID: UUID? = nil,
        requestedByActorID: UUID,
        approverActorID: UUID? = nil,
        scope: String,
        decision: ProjectApprovalDecision = .pending,
        reason: String? = nil,
        createdAt: Date = Date(),
        resolvedAt: Date? = nil,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.taskID = taskID
        self.runtimeInteractionID = runtimeInteractionID
        self.requestedByActorID = requestedByActorID
        self.approverActorID = approverActorID
        self.scope = scope
        self.decision = decision
        self.reason = reason
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
        self.expiresAt = expiresAt
    }
}

/// The structured state shared with a Runtime for one Task. Raw imported
/// transcripts stay outside the Pack; only permission-filtered canonical
/// records and accepted artifacts are eligible for governed delivery.
public struct ProjectContextPackRecord:
    Identifiable,
    Codable,
    Hashable,
    Sendable
{
    public var id: UUID
    public var projectID: UUID
    public var taskID: UUID
    public var workspaceID: UUID
    public var objective: String
    public var relevantFilePaths: [String]
    public var acceptedArtifactIDs: [UUID]
    public var dependencyTaskIDs: [UUID]
    public var constraints: [String]
    public var permissions: [ProjectPermission]
    public var acceptanceTests: [String]
    public var expectedOutputs: [String]
    public var baseRevision: String?
    public var actorID: UUID?
    public var principalID: UUID?
    public var runtimeEndpointID: UUID?
    public var runtimeBindingID: UUID?
    public var taskLeaseID: UUID?
    public var leaseFencingToken: Int64?
    public var selectionPolicyVersion: String?
    public var tokenBudget: Int?
    public var contextRevision: String?
    public var taskRevision: String?
    public var policyRevision: String?
    public var itemSetFingerprint: String?
    public var budgetEstimatorVersion: String?
    public var canonicalizationVersion: String?
    public var includedContextRecordIDs: [UUID]?
    public var unresolvedContextConflictIDs: [UUID]?
    public var contextPackItemIDs: [UUID]?
    public var renderedContextMarkdown: String?
    public var renderedArtifactURI: String?
    public var contentSHA256: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        taskID: UUID,
        workspaceID: UUID,
        objective: String,
        relevantFilePaths: [String] = [],
        acceptedArtifactIDs: [UUID] = [],
        dependencyTaskIDs: [UUID] = [],
        constraints: [String] = [],
        permissions: [ProjectPermission] = [],
        acceptanceTests: [String] = [],
        expectedOutputs: [String] = [],
        baseRevision: String? = nil,
        actorID: UUID? = nil,
        principalID: UUID? = nil,
        runtimeEndpointID: UUID? = nil,
        runtimeBindingID: UUID? = nil,
        taskLeaseID: UUID? = nil,
        leaseFencingToken: Int64? = nil,
        selectionPolicyVersion: String? = nil,
        tokenBudget: Int? = nil,
        contextRevision: String? = nil,
        taskRevision: String? = nil,
        policyRevision: String? = nil,
        itemSetFingerprint: String? = nil,
        budgetEstimatorVersion: String? = nil,
        canonicalizationVersion: String? = nil,
        includedContextRecordIDs: [UUID]? = nil,
        unresolvedContextConflictIDs: [UUID]? = nil,
        contextPackItemIDs: [UUID]? = nil,
        renderedContextMarkdown: String? = nil,
        renderedArtifactURI: String? = nil,
        contentSHA256: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.taskID = taskID
        self.workspaceID = workspaceID
        self.objective = objective
        self.relevantFilePaths = relevantFilePaths
        self.acceptedArtifactIDs = acceptedArtifactIDs
        self.dependencyTaskIDs = dependencyTaskIDs
        self.constraints = constraints
        self.permissions = permissions
        self.acceptanceTests = acceptanceTests
        self.expectedOutputs = expectedOutputs
        self.baseRevision = baseRevision
        self.actorID = actorID
        self.principalID = principalID
        self.runtimeEndpointID = runtimeEndpointID
        self.runtimeBindingID = runtimeBindingID
        self.taskLeaseID = taskLeaseID
        self.leaseFencingToken = leaseFencingToken
        self.selectionPolicyVersion = selectionPolicyVersion
        self.tokenBudget = tokenBudget
        self.contextRevision = contextRevision
        self.taskRevision = taskRevision
        self.policyRevision = policyRevision
        self.itemSetFingerprint = itemSetFingerprint
        self.budgetEstimatorVersion = budgetEstimatorVersion
        self.canonicalizationVersion = canonicalizationVersion
        self.includedContextRecordIDs = includedContextRecordIDs
        self.unresolvedContextConflictIDs =
            unresolvedContextConflictIDs
        self.contextPackItemIDs = contextPackItemIDs
        self.renderedContextMarkdown = renderedContextMarkdown
        self.renderedArtifactURI = renderedArtifactURI
        self.contentSHA256 = contentSHA256
        self.createdAt = createdAt
    }

    public var renderedMarkdown: String {
        var sections = [
            "# Mu Project Context Pack",
            "",
            "Project: \(projectID.uuidString.lowercased())",
            "Task: \(taskID.uuidString.lowercased())",
            "Workspace: \(workspaceID.uuidString.lowercased())",
            "",
            "## Objective",
            objective
        ]
        Self.appendList(
            title: "Relevant files",
            values: relevantFilePaths,
            to: &sections
        )
        Self.appendList(
            title: "Constraints",
            values: constraints,
            to: &sections
        )
        Self.appendList(
            title: "Permissions",
            values: permissions.map(\.rawValue),
            to: &sections
        )
        Self.appendList(
            title: "Acceptance tests",
            values: acceptanceTests,
            to: &sections
        )
        Self.appendList(
            title: "Expected outputs",
            values: expectedOutputs,
            to: &sections
        )
        if let baseRevision, !baseRevision.isEmpty {
            sections.append(contentsOf: [
                "",
                "## Base revision",
                baseRevision
            ])
        }
        if !acceptedArtifactIDs.isEmpty {
            Self.appendList(
                title: "Accepted artifacts",
                values: acceptedArtifactIDs.map {
                    $0.uuidString.lowercased()
                },
                to: &sections
            )
        }
        if !dependencyTaskIDs.isEmpty {
            Self.appendList(
                title: "Dependencies",
                values: dependencyTaskIDs.map {
                    $0.uuidString.lowercased()
                },
                to: &sections
            )
        }
        if let renderedContextMarkdown,
           !renderedContextMarkdown.isEmpty {
            sections.append(contentsOf: [
                "",
                "## Governed Project Context",
                renderedContextMarkdown
            ])
        }
        return sections.joined(separator: "\n")
    }

    private static func appendList(
        title: String,
        values: [String],
        to sections: inout [String]
    ) {
        guard !values.isEmpty else { return }
        sections.append("")
        sections.append("## \(title)")
        sections.append(contentsOf: values.map { "- \($0)" })
    }
}
