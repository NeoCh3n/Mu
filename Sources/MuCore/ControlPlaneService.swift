import Foundation

private actor OpenWorkerSyncGate {
    private var activeBindingIDs = Set<UUID>()
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ bindingID: UUID) async {
        if activeBindingIDs.insert(bindingID).inserted {
            return
        }
        await withCheckedContinuation { continuation in
            waiters[bindingID, default: []].append(continuation)
        }
    }

    func release(_ bindingID: UUID) {
        if var queued = waiters[bindingID], !queued.isEmpty {
            let next = queued.removeFirst()
            if queued.isEmpty {
                waiters.removeValue(forKey: bindingID)
            } else {
                waiters[bindingID] = queued
            }
            next.resume()
        } else {
            activeBindingIDs.remove(bindingID)
        }
    }
}

public struct OpenWorkerSessionSyncResult: Hashable, Sendable {
    public var binding: RuntimeSessionBinding
    public var didChange: Bool

    public init(binding: RuntimeSessionBinding, didChange: Bool) {
        self.binding = binding
        self.didChange = didChange
    }
}

public final class ControlPlaneService: @unchecked Sendable {
    public static let codexRuntimeTypeID = "openai.codex/app-server"
    public static let claudeCodeRuntimeTypeID =
        "anthropic.claude-code/cli"
    public static let openWorkerRuntimeTypeID = "andrewyng.openworker/desktop"
    public static let codexEndpointID = UUID(
        uuidString: "2BF4A318-CF0A-46C9-B1BA-4997C3F4A230"
    )!
    public static let openWorkerEndpointID = UUID(
        uuidString: "F80FE2E4-55C9-4A30-83E1-77DCE2D63B3B"
    )!
    public static let claudeCodeEndpointID = UUID(
        uuidString: "1F6A8867-4290-4B98-A8B0-9E14564DEAA4"
    )!
    public static let localOwnerPrincipalID = UUID(
        uuidString: "CF0F5E7B-CC4C-55B1-A567-8EF56E282D86"
    )!
    public static let localHumanActorID = UUID(
        uuidString: "80604C4D-BB4E-56B0-94CE-9B6CC107FC0A"
    )!
    public static let syntheticEndpointAID = UUID(
        uuidString: "7DDA46AF-32B4-4F75-A051-0A5A02B15D01"
    )!
    public static let syntheticEndpointBID = UUID(
        uuidString: "38FE2F9F-6889-4498-B15B-292B57CF84A1"
    )!
    public static let manualBridgeEndpointID = UUID(
        uuidString: "7B9A48D8-99AF-4A70-92CB-90E95109765D"
    )!
    public static let atlasAgentID = UUID(
        uuidString: "7512E5A0-F50F-4C60-AB0A-740D25CA2BD8"
    )!
    public static let forgeAgentID = UUID(
        uuidString: "A85A169B-45CD-47D2-BB37-A1D061A075D7"
    )!
    public static let lensAgentID = UUID(
        uuidString: "4FB16318-2786-4F36-AB08-8433D40BE110"
    )!
    public static let scoutAgentID = UUID(
        uuidString: "E7253352-F8CA-4EC0-9B83-8B34AE6CD21D"
    )!
    public static let relayAgentID = UUID(
        uuidString: "47A9E791-DDE4-498C-8BBA-4D8EF7AD2DC0"
    )!
    private static let starterAgentIDs: Set<UUID> = [
        atlasAgentID,
        forgeAgentID,
        lensAgentID,
        scoutAgentID,
        relayAgentID
    ]
    public static let codexImplementedCapabilities: Set<RuntimeCapability> = [
        .start,
        .replan,
        .streamEvents,
        .contributeCheckpointEvidence,
        .discoverGitArtifacts
    ]
    public static let openWorkerImplementedCapabilities: Set<RuntimeCapability> = [
        .start,
        .continueRun,
        .replan,
        .cancel,
        .streamEvents,
        .contributeCheckpointEvidence,
        .discoverGitArtifacts,
        .approvalIntent
    ]
    public static let claudeCodeImplementedCapabilities:
        Set<RuntimeCapability> = [
            .start,
            .continueRun,
            .cancel,
            .streamEvents,
            .contributeCheckpointEvidence,
            .discoverGitArtifacts
        ]

    public let store: SQLiteStore
    public let artifactStore: ArtifactStore

    let repositoryProbe: GitRepositoryProbe
    private let runtimePromptLock = NSLock()
    private var runtimePromptPreferencesStorage = RuntimePromptPreferences.default
    private let openWorkerSyncGate = OpenWorkerSyncGate()
    let codexRuntimeLock = NSLock()
    var activeCodexClients:
        [UUID: CodexAppServerClient] = [:]
    /// One long-lived app-server client per endpoint. Creating a new process
    /// for every Task made first routing pay process launch + initialize time.
    var cachedCodexClients:
        [UUID: CodexAppServerClient] = [:]
    let claudeRuntimeLock = NSLock()
    var activeClaudeClients:
        [UUID: ClaudeCodeClient] = [:]
    let additionalHistoryAdapters:
        [any ConversationHistoryAdapter]
    let historyDiscoveryLock = NSLock()
    var historyDiscoveryCache:
        [UUID: [String: ExternalConversationCandidate]] = [:]
    var historyDiscoveryCacheOrder: [UUID] = []

    /// Runtime guidance is local, user-owned configuration. The lock lets a
    /// Settings edit safely take effect for the next turn while a native
    /// Runtime is running on a background queue.
    public var runtimePromptPreferences: RuntimePromptPreferences {
        get { runtimePromptLock.withLock { runtimePromptPreferencesStorage } }
        set {
            runtimePromptLock.withLock {
                runtimePromptPreferencesStorage = newValue
            }
        }
    }

    public init(
        dataDirectory: URL? = nil,
        historyAdapters: [any ConversationHistoryAdapter] = []
    ) throws {
        var adapterRegistrations = Set<String>()
        for adapter in historyAdapters {
            let providerID = adapter.provider.rawValue
            let instanceKey = adapter.providerInstanceKey
            guard !providerID.isEmpty,
                  providerID.utf8.count <= 128,
                  !instanceKey.isEmpty,
                  instanceKey.utf8.count <= 2_048,
                  !ConversationProvider.allCases.contains(adapter.provider) else {
                throw MuError.invalidTransition(
                    "A conversation-history adapter must use a bounded, "
                        + "non-reserved provider and instance identity."
                )
            }
            let registration = providerID + "\u{0}" + instanceKey
            guard adapterRegistrations.insert(registration).inserted else {
                throw MuError.invalidTransition(
                    "A conversation-history adapter registration is duplicated."
                )
            }
        }
        let root = try dataDirectory ?? SQLiteStore.defaultDataDirectory()
        self.store = try SQLiteStore(databaseURL: root.appending(path: "mu.sqlite"))
        self.artifactStore = try ArtifactStore(
            rootURL: root.appending(path: "cas", directoryHint: .isDirectory)
        )
        self.repositoryProbe = GitRepositoryProbe(artifactStore: artifactStore)
        self.additionalHistoryAdapters = historyAdapters
        try redactLegacyImportedContextPlaintext()
        try bootstrapEndpoints()
        try bootstrapAgentIdentities()
        try bootstrapProjectKernel()
        try migrateLegacyImportedConversationsToContextSources()
        try refreshRuntimeAdapterRegistrations()
    }

    deinit {
        let clients = codexRuntimeLock.withLock {
            let values = Array(cachedCodexClients.values)
            cachedCodexClients.removeAll()
            activeCodexClients.removeAll()
            return values
        }
        for client in clients {
            client.stop()
        }
    }

    /// Returns the endpoint-scoped Codex client, creating it without starting
    /// a process. Callers can then warm it or submit a turn through the same
    /// persistent app-server connection.
    func codexClient(for endpoint: RuntimeEndpoint) throws -> CodexAppServerClient {
        guard let path = endpoint.nativeConfiguration?["executable"] else {
            throw MuError.commandFailed("Codex executable path is not registered.")
        }
        return codexRuntimeLock.withLock {
            if let cached = cachedCodexClients[endpoint.id] {
                return cached
            }
            let client = CodexAppServerClient(
                executableURL: URL(fileURLWithPath: path)
            )
            cachedCodexClients[endpoint.id] = client
            return client
        }
    }

    /// Best-effort background warm-up. A first Task remains correct if the
    /// runtime is unavailable, but normally reaches thread/start immediately.
    public func warmCodexEndpoints() {
        let endpoints = (try? store.fetchRegisteredEndpoints()) ?? []
        for endpoint in endpoints where endpoint.runtimeTypeID == Self.codexRuntimeTypeID
            && (endpoint.status == .active || endpoint.status == .discovered) {
            guard let client = try? codexClient(for: endpoint) else { continue }
            DispatchQueue.global(qos: .utility).async {
                try? client.warm()
            }
        }
    }

    public func bootstrapEndpoints() throws {
        let existing = try store.fetchEndpoints()
        let existingIDs = Set(existing.map(\.id))
        let deletedIDs = Set(
            try store.fetchRegistryTombstones()
                .filter { $0.entityKind == .runtimeEndpoint }
                .map(\.id)
        )
        let fullCapabilities: Set<RuntimeCapability> = [
            .start,
            .continueRun,
            .replan,
            .cancel,
            .streamEvents,
            .contributeCheckpointEvidence,
            .discoverGitArtifacts,
            .approvalIntent
        ]
        let endpointA = RuntimeEndpoint(
            id: Self.syntheticEndpointAID,
            runtimeTypeID: "mu.synthetic/runtime-a",
            displayName: "Synthetic Runtime A",
            adapterVersion: "0.1.0",
            runtimeVersion: "fixture-1",
            location: .local,
            provenance: .synthetic,
            permissionModel: .fineGrained,
            capabilities: fullCapabilities,
            status: .active,
            guaranteeNote: "Offline conformance fixture. It validates Mu workflows but does not control a vendor runtime."
        )
        let endpointB = RuntimeEndpoint(
            id: Self.syntheticEndpointBID,
            runtimeTypeID: "mu.synthetic/runtime-b",
            displayName: "Synthetic Runtime B",
            adapterVersion: "0.1.0",
            runtimeVersion: "fixture-1",
            location: .local,
            provenance: .synthetic,
            permissionModel: .promptGate,
            capabilities: fullCapabilities,
            status: .active,
            guaranteeNote: "Independent offline receiver fixture. Every cross-runtime Handoff starts a new Replan Run."
        )
        let manualBridge = RuntimeEndpoint(
            id: Self.manualBridgeEndpointID,
            runtimeTypeID: "mu.manual/artifact-bridge",
            displayName: "Manual Artifact Bridge",
            adapterVersion: "0.1.0",
            runtimeVersion: "manual",
            location: .local,
            provenance: .artifactOnly,
            permissionModel: .unknown,
            capabilities: [.contributeCheckpointEvidence, .discoverGitArtifacts],
            status: .active,
            guaranteeNote: "Captures user-confirmed repository evidence only. Live start, resume, approval, and Replan are unsupported."
        )

        var endpointsToInsert: [RuntimeEndpoint] = []
        if !existingIDs.contains(endpointA.id), !deletedIDs.contains(endpointA.id) {
            endpointsToInsert.append(endpointA)
        }
        if !existingIDs.contains(endpointB.id), !deletedIDs.contains(endpointB.id) {
            endpointsToInsert.append(endpointB)
        }
        if !existingIDs.contains(manualBridge.id), !deletedIDs.contains(manualBridge.id) {
            endpointsToInsert.append(manualBridge)
        }

        if let executableURL = CodexDiscovery.executableURL(),
           !existingIDs.contains(Self.codexEndpointID),
           !deletedIDs.contains(Self.codexEndpointID) {
            endpointsToInsert.append(
                RuntimeEndpoint(
                    id: Self.codexEndpointID,
                    runtimeTypeID: Self.codexRuntimeTypeID,
                    displayName: "Codex App Server",
                    adapterVersion: "0.4.0",
                    runtimeVersion: "probe required",
                    location: .local,
                    provenance: .vendorProtocol,
                    permissionModel: .fineGrained,
                    capabilities: Self.codexImplementedCapabilities,
                    status: .discovered,
                    guaranteeNote:
                        "Official App Server executable detected. Run a capability probe before scheduling.",
                    nativeConfiguration: ["executable": executableURL.path]
                )
            )
        }

        if let executableURL = ClaudeCodeDiscovery.executableURL(),
           !existingIDs.contains(Self.claudeCodeEndpointID),
           !deletedIDs.contains(Self.claudeCodeEndpointID) {
            endpointsToInsert.append(
                RuntimeEndpoint(
                    id: Self.claudeCodeEndpointID,
                    runtimeTypeID:
                        Self.claudeCodeRuntimeTypeID,
                    displayName: "Claude Code CLI",
                    adapterVersion: "0.1.0",
                    runtimeVersion: "probe required",
                    location: .local,
                    provenance: .vendorCLI,
                    permissionModel: .promptGate,
                    capabilities: [],
                    status: .discovered,
                    guaranteeNote:
                        "Claude Code CLI detected. Probe its local "
                        + "authentication and stream-json contract before "
                        + "scheduling a read-only Task.",
                    nativeConfiguration: [
                        "executable": executableURL.path,
                        RuntimeIdentityConfigurationKey.provider:
                            ConversationProvider.claudeCode.rawValue,
                        RuntimeIdentityConfigurationKey.surfaceKind:
                            AgentRuntimeSurfaceKind.terminalCLI.rawValue,
                        RuntimeIdentityConfigurationKey.instanceLabel:
                            "Claude Code CLI",
                        RuntimeIdentityConfigurationKey.nativeSource:
                            "managed_cli"
                    ]
                )
            )
        }

        if let discovery = OpenWorkerDiscovery.discover(),
           !existingIDs.contains(Self.openWorkerEndpointID),
           !deletedIDs.contains(Self.openWorkerEndpointID) {
            endpointsToInsert.append(
                RuntimeEndpoint(
                    id: Self.openWorkerEndpointID,
                    runtimeTypeID: Self.openWorkerRuntimeTypeID,
                    displayName: "OpenWorker Desktop",
                    adapterVersion: "0.5.0",
                    runtimeVersion: discovery.version,
                    location: .local,
                    provenance: .vendorProtocol,
                    permissionModel: .unknown,
                    capabilities: [],
                    status: .discovered,
                    guaranteeNote:
                        "Desktop bundle detected. Probe its loopback session protocol before "
                        + "routing Workspace Chat or linking a native session.",
                    nativeConfiguration: [
                        "application_path": discovery.appURL.path,
                        "bundle_identifier": discovery.bundleID,
                        "executable": discovery.executableURL.path
                    ]
                )
            )
        }

        if var registeredCodex = existing.first(where: {
            $0.id == Self.codexEndpointID && !deletedIDs.contains($0.id)
        }),
           registeredCodex.capabilities != Self.codexImplementedCapabilities
            || registeredCodex.adapterVersion != "0.4.0"
            || registeredCodex.guaranteeNote.localizedCaseInsensitiveContains(
                "project run"
            ) {
            registeredCodex.capabilities = Self.codexImplementedCapabilities
            registeredCodex.adapterVersion = "0.4.0"
            registeredCodex.guaranteeNote = registeredCodex.status == .active
                ? "Live official App Server connection verified. Initial read-only Task runs and "
                    + "receiving Replans create persistent native threads and turns. Workspace "
                    + "chat dispatch, Continue, Cancel, writes, and approvals are not exposed."
                : "Official App Server executable detected. Run a capability probe before scheduling."
            try store.upsertEndpoint(registeredCodex)
        }

        if var registeredOpenWorker = existing.first(where: {
            $0.id == Self.openWorkerEndpointID && !deletedIDs.contains($0.id)
        }) {
            registeredOpenWorker.adapterVersion = "0.5.0"
            registeredOpenWorker.capabilities = []
            if (registeredOpenWorker.nativeConfiguration?[
                RuntimeIdentityConfigurationKey.permissionModelSource
            ] ?? "") != "user_configured" {
                registeredOpenWorker.permissionModel = .unknown
            }
            if let discovery = OpenWorkerDiscovery.discover() {
                registeredOpenWorker.runtimeVersion = discovery.version
                registeredOpenWorker.status = .discovered
                registeredOpenWorker.guaranteeNote =
                    "Desktop bundle detected. Probe its loopback session protocol before "
                    + "routing Workspace Chat or linking a native session."
                var configuration = registeredOpenWorker.nativeConfiguration ?? [:]
                configuration.merge([
                    "application_path": discovery.appURL.path,
                    "bundle_identifier": discovery.bundleID,
                    "executable": discovery.executableURL.path
                ]) { _, discoveredValue in discoveredValue }
                registeredOpenWorker.nativeConfiguration = configuration
            } else {
                registeredOpenWorker.status = .offline
                registeredOpenWorker.guaranteeNote =
                    "OpenWorker Desktop is not installed. Workspace routing is disabled."
            }
            try store.upsertEndpoint(registeredOpenWorker)
        }

        if var registeredClaude = existing.first(where: {
            $0.id == Self.claudeCodeEndpointID
                && !deletedIDs.contains($0.id)
        }) {
            registeredClaude.adapterVersion = "0.1.0"
            if let executableURL =
                ClaudeCodeDiscovery.executableURL() {
                var configuration =
                    registeredClaude.nativeConfiguration ?? [:]
                configuration.merge([
                    "executable": executableURL.path,
                    RuntimeIdentityConfigurationKey.provider:
                        ConversationProvider.claudeCode.rawValue,
                    RuntimeIdentityConfigurationKey.surfaceKind:
                        AgentRuntimeSurfaceKind.terminalCLI.rawValue,
                    RuntimeIdentityConfigurationKey.instanceLabel:
                        "Claude Code CLI",
                    RuntimeIdentityConfigurationKey.nativeSource:
                        "managed_cli"
                ]) { _, discoveredValue in discoveredValue }
                registeredClaude.nativeConfiguration =
                    configuration
                if registeredClaude.status != .active {
                    registeredClaude.status = .discovered
                    registeredClaude.capabilities = []
                    registeredClaude.guaranteeNote =
                        "Claude Code CLI detected. Probe its local "
                        + "authentication and stream-json contract before "
                        + "scheduling a read-only Task."
                }
            } else {
                registeredClaude.status = .offline
                registeredClaude.capabilities = []
                registeredClaude.guaranteeNote =
                    "Claude Code CLI is not installed at a known local path."
            }
            try store.upsertEndpoint(registeredClaude)
        }

        guard !endpointsToInsert.isEmpty else { return }
        try store.withTransaction {
            for endpoint in endpointsToInsert {
                try store.upsertEndpoint(endpoint)
            }
            try store.appendEvent(
                LedgerEvent(
                    type: "registry.bootstrapped",
                    summary: "Registered \(endpointsToInsert.count) newly discovered runtime endpoint(s).",
                    payload: [
                        "schema_version": "0.2",
                        "endpoint_ids": endpointsToInsert.map(\.id.uuidString).joined(separator: ",")
                    ]
                )
            )
        }
    }

    public func bootstrapAgentIdentities() throws {
        let existingIDs = Set(try store.fetchAgents().map(\.id))
        let deletedIDs = Set(
            try store.fetchRegistryTombstones()
                .filter { $0.entityKind == .agentIdentity }
                .map(\.id)
        )
        let endpoints = try store.fetchRegisteredEndpoints()
        let registeredEndpointIDs = Set(endpoints.map(\.id))
        let codexIsActive = endpoints.contains {
            $0.id == Self.codexEndpointID && $0.status == .active
        }
        let defaultSyntheticEndpointID: UUID? =
            registeredEndpointIDs.contains(Self.syntheticEndpointAID)
                ? Self.syntheticEndpointAID
                : registeredEndpointIDs.contains(Self.syntheticEndpointBID)
                    ? Self.syntheticEndpointBID
                    : nil
        let identities = [
            AgentIdentity(
                id: Self.atlasAgentID,
                displayName: "Atlas",
                shortName: "AT",
                role: .orchestrator,
                summary: "Frames objectives, coordinates ownership, and keeps handoffs explicit.",
                preferredEndpointID: codexIsActive
                    ? Self.codexEndpointID
                    : defaultSyntheticEndpointID,
                capabilityTags: ["planning", "coordination", "handoff"],
                accentHex: "#6E4CEB"
            ),
            AgentIdentity(
                id: Self.forgeAgentID,
                displayName: "Forge",
                shortName: "FG",
                role: .builder,
                summary: "Implements scoped work and stays close to files, tests, and terminal evidence.",
                preferredEndpointID: registeredEndpointIDs.contains(Self.syntheticEndpointAID)
                    ? Self.syntheticEndpointAID
                    : nil,
                capabilityTags: ["implementation", "files", "terminal"],
                accentHex: "#F46E4D"
            ),
            AgentIdentity(
                id: Self.lensAgentID,
                displayName: "Lens",
                shortName: "LN",
                role: .reviewer,
                summary: "Reviews changes against constraints and turns findings into durable evidence.",
                preferredEndpointID: registeredEndpointIDs.contains(Self.syntheticEndpointBID)
                    ? Self.syntheticEndpointBID
                    : nil,
                capabilityTags: ["review", "verification", "artifacts"],
                accentHex: "#36B892"
            ),
            AgentIdentity(
                id: Self.scoutAgentID,
                displayName: "Scout",
                shortName: "SC",
                role: .researcher,
                summary:
                    "Investigates bounded questions and separates observed evidence from inference.",
                preferredEndpointID: registeredEndpointIDs.contains(Self.openWorkerEndpointID)
                    ? Self.openWorkerEndpointID
                    : defaultSyntheticEndpointID,
                capabilityTags: ["research", "browser", "files", "evidence"],
                accentHex: "#2F80ED"
            ),
            AgentIdentity(
                id: Self.relayAgentID,
                displayName: "Relay",
                shortName: "RY",
                role: .reviewer,
                summary:
                    "Runs verification-oriented tasks and returns concise, traceable receipts.",
                preferredEndpointID: codexIsActive
                    ? Self.codexEndpointID
                    : defaultSyntheticEndpointID,
                capabilityTags: ["verification", "terminal", "artifacts", "handoff"],
                accentHex: "#D98B23"
            )
        ]
        let newIdentities = identities.filter {
            !existingIDs.contains($0.id) && !deletedIDs.contains($0.id)
        }
        guard !newIdentities.isEmpty else { return }

        try store.withTransaction {
            for identity in newIdentities {
                try store.upsertAgent(identity)
            }
            try store.appendEvent(
                LedgerEvent(
                    type: "agent_registry.bootstrapped",
                    summary: "Registered \(newIdentities.count) runtime-independent agent identities.",
                    payload: [
                        "agent_ids": newIdentities.map(\.id.uuidString).joined(separator: ","),
                        "identity_contract": "runtime_independent"
                    ]
                )
            )
        }
    }

    @discardableResult
    public func createAgentIdentity(
        displayName: String,
        shortName: String,
        role: AgentRole,
        summary: String,
        preferredEndpointID: UUID?,
        capabilityTags: [String],
        accentHex: String
    ) throws -> AgentIdentity {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw MuError.invalidTransition("Agent name is required.")
        }
        let existing = try store.fetchAgents()
        guard !existing.contains(where: {
            $0.displayName.compare(name, options: [.caseInsensitive, .diacriticInsensitive])
                == .orderedSame
        }) else {
            throw MuError.invalidTransition("An Agent named “\(name)” already exists.")
        }
        if let preferredEndpointID,
           try store.fetchRegisteredEndpoint(id: preferredEndpointID) == nil {
            throw MuError.recordNotFound("Preferred runtime \(preferredEndpointID)")
        }
        let normalizedShortName = Self.normalizedShortName(
            shortName,
            fallbackName: name
        )
        let normalizedAccent = accentHex.uppercased()
        guard normalizedAccent.range(
            of: #"^#[0-9A-F]{6}$"#,
            options: .regularExpression
        ) != nil else {
            throw MuError.invalidTransition("Accent color must use #RRGGBB.")
        }
        var seenTags = Set<String>()
        let tags = capabilityTags.compactMap { raw -> String? in
            let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { return nil }
            let key = tag.lowercased()
            guard seenTags.insert(key).inserted else { return nil }
            return tag
        }
        let agent = AgentIdentity(
            displayName: name,
            shortName: normalizedShortName,
            role: role,
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            preferredEndpointID: preferredEndpointID,
            capabilityTags: tags,
            accentHex: normalizedAccent
        )
        try store.withTransaction {
            if let preferredEndpointID {
                guard try store.fetchRegisteredEndpoint(id: preferredEndpointID) != nil else {
                    throw MuError.recordNotFound("Preferred runtime \(preferredEndpointID)")
                }
            }
            try store.upsertAgent(agent)
            try store.upsertProjectActor(
                ProjectActorRecord(
                    id:
                        ProjectActorRecord
                        .stableAgentIdentityActorID(
                            agentIdentityID: agent.id
                        ),
                    principalID: Self.localOwnerPrincipalID,
                    kind: .agent,
                    displayName: agent.displayName,
                    agentIdentityID: agent.id,
                    runtimeEndpointID: preferredEndpointID,
                    createdAt: agent.createdAt,
                    updatedAt: agent.createdAt
                )
            )
            try store.appendEvent(
                LedgerEvent(
                    type: "agent.created",
                    summary: "Registered Agent identity “\(agent.displayName)”.",
                    payload: [
                        "agent_id": agent.id.uuidString,
                        "role": agent.role.rawValue,
                        "preferred_endpoint_id": preferredEndpointID?.uuidString ?? ""
                    ]
                )
            )
        }
        return agent
    }

    public func deleteAgentIdentity(id: UUID) throws {
        guard let agent = try store.fetchAgent(id: id) else {
            throw MuError.recordNotFound("Agent identity \(id)")
        }
        var tasks = try store.fetchTasks().filter {
            $0.assignedAgentIdentityID == id
        }
        var runs = try store.fetchRuns().filter {
            $0.agentIdentityID == id
        }
        var bindings = try store.fetchRuntimeSessionBindings().filter {
            $0.agentIdentityID == id
        }
        let affectedTaskCount = tasks.count
        let affectedRunCount = runs.count
        let affectedBindingCount = bindings.count
        let now = Date()
        for index in tasks.indices {
            tasks[index].assignedAgentIdentityID = nil
            tasks[index].assignedActorID = nil
            tasks[index].updatedAt = now
        }
        for index in runs.indices {
            runs[index].agentIdentityID = nil
            runs[index].updatedAt = now
        }
        for index in bindings.indices {
            bindings[index].agentIdentityID = nil
            bindings[index].updatedAt = now
        }

        try store.withTransaction {
            for task in tasks { try store.upsertTask(task) }
            for run in runs { try store.upsertRun(run) }
            for binding in bindings {
                try store.upsertRuntimeSessionBinding(binding)
            }
            try store.deleteAgent(id: id)
            let actorID =
                ProjectActorRecord.stableAgentIdentityActorID(
                    agentIdentityID: id
                )
            if var actor = try store.fetchProjectActor(id: actorID) {
                actor.status = .retired
                actor.updatedAt = now
                try store.upsertProjectActor(actor)
            }
            for task in tasks {
                if var link = try store.fetchTaskProjectLink(
                    taskID: task.id
                ), link.assignedToActorID == actorID {
                    link.assignedToActorID = nil
                    link.updatedAt = now
                    try store.upsertTaskProjectLink(link)
                }
            }
            try store.upsertRegistryTombstone(
                RegistryTombstone(
                    id: id,
                    entityKind: .agentIdentity,
                    displayName: agent.displayName,
                    deletedAt: now
                )
            )
            try store.appendEvent(
                LedgerEvent(
                    type: "agent.deleted",
                    summary: "Deleted Agent identity “\(agent.displayName)”.",
                    payload: [
                        "agent_id": id.uuidString,
                        "unassigned_task_count": String(affectedTaskCount),
                        "detached_run_count": String(affectedRunCount),
                        "detached_session_binding_count": String(affectedBindingCount)
                    ]
                )
            )
        }
    }

    @discardableResult
    public func registerManualEndpoint(
        displayName: String,
        runtimeTypeID: String,
        location: EndpointLocation,
        provenance: IntegrationProvenance,
        permissionModel: PermissionModel,
        executablePath: String?,
        surfaceKind: AgentRuntimeSurfaceKind = .unknown,
        instanceLabel: String = "",
        terminalIdentifier: String = "",
        notes: String,
        defaultModel: String? = nil,
        modelOptions: [String] = []
    ) throws -> RuntimeEndpoint {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let typeID = runtimeTypeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw MuError.invalidTransition("Runtime display name is required.")
        }
        guard typeID.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._-]+/[A-Za-z0-9][A-Za-z0-9._-]+$"#,
            options: .regularExpression
        ) != nil else {
            throw MuError.invalidTransition(
                "Runtime type ID must look like vendor.runtime/adapter."
            )
        }
        guard provenance != .synthetic else {
            throw MuError.invalidTransition(
                "Synthetic provenance is reserved for Mu conformance fixtures."
            )
        }
        let existing = try store.fetchEndpoints()
        guard !existing.contains(where: {
            $0.displayName.compare(name, options: [.caseInsensitive, .diacriticInsensitive])
                == .orderedSame
        }) else {
            throw MuError.invalidTransition("A Runtime named “\(name)” already exists.")
        }
        let path = executablePath?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let userNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedInstanceLabel =
            instanceLabel.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        let normalizedTerminalIdentifier =
            terminalIdentifier.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        var guarantee =
            "Manually registered definition. No adapter probe has completed, so scheduling and "
            + "Task Run dispatch is disabled."
        if !userNotes.isEmpty {
            guarantee += " \(userNotes)"
        }
        var nativeConfiguration:
            [String: String] = [
                RuntimeIdentityConfigurationKey.surfaceKind:
                    surfaceKind.rawValue,
                RuntimeIdentityConfigurationKey.instanceLabel:
                    normalizedInstanceLabel.isEmpty
                    ? name
                    : normalizedInstanceLabel,
                RuntimeIdentityConfigurationKey.nativeSource:
                    "user_configured"
            ]
        nativeConfiguration[
            RuntimeIdentityConfigurationKey.permissionModelSource
        ] = "user_configured"
        if let path, !path.isEmpty {
            nativeConfiguration["executable"] = path
        }
        if !normalizedTerminalIdentifier.isEmpty {
            nativeConfiguration[
                RuntimeIdentityConfigurationKey
                    .terminalIdentifier
            ] = normalizedTerminalIdentifier
        }
        let normalizedModel = Self.normalizedRuntimeModel(defaultModel)
        let normalizedModels = Self.normalizedRuntimeModels(
            modelOptions,
            including: normalizedModel
        )
        if let normalizedModel {
            nativeConfiguration[
                RuntimeIdentityConfigurationKey.defaultModel
            ] = normalizedModel
        }
        if !normalizedModels.isEmpty {
            nativeConfiguration[
                RuntimeIdentityConfigurationKey.modelOptions
            ] = normalizedModels.joined(separator: ",")
        }
        let endpoint = RuntimeEndpoint(
            runtimeTypeID: typeID,
            displayName: name,
            adapterVersion: "unbound",
            runtimeVersion: "unverified",
            location: location,
            provenance: provenance,
            permissionModel: permissionModel,
            capabilities: [],
            status: .offline,
            guaranteeNote: guarantee,
            nativeConfiguration: nativeConfiguration
        )
        let actor = ProjectActorRecord(
            id: ProjectActorRecord.stableRuntimeActorID(
                endpointID: endpoint.id
            ),
            principalID: Self.localOwnerPrincipalID,
            kind: .agent,
            displayName:
                endpoint.resolvedInstanceIdentity
                .instanceLabel,
            runtimeEndpointID: endpoint.id
        )
        try store.withTransaction {
            try store.upsertEndpoint(endpoint)
            try store.upsertProjectActor(actor)
            try store.appendEvent(
                LedgerEvent(
                    type: "endpoint.created",
                    summary: "Manually registered Runtime “\(endpoint.displayName)”.",
                    payload: [
                        "endpoint_id": endpoint.id.uuidString,
                        "runtime_type_id": endpoint.runtimeTypeID,
                        "provenance": endpoint.provenance.rawValue
                    ]
                )
            )
        }
        try refreshRuntimeAdapterRegistrations()
        return endpoint
    }

    /// Updates the user-owned model and permission settings for one endpoint.
    /// The adapter's safety contract remains authoritative: the current
    /// Codex and Claude adapters still run read-only, even when a host's
    /// permission model is changed here. This lets the UI describe the host
    /// boundary without accidentally granting a write-capable turn.
    @discardableResult
    public func updateRuntimeSettings(
        endpointID: UUID,
        defaultModel: String?,
        modelOptions: [String],
        permissionModel: PermissionModel
    ) throws -> RuntimeEndpoint {
        guard var endpoint = try store.fetchRegisteredEndpoint(id: endpointID) else {
            throw MuError.recordNotFound("Runtime endpoint \(endpointID)")
        }
        let normalizedModel = Self.normalizedRuntimeModel(defaultModel)
        let normalizedModels = Self.normalizedRuntimeModels(
            modelOptions,
            including: normalizedModel
        )
        var configuration = endpoint.nativeConfiguration ?? [:]
        if let normalizedModel {
            configuration[RuntimeIdentityConfigurationKey.defaultModel] = normalizedModel
        } else {
            configuration.removeValue(
                forKey: RuntimeIdentityConfigurationKey.defaultModel
            )
        }
        if normalizedModels.isEmpty {
            configuration.removeValue(
                forKey: RuntimeIdentityConfigurationKey.modelOptions
            )
        } else {
            configuration[RuntimeIdentityConfigurationKey.modelOptions] =
                normalizedModels.joined(separator: ",")
        }
        configuration[RuntimeIdentityConfigurationKey.permissionModelSource] =
            "user_configured"
        endpoint.nativeConfiguration = configuration.isEmpty ? nil : configuration
        endpoint.permissionModel = permissionModel
        try store.withTransaction {
            try store.upsertEndpoint(endpoint)
            try store.appendEvent(
                LedgerEvent(
                    type: "endpoint.settings_updated",
                    summary: "Updated Runtime settings for “\(endpoint.displayName)”.",
                    payload: [
                        "endpoint_id": endpoint.id.uuidString,
                        "default_model": normalizedModel ?? "",
                        "model_options": normalizedModels.joined(separator: ","),
                        "permission_model": permissionModel.rawValue
                    ]
                )
            )
        }
        try refreshRuntimeAdapterRegistrations()
        return endpoint
    }

    private static func normalizedRuntimeModel(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizedRuntimeModels(
        _ values: [String],
        including defaultModel: String?
    ) -> [String] {
        var seen = Set<String>()
        var normalized = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        if let defaultModel, seen.insert(defaultModel).inserted {
            normalized.insert(defaultModel, at: 0)
        }
        return normalized
    }

    public func deleteEndpoint(id: UUID) throws {
        try store.withTransaction {
            guard let endpoint = try store.fetchRegisteredEndpoint(id: id) else {
                throw MuError.recordNotFound("Runtime endpoint \(id)")
            }
            let now = Date()
            let tasks = try store.fetchTasks().filter {
                $0.currentEndpointID == id
            }
            let runReferences = try store.fetchRuns().filter {
                $0.endpointID == id
            }.count
            let checkpointReferences = try store.fetchCheckpoints().filter {
                $0.sourceEndpointID == id
            }.count
            let referencedHandoffs = try store.fetchHandoffs().filter {
                $0.sourceEndpointID == id || $0.receiverEndpointID == id
            }
            let sessionBindingReferences = try store.fetchRuntimeSessionBindings().filter {
                $0.endpointID == id
            }.count
            let interactionReferences = try store.fetchRuntimeInteractions().filter {
                $0.endpointID == id
            }.count
            let runtimeArtifactReferences = try store.fetchRuntimeArtifacts().filter {
                $0.endpointID == id
            }.count
            let totalReferences =
                tasks.count + runReferences + checkpointReferences + referencedHandoffs.count
                + sessionBindingReferences + interactionReferences + runtimeArtifactReferences
            var agents = try store.fetchAgents().filter {
                $0.preferredEndpointID == id
            }
            for index in agents.indices {
                agents[index].preferredEndpointID = nil
            }
            for agent in agents { try store.upsertAgent(agent) }
            let runtimeActorID =
                ProjectActorRecord.stableRuntimeActorID(
                    endpointID: id
                )
            var affectedActorIDs =
                Set([runtimeActorID])
            var projectActors =
                try store.fetchProjectActors().filter {
                    $0.runtimeEndpointID == id
                }
            for index in projectActors.indices {
                affectedActorIDs.insert(
                    projectActors[index].id
                )
                if projectActors[index].id
                    == runtimeActorID {
                    projectActors[index].status = .retired
                } else {
                    projectActors[index]
                        .runtimeEndpointID = nil
                }
                projectActors[index].updatedAt = now
                try store.upsertProjectActor(
                    projectActors[index]
                )
            }
            var delegations =
                try store.fetchDelegations().filter {
                    affectedActorIDs.contains(
                        $0.agentActorID
                    )
                }
            for index in delegations.indices {
                delegations[index].status = .revoked
                delegations[index].updatedAt = now
                try store.upsertDelegation(
                    delegations[index]
                )
            }
            try store.upsertRegistryTombstone(
                RegistryTombstone(
                    id: id,
                    entityKind: .runtimeEndpoint,
                    displayName: endpoint.displayName,
                    deletedAt: now
                )
            )
            try store.appendEvent(
                LedgerEvent(
                    type: "endpoint.deleted",
                    summary:
                        "Removed Runtime “\(endpoint.displayName)” from the registry while preserving history.",
                    payload: [
                        "endpoint_id": id.uuidString,
                        "preserved_references": String(totalReferences),
                        "task_references": String(tasks.count),
                        "run_references": String(runReferences),
                        "checkpoint_references": String(checkpointReferences),
                        "handoff_references": String(referencedHandoffs.count),
                        "session_binding_references": String(sessionBindingReferences),
                        "interaction_references": String(interactionReferences),
                        "runtime_artifact_references": String(runtimeArtifactReferences),
                        "cleared_agent_preferences": String(agents.count),
                        "retired_or_detached_actors":
                            String(projectActors.count),
                        "revoked_delegations":
                            String(delegations.count)
                    ]
                )
            )
            for task in tasks {
                try store.appendEvent(
                    LedgerEvent(
                        taskID: task.id,
                        runID: task.currentRunID,
                        type: "task.runtime_removed",
                        summary:
                            "Runtime “\(endpoint.displayName)” was removed from scheduling; historical Task state is unchanged.",
                        payload: [
                            "endpoint_id": id.uuidString,
                            "endpoint_name": endpoint.displayName
                        ]
                    )
                )
            }
        }
    }

    @discardableResult
    public func probeCodexEndpoint(
        endpointID: UUID =
            ControlPlaneService.codexEndpointID
    ) throws -> RuntimeEndpoint {
        guard var endpoint = try store.fetchRegisteredEndpoint(id: endpointID),
              endpoint.runtimeTypeID
                == Self.codexRuntimeTypeID else {
            throw MuError.recordNotFound("Codex App Server endpoint")
        }
        guard endpoint.nativeConfiguration?["executable"] != nil else {
            throw MuError.commandFailed("Codex executable path is not registered.")
        }

        let client = try codexClient(for: endpoint)
        do {
            let result = try client.probe()
            endpoint.runtimeVersion = Self.codexVersion(from: result.userAgent)
            endpoint.status = result.signedIn ? .active : .degraded
            endpoint.capabilities = Self.codexImplementedCapabilities
            endpoint.adapterVersion = "0.4.0"
            endpoint.lastProbedAt = Date()
            endpoint.guaranteeNote = result.signedIn
                ? "Live official App Server connection verified on \(result.platformOS). "
                    + "Initial read-only Task runs and receiving Replans create persistent native "
                    + "threads and turns with event receipts. Local Git evidence is available. "
                    + "Exact-workspace read-only Workspace Chat continuation and interruption are exposed; "
                    + "writes and Runtime approval interception are not."
                : "App Server responded, but no signed-in account is available. Scheduling is disabled."
            let registration = RuntimeAdapterRegistration(
                endpointID: endpoint.id,
                manifest:
                    RuntimeGatewayRegistry.manifest(
                        for: endpoint
                    ),
                probedAt: endpoint.lastProbedAt
            )
            try store.withTransaction {
                guard try store.fetchRegisteredEndpoint(id: endpoint.id) != nil else {
                    throw MuError.recordNotFound("Codex App Server endpoint")
                }
                try store.upsertEndpoint(endpoint)
                try store.upsertRuntimeAdapterRegistration(
                    registration
                )
                if result.signedIn,
                   endpoint.id == Self.codexEndpointID,
                   var atlas = try store.fetchAgent(id: Self.atlasAgentID) {
                    atlas.preferredEndpointID = endpoint.id
                    try store.upsertAgent(atlas)
                }
                if result.signedIn,
                   endpoint.id == Self.codexEndpointID,
                   var relay = try store.fetchAgent(id: Self.relayAgentID) {
                    relay.preferredEndpointID = endpoint.id
                    try store.upsertAgent(relay)
                }
                try store.appendEvent(
                    LedgerEvent(
                        type: "adapter.probed",
                        summary: result.signedIn
                            ? "Verified live Codex App Server endpoint."
                            : "Codex App Server responded without an authenticated account.",
                        payload: [
                            "runtime_type_id": endpoint.runtimeTypeID,
                            "runtime_version": endpoint.runtimeVersion,
                            "signed_in": String(result.signedIn),
                            "observed_threads": String(result.observedThreadCount)
                        ]
                    )
                )
            }
            return endpoint
        } catch {
            endpoint.status = .degraded
            endpoint.lastProbedAt = Date()
            endpoint.guaranteeNote = "Probe failed: \(error.localizedDescription)"
            try? store.withTransaction {
                guard try store.fetchRegisteredEndpoint(id: endpoint.id) != nil else {
                    return
                }
                try store.upsertEndpoint(endpoint)
                try store.appendEvent(
                    LedgerEvent(
                        type: "adapter.probe_failed",
                        summary: "Codex App Server capability probe failed.",
                        payload: [
                            "runtime_type_id": endpoint.runtimeTypeID,
                            "error": error.localizedDescription
                        ]
                    )
                )
            }
            throw error
        }
    }

    @discardableResult
    public func probeClaudeCodeEndpoint(
        endpointID: UUID =
            ControlPlaneService.claudeCodeEndpointID
    ) throws -> RuntimeEndpoint {
        guard var endpoint = try store.fetchRegisteredEndpoint(
            id: endpointID
        ), endpoint.runtimeTypeID
            == Self.claudeCodeRuntimeTypeID else {
            throw MuError.recordNotFound(
                "Claude Code CLI endpoint"
            )
        }
        guard let path = endpoint.nativeConfiguration?[
            "executable"
        ] else {
            throw MuError.commandFailed(
                "Claude Code executable path is not registered."
            )
        }
        let client = ClaudeCodeClient(
            executableURL: URL(fileURLWithPath: path)
        )
        do {
            let result = try client.probe()
            endpoint.runtimeVersion = result.version
            endpoint.status =
                result.loggedIn ? .active : .degraded
            endpoint.capabilities = result.loggedIn
                ? Self.claudeCodeImplementedCapabilities
                : []
            if (endpoint.nativeConfiguration?[
                RuntimeIdentityConfigurationKey.permissionModelSource
            ] ?? "") != "user_configured" {
                endpoint.permissionModel = .promptGate
            }
            endpoint.provenance = .vendorCLI
            endpoint.adapterVersion = "0.1.0"
            endpoint.lastProbedAt = Date()
            endpoint.guaranteeNote = result.loggedIn
                ? "Verified Claude Code CLI \(result.version). Mu can "
                    + "launch and resume exact-workspace read-only "
                    + "stream-json sessions, mirror visible output, "
                    + "interrupt Mu-launched processes, and publish "
                    + "reviewable artifacts."
                : "Claude Code CLI responded, but its current local "
                    + "authentication is unavailable. Sign in from "
                    + "Claude Code, then re-probe."
            var configuration =
                endpoint.nativeConfiguration ?? [:]
            configuration["auth_method"] = result.authMethod
            configuration["api_provider"] = result.apiProvider
            endpoint.nativeConfiguration = configuration
            let registration = RuntimeAdapterRegistration(
                endpointID: endpoint.id,
                manifest:
                    RuntimeGatewayRegistry.manifest(
                        for: endpoint
                    ),
                probedAt: endpoint.lastProbedAt
            )
            try store.withTransaction {
                guard try store.fetchRegisteredEndpoint(
                    id: endpoint.id
                ) != nil else {
                    throw MuError.recordNotFound(
                        "Claude Code CLI endpoint"
                    )
                }
                try store.upsertEndpoint(endpoint)
                try store.upsertRuntimeAdapterRegistration(
                    registration
                )
                try store.appendEvent(
                    LedgerEvent(
                        type: "adapter.probed",
                        summary: result.loggedIn
                            ? "Verified live Claude Code CLI endpoint."
                            : "Claude Code CLI responded without active authentication.",
                        payload: [
                            "runtime_type_id":
                                endpoint.runtimeTypeID,
                            "runtime_version":
                                result.version,
                            "signed_in":
                                String(result.loggedIn),
                            "auth_method":
                                result.authMethod,
                            "api_provider":
                                result.apiProvider,
                            "gateway_contract_version": "1"
                        ]
                    )
                )
            }
            return endpoint
        } catch {
            endpoint.status = .degraded
            endpoint.capabilities = []
            endpoint.lastProbedAt = Date()
            endpoint.guaranteeNote =
                "Claude Code CLI probe failed. "
                + error.localizedDescription
            try? store.withTransaction {
                guard try store.fetchRegisteredEndpoint(
                    id: endpoint.id
                ) != nil else {
                    return
                }
                try store.upsertEndpoint(endpoint)
                try store.upsertRuntimeAdapterRegistration(
                    RuntimeAdapterRegistration(
                        endpointID: endpoint.id,
                        manifest:
                            RuntimeGatewayRegistry.manifest(
                                for: endpoint
                            ),
                        probedAt: endpoint.lastProbedAt
                    )
                )
                try store.appendEvent(
                    LedgerEvent(
                        type: "adapter.probe_failed",
                        summary:
                            "Claude Code CLI capability probe failed.",
                        payload: [
                            "runtime_type_id":
                                endpoint.runtimeTypeID,
                            "error":
                                error.localizedDescription
                        ]
                    )
                )
            }
            throw error
        }
    }

    @discardableResult
    public func probeOpenWorkerEndpoint() async throws -> RuntimeEndpoint {
        guard var endpoint = try store.fetchRegisteredEndpoint(id: Self.openWorkerEndpointID) else {
            throw MuError.recordNotFound("OpenWorker Desktop endpoint")
        }

        do {
            guard OpenWorkerDiscovery.discover() != nil else {
                throw MuError.commandFailed("OpenWorker Desktop is not installed.")
            }
            guard let baseURL = OpenWorkerSidecarLocator.discoverBaseURL() else {
                throw MuError.commandFailed(
                    "OpenWorker is not running or its loopback sidecar port could not be discovered."
                )
            }
            let configuration = try OpenWorkerClientConfiguration(baseURL: baseURL)
            let result = try await OpenWorkerHTTPClient(
                configuration: configuration
            ).probe()
            guard result.status == "ok" else {
                throw MuError.commandFailed(
                    "OpenWorker health returned \(result.status)."
                )
            }

            endpoint.status = .active
            endpoint.capabilities = Self.openWorkerImplementedCapabilities
            if (endpoint.nativeConfiguration?[
                RuntimeIdentityConfigurationKey.permissionModelSource
            ] ?? "") != "user_configured" {
                endpoint.permissionModel = .promptGate
            }
            endpoint.provenance = .vendorProtocol
            endpoint.adapterVersion = "0.5.0"
            endpoint.lastProbedAt = Date()
            endpoint.guaranteeNote =
                "Verified the official OpenWorker session protocol on tokenless "
                + "127.0.0.1 compatibility mode. Workspace Chat can link or continue "
                + "native sessions, mirror live progress and messages, surface approve-once/"
                + "deny requests, interrupt a turn, and reconcile artifacts. No approval is automatic."
            var nativeConfiguration = endpoint.nativeConfiguration ?? [:]
            nativeConfiguration["base_url"] = result.baseURL.absoluteString
            nativeConfiguration["connection_mode"] = "legacy_loopback"
            nativeConfiguration["default_agent"] = result.defaultAgent
            // Preserve an explicit user choice; only seed the host-reported
            // model when this endpoint has never been configured.
            if nativeConfiguration[RuntimeIdentityConfigurationKey.defaultModel]?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                nativeConfiguration[RuntimeIdentityConfigurationKey.defaultModel] = result.model
            }
            endpoint.nativeConfiguration = nativeConfiguration

            try store.withTransaction {
                guard try store.fetchRegisteredEndpoint(id: endpoint.id) != nil else {
                    throw MuError.recordNotFound("OpenWorker Desktop endpoint")
                }
                try store.upsertEndpoint(endpoint)
                try store.appendEvent(
                    LedgerEvent(
                        type: "adapter.probed",
                        summary: "Verified the live OpenWorker Desktop session endpoint.",
                        payload: [
                            "runtime_type_id": endpoint.runtimeTypeID,
                            "runtime_version": endpoint.runtimeVersion,
                            "base_url": result.baseURL.absoluteString,
                            "connection_mode": "legacy_loopback",
                            "default_agent": result.defaultAgent,
                            "default_model": result.model,
                            "observed_sessions": String(result.sessionCount)
                        ]
                    )
                )
            }
            return endpoint
        } catch {
            endpoint.status = .degraded
            endpoint.capabilities = []
            if (endpoint.nativeConfiguration?[
                RuntimeIdentityConfigurationKey.permissionModelSource
            ] ?? "") != "user_configured" {
                endpoint.permissionModel = .unknown
            }
            endpoint.lastProbedAt = Date()
            endpoint.guaranteeNote =
                "OpenWorker protocol probe failed. Mu will not route messages until a "
                + "loopback session endpoint is verified. \(error.localizedDescription)"
            try? store.withTransaction {
                guard try store.fetchRegisteredEndpoint(id: endpoint.id) != nil else {
                    return
                }
                try store.upsertEndpoint(endpoint)
                try store.appendEvent(
                    LedgerEvent(
                        type: "adapter.probe_failed",
                        summary: "OpenWorker Desktop capability probe failed.",
                        payload: [
                            "runtime_type_id": endpoint.runtimeTypeID,
                            "error": error.localizedDescription
                        ]
                    )
                )
            }
            throw error
        }
    }

    public func listOpenWorkerSessions(
        workspace: String? = nil
    ) async throws -> [OpenWorkerSessionSummary] {
        let endpoint = try activeOpenWorkerEndpoint()
        let configuration = try openWorkerConfiguration(for: endpoint)
        return try await OpenWorkerHTTPClient(
            configuration: configuration
        ).sessions(workspace: workspace)
    }

    @discardableResult
    public func dispatchCodexTask(
        runID: UUID,
        workspaceEntryID: UUID? = nil
    ) throws -> CodexTurnResult {
        guard var initialRun = try store.fetchRun(id: runID) else {
            throw MuError.recordNotFound("Run \(runID)")
        }
        guard initialRun.purpose == .execution else {
            throw MuError.invalidTransition("Only an execution Run can start a Codex Task.")
        }
        guard initialRun.state == .starting,
              initialRun.nativeThreadID == nil,
              initialRun.nativeTurnID == nil else {
            throw MuError.invalidTransition(
                "This Codex Run is not safely dispatchable. Existing native identity is never retried automatically."
            )
        }
        guard let endpoint = try store.fetchRegisteredEndpoint(id: initialRun.endpointID),
              endpoint.runtimeTypeID == Self.codexRuntimeTypeID,
              endpoint.status == .active,
              endpoint.capabilities.contains(.start) else {
            throw MuError.capabilityMissing("The live Codex Start capability is not active.")
        }
        guard endpoint.nativeConfiguration?["executable"] != nil else {
            throw MuError.commandFailed("Codex executable path is not registered.")
        }
        guard var task = try store.fetchTask(id: initialRun.taskID),
              task.currentRunID == initialRun.id else {
            throw MuError.invalidTransition("The Codex Run is not the Task's current Run.")
        }
        var workspaceEntry = try workspaceEntryID.flatMap {
            try store.fetchChatEntry(id: $0)
        }
        if let workspaceEntry {
            guard workspaceEntry.taskID == task.id,
                  workspaceEntry.targetEndpointID == initialRun.endpointID,
                  workspaceEntry.runID == initialRun.id,
                  workspaceEntry.runtimeSessionBindingID == nil,
                  workspaceEntry.deliveryState == .awaitingSession else {
                throw MuError.invalidTransition(
                    "The Codex Workspace message is not waiting for its initial session."
                )
            }
        }
        let agent = try initialRun.agentIdentityID.flatMap { try store.fetchAgent(id: $0) }
        try RuntimeGatewayRegistry.require(
            .createSession,
            endpoint: endpoint
        )
        let kernel = try projectKernelContext(taskID: task.id)
        guard let actorID = kernel.actor?.id else {
            throw MuError.invalidTransition(
                "Codex has no authorized Project Actor."
            )
        }
        let bindingID = UUID()
        let lease = try claimTaskLease(
            taskID: task.id,
            endpointID: endpoint.id,
            actorID: actorID,
            runtimeBindingID: bindingID,
            duration: 30 * 60
        )
        let contextPack = try buildGovernedContextPack(
            taskID: task.id,
            actorID: actorID,
            endpointID: endpoint.id,
            runtimeBindingID: bindingID,
            taskLeaseID: lease.id
        )
        let promptPreferences = runtimePromptPreferences
        let initialPrompt = RuntimePromptPreferences.taskPrompt(
            contextPack: contextPack.renderedMarkdown,
            projectMessage: workspaceEntry.map {
                $0.routedText ?? $0.text
            },
            additionalInstructions:
                promptPreferences.codexAdditionalInstructions
        )
        let provisionalBinding = RuntimeSessionBinding(
            id: bindingID,
            taskID: task.id,
            projectID: kernel.project.id,
            workspaceID: kernel.workspace.id,
            actorID: actorID,
            principalID: kernel.principal?.id,
            taskLeaseID: lease.id,
            runID: initialRun.id,
            contextPackID: contextPack.id,
            endpointID: endpoint.id,
            agentIdentityID: initialRun.agentIdentityID,
            nativeSessionID:
                "pending-\(bindingID.uuidString.lowercased())",
            nativeAgentName:
                agent?.displayName ?? "Codex",
            workspacePath:
                kernel.workspace.repositoryPath,
            connectionMode:
                "official_app_server_stdio",
            state: .connecting,
            lastActivitySummary:
                "Preparing a governed Codex Project turn."
        )
        let responseEntry = ChatEntry(
            taskID: task.id,
            agentIdentityID: agent?.id,
            runID: initialRun.id,
            runtimeSessionBindingID: bindingID,
            deliveryState: .routing,
            authorKind: .agent,
            authorName:
                agent?.displayName ?? endpoint.displayName,
            text: "Starting Codex…"
        )
        if var entry = workspaceEntry {
            entry.runtimeSessionBindingID = bindingID
            entry.nativeMessageIndexLowerBound = provisionalBinding.lastSyncedMessageCount
            entry.deliveryState = .sending
            entry.updatedAt = Date()
            workspaceEntry = entry
        }
        initialRun.projectID = kernel.project.id
        initialRun.workspaceID = kernel.workspace.id
        initialRun.actorID = actorID
        initialRun.principalID = kernel.principal?.id
        initialRun.taskLeaseID = lease.id
        initialRun.contextPackID = contextPack.id
        initialRun.updatedAt = Date()
        task.projectID = kernel.project.id
        task.workspaceID = kernel.workspace.id
        task.assignedActorID = actorID
        task.status = .running
        task.updatedAt = Date()
        do {
            try store.withTransaction {
                try store.upsertRun(initialRun)
                try store.upsertTask(task)
                try store.upsertRuntimeSessionBinding(
                    provisionalBinding
                )
                if let workspaceEntry {
                    try store.upsertChatEntry(workspaceEntry)
                }
                try store.insertChatEntry(responseEntry)
                try store.appendEvent(
                    LedgerEvent(
                        projectID: kernel.project.id,
                        actorID: kernel.actor?.id,
                        principalID: kernel.principal?.id,
                        workspaceID: kernel.workspace.id,
                        taskID: task.id,
                        runID: initialRun.id,
                        type: "codex.task.dispatching",
                        summary:
                            "Dispatching a native read-only Task to Codex App Server.",
                        payload: [
                            "sandbox": "read-only",
                            "network_access": "false",
                            "approval_policy": "never",
                            "client_user_message_id":
                                initialRun.id.uuidString,
                            "lease_id": lease.id.uuidString,
                            "context_pack_id":
                                contextPack.id.uuidString
                        ]
                    )
                )
            }
        } catch {
            _ = try? releaseTaskLease(id: lease.id)
            throw error
        }

        let client = try codexClient(for: endpoint)
        codexRuntimeLock.withLock {
            activeCodexClients[runID] = client
        }
        defer {
            _ = codexRuntimeLock.withLock {
                activeCodexClients.removeValue(forKey: runID)
            }
        }
        let mirror = ClaudeCodeOutputMirror {
            [weak self] text, force in
            guard let self else { return }
            try? self.persistClaudeCodeVisibleText(
                entryID: responseEntry.id,
                bindingID: bindingID,
                text: text,
                force: force,
                runtimeName: "Codex"
            )
        }
        let activityTaskID = initialRun.taskID
        do {
            try recordContextDelivery(
                projectID: kernel.project.id,
                packID: contextPack.id,
                status: .prepared
            )
            let result = try client.runReadOnlyTask(
                task: task,
                agent: agent,
                contextPack: contextPack,
                promptOverride: initialPrompt,
                additionalInstructions:
                    promptPreferences.codexAdditionalInstructions,
                clientUserMessageID: initialRun.id.uuidString,
                model: workspaceEntry?.requestedModel
                    ?? endpoint.configuredDefaultModel,
                onThreadStarted: { [store] threadID in
                    guard var stagedRun = try store.fetchRun(id: runID) else {
                        throw MuError.recordNotFound("Run \(runID)")
                    }
                    if let existing = stagedRun.nativeThreadID, existing != threadID {
                        throw MuError.invalidTransition("Codex returned a conflicting native thread ID.")
                    }
                    stagedRun.nativeThreadID = threadID
                    stagedRun.updatedAt = Date()
                    var stagedLease =
                        try store.fetchTaskLease(id: lease.id)
                        ?? lease
                    stagedLease.runtimeBindingID = bindingID
                    stagedLease.lastHeartbeatAt = Date()
                    guard var binding =
                        try store.fetchRuntimeSessionBinding(
                            id: bindingID
                        ) else {
                        throw MuError.recordNotFound(
                            "Prepared Codex Runtime binding"
                        )
                    }
                    binding.nativeSessionID = threadID
                    binding.state = .connecting
                    binding.lastActivitySummary =
                        "Codex created a persistent Project thread."
                    binding.updatedAt = Date()
                    try store.withTransaction {
                        try store.upsertRun(stagedRun)
                        try store.upsertTaskLease(stagedLease)
                        try store.upsertRuntimeSessionBinding(
                            binding
                        )
                        try store.appendEvent(
                            LedgerEvent(
                                projectID: kernel.project.id,
                                actorID: kernel.actor?.id,
                                principalID: kernel.principal?.id,
                                workspaceID: kernel.workspace.id,
                                taskID: stagedRun.taskID,
                                runID: stagedRun.id,
                                type: "codex.thread.started",
                                summary: "Codex created the persistent native Task thread.",
                                payload: ["native_thread_id": threadID]
                            )
                        )
                    }
                },
                onTurnStarted: { [store] threadID, turnID in
                    guard var stagedRun = try store.fetchRun(id: runID) else {
                        throw MuError.recordNotFound("Run \(runID)")
                    }
                    guard stagedRun.nativeThreadID == threadID else {
                        throw MuError.invalidTransition("Codex turn does not match the recorded thread.")
                    }
                    if let existing = stagedRun.nativeTurnID, existing != turnID {
                        throw MuError.invalidTransition("Codex returned a conflicting native turn ID.")
                    }
                    stagedRun.nativeTurnID = turnID
                    stagedRun.state = .active
                    stagedRun.updatedAt = Date()
                    guard var binding =
                        try store
                        .fetchRuntimeSessionBinding(
                            id: bindingID
                        ) else {
                        throw MuError.recordNotFound(
                            "Codex Runtime binding"
                        )
                    }
                    binding.state = .working
                    binding.lastActivitySummary =
                        "Codex is working in the bounded Project workspace."
                    binding.updatedAt = Date()
                    try store.withTransaction {
                        try store.upsertRun(stagedRun)
                        try store.upsertRuntimeSessionBinding(
                            binding
                        )
                        try store.appendEvent(
                            LedgerEvent(
                                projectID: kernel.project.id,
                                actorID: kernel.actor?.id,
                                principalID: kernel.principal?.id,
                                workspaceID: kernel.workspace.id,
                                taskID: stagedRun.taskID,
                                runID: stagedRun.id,
                                type: "codex.turn.started",
                                summary: "Codex started the native read-only Task turn.",
                                payload: [
                                    "native_thread_id": threadID,
                                    "native_turn_id": turnID
                                ]
                            )
                        )
                    }
                    try self.recordContextDelivery(
                        projectID: kernel.project.id,
                        packID: contextPack.id,
                        status: .delivered,
                        adapterReceiptMaterial:
                            "codex-app-server|\(threadID)|\(turnID)"
                    )
                },
                onVisibleText: { text in
                    mirror.offer(text)
                },
                onActivity: { [weak self] activity in
                    guard let self else { return }
                    try? self.persistRuntimeActivity(
                        activity,
                        taskID: activityTaskID,
                        runID: runID,
                        projectID: kernel.project.id,
                        workspaceID: kernel.workspace.id,
                        bindingID: bindingID
                    )
                }
            )
            mirror.finish(result.output)

            guard var run = try store.fetchRun(id: runID) else {
                throw MuError.recordNotFound("Run \(runID)")
            }
            run.nativeThreadID = result.threadID
            run.nativeTurnID = result.turnID
            run.nativeOutput = result.output.isEmpty ? nil : result.output
            run.plan = Self.planLines(from: result.output)
            switch result.status {
            case "completed":
                run.state = .completed
                task.status = .completed
            case "interrupted":
                run.state = .cancelled
                task.status = .cancelled
            case "failed":
                run.state = .failed
                task.status = .failed
            default:
                run.state = .ambiguous
                task.status = .blocked
            }
            let now = Date()
            run.updatedAt = now
            task.updatedAt = now
            var binding = try store.fetchRuntimeSessionBinding(
                id: bindingID
            )
            binding?.state = result.status == "completed"
                ? .completed
                : result.status == "interrupted"
                    ? .disconnected
                    : .failed
            binding?.lastActivitySummary =
                result.status == "completed"
                ? "Codex completed the native turn."
                : "Codex ended with status \(result.status)."
            binding?.lastError = result.errorMessage
            binding?.updatedAt = now

            let projectArtifact =
                result.output.isEmpty
                ? nil
                : try submitRuntimeOutputArtifact(
                    taskID: task.id,
                    producerActorID: kernel.actor?.id,
                    title: "Codex result · \(task.title)",
                    output: result.output,
                    metadata: [
                        "provider":
                            ConversationProvider.codex.rawValue,
                        "native_thread_id": result.threadID,
                        "native_turn_id": result.turnID
                    ]
                )
            var chatEntry =
                try store.fetchChatEntry(
                    id: responseEntry.id
                ) ?? responseEntry
            chatEntry.text = result.output.isEmpty
                ? "Codex ended with status \(result.status)."
                : result.output
            chatEntry.deliveryState =
                result.status == "completed"
                ? .mirrored
                : result.status == "interrupted"
                    ? .cancelled
                    : result.status == "failed"
                        ? .failed
                        : .ambiguous
            chatEntry.updatedAt = now
            var finalWorkspaceEntry: ChatEntry?
            if var workspaceEntry = workspaceEntryID.flatMap({
                try? store.fetchChatEntry(id: $0)
            }) ?? workspaceEntry {
                workspaceEntry.runtimeSessionBindingID = binding?.id
                workspaceEntry.deliveryState = result.status == "completed"
                    ? .delivered
                    : result.status == "interrupted"
                        ? .cancelled
                        : .failed
                workspaceEntry.updatedAt = now
                finalWorkspaceEntry = workspaceEntry
            }
            try store.withTransaction {
                guard try store.fetchRegisteredEndpoint(id: endpoint.id) != nil else {
                    throw MuError.recordNotFound("Codex App Server endpoint")
                }
                try store.upsertRun(run)
                try store.upsertTask(task)
                if let binding {
                    try store.upsertRuntimeSessionBinding(
                        binding
                    )
                }
                if let workspaceEntry = finalWorkspaceEntry {
                    try store.upsertChatEntry(workspaceEntry)
                }
                try store.upsertChatEntry(chatEntry)
                try store.appendEvent(
                    LedgerEvent(
                        projectID: kernel.project.id,
                        actorID: kernel.actor?.id,
                        principalID: kernel.principal?.id,
                        workspaceID: kernel.workspace.id,
                        artifactID: projectArtifact?.id,
                        taskID: task.id,
                        runID: run.id,
                        type: "codex.turn.completed",
                        summary: result.status == "completed"
                            ? "Codex completed the native read-only Task turn."
                            : "Codex ended the native Task turn with status \(result.status).",
                        payload: [
                            "native_thread_id": result.threadID,
                            "native_turn_id": result.turnID,
                            "native_status": result.status,
                            "history_reconciled": String(result.historyReconciled),
                            "output_uri":
                                projectArtifact?.uri ?? "",
                            "output_sha256":
                                projectArtifact?.sha256 ?? "",
                            "error": result.errorMessage ?? ""
                        ]
                    )
                )
            }
            _ = try? releaseTaskLease(id: lease.id)
            return result
        } catch {
            if var run = try? store.fetchRun(id: runID),
               var failedTask = try? store.fetchTask(id: initialRun.taskID) {
                let hasNativeIdentity = run.nativeThreadID != nil || run.nativeTurnID != nil
                run.state = hasNativeIdentity ? .ambiguous : .failed
                failedTask.status = hasNativeIdentity ? .blocked : .failed
                let now = Date()
                run.updatedAt = now
                failedTask.updatedAt = now
                var failedBinding:
                    RuntimeSessionBinding?
                failedBinding =
                    try? store.fetchRuntimeSessionBinding(
                        id: bindingID
                    )
                if var binding = failedBinding {
                    binding.state = .failed
                    binding.lastError =
                        error.localizedDescription
                    binding.lastActivitySummary =
                        "Codex dispatch failed."
                    binding.updatedAt = now
                    failedBinding = binding
                }
                var failedEntry =
                    try? store.fetchChatEntry(
                        id: responseEntry.id
                    )
                if var entry = failedEntry {
                    entry.deliveryState =
                        hasNativeIdentity
                        ? .ambiguous
                        : .failed
                    entry.text = hasNativeIdentity
                        ? "Codex stopped after creating native state: "
                            + error.localizedDescription
                        : "Codex failed: "
                            + error.localizedDescription
                    entry.updatedAt = now
                    failedEntry = entry
                }
                var failedWorkspaceEntry: ChatEntry?
                if var workspaceEntry = workspaceEntryID.flatMap({
                    try? store.fetchChatEntry(id: $0)
                }) ?? workspaceEntry {
                    workspaceEntry.runtimeSessionBindingID = failedBinding?.id
                    workspaceEntry.deliveryState = hasNativeIdentity
                        ? .ambiguous
                        : .failed
                    workspaceEntry.updatedAt = now
                    failedWorkspaceEntry = workspaceEntry
                }
                try? store.withTransaction {
                    try store.upsertRun(run)
                    try store.upsertTask(failedTask)
                    if let binding = failedBinding {
                        try store.upsertRuntimeSessionBinding(
                            binding
                        )
                    }
                    if let failedEntry {
                        try store.upsertChatEntry(
                            failedEntry
                        )
                    }
                    if let failedWorkspaceEntry {
                        try store.upsertChatEntry(failedWorkspaceEntry)
                    }
                    try store.appendEvent(
                        LedgerEvent(
                            projectID: kernel.project.id,
                            actorID: kernel.actor?.id,
                            principalID: kernel.principal?.id,
                            workspaceID: kernel.workspace.id,
                            taskID: failedTask.id,
                            runID: run.id,
                            type: "codex.task.failed",
                            summary: hasNativeIdentity
                                ? "Codex dispatch ended ambiguously after native identity was recorded."
                                : "Codex dispatch failed before native identity was created.",
                            payload: [
                                "native_thread_id": run.nativeThreadID ?? "",
                                "native_turn_id": run.nativeTurnID ?? "",
                                "automatic_retry": "disabled",
                                "error": error.localizedDescription
                            ]
                        )
                    )
                }
            }
            _ = try? recordContextDelivery(
                projectID: kernel.project.id,
                packID: contextPack.id,
                status: .failed,
                failureCode: "codex_runtime_dispatch_failed"
            )
            _ = try? releaseTaskLease(id: lease.id)
            throw error
        }
    }

    @discardableResult
    public func dispatchCodexReplan(runID: UUID) throws -> CodexReplanResult {
        guard var run = try store.fetchRun(id: runID) else {
            throw MuError.recordNotFound("Run \(runID)")
        }
        guard run.purpose == .replan else {
            throw MuError.invalidTransition("Only a Replan Run can dispatch to Codex.")
        }
        guard let endpoint = try store.fetchRegisteredEndpoint(id: run.endpointID),
              endpoint.runtimeTypeID == Self.codexRuntimeTypeID,
              endpoint.status == .active else {
            throw MuError.capabilityMissing("The live Codex endpoint is not active.")
        }
        guard endpoint.nativeConfiguration?["executable"] != nil else {
            throw MuError.commandFailed("Codex executable path is not registered.")
        }
        guard let task = try store.fetchTask(id: run.taskID) else {
            throw MuError.recordNotFound("Task \(run.taskID)")
        }
        guard let handoff = try store.fetchHandoffs(taskID: task.id).first(where: {
            $0.status == .accepted && $0.receiverEndpointID == endpoint.id
        }),
        let checkpoint = try store.fetchCheckpoint(id: handoff.checkpointID) else {
            throw MuError.recordNotFound("Accepted Codex Handoff Checkpoint")
        }

        try store.withTransaction {
            guard try store.fetchRegisteredEndpoint(id: endpoint.id) != nil else {
                throw MuError.recordNotFound("Codex App Server endpoint")
            }
            try store.appendEvent(
                LedgerEvent(
                    taskID: task.id,
                    runID: run.id,
                    type: "codex.replan.dispatching",
                    summary: "Dispatching a read-only Replan to Codex App Server.",
                    payload: [
                        "sandbox": "read-only",
                        "approval_policy": "never",
                        "checkpoint_hash": checkpoint.contentHash
                    ]
                )
            )
        }

        let client = try codexClient(for: endpoint)
        do {
            let result = try client.runReadOnlyReplan(
                checkpoint: checkpoint,
                task: task,
                onThreadStarted: { [store] threadID in
                    guard var stagedRun = try store.fetchRun(id: runID) else {
                        throw MuError.recordNotFound("Run \(runID)")
                    }
                    stagedRun.nativeThreadID = threadID
                    stagedRun.updatedAt = Date()
                    try store.withTransaction {
                        try store.upsertRun(stagedRun)
                        try store.appendEvent(
                            LedgerEvent(
                                taskID: stagedRun.taskID,
                                runID: stagedRun.id,
                                type: "codex.thread.started",
                                summary: "Codex created the persistent receiving Replan thread.",
                                payload: ["native_thread_id": threadID]
                            )
                        )
                    }
                },
                onTurnStarted: { [store] threadID, turnID in
                    guard var stagedRun = try store.fetchRun(id: runID),
                          stagedRun.nativeThreadID == threadID else {
                        throw MuError.invalidTransition(
                            "Codex Replan turn does not match the recorded thread."
                        )
                    }
                    stagedRun.nativeTurnID = turnID
                    stagedRun.updatedAt = Date()
                    try store.withTransaction {
                        try store.upsertRun(stagedRun)
                        try store.appendEvent(
                            LedgerEvent(
                                taskID: stagedRun.taskID,
                                runID: stagedRun.id,
                                type: "codex.turn.started",
                                summary: "Codex started the native receiving Replan turn.",
                                payload: [
                                    "native_thread_id": threadID,
                                    "native_turn_id": turnID
                                ]
                            )
                        )
                    }
                }
            )
            run = try store.fetchRun(id: runID) ?? run
            run.nativeThreadID = result.threadID
            run.nativeTurnID = result.turnID
            run.nativeOutput = result.output
            run.plan = Self.planLines(from: result.output)
            run.state = result.status == "completed" ? .active : .degraded
            run.updatedAt = Date()
            try store.withTransaction {
                guard try store.fetchRegisteredEndpoint(id: endpoint.id) != nil else {
                    throw MuError.recordNotFound("Codex App Server endpoint")
                }
                try store.upsertRun(run)
                try store.appendEvent(
                    LedgerEvent(
                        taskID: task.id,
                        runID: run.id,
                        type: "codex.replan.completed",
                        summary: "Codex returned a sealed read-only Replan.",
                        payload: [
                            "native_thread_id": result.threadID,
                            "native_turn_id": result.turnID,
                            "native_status": result.status
                        ]
                    )
                )
            }
            return result
        } catch {
            run = (try? store.fetchRun(id: runID)) ?? run
            run.state = run.nativeThreadID == nil && run.nativeTurnID == nil
                ? .degraded
                : .ambiguous
            run.updatedAt = Date()
            try? store.withTransaction {
                guard try store.fetchRegisteredEndpoint(id: endpoint.id) != nil else {
                    return
                }
                try store.upsertRun(run)
                try store.appendEvent(
                    LedgerEvent(
                        taskID: task.id,
                        runID: run.id,
                        type: "codex.replan.failed",
                        summary: "Codex Replan could not be completed.",
                        payload: [
                            "native_thread_id": run.nativeThreadID ?? "",
                            "native_turn_id": run.nativeTurnID ?? "",
                            "automatic_retry": "disabled",
                            "error": error.localizedDescription
                        ]
                    )
                )
            }
            throw error
        }
    }

    @discardableResult
    public func createTask(
        title: String,
        objective: String,
        successCriteria: [String],
        constraints: [String],
        pendingSteps: [String],
        repositoryPath: String,
        sourceEndpointID: UUID,
        agentIdentityID: UUID? = nil
    ) throws -> TaskRecord {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MuError.invalidTransition("Task title is required.")
        }
        guard !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MuError.invalidTransition("Task objective is required.")
        }
        guard let endpoint = try store.fetchRegisteredEndpoint(id: sourceEndpointID) else {
            throw MuError.recordNotFound("Source endpoint \(sourceEndpointID)")
        }
        guard endpoint.status == .active else {
            throw MuError.capabilityMissing("The source endpoint is not active.")
        }
        guard endpoint.capabilities.contains(.start),
              endpoint.provenance != .artifactOnly else {
            throw MuError.capabilityMissing(
                "The source endpoint does not expose a verified Start capability."
            )
        }
        if RuntimeGatewayRegistry.adapter(for: endpoint) != nil {
            try RuntimeGatewayRegistry.require(
                .createSession,
                endpoint: endpoint
            )
        }
        let agent: AgentIdentity?
        if let agentIdentityID {
            guard let registeredAgent = try store.fetchAgent(id: agentIdentityID) else {
                throw MuError.recordNotFound("Agent identity \(agentIdentityID)")
            }
            agent = registeredAgent
        } else {
            agent = nil
        }

        var run = RunRecord(
            taskID: UUID(),
            endpointID: sourceEndpointID,
            actorName: agent?.displayName ?? endpoint.displayName,
            purpose: .execution,
            state: endpoint.runtimeTypeID == Self.codexRuntimeTypeID
                || endpoint.runtimeTypeID == Self.claudeCodeRuntimeTypeID
                || endpoint.runtimeTypeID == Self.openWorkerRuntimeTypeID
                ? .starting
                : .active,
            agentIdentityID: agent?.id
        )
        var task = TaskRecord(
            id: run.taskID,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            objective: objective.trimmingCharacters(in: .whitespacesAndNewlines),
            successCriteria: successCriteria.filter { !$0.isEmpty },
            constraints: constraints.filter { !$0.isEmpty },
            pendingSteps: pendingSteps.filter { !$0.isEmpty },
            repositoryPath: URL(fileURLWithPath: repositoryPath).standardizedFileURL.path,
            status: .running,
            currentEndpointID: sourceEndpointID,
            currentRunID: run.id,
            assignedAgentIdentityID: agent?.id
        )
        task.updatedAt = task.createdAt
        let assignmentText: String
        if endpoint.runtimeTypeID == Self.codexRuntimeTypeID, let agent {
            assignmentText =
                "\(agent.displayName) is assigned through \(endpoint.displayName). "
                + "A read-only native Codex thread and turn will be dispatched; their IDs and "
                + "final output are recorded as runtime evidence."
        } else if endpoint.runtimeTypeID == Self.codexRuntimeTypeID {
            assignmentText =
                "Task queued through \(endpoint.displayName). A read-only native Codex thread "
                + "and turn will be dispatched and recorded as runtime evidence."
        } else if endpoint.runtimeTypeID == Self.claudeCodeRuntimeTypeID,
                  let agent {
            assignmentText =
                "\(agent.displayName) is assigned through \(endpoint.displayName). "
                + "Mu will launch a read-only Claude Code CLI session, mirror visible "
                + "stream-json output, and preserve its session receipt."
        } else if endpoint.runtimeTypeID
                    == Self.claudeCodeRuntimeTypeID {
            assignmentText =
                "Task queued through \(endpoint.displayName). Mu will launch a "
                + "read-only native CLI session and preserve its session receipt."
        } else if endpoint.runtimeTypeID == Self.openWorkerRuntimeTypeID, let agent {
            assignmentText =
                "\(agent.displayName) is assigned through \(endpoint.displayName). "
                + "Mu will create a persistent native OpenWorker session, mirror its live "
                + "progress and approvals, and reconcile messages and artifacts."
        } else if endpoint.runtimeTypeID == Self.openWorkerRuntimeTypeID {
            assignmentText =
                "Task queued through \(endpoint.displayName). Mu will create a persistent "
                + "native session and mirror its work in Workspace Chat."
        } else if let agent {
            assignmentText = "\(agent.displayName) is assigned through \(endpoint.displayName). "
                + "This thread records workspace notes; runtime message dispatch is explicit."
        } else {
            assignmentText = "Task started through \(endpoint.displayName). "
                + "This thread records workspace notes; no named agent identity is assigned."
        }
        let assignmentEntry = ChatEntry(
            taskID: task.id,
            agentIdentityID: agent?.id,
            authorKind: .system,
            authorName: "Mu",
            text: assignmentText
        )
        var projectPreferenceToRestore =
            try store.fetchProjectPreferences()
                .filter {
                    WorkspacePathIdentity.isExactMatch(
                        $0.repositoryPath,
                        task.repositoryPath
                    )
                }
                .max { $0.updatedAt < $1.updatedAt }
        if projectPreferenceToRestore?.isRemoved == true {
            projectPreferenceToRestore?.isRemoved = false
            projectPreferenceToRestore?.updatedAt = task.createdAt
        } else {
            projectPreferenceToRestore = nil
        }

        try store.withTransaction {
            guard try store.fetchRegisteredEndpoint(id: sourceEndpointID) != nil else {
                throw MuError.recordNotFound("Source endpoint \(sourceEndpointID)")
            }
            if let projectPreferenceToRestore {
                try store.upsertProjectPreference(
                    projectPreferenceToRestore
                )
            }
            let link = try attachTaskToProjectKernel(
                task: &task,
                endpoint: endpoint
            )
            let kernel = try projectKernelContext(taskID: task.id)
            run.projectID = link.projectID
            run.workspaceID = link.workspaceID
            run.actorID = link.assignedToActorID
            run.principalID = kernel.principal?.id
            try store.upsertTask(task)
            try store.upsertRun(run)
            try store.insertChatEntry(assignmentEntry)
            try store.appendEvent(
                LedgerEvent(
                    projectID: link.projectID,
                    actorID: link.requestedByActorID,
                    principalID: Self.localOwnerPrincipalID,
                    workspaceID: link.workspaceID,
                    taskID: task.id,
                    runID: run.id,
                    type: "task.created",
                    summary: "Created “\(task.title)” on \(endpoint.displayName).",
                    payload: [
                        "runtime_type_id": endpoint.runtimeTypeID,
                        "repository_path": task.repositoryPath,
                        "agent_identity_id": agent?.id.uuidString ?? ""
                    ]
                )
            )
            try store.appendEvent(
                LedgerEvent(
                    projectID: link.projectID,
                    actorID: link.assignedToActorID,
                    principalID: kernel.principal?.id,
                    workspaceID: link.workspaceID,
                    taskID: task.id,
                    runID: run.id,
                    type: "run.started",
                    summary: endpoint.runtimeTypeID == Self.codexRuntimeTypeID
                        ? "Queued the initial read-only Codex execution Run."
                        : endpoint.runtimeTypeID == Self.claudeCodeRuntimeTypeID
                            ? "Queued the initial read-only Claude Code execution Run."
                        : endpoint.runtimeTypeID == Self.openWorkerRuntimeTypeID
                            ? "Queued the initial native OpenWorker execution Run."
                            : "Started the initial execution Run.",
                    payload: [
                        "purpose": run.purpose.rawValue,
                        "dispatch_mode": endpoint.runtimeTypeID == Self.codexRuntimeTypeID
                            ? "native_read_only"
                            : endpoint.runtimeTypeID == Self.claudeCodeRuntimeTypeID
                                ? "managed_cli_read_only"
                            : endpoint.runtimeTypeID == Self.openWorkerRuntimeTypeID
                                ? "native_session"
                            : "fixture_or_external"
                    ]
                )
            )
        }
        return task
    }

    @discardableResult
    public func prepareWorkspaceMessage(
        taskID: UUID,
        text: String,
        selectedEndpointID: UUID? = nil,
        requestedModel: String? = nil
    ) throws -> PreparedWorkspaceMessage {
        guard var task = try store.fetchTask(id: taskID) else {
            throw MuError.recordNotFound("Task \(taskID)")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MuError.invalidTransition("Chat message cannot be empty.")
        }
        // Starter identities remain readable for historical records, but a
        // new Project chat must not surface or route to them implicitly.
        let agents = try store.fetchAgents().filter {
            !Self.starterAgentIDs.contains($0.id)
        }
        let endpoints = try store.fetchRegisteredEndpoints()
        if let selectedEndpointID,
           !endpoints.contains(where: { $0.id == selectedEndpointID }) {
            throw MuError.recordNotFound("Selected Runtime (selectedEndpointID)")
        }
        let route = try WorkspaceChatRouter.resolve(
            text: trimmed,
            assignedAgentIdentityID: task.assignedAgentIdentityID,
            agents: agents,
            endpoints: endpoints,
            selectedEndpointID: selectedEndpointID
        )
        let normalizedRequestedModel = requestedModel?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveRequestedModel = normalizedRequestedModel?.isEmpty == false
            ? normalizedRequestedModel
            : nil

        guard let route else {
            let entry = ChatEntry(
                taskID: taskID,
                deliveryState: .local,
                authorKind: .user,
                authorName: "You",
                text: trimmed
            )
            try store.withTransaction {
                try store.insertChatEntry(entry)
                try store.appendEvent(
                    LedgerEvent(
                        taskID: taskID,
                        type: "chat.note_added",
                        summary: "You added a local workspace note.",
                        payload: [
                            "chat_entry_id": entry.id.uuidString,
                            "delivery_state": ChatDeliveryState.local.rawValue
                        ]
                    )
                )
            }
            return PreparedWorkspaceMessage(entry: entry, route: nil)
        }

        guard let endpoint = endpoints.first(where: { $0.id == route.endpointID }) else {
            throw MuError.recordNotFound("Routed Runtime \(route.endpointID)")
        }
        guard endpoint.status == .active else {
            throw MuError.capabilityMissing(
                "\(endpoint.displayName) is not active. Probe it before routing a message."
            )
        }
        try RuntimeGatewayRegistry.require(
            .submitInput,
            endpoint: endpoint
        )
        try RuntimeGatewayRegistry.require(
            .observeEvents,
            endpoint: endpoint
        )
        let isOpenWorker =
            endpoint.runtimeTypeID
            == Self.openWorkerRuntimeTypeID
        let isManagedNativeRuntime =
            endpoint.runtimeTypeID == Self.codexRuntimeTypeID
                || endpoint.runtimeTypeID == Self.claudeCodeRuntimeTypeID

        let binding = try currentRuntimeSessionBinding(
            taskID: taskID,
            endpointID: endpoint.id,
            agentIdentityID: route.agentIdentityID
        )
        if !isOpenWorker, !isManagedNativeRuntime, binding == nil {
            throw MuError.invalidTransition(
                "\(endpoint.displayName) has no resumable native session "
                    + "for this Task."
            )
        }
        if let binding,
           binding.state == .working || binding.state == .awaitingApproval {
            throw MuError.invalidTransition(
                "\(endpoint.displayName) is already working in session "
                + "\(binding.nativeSessionID). Wait for turn_done or interrupt it."
            )
        }

        var link = try store.fetchTaskProjectLink(
            taskID: taskID
        )
        let actorID =
            route.agentIdentityID.map {
                ProjectActorRecord
                    .stableAgentIdentityActorID(
                        agentIdentityID: $0
                    )
            }
            ?? ProjectActorRecord.stableRuntimeActorID(
                endpointID: endpoint.id
            )
        let routedActorID =
            binding?.actorID ?? actorID
        try authorizeTaskActor(
            taskID: taskID,
            actorID: routedActorID,
            endpointID: endpoint.id
        )
        let isInitialManagedRun = isManagedNativeRuntime && binding == nil
        let run: RunRecord
        let shouldInsertRun: Bool
        if let binding {
            let agent = route.agentIdentityID.flatMap { id in
                agents.first { $0.id == id }
            }
            run = RunRecord(
                taskID: taskID,
                projectID:
                    link?.projectID ?? task.projectID,
                workspaceID:
                    link?.workspaceID ?? task.workspaceID,
                actorID: routedActorID,
                principalID:
                    link?.costOwnerPrincipalID,
                endpointID: endpoint.id,
                actorName:
                    agent?.displayName
                    ?? endpoint.displayName,
                purpose: .delegation,
                state: .starting,
                nativeThreadID:
                    binding.nativeSessionID,
                agentIdentityID: agent?.id
            )
            shouldInsertRun = true
        } else if isInitialManagedRun,
                  task.currentEndpointID == endpoint.id,
                  let runID = task.currentRunID,
                  let currentRun = try store.fetchRun(id: runID),
                  currentRun.endpointID == endpoint.id,
                  currentRun.agentIdentityID == route.agentIdentityID,
                  currentRun.purpose == .execution,
                  (currentRun.state == .starting || currentRun.state == .created),
                  currentRun.nativeThreadID == nil,
                  currentRun.nativeTurnID == nil {
            run = currentRun
            shouldInsertRun = false
        } else {
            let agent = route.agentIdentityID.flatMap { id in
                agents.first { $0.id == id }
            }
            run = RunRecord(
                taskID: taskID,
                endpointID: endpoint.id,
                actorName: agent?.displayName ?? endpoint.displayName,
                purpose: isInitialManagedRun ? .execution : .delegation,
                state: .starting,
                agentIdentityID: agent?.id
            )
            shouldInsertRun = true
        }

        if isInitialManagedRun,
           let currentRunID = task.currentRunID,
           currentRunID != run.id,
           let currentRun = try store.fetchRun(id: currentRunID),
           currentRun.state == .starting || currentRun.state == .active {
            throw MuError.invalidTransition(
                "The current Runtime is still working. Wait for it to finish before switching Runtime."
            )
        }

        // A Runtime selected in the composer is an explicit switch for this
        // Task. Keep the Project Kernel's assigned actor in sync so the
        // initial Run can be authorized and can build its Context Pack even
        // when the Task was originally created on another Runtime.
        if isInitialManagedRun {
            if var taskLink = link {
                taskLink.assignedToActorID = routedActorID
                taskLink.updatedAt = Date()
                link = taskLink
            }
            task.currentEndpointID = endpoint.id
            task.currentRunID = run.id
            task.assignedActorID = routedActorID
            task.status = .running
            task.updatedAt = Date()
        }

        let entry = ChatEntry(
            taskID: taskID,
            targetAgentIdentityID: route.agentIdentityID,
            targetEndpointID: endpoint.id,
            runID: run.id,
            runtimeSessionBindingID: binding?.id,
            nativeMessageIndexLowerBound:
                binding?.lastSyncedMessageCount,
            requestedModel: effectiveRequestedModel,
            deliveryState:
                binding == nil
                ? .awaitingSession
                : .queued,
            routedText: route.prompt,
            authorKind: .user,
            authorName: "You",
            text: trimmed
        )
        try store.withTransaction {
            if shouldInsertRun {
                try store.upsertRun(run)
            }
            if isInitialManagedRun {
                try store.upsertTask(task)
                if let link {
                    try store.upsertTaskProjectLink(link)
                }
            }
            try store.insertChatEntry(entry)
            try store.appendEvent(
                LedgerEvent(
                    projectID:
                        link?.projectID ?? task.projectID,
                    actorID: routedActorID,
                    principalID:
                        link?.costOwnerPrincipalID,
                    workspaceID:
                        link?.workspaceID
                        ?? task.workspaceID,
                    taskID: taskID,
                    runID: run.id,
                    type: binding == nil
                        ? "runtime.message.awaiting_session"
                        : "runtime.message.queued",
                    summary: binding == nil
                        ? (isInitialManagedRun
                            ? "Workspace message is starting a native Runtime session."
                            : "Workspace message is waiting for an explicit OpenWorker session link.")
                        : "Queued a bounded Workspace message for "
                            + "\(endpoint.displayName) session "
                            + "\(binding!.nativeSessionID).",
                    payload: [
                        "chat_entry_id": entry.id.uuidString,
                        "endpoint_id": endpoint.id.uuidString,
                        "agent_identity_id": route.agentIdentityID?.uuidString ?? "",
                        "binding_id": binding?.id.uuidString ?? "",
                        "native_session_id": binding?.nativeSessionID ?? "",
                        "mention": route.mention
                    ]
                )
            )
        }
        return PreparedWorkspaceMessage(entry: entry, route: route)
    }

    @discardableResult
    public func appendChatEntry(
        taskID: UUID,
        agentIdentityID: UUID?,
        authorKind: ChatAuthorKind,
        authorName: String,
        text: String
    ) throws -> ChatEntry {
        guard try store.fetchTask(id: taskID) != nil else {
            throw MuError.recordNotFound("Task \(taskID)")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MuError.invalidTransition("Chat message cannot be empty.")
        }
        let entry = ChatEntry(
            taskID: taskID,
            agentIdentityID: agentIdentityID,
            deliveryState: .local,
            authorKind: authorKind,
            authorName: authorName,
            text: trimmed
        )
        try store.withTransaction {
            try store.insertChatEntry(entry)
            try store.appendEvent(
                LedgerEvent(
                    taskID: taskID,
                    type: "chat.note_added",
                    summary: "\(authorName) added a workspace note.",
                    payload: [
                        "chat_entry_id": entry.id.uuidString,
                        "author_kind": authorKind.rawValue,
                        "agent_identity_id": agentIdentityID?.uuidString ?? ""
                    ]
                )
            )
        }
        return entry
    }

    @discardableResult
    public func bindOpenWorkerSession(
        taskID: UUID,
        chatEntryID: UUID? = nil,
        existingSession: OpenWorkerSessionSummary? = nil
    ) throws -> RuntimeSessionBinding {
        guard var task = try store.fetchTask(id: taskID) else {
            throw MuError.recordNotFound("Task \(taskID)")
        }
        let endpoint = try activeOpenWorkerEndpoint()
        let pendingEntry = try chatEntryID.flatMap { try store.fetchChatEntry(id: $0) }
        if let pendingEntry, pendingEntry.taskID != taskID {
            throw MuError.invalidTransition("The routed message belongs to another Task.")
        }
        let agentID = pendingEntry?.targetAgentIdentityID
            ?? task.assignedAgentIdentityID.flatMap { id in
                (try? store.fetchAgent(id: id))?.preferredEndpointID == endpoint.id ? id : nil
            }
        let actorID =
            agentID.map {
                ProjectActorRecord
                    .stableAgentIdentityActorID(
                        agentIdentityID: $0
                    )
            }
            ?? ProjectActorRecord.stableRuntimeActorID(
                endpointID: endpoint.id
            )
        let runID: UUID
        var runToInsert: RunRecord?
        if let entryRunID = pendingEntry?.runID,
           let entryRun = try store.fetchRun(id: entryRunID),
           entryRun.endpointID == endpoint.id,
           entryRun.agentIdentityID == agentID {
            runID = entryRunID
            runToInsert = nil
        } else if task.currentEndpointID == endpoint.id,
                  let currentRunID = task.currentRunID,
                  let currentRun = try store.fetchRun(id: currentRunID),
                  currentRun.agentIdentityID == agentID {
            runID = currentRunID
            runToInsert = nil
        } else {
            let agent = try agentID.flatMap { try store.fetchAgent(id: $0) }
            let newRun = RunRecord(
                taskID: taskID,
                endpointID: endpoint.id,
                actorName: agent?.displayName ?? endpoint.displayName,
                purpose: .delegation,
                state: .starting,
                agentIdentityID: agent?.id
            )
            runID = newRun.id
            runToInsert = newRun
        }

        let nativeSessionID: String
        let workspacePath: String
        let nativeAgentName: String
        let model: String?
        let origin: String
        let initialState: RuntimeSessionState
        if let existingSession {
            guard WorkspacePathIdentity.isExactMatch(
                task.repositoryPath,
                existingSession.workspace
            ) else {
                throw MuError.invalidTransition(
                    "OpenWorker session \(existingSession.sessionID) belongs "
                        + "to another folder. Choose or create a session for "
                        + "this Task's exact Project workspace."
                )
            }
            nativeSessionID = existingSession.sessionID
            workspacePath = existingSession.workspace
            nativeAgentName = existingSession.agent
            model = existingSession.model
            origin = "linked_existing"
            initialState = existingSession.liveness == "working" ? .working : .connecting
        } else {
            nativeSessionID =
                "mu-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
                    .prefix(16)
            workspacePath = task.repositoryPath
            nativeAgentName =
                endpoint.nativeConfiguration?["default_agent"] ?? "cowork"
            model = endpoint.nativeConfiguration?["default_model"]
            origin = "created_by_mu"
            initialState = .connecting
        }
        guard nativeSessionID.range(
            of: #"^[A-Za-z0-9._-]{1,200}$"#,
            options: .regularExpression
        ) != nil else {
            throw MuError.invalidTransition("OpenWorker returned an unsafe native session ID.")
        }
        let workspaceURL = URL(fileURLWithPath: workspacePath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard workspaceURL.path.hasPrefix("/"),
              FileManager.default.fileExists(
                  atPath: workspaceURL.path,
                  isDirectory: &isDirectory
              ),
              isDirectory.boolValue else {
            throw MuError.invalidRepository(
                "OpenWorker session workspace is not an accessible directory."
            )
        }
        try authorizeTaskActor(
            taskID: taskID,
            actorID: actorID,
            endpointID: endpoint.id
        )
        let kernel = try projectKernelContext(
            taskID: taskID
        )
        let actor = try store.fetchProjectActor(
            id: actorID
        )
        let principal = try actor.flatMap {
            try store.fetchPrincipal(
                id: $0.principalID
            )
        }
        var lease = try claimTaskLease(
            taskID: taskID,
            endpointID: endpoint.id,
            actorID: actorID,
            duration: 30 * 60
        )
        let persistedRun = try store.fetchRun(
            id: runID
        )
        if var stagedRun =
            runToInsert ?? persistedRun {
            stagedRun.projectID = kernel.project.id
            stagedRun.workspaceID = kernel.workspace.id
            stagedRun.actorID = actorID
            stagedRun.principalID = principal?.id
            stagedRun.taskLeaseID = lease.id
            runToInsert = stagedRun
        }
        var taskLink = try store.fetchTaskProjectLink(
            taskID: taskID
        )
        taskLink?.assignedToActorID = actorID
        taskLink?.workspaceID = kernel.workspace.id
        taskLink?.updatedAt = Date()
        let allBindings = try store.fetchRuntimeSessionBindings()
        if var existingBinding = allBindings.first(where: {
            $0.endpointID == endpoint.id
                && $0.nativeSessionID == nativeSessionID
                && $0.taskID == taskID
                && $0.state != .detached
        }) {
            guard existingBinding.agentIdentityID == agentID else {
                throw MuError.invalidTransition(
                    "OpenWorker session \(nativeSessionID) belongs to another Agent in this "
                    + "Task. Choose or create a session for the mentioned Agent."
                )
            }
            existingBinding.projectID = kernel.project.id
            existingBinding.workspaceID =
                kernel.workspace.id
            existingBinding.actorID = actorID
            existingBinding.principalID = principal?.id
            existingBinding.taskLeaseID = lease.id
            existingBinding.runID = runID
            existingBinding.updatedAt = Date()
            lease.runtimeBindingID = existingBinding.id
            task.projectID = kernel.project.id
            task.workspaceID = kernel.workspace.id
            task.assignedActorID = actorID
            task.currentEndpointID = endpoint.id
            task.currentRunID = runID
            task.status = .running
            task.updatedAt = Date()
            if var pendingEntry {
                pendingEntry.runID = existingBinding.runID
                pendingEntry.runtimeSessionBindingID = existingBinding.id
                pendingEntry.nativeMessageIndexLowerBound =
                    existingBinding.lastSyncedMessageCount
                pendingEntry.deliveryState = .queued
                pendingEntry.updatedAt = Date()
                try store.withTransaction {
                    if let runToInsert {
                        try store.upsertRun(runToInsert)
                    }
                    try store.upsertTask(task)
                    if let taskLink {
                        try store.upsertTaskProjectLink(
                            taskLink
                        )
                    }
                    try store.upsertTaskLease(lease)
                    try store.upsertRuntimeSessionBinding(
                        existingBinding
                    )
                    try store.upsertChatEntry(pendingEntry)
                    try store.appendEvent(
                        LedgerEvent(
                            taskID: taskID,
                            runID: existingBinding.runID,
                            type: "runtime.session.reused",
                            summary:
                                "Reused linked OpenWorker session \(nativeSessionID).",
                            payload: [
                                "binding_id": existingBinding.id.uuidString,
                                "native_session_id": nativeSessionID,
                                "chat_entry_id": pendingEntry.id.uuidString
                            ]
                        )
                    )
                }
            } else {
                try store.withTransaction {
                    if let runToInsert {
                        try store.upsertRun(runToInsert)
                    }
                    try store.upsertTask(task)
                    if let taskLink {
                        try store.upsertTaskProjectLink(
                            taskLink
                        )
                    }
                    try store.upsertTaskLease(lease)
                    try store.upsertRuntimeSessionBinding(
                        existingBinding
                    )
                }
            }
            return existingBinding
        }
        if let conflicting = allBindings.first(where: {
            $0.endpointID == endpoint.id
                && $0.nativeSessionID == nativeSessionID
                && $0.taskID != taskID
                && $0.state != .detached
        }) {
            throw MuError.invalidTransition(
                "OpenWorker session \(nativeSessionID) is already linked to Task "
                + "\(conflicting.taskID)."
            )
        }

        let connectionMode =
            endpoint.nativeConfiguration?["connection_mode"] ?? "legacy_loopback"
        let binding = RuntimeSessionBinding(
            taskID: taskID,
            projectID: kernel.project.id,
            workspaceID: kernel.workspace.id,
            actorID: actorID,
            principalID: principal?.id,
            taskLeaseID: lease.id,
            runID: runID,
            endpointID: endpoint.id,
            agentIdentityID: agentID,
            nativeSessionID: nativeSessionID,
            nativeAgentName: nativeAgentName,
            workspacePath: workspaceURL.path,
            model: model,
            connectionMode: connectionMode,
            origin: origin,
            state: initialState,
            lastActivitySummary: existingSession == nil
                ? "Native OpenWorker session prepared."
                : "Existing OpenWorker session linked."
        )
        lease.runtimeBindingID = binding.id
        task.projectID = kernel.project.id
        task.workspaceID = kernel.workspace.id
        task.assignedActorID = actorID
        task.currentEndpointID = endpoint.id
        task.currentRunID = runID
        task.status = .running
        task.updatedAt = Date()
        var oldBindings = try store.fetchRuntimeSessionBindings(taskID: taskID).filter {
            $0.endpointID == endpoint.id
                && $0.agentIdentityID == agentID
                && $0.state != .detached
                && $0.nativeSessionID != nativeSessionID
        }
        let entries = try store.fetchChatEntries(taskID: taskID)
        var entriesToUpdate: [ChatEntry] = []
        for var entry in entries where
            entry.targetEndpointID == endpoint.id
                && entry.targetAgentIdentityID == agentID
                && entry.runtimeSessionBindingID == nil
                && entry.deliveryState == .awaitingSession {
            entry.runtimeSessionBindingID = binding.id
            entry.runID = runID
            entry.nativeMessageIndexLowerBound =
                binding.lastSyncedMessageCount
            entry.deliveryState = .queued
            entry.updatedAt = Date()
            entriesToUpdate.append(entry)
        }

        try store.withTransaction {
            for index in oldBindings.indices {
                oldBindings[index].state = .detached
                oldBindings[index].lastActivitySummary =
                    "Detached when another native session was linked."
                oldBindings[index].updatedAt = Date()
                try store.upsertRuntimeSessionBinding(oldBindings[index])
            }
            if let runToInsert {
                try store.upsertRun(runToInsert)
            }
            try store.upsertTask(task)
            if let taskLink {
                try store.upsertTaskProjectLink(taskLink)
            }
            try store.upsertTaskLease(lease)
            try store.upsertRuntimeSessionBinding(binding)
            for entry in entriesToUpdate {
                try store.upsertChatEntry(entry)
            }
            try store.appendEvent(
                LedgerEvent(
                    projectID: kernel.project.id,
                    actorID: actorID,
                    principalID: principal?.id,
                    workspaceID: kernel.workspace.id,
                    taskID: taskID,
                    runID: runID,
                    type: existingSession == nil
                        ? "runtime.session.created"
                        : "runtime.session.linked",
                    summary: existingSession == nil
                        ? "Prepared native OpenWorker session \(nativeSessionID)."
                        : "Linked existing OpenWorker session \(nativeSessionID).",
                    payload: [
                        "binding_id": binding.id.uuidString,
                        "endpoint_id": endpoint.id.uuidString,
                        "native_session_id": nativeSessionID,
                        "native_agent": nativeAgentName,
                        "workspace": workspaceURL.path,
                        "origin": origin,
                        "queued_messages": String(entriesToUpdate.count)
                    ]
                )
            )
        }
        return binding
    }

    public func makeOpenWorkerBridge(
        bindingID: UUID
    ) throws -> OpenWorkerSessionBridge {
        guard let binding = try store.fetchRuntimeSessionBinding(id: bindingID),
              binding.state != .detached else {
            throw MuError.recordNotFound("Active OpenWorker session binding \(bindingID)")
        }
        let endpoint = try activeOpenWorkerEndpoint()
        guard binding.endpointID == endpoint.id else {
            throw MuError.invalidTransition("The session binding does not use OpenWorker.")
        }
        return OpenWorkerSessionBridge(
            configuration: try openWorkerConfiguration(for: endpoint),
            sessionID: binding.nativeSessionID,
            workspace: binding.workspacePath,
            agent: binding.nativeAgentName
        )
    }

    public func queuedWorkspaceMessages(bindingID: UUID) throws -> [ChatEntry] {
        guard let binding = try store.fetchRuntimeSessionBinding(id: bindingID) else {
            throw MuError.recordNotFound("Runtime session binding \(bindingID)")
        }
        return try store.fetchChatEntries(taskID: binding.taskID)
            .filter {
                $0.runtimeSessionBindingID == bindingID
                    && $0.deliveryState == .queued
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    public func markWorkspaceMessageSending(
        entryID: UUID,
        bindingID: UUID
    ) async throws -> String {
        await openWorkerSyncGate.acquire(bindingID)
        do {
            let dispatchPayload = try markWorkspaceMessageSendingUnlocked(
                entryID: entryID,
                bindingID: bindingID
            )
            await openWorkerSyncGate.release(bindingID)
            return dispatchPayload
        } catch {
            await openWorkerSyncGate.release(bindingID)
            throw error
        }
    }

    private func markWorkspaceMessageSendingUnlocked(
        entryID: UUID,
        bindingID: UUID
    ) throws -> String {
        guard var entry = try store.fetchChatEntry(id: entryID),
              var binding = try store.fetchRuntimeSessionBinding(id: bindingID),
              entry.taskID == binding.taskID,
              entry.runtimeSessionBindingID == bindingID,
              entry.deliveryState == .queued,
              binding.state == .idle else {
            throw MuError.invalidTransition("The Workspace message is not safely queued.")
        }
        let endpoint = try activeOpenWorkerEndpoint()
        guard endpoint.id == binding.endpointID else {
            throw MuError.invalidTransition(
                "The queued message no longer targets the active OpenWorker adapter."
            )
        }
        guard var task = try store.fetchTask(id: entry.taskID),
              WorkspacePathIdentity.isExactMatch(
                  binding.workspacePath,
                  task.repositoryPath
              ) else {
            throw MuError.invalidTransition(
                "OpenWorker binding belongs to another workspace and requires relinking."
            )
        }
        guard let actorID = binding.actorID,
              let dispatchRunID =
                entry.runID ?? binding.runID,
              var run = try store.fetchRun(
                  id: dispatchRunID
              ) else {
            throw MuError.invalidTransition(
                "OpenWorker has no authorized Actor or persisted Run."
            )
        }
        var lease: TaskLeaseRecord
        if let leaseID = binding.taskLeaseID,
           let currentLease = try store.fetchTaskLease(
               id: leaseID
           ),
           currentLease.isActive(),
           currentLease.agentActorID == actorID,
           currentLease.endpointID == endpoint.id {
            lease = try renewTaskLease(
                id: currentLease.id,
                duration: 30 * 60
            )
        } else {
            lease = try claimTaskLease(
                taskID: entry.taskID,
                endpointID: endpoint.id,
                actorID: actorID,
                runtimeBindingID: binding.id,
                duration: 30 * 60
            )
        }
        if lease.runtimeBindingID != binding.id {
            lease.runtimeBindingID = binding.id
            try store.upsertTaskLease(lease)
        }
        let contextPack = try buildGovernedContextPack(
            taskID: entry.taskID,
            actorID: actorID,
            endpointID: endpoint.id,
            runtimeBindingID: binding.id,
            taskLeaseID: lease.id
        )
        let currentMessage =
            entry.routedText
            ?? entry.text
        let dispatchPayload =
            contextPack.renderedMarkdown
            + "\n\n# Current Project message\n\n"
            + currentMessage
        entry.nativeMessageIndexLowerBound = max(
            entry.nativeMessageIndexLowerBound ?? 0,
            binding.lastSyncedMessageCount
        )
        entry.deliveryState = .sending
        entry.runID = run.id
        entry.updatedAt = Date()
        binding.state = .connecting
        binding.taskLeaseID = lease.id
        binding.runID = run.id
        binding.contextPackID = contextPack.id
        binding.lastActivitySummary = "Sending a Workspace message to OpenWorker."
        binding.lastError = nil
        binding.updatedAt = Date()
        run.projectID = binding.projectID
        run.workspaceID = binding.workspaceID
        run.actorID = actorID
        run.principalID = binding.principalID
        run.taskLeaseID = lease.id
        run.contextPackID = contextPack.id
        run.state = .starting
        run.updatedAt = Date()
        task.projectID = binding.projectID
        task.workspaceID = binding.workspaceID
        task.assignedActorID = actorID
        task.currentEndpointID = endpoint.id
        task.currentRunID = run.id
        task.status = .running
        task.updatedAt = Date()
        try store.withTransaction {
            try store.upsertChatEntry(entry)
            try store.upsertRuntimeSessionBinding(binding)
            try store.upsertRun(run)
            try store.upsertTask(task)
            try store.appendEvent(
                LedgerEvent(
                    taskID: entry.taskID,
                    runID: entry.runID,
                    type: "runtime.message.sending",
                    summary: "Sending a Workspace message to OpenWorker.",
                    payload: [
                        "chat_entry_id": entry.id.uuidString,
                        "binding_id": binding.id.uuidString,
                        "native_session_id": binding.nativeSessionID,
                        "context_pack_id":
                            contextPack.id.uuidString
                    ]
                )
            )
            try recordContextDelivery(
                projectID:
                    binding.projectID
                    ?? contextPack.projectID,
                packID: contextPack.id,
                status: .prepared
            )
        }
        return dispatchPayload
    }

    public func markWorkspaceMessageAmbiguous(
        entryID: UUID,
        error: Error
    ) async throws {
        guard let entry = try store.fetchChatEntry(id: entryID),
              let bindingID = entry.runtimeSessionBindingID else {
            throw MuError.recordNotFound("Workspace message \(entryID)")
        }
        await openWorkerSyncGate.acquire(bindingID)
        do {
            try markWorkspaceMessageAmbiguousUnlocked(
                entryID: entryID,
                error: error
            )
            await openWorkerSyncGate.release(bindingID)
        } catch {
            await openWorkerSyncGate.release(bindingID)
            throw error
        }
    }

    private func markWorkspaceMessageAmbiguousUnlocked(
        entryID: UUID,
        error: Error
    ) throws {
        guard var entry = try store.fetchChatEntry(id: entryID) else {
            throw MuError.recordNotFound("Workspace message \(entryID)")
        }
        guard entry.deliveryState == .sending else {
            return
        }
        entry.deliveryState = .ambiguous
        Self.redactImportedContextPayload(&entry)
        entry.updatedAt = Date()
        var binding = try entry.runtimeSessionBindingID.flatMap {
            try store.fetchRuntimeSessionBinding(id: $0)
        }
        binding?.state = .disconnected
        binding?.lastActivitySummary =
            "Connection was lost after dispatch; Mu will not retry automatically."
        binding?.lastError = error.localizedDescription
        binding?.updatedAt = Date()
        try store.withTransaction {
            try store.upsertChatEntry(entry)
            if let binding {
                try store.upsertRuntimeSessionBinding(binding)
            }
            try store.appendEvent(
                LedgerEvent(
                    taskID: entry.taskID,
                    runID: entry.runID,
                    type: "runtime.message.ambiguous",
                    summary:
                        "OpenWorker delivery became ambiguous; automatic retry is disabled.",
                    payload: [
                        "chat_entry_id": entry.id.uuidString,
                        "binding_id": binding?.id.uuidString ?? "",
                        "error": error.localizedDescription
                    ]
                )
            )
        }
        if let binding {
            try finalizeOpenWorkerContextDeliveryIfNeeded(
                binding: binding,
                status: .failed,
                failureCode:
                    "openworker_send_failed_before_ack"
            )
        }
    }

    public func recordOpenWorkerEvent(
        bindingID: UUID,
        event: OpenWorkerEvent
    ) async throws -> RuntimeInteractionRequest? {
        await openWorkerSyncGate.acquire(bindingID)
        do {
            let interaction = try recordOpenWorkerEventUnlocked(
                bindingID: bindingID,
                event: event
            )
            await openWorkerSyncGate.release(bindingID)
            return interaction
        } catch {
            await openWorkerSyncGate.release(bindingID)
            throw error
        }
    }

    private func recordOpenWorkerEventUnlocked(
        bindingID: UUID,
        event: OpenWorkerEvent
    ) throws -> RuntimeInteractionRequest? {
        guard var binding = try store.fetchRuntimeSessionBinding(id: bindingID),
              binding.state != .detached else {
            throw MuError.recordNotFound("Active OpenWorker session binding \(bindingID)")
        }
        if event.type == "assistant_delta" || event.type == "reasoning_delta" {
            return nil
        }
        var run = try binding.runID.flatMap { try store.fetchRun(id: $0) }
        var interaction: RuntimeInteractionRequest?
        let now = Date()
        switch event.type {
        case "ready":
            if let ready = event.ready {
                guard ready.sessionID == binding.nativeSessionID else {
                    throw MuError.invalidTransition(
                        "OpenWorker acknowledged a conflicting native session."
                    )
                }
                binding.nativeAgentName = ready.agent
                binding.model = ready.model
                if !ready.workspace.isEmpty {
                    guard Self.sameWorkspace(
                        ready.workspace,
                        binding.workspacePath
                    ) else {
                        throw MuError.invalidTransition(
                            "OpenWorker reported a different workspace. Relink the intended session."
                        )
                    }
                }
            }
            if binding.state == .connecting || binding.state == .disconnected {
                binding.state = .idle
            }
            binding.lastError = nil
        case "turn_start":
            binding.state = .working
            binding.lastError = nil
            run?.state = .active
        case "permission_required":
            binding.state = .awaitingApproval
            interaction = makeOpenWorkerInteraction(
                binding: binding,
                event: event,
                kind: .approval,
                title: "Approve \(event.data["name"]?.stringValue ?? "OpenWorker action")?"
            )
            run?.state = .blocked
        case "directory_requested":
            binding.state = .awaitingApproval
            interaction = makeOpenWorkerInteraction(
                binding: binding,
                event: event,
                kind: .directory,
                title: "OpenWorker requested another folder."
            )
            run?.state = .blocked
        case "plan_proposed":
            binding.state = .awaitingApproval
            interaction = makeOpenWorkerInteraction(
                binding: binding,
                event: event,
                kind: .plan,
                title: "OpenWorker proposed a plan."
            )
            run?.state = .blocked
        case "question_requested":
            binding.state = .awaitingApproval
            interaction = makeOpenWorkerInteraction(
                binding: binding,
                event: event,
                kind: .question,
                title: event.data["question"]?.stringValue
                    ?? "OpenWorker asked a question."
            )
            run?.state = .blocked
        case "tool_started":
            binding.state = .working
            run?.state = .active
        case "model_changed":
            if let model = event.data["model"]?.stringValue, !model.isEmpty {
                binding.model = model
            }
        case "error", "input_rejected":
            binding.state = .idle
            binding.lastError = event.data["error"]?.stringValue ?? event.summary
            run?.state = .degraded
        case "connection_closed":
            if binding.state == .working || binding.state == .awaitingApproval {
                run?.state = .ambiguous
            }
            binding.state = .disconnected
            binding.lastError = event.data["error"]?.stringValue
        case "interrupted":
            binding.state = .idle
            binding.lastError = "The last OpenWorker turn was interrupted."
            run?.state = .degraded
        case "turn_done":
            if binding.state != .failed {
                binding.state = .idle
                if run?.state != .cancelled, run?.state != .degraded {
                    run?.state = .active
                }
            }
        default:
            break
        }
        if var proposedInteraction = interaction,
           proposedInteraction.projectApprovalID == nil {
            _ = try createProjectApproval(
                interaction: &proposedInteraction,
                requestedByActorID: binding.actorID,
                scope:
                    "openworker."
                    + proposedInteraction.kind.rawValue
            )
            interaction = proposedInteraction
        }
        if let leaseID = binding.taskLeaseID {
            if event.type == "connection_closed" {
                _ = try? releaseTaskLease(
                    id: leaseID
                )
            } else if [
                "ready",
                "turn_start",
                "tool_started",
                "turn_done"
            ].contains(event.type) {
                _ = try? renewTaskLease(
                    id: leaseID,
                    duration: 30 * 60
                )
            }
        }
        binding.lastActivitySummary = event.summary
        binding.updatedAt = now
        run?.updatedAt = now

        var sendingEntries: [ChatEntry] = []
        if event.type == "turn_start"
            || event.type == "connection_closed"
            || event.type == "input_rejected" {
            sendingEntries = try store.fetchChatEntries(taskID: binding.taskID).filter {
                $0.runtimeSessionBindingID == binding.id
                    && $0.deliveryState == .sending
            }
            for index in sendingEntries.indices {
                switch event.type {
                case "turn_start":
                    sendingEntries[index].deliveryState = .delivered
                case "input_rejected":
                    sendingEntries[index].deliveryState = .failed
                default:
                    sendingEntries[index].deliveryState = .ambiguous
                }
                Self.redactImportedContextPayload(
                    &sendingEntries[index]
                )
                sendingEntries[index].updatedAt = now
            }
        }

        let pendingInteractions = try store.fetchRuntimeInteractions(taskID: binding.taskID)
            .filter { $0.bindingID == binding.id && $0.state == .pending }
        if let proposedInteraction = interaction,
           let existing = pendingInteractions.first(where: {
               $0.kind == proposedInteraction.kind
           }) {
            var updatedInteraction = proposedInteraction
            updatedInteraction.id = existing.id
            updatedInteraction.nativeRequestID = existing.nativeRequestID
            updatedInteraction.createdAt = existing.createdAt
            interaction = updatedInteraction
        }
        var interactionsToResolve: [RuntimeInteractionRequest] = []
        if event.type == "tool_started" {
            interactionsToResolve = pendingInteractions.filter { $0.kind == .approval }
            for index in interactionsToResolve.indices {
                interactionsToResolve[index].state = .approved
                interactionsToResolve[index].resolvedAt = now
            }
        } else if event.type == "turn_done" {
            interactionsToResolve = pendingInteractions
            for index in interactionsToResolve.indices {
                interactionsToResolve[index].state = .superseded
                interactionsToResolve[index].resolvedAt = now
            }
        }

        try store.withTransaction {
            try store.upsertRuntimeSessionBinding(binding)
            if let run {
                try store.upsertRun(run)
            }
            for entry in sendingEntries {
                try store.upsertChatEntry(entry)
            }
            if let interaction {
                try store.upsertRuntimeInteraction(interaction)
            }
            for resolved in interactionsToResolve {
                try store.upsertRuntimeInteraction(resolved)
            }
            try store.appendEvent(
                LedgerEvent(
                    projectID: binding.projectID,
                    actorID: binding.actorID,
                    principalID: binding.principalID,
                    workspaceID: binding.workspaceID,
                    approvalID:
                        interaction?
                        .projectApprovalID,
                    taskID: binding.taskID,
                    runID: binding.runID,
                    type: "openworker.\(event.type)",
                    summary: event.summary,
                    payload: openWorkerLedgerPayload(binding: binding, event: event)
                )
            )
        }
        switch event.type {
        case "turn_start", "assistant_message", "turn_done":
            try finalizeOpenWorkerContextDeliveryIfNeeded(
                binding: binding,
                status: .delivered,
                adapterReceiptMaterial:
                    "openworker|\(binding.nativeSessionID)|\(event.type)|"
                    + (event.data["turn_id"]?.stringValue ?? "")
            )
        case "input_rejected":
            try finalizeOpenWorkerContextDeliveryIfNeeded(
                binding: binding,
                status: .failed,
                failureCode: "openworker_input_rejected"
            )
        case "connection_closed":
            try finalizeOpenWorkerContextDeliveryIfNeeded(
                binding: binding,
                status: .failed,
                failureCode:
                    "openworker_connection_closed_before_ack"
            )
        default:
            break
        }
        return interaction
    }

    public func recordOpenWorkerConnectionFailure(
        bindingID: UUID,
        error: Error
    ) async throws {
        await openWorkerSyncGate.acquire(bindingID)
        do {
            try recordOpenWorkerConnectionFailureUnlocked(
                bindingID: bindingID,
                error: error
            )
            await openWorkerSyncGate.release(bindingID)
        } catch {
            await openWorkerSyncGate.release(bindingID)
            throw error
        }
    }

    private func recordOpenWorkerConnectionFailureUnlocked(
        bindingID: UUID,
        error: Error
    ) throws {
        guard var binding = try store.fetchRuntimeSessionBinding(id: bindingID),
              binding.state != .detached else {
            return
        }
        binding.state = .disconnected
        binding.lastActivitySummary = "Could not connect to the native OpenWorker session."
        binding.lastError = error.localizedDescription
        binding.updatedAt = Date()
        var run = try binding.runID.flatMap { try store.fetchRun(id: $0) }
        if run?.state == .starting || run?.state == .active {
            run?.state = .degraded
            run?.updatedAt = Date()
        }
        try store.withTransaction {
            try store.upsertRuntimeSessionBinding(binding)
            if let run {
                try store.upsertRun(run)
            }
            try store.appendEvent(
                LedgerEvent(
                    taskID: binding.taskID,
                    runID: binding.runID,
                    type: "openworker.connection_failed",
                    summary: binding.lastActivitySummary,
                    payload: [
                        "binding_id": binding.id.uuidString,
                        "native_session_id": binding.nativeSessionID,
                        "error": String(error.localizedDescription.prefix(2_000))
                    ]
                )
            )
        }
        try finalizeOpenWorkerContextDeliveryIfNeeded(
            binding: binding,
            status: .failed,
            failureCode:
                "openworker_connection_failed_before_ack"
        )
    }

    public func resolveRuntimeInteraction(
        id: UUID,
        state: RuntimeInteractionState
    ) throws {
        guard var request = try store.fetchRuntimeInteraction(id: id),
              request.state == .pending else {
            throw MuError.invalidTransition("The OpenWorker request is no longer pending.")
        }
        request.state = state
        request.resolvedAt = Date()
        var projectApproval =
            try request.projectApprovalID.flatMap {
                approvalID in
                try store.fetchProjectApprovals()
                    .first {
                        $0.id == approvalID
                    }
            }
        if projectApproval?.decision == .pending {
            switch state {
            case .approved, .answered:
                projectApproval?.decision = .granted
            case .denied:
                projectApproval?.decision = .denied
            case .superseded:
                projectApproval?.decision = .expired
            case .pending:
                break
            }
            if projectApproval?.decision != .pending {
                projectApproval?.resolvedAt = Date()
            }
        }
        try store.withTransaction {
            try store.upsertRuntimeInteraction(request)
            if let projectApproval {
                try store.upsertProjectApproval(
                    projectApproval
                )
            }
            try store.appendEvent(
                LedgerEvent(
                    projectID: projectApproval?.projectID,
                    approvalID: projectApproval?.id,
                    taskID: request.taskID,
                    type: "runtime.interaction.resolved",
                    summary: "Resolved OpenWorker \(request.kind.rawValue) as \(state.rawValue).",
                    payload: [
                        "interaction_id": request.id.uuidString,
                        "binding_id": request.bindingID.uuidString,
                        "native_session_id": request.nativeSessionID,
                        "state": state.rawValue
                    ]
                )
            )
        }
    }

    public func resolveOpenWorkerInboxInteraction(
        id: UUID,
        resolution: String,
        state: RuntimeInteractionState
    ) async throws {
        guard var request = try store.fetchRuntimeInteraction(id: id),
              request.state == .pending else {
            throw MuError.invalidTransition("The OpenWorker request is no longer pending.")
        }
        if request.nativeRequestID == nil {
            _ = try await syncOpenWorkerSession(
                bindingID: request.bindingID,
                includeArtifacts: false
            )
            guard let refreshed = try store.fetchRuntimeInteraction(id: id),
                  refreshed.state == .pending else {
                throw MuError.invalidTransition(
                    "The OpenWorker request was resolved on another surface."
                )
            }
            request = refreshed
        }
        guard let nativeRequestID = request.nativeRequestID, !nativeRequestID.isEmpty else {
            throw MuError.invalidTransition(
                "OpenWorker has not published the durable Inbox request yet. Wait a moment and retry."
            )
        }
        guard let endpoint = try store.fetchRegisteredEndpoint(id: request.endpointID),
              endpoint.runtimeTypeID == Self.openWorkerRuntimeTypeID,
              endpoint.status == .active else {
            throw MuError.recordNotFound("Active OpenWorker runtime endpoint")
        }
        let client = OpenWorkerHTTPClient(
            configuration: try openWorkerConfiguration(for: endpoint)
        )
        let didResolve: Bool
        do {
            didResolve = try await client.resolveInbox(
                itemID: nativeRequestID,
                resolution: String(resolution.prefix(8_000))
            )
        } catch {
            _ = try? await syncOpenWorkerSession(
                bindingID: request.bindingID,
                includeArtifacts: false
            )
            if let current = try store.fetchRuntimeInteraction(id: id),
               current.state != .pending {
                return
            }
            throw MuError.commandFailed(
                "OpenWorker may have accepted the response, but Mu could not confirm it. "
                + "Wait for session reconciliation before responding again. "
                + error.localizedDescription
            )
        }
        guard didResolve else {
            _ = try? await syncOpenWorkerSession(
                bindingID: request.bindingID,
                includeArtifacts: false
            )
            throw MuError.invalidTransition(
                "This OpenWorker request was already answered on another surface."
            )
        }
        if let current = try store.fetchRuntimeInteraction(id: id),
           current.state == .pending {
            try resolveRuntimeInteraction(id: id, state: state)
        }
    }

    @discardableResult
    public func syncOpenWorkerSession(
        bindingID: UUID,
        includeArtifacts: Bool = true
    ) async throws -> RuntimeSessionBinding {
        try await syncOpenWorkerSessionReportingChanges(
            bindingID: bindingID,
            includeArtifacts: includeArtifacts
        ).binding
    }

    @discardableResult
    public func syncOpenWorkerSessionReportingChanges(
        bindingID: UUID,
        includeArtifacts: Bool = true
    ) async throws -> OpenWorkerSessionSyncResult {
        await openWorkerSyncGate.acquire(bindingID)
        do {
            let result = try await syncOpenWorkerSessionUnlocked(
                bindingID: bindingID,
                includeArtifacts: includeArtifacts
            )
            await openWorkerSyncGate.release(bindingID)
            return result
        } catch {
            await openWorkerSyncGate.release(bindingID)
            throw error
        }
    }

    private func syncOpenWorkerSessionUnlocked(
        bindingID: UUID,
        includeArtifacts: Bool
    ) async throws -> OpenWorkerSessionSyncResult {
        guard var binding = try store.fetchRuntimeSessionBinding(id: bindingID),
              binding.state != .detached else {
            throw MuError.recordNotFound("Active OpenWorker session binding \(bindingID)")
        }
        let previousBinding = binding
        let endpoint = try activeOpenWorkerEndpoint()
        guard binding.endpointID == endpoint.id else {
            throw MuError.invalidTransition("The session binding does not use OpenWorker.")
        }
        let client = OpenWorkerHTTPClient(
            configuration: try openWorkerConfiguration(for: endpoint)
        )
        let nativeSessionID = binding.nativeSessionID
        async let fetchedMessages = client.messages(sessionID: nativeSessionID)
        async let fetchedSessions = client.sessions()
        async let fetchedInbox = client.pendingInbox(sessionID: nativeSessionID)
        let (messages, sessions, inboxItems) = try await (
            fetchedMessages,
            fetchedSessions,
            fetchedInbox
        )
        let actionableInboxItems = inboxItems.filter {
            Self.runtimeInteractionKind(forOpenWorkerInboxKind: $0.kind) != nil
        }
        let nativeSummary = sessions.first { $0.sessionID == nativeSessionID }
        let isUndurableMuSession =
            nativeSummary == nil
                && binding.origin == "created_by_mu"
                && binding.lastSyncedMessageCount == 0
        let artifacts = if includeArtifacts, nativeSummary != nil {
            try await client.artifacts(sessionID: nativeSessionID)
        } else {
            [OpenWorkerArtifactInfo]()
        }
        if let nativeSummary {
            binding.model = nativeSummary.model
            binding.nativeAgentName = nativeSummary.agent
            if !nativeSummary.workspace.isEmpty {
                guard Self.sameWorkspace(
                    nativeSummary.workspace,
                    binding.workspacePath
                ) else {
                    throw MuError.invalidTransition(
                        "OpenWorker session workspace changed. Relink it explicitly."
                    )
                }
            }
            if !actionableInboxItems.isEmpty {
                binding.state = .awaitingApproval
            } else if nativeSummary.liveness == "working" {
                binding.state = .working
            } else if binding.state == .working
                        || binding.state == .connecting
                        || binding.state == .disconnected
                        || binding.state == .awaitingApproval {
                binding.state = .idle
                binding.lastError = nil
            }
        } else if isUndurableMuSession {
            // OpenWorker creates the durable session row lazily at turn_start. A Mu-created
            // binding is therefore valid (and dispatchable) before /v1/sessions can list it.
            binding.state = .idle
            binding.lastError = nil
        } else {
            binding.state = .disconnected
            binding.lastError = "The native OpenWorker session is no longer available."
        }
        let existingEntries = try store.fetchChatEntries(taskID: binding.taskID)
        let contextSnapshotsByID = Dictionary(
            uniqueKeysWithValues: try store.fetchContextSnapshots(
                taskID: binding.taskID
            ).map { ($0.id, $0) }
        )
        let previousMessageCount = binding.lastSyncedMessageCount
        let messagesToReconcile = nativeSummary == nil
            ? [OpenWorkerMessage]()
            : messages
        let startingIndex = min(
            binding.lastSyncedMessageCount,
            messagesToReconcile.count
        )
        var entriesToUpsert: [ChatEntry] = []
        var entryIDsToDelete = Set<UUID>()
        var reconciledNativeIndexes = Set<Int>()
        let agentName = try binding.agentIdentityID.flatMap {
            try store.fetchAgent(id: $0)?.displayName
        } ?? "OpenWorker"

        let bindingEntries = existingEntries.filter {
            $0.runtimeSessionBindingID == binding.id
        }
        var entriesByNativeIndex: [Int: [ChatEntry]] = [:]
        var activeOutboundByKey: [String: [ChatEntry]] = [:]
        var legacyDeliveredOutboundByKey: [String: [ChatEntry]] = [:]
        for entry in bindingEntries {
            if let nativeMessageIndex = entry.nativeMessageIndex {
                entriesByNativeIndex[nativeMessageIndex, default: []]
                    .append(entry)
                continue
            }
            let isActiveOutbound =
                entry.deliveryState == .sending
                    || entry.deliveryState == .ambiguous
                    || (entry.deliveryState == .delivered
                        && (entry.contextSnapshotID != nil
                            || entry.nativeMessageIndexLowerBound != nil))
            let isLegacyDeliveredOutbound =
                entry.deliveryState == .delivered
                    && entry.contextSnapshotID == nil
                    && entry.nativeMessageIndexLowerBound == nil
            guard isActiveOutbound || isLegacyDeliveredOutbound else {
                continue
            }
            let key = openWorkerOutboundReconciliationKey(
                for: entry,
                snapshotsByID: contextSnapshotsByID
            )
            if isActiveOutbound {
                activeOutboundByKey[key, default: []].append(entry)
            } else {
                legacyDeliveredOutboundByKey[key, default: []].append(entry)
            }
        }
        var activeOutboundOffsets: [String: Int] = [:]
        var legacyDeliveredOutboundOffsets: [String: Int] = [:]

        // Reconcile across the full native transcript, rather than only the new tail.
        // This repairs an older Mu build that could mirror a local, already-delivered
        // prompt as a second "OpenWorker user" row before attaching its native index.
        // Indexing by native position and a hashed outbound key keeps every poll linear
        // in the native transcript plus the local rows.
        for (index, message) in messagesToReconcile.enumerated()
            where message.role == "user" {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let mirroredDuplicates = (
                entriesByNativeIndex[index] ?? []
            ).filter {
                $0.deliveryState == .mirrored
                    && $0.authorKind == .user
                    && $0.authorName == "OpenWorker user"
                    && $0.text.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ) == text
            }
            let hasExistingUserAtIndex = (
                entriesByNativeIndex[index] ?? []
            ).contains {
                $0.authorKind == .user
                    && !entryIDsToDelete.contains($0.id)
            }
            let isUnclaimedNewNativeIndex =
                index >= startingIndex
                    && !hasExistingUserAtIndex
            let reconciliationKeys = openWorkerNativeReconciliationKeys(
                for: text
            )
            var choices: [
                (
                    key: String,
                    isLegacyDelivered: Bool,
                    entry: ChatEntry
                )
            ] = []
            for key in reconciliationKeys {
                let activeOffset = activeOutboundOffsets[key] ?? 0
                if let values = activeOutboundByKey[key],
                   activeOffset < values.count {
                    let candidate = values[activeOffset]
                    let isWithinCandidateCursor =
                        index
                            >= (candidate.nativeMessageIndexLowerBound
                                ?? 0)
                    let hasExplicitCursor =
                        candidate.nativeMessageIndexLowerBound != nil
                    let isExactLegacyContextRepair =
                        !mirroredDuplicates.isEmpty
                            && candidate.contextSnapshotID != nil
                    if isWithinCandidateCursor
                        && (hasExplicitCursor
                            || isUnclaimedNewNativeIndex
                            || isExactLegacyContextRepair) {
                        choices.append(
                            (key, false, candidate)
                        )
                    }
                }
                guard !mirroredDuplicates.isEmpty else { continue }
                let legacyOffset =
                    legacyDeliveredOutboundOffsets[key] ?? 0
                if let values = legacyDeliveredOutboundByKey[key],
                   legacyOffset < values.count {
                    let candidate = values[legacyOffset]
                    if index
                        >= (candidate.nativeMessageIndexLowerBound ?? 0) {
                        choices.append(
                            (key, true, candidate)
                        )
                    }
                }
            }
            let selected = if let timestamp = message.timestamp {
                choices.min {
                    abs(
                        $0.entry.createdAt.timeIntervalSince1970
                            - timestamp
                    ) < abs(
                        $1.entry.createdAt.timeIntervalSince1970
                            - timestamp
                    )
                }
            } else {
                choices.min {
                    $0.entry.createdAt < $1.entry.createdAt
                }
            }
            guard let selected,
                  openWorkerMessageMatchesOutbound(
                      nativeText: text,
                      outbound: selected.entry,
                      snapshotsByID: contextSnapshotsByID
                  ) else {
                continue
            }
            if selected.isLegacyDelivered {
                legacyDeliveredOutboundOffsets[selected.key] =
                    (legacyDeliveredOutboundOffsets[selected.key] ?? 0) + 1
            } else {
                activeOutboundOffsets[selected.key] =
                    (activeOutboundOffsets[selected.key] ?? 0) + 1
            }
            var outbound = selected.entry
            reconciledNativeIndexes.insert(index)
            outbound.nativeMessageIndex = index
            outbound.deliveryState = .delivered
            Self.redactImportedContextPayload(
                &outbound,
                snapshotsByID: contextSnapshotsByID
            )
            outbound.updatedAt = Date()
            entriesToUpsert.append(outbound)
            for duplicate in mirroredDuplicates where duplicate.id != outbound.id {
                entryIDsToDelete.insert(duplicate.id)
            }
        }

        for index in startingIndex..<messagesToReconcile.count {
            let message = messagesToReconcile[index]
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, message.role != "system" else { continue }
            if message.role == "user", reconciledNativeIndexes.contains(index) {
                continue
            } else if message.role == "assistant" {
                guard !(entriesByNativeIndex[index] ?? []).contains(
                    where: { !entryIDsToDelete.contains($0.id) }
                ) else { continue }
                entriesToUpsert.append(
                    ChatEntry(
                        taskID: binding.taskID,
                        agentIdentityID: binding.agentIdentityID,
                        runtimeSessionBindingID: binding.id,
                        nativeMessageIndex: index,
                        deliveryState: .mirrored,
                        authorKind: .agent,
                        authorName: agentName,
                        text: text,
                        createdAt: message.timestamp.map {
                            Date(timeIntervalSince1970: $0)
                        } ?? Date()
                    )
                )
            } else if message.role == "notice" {
                guard !(entriesByNativeIndex[index] ?? []).contains(
                    where: { !entryIDsToDelete.contains($0.id) }
                ) else { continue }
                entriesToUpsert.append(
                    ChatEntry(
                        taskID: binding.taskID,
                        runtimeSessionBindingID: binding.id,
                        nativeMessageIndex: index,
                        deliveryState: .mirrored,
                        authorKind: .system,
                        authorName: "OpenWorker",
                        text: text,
                        createdAt: message.timestamp.map {
                            Date(timeIntervalSince1970: $0)
                        } ?? Date()
                    )
                )
            } else if message.role == "user" {
                guard !(entriesByNativeIndex[index] ?? []).contains(
                    where: { !entryIDsToDelete.contains($0.id) }
                ) else { continue }
                entriesToUpsert.append(
                    ChatEntry(
                        taskID: binding.taskID,
                        runtimeSessionBindingID: binding.id,
                        nativeMessageIndex: index,
                        deliveryState: .mirrored,
                        authorKind: .user,
                        authorName: "OpenWorker user",
                        text: text,
                        createdAt: message.timestamp.map {
                            Date(timeIntervalSince1970: $0)
                        } ?? Date()
                    )
                )
            }
        }

        let existingArtifacts = try store.fetchRuntimeArtifacts(taskID: binding.taskID)
        var artifactRecords: [RuntimeArtifactRecord] = []
        for artifact in artifacts {
            guard let safePath = Self.validatedOpenWorkerArtifactPath(
                artifact,
                workspacePath: binding.workspacePath
            ) else {
                continue
            }
            let existing = existingArtifacts.first {
                $0.bindingID == binding.id
                    && $0.relativePath == safePath.relativePath
            }
            let modifiedAt = Date(timeIntervalSince1970: artifact.modifiedAt)
            if let existing,
               existing.absolutePath == safePath.absolutePath,
               existing.name == artifact.name,
               existing.kind == artifact.kind,
               existing.byteCount == artifact.size,
               abs(existing.modifiedAt.timeIntervalSince(modifiedAt)) < 0.001 {
                continue
            }
            artifactRecords.append(
                RuntimeArtifactRecord(
                    id: existing?.id ?? UUID(),
                    taskID: binding.taskID,
                    bindingID: binding.id,
                    endpointID: endpoint.id,
                    nativeSessionID: binding.nativeSessionID,
                    relativePath: safePath.relativePath,
                    absolutePath: safePath.absolutePath,
                    name: artifact.name,
                    kind: artifact.kind,
                    byteCount: artifact.size,
                    modifiedAt: modifiedAt
                )
            )
        }
        var projectArtifactRecords:
            [ProjectArtifactRecord] = []
        if let projectID = binding.projectID {
            for index in artifactRecords.indices {
                guard let absolutePath =
                    artifactRecords[index].absolutePath,
                      artifactRecords[index].byteCount
                        <= 64 * 1_024 * 1_024,
                      let data = try? Data(
                          contentsOf: URL(
                              fileURLWithPath: absolutePath
                          ),
                          options: .mappedIfSafe
                      ),
                      let reference =
                        try? artifactStore.put(data)
                else {
                    continue
                }
                let projectArtifact =
                    ProjectArtifactRecord(
                        projectID: projectID,
                        taskID: binding.taskID,
                        producerActorID:
                            binding.actorID,
                        kind: Self.projectArtifactKind(
                            openWorkerKind:
                                artifactRecords[index]
                                .kind
                        ),
                        title:
                            "OpenWorker · "
                            + artifactRecords[index].name,
                        uri: reference.uri,
                        sha256: reference.sha256,
                        status: .submitted,
                        metadata: [
                            "provider":
                                ConversationProvider
                                .openWorker.rawValue,
                            "native_session_id":
                                binding.nativeSessionID,
                            "relative_path":
                                artifactRecords[index]
                                .relativePath,
                            "byte_count":
                                String(
                                    artifactRecords[index]
                                    .byteCount
                                )
                        ]
                    )
                artifactRecords[index]
                    .projectArtifactID =
                    projectArtifact.id
                projectArtifactRecords.append(
                    projectArtifact
                )
            }
        }

        let existingInteractions = try store.fetchRuntimeInteractions(taskID: binding.taskID)
            .filter { $0.bindingID == binding.id }
        var interactionRecords: [RuntimeInteractionRequest] = []
        var matchedInteractionIDs = Set<UUID>()
        let pendingNativeRequestIDs = Set(actionableInboxItems.map(\.id))
        for item in actionableInboxItems {
            guard let kind = Self.runtimeInteractionKind(
                forOpenWorkerInboxKind: item.kind
            ) else { continue }
            let exact = existingInteractions.first {
                $0.nativeRequestID == item.id
            }
            let unbound = existingInteractions.first {
                $0.state == .pending
                    && $0.kind == kind
                    && $0.nativeRequestID == nil
                    && !matchedInteractionIDs.contains($0.id)
            }
            var request = exact
                ?? unbound
                ?? makeOpenWorkerInteraction(binding: binding, inboxItem: item, kind: kind)
            let original = exact ?? unbound
            request.nativeRequestID = item.id
            request.title = String(item.title.prefix(1_000))
            request.detail = String(item.body.prefix(4_000))
            request.payload = openWorkerInteractionPayload(inboxItem: item)
            request.state = .pending
            request.resolvedAt = nil
            matchedInteractionIDs.insert(request.id)
            if original != request {
                interactionRecords.append(request)
            }
        }
        for existing in existingInteractions where
            existing.state == .pending
                && existing.nativeRequestID != nil
                && !pendingNativeRequestIDs.contains(existing.nativeRequestID ?? "") {
            var resolved = existing
            resolved.state = .superseded
            resolved.resolvedAt = Date()
            interactionRecords.append(resolved)
        }
        for index in interactionRecords.indices
            where interactionRecords[index].state == .pending
                && interactionRecords[index]
                    .projectApprovalID == nil {
            _ = try createProjectApproval(
                interaction:
                    &interactionRecords[index],
                requestedByActorID:
                    binding.actorID,
                scope:
                    "openworker."
                    + interactionRecords[index]
                        .kind.rawValue
            )
        }

        let bindingChangedBySync = previousBinding != binding
        let latestBinding = try store.fetchRuntimeSessionBinding(id: binding.id)
        guard latestBinding?.state != .detached else {
            throw MuError.invalidTransition(
                "The OpenWorker session was detached while it was synchronizing."
            )
        }
        let hasConcurrentBindingMutation =
            latestBinding.map { $0.updatedAt > previousBinding.updatedAt } ?? false
        if let latestBinding, hasConcurrentBindingMutation {
            binding.state = latestBinding.state
            binding.lastActivitySummary = latestBinding.lastActivitySummary
            binding.lastError = latestBinding.lastError
            binding.nativeAgentName = latestBinding.nativeAgentName
            binding.model = latestBinding.model
            binding.workspacePath = latestBinding.workspacePath
        }

        let hasChanges = previousMessageCount != messagesToReconcile.count
            || !entriesToUpsert.isEmpty
            || !entryIDsToDelete.isEmpty
            || !artifactRecords.isEmpty
            || !interactionRecords.isEmpty
            || bindingChangedBySync
        guard hasChanges else {
            return OpenWorkerSessionSyncResult(
                binding: latestBinding ?? binding,
                didChange: false
            )
        }
        binding.lastSyncedMessageCount = messagesToReconcile.count
        if !hasConcurrentBindingMutation {
            binding.lastActivitySummary =
                "Synced \(messagesToReconcile.count) native messages, "
                + "\(artifacts.count) artifacts, and "
                + "\(actionableInboxItems.count) pending requests."
        }
        binding.updatedAt = Date()
        var run = try binding.runID.flatMap { try store.fetchRun(id: $0) }
        if !hasConcurrentBindingMutation {
            if !actionableInboxItems.isEmpty {
                run?.state = .blocked
            } else if let terminalNotice = Self.terminalOpenWorkerNotice(
                in: messagesToReconcile
            ) {
                binding.state = .idle
                binding.lastError = terminalNotice.text.isEmpty
                    ? "The last OpenWorker turn ended as \(terminalNotice.kind ?? "error")."
                    : terminalNotice.text
                run?.state = .degraded
            } else if (run?.state == .blocked
                        || run?.state == .ambiguous
                        || run?.state == .degraded),
                      binding.lastError == nil,
                      binding.state == .idle || binding.state == .working {
                run?.state = .active
            }
        }
        if let latestAssistant = messagesToReconcile.last(where: {
            $0.role == "assistant"
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            run?.nativeOutput = latestAssistant.text
            run?.plan = Self.planLines(from: latestAssistant.text)
            run?.updatedAt = Date()
        }

        try store.withTransaction {
            for entryID in entryIDsToDelete {
                try store.deleteChatEntry(id: entryID)
            }
            for entry in entriesToUpsert {
                try store.upsertChatEntry(entry)
            }
            for artifact in artifactRecords {
                try store.upsertRuntimeArtifact(artifact)
            }
            for artifact in projectArtifactRecords {
                try store.upsertProjectArtifact(artifact)
            }
            for interaction in interactionRecords {
                if let current = try store.fetchRuntimeInteraction(id: interaction.id),
                   current.state != .pending,
                   current.state != interaction.state {
                    continue
                }
                try store.upsertRuntimeInteraction(interaction)
            }
            try store.upsertRuntimeSessionBinding(binding)
            if let run {
                try store.upsertRun(run)
            }
            try store.appendEvent(
                LedgerEvent(
                    projectID: binding.projectID,
                    actorID: binding.actorID,
                    principalID: binding.principalID,
                    workspaceID: binding.workspaceID,
                    taskID: binding.taskID,
                    runID: binding.runID,
                    type: "runtime.session.synced",
                    summary: binding.lastActivitySummary,
                    payload: [
                        "binding_id": binding.id.uuidString,
                        "native_session_id": binding.nativeSessionID,
                        "message_count": String(messagesToReconcile.count),
                        "new_chat_entries": String(entriesToUpsert.count),
                        "removed_duplicate_chat_entries": String(entryIDsToDelete.count),
                        "artifact_count": String(artifacts.count),
                        "project_artifact_count":
                            String(
                                projectArtifactRecords.count
                            ),
                        "pending_request_count": String(actionableInboxItems.count),
                        "updated_interactions": String(interactionRecords.count)
                    ]
                )
            )
        }
        return OpenWorkerSessionSyncResult(
            binding: binding,
            didChange: true
        )
    }

    private static func projectArtifactKind(
        openWorkerKind: String
    ) -> ProjectArtifactKind {
        switch openWorkerKind.lowercased() {
        case "patch", "diff":
            .patch
        case "document", "markdown", "text":
            .document
        case "dataset", "csv", "json":
            .dataset
        case "test", "test_result", "report":
            .testResult
        default:
            .runtimeOutput
        }
    }

    @discardableResult
    public func captureCheckpoint(taskID: UUID) throws -> CheckpointRecord {
        guard let task = try store.fetchTask(id: taskID) else {
            throw MuError.recordNotFound("Task \(taskID)")
        }
        guard task.status == .running || task.status == .blocked else {
            throw MuError.invalidTransition("A Checkpoint can be captured only from a running or blocked Task.")
        }
        guard let sourceEndpointID = task.currentEndpointID,
              let endpoint = try store.fetchRegisteredEndpoint(id: sourceEndpointID) else {
            throw MuError.recordNotFound("Current runtime endpoint")
        }
        guard endpoint.capabilities.contains(.contributeCheckpointEvidence),
              endpoint.capabilities.contains(.discoverGitArtifacts) else {
            throw MuError.capabilityMissing(
                "\(endpoint.displayName) cannot contribute Checkpoint and Git evidence."
            )
        }

        let repository = try repositoryProbe.capture(path: task.repositoryPath)
        let content = CheckpointContent(
            taskID: task.id,
            sourceRunID: task.currentRunID,
            sourceEndpointID: sourceEndpointID,
            objective: task.objective,
            successCriteria: task.successCriteria,
            pendingSteps: task.pendingSteps,
            constraints: task.constraints,
            repository: repository
        )
        let checkpoint = CheckpointRecord(
            taskID: task.id,
            sourceEndpointID: sourceEndpointID,
            contentHash: try CheckpointHasher.hash(content),
            content: content
        )

        try store.withTransaction {
            guard try store.fetchRegisteredEndpoint(id: sourceEndpointID) != nil else {
                throw MuError.recordNotFound("Current runtime endpoint")
            }
            try store.insertCheckpoint(checkpoint)
            try store.appendEvent(
                LedgerEvent(
                    taskID: task.id,
                    runID: task.currentRunID,
                    type: "checkpoint.validated",
                    summary: "Captured immutable Checkpoint \(checkpoint.contentHash.prefix(19))…",
                    payload: [
                        "checkpoint_id": checkpoint.id.uuidString,
                        "content_hash": checkpoint.contentHash,
                        "head_commit": repository.headCommit,
                        "capture_mode": "non_exclusive"
                    ]
                )
            )
        }
        return checkpoint
    }

    @discardableResult
    public func proposeHandoff(
        taskID: UUID,
        checkpointID: UUID,
        receiverEndpointID: UUID
    ) throws -> HandoffRecord {
        guard var task = try store.fetchTask(id: taskID) else {
            throw MuError.recordNotFound("Task \(taskID)")
        }
        guard task.status == .running || task.status == .blocked else {
            throw MuError.invalidTransition("Task must be running or blocked before Handoff.")
        }
        guard let checkpoint = try store.fetchCheckpoint(id: checkpointID),
              checkpoint.taskID == taskID else {
            throw MuError.recordNotFound("Checkpoint \(checkpointID)")
        }
        guard let receiver = try store.fetchRegisteredEndpoint(id: receiverEndpointID) else {
            throw MuError.recordNotFound("Receiver endpoint \(receiverEndpointID)")
        }
        guard checkpoint.sourceEndpointID != receiverEndpointID else {
            throw MuError.invalidTransition("The first slice requires a different receiver endpoint.")
        }
        guard receiver.status == .active else {
            throw MuError.capabilityMissing("Receiver endpoint is not active.")
        }
        let required: Set<RuntimeCapability> = [.start, .replan]
        let missing = required.subtracting(receiver.capabilities)
        guard missing.isEmpty else {
            let names = missing.map(\.displayName).sorted().joined(separator: ", ")
            throw MuError.capabilityMissing("\(receiver.displayName) is missing: \(names).")
        }
        let hasPending = try store.fetchHandoffs(taskID: taskID).contains {
            $0.status == .proposed || $0.status == .validating
        }
        guard !hasPending else {
            throw MuError.invalidTransition("This Task already has a pending Handoff.")
        }

        let handoff = HandoffRecord(
            taskID: taskID,
            checkpointID: checkpointID,
            sourceEndpointID: checkpoint.sourceEndpointID,
            receiverEndpointID: receiverEndpointID,
            validationMessage: "Receiver advertises Start + Replan. Acceptance will create a new Run."
        )
        task.status = .handoffPending
        task.updatedAt = Date()

        try store.withTransaction {
            guard try store.fetchRegisteredEndpoint(id: receiverEndpointID) != nil else {
                throw MuError.recordNotFound("Receiver endpoint \(receiverEndpointID)")
            }
            try store.upsertHandoff(handoff)
            try store.upsertTask(task)
            try store.appendEvent(
                LedgerEvent(
                    taskID: taskID,
                    runID: task.currentRunID,
                    type: "handoff.proposed",
                    summary: "Proposed Handoff to \(receiver.displayName).",
                    payload: [
                        "handoff_id": handoff.id.uuidString,
                        "checkpoint_id": checkpoint.id.uuidString,
                        "receiver_endpoint_id": receiverEndpointID.uuidString
                    ]
                )
            )
        }
        return handoff
    }

    @discardableResult
    public func acceptHandoff(id: UUID) throws -> RunRecord {
        guard var handoff = try store.fetchHandoffs().first(where: { $0.id == id }) else {
            throw MuError.recordNotFound("Handoff \(id)")
        }
        guard handoff.status == .proposed else {
            throw MuError.invalidTransition("Only a proposed Handoff can be accepted.")
        }
        guard var task = try store.fetchTask(id: handoff.taskID),
              let checkpoint = try store.fetchCheckpoint(id: handoff.checkpointID),
              let receiver = try store.fetchRegisteredEndpoint(id: handoff.receiverEndpointID) else {
            throw MuError.recordNotFound("Handoff inputs")
        }
        try validateArtifacts(in: checkpoint)

        let replan = makeReplan(checkpoint: checkpoint, receiver: receiver)
        let assignedAgent = try task.assignedAgentIdentityID.flatMap {
            try store.fetchAgent(id: $0)
        }
        let receivingRun = RunRecord(
            taskID: task.id,
            endpointID: receiver.id,
            actorName: assignedAgent?.displayName ?? receiver.displayName,
            purpose: .replan,
            state: .active,
            plan: replan,
            agentIdentityID: assignedAgent?.id
        )
        let previousRunID = task.currentRunID

        handoff.status = .accepted
        handoff.validationMessage = "Checkpoint schema and CAS evidence validated. Receiver Replan created."
        handoff.resolvedAt = Date()
        task.status = .running
        task.currentEndpointID = receiver.id
        task.currentRunID = receivingRun.id
        task.updatedAt = Date()

        try store.withTransaction {
            guard try store.fetchRegisteredEndpoint(id: receiver.id) != nil else {
                throw MuError.recordNotFound("Handoff receiver endpoint")
            }
            if let previousRunID, var previousRun = try store.fetchRun(id: previousRunID) {
                previousRun.state = .completed
                previousRun.updatedAt = Date()
                try store.upsertRun(previousRun)
            }
            try store.upsertHandoff(handoff)
            try store.upsertRun(receivingRun)
            try store.upsertTask(task)
            let acceptedEventID = UUID()
            try store.appendEvent(
                LedgerEvent(
                    id: acceptedEventID,
                    taskID: task.id,
                    runID: previousRunID,
                    type: "handoff.accepted",
                    summary: "Accepted Handoff; source ownership was fenced.",
                    payload: [
                        "handoff_id": handoff.id.uuidString,
                        "receiver_endpoint_id": receiver.id.uuidString
                    ]
                )
            )
            try store.appendEvent(
                LedgerEvent(
                    taskID: task.id,
                    runID: receivingRun.id,
                    type: "replan.created",
                    summary: "Created mandatory receiving Replan with \(replan.count) steps.",
                    payload: [
                        "checkpoint_hash": checkpoint.contentHash,
                        "runtime_type_id": receiver.runtimeTypeID
                    ],
                    causalParentID: acceptedEventID
                )
            )
        }
        return receivingRun
    }

    public func rejectHandoff(id: UUID, reason: String) throws {
        guard var handoff = try store.fetchHandoffs().first(where: { $0.id == id }) else {
            throw MuError.recordNotFound("Handoff \(id)")
        }
        guard handoff.status == .proposed else {
            throw MuError.invalidTransition("Only a proposed Handoff can be rejected.")
        }
        guard var task = try store.fetchTask(id: handoff.taskID) else {
            throw MuError.recordNotFound("Task \(handoff.taskID)")
        }

        handoff.status = .rejected
        handoff.rejectionReason = reason.isEmpty ? "Rejected by receiver." : reason
        handoff.resolvedAt = Date()
        task.status = .running
        task.updatedAt = Date()

        try store.withTransaction {
            try store.upsertHandoff(handoff)
            try store.upsertTask(task)
            try store.appendEvent(
                LedgerEvent(
                    taskID: task.id,
                    runID: task.currentRunID,
                    type: "handoff.rejected",
                    summary: "Receiver rejected the Handoff.",
                    payload: [
                        "handoff_id": handoff.id.uuidString,
                        "reason": handoff.rejectionReason ?? ""
                    ]
                )
            )
        }
    }

    func activeOpenWorkerEndpoint() throws -> RuntimeEndpoint {
        guard let endpoint = try store.fetchRegisteredEndpoint(
            id: Self.openWorkerEndpointID
        ),
        endpoint.runtimeTypeID == Self.openWorkerRuntimeTypeID,
        endpoint.status == .active,
        endpoint.capabilities.contains(.continueRun),
        endpoint.capabilities.contains(.streamEvents) else {
            throw MuError.capabilityMissing(
                "The live OpenWorker session adapter is not active. Run its capability probe."
            )
        }
        return endpoint
    }

    func openWorkerConfiguration(
        for endpoint: RuntimeEndpoint
    ) throws -> OpenWorkerClientConfiguration {
        let configuredURL = endpoint.nativeConfiguration?["base_url"].flatMap(URL.init(string:))
        guard let baseURL = configuredURL else {
            throw MuError.commandFailed(
                "OpenWorker has no verified loopback endpoint. Open OpenWorker and re-probe."
            )
        }
        return try OpenWorkerClientConfiguration(baseURL: baseURL)
    }

    func currentRuntimeSessionBinding(
        taskID: UUID,
        endpointID: UUID,
        agentIdentityID: UUID?
    ) throws -> RuntimeSessionBinding? {
        let candidates = try store.fetchRuntimeSessionBindings(taskID: taskID)
            .filter {
                $0.endpointID == endpointID
                    && $0.state != .detached
                    && $0.state != .failed
                    && $0.state != .disconnected
            }
            .sorted { $0.updatedAt > $1.updatedAt }
        if let agentIdentityID {
            return candidates.first { $0.agentIdentityID == agentIdentityID }
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    private func makeOpenWorkerInteraction(
        binding: RuntimeSessionBinding,
        event: OpenWorkerEvent,
        kind: RuntimeInteractionKind,
        title: String
    ) -> RuntimeInteractionRequest {
        var payload: [String: String] = [:]
        for key in [
            "name", "reason", "category", "path", "writable", "plan",
            "question", "options", "arguments"
        ] {
            guard let value = event.data[key] else { continue }
            payload[key] = String(value.compactDescription.prefix(4_000))
        }
        let detail = event.data["reason"]?.stringValue
            ?? event.data["plan"]?.stringValue
            ?? event.data["path"]?.stringValue
            ?? ""
        return RuntimeInteractionRequest(
            taskID: binding.taskID,
            bindingID: binding.id,
            endpointID: binding.endpointID,
            nativeSessionID: binding.nativeSessionID,
            kind: kind,
            title: title,
            detail: String(detail.prefix(4_000)),
            payload: payload
        )
    }

    private static func runtimeInteractionKind(
        forOpenWorkerInboxKind kind: String
    ) -> RuntimeInteractionKind? {
        switch kind.lowercased() {
        case "approval": .approval
        case "directory": .directory
        case "plan": .plan
        case "question": .question
        default: nil
        }
    }

    private func finalizeOpenWorkerContextDeliveryIfNeeded(
        binding: RuntimeSessionBinding,
        status: ContextDeliveryStatus,
        adapterReceiptMaterial: String? = nil,
        failureCode: String? = nil
    ) throws {
        guard status != .prepared,
              let projectID = binding.projectID,
              let packID = binding.contextPackID,
              let runID = binding.runID else {
            return
        }
        let receipts = try store.fetchContextDeliveries(
            projectID: projectID,
            taskID: binding.taskID
        ).filter {
            $0.contextPackID == packID
                && $0.runtimeBindingID == binding.id
                && $0.runID == runID
        }
        guard receipts.contains(where: {
            $0.status == .prepared
        }), !receipts.contains(where: {
            $0.status == .delivered
                || $0.status == .failed
        }) else {
            return
        }
        try recordContextDelivery(
            projectID: projectID,
            packID: packID,
            status: status,
            adapterReceiptMaterial:
                adapterReceiptMaterial,
            failureCode: failureCode
        )
    }

    private func makeOpenWorkerInteraction(
        binding: RuntimeSessionBinding,
        inboxItem: OpenWorkerInboxItem,
        kind: RuntimeInteractionKind
    ) -> RuntimeInteractionRequest {
        RuntimeInteractionRequest(
            taskID: binding.taskID,
            bindingID: binding.id,
            endpointID: binding.endpointID,
            nativeSessionID: binding.nativeSessionID,
            nativeRequestID: inboxItem.id,
            kind: kind,
            title: String(inboxItem.title.prefix(1_000)),
            detail: String(inboxItem.body.prefix(4_000)),
            payload: openWorkerInteractionPayload(inboxItem: inboxItem)
        )
    }

    private func openWorkerInteractionPayload(
        inboxItem: OpenWorkerInboxItem
    ) -> [String: String] {
        var payload: [String: String] = [
            "native_request_id": inboxItem.id,
            "visibility": inboxItem.visibility,
            "allow_text": String(inboxItem.allowText),
            "multi": String(inboxItem.multi)
        ]
        if let toolCallID = inboxItem.toolCallID {
            payload["tool_call_id"] = String(toolCallID.prefix(1_000))
        }
        if !inboxItem.options.isEmpty {
            payload["options"] = String(
                inboxItem.options.joined(separator: "\n").prefix(4_000)
            )
        }
        for (key, value) in inboxItem.data {
            payload[key] = String(value.compactDescription.prefix(4_000))
        }
        return payload
    }

    private static func validatedOpenWorkerArtifactPath(
        _ artifact: OpenWorkerArtifactInfo,
        workspacePath: String
    ) -> (relativePath: String, absolutePath: String?)? {
        let relativePath = artifact.path.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
            return nil
        }
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !components.contains(where: { $0.isEmpty || $0 == ".." }) else {
            return nil
        }

        let root = URL(fileURLWithPath: workspacePath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let expected = root.appending(path: relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard expected.path.hasPrefix(rootPrefix) else { return nil }

        guard let reportedAbsolutePath = artifact.absolutePath else {
            return (relativePath, nil)
        }
        let reported = URL(fileURLWithPath: reportedAbsolutePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard reported.path == expected.path,
              reported.path.hasPrefix(rootPrefix) else {
            return nil
        }
        return (relativePath, reported.path)
    }

    private static func sameWorkspace(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath().path
            == URL(fileURLWithPath: rhs, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath().path
    }

    private static func terminalOpenWorkerNotice(
        in messages: [OpenWorkerMessage]
    ) -> OpenWorkerMessage? {
        for message in messages.reversed() {
            guard message.role == "notice" else { return nil }
            if message.kind == "model_switch" {
                continue
            }
            return message.kind == "error" || message.kind == "interrupted"
                ? message
                : nil
        }
        return nil
    }

    private func openWorkerLedgerPayload(
        binding: RuntimeSessionBinding,
        event: OpenWorkerEvent
    ) -> [String: String] {
        var payload = [
            "binding_id": binding.id.uuidString,
            "endpoint_id": binding.endpointID.uuidString,
            "native_session_id": binding.nativeSessionID,
            "native_agent": binding.nativeAgentName,
            "event_type": event.type
        ]
        for key in ["name", "status", "category", "standing_rule"] {
            if let value = event.data[key]?.stringValue {
                payload[key] = String(value.prefix(1_000))
            }
        }
        if event.type == "error" || event.type == "input_rejected"
            || event.type == "connection_closed" {
            payload["error"] = String(
                (event.data["error"]?.stringValue ?? event.summary).prefix(2_000)
            )
        }
        return payload
    }

    private func validateArtifacts(in checkpoint: CheckpointRecord) throws {
        let repository = checkpoint.content.repository
        if let uri = repository.trackedPatchURI,
           let hash = repository.trackedPatchSHA256,
           !artifactStore.verify(uri: uri, expectedSHA256: hash) {
            throw MuError.invalidTransition("Tracked patch evidence failed hash validation.")
        }
        if let uri = repository.untrackedManifestURI,
           let hash = repository.untrackedManifestSHA256,
           !artifactStore.verify(uri: uri, expectedSHA256: hash) {
            throw MuError.invalidTransition("Untracked manifest evidence failed hash validation.")
        }
        let recalculated = try CheckpointHasher.hash(checkpoint.content)
        guard recalculated == checkpoint.contentHash else {
            throw MuError.invalidTransition("Checkpoint content hash does not match the sealed record.")
        }
    }

    private func makeReplan(
        checkpoint: CheckpointRecord,
        receiver: RuntimeEndpoint
    ) -> [String] {
        var plan = [
            "Validate Checkpoint \(checkpoint.contentHash.prefix(19))… and repository HEAD \(checkpoint.content.repository.headCommit.prefix(10)).",
            "Confirm all \(checkpoint.content.constraints.count) transferred constraints before mutation."
        ]
        plan.append(contentsOf: checkpoint.content.constraints.map { "Respect constraint: \($0)" })
        if checkpoint.content.repository.isDirty {
            plan.append("Review the sealed dirty patch and \(checkpoint.content.repository.untrackedFiles.count) untracked file(s).")
        }
        if checkpoint.content.pendingSteps.isEmpty {
            plan.append("Derive the next action from the objective: \(checkpoint.content.objective)")
        } else {
            plan.append(contentsOf: checkpoint.content.pendingSteps.map { "Continue: \($0)" })
        }
        if !checkpoint.content.successCriteria.isEmpty {
            plan.append("Verify: \(checkpoint.content.successCriteria.joined(separator: "; "))")
        }
        plan.append("Wait for user approval before \(receiver.displayName) executes the Replan.")
        return plan
    }

    private static func normalizedShortName(
        _ rawValue: String,
        fallbackName: String
    ) -> String {
        let explicit = rawValue
            .uppercased()
            .filter { $0.isLetter || $0.isNumber }
        if !explicit.isEmpty {
            return String(explicit.prefix(3))
        }
        let words = fallbackName.split(whereSeparator: { $0.isWhitespace })
        let initials = words.prefix(3).compactMap(\.first)
        if initials.count >= 2 {
            return String(initials).uppercased()
        }
        let fallback = fallbackName
            .uppercased()
            .filter { $0.isLetter || $0.isNumber }
        return String(fallback.prefix(2))
    }

    private static func codexVersion(from userAgent: String) -> String {
        guard let slash = userAgent.firstIndex(of: "/") else { return userAgent }
        let suffix = userAgent[userAgent.index(after: slash)...]
        return String(suffix.prefix { !$0.isWhitespace && $0 != "(" })
    }

    func persistRuntimeActivity(
        _ activity: RuntimeActivityEvent,
        taskID: UUID,
        runID: UUID,
        projectID: UUID,
        workspaceID: UUID,
        bindingID: UUID
    ) throws {
        var payload: [String: String] = [
            "phase": activity.phase,
            "status": activity.status,
            "binding_id": bindingID.uuidString
        ]
        if let id = activity.id { payload["activity_id"] = id }
        if let detail = activity.detail { payload["detail"] = Self.redactRuntimeActivity(detail) }
        if let toolName = activity.toolName { payload["tool_name"] = toolName }
        if let path = activity.path { payload["path"] = Self.redactRuntimeActivity(path) }
        if let command = activity.command { payload["command"] = Self.redactRuntimeActivity(command) }
        if let requestID = activity.requestID { payload["request_id"] = requestID }
        if let artifactID = activity.artifactID { payload["artifact_id"] = artifactID }
        try store.withTransaction {
            if var binding = try store.fetchRuntimeSessionBinding(id: bindingID) {
                binding.state = activity.status == "blocked" ? .awaitingApproval : .working
                binding.lastActivitySummary = activity.title
                binding.updatedAt = Date()
                try store.upsertRuntimeSessionBinding(binding)
            }
            try store.appendEvent(
                LedgerEvent(
                    projectID: projectID,
                    workspaceID: workspaceID,
                    taskID: taskID,
                    runID: runID,
                    type: "runtime.activity",
                    summary: Self.redactRuntimeActivity(activity.title),
                    payload: payload
                )
            )
        }
    }

    private static func redactRuntimeActivity(_ value: String) -> String {
        value
            .replacingOccurrences(
                of: #"(?i)(sk|key|token|secret)[-_][A-Za-z0-9._-]+"#,
                with: "[redacted]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)Bearer\s+[A-Za-z0-9._-]+"#,
                with: "Bearer [redacted]",
                options: .regularExpression
            )
    }

    private static func planLines(from output: String) -> [String] {
        let lines = output
            .split(separator: "\n")
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(
                        of: #"^(?:[-*]|\d+[.)])\s+"#,
                        with: "",
                        options: .regularExpression
                    )
            }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return Array(lines.prefix(40))
    }
}
