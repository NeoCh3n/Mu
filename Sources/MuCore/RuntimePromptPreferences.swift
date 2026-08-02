import Foundation

/// User-editable guidance that Mu appends to a managed Runtime turn.
///
/// These instructions refine how Codex or Claude Code approaches a task. They
/// never replace the Context Pack or Mu's non-editable safety contract.
public struct RuntimePromptPreferences: Codable, Hashable, Sendable {
    public static let maxAdditionalInstructionCharacters = 8_000

    public var codexAdditionalInstructions: String
    public var claudeCodeAdditionalInstructions: String

    public init(
        codexAdditionalInstructions: String = "",
        claudeCodeAdditionalInstructions: String = ""
    ) {
        self.codexAdditionalInstructions = Self.normalize(
            codexAdditionalInstructions
        )
        self.claudeCodeAdditionalInstructions = Self.normalize(
            claudeCodeAdditionalInstructions
        )
    }

    public static let `default` = RuntimePromptPreferences()

    public static func load() -> RuntimePromptPreferences {
        RuntimePromptPreferences(
            codexAdditionalInstructions: UserDefaults.standard.string(
                forKey: codexAdditionalInstructionsKey
            ) ?? "",
            claudeCodeAdditionalInstructions: UserDefaults.standard.string(
                forKey: claudeCodeAdditionalInstructionsKey
            ) ?? ""
        )
    }

    public func save() {
        UserDefaults.standard.set(
            codexAdditionalInstructions,
            forKey: Self.codexAdditionalInstructionsKey
        )
        UserDefaults.standard.set(
            claudeCodeAdditionalInstructions,
            forKey: Self.claudeCodeAdditionalInstructionsKey
        )
    }

    /// Builds the bounded user message sent to either managed Runtime.
    public static func taskPrompt(
        contextPack: String,
        projectMessage: String?,
        additionalInstructions: String
    ) -> String {
        var sections = [contextPack]
        let additional = normalize(additionalInstructions)
        if !additional.isEmpty {
            sections.append(
                "# User-configured Runtime instructions\n\n"
                    + additional
            )
        }
        if let projectMessage {
            let message = projectMessage.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !message.isEmpty {
                sections.append(
                    "# Current Project message\n\n"
                        + message
                )
            }
        }
        return sections.joined(separator: "\n\n")
    }

    /// Appends user guidance without allowing it to replace Mu's required
    /// runtime contract. The final reminder is deliberately fixed so a user
    /// instruction cannot turn a read-only adapter into a write-capable one.
    public static func systemPrompt(
        base: String,
        additionalInstructions: String
    ) -> String {
        let additional = normalize(additionalInstructions)
        guard !additional.isEmpty else { return base }
        return base
            + "\n\nUser-configured instructions (subordinate to Mu's safety contract):\n"
            + additional
            + "\n\nMu's read-only, workspace-scoped, no-network, and no-escalation "
            + "requirements remain authoritative."
    }

    private static let codexAdditionalInstructionsKey =
        "mu.runtimePrompt.codexAdditionalInstructions"
    private static let claudeCodeAdditionalInstructionsKey =
        "mu.runtimePrompt.claudeCodeAdditionalInstructions"

    private static func normalize(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxAdditionalInstructionCharacters else {
            return trimmed
        }
        return String(trimmed.prefix(maxAdditionalInstructionCharacters))
    }
}
