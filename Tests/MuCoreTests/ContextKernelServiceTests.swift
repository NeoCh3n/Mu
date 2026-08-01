import Foundation
@testable import MuCore
import Testing

/// These are service-boundary tests: the bundle is encoded exactly as an
/// external Agent would send it, while authorization comes only from Mu's
/// provisioned Project actors.
@Suite(.serialized)
struct ContextKernelServiceTests {
    @Test
    func agentBundleImportCreatesRestrictedCandidateRecordsAndCompletedJob()
        throws
    {
        let fixture = try Fixture.make()
        defer { fixture.remove() }

        let result = try fixture.service.importAgentContextBundle(
            projectID: fixture.projectID,
            requestedByActorID: fixture.agentAID,
            idempotencyKey: "codex-export-1",
            rawData: try fixture.bundleData(
                recordValue: "Use the local SQLite store."
            )
        )

        #expect(result.wasIdempotentReplay == false)
        #expect(result.job.status == .completed)
        #expect(result.job.progress == 1)
        #expect(result.job.sourceID == result.source.id)
        #expect(result.job.recordIDs == result.records.map(\.id))
        #expect(result.source.state == .active)
        #expect(result.source.sourceActorID == fixture.agentAID)
        #expect(result.records.count == 1)
        #expect(result.records[0].status == .candidate)
        #expect(result.records[0].authority == .agentClaim)
        #expect(result.records[0].sensitivity == .restricted)

        let sourcePolicy = try #require(
            try fixture.service.store.fetchContextAccessPolicy(
                projectID: fixture.projectID,
                id: result.source.accessPolicyID!
            )
        )
        let recordPolicy = try #require(
            try fixture.service.store.fetchContextAccessPolicy(
                projectID: fixture.projectID,
                id: result.records[0].accessPolicyID!
            )
        )
        for policy in [sourcePolicy, recordPolicy] {
            #expect(policy.namespace == "agent-import/restricted")
            #expect(policy.visibility == .ownerOnly)
            #expect(policy.sensitivity == .restricted)
            #expect(policy.allowedActorIDs.isEmpty)
            #expect(policy.allowedPrincipalIDs.isEmpty)
        }

        let jobTransitions = try fixture.service.store
            .fetchContextTransitions(
                projectID: fixture.projectID,
                aggregateKind: .importJob,
                aggregateID: result.job.id
            )
        #expect(jobTransitions.map(\.toState) == [
            ContextImportJobStatus.received.rawValue,
            ContextImportJobStatus.validating.rawValue,
            ContextImportJobStatus.importing.rawValue,
            ContextImportJobStatus.completed.rawValue
        ])
        let recordTransitions = try fixture.service.store
            .fetchContextTransitions(
                projectID: fixture.projectID,
                aggregateKind: .record,
                aggregateID: result.records[0].id
            )
        #expect(recordTransitions.map(\.toState) == [
            ContextRecordStatus.candidate.rawValue
        ])
    }

    @Test
    func importIdempotencyIsScopedToAuthenticatedActorAndByteExact()
        throws
    {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let bytes = try fixture.bundleData(recordValue: "first")

        let first = try fixture.service.importAgentContextBundle(
            projectID: fixture.projectID,
            requestedByActorID: fixture.agentAID,
            idempotencyKey: "shared-key",
            rawData: bytes
        )
        let replay = try fixture.service.importAgentContextBundle(
            projectID: fixture.projectID,
            requestedByActorID: fixture.agentAID,
            idempotencyKey: "shared-key",
            rawData: bytes
        )
        #expect(replay.wasIdempotentReplay)
        #expect(replay.job.id == first.job.id)
        #expect(replay.source.id == first.source.id)
        #expect(replay.records.map(\.id) == first.records.map(\.id))

        #expect(throws: MuError.self) {
            _ = try fixture.service.importAgentContextBundle(
                projectID: fixture.projectID,
                requestedByActorID: fixture.agentAID,
                idempotencyKey: "shared-key",
                rawData: try fixture.bundleData(recordValue: "different")
            )
        }

        let otherActor = try fixture.service.importAgentContextBundle(
            projectID: fixture.projectID,
            requestedByActorID: fixture.agentBID,
            idempotencyKey: "shared-key",
            rawData: bytes
        )
        #expect(otherActor.job.id != first.job.id)
        #expect(otherActor.source.id != first.source.id)
        #expect(otherActor.source.sourceActorID == fixture.agentBID)
        #expect(
            try fixture.service.store.fetchContextImportJobs(
                projectID: fixture.projectID
            ).count == 2
        )
    }

    @Test
    func onlyHumanReviewerCanAcceptOrRejectCandidateContext()
        throws
    {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let imported = try fixture.service.importAgentContextBundle(
            projectID: fixture.projectID,
            requestedByActorID: fixture.agentAID,
            idempotencyKey: "review-boundary",
            rawData: try fixture.bundleData(recordValue: "candidate")
        )
        let recordID = try #require(imported.records.first?.id)

        #expect(throws: MuError.self) {
            _ = try fixture.service.reviewContextRecord(
                projectID: fixture.projectID,
                recordID: recordID,
                actorID: fixture.agentAID,
                decision: .accept,
                reason: "Agent must not self-approve."
            )
        }
        #expect(throws: MuError.self) {
            _ = try fixture.service.reviewContextRecord(
                projectID: fixture.projectID,
                recordID: recordID,
                actorID: fixture.agentAID,
                decision: .reject,
                reason: "Agent must not self-reject authoritative state."
            )
        }

        let accepted = try fixture.service.reviewContextRecord(
            projectID: fixture.projectID,
            recordID: recordID,
            actorID: fixture.humanActorID,
            decision: .accept,
            reason: "Local owner reviewed the proposal."
        )
        #expect(accepted.status == .accepted)
        #expect(accepted.statusUpdatedByActorID == fixture.humanActorID)
        #expect(accepted.revision == 2)
    }

    @Test
    func overlappingDifferentClaimsCreateDeterministicConflictAndHumanResolves()
        throws
    {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let first = try fixture.service.importAgentContextBundle(
            projectID: fixture.projectID,
            requestedByActorID: fixture.agentAID,
            idempotencyKey: "claim-a",
            rawData: try fixture.bundleData(
                subject: "Deployment target",
                recordValue: "staging"
            )
        )
        let second = try fixture.service.importAgentContextBundle(
            projectID: fixture.projectID,
            requestedByActorID: fixture.agentBID,
            idempotencyKey: "claim-b",
            rawData: try fixture.bundleData(
                subject: " deployment target ",
                recordValue: "production"
            )
        )
        let firstID = try #require(first.records.first?.id)
        let secondID = try #require(second.records.first?.id)
        let conflict = try #require(second.conflicts.first)
        let expectedID = ContextConflictRecord.stableID(
            projectID: fixture.projectID,
            subject: "deployment target",
            recordIDs: [firstID, secondID]
        )
        #expect(conflict.id == expectedID)
        #expect(conflict.status == .unresolved)
        #expect(conflict.recordIDs == [firstID, secondID].sorted {
            $0.uuidString < $1.uuidString
        })

        let resolved = try fixture.service.resolveContextConflict(
            projectID: fixture.projectID,
            conflictID: conflict.id,
            actorID: fixture.humanActorID,
            acceptedRecordIDs: [secondID],
            acceptMultiple: false,
            reason: "The deployment decision is production."
        )
        #expect(resolved.status == .resolved)
        #expect(resolved.acceptedRecordIDs == [secondID])
        #expect(resolved.resolvedByActorID == fixture.humanActorID)
        #expect(resolved.revision == 2)
    }

    @Test
    func humanSupersessionPinsAcceptedReplacementAndAuditRelation()
        throws
    {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let originalImport =
            try fixture.service.importAgentContextBundle(
                projectID: fixture.projectID,
                requestedByActorID: fixture.agentAID,
                idempotencyKey: "supersede-original",
                rawData: try fixture.bundleData(
                    subject: "Storage decision",
                    recordValue: "Use a JSON file."
                )
            )
        let replacementImport =
            try fixture.service.importAgentContextBundle(
                projectID: fixture.projectID,
                requestedByActorID: fixture.agentBID,
                idempotencyKey: "supersede-replacement",
                rawData: try fixture.bundleData(
                    subject: "Storage decision",
                    recordValue: "Use SQLite with migrations."
                )
            )
        let originalID = try #require(
            originalImport.records.first?.id
        )
        let replacementID = try #require(
            replacementImport.records.first?.id
        )
        _ = try fixture.service.reviewContextRecord(
            projectID: fixture.projectID,
            recordID: originalID,
            actorID: fixture.humanActorID,
            decision: .accept,
            reason: "Accepted as the initial decision."
        )
        _ = try fixture.service.reviewContextRecord(
            projectID: fixture.projectID,
            recordID: replacementID,
            actorID: fixture.humanActorID,
            decision: .accept,
            reason: "Accepted after implementation review."
        )

        #expect(throws: MuError.self) {
            _ = try fixture.service.supersedeContextRecord(
                projectID: fixture.projectID,
                recordID: originalID,
                with: replacementID,
                actorID: fixture.agentAID,
                reason: "An Agent cannot rewrite canonical state."
            )
        }
        let superseded =
            try fixture.service.supersedeContextRecord(
                projectID: fixture.projectID,
                recordID: originalID,
                with: replacementID,
                actorID: fixture.humanActorID,
                reason:
                    "SQLite is the reviewed implementation decision."
            )
        #expect(superseded.status == .superseded)
        #expect(
            superseded.supersededByRecordID
                == replacementID
        )
        #expect(superseded.revision == 3)

        let relations = try fixture.service.store
            .fetchContextRelations(
                projectID: fixture.projectID
            )
        let relation = try #require(
            relations.first {
                $0.relationType == .supersedes
            }
        )
        #expect(relation.fromRecordID == replacementID)
        #expect(relation.toRecordID == originalID)
        let transitions = try fixture.service.store
            .fetchContextTransitions(
                projectID: fixture.projectID,
                aggregateKind: .record,
                aggregateID: originalID
            )
        #expect(transitions.last?.transitionKind == .superseded)
        #expect(
            transitions.last?.toState
                == ContextRecordStatus.superseded.rawValue
        )
    }

    @Test
    func selfReportedForeignProjectOrPrincipalIsRejectedBeforePersistence()
        throws
    {
        let fixture = try Fixture.make()
        defer { fixture.remove() }

        #expect(throws: MuError.self) {
            _ = try fixture.service.importAgentContextBundle(
                projectID: fixture.projectID,
                requestedByActorID: fixture.agentAID,
                idempotencyKey: "foreign-project",
                rawData: try fixture.bundleData(
                    sourceProjectID: UUID().uuidString
                )
            )
        }
        #expect(throws: MuError.self) {
            _ = try fixture.service.importAgentContextBundle(
                projectID: fixture.projectID,
                requestedByActorID: fixture.agentAID,
                idempotencyKey: "foreign-principal",
                rawData: try fixture.bundleData(
                    ownerPrincipalID: UUID().uuidString
                )
            )
        }
        #expect(
            try fixture.service.store.fetchContextImportJobs(
                projectID: fixture.projectID
            ).isEmpty
        )
        #expect(
            try fixture.service.store.fetchContextSources(
                projectID: fixture.projectID
            ).isEmpty
        )
        #expect(
            try fixture.service.store.fetchContextRecords(
                projectID: fixture.projectID
            ).isEmpty
        )
    }

    private struct Fixture {
        let root: URL
        let service: ControlPlaneService
        let projectID: UUID
        let principalID: UUID
        let humanActorID: UUID
        let agentAID: UUID
        let agentBID: UUID

        static func make() throws -> Fixture {
            let root = FileManager.default.temporaryDirectory.appending(
                path: "mu-context-service-tests-\(UUID().uuidString)",
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
            let fixture = Fixture(
                root: root,
                service: service,
                projectID: UUID(),
                principalID: UUID(),
                humanActorID: UUID(),
                agentAID: UUID(),
                agentBID: UUID()
            )
            try fixture.provision()
            return fixture
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        func bundleData(
            subject: String = "Implementation approach",
            recordValue: String = "Use an explicit Context Pack.",
            ownerPrincipalID: String? = nil,
            sourceProjectID: String? = nil
        ) throws -> Data {
            try MuCoding.makeEncoder().encode(AgentContextBundle(
                bundleID: "bundle-\(UUID().uuidString)",
                agentID: "external-agent",
                ownerPrincipalID: ownerPrincipalID ?? principalID.uuidString,
                sourceProjectID: sourceProjectID ?? projectID.uuidString,
                exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
                records: [AgentContextBundleRecord(
                    externalID: "statement-1",
                    kind: .decision,
                    subject: subject,
                    value: .string(recordValue),
                    scope: ContextScope(environment: "production")
                )]
            ))
        }

        private func provision() throws {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            try service.store.upsertPrincipal(PrincipalRecord(
                id: principalID,
                kind: .person,
                displayName: "Context test owner",
                createdAt: now,
                updatedAt: now
            ))
            try service.store.upsertProject(ProjectRecord(
                id: projectID,
                displayName: "Context service test project",
                ownerPrincipalID: principalID,
                createdAt: now,
                updatedAt: now
            ))
            try service.store.upsertProjectActor(ProjectActorRecord(
                id: humanActorID,
                principalID: principalID,
                kind: .human,
                displayName: "Human owner",
                createdAt: now,
                updatedAt: now
            ))
            try service.store.upsertProjectMembership(ProjectMembershipRecord(
                projectID: projectID,
                actorID: humanActorID,
                role: .owner,
                createdAt: now,
                updatedAt: now
            ))
            for (index, actorID) in [agentAID, agentBID].enumerated() {
                try service.store.upsertProjectActor(ProjectActorRecord(
                    id: actorID,
                    principalID: principalID,
                    kind: .agent,
                    displayName: "Agent \(index + 1)",
                    createdAt: now,
                    updatedAt: now
                ))
                try service.store.upsertProjectMembership(
                    ProjectMembershipRecord(
                        projectID: projectID,
                        actorID: actorID,
                        role: .externalAgent,
                        createdAt: now,
                        updatedAt: now
                    )
                )
                try service.store.upsertDelegation(DelegationRecord(
                    projectID: projectID,
                    principalID: principalID,
                    delegatedByActorID: humanActorID,
                    agentActorID: actorID,
                    permissions: [.proposeContext],
                    createdAt: now,
                    updatedAt: now
                ))
            }
        }
    }
}
