import Foundation
@testable import MuCore
import Testing

@Suite(.serialized)
struct ContextKernelTests {
    @Test
    func projectContextValueUsesCanonicalEncodingHashingAndSearchText()
        throws
    {
        let first: ProjectContextValue = .object([
            "zeta": .object(["b": .number(2), "a": .string("first")]),
            "alpha": .array([.bool(true), .null])
        ])
        let reordered: ProjectContextValue = .object([
            "alpha": .array([.bool(true), .null]),
            "zeta": .object(["a": .string("first"), "b": .number(2)])
        ])

        #expect(first == reordered)
        #expect(Set([first, reordered]).count == 1)
        #expect(try first.canonicalData() == reordered.canonicalData())
        #expect(
            try first.contentSHA256()
                == reordered.contentSHA256()
        )
        #expect(
            try first.contentSHA256()
                == first.canonicalData().muSHA256
        )

        let text = ProjectContextValue.string("Caf\u{00E9} deployment notes")
        #expect(try text.renderedText() == "Caf\u{00E9} deployment notes")
        #expect(try text.containsText("cafe"))
        #expect(try first.renderedText().contains("\"alpha\""))
        #expect(try first.containsText("first"))
        #expect(try !first.containsText("missing"))
        #expect(
            ProjectContextValue.canonicalizationVersion
                == "mu-json-v1"
        )
    }

    @Test
    func contextScopeNormalizesAndOverlapsByWildcardDimension() {
        let taskID = uuid("11111111-1111-1111-1111-111111111111")
        let scope = ContextScope(
            environment: "  Production ",
            component: " API ",
            taskID: taskID
        )

        #expect(scope.environment == "production")
        #expect(scope.component == "api")
        #expect(scope.stableKey == "production\u{1F}api\u{1F}\(taskID.uuidString.lowercased())")
        #expect(scope.overlaps(ContextScope(environment: "production")))
        #expect(scope.overlaps(ContextScope(component: "api", taskID: taskID)))
        #expect(!scope.overlaps(ContextScope(environment: "staging")))
        #expect(!scope.overlaps(ContextScope(component: "worker")))
        #expect(!scope.overlaps(ContextScope(taskID: UUID())))
        #expect(ContextScope(environment: "   ", component: "\n").stableKey == "*\u{1F}*\u{1F}*")
    }

    @Test
    func contextRecordInitializesLifecycleReceiptAndValidityHelpers()
        throws
    {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let value = ProjectContextValue.object(["enabled": .bool(true)])
        let record = try makeRecord(
            externalID: "  imported-42  ",
            subject: "  Deployment Policy ",
            value: value,
            confidence: 0.75,
            createdAt: createdAt
        )

        #expect(record.status == .candidate)
        #expect(record.statusUpdatedAt == createdAt)
        #expect(record.statusUpdatedByActorID == nil)
        #expect(record.supersededByRecordID == nil)
        #expect(record.externalID == "imported-42")
        #expect(record.subject == "deployment policy")
        #expect(record.confidence == 0.75)
        #expect(record.contentSHA256 == (try value.contentSHA256()))
        #expect(record.revision == 1)
        #expect(
            record.canonicalizationVersion
                == ProjectContextValue.canonicalizationVersion
        )
        try record.validateImmutableReceipt()

        let bounded = try makeRecord(
            validFrom: createdAt,
            validUntil: createdAt.addingTimeInterval(60)
        )
        let adjacent = try makeRecord(
            validFrom: createdAt.addingTimeInterval(60),
            validUntil: createdAt.addingTimeInterval(120)
        )
        let endingAtBoundary = try makeRecord(
            validFrom: createdAt.addingTimeInterval(-60),
            validUntil: createdAt
        )
        let expired = try makeRecord(
            validFrom: createdAt.addingTimeInterval(-120),
            validUntil: createdAt.addingTimeInterval(-1)
        )
        let openEnded = try makeRecord(
            validFrom: createdAt.addingTimeInterval(3600)
        )

        #expect(!bounded.validityOverlaps(adjacent))
        #expect(!bounded.validityOverlaps(endingAtBoundary))
        #expect(!bounded.validityOverlaps(expired))
        #expect(record.validityOverlaps(openEnded))
    }

    @Test
    func contextRecordRejectsInvalidNumbersAndIntervals() {
        #expect(throws: ContextKernelValidationError.invalidConfidence) {
            try makeRecord(confidence: 4)
        }
        #expect(throws: ContextKernelValidationError.invalidConfidence) {
            try makeRecord(confidence: .nan)
        }
        let boundary = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(
            throws:
                ContextKernelValidationError.invalidValidityInterval
        ) {
            try makeRecord(
                validFrom: boundary,
                validUntil: boundary
            )
        }
        #expect(throws: ContextKernelValidationError.nonFiniteNumber) {
            try ProjectContextValue.number(.infinity)
                .canonicalData()
        }
    }

    @Test
    func contextRecordFingerprintCoversFullImmutableMeaning()
        throws
    {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let value = ProjectContextValue.string("same value")
        let first = try makeRecord(
            subject: "deployment",
            value: value,
            createdAt: createdAt
        )
        let same = try makeRecord(
            subject: " Deployment ",
            value: value,
            createdAt: createdAt
        )
        let differentSubject = try makeRecord(
            subject: "runtime",
            value: value,
            createdAt: createdAt
        )
        let differentScope = try ContextRecord(
            projectID: first.projectID,
            sourceID: first.sourceID,
            kind: first.kind,
            subject: first.subject,
            value: value,
            scope: ContextScope(environment: "production"),
            createdByActorID: first.createdByActorID,
            createdAt: createdAt
        )

        #expect(first.immutableFingerprint == same.immutableFingerprint)
        #expect(
            first.immutableFingerprint
                != differentSubject.immutableFingerprint
        )
        #expect(
            first.immutableFingerprint
                != differentScope.immutableFingerprint
        )
    }

    @Test
    func contextConflictStableIDIgnoresRecordOrderAndSubjectCasing() {
        let projectID = uuid("22222222-2222-2222-2222-222222222222")
        let first = uuid("33333333-3333-3333-3333-333333333333")
        let second = uuid("44444444-4444-4444-4444-444444444444")

        let stable = ContextConflictRecord.stableID(
            projectID: projectID,
            subject: "Deployment Policy",
            recordIDs: [first, second]
        )
        #expect(stable == ContextConflictRecord.stableID(
            projectID: projectID,
            subject: "deployment policy",
            recordIDs: [second, first]
        ))
        #expect(stable != ContextConflictRecord.stableID(
            projectID: projectID,
            subject: "runtime policy",
            recordIDs: [first, second]
        ))

        let conflict = ContextConflictRecord(
            projectID: projectID,
            subject: "  DEPLOYMENT POLICY ",
            recordIDs: [second, first, first],
            acceptedRecordIDs: [second, first, second]
        )
        #expect(conflict.subject == "deployment policy")
        #expect(conflict.recordIDs == [first, second])
        #expect(conflict.acceptedRecordIDs == [first, second])
    }

    @Test
    func contextBundleSafetyRejectsPrivateReasoningFieldsInRawJSON() {
        let raw = Data(
            #"{"records":[{"  Chain_Of_Thought ":"private trace"}],"nested":{"private_reasoning":"hidden"}}"#.utf8
        )

        let issues = ContextBundleSafety.issues(in: raw)

        #expect(issues.filter { $0.code == "forbidden_field" }.count == 2)
        #expect(issues.contains { $0.message.contains("$.records[0].  Chain_Of_Thought ") })
        #expect(issues.contains { $0.message.contains("$.nested.private_reasoning") })
    }

    @Test
    func contextBundleSafetyRejectsCommonCredentialMaterialInRawJSON() {
        let raw = Data(
            #"{"values":["sk-12345678901234567890","ghp_12345678901234567890","github_pat_12345678901234567890","xoxb-12345678901234567890","xoxp-12345678901234567890","AKIA1234567890123456","AIza12345678901234567890","-----BEGIN PRIVATE KEY-----\nmaterial"]}"#.utf8
        )

        let issues = ContextBundleSafety.issues(in: raw)

        #expect(issues.filter { $0.code == "secret_material" }.count == 8)
        #expect(issues.allSatisfy { $0.message.contains("$.values[") })
    }

    @Test
    func contextBundleSafetyAllowsOrdinaryRawJSONAndReportsInvalidJSON() {
        let ordinary = Data(
            #"{"summary":"Deploy the public API after review.","metadata":{"attempt":2,"approved":true},"items":["README.md",null]}"#.utf8
        )

        #expect(ContextBundleSafety.issues(in: ordinary).isEmpty)
        #expect(ContextBundleSafety.issues(in: Data("not json".utf8)).map(\.code) == ["invalid_json"])
    }

    private func makeRecord(
        externalID: String? = nil,
        subject: String? = nil,
        value: ProjectContextValue = .string("Current deployment state"),
        confidence: Double? = nil,
        validFrom: Date? = nil,
        validUntil: Date? = nil,
        createdAt: Date = Date()
    ) throws -> ContextRecord {
        try ContextRecord(
            projectID: uuid("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
            sourceID: uuid("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"),
            externalID: externalID,
            kind: .requirement,
            subject: subject,
            value: value,
            confidence: confidence,
            validFrom: validFrom,
            validUntil: validUntil,
            createdByActorID: uuid("cccccccc-cccc-cccc-cccc-cccccccccccc"),
            createdAt: createdAt
        )
    }

    private func uuid(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }
}
