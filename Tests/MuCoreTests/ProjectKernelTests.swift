import Foundation
@testable import MuCore
import Testing

@Suite(.serialized)
struct ProjectKernelTests {
    @Test
    func projectIdentityIsStableForCanonicalRepositoryAndAcrossRestart()
        throws
    {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataDirectory = root.appending(
            path: "data",
            directoryHint: .isDirectory
        )
        let repository = root.appending(
            path: "Workspace",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: repository,
            withIntermediateDirectories: true
        )

        let canonical = ProjectRecord.stableID(
            repositoryPath: repository.path
        )
        #expect(
            canonical == ProjectRecord.stableID(
                repositoryPath: repository.path + "/./"
            )
        )

        let service = try ControlPlaneService(dataDirectory: dataDirectory)
        let created = try service.resolveOrCreateProject(
            repositoryPath: repository.path,
            displayName: "Kernel workspace"
        )
        #expect(created.id == canonical)
        #expect(created.displayName == "Kernel workspace")

        let restarted = try ControlPlaneService(dataDirectory: dataDirectory)
        let reloaded = try #require(
            try restarted.store.fetchProject(id: canonical)
        )
        #expect(reloaded.id == created.id)
        #expect(reloaded.repositoryPath == repository.path)
        #expect(reloaded.displayName == "Kernel workspace")
    }

    @Test
    func legacyTaskBootstrapCreatesStableProjectWorkspaceAndLink()
        throws
    {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataDirectory = root.appending(
            path: "data",
            directoryHint: .isDirectory
        )
        let repository = root.appending(
            path: "Legacy Workspace",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: repository,
            withIntermediateDirectories: true
        )

        let first = try ControlPlaneService(dataDirectory: dataDirectory)
        let legacy = TaskRecord(
            title: "Legacy task",
            objective: "Remain readable after Project Kernel bootstrap.",
            successCriteria: ["Link is created"],
            constraints: ["Keep existing task JSON"],
            pendingSteps: ["Bootstrap"],
            repositoryPath: repository.path,
            currentEndpointID: ControlPlaneService.syntheticEndpointAID
        )
        #expect(legacy.projectID == nil)
        #expect(legacy.workspaceID == nil)
        try first.store.upsertTask(legacy)

        let restarted = try ControlPlaneService(dataDirectory: dataDirectory)
        let expectedProjectID = ProjectRecord.stableID(
            repositoryPath: repository.path
        )
        let migrated = try #require(
            try restarted.store.fetchTask(id: legacy.id)
        )
        let link = try #require(
            try restarted.store.fetchTaskProjectLink(taskID: legacy.id)
        )
        let workspace = try #require(
            link.workspaceID.flatMap {
                try restarted.store.fetchProjectWorkspace(id: $0)
            }
        )

        #expect(migrated.projectID == expectedProjectID)
        #expect(migrated.workspaceID == workspace.id)
        #expect(link.id == legacy.id)
        #expect(link.projectID == expectedProjectID)
        #expect(workspace.projectID == expectedProjectID)
        #expect(workspace.taskID == legacy.id)
        #expect(workspace.repositoryPath == repository.path)

        let secondRestart = try ControlPlaneService(dataDirectory: dataDirectory)
        let reloadedLink = try secondRestart.store.fetchTaskProjectLink(
            taskID: legacy.id
        )
        let reloadedWorkspace = try secondRestart.store.fetchProjectWorkspace(
            id: workspace.id
        )
        #expect(reloadedLink?.projectID == expectedProjectID)
        #expect(reloadedWorkspace?.id == workspace.id)
    }

    @Test
    func taskCreationCreatesMembershipAndTaskScopedDelegation()
        throws
    {
        let fixture = try serviceFixture()
        defer { fixture.remove() }
        let forge = try #require(
            try fixture.service.store.fetchAgent(
                id: ControlPlaneService.forgeAgentID
            )
        )

        let task = try fixture.service.createTask(
            title: "Governed task",
            objective: "Verify Project Kernel authorization records.",
            successCriteria: ["Authorization exists"],
            constraints: ["Local-only"],
            pendingSteps: ["Verify records"],
            repositoryPath: fixture.repository.path,
            sourceEndpointID: ControlPlaneService.syntheticEndpointAID,
            agentIdentityID: forge.id
        )

        let link = try #require(
            try fixture.service.store.fetchTaskProjectLink(taskID: task.id)
        )
        let actorID = try #require(link.assignedToActorID)
        let actor = try #require(
            try fixture.service.store.fetchProjectActor(id: actorID)
        )
        let membership = try #require(
            try fixture.service.store.fetchProjectMemberships(
                projectID: link.projectID
            ).first { $0.actorID == actorID }
        )
        let delegation = try #require(
            try fixture.service.store.fetchDelegations(
                projectID: link.projectID,
                agentActorID: actorID,
                taskID: task.id
            ).first { $0.taskID == task.id }
        )

        #expect(actor.kind == .agent)
        #expect(actor.agentIdentityID == forge.id)
        #expect(membership.isActive())
        #expect(membership.role == .contributor)
        #expect(delegation.isActive())
        #expect(delegation.principalID == ControlPlaneService.localOwnerPrincipalID)
        #expect(delegation.delegatedByActorID == ControlPlaneService.localHumanActorID)
        #expect(delegation.permissions.contains(.acceptTask))
        #expect(delegation.permissions.contains(.renewLease))
        #expect(delegation.permissions.contains(.submitArtifact))
    }

    @Test
    func oneTaskLeaseFencesContendersThenAllowsRenewAndRelease()
        throws
    {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStore(
            databaseURL: root.appending(path: "mu.sqlite")
        )
        let projectID = UUID()
        let taskID = UUID()
        let firstActorID = UUID()
        let secondActorID = UUID()
        let endpointID = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        let first = try store.claimTaskLease(
            projectID: projectID,
            taskID: taskID,
            agentActorID: firstActorID,
            endpointID: endpointID,
            duration: 90,
            now: start
        )
        let sameClaim = try store.claimTaskLease(
            projectID: projectID,
            taskID: taskID,
            agentActorID: firstActorID,
            endpointID: endpointID,
            duration: 90,
            now: start.addingTimeInterval(1)
        )
        #expect(sameClaim.id == first.id)
        #expect(sameClaim.fencingToken == 1)

        do {
            _ = try store.claimTaskLease(
                projectID: projectID,
                taskID: taskID,
                agentActorID: secondActorID,
                endpointID: endpointID,
                duration: 90,
                now: start.addingTimeInterval(2)
            )
            Issue.record("A second Agent claimed an active Task lease.")
        } catch let error as MuError {
            guard case .invalidTransition = error else {
                Issue.record("Unexpected lease contention error: \(error)")
                return
            }
        }

        let renewed = try store.renewTaskLease(
            id: first.id,
            duration: 120,
            now: start.addingTimeInterval(30)
        )
        #expect(renewed.lastHeartbeatAt == start.addingTimeInterval(30))
        #expect(renewed.expiresAt == start.addingTimeInterval(150))

        let released = try store.releaseTaskLease(
            id: first.id,
            now: start.addingTimeInterval(31)
        )
        #expect(released.state == .released)
        #expect(released.releasedAt == start.addingTimeInterval(31))

        let next = try store.claimTaskLease(
            projectID: projectID,
            taskID: taskID,
            agentActorID: secondActorID,
            endpointID: endpointID,
            duration: 90,
            now: start.addingTimeInterval(32)
        )
        #expect(next.agentActorID == secondActorID)
        #expect(next.fencingToken == 2)
    }

    @Test
    func contextPackMarkdownIsDeterministicAndBoundedToProjectState()
        throws
    {
        let projectID = uuid("11111111-1111-1111-1111-111111111111")
        let taskID = uuid("22222222-2222-2222-2222-222222222222")
        let workspaceID = uuid("33333333-3333-3333-3333-333333333333")
        let artifactID = uuid("44444444-4444-4444-4444-444444444444")
        let dependencyID = uuid("55555555-5555-5555-5555-555555555555")

        let first = ProjectContextPackRecord(
            id: uuid("66666666-6666-6666-6666-666666666666"),
            projectID: projectID,
            taskID: taskID,
            workspaceID: workspaceID,
            objective: "Implement the approved change.",
            relevantFilePaths: ["/repo/Sources/MuCore/ProjectKernel.swift"],
            acceptedArtifactIDs: [artifactID],
            dependencyTaskIDs: [dependencyID],
            constraints: ["Local-only", "No hidden context"],
            permissions: [.readProjectState, .readRepository],
            acceptanceTests: ["swift test"],
            expectedOutputs: ["Reviewable patch"],
            baseRevision: "abc123",
            contentSHA256: "ignored-for-rendering",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let second = ProjectContextPackRecord(
            id: uuid("77777777-7777-7777-7777-777777777777"),
            projectID: projectID,
            taskID: taskID,
            workspaceID: workspaceID,
            objective: first.objective,
            relevantFilePaths: first.relevantFilePaths,
            acceptedArtifactIDs: first.acceptedArtifactIDs,
            dependencyTaskIDs: first.dependencyTaskIDs,
            constraints: first.constraints,
            permissions: first.permissions,
            acceptanceTests: first.acceptanceTests,
            expectedOutputs: first.expectedOutputs,
            baseRevision: first.baseRevision,
            contentSHA256: "another-hash",
            createdAt: Date(timeIntervalSince1970: 2)
        )

        #expect(first.renderedMarkdown == second.renderedMarkdown)
        #expect(first.renderedMarkdown.contains("# Mu Project Context Pack"))
        #expect(first.renderedMarkdown.contains("## Permissions\n- project.read\n- repository.read"))
        #expect(first.renderedMarkdown.contains("## Accepted artifacts\n- \(artifactID.uuidString.lowercased())"))
        #expect(first.renderedMarkdown.contains("## Dependencies\n- \(dependencyID.uuidString.lowercased())"))
        #expect(!first.renderedMarkdown.contains("ignored-for-rendering"))
    }

    @Test
    func legacyBootstrapCapturesBaseRevisionAndContextPackUsesAcceptedArtifacts()
        throws
    {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appending(
            path: "Repository",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: repository,
            withIntermediateDirectories: true
        )
        let baseRevision = try initializeGitRepository(at: repository)
        let dataDirectory = root.appending(
            path: "data",
            directoryHint: .isDirectory
        )

        let first = try ControlPlaneService(dataDirectory: dataDirectory)
        let legacy = TaskRecord(
            title: "Legacy revision task",
            objective: "Preserve a concrete Project base revision.",
            successCriteria: ["Accepted artifact is in Context Pack"],
            constraints: ["Use Project state only"],
            pendingSteps: ["Review artifact"],
            repositoryPath: repository.path,
            currentEndpointID: ControlPlaneService.syntheticEndpointAID
        )
        try first.store.upsertTask(legacy)

        let migrated = try ControlPlaneService(dataDirectory: dataDirectory)
        let legacyContext = try migrated.projectKernelContext(taskID: legacy.id)
        #expect(legacyContext.workspace.baseRevision == baseRevision)

        let forge = try #require(
            try migrated.store.fetchAgent(id: ControlPlaneService.forgeAgentID)
        )
        let governed = try migrated.createTask(
            title: "Accepted artifact context",
            objective: "Use accepted outputs without leaking submitted outputs.",
            successCriteria: ["Only accepted artifact IDs are included"],
            constraints: ["Use accepted Project facts"],
            pendingSteps: ["Review the output"],
            repositoryPath: repository.path,
            sourceEndpointID: ControlPlaneService.syntheticEndpointAID,
            agentIdentityID: forge.id
        )
        let governedContext = try migrated.projectKernelContext(
            taskID: governed.id
        )
        #expect(governedContext.workspace.baseRevision == baseRevision)

        let acceptedCandidate = try migrated.submitRuntimeOutputArtifact(
            taskID: governed.id,
            producerActorID: governedContext.actor?.id,
            title: "Accepted output",
            output: "accepted project fact"
        )
        let review = try migrated.requestProjectReview(
            artifactID: acceptedCandidate.id,
            reviewerActorID: ControlPlaneService.localHumanActorID
        )
        _ = try migrated.resolveProjectReview(
            id: review.id,
            verdict: .approved,
            findings: []
        )
        let submittedCandidate = try migrated.submitRuntimeOutputArtifact(
            taskID: governed.id,
            producerActorID: governedContext.actor?.id,
            title: "Unreviewed output",
            output: "must not become Project context"
        )

        let pack = try migrated.buildProjectContextPack(taskID: governed.id)
        #expect(pack.baseRevision == baseRevision)
        #expect(pack.acceptedArtifactIDs == [acceptedCandidate.id])
        #expect(!pack.acceptedArtifactIDs.contains(submittedCandidate.id))
        #expect(
            pack.renderedMarkdown.contains(
                acceptedCandidate.id.uuidString.lowercased()
            )
        )
        #expect(
            !pack.renderedMarkdown.contains(
                submittedCandidate.id.uuidString.lowercased()
            )
        )
    }

    @Test
    func openWorkerApprovalIsLinkedToProjectGovernanceAndResolvedLocally()
        async throws
    {
        let fixture = try serviceFixture()
        defer { fixture.remove() }
        try fixture.service.store.upsertEndpoint(
            activeOpenWorkerFixtureEndpoint()
        )
        let scout = try #require(
            try fixture.service.store.fetchAgent(
                id: ControlPlaneService.scoutAgentID
            )
        )
        let task = try fixture.service.createTask(
            title: "OpenWorker approval governance",
            objective: "Link a native permission request to Project approval.",
            successCriteria: ["Approval remains accountable"],
            constraints: ["No network dispatch"],
            pendingSteps: ["Resolve native request"],
            repositoryPath: fixture.repository.path,
            sourceEndpointID: ControlPlaneService.openWorkerEndpointID,
            agentIdentityID: scout.id
        )
        let existingSession = try JSONDecoder().decode(
            OpenWorkerSessionSummary.self,
            from: Data(
                """
                {"session_id":"ow-approval-governance","workspace":"\(fixture.repository.path)","agent":"cowork","model":"fixture","mode":"interactive","messages":0,"liveness":"idle"}
                """.utf8
            )
        )
        let binding = try fixture.service.bindOpenWorkerSession(
            taskID: task.id,
            existingSession: existingSession
        )
        let context = try fixture.service.projectKernelContext(taskID: task.id)
        let interaction = try #require(
            try await fixture.service.recordOpenWorkerEvent(
                bindingID: binding.id,
                event: OpenWorkerEvent(
                    type: "permission_required",
                    data: ["name": .string("write_file")]
                )
            )
        )
        let approvalID = try #require(interaction.projectApprovalID)
        let approval = try #require(
            try fixture.service.store.fetchProjectApprovals().first {
                $0.id == approvalID
            }
        )

        #expect(interaction.kind == .approval)
        #expect(interaction.bindingID == binding.id)
        #expect(approval.projectID == context.project.id)
        #expect(approval.taskID == task.id)
        #expect(approval.runtimeInteractionID == interaction.id)
        #expect(approval.requestedByActorID == context.actor?.id)
        #expect(approval.approverActorID == ControlPlaneService.localHumanActorID)
        #expect(approval.scope == "openworker.approval")
        #expect(approval.decision == .pending)

        try fixture.service.resolveRuntimeInteraction(
            id: interaction.id,
            state: .approved
        )
        let resolved = try #require(
            try fixture.service.store.fetchProjectApprovals().first {
                $0.id == approvalID
            }
        )
        #expect(resolved.decision == .granted)
        #expect(resolved.resolvedAt != nil)
        let resolvedInteraction = try fixture.service.store
            .fetchRuntimeInteraction(id: interaction.id)
        #expect(resolvedInteraction?.state == .approved)
        #expect(
            try fixture.service.store.fetchEvents(taskID: task.id).contains {
                $0.type == "approval.requested" && $0.approvalID == approvalID
            }
        )
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "mu-project-kernel-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    private func serviceFixture() throws -> ServiceFixture {
        let root = try makeTemporaryRoot()
        let repository = root.appending(
            path: "Repository",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: repository,
            withIntermediateDirectories: true
        )
        let service = try ControlPlaneService(
            dataDirectory: root.appending(
                path: "data",
                directoryHint: .isDirectory
            )
        )
        return ServiceFixture(
            root: root,
            repository: repository,
            service: service
        )
    }

    private func uuid(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }

    private func initializeGitRepository(at repository: URL) throws -> String {
        try runGit(["init", "-q", repository.path])
        try "initial project state\n".write(
            to: repository.appending(path: "README.md"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["-C", repository.path, "config", "user.email", "test@mu.local"])
        try runGit(["-C", repository.path, "config", "user.name", "Mu Test"])
        try runGit(["-C", repository.path, "add", "README.md"])
        try runGit(["-C", repository.path, "commit", "-qm", "Initial state"])
        return try runGit(["-C", repository.path, "rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private func runGit(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        guard process.terminationStatus == 0 else {
            throw MuError.commandFailed(text)
        }
        return text
    }

    private func activeOpenWorkerFixtureEndpoint() -> RuntimeEndpoint {
        RuntimeEndpoint(
            id: ControlPlaneService.openWorkerEndpointID,
            runtimeTypeID: ControlPlaneService.openWorkerRuntimeTypeID,
            displayName: "OpenWorker governance fixture",
            adapterVersion: "test",
            runtimeVersion: "test",
            location: .local,
            provenance: .vendorProtocol,
            permissionModel: .promptGate,
            capabilities: ControlPlaneService.openWorkerImplementedCapabilities,
            status: .active,
            guaranteeNote: "Offline Project governance fixture.",
            nativeConfiguration: [
                "connection_mode": "fixture",
                "default_agent": "cowork",
                "default_model": "fixture"
            ]
        )
    }
}

private struct ServiceFixture {
    let root: URL
    let repository: URL
    let service: ControlPlaneService

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
