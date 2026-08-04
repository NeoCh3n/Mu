import Foundation

/// The user-visible surface that created or hosts an Agent session.
///
/// `terminalCLI` does not imply that Mu knows the originating TTY. Inspect
/// `identityBasis` or `hasConcreteTerminalIdentity` before presenting a
/// terminal name as authoritative.
public enum AgentRuntimeSurfaceKind:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Sendable
{
    case desktopApplication = "desktop_application"
    case terminalCLI = "terminal_cli"
    case editorExtension = "editor_extension"
    case automation
    case localService = "local_service"
    case remoteService = "remote_service"
    case historyArtifact = "history_artifact"
    case unknown

    public var displayName: String {
        switch self {
        case .desktopApplication: "Desktop"
        case .terminalCLI: "CLI"
        case .editorExtension: "Editor"
        case .automation: "Automation"
        case .localService: "Local service"
        case .remoteService: "Remote service"
        case .historyArtifact: "History artifact"
        case .unknown: "Unknown surface"
        }
    }
}

/// Describes what Mu actually used to distinguish an instance.
public enum AgentRuntimeIdentityBasis:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Sendable
{
    /// A product-level singleton, such as the one local Codex Desktop app.
    case desktopSingleton = "desktop_singleton"
    /// A terminal identifier was explicitly supplied by the runtime or user.
    case terminalIdentifier = "terminal_identifier"
    /// The vendor session is the narrowest reliable identity available.
    case sessionFallback = "session_fallback"
    /// The registered Mu endpoint is the narrowest reliable identity available.
    case endpointFallback = "endpoint_fallback"
    /// An installation or configuration root identifies the source.
    case installation
    /// No stronger identity evidence is available.
    case unknown
}

/// Stable keys understood by Runtime import/registration UI. They live in
/// `RuntimeEndpoint.nativeConfiguration` so older endpoint records remain
/// decodable and third-party adapters can opt in without a schema migration.
public enum RuntimeIdentityConfigurationKey {
    public static let provider = "identity.provider"
    public static let surfaceKind = "identity.surface_kind"
    public static let instanceLabel = "identity.instance_label"
    public static let terminalIdentifier = "identity.terminal_identifier"
    public static let workspacePath = "identity.workspace_path"
    public static let nativeSource = "identity.native_source"
    /// The model Mu should request when a Task does not override it.
    /// Stored as configuration rather than a schema field so legacy endpoint
    /// records remain decodable and adapters can opt in independently.
    public static let defaultModel = "default_model"
    /// Comma-separated model identifiers exposed by the Runtime host.
    public static let modelOptions = "model_options"
    public static let permissionModelSource = "permission_model_source"
}

public extension RuntimeEndpoint {
    /// A user-selected model for this endpoint, if one was persisted.
    var configuredDefaultModel: String? {
        guard let value = nativeConfiguration?[RuntimeIdentityConfigurationKey.defaultModel]
            else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    /// Model identifiers configured for the endpoint, de-duplicated while
    /// preserving the order in which the user entered them.
    var configuredModelOptions: [String] {
        guard let raw = nativeConfiguration?[RuntimeIdentityConfigurationKey.modelOptions]
            else { return [] }
        var seen = Set<String>()
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// Portable, user-facing identity for one Agent runtime instance or one
/// session-scoped fallback when a vendor does not persist terminal identity.
public struct AgentRuntimeInstanceIdentity:
    Codable,
    Hashable,
    Sendable
{
    public var provider: ConversationProvider
    public var surfaceKind: AgentRuntimeSurfaceKind
    public var identityBasis: AgentRuntimeIdentityBasis
    public var stableInstanceKey: String
    public var instanceLabel: String
    public var terminalIdentifier: String?
    public var executablePath: String?
    public var nativeSessionID: String?
    public var workspacePath: String?
    public var sourceLocation: String?
    public var nativeSource: String?

    public var hasConcreteTerminalIdentity: Bool {
        surfaceKind == .terminalCLI
            && identityBasis == .terminalIdentifier
            && terminalIdentifier?.isEmpty == false
    }

    public init(
        provider: ConversationProvider,
        surfaceKind: AgentRuntimeSurfaceKind,
        identityBasis: AgentRuntimeIdentityBasis,
        stableInstanceKey: String,
        instanceLabel: String,
        terminalIdentifier: String? = nil,
        executablePath: String? = nil,
        nativeSessionID: String? = nil,
        workspacePath: String? = nil,
        sourceLocation: String? = nil,
        nativeSource: String? = nil
    ) {
        self.provider = provider
        self.surfaceKind = surfaceKind
        self.identityBasis = identityBasis
        self.stableInstanceKey = stableInstanceKey
        self.instanceLabel = instanceLabel
        self.terminalIdentifier = terminalIdentifier
        self.executablePath = executablePath
        self.nativeSessionID = nativeSessionID
        self.workspacePath = workspacePath
        self.sourceLocation = sourceLocation
        self.nativeSource = nativeSource
    }

    /// Adds conversation provenance without changing an already-authoritative
    /// instance identity.
    public func enriched(
        nativeSessionID: String?,
        workspacePath: String?,
        sourceLocation: String?,
        nativeSource: String? = nil
    ) -> AgentRuntimeInstanceIdentity {
        var value = self
        if value.nativeSessionID == nil {
            value.nativeSessionID = Self.nonempty(nativeSessionID)
        }
        if value.workspacePath == nil {
            value.workspacePath = Self.nonempty(workspacePath).map(
                WorkspacePathIdentity.canonicalPath
            )
        }
        if value.sourceLocation == nil {
            value.sourceLocation = Self.nonempty(sourceLocation)
        }
        if value.nativeSource == nil {
            value.nativeSource = Self.nonempty(nativeSource)
        }
        return value
    }

    /// Resolves a Runtime registry entry. Explicit identity metadata wins.
    /// Without a terminal identifier, two CLI endpoints remain distinct by
    /// their persistent endpoint UUID and are never presented as a known TTY.
    public static func resolving(endpoint: RuntimeEndpoint)
        -> AgentRuntimeInstanceIdentity
    {
        let configuration = endpoint.nativeConfiguration ?? [:]
        let provider = configuredProvider(
            configuration[RuntimeIdentityConfigurationKey.provider]
        ) ?? inferredProvider(runtimeTypeID: endpoint.runtimeTypeID)
        let executablePath = canonicalExecutablePath(
            configuration["executable"]
        )
        let terminalIdentifier = nonempty(
            configuration[
                RuntimeIdentityConfigurationKey.terminalIdentifier
            ] ?? configuration["terminal_id"] ?? configuration["tty"]
        )
        let explicitSurface = configuration[
            RuntimeIdentityConfigurationKey.surfaceKind
        ].flatMap(AgentRuntimeSurfaceKind.init(rawValue:))
        let surfaceKind = explicitSurface ?? inferredSurface(
            provider: provider,
            executablePath: executablePath,
            applicationPath: configuration["application_path"],
            location: endpoint.location,
            provenance: endpoint.provenance
        )
        let basis: AgentRuntimeIdentityBasis
        let stableInstanceKey: String
        if surfaceKind == .desktopApplication, provider == .codex {
            basis = .desktopSingleton
            stableInstanceKey = "codex:desktop"
        } else if let terminalIdentifier {
            basis = .terminalIdentifier
            stableInstanceKey = stableKey(
                provider: provider,
                scope: "terminal",
                components: [terminalIdentifier]
            )
        } else {
            basis = .endpointFallback
            stableInstanceKey = stableKey(
                provider: provider,
                scope: surfaceKind.rawValue,
                components: [endpoint.id.uuidString]
            )
        }
        let explicitLabel = nonempty(
            configuration[RuntimeIdentityConfigurationKey.instanceLabel]
        )
        let label = explicitLabel ?? defaultLabel(
            provider: provider,
            surfaceKind: surfaceKind,
            basis: basis,
            terminalIdentifier: terminalIdentifier,
            nativeSessionID: nil,
            fallbackToken: String(endpoint.id.uuidString.prefix(8))
        )
        return AgentRuntimeInstanceIdentity(
            provider: provider,
            surfaceKind: surfaceKind,
            identityBasis: basis,
            stableInstanceKey: stableInstanceKey,
            instanceLabel: label,
            terminalIdentifier: terminalIdentifier,
            executablePath: executablePath,
            workspacePath: nonempty(
                configuration[RuntimeIdentityConfigurationKey.workspacePath]
            ).map(WorkspacePathIdentity.canonicalPath),
            nativeSource: nonempty(
                configuration[RuntimeIdentityConfigurationKey.nativeSource]
            )
        )
    }

    /// Identity for one Codex history thread. Codex's native `source` is kept
    /// distinct (`appServer`, `cli`, `exec`, `vscode`, and future values).
    /// CLI/exec/editor histories use a session-scoped key unless a concrete
    /// terminal identifier is supplied separately.
    public static func codexHistory(
        executablePath: String?,
        nativeSource: String?,
        nativeSessionID: String,
        workspacePath: String,
        sourceLocation: String? = nil
    ) -> AgentRuntimeInstanceIdentity {
        let provider = ConversationProvider.codex
        let executablePath = canonicalExecutablePath(executablePath)
        let normalizedSource = normalizedSourceKind(nativeSource)
        let surfaceKind: AgentRuntimeSurfaceKind
        switch normalizedSource {
        case "cli":
            surfaceKind = .terminalCLI
        case "exec":
            surfaceKind = .automation
        case "vscode", "vs_code":
            surfaceKind = .editorExtension
        case "appserver", "app_server":
            surfaceKind = executableIsInsideApplication(executablePath)
                ? .desktopApplication
                : .localService
        default:
            surfaceKind = executableIsInsideApplication(executablePath)
                ? .desktopApplication
                : .terminalCLI
        }

        let basis: AgentRuntimeIdentityBasis
        let stableInstanceKey: String
        if surfaceKind == .desktopApplication {
            basis = .desktopSingleton
            stableInstanceKey = "codex:desktop"
        } else {
            basis = .sessionFallback
            stableInstanceKey = stableKey(
                provider: provider,
                scope: normalizedSource ?? surfaceKind.rawValue,
                components: [
                    nativeSessionID,
                    executablePath ?? "",
                    sourceLocation ?? ""
                ]
            )
        }
        return AgentRuntimeInstanceIdentity(
            provider: provider,
            surfaceKind: surfaceKind,
            identityBasis: basis,
            stableInstanceKey: stableInstanceKey,
            instanceLabel: defaultLabel(
                provider: provider,
                surfaceKind: surfaceKind,
                basis: basis,
                terminalIdentifier: nil,
                nativeSessionID: nativeSessionID,
                fallbackToken: shortToken(nativeSessionID)
            ),
            executablePath: executablePath,
            nativeSessionID: nativeSessionID,
            workspacePath: WorkspacePathIdentity.canonicalPath(workspacePath),
            sourceLocation: nonempty(sourceLocation),
            nativeSource: nonempty(nativeSource)
        )
    }

    /// Claude Code's JSONL format reliably records sessions and source files,
    /// but does not normally persist a TTY. The fallback is therefore labelled
    /// as a CLI session, not as a concrete terminal.
    public static func claudeCodeHistory(
        providerInstanceKey: String,
        nativeSessionID: String,
        workspacePath: String,
        sourceLocation: String?
    ) -> AgentRuntimeInstanceIdentity {
        let provider = ConversationProvider.claudeCode
        return AgentRuntimeInstanceIdentity(
            provider: provider,
            surfaceKind: .terminalCLI,
            identityBasis: .sessionFallback,
            stableInstanceKey: stableKey(
                provider: provider,
                scope: "cli-session",
                components: [
                    nativeSessionID,
                    providerInstanceKey,
                    sourceLocation ?? ""
                ]
            ),
            instanceLabel: defaultLabel(
                provider: provider,
                surfaceKind: .terminalCLI,
                basis: .sessionFallback,
                terminalIdentifier: nil,
                nativeSessionID: nativeSessionID,
                fallbackToken: shortToken(nativeSessionID)
            ),
            nativeSessionID: nativeSessionID,
            workspacePath: WorkspacePathIdentity.canonicalPath(workspacePath),
            sourceLocation: nonempty(sourceLocation),
            nativeSource: "claude_code_jsonl"
        )
    }

    /// Safe fallback for extension adapters that have not adopted explicit
    /// runtime identity yet.
    public static func resolving(
        provider: ConversationProvider,
        providerInstanceKey: String,
        nativeSessionID: String,
        workspacePath: String,
        sourceLocation: String?,
        accessKind: ConversationAccessKind
    ) -> AgentRuntimeInstanceIdentity {
        if provider == .codex {
            let prefix = "codex-app-server:"
            let executable = providerInstanceKey.hasPrefix(prefix)
                ? String(providerInstanceKey.dropFirst(prefix.count))
                : nil
            return codexHistory(
                executablePath: executable,
                nativeSource: nil,
                nativeSessionID: nativeSessionID,
                workspacePath: workspacePath,
                sourceLocation: sourceLocation
            )
        }
        if provider == .claudeCode {
            return claudeCodeHistory(
                providerInstanceKey: providerInstanceKey,
                nativeSessionID: nativeSessionID,
                workspacePath: workspacePath,
                sourceLocation: sourceLocation
            )
        }
        let surfaceKind: AgentRuntimeSurfaceKind =
            provider == .openWorker
            ? .desktopApplication
            : accessKind == .localReadOnlyArtifact
                ? .historyArtifact
                : .unknown
        let basis: AgentRuntimeIdentityBasis =
            surfaceKind == .desktopApplication
            ? .desktopSingleton
            : .sessionFallback
        let key = surfaceKind == .desktopApplication
            ? "\(provider.rawValue):desktop"
            : stableKey(
                provider: provider,
                scope: "session",
                components: [
                    providerInstanceKey,
                    nativeSessionID,
                    sourceLocation ?? ""
                ]
            )
        return AgentRuntimeInstanceIdentity(
            provider: provider,
            surfaceKind: surfaceKind,
            identityBasis: basis,
            stableInstanceKey: key,
            instanceLabel: defaultLabel(
                provider: provider,
                surfaceKind: surfaceKind,
                basis: basis,
                terminalIdentifier: nil,
                nativeSessionID: nativeSessionID,
                fallbackToken: shortToken(nativeSessionID)
            ),
            nativeSessionID: nativeSessionID,
            workspacePath: WorkspacePathIdentity.canonicalPath(workspacePath),
            sourceLocation: nonempty(sourceLocation)
        )
    }

    private static func configuredProvider(_ rawValue: String?)
        -> ConversationProvider?
    {
        nonempty(rawValue).map(ConversationProvider.init(rawValue:))
    }

    private static func inferredProvider(runtimeTypeID: String)
        -> ConversationProvider
    {
        let normalized = runtimeTypeID.lowercased()
        if normalized.contains("codex") {
            return .codex
        }
        if normalized.contains("claude") {
            return .claudeCode
        }
        if normalized.contains("openworker") {
            return .openWorker
        }
        let vendor = normalized.split(separator: "/", maxSplits: 1).first
            .map(String.init)
            ?? normalized
        return ConversationProvider(rawValue: vendor)
    }

    private static func inferredSurface(
        provider: ConversationProvider,
        executablePath: String?,
        applicationPath: String?,
        location: EndpointLocation,
        provenance: IntegrationProvenance
    ) -> AgentRuntimeSurfaceKind {
        if nonempty(applicationPath) != nil
            || executableIsInsideApplication(executablePath) {
            return .desktopApplication
        }
        if location == .remote || location == .hosted {
            return .remoteService
        }
        if provenance == .artifactOnly {
            return .historyArtifact
        }
        if provenance == .vendorCLI
            || provider == .claudeCode
            || provider == .codex && executablePath != nil {
            return .terminalCLI
        }
        if location == .local, provenance == .vendorProtocol {
            return .localService
        }
        return .unknown
    }

    private static func defaultLabel(
        provider: ConversationProvider,
        surfaceKind: AgentRuntimeSurfaceKind,
        basis: AgentRuntimeIdentityBasis,
        terminalIdentifier: String?,
        nativeSessionID: String?,
        fallbackToken: String
    ) -> String {
        let product = provider.displayName
        switch surfaceKind {
        case .desktopApplication:
            return "\(product) Desktop"
        case .terminalCLI:
            if let terminalIdentifier {
                return "\(product) CLI · \(terminalIdentifier)"
            }
            if let nativeSessionID {
                return "\(product) CLI · session \(shortToken(nativeSessionID)) "
                    + "(terminal not recorded)"
            }
            return "\(product) CLI · Mu instance \(fallbackToken) "
                + "(terminal not recorded)"
        case .editorExtension:
            return "\(product) VS Code · session \(shortToken(nativeSessionID ?? fallbackToken))"
        case .automation:
            return "\(product) exec · session \(shortToken(nativeSessionID ?? fallbackToken))"
        case .localService:
            if let nativeSessionID {
                return "\(product) App Server · session \(shortToken(nativeSessionID))"
            }
            return "\(product) App Server · instance \(fallbackToken)"
        case .remoteService:
            return "\(product) Remote"
        case .historyArtifact:
            return "\(product) history · session \(shortToken(nativeSessionID ?? fallbackToken))"
        case .unknown:
            return basis == .installation
                ? "\(product) installation"
                : "\(product) · instance \(fallbackToken)"
        }
    }

    private static func normalizedSourceKind(_ value: String?) -> String? {
        nonempty(value)?
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private static func stableKey(
        provider: ConversationProvider,
        scope: String,
        components: [String]
    ) -> String {
        let material = components.joined(separator: "\u{1F}")
        return "\(provider.rawValue):\(scope):"
            + String(Data(material.utf8).muSHA256.prefix(20))
    }

    private static func shortToken(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "unknown" }
        let safe = value.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
        }
        return safe
            ? String(value.prefix(12))
            : String(Data(value.utf8).muSHA256.prefix(12))
    }

    private static func canonicalExecutablePath(_ rawValue: String?) -> String? {
        guard let rawValue = nonempty(rawValue) else { return nil }
        return URL(fileURLWithPath: rawValue)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func executableIsInsideApplication(_ path: String?) -> Bool {
        guard let path = nonempty(path) else { return false }
        return path.lowercased().contains(".app/contents/")
    }

    private static func nonempty(_ value: String?) -> String? {
        let value = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}

public extension RuntimeEndpoint {
    /// Explicit identity when an import/registration flow supplied one;
    /// otherwise a deterministic, non-overclaiming identity.
    var resolvedInstanceIdentity: AgentRuntimeInstanceIdentity {
        instanceIdentity ?? .resolving(endpoint: self)
    }
}

public extension ExternalConversationCandidate {
    var resolvedInstanceIdentity: AgentRuntimeInstanceIdentity {
        (runtimeInstanceIdentity
            ?? .resolving(
                provider: provider,
                providerInstanceKey: providerInstanceKey,
                nativeSessionID: nativeSessionID,
                workspacePath: canonicalWorkspacePath,
                sourceLocation: sourceLocation,
                accessKind: accessKind
            ))
            .enriched(
                nativeSessionID: nativeSessionID,
                workspacePath: canonicalWorkspacePath,
                sourceLocation: sourceLocation
            )
    }
}

public extension ImportedConversation {
    var resolvedInstanceIdentity: AgentRuntimeInstanceIdentity {
        (runtimeInstanceIdentity
            ?? .resolving(
                provider: provider,
                providerInstanceKey: providerInstanceKey,
                nativeSessionID: nativeSessionID,
                workspacePath: canonicalWorkspacePath,
                sourceLocation: sourceLocation,
                accessKind: accessKind
            ))
            .enriched(
                nativeSessionID: nativeSessionID,
                workspacePath: canonicalWorkspacePath,
                sourceLocation: sourceLocation
            )
    }
}
