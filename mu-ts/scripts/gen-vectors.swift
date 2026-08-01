// Generates byte-parity test vectors from the exact MuCore pure functions.
// Run: swift gen-vectors.swift
// Output: JSON lines with (name, value) pairs for the TypeScript tests.

import Foundation
import CryptoKit

// --- Copied verbatim from MuCore/Artifacts.swift ---
extension Data {
    var muSHA256: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}

// --- Copied verbatim from MuCore/Models.swift (MuCoding) ---
enum MuCoding {
    static func makeEncoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}


func enc(_ value: some Encodable) -> Data {
    try! MuCoding.makeEncoder().encode(value)
}

func encSer(_ value: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
}

// --- Copied verbatim from MuCore/ProjectKernel.swift (MuStableIdentity) ---
enum MuStableIdentity {
    static func uuid(namespace: String, components: [String]) -> String {
        let material = ([namespace] + components).joined(separator: "\u{1F}")
        var hex = String(Data(material.utf8).muSHA256.prefix(32))
        let versionIndex = hex.index(hex.startIndex, offsetBy: 12)
        hex.replaceSubrange(versionIndex...versionIndex, with: "5")
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
        return value
    }
}

// --- Copied verbatim from MuCore/ContextKernel.swift (ProjectContextValue) ---
enum ProjectContextValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: ProjectContextValue])
    case array([ProjectContextValue])
    case null

    static let canonicalizationVersion = "mu-json-v1"

    func canonicalData() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: try canonicalJSONObject(),
            options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    func contentSHA256() throws -> String {
        try canonicalData().muSHA256
    }

    private func canonicalJSONObject() throws -> Any {
        switch self {
        case .string(let value): return value
        case .number(let value):
            guard value.isFinite else { throw NSError(domain: "test", code: 1) }
            return NSNumber(value: value == 0 ? 0 : value)
        case .bool(let value): return NSNumber(value: value)
        case .object(let value):
            return try value.mapValues { try $0.canonicalJSONObject() }
        case .array(let value):
            return try value.map { try $0.canonicalJSONObject() }
        case .null: return NSNull()
        }
    }
}

// --- Fingerprint materials (copied verbatim) ---
enum ContextRecordKind: String, Codable {
    case fact, requirement, decision, constraint, assumption, finding
    case artifactReference = "artifact_ref"
    case taskState = "task_state"
}

enum ContextSensitivity: String, Codable {
    case `public`, project, restricted, secret
}

struct ContextScope: Codable {
    var environment: String?
    var component: String?
    var taskID: String?
}

struct ContextRecordFingerprintMaterial: Encodable {
    var schemaVersion: Int
    var canonicalizationVersion: String
    var projectID: String
    var sourceID: String
    var externalID: String?
    var kind: ContextRecordKind
    var subject: String?
    var contentSHA256: String
    var scope: ContextScope
    var sensitivity: ContextSensitivity
    var accessPolicyID: String?
    var confidence: Double?
    var validFrom: Date?
    var validUntil: Date?
    var createdByActorID: String
    var createdAt: Date
}

enum ContextPolicySubjectKind: String, Codable {
    case source, record, artifact, pack
}

enum ContextVisibility: String, Codable {
    case projectMembers = "project_members"
    case taskParticipants = "task_participants"
    case ownerOnly = "owner_only"
    case selectedActors = "selected_actors"
}

struct ContextPolicyFingerprintMaterial: Encodable {
    var schemaVersion: Int
    var projectID: String
    var subjectKind: ContextPolicySubjectKind
    var subjectID: String
    var familyID: String
    var version: Int
    var supersedesPolicyID: String?
    var namespace: String
    var sensitivity: ContextSensitivity
    var visibility: ContextVisibility
    var allowedActorIDs: [String]
    var allowedPrincipalIDs: [String]
    var allowedTaskIDs: [String]
    var createdByActorID: String
    var createdAt: Date
}

func emit(_ name: String, _ value: String) {
    let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    print("\(name)\t\(escaped)")
}

// --- Vectors ---
let fixedDate = Date(timeIntervalSince1970: 1_752_433_665)  // 2025-07-13T12:47:45Z
let fixedDate2 = Date(timeIntervalSince1970: 1_752_433_665.123)

// 1. ISO8601 date encoding via MuCoding (JSONEncoder .iso8601)
let datePayload = enc(["date": fixedDate]).muSHA256
emit("date_sha256", datePayload)
emit("date_json", String(decoding: enc(["date": fixedDate]), as: UTF8.self))
let msDatePayload = enc(["date": fixedDate2]).muSHA256
emit("date_ms_sha256", msDatePayload)
emit("date_ms_json", String(decoding: enc(["date": fixedDate2]), as: UTF8.self))

// 2. MuStableIdentity vectors
emit("stable_project", MuStableIdentity.uuid(
    namespace: "mu.project.repository",
    components: ["/Users/test/project"]
))
emit("stable_actor_runtime", MuStableIdentity.uuid(
    namespace: "mu.actor.runtime",
    components: ["d9f4d3f2-1a2b-4c3d-8e5f-60718293a4b5"]
))
emit("stable_conflict", MuStableIdentity.uuid(
    namespace: "mu.context-conflict",
    components: [
        "a1b2c3d4-e5f6-4789-abcd-ef0123456789",
        "api.rate.limit"
    ] + ["9f8e7d6c-5b4a-4321-8f0e-dcba98765432", "01234567-89ab-4cde-8f01-23456789abcd"].sorted()
))

// 3. ProjectContextValue canonicalData + contentSHA256
let nested: ProjectContextValue = .object([
    "z_last": .array([.number(1.0), .number(0.5), .string("a/b"), .null, .bool(true)]),
    "a_first": .object([
        "nested": .string("héllo"),
        "flag": .bool(false)
    ]),
    "num_negzero": .number(-0.0),
    "num_frac": .number(0.1),
    "num_exp": .number(1e21),
    "num_exp_small": .number(1e-7)
])
emit("cv_sha256", try! nested.contentSHA256())
emit("cv_json", String(decoding: try! nested.canonicalData(), as: UTF8.self))

// 4. ContextRecord fingerprint material
let recordMaterial = ContextRecordFingerprintMaterial(
    schemaVersion: 1,
    canonicalizationVersion: ProjectContextValue.canonicalizationVersion,
    projectID: "a1b2c3d4-e5f6-4789-abcd-ef0123456789",
    sourceID: "9f8e7d6c-5b4a-4321-8f0e-dcba98765432",
    externalID: "msg-42",
    kind: .fact,
    subject: "api.rate.limit",
    contentSHA256: "deadbeef".padding(toLength: 64, withPad: "0", startingAt: 0),
    scope: ContextScope(
        environment: "prod",
        component: nil,
        taskID: "01234567-89ab-4cde-8f01-23456789abcd"
    ),
    sensitivity: .restricted,
    accessPolicyID: "b4b4b4b4-b4b4-b4b4-b4b4-b4b4b4b4b4b4",
    confidence: 0.95,
    validFrom: fixedDate,
    validUntil: fixedDate2,
    createdByActorID: "d9f4d3f2-1a2b-4c3d-8e5f-60718293a4b5",
    createdAt: fixedDate
)
let recordJSON = enc(recordMaterial)
emit("record_material_sha256", recordJSON.muSHA256)
emit("record_material_json", String(decoding: recordJSON, as: UTF8.self))

// 5. ContextPolicy fingerprint material
let policyMaterial = ContextPolicyFingerprintMaterial(
    schemaVersion: 1,
    projectID: "a1b2c3d4-e5f6-4789-abcd-ef0123456789",
    subjectKind: .record,
    subjectID: "9f8e7d6c-5b4a-4321-8f0e-dcba98765432",
    familyID: "c1c2c3c4-c5c6-c7c8-c9ca-cbcccdcecfd0",
    version: 2,
    supersedesPolicyID: "d1d2d3d4-d5d6-d7d8-d9da-dbdcdddedfd0",
    namespace: "project/shared",
    sensitivity: .project,
    visibility: .taskParticipants,
    allowedActorIDs: ["a1b2c3d4-e5f6-4789-abcd-ef0123456789", "01234567-89ab-4cde-8f01-23456789abcd"],
    allowedPrincipalIDs: [],
    allowedTaskIDs: ["e1e2e3e4-e5e6-e7e8-e9ea-ebecedeeef00"],
    createdByActorID: "d9f4d3f2-1a2b-4c3d-8e5f-60718293a4b5",
    createdAt: fixedDate
)
let policyJSON = enc(policyMaterial)
emit("policy_material_sha256", policyJSON.muSHA256)
emit("policy_material_json", String(decoding: policyJSON, as: UTF8.self))

// 6. Number formatting across JSONEncoder vs JSONSerialization for tricky values
let trickyNumbers: [Double] = [0.1, 0.2, 1.0, 42.0, 1.5, -0.0, 0.3333333333333333, 1e21, 1e-7, 1.5e-7, 123456789.123456789, 1e6, 3.141592653589793]
for n in trickyNumbers {
    let enc = enc(["v": n])
    let ser = try! JSONSerialization.data(withJSONObject: ["v": n], options: [.sortedKeys, .withoutEscapingSlashes])
    let tag = String(format: "%.17g", n).replacingOccurrences(of: "-", with: "m").replacingOccurrences(of: "+", with: "p").replacingOccurrences(of: ".", with: "d")
    emit("num_\(tag)_enc", String(decoding: enc, as: UTF8.self))
    emit("num_\(tag)_ser", String(decoding: ser, as: UTF8.self))
}

// 7. Escaping: slashes, quotes, control chars
struct EscapePayload: Encodable {
    var slash: String
    var quote: String
    var backslash: String
    var newline: String
    var unicode: String
    var nested: [String: [Double?]]
}
let escapePayload = enc(EscapePayload(
    slash: "a/b/c",
    quote: "say \"hi\"",
    backslash: "path\\file",
    newline: "line1\nline2",
    unicode: "héllo 世界 🚀",
    nested: ["x": [1, 2.5, nil]]
))
emit("escape_sha256", escapePayload.muSHA256)
emit("escape_json", String(decoding: escapePayload, as: UTF8.self))

// 8. UUID string encoding (lowercase confirmation)
let uuidPayload = enc(["id": "A1B2C3D4-E5F6-4789-ABCD-EF0123456789"])
emit("uuid_json", String(decoding: uuidPayload, as: UTF8.self))
