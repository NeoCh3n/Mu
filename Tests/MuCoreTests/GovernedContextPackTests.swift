import Foundation
@testable import MuCore
import Testing

@Suite(.serialized)
struct GovernedContextPackTests {
    @Test
    func packFiltersBeforeSelectionAndIsDeterministicWithinBudget()
        throws
    {
        let fixture = try Fixture.make()
        defer { fixture.remove() }

        let allowed = try fixture.insertAcceptedRecord(
            subject: "SQLite migration decision",
            value: "Use the local SQLite store for the context migration.",
            visibility: .selectedActors,
            allowedActorIDs: [fixture.actorID]
        )
        let deniedMarker = "DENIED-PAYLOAD-MUST-NOT-ENTER-PACK"
        let denied = try fixture.insertAcceptedRecord(
            subject: "Private operator note",
            value: deniedMarker,
            visibility: .selectedActors,
            allowedActorIDs: [UUID()]
        )
        let oversized = try fixture.insertAcceptedRecord(
            subject: "Low relevance appendix",
            value: String(repeating: "oversized-context-", count: 600),
            visibility: .selectedActors,
            allowedActorIDs: [fixture.actorID]
        )

        let first = try fixture.buildPack(tokenBudget: 1)
        let second = try fixture.buildPack(tokenBudget: 1)

        #expect(first.tokenBudget == 1_024)
        #expect(first.includedContextRecordIDs?.contains(allowed.id) == true)
        #expect(first.includedContextRecordIDs?.contains(denied.id) == false)
        #expect(first.includedContextRecordIDs?.contains(oversized.id) == false)
        #expect(first.renderedContextMarkdown?.contains(deniedMarker) == false)
        #expect((first.renderedContextMarkdown?.utf8.count ?? 0) <= 4_096)

        // Pack identity and delivery binding are intentionally unique, while
        // the governed selection and its revision receipts are deterministic.
        #expect(
            first.includedContextRecordIDs
                == second.includedContextRecordIDs
        )
        #expect(first.contextRevision == second.contextRevision)
        #expect(first.taskRevision == second.taskRevision)
        #expect(first.policyRevision == second.policyRevision)
        #expect(first.itemSetFingerprint == second.itemSetFingerprint)
    }

    @Test
    func freshnessRejectsTaskContentAndPolicyChanges()
        throws
    {
        let taskFixture = try Fixture.make()
        defer { taskFixture.remove() }
        _ = try taskFixture.insertAcceptedRecord(
            subject: "Build target",
            value: "Build the macOS application.",
            visibility: .selectedActors,
            allowedActorIDs: [taskFixture.actorID]
        )
        let taskPack = try taskFixture.buildPack()
        try taskFixture.service.validateGovernedContextPackIsFresh(
            projectID: taskFixture.projectID,
            packID: taskPack.id
        )

        var changedTask = try #require(
            try taskFixture.service.store.fetchTask(
                id: taskFixture.task.id
            )
        )
        changedTask.objective += " Include a signed release bundle."
        changedTask.updatedAt = changedTask.updatedAt.addingTimeInterval(1)
        try taskFixture.service.store.upsertTask(changedTask)
        #expect(throws: MuError.self) {
            try taskFixture.service.validateGovernedContextPackIsFresh(
                projectID: taskFixture.projectID,
                packID: taskPack.id
            )
        }

        let policyFixture = try Fixture.make()
        defer { policyFixture.remove() }
        let policyRecord = try policyFixture.insertAcceptedRecord(
            subject: "Runtime constraint",
            value: "Stay inside the imported workspace.",
            visibility: .selectedActors,
            allowedActorIDs: [policyFixture.actorID]
        )
        let policyPack = try policyFixture.buildPack()
        let currentPolicy = try #require(
            try policyFixture.service.store
                .fetchCurrentContextAccessPolicy(
                    projectID: policyFixture.projectID,
                    subjectKind: .record,
                    subjectID: policyRecord.id
                )
        )
        let replacement = try ContextAccessPolicyRecord(
            projectID: policyFixture.projectID,
            subjectKind: .record,
            subjectID: policyRecord.id,
            familyID: currentPolicy.familyID,
            version: currentPolicy.version + 1,
            supersedesPolicyID: currentPolicy.id,
            namespace: currentPolicy.namespace,
            sensitivity: currentPolicy.sensitivity,
            visibility: .selectedActors,
            allowedActorIDs: [],
            createdByActorID: ControlPlaneService.localHumanActorID,
            createdAt: currentPolicy.createdAt.addingTimeInterval(1)
        )
        try policyFixture.service.store.insertContextAccessPolicy(
            replacement
        )

        #expect(throws: MuError.self) {
            try policyFixture.service.validateGovernedContextPackIsFresh(
                projectID: policyFixture.projectID,
                packID: policyPack.id
            )
        }
    }

    @Test
    func freshnessRejectsPackWhoseRenderedCASObjectIsMissing()
        throws
    {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        _ = try fixture.insertAcceptedRecord(
            subject: "Acceptance boundary",
            value: "The immutable pack must remain reconstructible.",
            visibility: .selectedActors,
            allowedActorIDs: [fixture.actorID]
        )
        let pack = try fixture.buildPack()
        try fixture.service.validateGovernedContextPackIsFresh(
            projectID: fixture.projectID,
            packID: pack.id
        )

        try FileManager.default.removeItem(
            at: fixture.service.artifactStore.artifactURL(
                for: pack.contentSHA256
            )
        )
        #expect(throws: MuError.self) {
            try fixture.service.validateGovernedContextPackIsFresh(
                projectID: fixture.projectID,
                packID: pack.id
            )
        }
    }

    @Test
    func deliveryRequiresExactRunAndBindingThenCompletesOnce()
        throws
    {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        _ = try fixture.insertAcceptedRecord(
            subject: "Delivery rule",
            value: "Bind every turn to its exact immutable Context Pack.",
            visibility: .selectedActors,
            allowedActorIDs: [fixture.actorID]
        )

        let bindingID = fixture.bindingID
        let pack = try fixture.buildPack()
        let runID = UUID()
        try fixture.persistRuntimeBoundary(
            pack: pack,
            bindingID: bindingID,
            runID: runID
        )

        let prepared = try fixture.service.recordContextDelivery(
            projectID: fixture.projectID,
            packID: pack.id,
            status: .prepared
        )
        #expect(prepared.runtimeBindingID == bindingID)
        #expect(prepared.runID == runID)
        #expect(prepared.status == .prepared)

        let delivered = try fixture.service.recordContextDelivery(
            projectID: fixture.projectID,
            packID: pack.id,
            status: .delivered,
            adapterReceiptMaterial: "native-turn-receipt"
        )
        #expect(delivered.status == .delivered)
        #expect(delivered.completedAt != nil)
        #expect(
            delivered.adapterReceiptSHA256
                == Data("native-turn-receipt".utf8).muSHA256
        )
        #expect(throws: MuError.self) {
            _ = try fixture.service.recordContextDelivery(
                projectID: fixture.projectID,
                packID: pack.id,
                status: .failed,
                failureCode: "late-failure"
            )
        }

        let mismatchedPack = try fixture.buildPack()
        try fixture.persistRuntimeBoundary(
            pack: mismatchedPack,
            bindingID: bindingID,
            runID: UUID(),
            persistedContextPackID: pack.id
        )
        #expect(throws: MuError.self) {
            _ = try fixture.service.recordContextDelivery(
                projectID: fixture.projectID,
                packID: mismatchedPack.id,
                status: .prepared
            )
        }
    }

    private struct Fixture {
        let root: URL
        let service: ControlPlaneService
        let task: TaskRecord
        let projectID: UUID
        let workspaceID: UUID
        let actorID: UUID
        let principalID: UUID
        let endpointID: UUID
        let bindingID: UUID
        let lease: TaskLeaseRecord

        static func make() throws -> Fixture {
            let root = FileManager.default.temporaryDirectory.appending(
                path: "mu-governed-context-pack-tests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            let repository = root.appending(
                path: "repository",
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
            let endpointID = ControlPlaneService.syntheticEndpointAID
            let task = try service.createTask(
                title: "Build governed Context Pack",
                objective:
                    "Use the SQLite migration decision to build a deterministic Context Pack.",
                successCriteria: ["Pack remains auditable"],
                constraints: ["Read only"],
                pendingSteps: ["Build pack"],
                repositoryPath: repository.path,
                sourceEndpointID: endpointID,
                agentIdentityID: ControlPlaneService.forgeAgentID
            )
            let kernel = try service.projectKernelContext(
                taskID: task.id
            )
            let actorID = try #require(
                kernel.link.assignedToActorID
            )
            let principalID = try #require(
                kernel.principal?.id
            )
            let bindingID = UUID()
            let lease = try service.store.claimTaskLease(
                projectID: kernel.project.id,
                taskID: task.id,
                agentActorID: actorID,
                endpointID: endpointID,
                runtimeBindingID: bindingID,
                duration: 15 * 60
            )
            return Fixture(
                root: root,
                service: service,
                task: task,
                projectID: kernel.project.id,
                workspaceID: kernel.workspace.id,
                actorID: actorID,
                principalID: principalID,
                endpointID: endpointID,
                bindingID: bindingID,
                lease: lease
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        func buildPack(
            tokenBudget: Int = 8_000
        ) throws -> ProjectContextPackRecord {
            try service.buildGovernedContextPack(
                taskID: task.id,
                actorID: actorID,
                endpointID: endpointID,
                runtimeBindingID: bindingID,
                taskLeaseID: lease.id,
                tokenBudget: tokenBudget
            )
        }

        func insertAcceptedRecord(
            subject: String,
            value: String,
            visibility: ContextVisibility,
            allowedActorIDs: [UUID]
        ) throws -> ContextRecord {
            let now = Date()
            let sourceID = UUID()
            let sourcePolicyID = UUID()
            let recordID = UUID()
            let recordPolicyID = UUID()
            let source = ContextSourceRecord(
                id: sourceID,
                projectID: projectID,
                sourceType: .humanInput,
                sourceActorID: ControlPlaneService.localHumanActorID,
                sourcePrincipalID:
                    ControlPlaneService.localOwnerPrincipalID,
                externalRef: "test-source-\(sourceID.uuidString)",
                sourceChecksum:
                    Data("\(subject)\u{0}\(value)".utf8).muSHA256,
                accessPolicyID: sourcePolicyID,
                importedAt: now
            )
            let sourcePolicy = try ContextAccessPolicyRecord(
                id: sourcePolicyID,
                projectID: projectID,
                subjectKind: .source,
                subjectID: sourceID,
                namespace: "test/governed-pack",
                sensitivity: .project,
                visibility: visibility,
                allowedActorIDs: allowedActorIDs,
                allowedTaskIDs: [task.id],
                createdByActorID:
                    ControlPlaneService.localHumanActorID,
                createdAt: now
            )
            let candidate = try ContextRecord(
                id: recordID,
                projectID: projectID,
                sourceID: sourceID,
                externalID: "test-record-\(recordID.uuidString)",
                kind: .decision,
                subject: subject,
                value: .string(value),
                status: .candidate,
                authority: .humanReviewed,
                scope: ContextScope(taskID: task.id),
                sensitivity: .project,
                accessPolicyID: recordPolicyID,
                createdByActorID:
                    ControlPlaneService.localHumanActorID,
                createdAt: now
            )
            let recordPolicy = try ContextAccessPolicyRecord(
                id: recordPolicyID,
                projectID: projectID,
                subjectKind: .record,
                subjectID: recordID,
                namespace: "test/governed-pack",
                sensitivity: .project,
                visibility: visibility,
                allowedActorIDs: allowedActorIDs,
                allowedTaskIDs: [task.id],
                createdByActorID:
                    ControlPlaneService.localHumanActorID,
                createdAt: now
            )
            try service.store.withTransaction {
                try service.store.insertContextSource(
                    source,
                    transition: creationTransition(
                        kind: .source,
                        id: source.id,
                        toState: source.state.rawValue,
                        at: now
                    )
                )
                try service.store.insertContextAccessPolicy(
                    sourcePolicy
                )
                try service.store.insertContextRecord(
                    candidate,
                    transition: creationTransition(
                        kind: .record,
                        id: candidate.id,
                        toState: candidate.status.rawValue,
                        at: now
                    )
                )
                try service.store.insertContextAccessPolicy(
                    recordPolicy
                )
            }
            return try service.reviewContextRecord(
                projectID: projectID,
                recordID: candidate.id,
                actorID: ControlPlaneService.localHumanActorID,
                decision: .accept,
                reason: "Accepted by the test Project owner."
            )
        }

        func persistRuntimeBoundary(
            pack: ProjectContextPackRecord,
            bindingID: UUID,
            runID: UUID,
            persistedContextPackID: UUID? = nil
        ) throws {
            let contextPackID = persistedContextPackID ?? pack.id
            let run = RunRecord(
                id: runID,
                taskID: task.id,
                projectID: projectID,
                workspaceID: workspaceID,
                actorID: actorID,
                principalID: principalID,
                taskLeaseID: lease.id,
                contextPackID: contextPackID,
                endpointID: endpointID,
                actorName: "Pack test Agent",
                purpose: .execution,
                state: .active
            )
            let binding = RuntimeSessionBinding(
                id: bindingID,
                taskID: task.id,
                projectID: projectID,
                workspaceID: workspaceID,
                actorID: actorID,
                principalID: principalID,
                taskLeaseID: lease.id,
                runID: runID,
                contextPackID: contextPackID,
                endpointID: endpointID,
                nativeSessionID: "pack-test-\(bindingID.uuidString)",
                nativeAgentName: "Pack test Agent",
                workspacePath: task.repositoryPath,
                connectionMode: "test",
                state: .working
            )
            try service.store.withTransaction {
                try service.store.upsertRun(run)
                try service.store.upsertRuntimeSessionBinding(binding)
            }
        }

        private func creationTransition(
            kind: ContextTransitionAggregateKind,
            id: UUID,
            toState: String,
            at: Date
        ) -> ContextTransitionRecord {
            ContextTransitionRecord(
                projectID: projectID,
                aggregateKind: kind,
                aggregateID: id,
                transitionKind: .created,
                fromState: nil,
                toState: toState,
                actorID: ControlPlaneService.localHumanActorID,
                principalID: ControlPlaneService.localOwnerPrincipalID,
                reason: "Governed Context Pack test fixture.",
                expectedRevision: 0,
                newRevision: 1,
                occurredAt: at
            )
        }
    }
}
