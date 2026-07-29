import Foundation

/// Discovers user-visible Claude Code conversations from Claude Code's local,
/// append-only JSONL artifacts. The adapter never writes to Claude's config
/// directory and intentionally exposes history as non-resumable.
public enum ClaudeCodeHistoryAdapter {
    private static let maximumProjectDirectories = 256
    private static let maximumHistoryFiles = 2_048
    private static let maximumRecordsPerFile = 250_000
    private static let maximumLineBytes = 8 * 1_024 * 1_024
    private static let maximumMessageCharacters = 1_000_000
    private static let maximumMessagesPerSession = 50_000
    private static let maximumSessionTextBytes = 64 * 1_024 * 1_024
    private static let maximumDiscoveryCandidates = 512
    private static let maximumDiscoveryMessages = 100_000
    private static let maximumDiscoveryTextBytes = 64 * 1_024 * 1_024
    private static let readChunkBytes = 64 * 1_024

    private static let systemReminderExpression = try? NSRegularExpression(
        pattern: #"<system-reminder(?:\s[^>]*)?>.*?</system-reminder\s*>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let unterminatedSystemReminderExpression = try? NSRegularExpression(
        pattern: #"<system-reminder(?:\s[^>]*)?>.*\z"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    /// Returns Claude Code sessions whose record-level `cwd` resolves to the
    /// selected workspace. `configurationRoot` is injectable for tests and
    /// alternative Claude installations.
    public static func discover(
        workspacePath: String,
        configurationRoot: URL? = nil
    ) throws -> [ExternalConversationCandidate] {
        let fileManager = FileManager.default
        let canonicalWorkspacePath = WorkspacePathIdentity.canonicalPath(workspacePath)
        let root = canonicalConfigurationRoot(
            configurationRoot ?? defaultConfigurationRoot(fileManager: fileManager)
        )
        let projectsRoot = root
            .appendingPathComponent("projects", isDirectory: true)
            .standardizedFileURL

        var projectsIsDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: projectsRoot.path,
            isDirectory: &projectsIsDirectory
        ), projectsIsDirectory.boolValue else {
            return []
        }

        let providerInstanceKey = "claude-code:\(root.path)"
        let preferredDirectories = encodedWorkspaceDirectoryNames(
            canonicalWorkspacePath
        ).map {
            projectsRoot.appendingPathComponent($0, isDirectory: true)
        }

        var preferredFiles: [URL] = []
        for directory in preferredDirectories {
            let files = try directJSONLFiles(
                in: directory,
                fileManager: fileManager,
                limit: maximumHistoryFiles
            )
            preferredFiles.append(contentsOf: files)
            if preferredFiles.count >= maximumHistoryFiles {
                preferredFiles = Array(preferredFiles.prefix(maximumHistoryFiles))
                break
            }
        }
        preferredFiles = uniqueFiles(preferredFiles)

        var candidates = parseHistoryFiles(
            preferredFiles,
            canonicalWorkspacePath: canonicalWorkspacePath,
            providerInstanceKey: providerInstanceKey,
            fileManager: fileManager
        )

        // Claude has changed its cwd-to-directory encoding over time. Only
        // fall back to other direct project directories when the expected
        // location yielded no exact record-level cwd matches. Both directory
        // and file counts are bounded, and symlinks are never followed.
        if candidates.isEmpty {
            let preferredPaths = Set(preferredDirectories.map(\.standardizedFileURL.path))
            let fallbackFiles = try fallbackJSONLFiles(
                in: projectsRoot,
                excludingDirectoryPaths: preferredPaths,
                fileManager: fileManager
            )
            candidates = parseHistoryFiles(
                fallbackFiles,
                canonicalWorkspacePath: canonicalWorkspacePath,
                providerInstanceKey: providerInstanceKey,
                fileManager: fileManager
            )
        }

        return mergeAndSort(candidates)
    }

    private struct SessionAccumulator {
        var nativeSessionID: String
        var sourceURL: URL
        var messages: [ExternalConversationMessage] = []
        var seenNativeItemIDs: Set<String> = []
        var warnings: [String] = []
        var createdAt: Date?
        var updatedAt: Date?
        var model: String?
        var textByteCount = 0

        mutating func appendWarning(_ warning: String) {
            guard !warnings.contains(warning) else { return }
            warnings.append(warning)
        }

        @discardableResult
        mutating func include(
            role: ExternalConversationRole,
            text: String,
            nativeItemID: String,
            createdAt messageDate: Date?,
            model messageModel: String?
        ) -> Bool {
            guard !seenNativeItemIDs.contains(nativeItemID) else {
                return false
            }
            guard messages.count < ClaudeCodeHistoryAdapter.maximumMessagesPerSession else {
                appendWarning(
                    "The session exceeded Mu's message-count safety limit; later messages were omitted."
                )
                return false
            }

            let byteCount = text.lengthOfBytes(using: .utf8)
            guard textByteCount + byteCount <= ClaudeCodeHistoryAdapter.maximumSessionTextBytes else {
                appendWarning(
                    "The session exceeded Mu's text-size safety limit; later messages were omitted."
                )
                return false
            }

            seenNativeItemIDs.insert(nativeItemID)
            textByteCount += byteCount
            messages.append(
                ExternalConversationMessage(
                    nativeItemID: nativeItemID,
                    ordinal: messages.count,
                    role: role,
                    text: text,
                    createdAt: messageDate
                )
            )
            if let messageDate {
                createdAt = minDate(createdAt, messageDate)
                updatedAt = maxDate(updatedAt, messageDate)
            }
            if let messageModel, !messageModel.isEmpty {
                model = messageModel
            }
            return true
        }
    }

    private struct DiscoveryBudget {
        var remainingCandidates = maximumDiscoveryCandidates
        var remainingMessages = maximumDiscoveryMessages
        var remainingTextBytes = maximumDiscoveryTextBytes
        var isExhausted = false

        mutating func reserve(
            textBytes: Int,
            createsCandidate: Bool
        ) -> Bool {
            guard remainingMessages > 0,
                  textBytes <= remainingTextBytes,
                  !createsCandidate || remainingCandidates > 0 else {
                isExhausted = true
                return false
            }
            remainingMessages -= 1
            remainingTextBytes -= textBytes
            if createsCandidate {
                remainingCandidates -= 1
            }
            return true
        }

        mutating func refund(
            textBytes: Int,
            createdCandidate: Bool
        ) {
            remainingMessages += 1
            remainingTextBytes += textBytes
            if createdCandidate {
                remainingCandidates += 1
            }
        }
    }

    private struct LineStreamStatistics {
        var oversizedLineCount = 0
        var stoppedAtRecordLimit = false
    }

    private static func parseHistoryFiles(
        _ files: [URL],
        canonicalWorkspacePath: String,
        providerInstanceKey: String,
        fileManager: FileManager
    ) -> [ExternalConversationCandidate] {
        var result: [ExternalConversationCandidate] = []
        var budget = DiscoveryBudget()
        for file in files.prefix(maximumHistoryFiles) {
            guard let parsed = try? parseHistoryFile(
                file,
                canonicalWorkspacePath: canonicalWorkspacePath,
                providerInstanceKey: providerInstanceKey,
                fileManager: fileManager,
                discoveryBudget: &budget
            ) else {
                continue
            }
            result.append(contentsOf: parsed)
            if budget.isExhausted { break }
        }
        return result
    }

    private static func parseHistoryFile(
        _ file: URL,
        canonicalWorkspacePath: String,
        providerInstanceKey: String,
        fileManager: FileManager,
        discoveryBudget: inout DiscoveryBudget
    ) throws -> [ExternalConversationCandidate] {
        let attributes = try? file.resourceValues(
            forKeys: [.creationDateKey, .contentModificationDateKey]
        )
        let fallbackCreatedAt = attributes?.creationDate
        let fallbackUpdatedAt = attributes?.contentModificationDate
        let fileSessionID = file.deletingPathExtension().lastPathComponent
        let sourceFileFingerprint = String(
            Data(
                file.standardizedFileURL.resolvingSymlinksInPath().path.utf8
            ).muSHA256.prefix(16)
        )

        var sessions: [String: SessionAccumulator] = [:]
        var sessionOrder: [String] = []
        var canonicalCWDCache: [String: String] = [:]
        var malformedRecordCount = 0
        var lastNonemptyRecordWasMalformed = false
        var recordCount = 0
        var fileWarnings: [String] = []
        var stoppedForRecordLimit = false
        var stoppedForDiscoveryBudget = false

        let statistics = try streamLines(at: file) { line in
            guard !line.isEmpty else { return true }
            recordCount += 1
            guard recordCount <= maximumRecordsPerFile else {
                stoppedForRecordLimit = true
                return false
            }

            guard
                let rawObject = try? JSONSerialization.jsonObject(with: line),
                let record = rawObject as? [String: Any]
            else {
                malformedRecordCount += 1
                lastNonemptyRecordWasMalformed = true
                return true
            }
            lastNonemptyRecordWasMalformed = false

            guard record["isSidechain"] as? Bool != true,
                  record["isMeta"] as? Bool != true,
                  record["isCompactSummary"] as? Bool != true,
                  record["isGenerated"] as? Bool != true,
                  let type = nonemptyString(record["type"]),
                  type == "user" || type == "assistant",
                  let recordCWD = nonemptyString(record["cwd"]),
                  (recordCWD as NSString).isAbsolutePath
            else {
                return true
            }

            let canonicalRecordCWD: String
            if let cached = canonicalCWDCache[recordCWD] {
                canonicalRecordCWD = cached
            } else {
                canonicalRecordCWD = WorkspacePathIdentity.canonicalPath(recordCWD)
                canonicalCWDCache[recordCWD] = canonicalRecordCWD
            }
            guard canonicalRecordCWD == canonicalWorkspacePath,
                  let message = record["message"] as? [String: Any],
                  nonemptyString(message["role"]).map({ $0 == type }) ?? true,
                  let extractedText = visibleText(from: message["content"]),
                  !containsLocalCommandEnvelope(extractedText)
            else {
                return true
            }

            var text = removeSystemReminderContent(from: extractedText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return true }

            var messageWasTruncated = false
            if text.count > maximumMessageCharacters {
                text = String(text.prefix(maximumMessageCharacters))
                messageWasTruncated = true
            }

            let sessionID = nonemptyString(record["sessionId"]) ?? fileSessionID
            guard !sessionID.isEmpty, sessionID.utf8.count <= 1_024 else {
                return true
            }

            let nativeItemID = nonemptyString(record["uuid"])
                ?? "\(sessionID):\(sourceFileFingerprint):record:\(recordCount)"
            guard nativeItemID.utf8.count <= 2_048 else { return true }
            let messageDate = parseDate(record["timestamp"])
            let messageModel = nonemptyString(message["model"])
            let role: ExternalConversationRole = type == "user" ? .user : .assistant
            let createsCandidate = sessions[sessionID] == nil
            let textBytes = text.lengthOfBytes(using: .utf8)
            guard discoveryBudget.reserve(
                textBytes: textBytes,
                createsCandidate: createsCandidate
            ) else {
                stoppedForDiscoveryBudget = true
                return false
            }
            if createsCandidate {
                sessions[sessionID] = SessionAccumulator(
                    nativeSessionID: sessionID,
                    sourceURL: file
                )
                sessionOrder.append(sessionID)
            }
            let didInclude = sessions[sessionID]?.include(
                role: role,
                text: text,
                nativeItemID: nativeItemID,
                createdAt: messageDate,
                model: messageModel
            ) ?? false
            if !didInclude {
                discoveryBudget.refund(
                    textBytes: textBytes,
                    createdCandidate: createsCandidate
                )
            }
            if messageWasTruncated {
                sessions[sessionID]?.appendWarning(
                    "An oversized message was truncated while importing its visible text."
                )
            }
            return true
        }

        if malformedRecordCount > 0 {
            fileWarnings.append(
                "Skipped \(malformedRecordCount) malformed JSONL record(s)."
            )
        }
        if lastNonemptyRecordWasMalformed {
            fileWarnings.append(
                "The JSONL file has a damaged trailing record; earlier messages were preserved."
            )
        }
        if statistics.oversizedLineCount > 0 {
            fileWarnings.append(
                "Skipped \(statistics.oversizedLineCount) JSONL record(s) that exceeded Mu's per-record safety limit."
            )
        }
        if stoppedForRecordLimit || recordCount > maximumRecordsPerFile {
            fileWarnings.append(
                "The JSONL file exceeded Mu's record-count safety limit; later records were omitted."
            )
        }
        if stoppedForDiscoveryBudget {
            fileWarnings.append(
                "Claude Code discovery reached Mu's global memory safety "
                    + "limit; later messages and sessions were omitted."
            )
        }

        return sessionOrder.compactMap { sessionID in
            guard var session = sessions[sessionID], !session.messages.isEmpty else {
                return nil
            }
            for warning in fileWarnings {
                session.appendWarning(warning)
            }

            let createdAt = session.createdAt ?? fallbackCreatedAt
            let updatedAt = session.updatedAt ?? fallbackUpdatedAt ?? createdAt
            return ExternalConversationCandidate(
                provider: .claudeCode,
                providerInstanceKey: providerInstanceKey,
                nativeSessionID: session.nativeSessionID,
                title: conversationTitle(
                    messages: session.messages,
                    sessionID: session.nativeSessionID
                ),
                canonicalWorkspacePath: canonicalWorkspacePath,
                createdAt: createdAt,
                updatedAt: updatedAt,
                isArchived: false,
                model: session.model,
                agentLabel: "Claude Code",
                accessKind: .localReadOnlyArtifact,
                resumability: .historyOnly,
                sourceLocation: session.sourceURL.path,
                warnings: session.warnings,
                discoveredMessageCount: session.messages.count,
                messages: session.messages,
                runtimeInstanceIdentity: .claudeCodeHistory(
                    providerInstanceKey: providerInstanceKey,
                    nativeSessionID: session.nativeSessionID,
                    workspacePath: canonicalWorkspacePath,
                    sourceLocation: session.sourceURL.path
                )
            )
        }
    }

    private static func streamLines(
        at file: URL,
        consume: (Data) -> Bool
    ) throws -> LineStreamStatistics {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var statistics = LineStreamStatistics()
        var buffer = Data()
        var discardingOversizedLine = false
        var shouldContinue = true

        while shouldContinue,
              let chunk = try handle.read(upToCount: readChunkBytes),
              !chunk.isEmpty {
            var cursor = chunk.startIndex
            while shouldContinue && cursor < chunk.endIndex {
                if discardingOversizedLine {
                    guard let newline = chunk[cursor...].firstIndex(of: 0x0A) else {
                        cursor = chunk.endIndex
                        continue
                    }
                    discardingOversizedLine = false
                    cursor = chunk.index(after: newline)
                    continue
                }

                if let newline = chunk[cursor...].firstIndex(of: 0x0A) {
                    let segment = chunk[cursor..<newline]
                    if buffer.count + segment.count > maximumLineBytes {
                        statistics.oversizedLineCount += 1
                        buffer.removeAll(keepingCapacity: false)
                    } else {
                        buffer.append(contentsOf: segment)
                        shouldContinue = consume(buffer)
                        buffer.removeAll(keepingCapacity: true)
                    }
                    cursor = chunk.index(after: newline)
                } else {
                    let segment = chunk[cursor..<chunk.endIndex]
                    if buffer.count + segment.count > maximumLineBytes {
                        statistics.oversizedLineCount += 1
                        buffer.removeAll(keepingCapacity: false)
                        discardingOversizedLine = true
                    } else {
                        buffer.append(contentsOf: segment)
                    }
                    cursor = chunk.endIndex
                }
            }
        }

        if shouldContinue, !discardingOversizedLine, !buffer.isEmpty {
            shouldContinue = consume(buffer)
        }
        statistics.stoppedAtRecordLimit = !shouldContinue
        return statistics
    }

    private static func visibleText(from content: Any?) -> String? {
        if let text = content as? String {
            return text
        }
        guard let blocks = content as? [Any] else { return nil }

        let textBlocks = blocks.compactMap { block -> String? in
            guard let object = block as? [String: Any],
                  nonemptyString(object["type"]) == "text",
                  let text = object["text"] as? String
            else {
                return nil
            }
            return text
        }
        guard !textBlocks.isEmpty else { return nil }
        return textBlocks.joined(separator: "\n")
    }

    private static func removeSystemReminderContent(from text: String) -> String {
        var result = text
        if let expression = systemReminderExpression {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: ""
            )
        }
        if let expression = unterminatedSystemReminderExpression {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: ""
            )
        }
        return result
    }

    private static func containsLocalCommandEnvelope(
        _ text: String
    ) -> Bool {
        let normalized = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        let generatedMarkers = [
            "<local-command-caveat",
            "<local-command-stdout",
            "<local-command-stderr",
            "<command-name",
            "<command-message",
            "<command-args",
            "<bash-input",
            "<bash-stdout",
            "<bash-stderr"
        ]
        return generatedMarkers.contains {
            normalized.hasPrefix($0)
                || normalized.contains("\n\($0)")
        }
    }

    private static func conversationTitle(
        messages: [ExternalConversationMessage],
        sessionID: String
    ) -> String {
        if let firstUserMessage = messages.first(where: { $0.role == .user }),
           let firstLine = firstUserMessage.text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) {
            let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
            return String(trimmed.prefix(96))
        }
        return "Claude Code session \(String(sessionID.prefix(12)))"
    }

    private static func parseDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let rawValue = number.doubleValue
            let seconds = rawValue > 10_000_000_000 ? rawValue / 1_000 : rawValue
            return Date(timeIntervalSince1970: seconds)
        }
        guard let value = nonemptyString(value) else { return nil }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func directJSONLFiles(
        in directory: URL,
        fileManager: FileManager,
        limit: Int
    ) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return []
        }
        let directoryValues = try directory.resourceValues(
            forKeys: [.isSymbolicLinkKey, .isDirectoryKey]
        )
        guard directoryValues.isSymbolicLink != true,
              directoryValues.isDirectory == true else {
            return []
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey
        ]
        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        let jsonlFiles = try children.compactMap { child -> (URL, Date?)? in
            guard child.pathExtension.lowercased() == "jsonl" else { return nil }
            let values = try child.resourceValues(forKeys: keys)
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                return nil
            }
            return (child.standardizedFileURL, values.contentModificationDate)
        }
        .sorted {
            let lhsDate = $0.1 ?? .distantPast
            let rhsDate = $1.1 ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return $0.0.lastPathComponent < $1.0.lastPathComponent
        }
        return jsonlFiles.prefix(limit).map(\.0)
    }

    private static func fallbackJSONLFiles(
        in projectsRoot: URL,
        excludingDirectoryPaths: Set<String>,
        fileManager: FileManager
    ) throws -> [URL] {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey
        ]
        let children = try fileManager.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        let directories = try children.compactMap { child -> (URL, Date?)? in
            let values = try child.resourceValues(forKeys: keys)
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  !excludingDirectoryPaths.contains(child.standardizedFileURL.path)
            else {
                return nil
            }
            return (child.standardizedFileURL, values.contentModificationDate)
        }
        .sorted {
            let lhsDate = $0.1 ?? .distantPast
            let rhsDate = $1.1 ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return $0.0.lastPathComponent < $1.0.lastPathComponent
        }

        var result: [URL] = []
        for (directory, _) in directories.prefix(maximumProjectDirectories) {
            guard result.count < maximumHistoryFiles else { break }
            let remaining = maximumHistoryFiles - result.count
            guard let files = try? directJSONLFiles(
                in: directory,
                fileManager: fileManager,
                limit: remaining
            ) else {
                continue
            }
            result.append(contentsOf: files)
        }
        return uniqueFiles(result)
    }

    private static func encodedWorkspaceDirectoryNames(
        _ canonicalWorkspacePath: String
    ) -> [String] {
        let slashEncoded = canonicalWorkspacePath.replacingOccurrences(
            of: "/",
            with: "-"
        )
        let conservativeEncoded = String(
            canonicalWorkspacePath.unicodeScalars.map { scalar in
                CharacterSet.alphanumerics.contains(scalar)
                    ? Character(scalar)
                    : "-"
            }
        )
        return Array(Set([slashEncoded, conservativeEncoded]))
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .sorted()
    }

    private static func mergeAndSort(
        _ candidates: [ExternalConversationCandidate]
    ) -> [ExternalConversationCandidate] {
        struct Accumulator {
            var candidate: ExternalConversationCandidate
            var messagesByID: [String: ExternalConversationMessage]
        }

        var merged: [String: Accumulator] = [:]
        var order: [String] = []

        for candidate in candidates {
            let key = candidate.nativeSessionID
            guard var accumulator = merged[key] else {
                merged[key] = Accumulator(
                    candidate: candidate,
                    messagesByID: candidate.messages.reduce(into: [:]) {
                        $0[$1.nativeItemID] = $1
                    }
                )
                order.append(key)
                continue
            }
            for message in candidate.messages
                where accumulator.messagesByID[message.nativeItemID] == nil {
                accumulator.messagesByID[message.nativeItemID] = message
            }
            var existing = accumulator.candidate
            existing.createdAt = minDate(existing.createdAt, candidate.createdAt)
            existing.updatedAt = maxDate(existing.updatedAt, candidate.updatedAt)
            existing.discoveredMessageCount = max(
                existing.discoveredMessageCount ?? 0,
                candidate.discoveredMessageCount ?? candidate.messages.count
            )
            if existing.model == nil {
                existing.model = candidate.model
            }
            for warning in candidate.warnings where !existing.warnings.contains(warning) {
                existing.warnings.append(warning)
            }
            let multiArtifactWarning =
                "This session was assembled from multiple read-only Claude Code history artifacts."
            if existing.sourceLocation != candidate.sourceLocation,
               !existing.warnings.contains(multiArtifactWarning) {
                existing.warnings.append(multiArtifactWarning)
            }
            accumulator.candidate = existing
            merged[key] = accumulator
        }

        let values = order.compactMap { key -> ExternalConversationCandidate? in
            guard var accumulator = merged[key] else { return nil }
            let sortedMessages = accumulator.messagesByID.values.sorted {
                let leftDate = $0.createdAt ?? .distantPast
                let rightDate = $1.createdAt ?? .distantPast
                if leftDate != rightDate { return leftDate < rightDate }
                return $0.nativeItemID < $1.nativeItemID
            }
            var retained: [ExternalConversationMessage] = []
            var retainedBytes = 0
            for message in sortedMessages {
                let byteCount = message.text.lengthOfBytes(using: .utf8)
                guard retained.count < maximumMessagesPerSession,
                      retainedBytes + byteCount <= maximumSessionTextBytes else {
                    break
                }
                retained.append(message)
                retainedBytes += byteCount
            }
            accumulator.candidate.messages = retained.enumerated().map {
                index, message in
                ExternalConversationMessage(
                    nativeItemID: message.nativeItemID,
                    ordinal: index,
                    role: message.role,
                    text: message.text,
                    phase: message.phase,
                    createdAt: message.createdAt
                )
            }
            if retained.count < sortedMessages.count {
                accumulator.candidate.warnings.append(
                    "The merged Claude Code session reached Mu's per-session "
                        + "safety limit; later messages were omitted."
                )
            }
            accumulator.candidate.discoveredMessageCount = max(
                accumulator.candidate.discoveredMessageCount ?? 0,
                sortedMessages.count
            )
            return accumulator.candidate
        }
        return values.sorted {
            let lhsDate = $0.updatedAt ?? .distantPast
            let rhsDate = $1.updatedAt ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return $0.nativeSessionID < $1.nativeSessionID
        }
    }

    private static func uniqueFiles(_ files: [URL]) -> [URL] {
        var seen: Set<String> = []
        return files.filter {
            seen.insert($0.standardizedFileURL.path).inserted
        }
    }

    private static func defaultConfigurationRoot(
        fileManager: FileManager
    ) -> URL {
        if let rawValue = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !rawValue.isEmpty {
            return URL(
                fileURLWithPath: (rawValue as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }

    private static func canonicalConfigurationRoot(_ url: URL) -> URL {
        URL(
            fileURLWithPath: (url.path as NSString).expandingTildeInPath,
            isDirectory: true
        )
        .standardizedFileURL
        .resolvingSymlinksInPath()
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func minDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): min(lhs, rhs)
        case let (lhs?, nil): lhs
        case let (nil, rhs?): rhs
        case (nil, nil): nil
        }
    }

    private static func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): max(lhs, rhs)
        case let (lhs?, nil): lhs
        case let (nil, rhs?): rhs
        case (nil, nil): nil
        }
    }
}
