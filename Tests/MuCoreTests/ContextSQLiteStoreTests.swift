import Foundation
import SQLite3
@testable import MuCore
import Testing

@Suite(.serialized)
struct ContextSQLiteStoreTests {
    @Test
    func sameChecksumFromDifferentAuthenticatedAgentsRetainsBothSources()
        throws
    {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        _ = try insertSource(
            store: fixture.store,
            projectID: fixture.projectID,
            humanActorID: fixture.humanActorID,
            principalID: fixture.principalID,
            actorID: fixture.agentAID,
            checksum: "same-export-checksum",
            importedAt: fixture.start
        )
        _ = try insertSource(
            store: fixture.store,
            projectID: fixture.projectID,
            humanActorID: fixture.humanActorID,
            principalID: fixture.principalID,
            actorID: fixture.agentBID,
            checksum: "same-export-checksum",
            importedAt: fixture.start.addingTimeInterval(1)
        )

        let stored = try fixture.store.fetchContextSources(
            projectID: fixture.projectID,
            checksum: "same-export-checksum"
        )
        #expect(stored.count == 2)
        #expect(Set(stored.map(\.sourceActorID)) == [
            fixture.agentAID,
            fixture.agentBID
        ])
    }

    @Test
    func rawSQLiteRejectsContextRecordWhoseSourceBelongsToAnotherProject()
        throws
    {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let secondProjectID = UUID()
        try provision(
            store: fixture.store,
            projectID: secondProjectID,
            principalID: fixture.principalID,
            humanActorID: fixture.humanActorID,
            agentActorIDs: [fixture.agentAID, fixture.agentBID],
            at: fixture.start
        )
        let foreignSource = try insertSource(
            store: fixture.store,
            projectID: secondProjectID,
            humanActorID: fixture.humanActorID,
            principalID: fixture.principalID,
            actorID: fixture.agentAID,
            checksum: "foreign-source",
            importedAt: fixture.start
        )

        var database: OpaquePointer?
        #expect(sqlite3_open_v2(
            fixture.store.databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, "PRAGMA foreign_keys = ON;", nil, nil, nil) == SQLITE_OK)

        let rawPolicyID = UUID()
        let policySQL = """
        INSERT INTO context_access_policies(
            id, project_id, subject_kind, subject_id, source_id,
            record_id, pack_id, family_id, version,
            supersedes_policy_id, policy_sha256, sort_at, json
        ) VALUES (
            '\(rawPolicyID.uuidString)', '\(fixture.projectID.uuidString)',
            'artifact', '\(UUID().uuidString)', NULL, NULL, NULL,
            '\(UUID().uuidString)', 1, NULL, 'raw-policy',
            '2023-11-14T00:00:00Z', '{}'
        );
        """
        #expect(sqlite3_exec(database, policySQL, nil, nil, nil) == SQLITE_OK)
        let SQL = """
        INSERT INTO context_records(
            id, project_id, source_id, external_id, content_sha256,
            immutable_fingerprint, kind, status, scope_task_id, sensitivity,
            access_policy_id, revision, subject, sort_at, json
        ) VALUES (
            '\(UUID().uuidString)', '\(fixture.projectID.uuidString)',
            '\(foreignSource.id.uuidString)', 'raw-injection', 'checksum',
            'fingerprint', 'fact', 'candidate', NULL, 'restricted',
            '\(rawPolicyID.uuidString)', 1, 'cross-project',
            '2023-11-14T00:00:00Z', '{}'
        );
        """
        let result = sqlite3_exec(database, SQL, nil, nil, nil)

        #expect(result == SQLITE_CONSTRAINT)
        #expect(
            try fixture.store.fetchContextRecords(
                projectID: fixture.projectID
            ).isEmpty
        )
    }

    @Test
    func recordLifecycleRejectsRollbackPayloadRewriteAndStaleRevision()
        throws
    {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let source = try insertSource(
            store: fixture.store,
            projectID: fixture.projectID,
            humanActorID: fixture.humanActorID,
            principalID: fixture.principalID,
            actorID: fixture.agentAID,
            checksum: "record-source",
            importedAt: fixture.start.addingTimeInterval(1)
        )
        let initial = try insertRecord(
            into: fixture,
            sourceID: source.id,
            actorID: fixture.agentAID,
            createdAt: fixture.start.addingTimeInterval(2)
        )

        var stale = initial
        stale.status = .accepted
        stale.statusUpdatedAt = fixture.start.addingTimeInterval(3)
        stale.statusUpdatedByActorID = fixture.humanActorID
        #expect(throws: MuError.self) {
            try fixture.store.updateContextRecordLifecycle(
                stale,
                transition: transition(
                    for: stale,
                    actorID: fixture.humanActorID,
                    principalID: fixture.principalID,
                    kind: .record,
                    transitionKind: .stateChanged,
                    from: .candidate,
                    to: .accepted,
                    expectedRevision: 1,
                    newRevision: 2,
                    at: stale.statusUpdatedAt
                )
            )
        }

        var rewritten = initial
        rewritten.status = .accepted
        rewritten.revision = 2
        rewritten.statusUpdatedAt = fixture.start.addingTimeInterval(4)
        rewritten.statusUpdatedByActorID = fixture.humanActorID
        rewritten.value = .string("rewritten raw payload")
        #expect(throws: MuError.self) {
            try fixture.store.updateContextRecordLifecycle(
                rewritten,
                transition: transition(
                    for: rewritten,
                    actorID: fixture.humanActorID,
                    principalID: fixture.principalID,
                    kind: .record,
                    transitionKind: .stateChanged,
                    from: .candidate,
                    to: .accepted,
                    expectedRevision: 1,
                    newRevision: 2,
                    at: rewritten.statusUpdatedAt
                )
            )
        }

        var accepted = initial
        accepted.status = .accepted
        accepted.revision = 2
        accepted.statusUpdatedAt = fixture.start.addingTimeInterval(5)
        accepted.statusUpdatedByActorID = fixture.humanActorID
        try fixture.store.updateContextRecordLifecycle(
            accepted,
            transition: transition(
                for: accepted,
                actorID: fixture.humanActorID,
                principalID: fixture.principalID,
                kind: .record,
                transitionKind: .stateChanged,
                from: .candidate,
                to: .accepted,
                expectedRevision: 1,
                newRevision: 2,
                at: accepted.statusUpdatedAt
            )
        )

        var rollback = accepted
        rollback.status = .candidate
        rollback.revision = 3
        rollback.statusUpdatedAt = fixture.start.addingTimeInterval(6)
        rollback.statusUpdatedByActorID = fixture.humanActorID
        #expect(throws: MuError.self) {
            try fixture.store.updateContextRecordLifecycle(
                rollback,
                transition: transition(
                    for: rollback,
                    actorID: fixture.humanActorID,
                    principalID: fixture.principalID,
                    kind: .record,
                    transitionKind: .stateChanged,
                    from: .accepted,
                    to: .candidate,
                    expectedRevision: 2,
                    newRevision: 3,
                    at: rollback.statusUpdatedAt
                )
            )
        }
        #expect(
            try fixture.store.fetchContextRecord(
                projectID: fixture.projectID,
                id: initial.id
            )?.status == .accepted
        )
    }

    @Test
    func importJobsFenceIdempotencyPerAuthenticatedActorAndChecksum()
        throws
    {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let first = ContextImportJobRecord(
            projectID: fixture.projectID,
            sourceActorID: fixture.agentAID,
            sourcePrincipalID: fixture.principalID,
            bundleChecksum: "bundle-a",
            idempotencyKey: "shared-idempotency-key",
            createdAt: fixture.start,
            updatedAt: fixture.start
        )
        try insertImportJob(first, fixture: fixture, actorID: fixture.agentAID)

        let invalidReuse = ContextImportJobRecord(
            projectID: fixture.projectID,
            sourceActorID: fixture.agentAID,
            sourcePrincipalID: fixture.principalID,
            bundleChecksum: "bundle-b",
            idempotencyKey: "shared-idempotency-key",
            createdAt: fixture.start.addingTimeInterval(1),
            updatedAt: fixture.start.addingTimeInterval(1)
        )
        #expect(throws: MuError.self) {
            try insertImportJob(
                invalidReuse,
                fixture: fixture,
                actorID: fixture.agentAID
            )
        }

        let independent = ContextImportJobRecord(
            projectID: fixture.projectID,
            sourceActorID: fixture.agentBID,
            sourcePrincipalID: fixture.principalID,
            bundleChecksum: "bundle-b",
            idempotencyKey: "shared-idempotency-key",
            createdAt: fixture.start.addingTimeInterval(2),
            updatedAt: fixture.start.addingTimeInterval(2)
        )
        try insertImportJob(
            independent,
            fixture: fixture,
            actorID: fixture.agentBID
        )

        #expect(
            try fixture.store.fetchContextImportJob(
                projectID: fixture.projectID,
                sourceActorID: fixture.agentAID,
                idempotencyKey: "shared-idempotency-key"
            )?.id == first.id
        )
        #expect(
            try fixture.store.fetchContextImportJob(
                projectID: fixture.projectID,
                sourceActorID: fixture.agentBID,
                idempotencyKey: "shared-idempotency-key"
            )?.id == independent.id
        )
        #expect(
            try fixture.store.fetchContextImportJobs(
                projectID: fixture.projectID
            ).count == 2
        )
    }

    @Test
    func recordProjectionAndAppendOnlyTransitionStayInLockstep()
        throws
    {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let source = try insertSource(
            store: fixture.store,
            projectID: fixture.projectID,
            humanActorID: fixture.humanActorID,
            principalID: fixture.principalID,
            actorID: fixture.agentAID,
            checksum: "projection-source",
            importedAt: fixture.start.addingTimeInterval(1)
        )
        let record = try insertRecord(
            into: fixture,
            sourceID: source.id,
            actorID: fixture.agentAID,
            createdAt: fixture.start.addingTimeInterval(2)
        )

        let initialProjection = try #require(
            try fixture.store.fetchContextRecord(
                projectID: fixture.projectID,
                id: record.id
            )
        )
        let initialTransitions = try fixture.store.fetchContextTransitions(
            projectID: fixture.projectID,
            aggregateKind: .record,
            aggregateID: record.id
        )
        #expect(initialProjection.status == .candidate)
        #expect(initialProjection.revision == 1)
        #expect(initialTransitions.map(\.newRevision) == [1])

        var accepted = initialProjection
        accepted.status = .accepted
        accepted.revision = 2
        accepted.statusUpdatedAt = fixture.start.addingTimeInterval(3)
        accepted.statusUpdatedByActorID = fixture.humanActorID
        try fixture.store.updateContextRecordLifecycle(
            accepted,
            transition: transition(
                for: accepted,
                actorID: fixture.humanActorID,
                principalID: fixture.principalID,
                kind: .record,
                transitionKind: .stateChanged,
                from: .candidate,
                to: .accepted,
                expectedRevision: 1,
                newRevision: 2,
                at: accepted.statusUpdatedAt
            )
        )
        let finalProjection = try #require(
            try fixture.store.fetchContextRecord(
                projectID: fixture.projectID,
                id: record.id
            )
        )
        let finalTransitions = try fixture.store.fetchContextTransitions(
            projectID: fixture.projectID,
            aggregateKind: .record,
            aggregateID: record.id
        )
        #expect(finalProjection.status == .accepted)
        #expect(finalProjection.revision == 2)
        #expect(finalTransitions.map(\.newRevision) == [1, 2])
        #expect(finalTransitions.map(\.toState) == ["candidate", "accepted"])
    }

    private func makeFixture() throws -> ContextSQLiteFixture {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "mu-context-sqlite-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let store = try SQLiteStore(
            databaseURL: root.appending(path: "mu.sqlite")
        )
        let fixture = ContextSQLiteFixture(
            root: root,
            store: store,
            projectID: UUID(),
            principalID: UUID(),
            humanActorID: UUID(),
            agentAID: UUID(),
            agentBID: UUID(),
            start: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try provision(
            store: store,
            projectID: fixture.projectID,
            principalID: fixture.principalID,
            humanActorID: fixture.humanActorID,
            agentActorIDs: [fixture.agentAID, fixture.agentBID],
            at: fixture.start
        )
        return fixture
    }

    private func provision(
        store: SQLiteStore,
        projectID: UUID,
        principalID: UUID,
        humanActorID: UUID,
        agentActorIDs: [UUID],
        at date: Date
    ) throws {
        try store.upsertPrincipal(PrincipalRecord(
            id: principalID,
            kind: .person,
            displayName: "Context test owner",
            createdAt: date,
            updatedAt: date
        ))
        try store.upsertProject(ProjectRecord(
            id: projectID,
            displayName: "Context test project",
            ownerPrincipalID: principalID,
            createdAt: date,
            updatedAt: date
        ))
        try store.upsertProjectActor(ProjectActorRecord(
            id: humanActorID,
            principalID: principalID,
            kind: .human,
            displayName: "Human reviewer",
            createdAt: date,
            updatedAt: date
        ))
        try store.upsertProjectMembership(ProjectMembershipRecord(
            projectID: projectID,
            actorID: humanActorID,
            role: .owner,
            createdAt: date,
            updatedAt: date
        ))
        for (index, actorID) in agentActorIDs.enumerated() {
            try store.upsertProjectActor(ProjectActorRecord(
                id: actorID,
                principalID: principalID,
                kind: .agent,
                displayName: "Context Agent \(index + 1)",
                createdAt: date,
                updatedAt: date
            ))
            try store.upsertProjectMembership(ProjectMembershipRecord(
                projectID: projectID,
                actorID: actorID,
                role: .externalAgent,
                createdAt: date,
                updatedAt: date
            ))
            try store.upsertDelegation(DelegationRecord(
                projectID: projectID,
                principalID: principalID,
                delegatedByActorID: humanActorID,
                agentActorID: actorID,
                permissions: [.proposeContext],
                createdAt: date,
                updatedAt: date
            ))
        }
    }

    private func insertSource(
        store: SQLiteStore,
        projectID: UUID,
        humanActorID: UUID,
        principalID: UUID,
        actorID: UUID,
        checksum: String,
        importedAt: Date
    ) throws -> ContextSourceRecord {
        let policyID = UUID()
        let source = try makeSource(
            projectID: projectID,
            actorID: actorID,
            principalID: principalID,
            checksum: checksum,
            accessPolicyID: policyID,
            importedAt: importedAt
        )
        let policy = try ownerOnlyRestrictedPolicy(
            id: policyID,
            projectID: projectID,
            subjectKind: .source,
            subjectID: source.id,
            humanActorID: humanActorID,
            principalID: principalID,
            createdAt: importedAt
        )
        try store.withTransaction {
            try store.insertContextSource(
                source,
                transition: transition(
                    for: source,
                    actorID: actorID,
                    principalID: principalID,
                    kind: .source,
                    transitionKind: .created,
                    from: nil,
                    to: .active,
                    expectedRevision: 0,
                    newRevision: 1,
                    at: source.importedAt
                )
            )
            try store.insertContextAccessPolicy(policy)
        }
        return source
    }

    private func makeSource(
        projectID: UUID,
        actorID: UUID,
        principalID: UUID,
        checksum: String,
        accessPolicyID: UUID,
        importedAt: Date
    ) throws -> ContextSourceRecord {
        ContextSourceRecord(
            projectID: projectID,
            sourceType: .agentExport,
            sourceActorID: actorID,
            sourcePrincipalID: principalID,
            externalRef: "fixture://\(checksum)",
            sourceChecksum: checksum,
            accessPolicyID: accessPolicyID,
            importedAt: importedAt
        )
    }

    private func insertRecord(
        into fixture: ContextSQLiteFixture,
        sourceID: UUID,
        actorID: UUID,
        createdAt: Date
    ) throws -> ContextRecord {
        let policyID = UUID()
        let record = try makeRecord(
            projectID: fixture.projectID,
            sourceID: sourceID,
            actorID: actorID,
            accessPolicyID: policyID,
            createdAt: createdAt
        )
        let policy = try ownerOnlyRestrictedPolicy(
            id: policyID,
            projectID: fixture.projectID,
            subjectKind: .record,
            subjectID: record.id,
            humanActorID: fixture.humanActorID,
            principalID: fixture.principalID,
            createdAt: createdAt
        )
        try fixture.store.withTransaction {
            try fixture.store.insertContextRecord(
                record,
                transition: transition(
                    for: record,
                    actorID: actorID,
                    principalID: fixture.principalID,
                    kind: .record,
                    transitionKind: .created,
                    from: nil,
                    to: .candidate,
                    expectedRevision: 0,
                    newRevision: 1,
                    at: createdAt
                )
            )
            try fixture.store.insertContextAccessPolicy(policy)
        }
        return record
    }

    private func ownerOnlyRestrictedPolicy(
        id: UUID,
        projectID: UUID,
        subjectKind: ContextPolicySubjectKind,
        subjectID: UUID,
        humanActorID: UUID,
        principalID: UUID,
        createdAt: Date
    ) throws -> ContextAccessPolicyRecord {
        try ContextAccessPolicyRecord(
            id: id,
            projectID: projectID,
            subjectKind: subjectKind,
            subjectID: subjectID,
            namespace: "project/owner-only",
            sensitivity: .restricted,
            visibility: .ownerOnly,
            allowedActorIDs: [humanActorID],
            allowedPrincipalIDs: [principalID],
            createdByActorID: humanActorID,
            createdAt: createdAt
        )
    }

    private func makeRecord(
        projectID: UUID,
        sourceID: UUID,
        actorID: UUID,
        accessPolicyID: UUID,
        createdAt: Date
    ) throws -> ContextRecord {
        try ContextRecord(
            projectID: projectID,
            sourceID: sourceID,
            externalID: "record-1",
            kind: .requirement,
            subject: "deployment policy",
            value: .string("A human must approve deployment."),
            sensitivity: .restricted,
            accessPolicyID: accessPolicyID,
            createdByActorID: actorID,
            createdAt: createdAt
        )
    }

    private func insertImportJob(
        _ job: ContextImportJobRecord,
        fixture: ContextSQLiteFixture,
        actorID: UUID
    ) throws {
        try fixture.store.upsertContextImportJob(
            job,
            transition: transition(
                for: job,
                actorID: actorID,
                principalID: fixture.principalID,
                kind: .importJob,
                transitionKind: .created,
                from: nil,
                to: .received,
                expectedRevision: 0,
                newRevision: 1,
                at: job.updatedAt
            )
        )
    }

    private func transition(
        for aggregate: ContextSourceRecord,
        actorID: UUID,
        principalID: UUID,
        kind: ContextTransitionAggregateKind,
        transitionKind: ContextTransitionKind,
        from: ContextSourceState?,
        to: ContextSourceState,
        expectedRevision: Int,
        newRevision: Int,
        at: Date
    ) -> ContextTransitionRecord {
        transition(
            projectID: aggregate.projectID,
            aggregateID: aggregate.id,
            actorID: actorID,
            principalID: principalID,
            kind: kind,
            transitionKind: transitionKind,
            fromState: from?.rawValue,
            toState: to.rawValue,
            expectedRevision: expectedRevision,
            newRevision: newRevision,
            at: at
        )
    }

    private func transition(
        for aggregate: ContextRecord,
        actorID: UUID,
        principalID: UUID,
        kind: ContextTransitionAggregateKind,
        transitionKind: ContextTransitionKind,
        from: ContextRecordStatus?,
        to: ContextRecordStatus,
        expectedRevision: Int,
        newRevision: Int,
        at: Date
    ) -> ContextTransitionRecord {
        transition(
            projectID: aggregate.projectID,
            aggregateID: aggregate.id,
            actorID: actorID,
            principalID: principalID,
            kind: kind,
            transitionKind: transitionKind,
            fromState: from?.rawValue,
            toState: to.rawValue,
            expectedRevision: expectedRevision,
            newRevision: newRevision,
            at: at
        )
    }

    private func transition(
        for aggregate: ContextImportJobRecord,
        actorID: UUID,
        principalID: UUID,
        kind: ContextTransitionAggregateKind,
        transitionKind: ContextTransitionKind,
        from: ContextImportJobStatus?,
        to: ContextImportJobStatus,
        expectedRevision: Int,
        newRevision: Int,
        at: Date
    ) -> ContextTransitionRecord {
        transition(
            projectID: aggregate.projectID,
            aggregateID: aggregate.id,
            actorID: actorID,
            principalID: principalID,
            kind: kind,
            transitionKind: transitionKind,
            fromState: from?.rawValue,
            toState: to.rawValue,
            expectedRevision: expectedRevision,
            newRevision: newRevision,
            at: at
        )
    }

    private func transition(
        projectID: UUID,
        aggregateID: UUID,
        actorID: UUID,
        principalID: UUID,
        kind: ContextTransitionAggregateKind,
        transitionKind: ContextTransitionKind,
        fromState: String?,
        toState: String,
        expectedRevision: Int,
        newRevision: Int,
        at: Date
    ) -> ContextTransitionRecord {
        ContextTransitionRecord(
            projectID: projectID,
            aggregateKind: kind,
            aggregateID: aggregateID,
            transitionKind: transitionKind,
            fromState: fromState,
            toState: toState,
            actorID: actorID,
            principalID: principalID,
            expectedRevision: expectedRevision,
            newRevision: newRevision,
            occurredAt: at
        )
    }
}

private struct ContextSQLiteFixture {
    let root: URL
    let store: SQLiteStore
    let projectID: UUID
    let principalID: UUID
    let humanActorID: UUID
    let agentAID: UUID
    let agentBID: UUID
    let start: Date

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
