import Foundation

public enum AgentContextBundleValidationError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    public enum Field: String, Equatable, Sendable {
        case agentID = "agent_id"
        case bundleID = "bundle_id"
        case ownerPrincipalID = "owner_principal_id"
        case sourceProjectID = "source_project_id"
        case runtimeSessionID = "runtime_session_id"
        case externalID = "record_external_id"
        case subject = "record_subject"
        case namespace = "access_policy_namespace"
        case artifactURI = "artifact_uri"
    }

    case payloadTooLarge
    case invalidJSON
    case duplicateObjectKey
    case nestingTooDeep
    case stringTooLong
    case invalidBundle
    case unsupportedSchemaVersion
    case tooManyRecords
    case recordTooLarge
    case missingRequiredField(Field)
    case fieldTooLong(Field)
    case unsafeContent([String])
    case artifactsUnsupported

    public var errorDescription: String? {
        switch self {
        case .payloadTooLarge:
            "Agent Context Bundle exceeds the 8 MiB import limit."
        case .invalidJSON:
            "Agent Context Bundle is not valid strict JSON."
        case .duplicateObjectKey:
            "Agent Context Bundle contains a duplicate object key."
        case .nestingTooDeep:
            "Agent Context Bundle exceeds the maximum JSON nesting depth."
        case .stringTooLong:
            "Agent Context Bundle contains an oversized JSON string."
        case .invalidBundle:
            "Agent Context Bundle does not match the supported schema."
        case .unsupportedSchemaVersion:
            "Agent Context Bundle schemaVersion must be exactly 1."
        case .tooManyRecords:
            "Agent Context Bundle exceeds the 1,000-record import limit."
        case .recordTooLarge:
            "Agent Context Bundle contains a record larger than 256 KiB."
        case .missingRequiredField(let field):
            "Agent Context Bundle is missing required field \(field.rawValue)."
        case .fieldTooLong(let field):
            "Agent Context Bundle field \(field.rawValue) exceeds its limit."
        case .unsafeContent(let codes):
            "Agent Context Bundle was rejected by safety validation: "
                + codes.joined(separator: ", ") + "."
        case .artifactsUnsupported:
            "Agent Context Bundle artifacts are not supported by schema v1."
        }
    }
}

/// Strict, deterministic validation at the untrusted Agent Context Bundle
/// boundary. Validation intentionally runs before decoding so duplicate keys
/// cannot be hidden by a JSON implementation's last-value-wins behavior.
public enum AgentContextBundleValidator {
    public static let maximumPayloadBytes = 8 * 1_024 * 1_024
    public static let maximumNestingDepth = 32
    public static let maximumStringBytes = 256 * 1_024
    public static let maximumRecordBytes = 256 * 1_024
    public static let maximumRecordCount = 1_000
    public static let maximumURIBytes = 2_048

    public static func validate(
        rawData: Data
    ) throws -> AgentContextBundle {
        guard rawData.count <= maximumPayloadBytes else {
            throw AgentContextBundleValidationError.payloadTooLarge
        }

        var scanner = StrictJSONScanner(
            data: rawData,
            maximumDepth: maximumNestingDepth,
            maximumStringBytes: maximumStringBytes
        )
        try scanner.validate()

        let safetyCodes = Array(
            Set(ContextBundleSafety.issues(in: rawData).map(\.code))
        ).sorted()
        guard safetyCodes.isEmpty else {
            throw AgentContextBundleValidationError
                .unsafeContent(safetyCodes)
        }

        let bundle: AgentContextBundle
        do {
            bundle = try MuCoding.makeDecoder().decode(
                AgentContextBundle.self,
                from: rawData
            )
        } catch {
            throw AgentContextBundleValidationError.invalidBundle
        }

        guard bundle.schemaVersion == "1" else {
            throw AgentContextBundleValidationError
                .unsupportedSchemaVersion
        }
        try requireNonempty(bundle.agentID, field: .agentID)
        try requireLength(bundle.agentID, maximum: 256, field: .agentID)
        try validateOptional(
            bundle.bundleID,
            maximum: 512,
            field: .bundleID
        )
        try validateOptional(
            bundle.ownerPrincipalID,
            maximum: 512,
            field: .ownerPrincipalID
        )
        try validateOptional(
            bundle.sourceProjectID,
            maximum: 1_024,
            field: .sourceProjectID
        )
        try validateOptional(
            bundle.runtimeSessionID,
            maximum: 1_024,
            field: .runtimeSessionID
        )

        guard bundle.records.count <= maximumRecordCount else {
            throw AgentContextBundleValidationError.tooManyRecords
        }

        let encoder = MuCoding.makeEncoder()
        for record in bundle.records {
            try validateOptional(
                record.externalID,
                maximum: 512,
                field: .externalID
            )
            try validateOptional(
                record.subject,
                maximum: 1_024,
                field: .subject
            )
            let encoded: Data
            do {
                encoded = try encoder.encode(record)
            } catch {
                throw AgentContextBundleValidationError.invalidBundle
            }
            guard encoded.count <= maximumRecordBytes else {
                throw AgentContextBundleValidationError.recordTooLarge
            }
        }

        if let policy = bundle.accessPolicy {
            try requireNonempty(policy.namespace, field: .namespace)
            try requireLength(
                policy.namespace,
                maximum: 256,
                field: .namespace
            )
        }

        // Bundle v1 only carries an artifact URI and claimed metadata. It has
        // no inline bytes or trusted digest with which Mu could verify the
        // artifact, so accepting even a file or HTTP URI would cross the
        // import trust boundary without integrity protection.
        guard bundle.artifacts.isEmpty else {
            for artifact in bundle.artifacts {
                if let uri = artifact.uri {
                    try requireLength(
                        uri,
                        maximum: maximumURIBytes,
                        field: .artifactURI
                    )
                }
            }
            throw AgentContextBundleValidationError
                .artifactsUnsupported
        }

        return bundle
    }

    private static func validateOptional(
        _ value: String?,
        maximum: Int,
        field: AgentContextBundleValidationError.Field
    ) throws {
        guard let value else { return }
        try requireNonempty(value, field: field)
        try requireLength(value, maximum: maximum, field: field)
    }

    private static func requireNonempty(
        _ value: String,
        field: AgentContextBundleValidationError.Field
    ) throws {
        guard !value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw AgentContextBundleValidationError
                .missingRequiredField(field)
        }
    }

    private static func requireLength(
        _ value: String,
        maximum: Int,
        field: AgentContextBundleValidationError.Field
    ) throws {
        guard value.utf8.count <= maximum else {
            throw AgentContextBundleValidationError.fieldTooLong(field)
        }
    }
}

private struct StrictJSONScanner {
    private let bytes: [UInt8]
    private let maximumDepth: Int
    private let maximumStringBytes: Int
    private var index = 0

    init(
        data: Data,
        maximumDepth: Int,
        maximumStringBytes: Int
    ) {
        self.bytes = Array(data)
        self.maximumDepth = maximumDepth
        self.maximumStringBytes = maximumStringBytes
    }

    mutating func validate() throws {
        skipWhitespace()
        try parseValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else {
            throw AgentContextBundleValidationError.invalidJSON
        }
    }

    private mutating func parseValue(depth: Int) throws {
        guard let byte = current else {
            throw AgentContextBundleValidationError.invalidJSON
        }
        switch byte {
        case 0x7B:
            try parseObject(depth: depth + 1)
        case 0x5B:
            try parseArray(depth: depth + 1)
        case 0x22:
            _ = try parseString()
        case 0x74:
            try consumeLiteral([0x74, 0x72, 0x75, 0x65])
        case 0x66:
            try consumeLiteral([0x66, 0x61, 0x6C, 0x73, 0x65])
        case 0x6E:
            try consumeLiteral([0x6E, 0x75, 0x6C, 0x6C])
        case 0x2D, 0x30...0x39:
            try parseNumber()
        default:
            throw AgentContextBundleValidationError.invalidJSON
        }
    }

    private mutating func parseObject(depth: Int) throws {
        try requireDepth(depth)
        index += 1
        skipWhitespace()
        if consume(0x7D) { return }

        var keys = Set<String>()
        while true {
            guard current == 0x22 else {
                throw AgentContextBundleValidationError.invalidJSON
            }
            let key = try parseString()
            guard keys.insert(key).inserted else {
                throw AgentContextBundleValidationError
                    .duplicateObjectKey
            }
            skipWhitespace()
            guard consume(0x3A) else {
                throw AgentContextBundleValidationError.invalidJSON
            }
            skipWhitespace()
            try parseValue(depth: depth)
            skipWhitespace()
            if consume(0x7D) { return }
            guard consume(0x2C) else {
                throw AgentContextBundleValidationError.invalidJSON
            }
            skipWhitespace()
        }
    }

    private mutating func parseArray(depth: Int) throws {
        try requireDepth(depth)
        index += 1
        skipWhitespace()
        if consume(0x5D) { return }

        while true {
            try parseValue(depth: depth)
            skipWhitespace()
            if consume(0x5D) { return }
            guard consume(0x2C) else {
                throw AgentContextBundleValidationError.invalidJSON
            }
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        guard consume(0x22) else {
            throw AgentContextBundleValidationError.invalidJSON
        }
        var result = ""
        var decodedByteCount = 0

        while index < bytes.count {
            let segmentStart = index
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x22 || byte == 0x5C || byte < 0x20 {
                    break
                }
                index += 1
            }
            if index > segmentStart {
                let segmentBytes = bytes[segmentStart..<index]
                guard let segment = String(
                    bytes: segmentBytes,
                    encoding: .utf8
                ) else {
                    throw AgentContextBundleValidationError.invalidJSON
                }
                decodedByteCount += segment.utf8.count
                try requireStringLimit(decodedByteCount)
                result += segment
            }

            guard let byte = current else {
                throw AgentContextBundleValidationError.invalidJSON
            }
            if byte == 0x22 {
                index += 1
                return result
            }
            guard byte == 0x5C else {
                throw AgentContextBundleValidationError.invalidJSON
            }
            index += 1
            guard let escape = current else {
                throw AgentContextBundleValidationError.invalidJSON
            }
            index += 1

            let scalar: Unicode.Scalar
            switch escape {
            case 0x22: scalar = "\""
            case 0x5C: scalar = "\\"
            case 0x2F: scalar = "/"
            case 0x62: scalar = "\u{08}"
            case 0x66: scalar = "\u{0C}"
            case 0x6E: scalar = "\n"
            case 0x72: scalar = "\r"
            case 0x74: scalar = "\t"
            case 0x75:
                scalar = try parseUnicodeEscape()
            default:
                throw AgentContextBundleValidationError.invalidJSON
            }
            let decoded = String(scalar)
            decodedByteCount += decoded.utf8.count
            try requireStringLimit(decodedByteCount)
            result.unicodeScalars.append(scalar)
        }
        throw AgentContextBundleValidationError.invalidJSON
    }

    private mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
        let first = try parseFourHexDigits()
        let scalarValue: UInt32
        if (0xD800...0xDBFF).contains(first) {
            guard consume(0x5C), consume(0x75) else {
                throw AgentContextBundleValidationError.invalidJSON
            }
            let second = try parseFourHexDigits()
            guard (0xDC00...0xDFFF).contains(second) else {
                throw AgentContextBundleValidationError.invalidJSON
            }
            scalarValue = 0x10000
                + (UInt32(first - 0xD800) << 10)
                + UInt32(second - 0xDC00)
        } else {
            guard !(0xDC00...0xDFFF).contains(first) else {
                throw AgentContextBundleValidationError.invalidJSON
            }
            scalarValue = UInt32(first)
        }
        guard let scalar = Unicode.Scalar(scalarValue) else {
            throw AgentContextBundleValidationError.invalidJSON
        }
        return scalar
    }

    private mutating func parseFourHexDigits() throws -> UInt16 {
        guard index + 4 <= bytes.count else {
            throw AgentContextBundleValidationError.invalidJSON
        }
        var value: UInt16 = 0
        for _ in 0..<4 {
            let digit: UInt16
            switch bytes[index] {
            case 0x30...0x39:
                digit = UInt16(bytes[index] - 0x30)
            case 0x41...0x46:
                digit = UInt16(bytes[index] - 0x41 + 10)
            case 0x61...0x66:
                digit = UInt16(bytes[index] - 0x61 + 10)
            default:
                throw AgentContextBundleValidationError.invalidJSON
            }
            value = value * 16 + digit
            index += 1
        }
        return value
    }

    private mutating func parseNumber() throws {
        if consume(0x2D), current == nil {
            throw AgentContextBundleValidationError.invalidJSON
        }
        if consume(0x30) {
            if let byte = current, (0x30...0x39).contains(byte) {
                throw AgentContextBundleValidationError.invalidJSON
            }
        } else {
            guard consumeDigit(in: 0x31...0x39) else {
                throw AgentContextBundleValidationError.invalidJSON
            }
            while consumeDigit(in: 0x30...0x39) {}
        }
        if consume(0x2E) {
            guard consumeDigit(in: 0x30...0x39) else {
                throw AgentContextBundleValidationError.invalidJSON
            }
            while consumeDigit(in: 0x30...0x39) {}
        }
        if consume(0x65) || consume(0x45) {
            _ = consume(0x2B) || consume(0x2D)
            guard consumeDigit(in: 0x30...0x39) else {
                throw AgentContextBundleValidationError.invalidJSON
            }
            while consumeDigit(in: 0x30...0x39) {}
        }
    }

    private mutating func consumeLiteral(
        _ literal: [UInt8]
    ) throws {
        guard index + literal.count <= bytes.count,
              Array(bytes[index..<(index + literal.count)]) == literal else {
            throw AgentContextBundleValidationError.invalidJSON
        }
        index += literal.count
    }

    private mutating func skipWhitespace() {
        while let byte = current,
              byte == 0x20 || byte == 0x09
                || byte == 0x0A || byte == 0x0D {
            index += 1
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard current == byte else { return false }
        index += 1
        return true
    }

    private mutating func consumeDigit(
        in range: ClosedRange<UInt8>
    ) -> Bool {
        guard let byte = current, range.contains(byte) else {
            return false
        }
        index += 1
        return true
    }

    private var current: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private func requireDepth(_ depth: Int) throws {
        guard depth <= maximumDepth else {
            throw AgentContextBundleValidationError.nestingTooDeep
        }
    }

    private func requireStringLimit(_ count: Int) throws {
        guard count <= maximumStringBytes else {
            throw AgentContextBundleValidationError.stringTooLong
        }
    }
}
