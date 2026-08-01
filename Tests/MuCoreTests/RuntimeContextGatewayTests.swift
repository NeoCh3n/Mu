import Foundation
@testable import MuCore
import Testing

@Suite(.serialized)
struct RuntimeContextGatewayTests {
    @Test
    func gatewayRejectsPreparedOnlyThenAcceptsExactDeliveredBinding()
        throws
    {
        let fixture = try Fixture.make()
        defer { fixture.remove() }

        #expect(throws: MuError.self) {
            _ = try fixture.service.runtimeContextSearch(
                bindingID: fixture.binding.id,
                query: "anything"
            )
        }

        try fixture.insertDelivery(status: .delivered)
        let results = try fixture.service.runtimeContextSearch(
            bindingID: fixture.binding.id,
            query: "anything",
            limit: 5
        )
        #expect(results.isEmpty)
        #expect(
            try fixture.service.runtimeContextRecord(
                bindingID: fixture.binding.id,
                recordID: UUID()
            ) == nil
        )
    }

    @Test
    func runtimeCannotReusePackThroughAnotherBinding() throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        try fixture.insertDelivery(status: .delivered)

        var forged = fixture.binding
        forged.id = UUID()
        forged.nativeSessionID = "forged-native-session"
        try fixture.service.store.upsertRuntimeSessionBinding(forged)

        #expect(throws: MuError.self) {
            _ = try fixture.service.runtimeContextSearch(
                bindingID: forged.id,
                query: "anything"
            )
        }
    }

    @Test
    func runtimeCannotUseCompletedBindingOrRun() throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        try fixture.insertDelivery(status: .delivered)

        var completed = fixture.binding
        completed.state = .completed
        try fixture.service.store.upsertRuntimeSessionBinding(completed)
        #expect(throws: MuError.self) {
            _ = try fixture.service.runtimeContextSearch(
                bindingID: completed.id,
                query: "anything"
            )
        }
    }

    private struct Fixture {
        let root: URL
        let service: ControlPlaneService
        let projectID: UUID
        let principalID: UUID
        let actorID: UUID
        let task: TaskRecord
        let workspace: ProjectWorkspaceRecord
        let run: RunRecord
        let binding: RuntimeSessionBinding
        let lease: TaskLeaseRecord
        let pack: ProjectContextPackRecord

        static func make() throws -> Fixture {
            let root = FileManager.default.temporaryDirectory.appending(
                path: "mu-runtime-context-gateway-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let service = try ControlPlaneService(
                dataDirectory: root.appending(
                    path: "data",
                    directoryHint: .isDirectory
                )
            )
            let projectID = UUID()
            let principalID = UUID()
            let humanActorID = UUID()
            let actorID = UUID()
            let taskID = UUID()
            let workspaceID = UUID()
            let runID = UUID()
            let bindingID = UUID()
            let leaseID = UUID()
            let packID = UUID()
            let endpointID = ControlPlaneService.codexEndpointID
            let now = Date()

            try service.store.upsertPrincipal(
                PrincipalRecord(
                    id: principalID,
                    kind: .organization,
                    displayName: "Runtime principal"
                )
            )
            try service.store.upsertProject(
                ProjectRecord(
                    id: projectID,
                    displayName: "Runtime Context Project",
                    ownerPrincipalID: principalID
                )
            )
            try service.store.upsertProjectActor(
                ProjectActorRecord(
                    id: humanActorID,
                    principalID: principalID,
                    kind: .human,
                    displayName: "Runtime Context owner"
                )
            )
            try service.store.upsertProjectMembership(
                ProjectMembershipRecord(
                    projectID: projectID,
                    actorID: humanActorID,
                    role: .owner
                )
            )
            try service.store.upsertProjectActor(
                ProjectActorRecord(
                    id: actorID,
                    principalID: principalID,
                    kind: .agent,
                    displayName: "Codex runtime actor",
                    runtimeEndpointID: endpointID
                )
            )
            try service.store.upsertProjectMembership(
                ProjectMembershipRecord(
                    projectID: projectID,
                    actorID: actorID,
                    role: .externalAgent
                )
            )
            try service.store.upsertDelegation(
                DelegationRecord(
                    projectID: projectID,
                    principalID: principalID,
                    delegatedByActorID: humanActorID,
                    agentActorID: actorID,
                    permissions: [.readContext]
                )
            )
            guard var endpoint = try service.store
                .fetchRegisteredEndpoint(id: endpointID) else {
                throw MuError.recordNotFound("Codex endpoint")
            }
            endpoint.status = .active
            try service.store.upsertEndpoint(endpoint)

            let workspace = ProjectWorkspaceRecord(
                id: workspaceID,
                projectID: projectID,
                taskID: taskID,
                repositoryPath: root.path,
                isolationKind: .sharedProjectFolder
            )
            try service.store.upsertProjectWorkspace(workspace)
            let task = TaskRecord(
                id: taskID,
                projectID: projectID,
                workspaceID: workspaceID,
                requestedByActorID:
                    ControlPlaneService.localHumanActorID,
                assignedActorID: actorID,
                title: "Runtime Context lookup",
                objective: "Read only governed Project Context.",
                successCriteria: ["No authority supplied by Runtime"],
                constraints: ["Read-only"],
                pendingSteps: [],
                repositoryPath: root.path,
                status: .running,
                currentEndpointID: endpointID,
                currentRunID: runID
            )
            try service.store.upsertTask(task)
            try service.store.upsertTaskProjectLink(
                TaskProjectLink(
                    taskID: taskID,
                    projectID: projectID,
                    workspaceID: workspaceID,
                    requestedByActorID:
                        ControlPlaneService.localHumanActorID,
                    assignedToActorID: actorID,
                    costOwnerPrincipalID: principalID
                )
            )
            let lease = TaskLeaseRecord(
                id: leaseID,
                projectID: projectID,
                taskID: taskID,
                agentActorID: actorID,
                endpointID: endpointID,
                runtimeBindingID: bindingID,
                fencingToken: 1,
                issuedAt: now,
                expiresAt: now.addingTimeInterval(3_600),
                lastHeartbeatAt: now
            )
            try service.store.upsertTaskLease(lease)
            let run = RunRecord(
                id: runID,
                taskID: taskID,
                projectID: projectID,
                workspaceID: workspaceID,
                actorID: actorID,
                principalID: principalID,
                taskLeaseID: leaseID,
                endpointID: endpointID,
                actorName: "Codex",
                purpose: .execution,
                state: .active
            )
            var binding = RuntimeSessionBinding(
                id: bindingID,
                taskID: taskID,
                projectID: projectID,
                workspaceID: workspaceID,
                actorID: actorID,
                principalID: principalID,
                taskLeaseID: leaseID,
                runID: runID,
                endpointID: endpointID,
                nativeSessionID: "native-session",
                nativeAgentName: "Codex",
                workspacePath: root.path,
                connectionMode: "managed",
                state: .working
            )
            let packPolicy = try ContextAccessPolicyRecord(
                projectID: projectID,
                subjectKind: .pack,
                subjectID: packID,
                namespace:
                    "runtime-context-test/\(taskID.uuidString.lowercased())",
                sensitivity: .project,
                visibility: .selectedActors,
                allowedActorIDs: [actorID],
                allowedTaskIDs: [taskID],
                createdByActorID: humanActorID
            )
            let packItem = ContextPackItemRecord(
                projectID: projectID,
                packID: packID,
                itemKind: .projectFact,
                referencedID: taskID,
                inclusionReason: "Pinned Task revision",
                ordinal: 0,
                renderedSHA256:
                    Data(task.objective.utf8).muSHA256,
                referencedSHA256: "task-revision",
                policyReceipts: [
                    ContextPolicyReceipt(policy: packPolicy)
                ]
            )
            var pack = ProjectContextPackRecord(
                id: packID,
                projectID: projectID,
                taskID: taskID,
                workspaceID: workspaceID,
                objective: task.objective,
                constraints: task.constraints,
                permissions: [.readContext],
                acceptanceTests: task.successCriteria,
                actorID: actorID,
                principalID: principalID,
                runtimeEndpointID: endpointID,
                runtimeBindingID: bindingID,
                taskLeaseID: leaseID,
                leaseFencingToken: 1,
                selectionPolicyVersion: "mu-context-selection-v1",
                tokenBudget: 8_000,
                contextRevision: "context-revision",
                taskRevision: "task-revision",
                policyRevision: "policy-revision",
                itemSetFingerprint: "item-set",
                budgetEstimatorVersion:
                    "utf8-bytes-per-token-v1:4",
                canonicalizationVersion:
                    ProjectContextValue.canonicalizationVersion,
                includedContextRecordIDs: [],
                unresolvedContextConflictIDs: [],
                contextPackItemIDs: [packItem.id],
                renderedContextMarkdown:
                    "No accepted Context records were selected.",
                contentSHA256: ""
            )
            pack.contentSHA256 = Data(
                pack.renderedMarkdown.utf8
            ).muSHA256
            let reference = try service.artifactStore.put(
                Data(pack.renderedMarkdown.utf8)
            )
            pack.renderedArtifactURI = reference.uri
            binding.contextPackID = pack.id
            var storedRun = run
            storedRun.contextPackID = pack.id
            try service.store.upsertRun(storedRun)
            try service.store.upsertRuntimeSessionBinding(binding)
            try service.store.withTransaction {
                try service.store.insertProjectContextPack(pack)
                try service.store.insertContextAccessPolicy(packPolicy)
                try service.store.insertContextPackItem(packItem)
            }

            let fixture = Fixture(
                root: root,
                service: service,
                projectID: projectID,
                principalID: principalID,
                actorID: actorID,
                task: task,
                workspace: workspace,
                run: storedRun,
                binding: binding,
                lease: lease,
                pack: pack
            )
            try fixture.insertDelivery(status: .prepared)
            return fixture
        }

        func insertDelivery(status: ContextDeliveryStatus) throws {
            let now = Date()
            try service.store.insertContextDelivery(
                ContextDeliveryReceipt(
                    projectID: projectID,
                    taskID: task.id,
                    contextPackID: pack.id,
                    runtimeBindingID: binding.id,
                    runID: run.id,
                    endpointID: binding.endpointID,
                    actorID: actorID,
                    principalID: principalID,
                    workspaceID: workspace.id,
                    taskLeaseID: lease.id,
                    leaseFencingToken: lease.fencingToken,
                    contextRevision: pack.contextRevision!,
                    policyRevision: pack.policyRevision!,
                    packContentSHA256: pack.contentSHA256,
                    status: status,
                    adapterReceiptSHA256:
                        status == .delivered
                        ? Data("adapter-receipt".utf8).muSHA256
                        : nil,
                    preparedAt: now,
                    completedAt:
                        status == .delivered ? now : nil
                )
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
