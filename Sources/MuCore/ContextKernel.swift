import Foundation

// MARK: - Portable values

/// A provider-neutral JSON value used by the Context Kernel. It deliberately
/// excludes executable objects and preserves deterministic, sorted-key
/// encoding for checksums, conflicts, and immutable Pack receipts.
public enum ProjectContextValue:
    Codable,
    Hashable,
    Sendable
{
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: ProjectContextValue])
    case array([ProjectContextValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(
            [String: ProjectContextValue].self
        ) {
            self = .object(value)
        } else if let value = try? container.decode(
            [ProjectContextValue].self
        ) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported Project Context value."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    public static let canonicalizationVersion = "mu-json-v1"

    /// Versioned, sorted-key JSON used for receipts and immutable
    /// fingerprints. Encoding failure is never converted into a valid value.
    /// Non-finite numbers are rejected before they can enter the Kernel.
    public func canonicalData() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: try canonicalJSONObject(),
            options: [
                .fragmentsAllowed,
                .sortedKeys,
                .withoutEscapingSlashes
            ]
        )
    }

    public func contentSHA256() throws -> String {
        try canonicalData().muSHA256
    }

    public func renderedText() throws -> String {
        switch self {
        case .string(let value):
            return value
        default:
            return String(
                decoding: try canonicalData(),
                as: UTF8.self
            )
        }
    }

    public func containsText(
        _ normalizedNeedle: String
    ) throws -> Bool {
        try renderedText()
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .contains(normalizedNeedle)
    }

    private func canonicalJSONObject() throws -> Any {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            guard value.isFinite else {
                throw ContextKernelValidationError.nonFiniteNumber
            }
            return NSNumber(value: value == 0 ? 0 : value)
        case .bool(let value):
            return NSNumber(value: value)
        case .object(let value):
            return try value.mapValues {
                try $0.canonicalJSONObject()
            }
        case .array(let value):
            return try value.map {
                try $0.canonicalJSONObject()
            }
        case .null:
            return NSNull()
        }
    }
}

public enum ContextKernelValidationError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case nonFiniteNumber
    case invalidConfidence
    case invalidValidityInterval
    case immutableFingerprintMismatch
    case unsupportedCanonicalizationVersion(String)

    public var errorDescription: String? {
        switch self {
        case .nonFiniteNumber:
            "Project Context values cannot contain NaN or infinity."
        case .invalidConfidence:
            "Context confidence must be a finite number from 0 through 1."
        case .invalidValidityInterval:
            "Context validity must use a non-empty [from, until) interval."
        case .immutableFingerprintMismatch:
            "Context immutable fingerprint does not match its payload."
        case .unsupportedCanonicalizationVersion(let version):
            "Unsupported Context canonicalization version: \(version)."
        }
    }
}

// MARK: - Sources and normalized records

public enum ContextSourceType:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case agentExport = "agent_export"
    case runtimeSession = "runtime_session"
    case humanInput = "human_input"
    case artifact
    case repository
    case externalSource = "external_source"
}

public enum ContextSourceState:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case active
    case redacted
    case rejected

    public func allowsTransition(
        to next: ContextSourceState
    ) -> Bool {
        self == .active
            && (next == .redacted || next == .rejected)
    }
}

/// Raw provenance. Large source bytes live in CAS and are referenced by URI;
/// they are never placed directly in a Task Context Pack.
public struct ContextSourceRecord:
    Identifiable,
    Codable,
    Hashable,
    Sendable
{
    public var id: UUID
    public var projectID: UUID
    public var sourceType: ContextSourceType
    public var sourceActorID: UUID
    public var sourcePrincipalID: UUID?
    public var runtimeEndpointID: UUID?
    public var runtimeProvider: ConversationProvider?
    public var runtimeSessionID: String?
    public var externalRef: String?
    public var sourceChecksum: String
    public var checksumAlgorithm: String
    public var sourceSchemaVersion: String?
    public var rawArtifactURI: String?
    public var accessPolicyID: UUID?
    public var originalTimestamp: Date?
    public var importedAt: Date
    public var state: ContextSourceState
    public var revision: Int

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        sourceType: ContextSourceType,
        sourceActorID: UUID,
        sourcePrincipalID: UUID? = nil,
        runtimeEndpointID: UUID? = nil,
        runtimeProvider: ConversationProvider? = nil,
        runtimeSessionID: String? = nil,
        externalRef: String? = nil,
        sourceChecksum: String,
        checksumAlgorithm: String = "sha256",
        sourceSchemaVersion: String? = nil,
        rawArtifactURI: String? = nil,
        accessPolicyID: UUID? = nil,
        originalTimestamp: Date? = nil,
        importedAt: Date = Date(),
        state: ContextSourceState = .active,
        revision: Int = 1
    ) {
        self.id = id
        self.projectID = projectID
        self.sourceType = sourceType
        self.sourceActorID = sourceActorID
        self.sourcePrincipalID = sourcePrincipalID
        self.runtimeEndpointID = runtimeEndpointID
        self.runtimeProvider = runtimeProvider
        self.runtimeSessionID = runtimeSessionID
        self.externalRef = externalRef
        self.sourceChecksum = sourceChecksum
        self.checksumAlgorithm = checksumAlgorithm
        self.sourceSchemaVersion = sourceSchemaVersion
        self.rawArtifactURI = rawArtifactURI
        self.accessPolicyID = accessPolicyID
        self.originalTimestamp = originalTimestamp
        self.importedAt = importedAt
        self.state = state
        self.revision = max(1, revision)
    }
}

public enum ContextRecordKind:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case fact
    case requirement
    case decision
    case constraint
    case assumption
    case finding
    case artifactReference = "artifact_ref"
    case taskState = "task_state"
}

public enum ContextRecordStatus:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case candidate
    case accepted
    case disputed
    case superseded
    case rejected

    public func allowsTransition(
        to next: ContextRecordStatus
    ) -> Bool {
        switch (self, next) {
        case (.candidate, .accepted),
             (.candidate, .rejected),
             (.candidate, .disputed),
             (.accepted, .superseded),
             (.accepted, .disputed),
             (.disputed, .accepted),
             (.disputed, .rejected),
             (.disputed, .superseded):
            true
        default:
            false
        }
    }
}

public enum ContextAuthority:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case rawAgentOutput = "raw_agent_output"
    case agentClaim = "agent_claim"
    case toolVerified = "tool_verified"
    case humanReviewed = "human_reviewed"
    case projectApproved = "project_approved"
    case externalAuthority = "external_authority"

    /// Authority is intentionally not globally ordered. Applicability,
    /// Project approval, source provenance, and conflicts are evaluated as
    /// separate dimensions rather than collapsed into one "truth score".
}

public enum ContextSensitivity:
    String,
    Codable,
    CaseIterable,
    Comparable,
    Sendable
{
    case `public`
    case project
    case restricted
    case secret

    public static func < (
        lhs: ContextSensitivity,
        rhs: ContextSensitivity
    ) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .public: 0
        case .project: 1
        case .restricted: 2
        case .secret: 3
        }
    }
}

public struct ContextScope:
    Codable,
    Hashable,
    Sendable
{
    public var environment: String?
    public var component: String?
    public var taskID: UUID?

    public init(
        environment: String? = nil,
        component: String? = nil,
        taskID: UUID? = nil
    ) {
        self.environment = Self.normalized(environment)
        self.component = Self.normalized(component)
        self.taskID = taskID
    }

    public var stableKey: String {
        [
            environment ?? "*",
            component ?? "*",
            taskID?.uuidString.lowercased() ?? "*"
        ].joined(separator: "\u{1F}")
    }

    public func overlaps(_ other: ContextScope) -> Bool {
        Self.dimensionOverlaps(environment, other.environment)
            && Self.dimensionOverlaps(component, other.component)
            && (taskID == nil || other.taskID == nil
                || taskID == other.taskID)
    }

    private static func dimensionOverlaps(
        _ lhs: String?,
        _ rhs: String?
    ) -> Bool {
        lhs == nil || rhs == nil || lhs == rhs
    }

    private static func normalized(
        _ value: String?
    ) -> String? {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized?.isEmpty == false
            ? normalized
            : nil
    }
}

/// A normalized claim. Payload, source, subject, scope, and checksum are
/// immutable after insert; only controlled lifecycle fields may transition.
public struct ContextRecord:
    Identifiable,
    Codable,
    Hashable,
    Sendable
{
    public var id: UUID
    public var projectID: UUID
    public var sourceID: UUID
    public var externalID: String?
    public var kind: ContextRecordKind
    public var subject: String?
    public var value: ProjectContextValue
    public var contentSHA256: String
    public var immutableFingerprint: String
    public var canonicalizationVersion: String
    public var status: ContextRecordStatus
    public var authority: ContextAuthority
    public var scope: ContextScope
    public var sensitivity: ContextSensitivity
    public var accessPolicyID: UUID?
    public var confidence: Double?
    public var validFrom: Date?
    public var validUntil: Date?
    public var createdByActorID: UUID
    public var createdAt: Date
    public var statusUpdatedAt: Date
    public var statusUpdatedByActorID: UUID?
    public var supersededByRecordID: UUID?
    public var revision: Int

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        sourceID: UUID,
        externalID: String? = nil,
        kind: ContextRecordKind,
        subject: String? = nil,
        value: ProjectContextValue,
        status: ContextRecordStatus = .candidate,
        authority: ContextAuthority = .agentClaim,
        scope: ContextScope = ContextScope(),
        sensitivity: ContextSensitivity = .project,
        accessPolicyID: UUID? = nil,
        confidence: Double? = nil,
        validFrom: Date? = nil,
        validUntil: Date? = nil,
        createdByActorID: UUID,
        createdAt: Date = Date(),
        statusUpdatedAt: Date? = nil,
        statusUpdatedByActorID: UUID? = nil,
        supersededByRecordID: UUID? = nil,
        revision: Int = 1
    ) throws {
        guard confidence == nil
            || (confidence!.isFinite
                && (0...1).contains(confidence!)) else {
            throw ContextKernelValidationError.invalidConfidence
        }
        if let validFrom, let validUntil,
           validFrom >= validUntil {
            throw ContextKernelValidationError.invalidValidityInterval
        }
        let contentSHA256 = try value.contentSHA256()
        let normalizedExternalID = externalID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let normalizedSubject = subject?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty
        self.id = id
        self.projectID = projectID
        self.sourceID = sourceID
        self.externalID = normalizedExternalID
        self.kind = kind
        self.subject = normalizedSubject
        self.value = value
        self.contentSHA256 = contentSHA256
        self.canonicalizationVersion =
            ProjectContextValue.canonicalizationVersion
        self.immutableFingerprint =
            try Self.makeImmutableFingerprint(
                projectID: projectID,
                sourceID: sourceID,
                externalID: normalizedExternalID,
                kind: kind,
                subject: normalizedSubject,
                contentSHA256: contentSHA256,
                scope: scope,
                sensitivity: sensitivity,
                accessPolicyID: accessPolicyID,
                confidence: confidence,
                validFrom: validFrom,
                validUntil: validUntil,
                createdByActorID: createdByActorID,
                createdAt: createdAt
            )
        self.status = status
        self.authority = authority
        self.scope = scope
        self.sensitivity = sensitivity
        self.accessPolicyID = accessPolicyID
        self.confidence = confidence
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.createdByActorID = createdByActorID
        self.createdAt = createdAt
        self.statusUpdatedAt = statusUpdatedAt ?? createdAt
        self.statusUpdatedByActorID = statusUpdatedByActorID
        self.supersededByRecordID = supersededByRecordID
        self.revision = max(1, revision)
    }

    public func validityOverlaps(_ other: ContextRecord) -> Bool {
        let lhsStart = validFrom ?? .distantPast
        let lhsEnd = validUntil ?? .distantFuture
        let rhsStart = other.validFrom ?? .distantPast
        let rhsEnd = other.validUntil ?? .distantFuture
        return lhsStart < rhsEnd && rhsStart < lhsEnd
    }

    public func validateImmutableReceipt() throws {
        guard canonicalizationVersion
            == ProjectContextValue.canonicalizationVersion else {
            throw ContextKernelValidationError
                .unsupportedCanonicalizationVersion(
                    canonicalizationVersion
                )
        }
        let rebuiltContentSHA256 = try value.contentSHA256()
        let rebuiltFingerprint =
            try Self.makeImmutableFingerprint(
                projectID: projectID,
                sourceID: sourceID,
                externalID: externalID,
                kind: kind,
                subject: subject,
                contentSHA256: contentSHA256,
                scope: scope,
                sensitivity: sensitivity,
                accessPolicyID: accessPolicyID,
                confidence: confidence,
                validFrom: validFrom,
                validUntil: validUntil,
                createdByActorID: createdByActorID,
                createdAt: createdAt
            )
        guard contentSHA256 == rebuiltContentSHA256,
              immutableFingerprint == rebuiltFingerprint else {
            throw ContextKernelValidationError
                .immutableFingerprintMismatch
        }
    }

    private static func makeImmutableFingerprint(
        projectID: UUID,
        sourceID: UUID,
        externalID: String?,
        kind: ContextRecordKind,
        subject: String?,
        contentSHA256: String,
        scope: ContextScope,
        sensitivity: ContextSensitivity,
        accessPolicyID: UUID?,
        confidence: Double?,
        validFrom: Date?,
        validUntil: Date?,
        createdByActorID: UUID,
        createdAt: Date
    ) throws -> String {
        let material = ContextRecordFingerprintMaterial(
            schemaVersion: 1,
            canonicalizationVersion:
                ProjectContextValue.canonicalizationVersion,
            projectID: projectID,
            sourceID: sourceID,
            externalID: externalID,
            kind: kind,
            subject: subject,
            contentSHA256: contentSHA256,
            scope: scope,
            sensitivity: sensitivity,
            accessPolicyID: accessPolicyID,
            confidence: confidence,
            validFrom: validFrom,
            validUntil: validUntil,
            createdByActorID: createdByActorID,
            createdAt: createdAt
        )
        return try MuCoding.makeEncoder()
            .encode(material)
            .muSHA256
    }
}

private struct ContextRecordFingerprintMaterial: Encodable {
    var schemaVersion: Int
    var canonicalizationVersion: String
    var projectID: UUID
    var sourceID: UUID
    var externalID: String?
    var kind: ContextRecordKind
    var subject: String?
    var contentSHA256: String
    var scope: ContextScope
    var sensitivity: ContextSensitivity
    var accessPolicyID: UUID?
    var confidence: Double?
    var validFrom: Date?
    var validUntil: Date?
    var createdByActorID: UUID
    var createdAt: Date
}

// MARK: - Relations and conflicts

public enum ContextRelationType:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case supports
    case contradicts
    case supersedes
    case derivedFrom = "derived_from"
    case dependsOn = "depends_on"
    case implements
    case reviews
    case references
}

public struct ContextRelationRecord:
    Identifiable,
    Codable,
    Hashable,
    Sendable
{
    public var id: UUID
    public var projectID: UUID
    public var fromRecordID: UUID
    public var toRecordID: UUID
    public var relationType: ContextRelationType
    public var createdByActorID: UUID
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        fromRecordID: UUID,
        toRecordID: UUID,
        relationType: ContextRelationType,
        createdByActorID: UUID,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.fromRecordID = fromRecordID
        self.toRecordID = toRecordID
        self.relationType = relationType
        self.createdByActorID = createdByActorID
        self.createdAt = createdAt
    }
}

public enum ContextConflictType:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case value
    case version
    case scope
    case temporal
    case interpretation
}

public enum ContextConflictStatus:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case unresolved
    case resolved
    case acceptedMultiple = "accepted_multiple"

    public func allowsTransition(
        to next: ContextConflictStatus
    ) -> Bool {
        self == .unresolved
            && (next == .resolved
                || next == .acceptedMultiple)
    }
}

public struct ContextConflictRecord:
    Identifiable,
    Codable,
    Hashable,
    Sendable
{
    public var id: UUID
    public var projectID: UUID
    public var subject: String
    public var recordIDs: [UUID]
    public var conflictType: ContextConflictType
    public var status: ContextConflictStatus
    public var resolvedByActorID: UUID?
    public var acceptedRecordIDs: [UUID]
    public var resolutionNote: String?
    public var createdAt: Date
    public var resolvedAt: Date?
    public var revision: Int

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        subject: String,
        recordIDs: [UUID],
        conflictType: ContextConflictType = .value,
        status: ContextConflictStatus = .unresolved,
        resolvedByActorID: UUID? = nil,
        acceptedRecordIDs: [UUID] = [],
        resolutionNote: String? = nil,
        createdAt: Date = Date(),
        resolvedAt: Date? = nil,
        revision: Int = 1
    ) {
        self.id = id
        self.projectID = projectID
        self.subject = subject
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self.recordIDs = Array(Set(recordIDs)).sorted {
            $0.uuidString < $1.uuidString
        }
        self.conflictType = conflictType
        self.status = status
        self.resolvedByActorID = resolvedByActorID
        self.acceptedRecordIDs = Array(Set(acceptedRecordIDs)).sorted {
            $0.uuidString < $1.uuidString
        }
        self.resolutionNote = resolutionNote
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
        self.revision = max(1, revision)
    }

    public static func stableID(
        projectID: UUID,
        subject: String,
        recordIDs: [UUID]
    ) -> UUID {
        MuStableIdentity.uuid(
            namespace: "mu.context-conflict",
            components: [
                projectID.uuidString.lowercased(),
                subject.lowercased()
            ] + recordIDs.map {
                $0.uuidString.lowercased()
            }.sorted()
        )
    }
}

// MARK: - Access policy

public enum ContextPolicySubjectKind:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case source
    case record
    case artifact
    case pack
}

public enum ContextVisibility:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case projectMembers = "project_members"
    case taskParticipants = "task_participants"
    case ownerOnly = "owner_only"
    case selectedActors = "selected_actors"
}

public struct ContextAccessPolicyRecord:
    Identifiable,
    Codable,
    Hashable,
    Sendable
{
    public var id: UUID
    public var projectID: UUID
    public var subjectKind: ContextPolicySubjectKind
    public var subjectID: UUID
    public var familyID: UUID
    public var version: Int
    public var supersedesPolicyID: UUID?
    public var namespace: String
    public var sensitivity: ContextSensitivity
    public var visibility: ContextVisibility
    public var allowedActorIDs: [UUID]
    public var allowedPrincipalIDs: [UUID]
    public var allowedTaskIDs: [UUID]
    public var createdByActorID: UUID
    public var createdAt: Date
    public var policySHA256: String

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        subjectKind: ContextPolicySubjectKind,
        subjectID: UUID,
        familyID: UUID? = nil,
        version: Int = 1,
        supersedesPolicyID: UUID? = nil,
        namespace: String = "project/shared",
        sensitivity: ContextSensitivity = .project,
        visibility: ContextVisibility = .projectMembers,
        allowedActorIDs: [UUID] = [],
        allowedPrincipalIDs: [UUID] = [],
        allowedTaskIDs: [UUID] = [],
        createdByActorID: UUID,
        createdAt: Date = Date()
    ) throws {
        let normalizedNamespace = namespace
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedVersion = max(1, version)
        let resolvedFamilyID = familyID
            ?? MuStableIdentity.uuid(
                namespace: "mu.context-policy-family",
                components: [
                    projectID.uuidString.lowercased(),
                    subjectKind.rawValue,
                    subjectID.uuidString.lowercased()
                ]
            )
        let actorIDs = Array(Set(allowedActorIDs)).sorted {
            $0.uuidString < $1.uuidString
        }
        let principalIDs = Array(Set(allowedPrincipalIDs)).sorted {
            $0.uuidString < $1.uuidString
        }
        let taskIDs = Array(Set(allowedTaskIDs)).sorted {
            $0.uuidString < $1.uuidString
        }
        self.id = id
        self.projectID = projectID
        self.subjectKind = subjectKind
        self.subjectID = subjectID
        self.familyID = resolvedFamilyID
        self.version = normalizedVersion
        self.supersedesPolicyID = supersedesPolicyID
        self.namespace = normalizedNamespace
        self.sensitivity = sensitivity
        self.visibility = visibility
        self.allowedActorIDs = actorIDs
        self.allowedPrincipalIDs = principalIDs
        self.allowedTaskIDs = taskIDs
        self.createdByActorID = createdByActorID
        self.createdAt = createdAt
        self.policySHA256 = try MuCoding.makeEncoder().encode(
            ContextPolicyFingerprintMaterial(
                schemaVersion: 1,
                projectID: projectID,
                subjectKind: subjectKind,
                subjectID: subjectID,
                familyID: resolvedFamilyID,
                version: normalizedVersion,
                supersedesPolicyID: supersedesPolicyID,
                namespace: normalizedNamespace,
                sensitivity: sensitivity,
                visibility: visibility,
                allowedActorIDs: actorIDs,
                allowedPrincipalIDs: principalIDs,
                allowedTaskIDs: taskIDs,
                createdByActorID: createdByActorID,
                createdAt: createdAt
            )
        ).muSHA256
    }

    public func validateImmutableReceipt() throws {
        let rebuilt = try ContextAccessPolicyRecord(
            id: id,
            projectID: projectID,
            subjectKind: subjectKind,
            subjectID: subjectID,
            familyID: familyID,
            version: version,
            supersedesPolicyID: supersedesPolicyID,
            namespace: namespace,
            sensitivity: sensitivity,
            visibility: visibility,
            allowedActorIDs: allowedActorIDs,
            allowedPrincipalIDs: allowedPrincipalIDs,
            allowedTaskIDs: allowedTaskIDs,
            createdByActorID: createdByActorID,
            createdAt: createdAt
        )
        guard rebuilt.policySHA256 == policySHA256 else {
            throw ContextKernelValidationError
                .immutableFingerprintMismatch
        }
    }
}

private struct ContextPolicyFingerprintMaterial: Encodable {
    var schemaVersion: Int
    var projectID: UUID
    var subjectKind: ContextPolicySubjectKind
    var subjectID: UUID
    var familyID: UUID
    var version: Int
    var supersedesPolicyID: UUID?
    var namespace: String
    var sensitivity: ContextSensitivity
    var visibility: ContextVisibility
    var allowedActorIDs: [UUID]
    var allowedPrincipalIDs: [UUID]
    var allowedTaskIDs: [UUID]
    var createdByActorID: UUID
    var createdAt: Date
}

// MARK: - Imports

public enum ContextImportJobStatus:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case received
    case validating
    case importing
    case completed
    case failed
    case rejected

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .rejected:
            true
        default:
            false
        }
    }

    public func allowsTransition(
        to next: ContextImportJobStatus
    ) -> Bool {
        switch (self, next) {
        case (.received, .validating),
             (.received, .rejected),
             (.received, .failed),
             (.validating, .importing),
             (.validating, .rejected),
             (.validating, .failed),
             (.importing, .completed),
             (.importing, .failed):
            true
        default:
            false
        }
    }
}

public struct ContextImportIssue:
    Codable,
    Hashable,
    Sendable
{
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct ContextImportJobRecord:
    Identifiable,
    Codable,
    Hashable,
    Sendable
{
    public var id: UUID
    public var projectID: UUID
    public var sourceActorID: UUID
    public var sourcePrincipalID: UUID?
    public var runtimeProvider: ConversationProvider?
    public var runtimeSessionID: String?
    public var externalBundleID: String?
    public var bundleChecksum: String
    public var idempotencyKey: String
    public var status: ContextImportJobStatus
    public var progress: Double
    public var sourceID: UUID?
    public var recordIDs: [UUID]
    public var issues: [ContextImportIssue]
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var revision: Int

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        sourceActorID: UUID,
        sourcePrincipalID: UUID? = nil,
        runtimeProvider: ConversationProvider? = nil,
        runtimeSessionID: String? = nil,
        externalBundleID: String? = nil,
        bundleChecksum: String,
        idempotencyKey: String,
        status: ContextImportJobStatus = .received,
        progress: Double = 0,
        sourceID: UUID? = nil,
        recordIDs: [UUID] = [],
        issues: [ContextImportIssue] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil,
        revision: Int = 1
    ) {
        self.id = id
        self.projectID = projectID
        self.sourceActorID = sourceActorID
        self.sourcePrincipalID = sourcePrincipalID
        self.runtimeProvider = runtimeProvider
        self.runtimeSessionID = runtimeSessionID
        self.externalBundleID = externalBundleID
        self.bundleChecksum = bundleChecksum
        self.idempotencyKey = idempotencyKey
        self.status = status
        self.progress = min(1, max(0, progress))
        self.sourceID = sourceID
        self.recordIDs = recordIDs
        self.issues = issues
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.revision = max(1, revision)
    }
}

public struct AgentContextBundle:
    Codable,
    Hashable,
    Sendable
{
    public var schemaVersion: String
    public var bundleID: String?
    public var agentID: String
    public var ownerPrincipalID: String?
    public var sourceProjectID: String?
    public var runtimeProvider: ConversationProvider?
    public var runtimeSessionID: String?
    public var exportedAt: Date
    public var records: [AgentContextBundleRecord]
    public var artifacts: [AgentContextBundleArtifact]
    public var accessPolicy: AgentContextBundleAccessPolicy?
    public var retentionPolicy: AgentContextBundleRetentionPolicy?

    public init(
        schemaVersion: String = "1",
        bundleID: String? = nil,
        agentID: String,
        ownerPrincipalID: String? = nil,
        sourceProjectID: String? = nil,
        runtimeProvider: ConversationProvider? = nil,
        runtimeSessionID: String? = nil,
        exportedAt: Date = Date(),
        records: [AgentContextBundleRecord],
        artifacts: [AgentContextBundleArtifact] = [],
        accessPolicy: AgentContextBundleAccessPolicy? = nil,
        retentionPolicy: AgentContextBundleRetentionPolicy? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.bundleID = bundleID
        self.agentID = agentID
        self.ownerPrincipalID = ownerPrincipalID
        self.sourceProjectID = sourceProjectID
        self.runtimeProvider = runtimeProvider
        self.runtimeSessionID = runtimeSessionID
        self.exportedAt = exportedAt
        self.records = records
        self.artifacts = artifacts
        self.accessPolicy = accessPolicy
        self.retentionPolicy = retentionPolicy
    }
}

public struct AgentContextBundleRecord:
    Codable,
    Hashable,
    Sendable
{
    public var externalID: String?
    public var kind: ContextRecordKind
    public var subject: String?
    public var value: ProjectContextValue
    public var confidence: Double?
    public var validFrom: Date?
    public var validUntil: Date?
    public var scope: ContextScope?
    public var sensitivity: ContextSensitivity?

    public init(
        externalID: String? = nil,
        kind: ContextRecordKind,
        subject: String? = nil,
        value: ProjectContextValue,
        confidence: Double? = nil,
        validFrom: Date? = nil,
        validUntil: Date? = nil,
        scope: ContextScope? = nil,
        sensitivity: ContextSensitivity? = nil
    ) {
        self.externalID = externalID
        self.kind = kind
        self.subject = subject
        self.value = value
        self.confidence = confidence
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.scope = scope
        self.sensitivity = sensitivity
    }
}

public struct AgentContextBundleArtifact:
    Codable,
    Hashable,
    Sendable
{
    public var artifactID: String?
    public var name: String
    public var contentType: String
    public var uri: String?

    public init(
        artifactID: String? = nil,
        name: String,
        contentType: String,
        uri: String? = nil
    ) {
        self.artifactID = artifactID
        self.name = name
        self.contentType = contentType
        self.uri = uri
    }
}

public struct AgentContextBundleAccessPolicy:
    Codable,
    Hashable,
    Sendable
{
    public var namespace: String
    public var visibility: ContextVisibility
    public var sensitivity: ContextSensitivity
    public var allowedActorIDs: [UUID]
    public var allowedPrincipalIDs: [UUID]
    public var allowedTaskIDs: [UUID]

    public init(
        namespace: String = "project/shared",
        visibility: ContextVisibility = .projectMembers,
        sensitivity: ContextSensitivity = .project,
        allowedActorIDs: [UUID] = [],
        allowedPrincipalIDs: [UUID] = [],
        allowedTaskIDs: [UUID] = []
    ) {
        self.namespace = namespace
        self.visibility = visibility
        self.sensitivity = sensitivity
        self.allowedActorIDs = allowedActorIDs
        self.allowedPrincipalIDs = allowedPrincipalIDs
        self.allowedTaskIDs = allowedTaskIDs
    }
}

public struct AgentContextBundleRetentionPolicy:
    Codable,
    Hashable,
    Sendable
{
    public var retainUntil: Date?
    public var deleteRawAfterImport: Bool

    public init(
        retainUntil: Date? = nil,
        deleteRawAfterImport: Bool = false
    ) {
        self.retainUntil = retainUntil
        self.deleteRawAfterImport = deleteRawAfterImport
    }
}

// MARK: - Append-only lifecycle receipts

public enum ContextTransitionAggregateKind:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case source
    case record
    case conflict
    case importJob = "import_job"
}

public enum ContextTransitionKind:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case created
    case stateChanged = "state_changed"
    case superseded
    case resolved
    case failed
}

/// Immutable audit receipt. The aggregate row is only a CAS-protected current
/// projection and can be rebuilt by replaying these transitions.
public struct ContextTransitionRecord:
    Identifiable,
    Codable,
    Hashable,
    Sendable
{
    public var id: UUID
    public var projectID: UUID
    public var aggregateKind: ContextTransitionAggregateKind
    public var aggregateID: UUID
    public var transitionKind: ContextTransitionKind
    public var fromState: String?
    public var toState: String
    public var actorID: UUID
    public var principalID: UUID
    public var approvalID: UUID?
    public var reviewID: UUID?
    public var reason: String?
    public var expectedRevision: Int
    public var newRevision: Int
    public var occurredAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        aggregateKind: ContextTransitionAggregateKind,
        aggregateID: UUID,
        transitionKind: ContextTransitionKind,
        fromState: String?,
        toState: String,
        actorID: UUID,
        principalID: UUID,
        approvalID: UUID? = nil,
        reviewID: UUID? = nil,
        reason: String? = nil,
        expectedRevision: Int,
        newRevision: Int,
        occurredAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.aggregateKind = aggregateKind
        self.aggregateID = aggregateID
        self.transitionKind = transitionKind
        self.fromState = fromState
        self.toState = toState
        self.actorID = actorID
        self.principalID = principalID
        self.approvalID = approvalID
        self.reviewID = reviewID
        self.reason = reason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        self.expectedRevision = max(0, expectedRevision)
        self.newRevision = max(1, newRevision)
        self.occurredAt = occurredAt
    }
}

/// One immutable receipt per external turn delivery. A Runtime binding may
/// point at the latest Pack, but historical reconstruction uses this receipt.
public enum ContextDeliveryStatus:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case prepared
    case delivered
    case failed
}

public struct ContextDeliveryReceipt:
    Identifiable,
    Codable,
    Hashable,
    Sendable
{
    public var id: UUID
    public var projectID: UUID
    public var taskID: UUID
    public var contextPackID: UUID
    public var runtimeBindingID: UUID
    public var runID: UUID
    public var endpointID: UUID
    public var actorID: UUID
    public var principalID: UUID
    public var workspaceID: UUID
    public var taskLeaseID: UUID?
    public var leaseFencingToken: Int64?
    public var contextRevision: String
    public var policyRevision: String
    public var packContentSHA256: String
    public var status: ContextDeliveryStatus
    public var adapterReceiptSHA256: String?
    public var failureCode: String?
    public var preparedAt: Date
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        taskID: UUID,
        contextPackID: UUID,
        runtimeBindingID: UUID,
        runID: UUID,
        endpointID: UUID,
        actorID: UUID,
        principalID: UUID,
        workspaceID: UUID,
        taskLeaseID: UUID? = nil,
        leaseFencingToken: Int64? = nil,
        contextRevision: String,
        policyRevision: String,
        packContentSHA256: String,
        status: ContextDeliveryStatus,
        adapterReceiptSHA256: String? = nil,
        failureCode: String? = nil,
        preparedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.taskID = taskID
        self.contextPackID = contextPackID
        self.runtimeBindingID = runtimeBindingID
        self.runID = runID
        self.endpointID = endpointID
        self.actorID = actorID
        self.principalID = principalID
        self.workspaceID = workspaceID
        self.taskLeaseID = taskLeaseID
        self.leaseFencingToken = leaseFencingToken
        self.contextRevision = contextRevision
        self.policyRevision = policyRevision
        self.packContentSHA256 = packContentSHA256
        self.status = status
        self.adapterReceiptSHA256 = adapterReceiptSHA256
        self.failureCode = failureCode
        self.preparedAt = preparedAt
        self.completedAt = completedAt
    }
}

// MARK: - Immutable Pack items and retrieval

public enum ContextPackItemKind:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case record
    case artifact
    case conflict
    case projectFact = "project_fact"
}

public struct ContextPolicyReceipt:
    Codable,
    Hashable,
    Sendable
{
    public var policyID: UUID
    public var subjectKind: ContextPolicySubjectKind
    public var subjectID: UUID
    public var version: Int
    public var policySHA256: String
    public var sensitivity: ContextSensitivity

    public init(policy: ContextAccessPolicyRecord) {
        self.policyID = policy.id
        self.subjectKind = policy.subjectKind
        self.subjectID = policy.subjectID
        self.version = policy.version
        self.policySHA256 = policy.policySHA256
        self.sensitivity = policy.sensitivity
    }
}

public struct ContextPackItemRecord:
    Identifiable,
    Codable,
    Hashable,
    Sendable
{
    public var id: UUID
    public var projectID: UUID
    public var packID: UUID
    public var itemKind: ContextPackItemKind
    public var referencedID: UUID
    public var sourceID: UUID?
    public var inclusionReason: String
    public var ordinal: Int
    public var renderedSHA256: String
    public var referencedVersion: Int?
    public var referencedSHA256: String
    public var referencedURI: String?
    public var policyReceipts: [ContextPolicyReceipt]

    public init(
        id: UUID? = nil,
        projectID: UUID,
        packID: UUID,
        itemKind: ContextPackItemKind,
        referencedID: UUID,
        sourceID: UUID? = nil,
        inclusionReason: String,
        ordinal: Int,
        renderedSHA256: String,
        referencedVersion: Int? = nil,
        referencedSHA256: String,
        referencedURI: String? = nil,
        policyReceipts: [ContextPolicyReceipt]
    ) {
        self.id = id ?? MuStableIdentity.uuid(
            namespace: "mu.context-pack-item",
            components: [
                packID.uuidString.lowercased(),
                String(ordinal),
                itemKind.rawValue,
                referencedID.uuidString.lowercased()
            ]
        )
        self.projectID = projectID
        self.packID = packID
        self.itemKind = itemKind
        self.referencedID = referencedID
        self.sourceID = sourceID
        self.inclusionReason = inclusionReason
        self.ordinal = ordinal
        self.renderedSHA256 = renderedSHA256
        self.referencedVersion = referencedVersion
        self.referencedSHA256 = referencedSHA256
        self.referencedURI = referencedURI
        self.policyReceipts = Array(Set(policyReceipts)).sorted {
            if $0.subjectKind.rawValue
                != $1.subjectKind.rawValue {
                return $0.subjectKind.rawValue
                    < $1.subjectKind.rawValue
            }
            if $0.subjectID != $1.subjectID {
                return $0.subjectID.uuidString
                    < $1.subjectID.uuidString
            }
            return $0.version < $1.version
        }
    }
}

public struct ContextSearchResult:
    Codable,
    Hashable,
    Sendable
{
    public var record: ContextRecord
    public var source: ContextSourceRecord
    public var matchReason: String
}

/// Metadata-only projections used to authorize a lookup before SQLite reads
/// any Context payload, subject, summary, or searchable text.
public struct ContextSourceAccessHeader:
    Hashable,
    Sendable
{
    public var id: UUID
    public var projectID: UUID
    public var sourceActorID: UUID
    public var sourcePrincipalID: UUID?
    public var accessPolicyID: UUID
    public var state: ContextSourceState
}

public struct ContextRecordAccessHeader:
    Hashable,
    Sendable
{
    public var id: UUID
    public var projectID: UUID
    public var sourceID: UUID
    public var accessPolicyID: UUID
    public var status: ContextRecordStatus
    public var scopeTaskID: UUID?
    public var sensitivity: ContextSensitivity
}

public struct ContextImportResult:
    Codable,
    Hashable,
    Sendable
{
    public var job: ContextImportJobRecord
    public var source: ContextSourceRecord
    public var records: [ContextRecord]
    public var conflicts: [ContextConflictRecord]
    public var wasIdempotentReplay: Bool
}

// MARK: - Secret and private-reasoning validation

public enum ContextBundleSafety {
    public static let forbiddenFieldNames: Set<String> = [
        "hidden_chain_of_thought",
        "chain_of_thought",
        "raw_model_reasoning",
        "private_reasoning",
        "api_key",
        "apikey",
        "access_token",
        "refresh_token",
        "password",
        "credential",
        "credentials",
        "private_key"
    ]

    public static func issues(in rawData: Data) -> [ContextImportIssue] {
        guard let value = try? JSONSerialization.jsonObject(
            with: rawData
        ) else {
            return [
                ContextImportIssue(
                    code: "invalid_json",
                    message: "The Context Bundle is not valid JSON."
                )
            ]
        }
        var issues: [ContextImportIssue] = []
        inspect(value, path: "$", issues: &issues)
        return issues
    }

    public static func issues(
        in value: ProjectContextValue
    ) -> [ContextImportIssue] {
        var issues: [ContextImportIssue] = []
        inspectContextValue(value, path: "$", issues: &issues)
        return issues
    }

    private static func inspect(
        _ value: Any,
        path: String,
        issues: inout [ContextImportIssue]
    ) {
        if let object = value as? [String: Any] {
            for (key, nested) in object {
                let normalizedKey = key
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    .lowercased()
                if forbiddenFieldNames.contains(normalizedKey) {
                    issues.append(
                        ContextImportIssue(
                            code: "forbidden_field",
                            message:
                                "Forbidden private or secret field at "
                                + "\(path).\(key)."
                        )
                    )
                }
                inspect(
                    nested,
                    path: "\(path).\(key)",
                    issues: &issues
                )
            }
        } else if let array = value as? [Any] {
            for (index, nested) in array.enumerated() {
                inspect(
                    nested,
                    path: "\(path)[\(index)]",
                    issues: &issues
                )
            }
        } else if let text = value as? String,
                  looksLikeSecret(text) {
            issues.append(
                ContextImportIssue(
                    code: "secret_material",
                    message:
                        "Potential credential or private key at \(path)."
                )
            )
        }
    }

    private static func inspectContextValue(
        _ value: ProjectContextValue,
        path: String,
        issues: inout [ContextImportIssue]
    ) {
        switch value {
        case .object(let object):
            for (key, nested) in object {
                let normalizedKey = key.lowercased()
                if forbiddenFieldNames.contains(normalizedKey) {
                    issues.append(
                        ContextImportIssue(
                            code: "forbidden_field",
                            message:
                                "Forbidden private or secret field at "
                                + "\(path).\(key)."
                        )
                    )
                }
                inspectContextValue(
                    nested,
                    path: "\(path).\(key)",
                    issues: &issues
                )
            }
        case .array(let values):
            for (index, nested) in values.enumerated() {
                inspectContextValue(
                    nested,
                    path: "\(path)[\(index)]",
                    issues: &issues
                )
            }
        case .string(let value):
            if looksLikeSecret(value) {
                issues.append(
                    ContextImportIssue(
                        code: "secret_material",
                        message:
                            "Potential credential or private key at \(path)."
                    )
                )
            }
        default:
            break
        }
    }

    private static func looksLikeSecret(_ rawValue: String) -> Bool {
        let value = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let upper = value.uppercased()
        if upper.contains("-----BEGIN ")
            && upper.contains("PRIVATE KEY-----") {
            return true
        }
        let prefixes = [
            "sk-",
            "ghp_",
            "github_pat_",
            "xoxb-",
            "xoxp-",
            "AKIA",
            "AIza"
        ]
        return prefixes.contains { prefix in
            guard let range = value.range(of: prefix) else {
                return false
            }
            return value[range.lowerBound...].count >= 20
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
