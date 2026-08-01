import Foundation

public struct ProjectKernelTaskContext:
    Hashable,
    Sendable
{
    public var project: ProjectRecord
    public var link: TaskProjectLink
    public var workspace: ProjectWorkspaceRecord
    public var actor: ProjectActorRecord?
    public var principal: PrincipalRecord?
    public var membership: ProjectMembershipRecord?
    public var delegation: DelegationRecord?
    public var activeLease: TaskLeaseRecord?

    public init(
        project: ProjectRecord,
        link: TaskProjectLink,
        workspace: ProjectWorkspaceRecord,
        actor: ProjectActorRecord?,
        principal: PrincipalRecord?,
        membership: ProjectMembershipRecord?,
        delegation: DelegationRecord?,
        activeLease: TaskLeaseRecord?
    ) {
        self.project = project
        self.link = link
        self.workspace = workspace
        self.actor = actor
        self.principal = principal
        self.membership = membership
        self.delegation = delegation
        self.activeLease = activeLease
    }
}

extension ControlPlaneService {
    /// Idempotently projects legacy path-backed Tasks into the first-class
    /// Project Kernel. Existing Task, history, Run, and ledger records remain
    /// untouched except for optional governance references.
    public func bootstrapProjectKernel() throws {
        let now = Date()
        let tasks = try store.fetchTasks()
        let endpoints = try store.fetchEndpoints()
        let agents = try store.fetchAgents()
        let preferencesByPath = try store.fetchProjectPreferences()
            .sorted { $0.updatedAt < $1.updatedAt }
            .reduce(into: [String: ProjectPreference]()) {
                $0[
                    WorkspacePathIdentity.canonicalPath(
                        $1.repositoryPath
                    )
                ] = $1
            }
        var didChange = false

        try store.withTransaction {
            if try store.fetchPrincipal(
                id: Self.localOwnerPrincipalID
            ) == nil {
                try store.upsertPrincipal(
                    PrincipalRecord(
                        id: Self.localOwnerPrincipalID,
                        kind: .person,
                        displayName: "Local owner",
                        createdAt: now,
                        updatedAt: now
                    )
                )
                didChange = true
            }
            if try store.fetchProjectActor(
                id: Self.localHumanActorID
            ) == nil {
                try store.upsertProjectActor(
                    ProjectActorRecord(
                        id: Self.localHumanActorID,
                        principalID: Self.localOwnerPrincipalID,
                        kind: .human,
                        displayName: "You",
                        createdAt: now,
                        updatedAt: now
                    )
                )
                didChange = true
            }

            for endpoint in endpoints {
                let actorID = ProjectActorRecord.stableRuntimeActorID(
                    endpointID: endpoint.id
                )
                if try store.fetchProjectActor(id: actorID) == nil {
                    try store.upsertProjectActor(
                        ProjectActorRecord(
                            id: actorID,
                            principalID: Self.localOwnerPrincipalID,
                            kind: .agent,
                            displayName:
                                endpoint.resolvedInstanceIdentity
                                .instanceLabel,
                            runtimeEndpointID: endpoint.id,
                            createdAt: endpoint.lastProbedAt,
                            updatedAt: now
                        )
                    )
                    didChange = true
                }
            }
            for agent in agents {
                let actorID =
                    ProjectActorRecord.stableAgentIdentityActorID(
                        agentIdentityID: agent.id
                    )
                if try store.fetchProjectActor(id: actorID) == nil {
                    try store.upsertProjectActor(
                        ProjectActorRecord(
                            id: actorID,
                            principalID: Self.localOwnerPrincipalID,
                            kind: .agent,
                            displayName: agent.displayName,
                            agentIdentityID: agent.id,
                            runtimeEndpointID:
                                agent.preferredEndpointID,
                            createdAt: agent.createdAt,
                            updatedAt: now
                        )
                    )
                    didChange = true
                }
            }

            for var task in tasks {
                let canonicalPath = WorkspacePathIdentity.canonicalPath(
                    task.repositoryPath
                )
                let projectID =
                    task.projectID
                    ?? ProjectRecord.stableID(
                        repositoryPath: canonicalPath
                    )
                let preference = preferencesByPath[canonicalPath]
                var project =
                    try store.fetchProject(id: projectID)
                    ?? ProjectRecord(
                        id: projectID,
                        displayName:
                            preference?.displayName
                            ?? Self.defaultProjectName(
                                repositoryPath: canonicalPath
                            ),
                        repositoryPath: canonicalPath,
                        ownerPrincipalID:
                            Self.localOwnerPrincipalID,
                        status: preference?.isRemoved == true
                            ? .archived
                            : .active,
                        createdAt: task.createdAt,
                        updatedAt: task.updatedAt
                    )
                let projectWasMissing =
                    try store.fetchProject(id: projectID) == nil
                if let displayName = preference?.displayName,
                   !displayName.isEmpty,
                   project.displayName != displayName {
                    project.displayName = displayName
                    project.updatedAt = max(
                        project.updatedAt,
                        preference?.updatedAt ?? now
                    )
                    didChange = true
                }
                let desiredStatus: ProjectStatus =
                    preference?.isRemoved == true
                    ? .archived
                    : .active
                if project.status != desiredStatus {
                    project.status = desiredStatus
                    project.updatedAt = now
                    didChange = true
                }
                if projectWasMissing {
                    try store.upsertProject(project)
                    didChange = true
                } else if project.updatedAt > task.updatedAt
                            || preference != nil {
                    try store.upsertProject(project)
                }

                let workspaceID =
                    task.workspaceID
                    ?? ProjectWorkspaceRecord.stableID(
                        taskID: task.id
                    )
                if var existingWorkspace =
                    try store.fetchProjectWorkspace(
                        id: workspaceID
                    ) {
                    if existingWorkspace.baseRevision == nil {
                        existingWorkspace.baseRevision =
                            repositoryProbe.baseRevision(
                                path: canonicalPath
                            )
                        existingWorkspace.updatedAt = now
                        try store.upsertProjectWorkspace(
                            existingWorkspace
                        )
                        didChange = true
                    }
                } else {
                    try store.upsertProjectWorkspace(
                        ProjectWorkspaceRecord(
                            id: workspaceID,
                            projectID: projectID,
                            taskID: task.id,
                            repositoryPath: canonicalPath,
                            baseRevision:
                                repositoryProbe.baseRevision(
                                    path: canonicalPath
                                ),
                            isolationKind:
                                .sharedProjectFolder,
                            createdAt: task.createdAt,
                            updatedAt: task.updatedAt
                        )
                    )
                    didChange = true
                }

                let assignedActorID = try Self.assignedActorID(
                    task: task,
                    store: store
                )
                if try store.fetchTaskProjectLink(
                    taskID: task.id
                ) == nil {
                    try store.upsertTaskProjectLink(
                        TaskProjectLink(
                            taskID: task.id,
                            projectID: projectID,
                            workspaceID: workspaceID,
                            requestedByActorID:
                                Self.localHumanActorID,
                            assignedToActorID:
                                assignedActorID,
                            approvalOwnerActorID:
                                Self.localHumanActorID,
                            costOwnerPrincipalID:
                                Self.localOwnerPrincipalID,
                            createdAt: task.createdAt,
                            updatedAt: task.updatedAt
                        )
                    )
                    didChange = true
                }

                try ensureKernelAuthorization(
                    projectID: projectID,
                    taskID: task.id,
                    actorID: Self.localHumanActorID,
                    endpoint: nil,
                    role: .owner,
                    now: now
                )
                if let assignedActorID {
                    let endpoint = task.currentEndpointID.flatMap {
                        id in endpoints.first { $0.id == id }
                    }
                    try ensureKernelAuthorization(
                        projectID: projectID,
                        taskID: task.id,
                        actorID: assignedActorID,
                        endpoint: endpoint,
                        role: .contributor,
                        now: now
                    )
                }

                if task.projectID != projectID
                    || task.workspaceID != workspaceID
                    || task.requestedByActorID
                        != Self.localHumanActorID
                    || task.assignedActorID
                        != assignedActorID {
                    task.projectID = projectID
                    task.workspaceID = workspaceID
                    task.requestedByActorID =
                        Self.localHumanActorID
                    task.assignedActorID = assignedActorID
                    try store.upsertTask(task)
                    didChange = true
                }
            }

            if didChange {
                try store.appendEvent(
                    LedgerEvent(
                        type: "project_kernel.migrated",
                        summary:
                            "Mapped existing local records into the "
                            + "Project, Principal, Actor, Membership, "
                            + "Delegation, and Workspace kernel.",
                        payload: [
                            "schema_version": "1.0",
                            "task_count": String(tasks.count),
                            "migration": "idempotent"
                        ]
                    )
                )
            }
        }
    }

    public func refreshRuntimeAdapterRegistrations() throws {
        let endpoints = try store.fetchEndpoints()
        try store.withTransaction {
            for endpoint in endpoints {
                try store.upsertRuntimeAdapterRegistration(
                    RuntimeAdapterRegistration(
                        endpointID: endpoint.id,
                        manifest:
                            RuntimeGatewayRegistry.manifest(
                                for: endpoint
                            ),
                        probedAt: endpoint.lastProbedAt
                    )
                )
            }
        }
    }

    @discardableResult
    public func resolveOrCreateProject(
        repositoryPath: String,
        displayName: String? = nil
    ) throws -> ProjectRecord {
        let canonicalPath = WorkspacePathIdentity.canonicalPath(
            repositoryPath
        )
        let projectID = ProjectRecord.stableID(
            repositoryPath: canonicalPath
        )
        let now = Date()
        var project =
            try store.fetchProject(id: projectID)
            ?? ProjectRecord(
                id: projectID,
                displayName:
                    displayName?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).nilIfEmpty
                    ?? Self.defaultProjectName(
                        repositoryPath: canonicalPath
                    ),
                repositoryPath: canonicalPath,
                ownerPrincipalID: Self.localOwnerPrincipalID,
                createdAt: now,
                updatedAt: now
            )
        if let displayName = displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            project.displayName = displayName
        }
        project.repositoryPath = canonicalPath
        project.status = .active
        project.updatedAt = now
        try store.upsertProject(project)
        try ensureKernelAuthorization(
            projectID: project.id,
            taskID: nil,
            actorID: Self.localHumanActorID,
            endpoint: nil,
            role: .owner,
            now: now
        )
        return project
    }

    /// Creates the authoritative Task→Project→Workspace link and the explicit
    /// task-scoped Delegation used by the selected Runtime.
    @discardableResult
    func attachTaskToProjectKernel(
        task: inout TaskRecord,
        endpoint: RuntimeEndpoint
    ) throws -> TaskProjectLink {
        let project = try resolveOrCreateProject(
            repositoryPath: task.repositoryPath
        )
        let workspaceID = ProjectWorkspaceRecord.stableID(
            taskID: task.id
        )
        let workspace = ProjectWorkspaceRecord(
            id: workspaceID,
            projectID: project.id,
            taskID: task.id,
            repositoryPath: task.repositoryPath,
            baseRevision:
                repositoryProbe.baseRevision(
                    path: task.repositoryPath
                ),
            isolationKind: .sharedProjectFolder,
            createdAt: task.createdAt,
            updatedAt: task.updatedAt
        )
        let assignedActorID = try Self.assignedActorID(
            task: task,
            fallbackEndpointID: endpoint.id,
            store: store
        )
        let link = TaskProjectLink(
            taskID: task.id,
            projectID: project.id,
            workspaceID: workspaceID,
            requestedByActorID: Self.localHumanActorID,
            assignedToActorID: assignedActorID,
            approvalOwnerActorID: Self.localHumanActorID,
            costOwnerPrincipalID: Self.localOwnerPrincipalID,
            createdAt: task.createdAt,
            updatedAt: task.updatedAt
        )
        try store.upsertProjectWorkspace(workspace)
        try store.upsertTaskProjectLink(link)
        try ensureKernelAuthorization(
            projectID: project.id,
            taskID: task.id,
            actorID: Self.localHumanActorID,
            endpoint: nil,
            role: .owner,
            now: task.createdAt
        )
        if let assignedActorID {
            try ensureKernelAuthorization(
                projectID: project.id,
                taskID: task.id,
                actorID: assignedActorID,
                endpoint: endpoint,
                role: .contributor,
                now: task.createdAt
            )
        }
        task.projectID = project.id
        task.workspaceID = workspaceID
        task.requestedByActorID = Self.localHumanActorID
        task.assignedActorID = assignedActorID
        return link
    }

    /// An explicit @mention is the user's task-scoped delegation intent. This
    /// grants only the adapter's bounded default permissions and does not make
    /// the Agent a global Project owner.
    func authorizeTaskActor(
        taskID: UUID,
        actorID: UUID,
        endpointID: UUID
    ) throws {
        let context = try projectKernelContext(
            taskID: taskID
        )
        guard let actor = try store.fetchProjectActor(
            id: actorID
        ), actor.status == .active else {
            throw MuError.invalidTransition(
                "The mentioned Agent has no active Project Actor identity."
            )
        }
        guard let endpoint =
            try store.fetchRegisteredEndpoint(
                id: endpointID
            ) else {
            throw MuError.recordNotFound(
                "Runtime endpoint \(endpointID)"
            )
        }
        if let runtimeEndpointID =
            actor.runtimeEndpointID,
           runtimeEndpointID != endpointID {
            throw MuError.invalidTransition(
                "The mentioned Agent Actor belongs to another Runtime instance."
            )
        }
        try ensureKernelAuthorization(
            projectID: context.project.id,
            taskID: taskID,
            actorID: actorID,
            endpoint: endpoint,
            role: .contributor,
            now: Date()
        )
    }

    public func projectKernelContext(
        taskID: UUID
    ) throws -> ProjectKernelTaskContext {
        guard let link = try store.fetchTaskProjectLink(
            taskID: taskID
        ) else {
            throw MuError.recordNotFound(
                "Task \(taskID) Project link"
            )
        }
        guard let project = try store.fetchProject(
            id: link.projectID
        ) else {
            throw MuError.recordNotFound(
                "Project \(link.projectID)"
            )
        }
        guard let workspaceID = link.workspaceID,
              let workspace =
                try store.fetchProjectWorkspace(id: workspaceID)
        else {
            throw MuError.recordNotFound(
                "Task \(taskID) Workspace"
            )
        }
        let actor = try link.assignedToActorID.flatMap {
            try store.fetchProjectActor(id: $0)
        }
        let principal = try actor.flatMap {
            try store.fetchPrincipal(id: $0.principalID)
        }
        let membership = try link.assignedToActorID.flatMap {
            actorID in
            try store.fetchProjectMemberships(
                projectID: project.id
            ).first { $0.actorID == actorID }
        }
        let delegation = try link.assignedToActorID.flatMap {
            actorID in
            try store.fetchDelegations(
                projectID: project.id,
                agentActorID: actorID,
                taskID: taskID
            ).filter { $0.isActive() }
                .sorted {
                    ($0.taskID != nil ? 0 : 1)
                        < ($1.taskID != nil ? 0 : 1)
                }
                .first
        }
        let activeLease = try store.fetchTaskLeases(
            taskID: taskID
        ).first { $0.isActive() }
        return ProjectKernelTaskContext(
            project: project,
            link: link,
            workspace: workspace,
            actor: actor,
            principal: principal,
            membership: membership,
            delegation: delegation,
            activeLease: activeLease
        )
    }

    @discardableResult
    public func claimTaskLease(
        taskID: UUID,
        endpointID: UUID,
        actorID: UUID? = nil,
        runtimeBindingID: UUID? = nil,
        duration: TimeInterval = 15 * 60
    ) throws -> TaskLeaseRecord {
        guard let endpoint = try store.fetchRegisteredEndpoint(
            id: endpointID
        ) else {
            throw MuError.recordNotFound(
                "Runtime endpoint \(endpointID)"
            )
        }
        try RuntimeGatewayRegistry.require(
            .acceptTaskLease,
            endpoint: endpoint
        )
        let context = try projectKernelContext(taskID: taskID)
        guard context.project.status == .active else {
            throw MuError.invalidTransition(
                "An archived Project cannot issue a Task lease."
            )
        }
        let actor =
            try actorID.flatMap {
                try store.fetchProjectActor(id: $0)
            }
            ?? context.actor
        let principal =
            try actor.flatMap {
                try store.fetchPrincipal(
                    id: $0.principalID
                )
            }
        let membership =
            try actor.flatMap { actor in
                try store.fetchProjectMemberships(
                    projectID: context.project.id
                ).first {
                    $0.actorID == actor.id
                }
            }
        let delegation =
            try actor.flatMap { actor in
                try store.fetchDelegations(
                    projectID: context.project.id,
                    agentActorID: actor.id,
                    taskID: taskID
                ).first {
                    $0.taskID == taskID
                }
            }
        guard let actor,
              actor.status == .active,
              let principal,
              principal.status == .active else {
            throw MuError.invalidTransition(
                "The assigned Agent has no active accountable Principal."
            )
        }
        guard membership?.isActive() == true else {
            throw MuError.invalidTransition(
                "The assigned Agent is not an active Project member."
            )
        }
        guard let delegation,
              delegation.isActive(),
              delegation.permissions.contains(.acceptTask),
              delegation.permissions.contains(.renewLease) else {
            throw MuError.invalidTransition(
                "The assigned Agent has no active task-scoped Delegation."
            )
        }
        let lease = try store.claimTaskLease(
            projectID: context.project.id,
            taskID: taskID,
            agentActorID: actor.id,
            endpointID: endpointID,
            runtimeBindingID: runtimeBindingID,
            duration: duration
        )
        try store.appendEvent(
            LedgerEvent(
                projectID: context.project.id,
                actorID: actor.id,
                principalID: principal.id,
                workspaceID: context.workspace.id,
                taskID: taskID,
                type: "task.lease.claimed",
                summary:
                    "\(actor.displayName) accepted a bounded Task lease.",
                payload: [
                    "lease_id": lease.id.uuidString,
                    "endpoint_id": endpointID.uuidString,
                    "fencing_token":
                        String(lease.fencingToken),
                    "expires_at":
                        ISO8601DateFormatter().string(
                            from: lease.expiresAt
                        )
                ]
            )
        )
        return lease
    }

    @discardableResult
    public func renewTaskLease(
        id: UUID,
        duration: TimeInterval = 15 * 60
    ) throws -> TaskLeaseRecord {
        let lease = try store.renewTaskLease(
            id: id,
            duration: duration
        )
        try store.appendEvent(
            LedgerEvent(
                projectID: lease.projectID,
                actorID: lease.agentActorID,
                taskID: lease.taskID,
                type: "task.lease.renewed",
                summary: "Renewed the active Task lease heartbeat.",
                payload: [
                    "lease_id": lease.id.uuidString,
                    "fencing_token":
                        String(lease.fencingToken)
                ]
            )
        )
        return lease
    }

    @discardableResult
    public func releaseTaskLease(
        id: UUID,
        state: TaskLeaseState = .released
    ) throws -> TaskLeaseRecord {
        let lease = try store.releaseTaskLease(
            id: id,
            state: state
        )
        try store.appendEvent(
            LedgerEvent(
                projectID: lease.projectID,
                actorID: lease.agentActorID,
                taskID: lease.taskID,
                type: "task.lease.\(lease.state.rawValue)",
                summary:
                    "Closed Task lease \(lease.fencingToken) as "
                    + "\(lease.state.rawValue).",
                payload: [
                    "lease_id": lease.id.uuidString,
                    "fencing_token":
                        String(lease.fencingToken)
                ]
            )
        )
        return lease
    }

    @discardableResult
    public func buildProjectContextPack(
        taskID: UUID
    ) throws -> ProjectContextPackRecord {
        guard let task = try store.fetchTask(id: taskID) else {
            throw MuError.recordNotFound("Task \(taskID)")
        }
        let context = try projectKernelContext(taskID: taskID)
        let acceptedArtifacts = try store.fetchProjectArtifacts(
            projectID: context.project.id
        ).filter { $0.status == .accepted }
        let permissions = context.delegation?.permissions
            .sorted { $0.rawValue < $1.rawValue } ?? []
        var pack = ProjectContextPackRecord(
            projectID: context.project.id,
            taskID: task.id,
            workspaceID: context.workspace.id,
            objective: task.objective,
            relevantFilePaths: [context.workspace.repositoryPath],
            acceptedArtifactIDs: acceptedArtifacts.map(\.id),
            dependencyTaskIDs: context.link.dependencyTaskIDs,
            constraints: task.constraints,
            permissions: permissions,
            acceptanceTests: task.successCriteria,
            expectedOutputs:
                task.pendingSteps.isEmpty
                ? ["A reviewable Runtime result with evidence."]
                : task.pendingSteps,
            baseRevision: context.workspace.baseRevision,
            contentSHA256: ""
        )
        pack.contentSHA256 = Data(
            pack.renderedMarkdown.utf8
        ).muSHA256
        let reference = try artifactStore.put(
            Data(pack.renderedMarkdown.utf8)
        )
        let artifact = ProjectArtifactRecord(
            projectID: context.project.id,
            taskID: task.id,
            producerActorID: Self.localHumanActorID,
            kind: .contextPack,
            title: "Context Pack · \(task.title)",
            uri: reference.uri,
            sha256: reference.sha256,
            status: .accepted,
            metadata: [
                "context_pack_id": pack.id.uuidString,
                "workspace_id": context.workspace.id.uuidString
            ]
        )
        try store.withTransaction {
            try store.insertProjectContextPack(pack)
            try store.upsertProjectArtifact(artifact)
            try store.appendEvent(
                LedgerEvent(
                    projectID: context.project.id,
                    actorID: Self.localHumanActorID,
                    principalID: Self.localOwnerPrincipalID,
                    workspaceID: context.workspace.id,
                    artifactID: artifact.id,
                    taskID: task.id,
                    type: "context_pack.published",
                    summary:
                        "Published a bounded structured Context Pack "
                        + "from Mu Project state.",
                    payload: [
                        "context_pack_id": pack.id.uuidString,
                        "sha256": pack.contentSHA256,
                        "accepted_artifact_count":
                            String(
                                acceptedArtifacts.count
                            )
                    ]
                )
            )
        }
        return pack
    }

    @discardableResult
    public func submitRuntimeOutputArtifact(
        taskID: UUID,
        producerActorID: UUID?,
        title: String,
        output: String,
        metadata: [String: String] = [:]
    ) throws -> ProjectArtifactRecord {
        let context = try projectKernelContext(taskID: taskID)
        let reference = try artifactStore.put(Data(output.utf8))
        let artifact = ProjectArtifactRecord(
            projectID: context.project.id,
            taskID: taskID,
            producerActorID:
                producerActorID ?? context.actor?.id,
            kind: .runtimeOutput,
            title: title,
            uri: reference.uri,
            sha256: reference.sha256,
            status: .submitted,
            metadata: metadata
        )
        try store.withTransaction {
            try store.upsertProjectArtifact(artifact)
            try store.appendEvent(
                LedgerEvent(
                    projectID: context.project.id,
                    actorID: artifact.producerActorID,
                    principalID: context.principal?.id,
                    workspaceID: context.workspace.id,
                    artifactID: artifact.id,
                    taskID: taskID,
                    type: "artifact.published",
                    summary:
                        "Published “\(title)” for Project review.",
                    payload: [
                        "artifact_kind": artifact.kind.rawValue,
                        "artifact_status":
                            artifact.status.rawValue,
                        "sha256": artifact.sha256
                    ]
                )
            )
        }
        return artifact
    }

    @discardableResult
    public func requestProjectReview(
        artifactID: UUID,
        reviewerActorID: UUID
    ) throws -> ProjectReviewRecord {
        guard let artifact = try store.fetchProjectArtifact(
            id: artifactID
        ) else {
            throw MuError.recordNotFound(
                "Project artifact \(artifactID)"
            )
        }
        let memberships = try store.fetchProjectMemberships(
            projectID: artifact.projectID
        )
        guard memberships.contains(where: {
            $0.actorID == reviewerActorID
                && $0.isActive()
                && ($0.role == .owner
                    || $0.role == .lead
                    || $0.role == .reviewer)
        }) else {
            throw MuError.invalidTransition(
                "The selected reviewer is not authorized for this Project."
            )
        }
        let review = ProjectReviewRecord(
            projectID: artifact.projectID,
            taskID: artifact.taskID,
            artifactID: artifact.id,
            reviewerActorID: reviewerActorID
        )
        try store.withTransaction {
            try store.upsertProjectReview(review)
            try store.appendEvent(
                LedgerEvent(
                    projectID: artifact.projectID,
                    actorID: reviewerActorID,
                    artifactID: artifact.id,
                    reviewID: review.id,
                    taskID: artifact.taskID,
                    type: "review.requested",
                    summary: "Requested review of “\(artifact.title)”."
                )
            )
        }
        return review
    }

    @discardableResult
    public func resolveProjectReview(
        id: UUID,
        verdict: ProjectReviewVerdict,
        findings: [String]
    ) throws -> ProjectReviewRecord {
        guard var review = try store.fetchProjectReviews()
            .first(where: { $0.id == id }) else {
            throw MuError.recordNotFound("Project review \(id)")
        }
        guard review.verdict == .pending else {
            throw MuError.invalidTransition(
                "The Project review is already resolved."
            )
        }
        review.verdict = verdict
        review.findings = findings
        review.resolvedAt = Date()
        var artifact = try review.artifactID.flatMap {
            try store.fetchProjectArtifact(id: $0)
        }
        if verdict == .approved {
            artifact?.status = .accepted
        } else if verdict == .rejected {
            artifact?.status = .rejected
        }
        artifact?.updatedAt = Date()
        try store.withTransaction {
            try store.upsertProjectReview(review)
            if let artifact {
                try store.upsertProjectArtifact(artifact)
            }
            try store.appendEvent(
                LedgerEvent(
                    projectID: review.projectID,
                    actorID: review.reviewerActorID,
                    artifactID: review.artifactID,
                    reviewID: review.id,
                    taskID: review.taskID,
                    type: "review.completed",
                    summary:
                        "Completed Project review as "
                        + "\(verdict.rawValue).",
                    payload: [
                        "verdict": verdict.rawValue,
                        "finding_count": String(findings.count)
                    ]
                )
            )
        }
        return review
    }

    @discardableResult
    func createProjectApproval(
        interaction: inout RuntimeInteractionRequest,
        requestedByActorID: UUID? = nil,
        scope: String
    ) throws -> ProjectApprovalRecord {
        let context = try projectKernelContext(
            taskID: interaction.taskID
        )
        guard let actorID =
            requestedByActorID
            ?? context.actor?.id else {
            throw MuError.invalidTransition(
                "A Runtime approval must have an accountable Agent Actor."
            )
        }
        let approval = ProjectApprovalRecord(
            projectID: context.project.id,
            taskID: interaction.taskID,
            runtimeInteractionID: interaction.id,
            requestedByActorID: actorID,
            approverActorID:
                context.link.approvalOwnerActorID,
            scope: scope
        )
        interaction.projectApprovalID = approval.id
        try store.upsertProjectApproval(approval)
        try store.appendEvent(
            LedgerEvent(
                projectID: context.project.id,
                actorID: actorID,
                principalID: context.principal?.id,
                workspaceID: context.workspace.id,
                approvalID: approval.id,
                taskID: interaction.taskID,
                type: "approval.requested",
                summary:
                    "Requested Project approval for \(scope).",
                payload: [
                    "runtime_interaction_id":
                        interaction.id.uuidString
                ]
            )
        )
        return approval
    }

    @discardableResult
    public func resolveProjectApproval(
        id: UUID,
        decision: ProjectApprovalDecision,
        reason: String? = nil
    ) throws -> ProjectApprovalRecord {
        guard var approval = try store.fetchProjectApprovals()
            .first(where: { $0.id == id }) else {
            throw MuError.recordNotFound(
                "Project approval \(id)"
            )
        }
        guard approval.decision == .pending else {
            throw MuError.invalidTransition(
                "The Project approval is already resolved."
            )
        }
        approval.decision = decision
        approval.reason = reason
        approval.resolvedAt = Date()
        try store.withTransaction {
            try store.upsertProjectApproval(approval)
            try store.appendEvent(
                LedgerEvent(
                    projectID: approval.projectID,
                    actorID: approval.approverActorID,
                    approvalID: approval.id,
                    taskID: approval.taskID,
                    type: "approval.\(decision.rawValue)",
                    summary:
                        "Resolved Project approval as "
                        + "\(decision.rawValue).",
                    payload: [
                        "scope": approval.scope,
                        "reason": reason ?? ""
                    ]
                )
            )
        }
        return approval
    }

    private func ensureKernelAuthorization(
        projectID: UUID,
        taskID: UUID?,
        actorID: UUID,
        endpoint: RuntimeEndpoint?,
        role: ProjectMembershipRole,
        now: Date
    ) throws {
        let membershipID = ProjectMembershipRecord.stableID(
            projectID: projectID,
            actorID: actorID
        )
        var membership =
            try store.fetchProjectMemberships(
                projectID: projectID
            ).first { $0.id == membershipID }
            ?? ProjectMembershipRecord(
                id: membershipID,
                projectID: projectID,
                actorID: actorID,
                role: role,
                taskScope: taskID.map { [$0] } ?? [],
                createdAt: now,
                updatedAt: now
            )
        if let taskID,
           !membership.taskScope.contains(taskID) {
            membership.taskScope.append(taskID)
            membership.updatedAt = now
        }
        if role == .owner {
            membership.role = .owner
        }
        membership.status = .active
        try store.upsertProjectMembership(membership)

        guard actorID != Self.localHumanActorID else { return }
        let permissions = Self.defaultDelegationPermissions(
            endpoint: endpoint
        )
        let delegationID = DelegationRecord.stableID(
            projectID: projectID,
            agentActorID: actorID,
            taskID: taskID
        )
        var delegation =
            try store.fetchDelegations(
                projectID: projectID,
                agentActorID: actorID,
                taskID: taskID
            ).first { $0.id == delegationID }
            ?? DelegationRecord(
                id: delegationID,
                projectID: projectID,
                principalID:
                    Self.localOwnerPrincipalID,
                delegatedByActorID:
                    Self.localHumanActorID,
                agentActorID: actorID,
                taskID: taskID,
                permissions: permissions,
                restrictions:
                    Self.defaultDelegationRestrictions(
                        endpoint: endpoint
                    ),
                createdAt: now,
                updatedAt: now
            )
        delegation.permissions = permissions
        delegation.restrictions =
            Self.defaultDelegationRestrictions(
                endpoint: endpoint
            )
        delegation.status = .active
        delegation.updatedAt = now
        try store.upsertDelegation(delegation)
    }

    private static func assignedActorID(
        task: TaskRecord,
        fallbackEndpointID: UUID? = nil,
        store: SQLiteStore
    ) throws -> UUID? {
        if let assignedActorID = task.assignedActorID,
           try store.fetchProjectActor(id: assignedActorID) != nil {
            return assignedActorID
        }
        if let agentIdentityID = task.assignedAgentIdentityID {
            return ProjectActorRecord.stableAgentIdentityActorID(
                agentIdentityID: agentIdentityID
            )
        }
        guard let endpointID =
            task.currentEndpointID ?? fallbackEndpointID else {
            return nil
        }
        return ProjectActorRecord.stableRuntimeActorID(
            endpointID: endpointID
        )
    }

    private static func defaultProjectName(
        repositoryPath: String
    ) -> String {
        let name = URL(
            fileURLWithPath: repositoryPath,
            isDirectory: true
        ).lastPathComponent
        return name.isEmpty ? repositoryPath : name
    }

    private static func defaultDelegationPermissions(
        endpoint: RuntimeEndpoint?
    ) -> Set<ProjectPermission> {
        var permissions: Set<ProjectPermission> = [
            .readProjectState,
            .readRepository,
            .readContext,
            .proposeContext,
            .acceptTask,
            .renewLease,
            .publishEvent,
            .submitArtifact,
            .completeTask
        ]
        if endpoint?.runtimeTypeID
            == Self.openWorkerRuntimeTypeID {
            permissions.formUnion([
                .writeWorkspace,
                .runCommands,
                .runTests,
                .requestApproval
            ])
        }
        return permissions
    }

    private static func defaultDelegationRestrictions(
        endpoint: RuntimeEndpoint?
    ) -> [String] {
        if endpoint?.runtimeTypeID
            == Self.openWorkerRuntimeTypeID {
            return [
                "Exact Project workspace only.",
                "External network and sensitive credentials require separate policy approval.",
                "Outputs enter Project review before becoming accepted state."
            ]
        }
        return [
            "Read-only Project workspace.",
            "No external network.",
            "No production deployment.",
            "Outputs enter Project review before becoming accepted state."
        ]
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
