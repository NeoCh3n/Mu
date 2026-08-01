import Foundation
@testable import MuCore
import Testing

@Suite(.serialized)
struct ContextBundleValidationTests {
    @Test
    func acceptsOrdinaryBundle() throws {
        let raw = try encodedBundle(
            records: [
                AgentContextBundleRecord(
                    externalID: "requirement-1",
                    kind: .requirement,
                    subject: "deployment",
                    value: .object([
                        "approved": .bool(true),
                        "region": .string("Singapore")
                    ])
                )
            ]
        )

        let bundle = try AgentContextBundleValidator.validate(
            rawData: raw
        )

        #expect(bundle.schemaVersion == "1")
        #expect(bundle.agentID == "codex-desktop")
        #expect(bundle.records.count == 1)
    }

    @Test
    func rejectsLiteralAndEscapedDuplicateObjectKeys() {
        let literal = validRaw(
            replacingRecordsWith:
                #"[{"kind":"fact","value":{"a":1,"a":2}}]"#
        )
        #expect(
            throws:
                AgentContextBundleValidationError
                    .duplicateObjectKey
        ) {
            try AgentContextBundleValidator.validate(rawData: literal)
        }

        let escaped = validRaw(
            replacingRecordsWith:
                #"[{"kind":"fact","value":{"a":1,"\u0061":2}}]"#
        )
        #expect(
            throws:
                AgentContextBundleValidationError
                    .duplicateObjectKey
        ) {
            try AgentContextBundleValidator.validate(rawData: escaped)
        }
    }

    @Test
    func rejectsExcessiveDepth() {
        let nested = String(repeating: "[", count: 33)
            + "null"
            + String(repeating: "]", count: 33)
        let raw = validRaw(
            replacingRecordsWith:
                #"[{"kind":"fact","value":"#
                + nested + "}]"
        )

        #expect(
            throws:
                AgentContextBundleValidationError.nestingTooDeep
        ) {
            try AgentContextBundleValidator.validate(rawData: raw)
        }
    }

    @Test
    func rejectsNaNAndMalformedJSON() {
        let nan = validRaw(
            replacingRecordsWith:
                #"[{"kind":"fact","value":NaN}]"#
        )
        #expect(
            throws:
                AgentContextBundleValidationError.invalidJSON
        ) {
            try AgentContextBundleValidator.validate(rawData: nan)
        }

        #expect(
            throws:
                AgentContextBundleValidationError.invalidJSON
        ) {
            try AgentContextBundleValidator.validate(
                rawData: Data(#"{"schemaVersion":"1",}"#.utf8)
            )
        }
    }

    @Test
    func rejectsPayloadStringRecordAndFieldLimits() throws {
        let oversizedPayload = Data(
            repeating: 0x20,
            count: AgentContextBundleValidator.maximumPayloadBytes + 1
        )
        #expect(
            throws:
                AgentContextBundleValidationError.payloadTooLarge
        ) {
            try AgentContextBundleValidator.validate(
                rawData: oversizedPayload
            )
        }

        let oversizedString = String(
            repeating: "x",
            count: AgentContextBundleValidator.maximumStringBytes + 1
        )
        let stringRaw = validRaw(
            replacingRecordsWith:
                #"[{"kind":"fact","value":"#
                + jsonString(oversizedString) + "}]"
        )
        #expect(
            throws:
                AgentContextBundleValidationError.stringTooLong
        ) {
            try AgentContextBundleValidator.validate(
                rawData: stringRaw
            )
        }

        let almostMaximumString = String(
            repeating: "x",
            count: AgentContextBundleValidator.maximumStringBytes
        )
        let recordRaw = validRaw(
            replacingRecordsWith:
                #"[{"kind":"fact","value":"#
                + jsonString(almostMaximumString) + "}]"
        )
        #expect(
            throws:
                AgentContextBundleValidationError.recordTooLarge
        ) {
            try AgentContextBundleValidator.validate(
                rawData: recordRaw
            )
        }

        let longAgent = String(repeating: "a", count: 257)
        let fieldRaw = validRaw(agentID: longAgent)
        #expect(
            throws:
                AgentContextBundleValidationError
                    .fieldTooLong(.agentID)
        ) {
            try AgentContextBundleValidator.validate(
                rawData: fieldRaw
            )
        }
    }

    @Test
    func rejectsTooManyRecordsAndUnsafeFields() {
        let record = #"{"kind":"fact","value":"safe"}"#
        let records = Array(
            repeating: record,
            count: AgentContextBundleValidator.maximumRecordCount + 1
        ).joined(separator: ",")

        #expect(
            throws:
                AgentContextBundleValidationError.tooManyRecords
        ) {
            try AgentContextBundleValidator.validate(
                rawData: validRaw(
                    replacingRecordsWith: "[\(records)]"
                )
            )
        }

        let unsafe = Data(
            #"{"schemaVersion":"1","agentID":"codex","exportedAt":"2026-07-29T00:00:00Z","records":[],"artifacts":[],"private_reasoning":"do not import"}"#.utf8
        )
        #expect(
            throws:
                AgentContextBundleValidationError
                    .unsafeContent(["forbidden_field"])
        ) {
            try AgentContextBundleValidator.validate(rawData: unsafe)
        }
    }

    @Test
    func rejectsEveryArtifactIncludingFileAndHTTPURIs() throws {
        for uri in [
            "file:///Users/example/.ssh/id_ed25519",
            "https://example.invalid/untrusted.bin"
        ] {
            let raw = try encodedBundle(
                artifacts: [
                    AgentContextBundleArtifact(
                        artifactID: "artifact-1",
                        name: "untrusted",
                        contentType: "application/octet-stream",
                        uri: uri
                    )
                ]
            )

            #expect(
                throws:
                    AgentContextBundleValidationError
                        .artifactsUnsupported
            ) {
                try AgentContextBundleValidator.validate(rawData: raw)
            }
        }
    }

    @Test
    func rejectsWrongSchemaAndEmptyAgentIdentity() {
        #expect(
            throws:
                AgentContextBundleValidationError
                    .unsupportedSchemaVersion
        ) {
            try AgentContextBundleValidator.validate(
                rawData: validRaw(schemaVersion: "2")
            )
        }
        #expect(
            throws:
                AgentContextBundleValidationError
                    .missingRequiredField(.agentID)
        ) {
            try AgentContextBundleValidator.validate(
                rawData: validRaw(agentID: "   ")
            )
        }
    }

    private func encodedBundle(
        records: [AgentContextBundleRecord] = [],
        artifacts: [AgentContextBundleArtifact] = []
    ) throws -> Data {
        try MuCoding.makeEncoder().encode(
            AgentContextBundle(
                bundleID: "bundle-1",
                agentID: "codex-desktop",
                runtimeSessionID: "thread-1",
                exportedAt: Date(
                    timeIntervalSince1970: 1_700_000_000
                ),
                records: records,
                artifacts: artifacts
            )
        )
    }

    private func validRaw(
        schemaVersion: String = "1",
        agentID: String = "codex",
        replacingRecordsWith records: String = "[]"
    ) -> Data {
        let raw = """
        {"schemaVersion":\(jsonString(schemaVersion)),"agentID":\(jsonString(agentID)),"exportedAt":"2026-07-29T00:00:00Z","records":\(records),"artifacts":[]}
        """
        return Data(raw.utf8)
    }

    private func jsonString(_ value: String) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed]
        )
        return String(decoding: data, as: UTF8.self)
    }
}
