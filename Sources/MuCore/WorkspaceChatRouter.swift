import Foundation

public struct WorkspaceChatRoute: Hashable, Sendable {
    public var mention: String
    public var endpointID: UUID
    public var agentIdentityID: UUID?
    public var prompt: String

    public init(
        mention: String,
        endpointID: UUID,
        agentIdentityID: UUID?,
        prompt: String
    ) {
        self.mention = mention
        self.endpointID = endpointID
        self.agentIdentityID = agentIdentityID
        self.prompt = prompt
    }
}

public struct PreparedWorkspaceMessage: Hashable, Sendable {
    public var entry: ChatEntry
    public var route: WorkspaceChatRoute?

    public init(entry: ChatEntry, route: WorkspaceChatRoute?) {
        self.entry = entry
        self.route = route
    }
}

public enum WorkspaceChatRouter {
    public static func resolve(
        text: String,
        assignedAgentIdentityID: UUID?,
        agents: [AgentIdentity],
        endpoints: [RuntimeEndpoint]
    ) throws -> WorkspaceChatRoute? {
        let expression = try NSRegularExpression(
            pattern: #"(?<![@\p{L}\p{N}_])@([\p{L}\p{N}][\p{L}\p{N}._-]*)"#,
            options: [.caseInsensitive]
        )
        let sourceRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = expression.matches(in: text, range: sourceRange)
        guard !matches.isEmpty else { return nil }

        let endpointByID = Dictionary(uniqueKeysWithValues: endpoints.map { ($0.id, $0) })
        var agentAliases: [String: [AgentIdentity]] = [:]
        for agent in agents {
            let names = aliases(for: agent.displayName).union(
                aliases(for: agent.shortName)
            )
            for alias in names {
                agentAliases[alias, default: []].append(agent)
            }
        }
        var endpointAliases: [String: [RuntimeEndpoint]] = [:]
        for endpoint in endpoints {
            for alias in aliases(for: endpoint.displayName) {
                endpointAliases[alias, default: []].append(endpoint)
            }
            switch endpoint.runtimeTypeID {
            case ControlPlaneService.openWorkerRuntimeTypeID:
                endpointAliases["openworker", default: []].append(endpoint)
            case ControlPlaneService.codexRuntimeTypeID:
                endpointAliases["codex", default: []].append(endpoint)
                endpointAliases[
                    "codex-"
                        + endpoint.id.uuidString
                        .lowercased().prefix(8),
                    default: []
                ].append(endpoint)
            case ControlPlaneService.claudeCodeRuntimeTypeID:
                endpointAliases["claude", default: []].append(endpoint)
                endpointAliases["claudecode", default: []].append(endpoint)
                endpointAliases[
                    "claude-"
                        + endpoint.id.uuidString
                        .lowercased().prefix(8),
                    default: []
                ].append(endpoint)
            default:
                break
            }
        }

        struct Target: Hashable {
            var endpointID: UUID
            var agentID: UUID?
        }
        var resolvedTargets: [Target] = []
        var mentionNames: [String] = []
        for match in matches {
            guard let tokenRange = Range(match.range(at: 1), in: text) else { continue }
            let rawToken = String(text[tokenRange])
            let token = normalize(rawToken)
            let matchingAgents = Array(
                Dictionary(
                    grouping: agentAliases[token] ?? [],
                    by: \.id
                ).values.compactMap(\.first)
            )
            let matchingEndpoints = Array(
                Dictionary(
                    grouping: endpointAliases[token] ?? [],
                    by: \.id
                ).values.compactMap(\.first)
            )
            guard matchingAgents.count + matchingEndpoints.count <= 1 else {
                let candidates =
                    matchingAgents.map(\.displayName) + matchingEndpoints.map(\.displayName)
                throw MuError.invalidTransition(
                    "@\(rawToken) is ambiguous: \(candidates.sorted().joined(separator: ", "))."
                )
            }
            if let agent = matchingAgents.first {
                guard let endpointID = agent.preferredEndpointID,
                      endpointByID[endpointID] != nil else {
                    throw MuError.capabilityMissing(
                        "Agent “\(agent.displayName)” has no registered preferred Runtime."
                    )
                }
                resolvedTargets.append(Target(endpointID: endpointID, agentID: agent.id))
                mentionNames.append(agent.displayName)
            } else if let endpoint = matchingEndpoints.first {
                let assigned = agents.first {
                    $0.id == assignedAgentIdentityID
                        && $0.preferredEndpointID == endpoint.id
                }
                let preferred = assigned ?? agents
                    .filter { $0.preferredEndpointID == endpoint.id }
                    .sorted {
                        $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                            == .orderedAscending
                    }
                    .first
                resolvedTargets.append(
                    Target(endpointID: endpoint.id, agentID: preferred?.id)
                )
                mentionNames.append(endpoint.displayName)
            } else {
                throw MuError.recordNotFound(
                    "No Agent or Runtime is registered for @\(rawToken)."
                )
            }
        }

        let uniqueTargets = Set(resolvedTargets)
        guard uniqueTargets.count == 1, let target = uniqueTargets.first else {
            throw MuError.invalidTransition(
                "Route one Agent per message so each native session has an explicit owner."
            )
        }

        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            mutable.replaceCharacters(in: match.range, with: "")
        }
        let punctuation = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: ",:;，：；")
        )
        let prompt = String(mutable).trimmingCharacters(in: punctuation)
        guard !prompt.isEmpty else {
            throw MuError.invalidTransition(
                "@\(mentionNames.first ?? "Agent") needs a task message."
            )
        }
        return WorkspaceChatRoute(
            mention: mentionNames.first ?? "Agent",
            endpointID: target.endpointID,
            agentIdentityID: target.agentID,
            prompt: prompt
        )
    }

    private static func aliases(for displayName: String) -> Set<String> {
        let normalized = normalize(displayName)
        let collapsed = normalize(
            displayName.replacingOccurrences(of: " ", with: "")
        )
        let first = displayName.split(separator: " ").first.map {
            normalize(String($0))
        }
        return Set([normalized, collapsed, first].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        })
    }

    private static func normalize(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        ).lowercased()
    }
}
