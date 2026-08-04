import AppKit
import Foundation
import MuCore
import SwiftUI

private func replaceIfChanged<Value: Equatable>(
    _ current: inout Value,
    with next: Value
) {
    guard current != next else { return }
    current = next
}

enum AppSection: String, CaseIterable, Identifiable {
    case overview
    case agents
    case tasks
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .agents: "Agents"
        case .tasks: "Projects"
        case .settings: "Settings"
        }
    }

    func localizedTitle(for language: MuInterfaceLanguage) -> String {
        switch self {
        case .overview: muText(language, "Overview", "概览")
        case .agents: muText(language, "Agents", "Agents")
        case .tasks: muText(language, "Projects", "Projects")
        case .settings: muText(language, "Settings", "设置")
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .agents: "person.2.crop.square.stack"
        case .tasks: "checklist"
        case .settings: "gearshape"
        }
    }
}

enum MuInterfaceLanguage: String, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }
}

func muText(_ language: MuInterfaceLanguage, _ english: String, _ simplifiedChinese: String) -> String {
    language == .simplifiedChinese ? simplifiedChinese : english
}

struct CreateTaskDraft {
    var title = ""
    var objective = ""
    var successCriteria = ""
    var constraints = ""
    var pendingSteps = ""
    var repositoryPath = ""
    var sourceEndpointID: UUID?
    var agentIdentityID: UUID?

    func lines(_ value: String) -> [String] {
        value
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

struct CreateAgentDraft {
    var displayName = ""
    var shortName = ""
    var role: AgentRole = .builder
    var summary = ""
    var preferredEndpointID: UUID?
    var capabilityTags = ""
    var accentHex = "#6E4CEB"

    var tags: [String] {
        capabilityTags
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

struct RegisterRuntimeDraft {
    var displayName = ""
    var runtimeTypeID = ""
    var surfaceKind: AgentRuntimeSurfaceKind = .terminalCLI
    var instanceLabel = ""
    var terminalIdentifier = ""
    var location: EndpointLocation = .local
    var provenance: IntegrationProvenance = .vendorCLI
    var permissionModel: PermissionModel = .unknown
    var defaultModel = ""
    var modelOptions = ""
    var executablePath = ""
    var notes = ""

    init(provider: MuRuntimeProvider? = nil) {
        guard let provider else { return }
        displayName = provider.defaultDisplayName
        runtimeTypeID = provider.runtimeTypeID
        instanceLabel = provider.displayName
        notes = provider.summary
    }
}

enum RegistryDeletion: Identifiable {
    case agent(AgentIdentity)
    case endpoint(RuntimeEndpoint)

    var id: String {
        switch self {
        case .agent(let agent): "agent-\(agent.id.uuidString)"
        case .endpoint(let endpoint): "endpoint-\(endpoint.id.uuidString)"
        }
    }

    var displayName: String {
        switch self {
        case .agent(let agent): agent.displayName
        case .endpoint(let endpoint): endpoint.muInstanceDisplayName
        }
    }
}

struct OpenWorkerSessionLinkRequest: Identifiable {
    var chatEntryID: UUID
    var taskID: UUID
    var routeName: String

    var id: UUID { chatEntryID }
}

struct HistoryImportRequest: Identifiable {
    var taskID: UUID
    var report: HistoryDiscoveryReport

    var id: UUID { taskID }
}

struct CompletionToast: Identifiable, Equatable {
    let id: UUID
    let taskID: UUID
    let message: String

    init(taskID: UUID, message: String) {
        self.id = UUID()
        self.taskID = taskID
        self.message = message
    }
}

enum CollaborationConnectionState: String {
    case offline
    case connecting
    case connected
}

@MainActor
final class AppStore: ObservableObject {
    private static let seededStarterAgentIDs: Set<UUID> = [
        ControlPlaneService.atlasAgentID,
        ControlPlaneService.forgeAgentID,
        ControlPlaneService.lensAgentID,
        ControlPlaneService.scoutAgentID,
        ControlPlaneService.relayAgentID
    ]

    private static let completionNotificationsKey =
        "mu.notifications.taskCompletion.enabled"
    private static let completionToastDurationKey =
        "mu.notifications.taskCompletion.duration"
    private static let interfaceLanguageKey = "mu.interfaceLanguage"
    static let completionToastDurationOptions: [Double] = [2, 4, 6, 10, 15]

    @Published var interfaceLanguage: MuInterfaceLanguage = {
        let raw = UserDefaults.standard.string(
            forKey: AppStore.interfaceLanguageKey
        )
        return MuInterfaceLanguage(rawValue: raw ?? "") ?? .english
    }() {
        didSet {
            UserDefaults.standard.set(
                interfaceLanguage.rawValue,
                forKey: AppStore.interfaceLanguageKey
            )
        }
    }

    @Published var codexPromptInstructions: String =
        RuntimePromptPreferences.load().codexAdditionalInstructions {
        didSet {
            codexPromptInstructions = normalizedPromptInstructions(
                codexPromptInstructions
            )
            persistRuntimePromptPreferences()
        }
    }

    @Published var claudeCodePromptInstructions: String =
        RuntimePromptPreferences.load().claudeCodeAdditionalInstructions {
        didSet {
            claudeCodePromptInstructions = normalizedPromptInstructions(
                claudeCodePromptInstructions
            )
            persistRuntimePromptPreferences()
        }
    }

    @Published var section: AppSection = .overview
    @Published var tasks: [TaskRecord] = []
    @Published var projectPreferences: [ProjectPreference] = []
    @Published var projectRecords: [ProjectRecord] = []
    @Published var principals: [PrincipalRecord] = []
    @Published var projectActors: [ProjectActorRecord] = []
    @Published var projectMemberships: [ProjectMembershipRecord] = []
    @Published var delegations: [DelegationRecord] = []
    @Published var projectWorkspaces: [ProjectWorkspaceRecord] = []
    @Published var taskProjectLinks: [TaskProjectLink] = []
    @Published var taskLeases: [TaskLeaseRecord] = []
    @Published var projectArtifacts: [ProjectArtifactRecord] = []
    @Published var projectReviews: [ProjectReviewRecord] = []
    @Published var projectApprovals: [ProjectApprovalRecord] = []
    @Published var runtimeAdapterRegistrations:
        [RuntimeAdapterRegistration] = []
    @Published var agents: [AgentIdentity] = []
    @Published var chatEntries: [ChatEntry] = []
    @Published var runs: [RunRecord] = []
    @Published var runtimeSessionBindings: [RuntimeSessionBinding] = []
    @Published var runtimeInteractions: [RuntimeInteractionRequest] = []
    @Published var runtimeArtifacts: [RuntimeArtifactRecord] = []
    @Published var importedConversations: [ImportedConversation] = []
    @Published var taskContextSources: [TaskContextSource] = []
    @Published var contextSnapshots: [ContextSnapshot] = []
    @Published var kernelContextSources: [ContextSourceRecord] = []
    @Published var kernelContextRecords: [ContextRecord] = []
    @Published var kernelContextConflicts: [ContextConflictRecord] = []
    @Published var kernelContextPacks: [ProjectContextPackRecord] = []
    @Published var importedMessagesByConversation:
        [UUID: [ImportedConversationMessage]] = [:]
    @Published var checkpoints: [CheckpointRecord] = []
    @Published var handoffs: [HandoffRecord] = []
    @Published var endpoints: [RuntimeEndpoint] = []
    @Published private(set) var endpointSnapshots: [RuntimeEndpoint] = []
    @Published var registryTombstones: [RegistryTombstone] = []
    @Published var events: [LedgerEvent] = []
    @Published var selectedTaskID: UUID?
    @Published var collapsedProjectPaths: Set<String> = []
    @Published var isCreatingTask = false
    @Published var isCreatingAgent = false
    @Published var isRegisteringRuntime = false
    @Published var runtimeConfigurationEndpoint: RuntimeEndpoint?
    @Published var runtimeSetupProvider: MuRuntimeProvider?
    @Published var runtimeSetupExecutablePath = ""
    @Published var pendingRegistryDeletion: RegistryDeletion?
    @Published var checkpointForHandoff: CheckpointRecord?
    @Published var handoffToReject: HandoffRecord?
    @Published var errorMessage: String?
    @Published var transientMessage: String?
    @Published var probingEndpointIDs: Set<UUID> = []
    @Published var dispatchingRunIDs: Set<UUID> = []
    @Published var dispatchingSessionBindingIDs: Set<UUID> = []
    @Published var capturingCheckpointTaskIDs: Set<UUID> = []
    @Published var preselectedAgentID: UUID?
    @Published var pendingOpenWorkerSessionLink: OpenWorkerSessionLinkRequest?
    @Published var availableOpenWorkerSessions: [OpenWorkerSessionSummary] = []
    @Published var isLoadingOpenWorkerSessions = false
    @Published var openWorkerStreamingText: [UUID: String] = [:]
    @Published var historyImportRequest: HistoryImportRequest?
    @Published var isDiscoveringHistoryTaskIDs: Set<UUID> = []
    @Published var historyDiscoveryProgressByTask:
        [UUID: HistoryDiscoveryProgress] = [:]
    @Published var historyDiscoverySelectionsByTask:
        [UUID: Set<ConversationProvider>] = [:]
    @Published var historyDiscoveryReportsByTask:
        [UUID: HistoryDiscoveryReport] = [:]
    @Published var isImportingHistory = false
    @Published var pendingTaskProjectPath: String?
    @Published var completionToast: CompletionToast?
    @Published var completionNotificationsEnabled: Bool =
        UserDefaults.standard.object(
            forKey: AppStore.completionNotificationsKey
        ) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(
                completionNotificationsEnabled,
                forKey: AppStore.completionNotificationsKey
            )
            if !completionNotificationsEnabled {
                dismissCompletionToast()
            }
        }
    }
    @Published var completionToastDuration: Double = {
        let stored = UserDefaults.standard.double(
            forKey: AppStore.completionToastDurationKey
        )
        return AppStore.completionToastDurationOptions.contains(stored)
            ? stored
            : 4
    }() {
        didSet {
            let normalized = AppStore.completionToastDurationOptions.contains(
                completionToastDuration
            ) ? completionToastDuration : 4
            if normalized != completionToastDuration {
                completionToastDuration = normalized
                return
            }
            UserDefaults.standard.set(
                normalized,
                forKey: AppStore.completionToastDurationKey
            )
        }
    }

    // Shared Space transport state. The native UI observes the same ordered
    // event stream as the TS client; Runtime receipts remain local and are
    // not copied into this durable collaboration history.
    @Published private(set) var collaborationSpaces: [CollaborationSpaceRecord] = []
    @Published private(set) var collaborationEventsBySpace: [UUID: [SpaceEventRecord]] = [:]
    @Published private(set) var collaborationPresenceBySpace: [UUID: [PresenceSessionRecord]] = [:]
    @Published private(set) var collaborationConnectionState: CollaborationConnectionState = .offline
    @Published private(set) var collaborationError: String?

    private(set) var service: ControlPlaneService?
    private let collaborationClient: CollaborationHTTPClient?
    private var collaborationSequencesBySpace: [UUID: Int64] = [:]
    private var collaborationStreamTasks: [UUID: Task<Void, Never>] = [:]
    private var collaborationJoinTasks: [UUID: Task<Void, Never>] = [:]
    private var collaborationHeartbeatTasks: [UUID: Task<Void, Never>] = [:]
    let workspaceService = WorkspaceService()
    private var openWorkerBridges: [UUID: OpenWorkerSessionBridge] = [:]
    private var openWorkerBridgeConnectionTasks:
        [UUID: Task<OpenWorkerSessionBridge, Error>] = [:]
    private var openWorkerPollTasks: [UUID: Task<Void, Never>] = [:]
    private var openWorkerLiveTextStates:
        [UUID: OpenWorkerLiveTextState] = [:]
    private var openWorkerStateRefreshTask: Task<Void, Never>?
    private var completionToastDismissTask: Task<Void, Never>?

    init(service: ControlPlaneService? = nil) {
        let collaborationIdentity = CollaborationClientIdentity.local()
        self.collaborationClient = try? CollaborationHTTPClient(
            configuration: CollaborationHTTPClientConfiguration(
                identity: collaborationIdentity
            )
        )
        do {
            self.service = try service ?? ControlPlaneService()
            self.service?.runtimePromptPreferences = RuntimePromptPreferences(
                codexAdditionalInstructions: codexPromptInstructions,
                claudeCodeAdditionalInstructions: claudeCodePromptInstructions
            )
            reload()
            if let service = self.service {
                // Keep Codex app-server startup off the UI thread and out of
                // the first Project routing path.
                DispatchQueue.global(qos: .utility).async {
                    service.warmCodexEndpoints()
                }
            }
            Task { [weak self] in
                await self?.verifyOpenWorkerAndRestoreObservers()
            }
            Task { [weak self] in
                await self?.discoverCollaborationSpaces()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persistRuntimePromptPreferences() {
        let preferences = RuntimePromptPreferences(
            codexAdditionalInstructions: codexPromptInstructions,
            claudeCodeAdditionalInstructions: claudeCodePromptInstructions
        )
        preferences.save()
        service?.runtimePromptPreferences = preferences
    }

    private func normalizedPromptInstructions(_ value: String) -> String {
        String(
            value.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(RuntimePromptPreferences.maxAdditionalInstructionCharacters)
        )
    }

    func showCompletionToast(_ message: String, taskID: UUID) {
        guard completionNotificationsEnabled else { return }
        completionToastDismissTask?.cancel()
        let notice = CompletionToast(taskID: taskID, message: message)
        completionToast = notice
        let duration = completionToastDuration
        completionToastDismissTask = Task { [weak self, noticeID = notice.id] in
            do {
                try await Task.sleep(for: .seconds(duration))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.completionToast?.id == noticeID else {
                return
            }
            self.completionToast = nil
        }
    }

    func dismissCompletionToast() {
        completionToastDismissTask?.cancel()
        completionToastDismissTask = nil
        completionToast = nil
    }

    private func announceTaskCompletion(
        taskID: UUID,
        agentName: String
    ) {
        let title = tasks.first(where: { $0.id == taskID })?.title
            ?? "Project task"
        showCompletionToast(
            "\(agentName) completed “\(title)”.",
            taskID: taskID
        )
    }

    private func verifyOpenWorkerAndRestoreObservers() async {
        guard service != nil else { return }
        // OpenWorker is an optional attached desktop surface. Do not probe a
        // missing sidecar on every launch: that made startup noisy and
        // appended a new failure event each time the app opened. The Runtime
        // registry's explicit Probe action remains the authority for verifying
        // a newly started sidecar; only restore observers for an endpoint that
        // was already verified active.
        guard endpoints.contains(where: {
            $0.id == ControlPlaneService.openWorkerEndpointID
                && $0.status == .active
        }) else { return }
        await restoreOpenWorkerObservers()
    }

    var selectedTask: TaskRecord? {
        guard let selectedTaskID else { return nil }
        return tasks.first { $0.id == selectedTaskID }
    }

    var projects: [ProjectCatalog.Project] {
        ProjectCatalog.projects(
            from: tasks,
            preferences: projectPreferences,
            projects: projectRecords,
            taskProjectLinks: taskProjectLinks
        )
    }

    func projectLink(for taskID: UUID) -> TaskProjectLink? {
        taskProjectLinks.first { $0.taskID == taskID }
    }

    func projectRecord(for taskID: UUID) -> ProjectRecord? {
        guard let projectID =
            projectLink(for: taskID)?.projectID
            ?? task(id: taskID)?.projectID else {
            return nil
        }
        return projectRecords.first { $0.id == projectID }
    }

    func projectWorkspace(for taskID: UUID) -> ProjectWorkspaceRecord? {
        guard let workspaceID =
            projectLink(for: taskID)?.workspaceID
            ?? task(id: taskID)?.workspaceID else {
            return nil
        }
        return projectWorkspaces.first { $0.id == workspaceID }
    }

    func activeLease(for taskID: UUID) -> TaskLeaseRecord? {
        taskLeases
            .filter { $0.taskID == taskID && $0.isActive() }
            .max { $0.fencingToken < $1.fencingToken }
    }

    func projectArtifacts(
        for taskID: UUID
    ) -> [ProjectArtifactRecord] {
        projectArtifacts
            .filter { $0.taskID == taskID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func projectReviews(
        for taskID: UUID
    ) -> [ProjectReviewRecord] {
        projectReviews
            .filter { $0.taskID == taskID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func projectApprovals(
        for taskID: UUID
    ) -> [ProjectApprovalRecord] {
        projectApprovals
            .filter { $0.taskID == taskID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func projectActor(id: UUID?) -> ProjectActorRecord? {
        guard let id else { return nil }
        return projectActors.first { $0.id == id }
    }

    func principal(id: UUID?) -> PrincipalRecord? {
        guard let id else { return nil }
        return principals.first { $0.id == id }
    }

    func adapterRegistration(
        endpointID: UUID
    ) -> RuntimeAdapterRegistration? {
        runtimeAdapterRegistrations.first {
            $0.endpointID == endpointID
        }
    }

    func isProjectExpanded(path: String) -> Bool {
        !collapsedProjectPaths.contains(standardizedProjectPath(path))
    }

    func toggleProject(path: String) {
        let projectPath = standardizedProjectPath(path)
        if collapsedProjectPaths.contains(projectPath) {
            collapsedProjectPaths.remove(projectPath)
        } else {
            collapsedProjectPaths.insert(projectPath)
        }
    }

    func selectTask(_ task: TaskRecord) {
        selectedTaskID = task.id
        collapsedProjectPaths.remove(
            standardizedProjectPath(task.repositoryPath)
        )
    }

    func selectTask(id: UUID) {
        guard let task = task(id: id) else {
            selectedTaskID = id
            return
        }
        selectTask(task)
    }

    var pendingHandoffs: [HandoffRecord] {
        handoffs.filter { $0.status == .proposed || $0.status == .validating }
    }

    func endpoints(excluding id: UUID?) -> [RuntimeEndpoint] {
        endpoints.filter { $0.id != id }
    }

    var initialTaskEndpoints: [RuntimeEndpoint] {
        endpoints.filter {
            $0.status == .active
                && $0.capabilities.contains(.start)
                && $0.provenance != .artifactOnly
                && $0.provenance != .synthetic
        }
    }

    var availableHistoryProviders: [ConversationProvider] {
        service?.availableConversationHistoryProviders()
            ?? ConversationProvider.allCases
    }

    func endpoint(id: UUID?) -> RuntimeEndpoint? {
        guard let id else { return nil }
        return endpointSnapshots.first { $0.id == id }
    }

    func registeredEndpoint(id: UUID?) -> RuntimeEndpoint? {
        guard let id else { return nil }
        return endpoints.first { $0.id == id }
    }

    func isEndpointRegistered(id: UUID?) -> Bool {
        registeredEndpoint(id: id) != nil
    }

    func isEndpointRemoved(id: UUID?) -> Bool {
        guard let id else { return false }
        return registryTombstones.contains {
            $0.id == id && $0.entityKind == .runtimeEndpoint
        }
    }

    func endpointDisplayName(id: UUID?, fallback: String = "No runtime") -> String {
        guard let id else { return fallback }
        if let endpoint = endpoint(id: id) {
            return isEndpointRemoved(id: id)
                ? "\(endpoint.muInstanceDisplayName) · Removed"
                : endpoint.muInstanceDisplayName
        }
        if let tombstone = registryTombstones.first(where: {
            $0.id == id && $0.entityKind == .runtimeEndpoint
        }) {
            return "\(tombstone.displayName) · Removed"
        }
        return fallback
    }

    func task(id: UUID) -> TaskRecord? {
        tasks.first { $0.id == id }
    }

    func agent(id: UUID?) -> AgentIdentity? {
        guard let id else { return nil }
        return agents.first { $0.id == id }
    }

    /// Starter identities remain readable for old Tasks and ledger records, but
    /// they are not a required product concept. A new Task can run directly
    /// through its local Runtime and may receive a reusable identity later.
    var visibleAgentIdentities: [AgentIdentity] {
        agents.filter {
            !Self.seededStarterAgentIDs.contains($0.id)
                && !isSyntheticPlaceholderAgent($0)
        }
    }

    var hiddenAgentIdentities: [AgentIdentity] {
        agents.filter {
            Self.seededStarterAgentIDs.contains($0.id)
                || isSyntheticPlaceholderAgent($0)
        }
    }

    var selectableAgentIdentities: [AgentIdentity] {
        visibleAgentIdentities
    }

    private func isSyntheticPlaceholderAgent(_ agent: AgentIdentity) -> Bool {
        guard agent.preferredEndpointID == nil,
              agent.capabilityTags.isEmpty,
              agent.shortName.caseInsensitiveCompare(agent.displayName)
                  == .orderedSame else {
            return false
        }
        let key = agent.displayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        let knownSummaries: [String: String] = [
            "builder": "Implements task work in the workspace.",
            "reviewer": "Reviews work and approves changes.",
            "researcher": "Discovers and verifies context facts.",
            "orchestrator": "Plans and routes tasks across agents."
        ]
        return knownSummaries[key]?.caseInsensitiveCompare(agent.summary)
            == .orderedSame
    }

    func activeTasks(for agentID: UUID) -> [TaskRecord] {
        tasks.filter {
            $0.assignedAgentIdentityID == agentID && !$0.status.isTerminal
        }
    }

    func chat(for taskID: UUID) -> [ChatEntry] {
        chatEntries.filter { $0.taskID == taskID }
    }

    func sessionBindings(for taskID: UUID) -> [RuntimeSessionBinding] {
        runtimeSessionBindings
            .filter { $0.taskID == taskID && $0.state != .detached }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func currentOpenWorkerBinding(for taskID: UUID) -> RuntimeSessionBinding? {
        sessionBindings(for: taskID).first {
            endpoint(id: $0.endpointID)?.runtimeTypeID
                == ControlPlaneService.openWorkerRuntimeTypeID
        }
    }

    func pendingInteractions(for taskID: UUID) -> [RuntimeInteractionRequest] {
        runtimeInteractions
            .filter { $0.taskID == taskID && $0.state == .pending }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func runtimeArtifacts(for taskID: UUID) -> [RuntimeArtifactRecord] {
        runtimeArtifacts
            .filter { $0.taskID == taskID }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func importedConversations(
        for taskID: UUID
    ) -> [ImportedConversation] {
        importedConversations
            .filter { $0.taskID == taskID }
            .sorted {
                ($0.sourceUpdatedAt ?? $0.importedAt)
                    > ($1.sourceUpdatedAt ?? $1.importedAt)
            }
    }

    func contextSources(for taskID: UUID) -> [TaskContextSource] {
        taskContextSources
            .filter { $0.taskID == taskID }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    func isConversationContextEnabled(
        taskID: UUID,
        conversationID: UUID
    ) -> Bool {
        contextSources(for: taskID).first {
            $0.conversationID == conversationID
        }?.enabled == true
    }

    func importedMessages(
        for conversationID: UUID
    ) -> [ImportedConversationMessage] {
        importedMessagesByConversation[conversationID] ?? []
    }

    func loadImportedMessages(conversationID: UUID) {
        guard importedMessagesByConversation[conversationID] == nil,
              let service else {
            return
        }
        do {
            importedMessagesByConversation[conversationID] =
                try service.store.fetchImportedConversationMessages(
                    conversationID: conversationID
                )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func contextSnapshot(id: UUID?) -> ContextSnapshot? {
        guard let id else { return nil }
        return contextSnapshots.first { $0.id == id }
    }

    func kernelContextSources(
        for taskID: UUID
    ) -> [ContextSourceRecord] {
        guard let projectID = projectRecord(for: taskID)?.id else {
            return []
        }
        return kernelContextSources
            .filter { $0.projectID == projectID }
            .sorted { $0.importedAt > $1.importedAt }
    }

    func kernelContextRecords(
        for taskID: UUID
    ) -> [ContextRecord] {
        guard let projectID = projectRecord(for: taskID)?.id else {
            return []
        }
        return kernelContextRecords
            .filter {
                $0.projectID == projectID
                    && ($0.scope.taskID == nil
                        || $0.scope.taskID == taskID)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func kernelContextConflicts(
        for taskID: UUID
    ) -> [ContextConflictRecord] {
        guard let projectID = projectRecord(for: taskID)?.id else {
            return []
        }
        return kernelContextConflicts
            .filter { $0.projectID == projectID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func kernelContextPacks(
        for taskID: UUID
    ) -> [ProjectContextPackRecord] {
        kernelContextPacks
            .filter { $0.taskID == taskID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func discoverConversationHistory(
        taskID: UUID,
        selectedProviders: Set<ConversationProvider>
    ) {
        guard let service,
              !isDiscoveringHistoryTaskIDs.contains(taskID) else {
            return
        }
        let available = Set(
            service.availableConversationHistoryProviders()
        )
        let selection = selectedProviders.intersection(available)
        guard !selection.isEmpty else {
            errorMessage = "Choose at least one Agent history source."
            return
        }
        service.discardConversationHistoryDiscovery(taskID: taskID)
        historyImportRequest = nil
        historyDiscoverySelectionsByTask[taskID] = selection
        isDiscoveringHistoryTaskIDs.insert(taskID)
        Task { [weak self] in
            do {
                let report = try await service.discoverConversationHistory(
                    taskID: taskID,
                    selectedProviders: selection,
                    progress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.historyDiscoveryProgressByTask[taskID] =
                            progress
                    }
                })
                guard let self else { return }
                isDiscoveringHistoryTaskIDs.remove(taskID)
                historyDiscoveryReportsByTask[taskID] = report
                historyImportRequest = HistoryImportRequest(
                    taskID: taskID,
                    report: report
                )
            } catch {
                guard let self else { return }
                isDiscoveringHistoryTaskIDs.remove(taskID)
                errorMessage = error.localizedDescription
            }
        }
    }

    func discoverConversationHistory(taskID: UUID) {
        discoverConversationHistory(
            taskID: taskID,
            selectedProviders: Set(availableHistoryProviders)
        )
    }

    func importConversationHistory(
        taskID: UUID,
        candidates: [ExternalConversationCandidate]
    ) {
        guard let service, !isImportingHistory else { return }
        isImportingHistory = true
        Task { [weak self] in
            do {
                let imported = try await service.importConversationHistory(
                    taskID: taskID,
                    candidates: candidates
                )
                guard let self else { return }
                isImportingHistory = false
                historyImportRequest = nil
                historyDiscoveryProgressByTask.removeValue(
                    forKey: taskID
                )
                historyDiscoverySelectionsByTask.removeValue(
                    forKey: taskID
                )
                reload()
                transientMessage =
                    "Imported \(imported.count) conversation"
                    + (imported.count == 1 ? "" : "s")
                    + ". They are now visible and enabled for the next "
                    + "cross-agent Context."
            } catch {
                guard let self else { return }
                isImportingHistory = false
                reload()
                errorMessage = error.localizedDescription
            }
        }
    }

    func dismissConversationHistoryImport(taskID: UUID) {
        service?.discardConversationHistoryDiscovery(taskID: taskID)
        historyImportRequest = nil
        historyDiscoveryProgressByTask.removeValue(forKey: taskID)
        historyDiscoverySelectionsByTask.removeValue(forKey: taskID)
    }

    func setConversationContextEnabled(
        taskID: UUID,
        conversationID: UUID,
        enabled: Bool
    ) {
        guard let service else { return }
        do {
            try service.setConversationContextEnabled(
                taskID: taskID,
                conversationID: conversationID,
                enabled: enabled
            )
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importedContextRoutingStatus(
        taskID: UUID,
        bindingID: UUID
    ) -> ImportedContextRoutingStatus? {
        try? service?.importedContextRoutingStatus(
            taskID: taskID,
            bindingID: bindingID
        )
    }

    func relinkOpenWorkerForImportedContext(
        taskID: UUID,
        bindingID: UUID
    ) {
        guard let service else { return }
        do {
            let preparation =
                try service.detachOpenWorkerBindingForContextRelink(
                    taskID: taskID,
                    bindingID: bindingID
                )
            let binding = try service.bindOpenWorkerSession(
                taskID: taskID
            )
            reload()
            transientMessage =
                "Created an exact-workspace OpenWorker session for "
                + preparation.requiredWorkspacePath
                + (preparation.messagesReturnedToQueue == 0
                    ? "."
                    : " and returned "
                        + "\(preparation.messagesReturnedToQueue) queued "
                        + "message"
                        + (preparation.messagesReturnedToQueue == 1
                            ? "."
                            : "s."))
            Task { [weak self] in
                await self?.connectAndDispatchOpenWorker(
                    bindingID: binding.id
                )
            }
        } catch {
            reload()
            errorMessage = error.localizedDescription
        }
    }

    func removeImportedConversation(
        taskID: UUID,
        conversationID: UUID
    ) {
        guard let service else { return }
        do {
            try service.removeImportedConversation(
                taskID: taskID,
                conversationID: conversationID
            )
            importedMessagesByConversation.removeValue(
                forKey: conversationID
            )
            reload()
            transientMessage = "Removed Mu's local history copy."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameProject(
        path: String,
        displayName: String
    ) {
        guard let service else { return }
        do {
            let preference = try service.renameProject(
                repositoryPath: path,
                displayName: displayName
            )
            reload()
            transientMessage =
                "Renamed Project to “\(preference.displayName ?? displayName)”."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeProject(path: String) {
        guard let service else { return }
        do {
            _ = try service.removeProject(repositoryPath: path)
            collapsedProjectPaths.remove(
                standardizedProjectPath(path)
            )
            reload()
            transientMessage =
                "Removed Project from Mu. Its folder and external Agent "
                + "history were not changed."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func checkpoint(id: UUID) -> CheckpointRecord? {
        checkpoints.first { $0.id == id }
    }

    func runs(for taskID: UUID) -> [RunRecord] {
        runs.filter { $0.taskID == taskID }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Returns the current native execution when Mu can send a real interrupt
    /// to its Runtime. Codex needs both native identifiers; Claude Code can be
    /// interrupted as soon as its Mu-launched process is registered.
    func interruptibleRun(for taskID: UUID) -> RunRecord? {
        guard let task = task(id: taskID),
              let runID = task.currentRunID,
              let run = runs.first(where: { $0.id == runID }),
              run.purpose == .execution,
              run.state == .starting || run.state == .active,
              let endpoint = endpoint(id: run.endpointID) else {
            return nil
        }
        switch endpoint.runtimeTypeID {
        case ControlPlaneService.codexRuntimeTypeID:
            guard run.nativeThreadID != nil,
                  run.nativeTurnID != nil else {
                return nil
            }
        case ControlPlaneService.claudeCodeRuntimeTypeID:
            guard dispatchingRunIDs.contains(run.id) else { return nil }
        case ControlPlaneService.openWorkerRuntimeTypeID:
            guard runtimeSessionBindings.contains(where: {
                $0.taskID == taskID
                    && $0.runID == run.id
                    && ($0.state == .working || $0.state == .awaitingApproval)
            }) else {
                return nil
            }
        default:
            return nil
        }
        return run
    }

    func interruptCurrentRun(taskID: UUID) {
        guard let run = interruptibleRun(for: taskID),
              let endpoint = endpoint(id: run.endpointID) else {
            errorMessage = "No interruptible Runtime turn is currently active."
            return
        }
        switch endpoint.runtimeTypeID {
        case ControlPlaneService.codexRuntimeTypeID:
            interruptCodex(run)
        case ControlPlaneService.claudeCodeRuntimeTypeID:
            interruptClaudeCode(run)
        case ControlPlaneService.openWorkerRuntimeTypeID:
            guard let binding = runtimeSessionBindings.first(where: {
                $0.taskID == taskID
                    && $0.runID == run.id
                    && ($0.state == .working || $0.state == .awaitingApproval)
            }) else {
                errorMessage = "The active OpenWorker session could not be found."
                return
            }
            interruptOpenWorker(binding)
        default:
            errorMessage = "This Runtime does not support interruption."
        }
    }

    func checkpoints(for taskID: UUID) -> [CheckpointRecord] {
        checkpoints.filter { $0.taskID == taskID }.sorted { $0.createdAt > $1.createdAt }
    }

    func events(for taskID: UUID) -> [LedgerEvent] {
        events.filter { $0.taskID == taskID }
    }

    func collaborationSpaceID(for task: TaskRecord) -> UUID? {
        task.spaceID
            ?? task.projectID
            ?? projectLink(for: task.id)?.projectID
            ?? task.workspaceID
    }

    func collaborationEvents(for task: TaskRecord) -> [SpaceEventRecord] {
        guard let spaceID = collaborationSpaceID(for: task) else { return [] }
        let taskKey = task.id.uuidString.lowercased()
        return collaborationEventsBySpace[spaceID, default: []].filter { event in
            event.threadID == task.threadID
                || event.payload["taskID"]?.lowercased() == taskKey
        }
    }

    func collaborationPresence(for task: TaskRecord) -> [PresenceSessionRecord] {
        guard let spaceID = collaborationSpaceID(for: task) else { return [] }
        return collaborationPresenceBySpace[spaceID, default: []]
    }

    /// Joins the Project-backed Space lazily when a native workspace is opened.
    /// This keeps startup fast and avoids treating an unavailable local server
    /// as a task/runtime failure.
    func connectToCollaboration(for task: TaskRecord) {
        guard let spaceID = collaborationSpaceID(for: task),
              collaborationClient != nil else { return }
        guard collaborationJoinTasks[spaceID] == nil else { return }
        collaborationJoinTasks[spaceID] = Task { [weak self] in
            await self?.joinCollaborationSpace(spaceID, task: task)
        }
    }

    private func discoverCollaborationSpaces() async {
        guard let collaborationClient else { return }
        collaborationConnectionState = .connecting
        do {
            collaborationSpaces = try await collaborationClient.listSpaces()
            collaborationConnectionState = .connected
            collaborationError = nil
        } catch {
            // The native app remains useful in local-only mode while the TS
            // control plane is stopped. The status is visible in Environment
            // and will recover on the first Project join.
            collaborationConnectionState = .offline
        }
    }

    private func joinCollaborationSpace(
        _ spaceID: UUID,
        task: TaskRecord
    ) async {
        defer { collaborationJoinTasks[spaceID] = nil }
        guard let collaborationClient else { return }
        collaborationConnectionState = .connecting
        do {
            let displayName = projectRecord(for: task.id)?.displayName
                ?? task.title
            let space = try await collaborationClient.ensureSpace(
                id: spaceID,
                displayName: displayName,
                description: task.objective
            )
            mergeCollaborationSpace(space)
            try await syncCollaborationSpace(spaceID)
            _ = try await collaborationClient.heartbeatPresence(spaceID: spaceID)
            try await syncCollaborationSpace(spaceID)
            collaborationConnectionState = .connected
            collaborationError = nil
            startCollaborationStream(spaceID: spaceID, client: collaborationClient)
            startCollaborationHeartbeat(spaceID: spaceID, client: collaborationClient)
        } catch {
            collaborationConnectionState = .offline
            collaborationError = error.localizedDescription
        }
    }

    private func startCollaborationStream(
        spaceID: UUID,
        client: CollaborationHTTPClient
    ) {
        guard collaborationStreamTasks[spaceID] == nil else { return }
        collaborationStreamTasks[spaceID] = Task { [weak self] in
            do {
                for try await envelope in client.streamEvents(spaceID: spaceID) {
                    guard let self else { return }
                    switch envelope {
                    case .spaceEvent(let event):
                        mergeCollaborationEvent(event)
                    case .presence(let presence):
                        mergeCollaborationPresence(presence)
                    }
                    collaborationConnectionState = .connected
                    collaborationError = nil
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                collaborationConnectionState = .offline
                collaborationError = error.localizedDescription
            }
            if !Task.isCancelled {
                self?.collaborationStreamTasks[spaceID] = nil
            }
        }
    }

    private func syncCollaborationSpace(_ spaceID: UUID) async throws {
        guard let collaborationClient else { return }
        let after = collaborationSequencesBySpace[spaceID] ?? 0
        let batch = try await collaborationClient.syncSpace(
            id: spaceID,
            afterSequence: after
        )
        for event in batch.events {
            mergeCollaborationEvent(event)
        }
        collaborationPresenceBySpace[spaceID] = batch.presence.sorted {
            if $0.state != $1.state { return $0.state == .online }
            return $0.lastSeenAt > $1.lastSeenAt
        }
        collaborationSequencesBySpace[spaceID] = max(
            after,
            max(batch.nextSequence, batch.events.map(\.sequence).max() ?? after)
        )
    }

    private func startCollaborationHeartbeat(
        spaceID: UUID,
        client: CollaborationHTTPClient
    ) {
        guard collaborationHeartbeatTasks[spaceID] == nil else { return }
        collaborationHeartbeatTasks[spaceID] = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(20))
                    guard let self, !Task.isCancelled else { return }
                    let presence = try await client.heartbeatPresence(spaceID: spaceID)
                    mergeCollaborationPresence(presence)
                    collaborationConnectionState = .connected
                    collaborationError = nil
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    collaborationConnectionState = .offline
                    collaborationError = error.localizedDescription
                    self.collaborationHeartbeatTasks[spaceID] = nil
                    return
                }
            }
            self?.collaborationHeartbeatTasks[spaceID] = nil
        }
    }

    private func mergeCollaborationSpace(_ space: CollaborationSpaceRecord) {
        if let index = collaborationSpaces.firstIndex(where: { $0.id == space.id }) {
            collaborationSpaces[index] = space
        } else {
            collaborationSpaces.append(space)
        }
        collaborationSpaces.sort { $0.updatedAt > $1.updatedAt }
    }

    private func mergeCollaborationEvent(_ event: SpaceEventRecord) {
        var events = collaborationEventsBySpace[event.spaceID, default: []]
        if let index = events.firstIndex(where: { $0.id == event.id }) {
            events[index] = event
        } else {
            events.append(event)
        }
        events.sort {
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.occurredAt < $1.occurredAt
        }
        collaborationEventsBySpace[event.spaceID] = events
        collaborationSequencesBySpace[event.spaceID] = max(
            collaborationSequencesBySpace[event.spaceID] ?? 0,
            event.sequence
        )
    }

    private func mergeCollaborationPresence(_ presence: PresenceSessionRecord) {
        var sessions = collaborationPresenceBySpace[presence.spaceID, default: []]
        if let index = sessions.firstIndex(where: { $0.id == presence.id }) {
            sessions[index] = presence
        } else {
            sessions.append(presence)
        }
        collaborationPresenceBySpace[presence.spaceID] = sessions.filter {
            !$0.isExpired()
        }.sorted {
            if $0.state != $1.state { return $0.state == .online }
            return $0.lastSeenAt > $1.lastSeenAt
        }
    }

    private func publishWorkspaceChat(taskID: UUID) {
        guard let task = task(id: taskID),
              let spaceID = collaborationSpaceID(for: task),
              collaborationClient != nil else { return }
        let entries = chat(for: taskID)
        Task { [weak self] in
            guard let self, let collaborationClient else { return }
            do {
                let displayName = projectRecord(for: task.id)?.displayName ?? task.title
                let space = try await collaborationClient.ensureSpace(
                    id: spaceID,
                    displayName: displayName,
                    description: task.objective
                )
                mergeCollaborationSpace(space)
                for entry in entries {
                    var payload: [String: String] = [
                        "taskID": taskID.uuidString.lowercased(),
                        "entryID": entry.id.uuidString.lowercased(),
                        "authorKind": entry.authorKind.rawValue,
                        "authorName": entry.authorName,
                        "text": entry.text
                    ]
                    if let threadID = entry.threadID ?? task.threadID {
                        payload["threadID"] = threadID.uuidString.lowercased()
                    }
                    let event = try await collaborationClient.appendEvent(
                        spaceID: spaceID,
                        threadID: entry.threadID ?? task.threadID,
                        eventType: "chat.message",
                        payload: payload,
                        idempotencyKey: "swift.chat.\(entry.id.uuidString.lowercased())"
                    )
                    mergeCollaborationEvent(event)
                }
                _ = try await collaborationClient.heartbeatPresence(spaceID: spaceID)
                collaborationConnectionState = .connected
                collaborationError = nil
                startCollaborationStream(spaceID: spaceID, client: collaborationClient)
                startCollaborationHeartbeat(spaceID: spaceID, client: collaborationClient)
            } catch {
                collaborationConnectionState = .offline
                collaborationError = error.localizedDescription
            }
        }
    }

    func reload() {
        guard let service else { return }
        var reloadStage = "tasks"
        do {
            let nextTasks = try service.store.fetchTasks()
            reloadStage = "project preferences"
            let nextProjectPreferences =
                try service.store.fetchProjectPreferences()
            reloadStage = "projects"
            let nextProjectRecords =
                try service.store.fetchProjects()
            reloadStage = "principals"
            let nextPrincipals =
                try service.store.fetchPrincipals()
            reloadStage = "project actors"
            let nextProjectActors =
                try service.store.fetchProjectActors()
            reloadStage = "project memberships"
            let nextProjectMemberships =
                try service.store.fetchProjectMemberships()
            reloadStage = "delegations"
            let nextDelegations =
                try service.store.fetchDelegations()
            reloadStage = "project workspaces"
            let nextProjectWorkspaces =
                try service.store.fetchProjectWorkspaces()
            reloadStage = "task/project links"
            let nextTaskProjectLinks =
                try service.store.fetchTaskProjectLinks()
            reloadStage = "task leases"
            let nextTaskLeases =
                try service.store.fetchTaskLeases()
            reloadStage = "project artifacts"
            let nextProjectArtifacts =
                try service.store.fetchProjectArtifacts()
            reloadStage = "project reviews"
            let nextProjectReviews =
                try service.store.fetchProjectReviews()
            reloadStage = "project approvals"
            let nextProjectApprovals =
                try service.store.fetchProjectApprovals()
            reloadStage = "runtime adapter registrations"
            let nextRuntimeAdapterRegistrations =
                try service.store
                .fetchRuntimeAdapterRegistrations()
            reloadStage = "agents"
            let nextAgents = try service.store.fetchAgents()
            reloadStage = "chat entries"
            let nextChatEntries = try service.store.fetchChatEntries()
            reloadStage = "runs"
            let nextRuns = try service.store.fetchRuns()
            reloadStage = "runtime session bindings"
            let nextRuntimeSessionBindings =
                try service.store.fetchRuntimeSessionBindings()
            reloadStage = "runtime interactions"
            let nextRuntimeInteractions =
                try service.store.fetchRuntimeInteractions()
            reloadStage = "runtime artifacts"
            let nextRuntimeArtifacts =
                try service.store.fetchRuntimeArtifacts()
            reloadStage = "imported conversations"
            let nextImportedConversations =
                try service.store.fetchImportedConversations()
            reloadStage = "task context sources"
            let nextTaskContextSources = try nextTasks.flatMap {
                try service.store.fetchTaskContextSources(taskID: $0.id)
            }
            reloadStage = "context snapshots"
            let nextContextSnapshots =
                try service.store.fetchContextSnapshots()
            reloadStage = "context sources"
            let nextKernelContextSources =
                try nextProjectRecords.flatMap {
                    try service.store.fetchContextSources(
                        projectID: $0.id
                    )
                }
            reloadStage = "context records"
            let nextKernelContextRecords =
                try nextProjectRecords.flatMap {
                    try service.store.fetchContextRecords(
                        projectID: $0.id
                    )
                }
            reloadStage = "context conflicts"
            let nextKernelContextConflicts =
                try nextProjectRecords.flatMap {
                    try service.store.fetchContextConflicts(
                        projectID: $0.id
                    )
                }
            reloadStage = "context packs"
            let nextKernelContextPacks =
                try nextProjectRecords.flatMap {
                    try service.store.fetchProjectContextPacks(
                        projectID: $0.id
                    )
                }
            let importedConversationIDs =
                Set(nextImportedConversations.map(\.id))
            let nextImportedMessagesByConversation =
                importedMessagesByConversation
                .filter { importedConversationIDs.contains($0.key) }
            reloadStage = "checkpoints"
            let nextCheckpoints = try service.store.fetchCheckpoints()
            reloadStage = "handoffs"
            let nextHandoffs = try service.store.fetchHandoffs()
            reloadStage = "endpoint snapshots"
            let nextEndpointSnapshots = try service.store.fetchEndpoints()
            reloadStage = "registered endpoints"
            let nextEndpoints =
                try service.store.fetchRegisteredEndpoints()
            reloadStage = "registry tombstones"
            let nextRegistryTombstones =
                try service.store.fetchRegistryTombstones()
            reloadStage = "ledger events"
            let nextEvents = try service.store.fetchEvents()

            replaceIfChanged(&tasks, with: nextTasks)
            replaceIfChanged(
                &projectPreferences,
                with: nextProjectPreferences
            )
            replaceIfChanged(
                &projectRecords,
                with: nextProjectRecords
            )
            replaceIfChanged(
                &principals,
                with: nextPrincipals
            )
            replaceIfChanged(
                &projectActors,
                with: nextProjectActors
            )
            replaceIfChanged(
                &projectMemberships,
                with: nextProjectMemberships
            )
            replaceIfChanged(
                &delegations,
                with: nextDelegations
            )
            replaceIfChanged(
                &projectWorkspaces,
                with: nextProjectWorkspaces
            )
            replaceIfChanged(
                &taskProjectLinks,
                with: nextTaskProjectLinks
            )
            replaceIfChanged(
                &taskLeases,
                with: nextTaskLeases
            )
            replaceIfChanged(
                &projectArtifacts,
                with: nextProjectArtifacts
            )
            replaceIfChanged(
                &projectReviews,
                with: nextProjectReviews
            )
            replaceIfChanged(
                &projectApprovals,
                with: nextProjectApprovals
            )
            replaceIfChanged(
                &runtimeAdapterRegistrations,
                with: nextRuntimeAdapterRegistrations
            )
            replaceIfChanged(&agents, with: nextAgents)
            replaceIfChanged(&chatEntries, with: nextChatEntries)
            replaceIfChanged(&runs, with: nextRuns)
            replaceIfChanged(
                &runtimeSessionBindings,
                with: nextRuntimeSessionBindings
            )
            replaceIfChanged(
                &runtimeInteractions,
                with: nextRuntimeInteractions
            )
            replaceIfChanged(
                &runtimeArtifacts,
                with: nextRuntimeArtifacts
            )
            replaceIfChanged(
                &importedConversations,
                with: nextImportedConversations
            )
            replaceIfChanged(
                &taskContextSources,
                with: nextTaskContextSources
            )
            replaceIfChanged(
                &contextSnapshots,
                with: nextContextSnapshots
            )
            replaceIfChanged(
                &kernelContextSources,
                with: nextKernelContextSources
            )
            replaceIfChanged(
                &kernelContextRecords,
                with: nextKernelContextRecords
            )
            replaceIfChanged(
                &kernelContextConflicts,
                with: nextKernelContextConflicts
            )
            replaceIfChanged(
                &kernelContextPacks,
                with: nextKernelContextPacks
            )
            replaceIfChanged(
                &importedMessagesByConversation,
                with: nextImportedMessagesByConversation
            )
            replaceIfChanged(&checkpoints, with: nextCheckpoints)
            replaceIfChanged(&handoffs, with: nextHandoffs)
            replaceIfChanged(
                &endpointSnapshots,
                with: nextEndpointSnapshots
            )
            replaceIfChanged(&endpoints, with: nextEndpoints)
            replaceIfChanged(
                &registryTombstones,
                with: nextRegistryTombstones
            )
            replaceIfChanged(&events, with: nextEvents)
            cleanupDetachedOpenWorkerObservers()
            let visibleTasks = ProjectCatalog.projects(
                from: nextTasks,
                preferences: nextProjectPreferences,
                projects: nextProjectRecords,
                taskProjectLinks: nextTaskProjectLinks
            ).flatMap(\.tasks)
            if selectedTaskID == nil
                || !visibleTasks.contains(where: {
                    $0.id == selectedTaskID
                }) {
                selectedTaskID = visibleTasks.first?.id
            }
        } catch {
            errorMessage = "\(error.localizedDescription) (while loading \(reloadStage))"
        }
    }

    private func reloadOpenWorkerState() {
        openWorkerStateRefreshTask?.cancel()
        openWorkerStateRefreshTask = nil
        guard let service else { return }
        do {
            let nextChatEntries = try service.store.fetchChatEntries()
            let nextRuns = try service.store.fetchRuns()
            let nextBindings =
                try service.store.fetchRuntimeSessionBindings()
            let nextInteractions =
                try service.store.fetchRuntimeInteractions()
            let nextArtifacts =
                try service.store.fetchRuntimeArtifacts()
            let nextEvents = try service.store.fetchEvents()

            replaceIfChanged(&chatEntries, with: nextChatEntries)
            replaceIfChanged(&runs, with: nextRuns)
            replaceIfChanged(
                &runtimeSessionBindings,
                with: nextBindings
            )
            replaceIfChanged(
                &runtimeInteractions,
                with: nextInteractions
            )
            replaceIfChanged(
                &runtimeArtifacts,
                with: nextArtifacts
            )
            replaceIfChanged(&events, with: nextEvents)
            cleanupDetachedOpenWorkerObservers()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleOpenWorkerStateReload() {
        guard openWorkerStateRefreshTask == nil else { return }
        openWorkerStateRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
            guard let self else { return }
            openWorkerStateRefreshTask = nil
            reloadOpenWorkerState()
        }
    }

    private func cleanupDetachedOpenWorkerObservers() {
        let activeOpenWorkerEndpointIDs = Set(
            endpoints.filter {
                $0.runtimeTypeID == ControlPlaneService.openWorkerRuntimeTypeID
                    && $0.status == .active
                    && $0.capabilities.contains(.continueRun)
                    && $0.capabilities.contains(.streamEvents)
            }.map(\.id)
        )
        let activeBindingIDs = Set(
            runtimeSessionBindings.filter {
                $0.state != .detached
                    && activeOpenWorkerEndpointIDs.contains($0.endpointID)
            }.map(\.id)
        )
        let staleBindingIDs = Set(openWorkerBridges.keys)
            .union(openWorkerBridgeConnectionTasks.keys)
            .union(openWorkerPollTasks.keys)
            .subtracting(activeBindingIDs)
        for bindingID in staleBindingIDs {
            let bridge = openWorkerBridges.removeValue(forKey: bindingID)
            openWorkerBridgeConnectionTasks[bindingID]?.cancel()
            openWorkerBridgeConnectionTasks.removeValue(forKey: bindingID)
            openWorkerPollTasks[bindingID]?.cancel()
            openWorkerPollTasks.removeValue(forKey: bindingID)
            dispatchingSessionBindingIDs.remove(bindingID)
            openWorkerLiveTextStates.removeValue(forKey: bindingID)
            if openWorkerStreamingText[bindingID] != nil {
                openWorkerStreamingText.removeValue(forKey: bindingID)
            }
            if let bridge {
                Task {
                    await bridge.disconnect()
                }
            }
        }
    }

    func createTask(
        from draft: CreateTaskDraft,
        discoverHistoryProviders: Set<ConversationProvider> = []
    ) {
        guard let service, let endpointID = draft.sourceEndpointID else {
            errorMessage = "Choose a source runtime endpoint."
            return
        }
        do {
            let task = try service.createTask(
                title: draft.title,
                objective: draft.objective,
                successCriteria: draft.lines(draft.successCriteria),
                constraints: draft.lines(draft.constraints),
                pendingSteps: draft.lines(draft.pendingSteps),
                repositoryPath: draft.repositoryPath,
                sourceEndpointID: endpointID,
                agentIdentityID: draft.agentIdentityID
            )
            reload()
            selectedTaskID = task.id
            collapsedProjectPaths.remove(
                standardizedProjectPath(task.repositoryPath)
            )
            section = .tasks
            isCreatingTask = false
            pendingTaskProjectPath = nil
            if !discoverHistoryProviders.isEmpty {
                discoverConversationHistory(
                    taskID: task.id,
                    selectedProviders: discoverHistoryProviders
                )
            }
            if registeredEndpoint(id: endpointID)?.runtimeTypeID
                == ControlPlaneService.codexRuntimeTypeID,
               let runID = task.currentRunID,
               let run = runs.first(where: { $0.id == runID }) {
                transientMessage =
                    "Task created in Project. Native read-only Codex run is starting."
                dispatchCodexTask(run)
            } else if registeredEndpoint(id: endpointID)?.runtimeTypeID
                == ControlPlaneService.claudeCodeRuntimeTypeID,
               let runID = task.currentRunID,
               let run = runs.first(where: { $0.id == runID }) {
                transientMessage =
                    "Task created in Project. Native read-only Claude Code run is starting."
                dispatchClaudeCodeTask(run)
            } else if registeredEndpoint(id: endpointID)?.runtimeTypeID
                == ControlPlaneService.openWorkerRuntimeTypeID {
                transientMessage =
                    "Task created in Project. Native OpenWorker session is starting."
                startInitialOpenWorkerTask(task)
            } else {
                transientMessage = "Task created in Project with an active source Run."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openNewTask(agentID: UUID? = nil) {
        preselectedAgentID = agentID
        pendingTaskProjectPath = nil
        isCreatingTask = true
    }

    func openRuntimeSetup(
        _ provider: MuRuntimeProvider,
        executablePath: String? = nil
    ) {
        runtimeSetupProvider = provider
        runtimeSetupExecutablePath = executablePath ?? ""
        isRegisteringRuntime = true
    }

    func openNewTask(projectPath: String) {
        let path = standardizedProjectPath(projectPath)
        guard service != nil else {
            pendingTaskProjectPath = path
            isCreatingTask = true
            return
        }

        // A Project-row plus is an invitation to start working, not another
        // metadata form. Create a lightweight Task shell from the Project's
        // existing endpoint/Agent choice and open Workspace Chat immediately.
        // The first message replaces this placeholder title with a local
        // summary, so the user never has to name the Task up front.
        guard let endpoint = quickTaskEndpoint(for: path) else {
            pendingTaskProjectPath = path
            isCreatingTask = true
            return
        }
        let projectName = projects.first {
            standardizedProjectPath($0.path) == path
        }?.name ?? URL(fileURLWithPath: path).lastPathComponent
        let existingTask = projects.first {
            standardizedProjectPath($0.path) == path
        }?.tasks.first
        let agentID = existingTask?.assignedAgentIdentityID
        let draft = CreateTaskDraft(
            title: "New task",
            objective: "Start working in \(projectName).",
            repositoryPath: path,
            sourceEndpointID: endpoint.id,
            agentIdentityID: agentID
        )
        collapsedProjectPaths.remove(path)
        createTask(from: draft)
        transientMessage =
            "Thread ready. Send the first message and Mu will summarize the title."
    }

    private func quickTaskEndpoint(for projectPath: String) -> RuntimeEndpoint? {
        let projectTask = projects.first {
            standardizedProjectPath($0.path) == projectPath
        }?.tasks.first
        let preferredIDs = [
            projectTask?.currentEndpointID,
            projectTask?.assignedAgentIdentityID.flatMap {
                agent(id: $0)?.preferredEndpointID
            }
        ].compactMap { $0 }
        let candidates = preferredIDs.compactMap { id in
            initialTaskEndpoints.first { $0.id == id }
        } + initialTaskEndpoints
        var seen = Set<UUID>()
        return candidates.first { seen.insert($0.id).inserted }
    }

    private func standardizedProjectPath(_ path: String) -> String {
        WorkspacePathIdentity.canonicalPath(path)
    }

    func sendChat(
        taskID: UUID,
        text: String,
        endpointID: UUID? = nil,
        model: String? = nil
    ) {
        guard let service else { return }
        autoSummarizeTaskTitle(taskID: taskID, firstMessage: text)
        do {
            let prepared = try service.prepareWorkspaceMessage(
                taskID: taskID,
                text: text,
                selectedEndpointID: endpointID,
                requestedModel: model
            )
            reload()
            // Publish the durable user message immediately; the later
            // dispatch completion publishes any Agent reply with the same
            // idempotency contract.
            publishWorkspaceChat(taskID: taskID)
            guard let route = prepared.route else {
                transientMessage = "Message saved automatically."
                return
            }
            let runtimeTypeID =
                registeredEndpoint(id: route.endpointID)?
                .runtimeTypeID
            if runtimeTypeID
                == ControlPlaneService.codexRuntimeTypeID {
                dispatchWorkspaceMessage(
                    entryID: prepared.entry.id,
                    provider: .codex
                )
            } else if runtimeTypeID
                == ControlPlaneService.claudeCodeRuntimeTypeID {
                dispatchWorkspaceMessage(
                    entryID: prepared.entry.id,
                    provider: .claudeCode
                )
            } else if let bindingID =
                prepared.entry.runtimeSessionBindingID {
                Task { [weak self] in
                    await self?.connectAndDispatchOpenWorker(bindingID: bindingID)
                }
            } else {
                pendingOpenWorkerSessionLink = OpenWorkerSessionLinkRequest(
                    chatEntryID: prepared.entry.id,
                    taskID: taskID,
                    routeName: route.mention
                )
                refreshOpenWorkerSessions()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func autoSummarizeTaskTitle(
        taskID: UUID,
        firstMessage: String
    ) {
        guard let service,
              var task = try? service.store.fetchTask(id: taskID),
              ["new task", "untitled task", "new workspace task"]
                .contains(task.title.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).lowercased()) else {
            return
        }
        var words = firstMessage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
        while let first = words.first, first.hasPrefix("@") {
            words.removeFirst()
        }
        if words.first?.lowercased() == "code" {
            words.removeFirst()
        }
        let message = words.joined(separator: " ")
        guard let firstSentence = message.split(
            whereSeparator: { ".!?\n".contains($0) }
        ).first else {
            return
        }
        let candidate = String(firstSentence)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        let title = candidate.count > 72
            ? String(candidate.prefix(71)) + "…"
            : candidate
        task.title = title
        task.updatedAt = Date()
        do {
            try service.store.withTransaction {
                try service.store.upsertTask(task)
                try service.store.appendEvent(
                    LedgerEvent(
                        projectID: task.projectID,
                        actorID: task.assignedActorID,
                        workspaceID: task.workspaceID,
                        taskID: task.id,
                        runID: task.currentRunID,
                        type: "task.auto_titled",
                        summary: "Auto-titled Task “\(title)”.",
                        payload: [
                            "source": "first_workspace_message",
                            "message_prefix": String(firstMessage.prefix(120))
                        ]
                    )
                )
            }
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func dispatchManagedWorkspaceMessage(
        entryID: UUID,
        provider: ConversationProvider
    ) {
        guard let service else { return }
        let entry = chatEntries.first { $0.id == entryID }
        let runID = entry?.runID
        let taskID = entry?.taskID
        if let runID {
            dispatchingRunIDs.insert(runID)
            Task { [weak self] in
                while self?.dispatchingRunIDs
                    .contains(runID) == true {
                    try? await Task.sleep(
                        for: .milliseconds(500)
                    )
                    guard let self,
                          dispatchingRunIDs
                            .contains(runID) else {
                        break
                    }
                    reload()
                }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<String, Error>
            switch provider {
            case .codex:
                result = Result {
                    let receipt =
                        try service
                        .dispatchCodexWorkspaceMessage(
                            entryID: entryID
                        )
                    return receipt.status
                }
            case .claudeCode:
                result = Result {
                    let receipt =
                        try service
                        .dispatchClaudeCodeWorkspaceMessage(
                            entryID: entryID
                        )
                    return receipt.status
                }
            default:
                result = .failure(
                    MuError.capabilityMissing(
                        "This Runtime has no managed Workspace Chat adapter."
                    )
                )
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let runID {
                    dispatchingRunIDs.remove(runID)
                }
                reload()
                if let taskID {
                    publishWorkspaceChat(taskID: taskID)
                }
                switch result {
                case .success(let status):
                    if status == "completed" || status == "success" {
                        transientMessage = nil
                        if let runID,
                           let taskID = runs.first(where: { $0.id == runID })?.taskID {
                            announceTaskCompletion(
                                taskID: taskID,
                                agentName: provider.displayName
                            )
                        }
                    } else {
                        transientMessage =
                            "\(provider.displayName) finished with status \(status); "
                            + "the result is available for Project review."
                    }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func dispatchWorkspaceMessage(
        entryID: UUID,
        provider: ConversationProvider
    ) {
        guard let entry = chatEntries.first(where: { $0.id == entryID }) else {
            errorMessage = "The Workspace message could not be found."
            return
        }
        if entry.runtimeSessionBindingID == nil {
            dispatchInitialManagedWorkspaceMessage(
                entryID: entryID,
                provider: provider
            )
            return
        }
        guard let bindingID = entry.runtimeSessionBindingID,
              let binding = runtimeSessionBindings.first(where: {
                  $0.id == bindingID
              }) else {
            errorMessage = "The Runtime session binding could not be found."
            return
        }
        if binding.state == .connecting || binding.state == .working {
            waitForManagedWorkspaceMessage(
                entryID: entryID,
                provider: provider,
                bindingID: bindingID
            )
            return
        }
        dispatchManagedWorkspaceMessage(
            entryID: entryID,
            provider: provider
        )
    }

    private func waitForManagedWorkspaceMessage(
        entryID: UUID,
        provider: ConversationProvider,
        bindingID: UUID
    ) {
        transientMessage =
            "\(provider.displayName) is finishing its current turn; your message is queued."
        Task { @MainActor [weak self] in
            for _ in 0..<240 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                reload()
                guard let entry = chatEntries.first(where: { $0.id == entryID }) else {
                    return
                }
                if let currentBinding = runtimeSessionBindings.first(where: {
                    $0.id == bindingID
                }), currentBinding.state == .connecting || currentBinding.state == .working {
                    continue
                }
                if entry.runtimeSessionBindingID == nil {
                    do {
                        _ = try service?.promoteWorkspaceMessageToManagedContinuation(
                            entryID: entryID
                        )
                        reload()
                    } catch {
                        // A failed initial Run updates the entry to failed;
                        // surface that state instead of retrying forever.
                        if entry.deliveryState != .awaitingSession {
                            errorMessage = error.localizedDescription
                            return
                        }
                        continue
                    }
                }
                dispatchManagedWorkspaceMessage(
                    entryID: entryID,
                    provider: provider
                )
                return
            }
            self?.errorMessage =
                "\(provider.displayName) did not become ready for the queued message."
        }
    }

    /// Starts a native session for the first message on a Runtime that has
    /// not yet been bound to this Task. The initial prompt includes the
    /// user's message, so the first Workspace message is a real turn rather
    /// than an artificial empty warm-up followed by a second turn.
    private func dispatchInitialManagedWorkspaceMessage(
        entryID: UUID,
        provider: ConversationProvider
    ) {
        guard let service,
              let entry = chatEntries.first(where: { $0.id == entryID }),
              let runID = entry.runID else {
            errorMessage = "The initial Runtime Run could not be prepared."
            return
        }
        guard !dispatchingRunIDs.contains(runID) else {
            // A Project created moments ago may already be dispatching its
            // initial Run. Keep the entry and attach it as soon as that Run
            // has established a resumable native session.
            transientMessage =
                "\(provider.displayName) is still starting its native session."
            waitForInitialManagedWorkspaceMessage(
                entryID: entryID,
                provider: provider,
                runID: runID
            )
            return
        }
        dispatchingRunIDs.insert(runID)
        Task { [weak self] in
            while self?.dispatchingRunIDs.contains(runID) == true {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self,
                      dispatchingRunIDs.contains(runID) else {
                    break
                }
                reload()
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<String, Error>
            switch provider {
            case .codex:
                result = Result {
                    let receipt = try service.dispatchCodexTask(
                        runID: runID,
                        workspaceEntryID: entryID
                    )
                    return receipt.status
                }
            case .claudeCode:
                result = Result {
                    let receipt = try service.dispatchClaudeCodeTask(
                        runID: runID,
                        workspaceEntryID: entryID
                    )
                    return receipt.status
                }
            default:
                result = .failure(
                    MuError.capabilityMissing(
                        "This Runtime has no managed initial Workspace adapter."
                    )
                )
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                dispatchingRunIDs.remove(runID)
                reload()
                publishWorkspaceChat(taskID: entry.taskID)
                switch result {
                case .success(let status):
                    if status == "completed" || status == "success" {
                        transientMessage = nil
                        announceTaskCompletion(
                            taskID: entry.taskID,
                            agentName: provider.displayName
                        )
                    } else {
                        transientMessage =
                            "\(provider.displayName) finished with status \(status); "
                            + "the result is available for Project review."
                    }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func waitForInitialManagedWorkspaceMessage(
        entryID: UUID,
        provider: ConversationProvider,
        runID: UUID
    ) {
        Task { @MainActor [weak self] in
            for _ in 0..<240 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                reload()
                guard let entry = chatEntries.first(where: { $0.id == entryID }) else {
                    return
                }
                guard entry.deliveryState == .awaitingSession else {
                    if entry.deliveryState == .failed || entry.deliveryState == .ambiguous {
                        errorMessage = "\(provider.displayName) could not start this message."
                    }
                    return
                }
                if dispatchingRunIDs.contains(runID) {
                    continue
                }
                do {
                    _ = try service?.promoteWorkspaceMessageToManagedContinuation(
                        entryID: entryID
                    )
                    reload()
                    dispatchWorkspaceMessage(
                        entryID: entryID,
                        provider: provider
                    )
                    return
                } catch {
                    // The native binding can be persisted a few milliseconds
                    // after the dispatcher releases its Run lease.
                    continue
                }
            }
            self?.errorMessage =
                "\(provider.displayName) did not create a native session for the queued message."
        }
    }

    func createAgent(from draft: CreateAgentDraft) {
        guard let service else { return }
        do {
            let agent = try service.createAgentIdentity(
                displayName: draft.displayName,
                shortName: draft.shortName,
                role: draft.role,
                summary: draft.summary,
                preferredEndpointID: draft.preferredEndpointID,
                capabilityTags: draft.tags,
                accentHex: draft.accentHex
            )
            reload()
            isCreatingAgent = false
            transientMessage = "Agent “\(agent.displayName)” registered."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func registerRuntime(from draft: RegisterRuntimeDraft) {
        guard let service else { return }
        do {
            let endpoint = try service.registerManualEndpoint(
                displayName: draft.displayName,
                runtimeTypeID: draft.runtimeTypeID,
                location: draft.location,
                provenance: draft.provenance,
                permissionModel: draft.permissionModel,
                executablePath: draft.executablePath,
                surfaceKind: draft.surfaceKind,
                instanceLabel: draft.instanceLabel,
                terminalIdentifier:
                    draft.terminalIdentifier,
                notes: draft.notes,
                defaultModel: draft.defaultModel,
                modelOptions: draft.modelOptions
                    .split(whereSeparator: { $0 == "," || $0 == "\n" })
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            )
            reload()
            isRegisteringRuntime = false
            transientMessage =
                "Runtime “\(endpoint.muInstanceDisplayName)” registered offline pending an adapter probe."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openRuntimeSettings(_ endpoint: RuntimeEndpoint) {
        runtimeConfigurationEndpoint = endpoint
    }

    func updateRuntimeSettings(
        endpointID: UUID,
        defaultModel: String,
        modelOptions: String,
        permissionModel: PermissionModel
    ) {
        guard let service else { return }
        do {
            let updated = try service.updateRuntimeSettings(
                endpointID: endpointID,
                defaultModel: defaultModel,
                modelOptions: modelOptions
                    .split(whereSeparator: { $0 == "," || $0 == "\n" })
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
                permissionModel: permissionModel
            )
            reload()
            runtimeConfigurationEndpoint = nil
            transientMessage = "Runtime settings for “\(updated.muInstanceDisplayName)” saved."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestDelete(_ agent: AgentIdentity) {
        pendingRegistryDeletion = .agent(agent)
    }

    func requestDelete(_ endpoint: RuntimeEndpoint) {
        pendingRegistryDeletion = .endpoint(endpoint)
    }

    func removeDuplicateDiscoveredEndpoints(_ endpoints: [RuntimeEndpoint]) {
        guard let service, !endpoints.isEmpty else { return }
        do {
            for endpoint in endpoints {
                try service.deleteEndpoint(id: endpoint.id)
            }
            reload()
            transientMessage =
                "Removed \(endpoints.count) duplicate discoveries; the newest copy was kept."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func confirmRegistryDeletion() {
        guard let service, let deletion = pendingRegistryDeletion else { return }
        do {
            switch deletion {
            case .agent(let agent):
                try service.deleteAgentIdentity(id: agent.id)
                transientMessage = "Agent “\(agent.displayName)” deleted."
            case .endpoint(let endpoint):
                try service.deleteEndpoint(id: endpoint.id)
                transientMessage =
                    "Runtime “\(endpoint.muInstanceDisplayName)” removed from the registry; history preserved."
            }
            pendingRegistryDeletion = nil
            reload()
        } catch {
            pendingRegistryDeletion = nil
            if case .agent(let agent) = deletion,
               case MuError.recordNotFound = error {
                // A stale card can survive while another process (or an
                // earlier Mu build) has already removed the identity. Refresh
                // the registry instead of surfacing a misleading hard error.
                reload()
                transientMessage =
                    "Agent “\(agent.displayName)” was already removed; the registry was refreshed."
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    func captureCheckpoint(taskID: UUID) {
        guard let service, !capturingCheckpointTaskIDs.contains(taskID) else { return }
        capturingCheckpointTaskIDs.insert(taskID)

        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try service.captureCheckpoint(taskID: taskID) }
            }.value
            guard let self else { return }

            capturingCheckpointTaskIDs.remove(taskID)
            switch outcome {
            case .success(let checkpoint):
                reload()
                checkpointForHandoff = checkpoint
                transientMessage = "Checkpoint sealed and verified."
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    func proposeHandoff(checkpoint: CheckpointRecord, receiverEndpointID: UUID) {
        guard let service else { return }
        do {
            _ = try service.proposeHandoff(
                taskID: checkpoint.taskID,
                checkpointID: checkpoint.id,
                receiverEndpointID: receiverEndpointID
            )
            checkpointForHandoff = nil
            reload()
            section = .tasks
            selectTask(id: checkpoint.taskID)
            transientMessage = "Handoff proposed. Receiver acceptance is required."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func acceptHandoff(_ handoff: HandoffRecord) {
        guard let service else { return }
        do {
            let receivingRun = try service.acceptHandoff(id: handoff.id)
            reload()
            section = .tasks
            selectTask(id: handoff.taskID)
            if registeredEndpoint(id: handoff.receiverEndpointID)?.runtimeTypeID
                == ControlPlaneService.codexRuntimeTypeID {
                transientMessage = "Handoff accepted. Codex read-only Replan is starting."
                dispatchCodexReplan(receivingRun)
            } else {
                transientMessage = "Handoff accepted and receiving Replan created."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rejectHandoff(_ handoff: HandoffRecord, reason: String) {
        guard let service else { return }
        do {
            try service.rejectHandoff(id: handoff.id, reason: reason)
            handoffToReject = nil
            reload()
            transientMessage = "Handoff rejected; ownership stayed with the sender."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func probeCodex(_ endpoint: RuntimeEndpoint) {
        guard let service,
              endpoint.runtimeTypeID == ControlPlaneService.codexRuntimeTypeID,
              !probingEndpointIDs.contains(endpoint.id) else {
            return
        }
        probingEndpointIDs.insert(endpoint.id)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try service.probeCodexEndpoint(
                    endpointID: endpoint.id
                )
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.probingEndpointIDs.remove(endpoint.id)
                switch result {
                case .success:
                    self.reload()
                    self.transientMessage = "Live Codex App Server endpoint verified."
                case .failure(let error):
                    self.reload()
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func probeOpenWorker(_ endpoint: RuntimeEndpoint) {
        guard let service,
              endpoint.runtimeTypeID == ControlPlaneService.openWorkerRuntimeTypeID,
              !probingEndpointIDs.contains(endpoint.id) else {
            return
        }
        probingEndpointIDs.insert(endpoint.id)
        Task { [weak self] in
            let outcome: Result<RuntimeEndpoint, Error>
            do {
                outcome = .success(try await service.probeOpenWorkerEndpoint())
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return }
            probingEndpointIDs.remove(endpoint.id)
            reload()
            switch outcome {
            case .success:
                transientMessage =
                    "Live OpenWorker session endpoint verified. Existing sessions can now be linked."
                await restoreOpenWorkerObservers()
                refreshOpenWorkerSessions()
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    func probeClaudeCode(_ endpoint: RuntimeEndpoint) {
        guard let service,
              endpoint.runtimeTypeID
                == ControlPlaneService.claudeCodeRuntimeTypeID,
              !probingEndpointIDs.contains(endpoint.id) else {
            return
        }
        probingEndpointIDs.insert(endpoint.id)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try service.probeClaudeCodeEndpoint(
                    endpointID: endpoint.id
                )
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                probingEndpointIDs.remove(endpoint.id)
                reload()
                switch result {
                case .success:
                    transientMessage =
                        "Claude Code CLI and authentication were verified."
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func openRuntimeApplication(_ endpoint: RuntimeEndpoint) {
        guard let path = endpoint.nativeConfiguration?["application_path"] else {
            errorMessage = "This Runtime has no registered desktop application."
            return
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "The registered application is no longer installed at \(url.path)."
            return
        }
        NSWorkspace.shared.openApplication(
            at: url,
            configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] _, error in
            Task { @MainActor in
                if let error {
                    self?.errorMessage = error.localizedDescription
                } else {
                    self?.transientMessage = endpoint.runtimeTypeID
                        == ControlPlaneService.openWorkerRuntimeTypeID
                        ? "Opened \(endpoint.muInstanceDisplayName). Probe or re-probe it to refresh the loopback session endpoint."
                        : "Opened \(endpoint.muInstanceDisplayName)."
                }
            }
        }
    }

    func dispatchCodexTask(_ run: RunRecord) {
        guard let service, !dispatchingRunIDs.contains(run.id) else { return }
        dispatchingRunIDs.insert(run.id)
        Task { [weak self] in
            while self?.dispatchingRunIDs.contains(run.id) == true {
                try? await Task.sleep(for: .seconds(1))
                guard let self,
                      self.dispatchingRunIDs.contains(run.id) else {
                    break
                }
                self.reload()
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try service.dispatchCodexTask(runID: run.id) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.dispatchingRunIDs.remove(run.id)
                self.reload()
                switch result {
                case .success(let receipt):
                    if receipt.status == "completed" || receipt.status == "success" {
                        self.transientMessage = nil
                        announceTaskCompletion(
                            taskID: run.taskID,
                            agentName: "Codex"
                        )
                    } else {
                        self.transientMessage =
                            "Codex ended with status \(receipt.status). Review the Task receipt."
                    }
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func dispatchCodexReplan(_ run: RunRecord) {
        guard let service, !dispatchingRunIDs.contains(run.id) else { return }
        dispatchingRunIDs.insert(run.id)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try service.dispatchCodexReplan(runID: run.id) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.dispatchingRunIDs.remove(run.id)
                self.reload()
                switch result {
                case .success:
                    self.transientMessage = "Codex returned a read-only receiving Replan."
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func dispatchClaudeCodeTask(_ run: RunRecord) {
        guard let service,
              !dispatchingRunIDs.contains(run.id) else {
            return
        }
        dispatchingRunIDs.insert(run.id)
        Task { [weak self] in
            while self?.dispatchingRunIDs.contains(run.id) == true {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self,
                      dispatchingRunIDs.contains(run.id) else {
                    break
                }
                reload()
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try service.dispatchClaudeCodeTask(
                    runID: run.id
                )
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                dispatchingRunIDs.remove(run.id)
                reload()
                switch result {
                case .success(let receipt):
                    if receipt.status == "completed" || receipt.status == "success" {
                        transientMessage = nil
                        announceTaskCompletion(
                            taskID: run.taskID,
                            agentName: "Claude Code"
                        )
                    } else {
                        transientMessage =
                            receipt.status == "cancelled"
                            ? "Claude Code was interrupted; its partial receipt is preserved."
                            : "Claude Code ended with status \(receipt.status). Review the Task receipt."
                    }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func interruptClaudeCode(_ run: RunRecord) {
        guard let service else { return }
        do {
            try service.interruptClaudeCodeRun(runID: run.id)
            transientMessage =
                "Interrupt requested for Claude Code."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func interruptCodex(_ run: RunRecord) {
        guard let service else { return }
        do {
            try service.interruptCodexRun(runID: run.id)
            transientMessage =
                "Interrupt requested through Codex App Server."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshOpenWorkerSessions() {
        guard let service,
              endpoints.contains(where: {
                  $0.id == ControlPlaneService.openWorkerEndpointID
                      && $0.status == .active
              }),
              !isLoadingOpenWorkerSessions else {
            return
        }
        isLoadingOpenWorkerSessions = true
        Task { [weak self] in
            let outcome: Result<[OpenWorkerSessionSummary], Error>
            do {
                outcome = .success(try await service.listOpenWorkerSessions())
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return }
            isLoadingOpenWorkerSessions = false
            switch outcome {
            case .success(let sessions):
                let selectedWorkspace = pendingOpenWorkerSessionLink
                    .flatMap { self.task(id: $0.taskID)?.repositoryPath }
                availableOpenWorkerSessions = sessions.sorted { lhs, rhs in
                    let lhsMatches = selectedWorkspace.map {
                        WorkspacePathIdentity.isExactMatch(
                            lhs.workspace,
                            $0
                        )
                    } ?? false
                    let rhsMatches = selectedWorkspace.map {
                        WorkspacePathIdentity.isExactMatch(
                            rhs.workspace,
                            $0
                        )
                    } ?? false
                    if lhsMatches != rhsMatches { return lhsMatches }
                    return (lhs.updatedAt ?? "") > (rhs.updatedAt ?? "")
                }
            case .failure(let error):
                availableOpenWorkerSessions = []
                errorMessage = error.localizedDescription
            }
        }
    }

    func createOpenWorkerSession(for request: OpenWorkerSessionLinkRequest) {
        bindOpenWorkerSession(request: request, existingSession: nil)
    }

    func linkOpenWorkerSession(
        _ session: OpenWorkerSessionSummary,
        for request: OpenWorkerSessionLinkRequest
    ) {
        bindOpenWorkerSession(request: request, existingSession: session)
    }

    func dismissOpenWorkerSessionLink() {
        pendingOpenWorkerSessionLink = nil
    }

    func respondToOpenWorkerApproval(
        _ request: RuntimeInteractionRequest,
        allow: Bool
    ) {
        guard request.kind == .approval else { return }
        Task { [weak self] in
            guard let self, let service else { return }
            do {
                try await service.resolveOpenWorkerInboxInteraction(
                    id: request.id,
                    resolution: allow ? "allow" : "deny",
                    state: allow ? .approved : .denied
                )
                reload()
                transientMessage = allow
                    ? "Approved this OpenWorker action once."
                    : "Denied the OpenWorker action."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func respondToOpenWorkerPlan(
        _ request: RuntimeInteractionRequest,
        approved: Bool
    ) {
        guard request.kind == .plan else { return }
        Task { [weak self] in
            guard let self, let service else { return }
            do {
                let resolution = approved
                    ? #"{"approved":true,"mode":"interactive"}"#
                    : #"{"approved":false,"feedback":"Rejected in Mu."}"#
                try await service.resolveOpenWorkerInboxInteraction(
                    id: request.id,
                    resolution: resolution,
                    state: approved ? .approved : .denied
                )
                reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func answerOpenWorkerQuestion(
        _ request: RuntimeInteractionRequest,
        answer: String
    ) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard request.kind == .question, !trimmed.isEmpty else { return }
        Task { [weak self] in
            guard let self, let service else { return }
            do {
                try await service.resolveOpenWorkerInboxInteraction(
                    id: request.id,
                    resolution: trimmed,
                    state: .answered
                )
                reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func interruptOpenWorker(_ binding: RuntimeSessionBinding) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let bridge = try await ensureOpenWorkerBridge(bindingID: binding.id)
                try await bridge.interrupt()
                transientMessage = "Interrupt sent to OpenWorker session \(binding.nativeSessionID)."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func revealRuntimeArtifact(_ artifact: RuntimeArtifactRecord) {
        guard let absolutePath = artifact.absolutePath,
              let binding = runtimeSessionBindings.first(where: {
                  $0.id == artifact.bindingID
              }) else {
            errorMessage = "This Runtime artifact has no local file reference."
            return
        }
        let root = URL(fileURLWithPath: binding.workspacePath).standardizedFileURL
        let target = URL(fileURLWithPath: absolutePath).standardizedFileURL
        guard target.path == root.path
            || target.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
        else {
            errorMessage = "OpenWorker returned an artifact path outside its bound workspace."
            return
        }
        guard FileManager.default.fileExists(atPath: target.path) else {
            errorMessage = "The Runtime artifact is no longer present at \(target.path)."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    private func startInitialOpenWorkerTask(_ task: TaskRecord) {
        guard let service else { return }
        do {
            let prepared = try service.prepareWorkspaceMessage(
                taskID: task.id,
                text:
                    "@OpenWorker Start this Project task using its governed "
                    + "objective, constraints, and acceptance criteria."
            )
            let binding = try service.bindOpenWorkerSession(
                taskID: task.id,
                chatEntryID: prepared.entry.id
            )
            reload()
            Task { [weak self] in
                await self?.connectAndDispatchOpenWorker(bindingID: binding.id)
            }
        } catch {
            reload()
            errorMessage = error.localizedDescription
        }
    }

    private func bindOpenWorkerSession(
        request: OpenWorkerSessionLinkRequest,
        existingSession: OpenWorkerSessionSummary?
    ) {
        guard let service else { return }
        do {
            let binding = try service.bindOpenWorkerSession(
                taskID: request.taskID,
                chatEntryID: request.chatEntryID,
                existingSession: existingSession
            )
            pendingOpenWorkerSessionLink = nil
            reload()
            transientMessage = existingSession == nil
                ? "Native OpenWorker session prepared."
                : "Linked OpenWorker session \(binding.nativeSessionID)."
            Task { [weak self] in
                await self?.connectAndDispatchOpenWorker(bindingID: binding.id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restoreOpenWorkerObservers() async {
        guard let service else { return }
        let bindings = runtimeSessionBindings.filter {
            $0.state != .detached
                && endpoint(id: $0.endpointID)?.runtimeTypeID
                    == ControlPlaneService.openWorkerRuntimeTypeID
                && isEndpointRegistered(id: $0.endpointID)
        }
        for binding in bindings {
            let uncertainEntries = chatEntries.filter {
                $0.runtimeSessionBindingID == binding.id
                    && $0.deliveryState == .sending
            }
            for entry in uncertainEntries {
                try? await service.markWorkspaceMessageAmbiguous(
                    entryID: entry.id,
                    error: MuError.invalidTransition(
                        "Mu restarted after dispatch but before OpenWorker acknowledged the turn."
                    )
                )
            }
            do {
                _ = try await ensureOpenWorkerBridge(bindingID: binding.id)
                _ = try await service.syncOpenWorkerSession(bindingID: binding.id)
                reload()
                await dispatchNextOpenWorkerMessage(bindingID: binding.id)
            } catch {
                try? await service.recordOpenWorkerConnectionFailure(
                    bindingID: binding.id,
                    error: error
                )
                reload()
            }
        }
    }

    private func connectAndDispatchOpenWorker(bindingID: UUID) async {
        guard let service else { return }
        do {
            _ = try await ensureOpenWorkerBridge(bindingID: bindingID)
            _ = try await service.syncOpenWorkerSession(bindingID: bindingID)
            reload()
            await dispatchNextOpenWorkerMessage(bindingID: bindingID)
        } catch {
            try? await service.recordOpenWorkerConnectionFailure(
                bindingID: bindingID,
                error: error
            )
            reload()
            errorMessage = error.localizedDescription
        }
    }

    private func ensureOpenWorkerBridge(
        bindingID: UUID
    ) async throws -> OpenWorkerSessionBridge {
        if let connectionTask = openWorkerBridgeConnectionTasks[bindingID] {
            return try await connectionTask.value
        }
        if let bridge = openWorkerBridges[bindingID] {
            return bridge
        }
        guard let service else {
            throw MuError.commandFailed("Mu control plane is unavailable.")
        }
        do {
            let bridge = try service.makeOpenWorkerBridge(bindingID: bindingID)
            openWorkerBridges[bindingID] = bridge
            let connectionTask = Task { [weak self] () throws -> OpenWorkerSessionBridge in
                guard let self else {
                    throw MuError.commandFailed("Mu closed while connecting to OpenWorker.")
                }
                _ = try await bridge.connect { [weak self] event in
                    await self?.handleOpenWorkerEvent(bindingID: bindingID, event: event)
                }
                return bridge
            }
            openWorkerBridgeConnectionTasks[bindingID] = connectionTask
            let connectedBridge = try await connectionTask.value
            openWorkerBridgeConnectionTasks.removeValue(forKey: bindingID)
            startOpenWorkerPolling(bindingID: bindingID)
            return connectedBridge
        } catch {
            openWorkerBridgeConnectionTasks.removeValue(forKey: bindingID)
            openWorkerBridges.removeValue(forKey: bindingID)
            try? await service.recordOpenWorkerConnectionFailure(
                bindingID: bindingID,
                error: error
            )
            reload()
            startOpenWorkerPolling(bindingID: bindingID)
            throw error
        }
    }

    private func dispatchNextOpenWorkerMessage(bindingID: UUID) async {
        guard let service,
              !dispatchingSessionBindingIDs.contains(bindingID),
              let binding = runtimeSessionBindings.first(where: { $0.id == bindingID }),
              binding.state != .working,
              binding.state != .awaitingApproval,
              binding.state != .failed,
              binding.state != .disconnected,
              !chatEntries.contains(where: {
                  $0.runtimeSessionBindingID == bindingID
                      && $0.deliveryState == .ambiguous
              }) else {
            return
        }
        guard let entry = try? service.queuedWorkspaceMessages(
            bindingID: bindingID
        ).first else {
            return
        }
        dispatchingSessionBindingIDs.insert(bindingID)
        var didClaimEntry = false
        do {
            let bridge = try await ensureOpenWorkerBridge(bindingID: bindingID)
            let dispatchPayload = try await service.markWorkspaceMessageSending(
                entryID: entry.id,
                bindingID: bindingID
            )
            didClaimEntry = true
            reload()
            guard chatEntries.contains(where: {
                $0.id == entry.id
                    && $0.runtimeSessionBindingID == bindingID
                    && $0.deliveryState == .sending
            }) else {
                throw MuError.invalidTransition(
                    "The claimed Workspace message could not be reloaded safely."
                )
            }
            guard let currentBinding = runtimeSessionBindings.first(where: {
                $0.id == bindingID
            }) else {
                throw MuError.recordNotFound(
                    "OpenWorker session binding \(bindingID)"
                )
            }
            let firstTurnModel =
                currentBinding.origin == "created_by_mu"
                    && currentBinding.lastSyncedMessageCount == 0
                ? currentBinding.model
                : nil
            try await bridge.sendUserMessage(
                dispatchPayload,
                model: firstTurnModel
            )
        } catch {
            if didClaimEntry {
                try? await service.markWorkspaceMessageAmbiguous(
                    entryID: entry.id,
                    error: error
                )
            }
            dispatchingSessionBindingIDs.remove(bindingID)
            reload()
            errorMessage = error.localizedDescription
        }
    }

    private func handleOpenWorkerEvent(
        bindingID: UUID,
        event: OpenWorkerEvent
    ) async {
        guard let service else { return }
        if event.type == "reasoning_delta" {
            return
        }
        let isLiveTextEvent =
            event.type == "turn_start"
                || event.type == "assistant_delta"
                || event.type == "assistant_message"
                || event.type == "turn_done"
                || event.type == "input_rejected"
                || event.type == "connection_closed"
        if isLiveTextEvent {
            var liveTextState =
                openWorkerLiveTextStates[bindingID]
                ?? OpenWorkerLiveTextState()
            let didChange = liveTextState.apply(event)
            openWorkerLiveTextStates[bindingID] = liveTextState
            if didChange {
                if liveTextState.text.isEmpty {
                    if openWorkerStreamingText[bindingID] != nil {
                        openWorkerStreamingText.removeValue(
                            forKey: bindingID
                        )
                    }
                } else if openWorkerStreamingText[bindingID]
                            != liveTextState.text {
                    openWorkerStreamingText[bindingID] =
                        liveTextState.text
                }
            }
        }
        if event.type == "assistant_delta" {
            return
        }
        if event.type == "turn_start" {
            dispatchingSessionBindingIDs.insert(bindingID)
        }
        do {
            let interaction = try await service.recordOpenWorkerEvent(
                bindingID: bindingID,
                event: event
            )
            if event.type == "turn_done" {
                _ = try? await service.syncOpenWorkerSessionReportingChanges(
                    bindingID: bindingID
                )
                if let binding = try? service.store.fetchRuntimeSessionBinding(
                    id: bindingID
                ),
                   let task = try? service.store.fetchTask(id: binding.taskID),
                   task.status == .completed {
                    transientMessage = nil
                    announceTaskCompletion(
                        taskID: binding.taskID,
                        agentName: "OpenWorker"
                    )
                }
                dispatchingSessionBindingIDs.remove(bindingID)
                openWorkerLiveTextStates.removeValue(
                    forKey: bindingID
                )
                if openWorkerStreamingText[bindingID] != nil {
                    openWorkerStreamingText.removeValue(
                        forKey: bindingID
                    )
                }
                reloadOpenWorkerState()
                await dispatchNextOpenWorkerMessage(bindingID: bindingID)
            } else if event.type == "input_rejected" {
                dispatchingSessionBindingIDs.remove(bindingID)
                reloadOpenWorkerState()
            } else if event.type == "connection_closed" {
                dispatchingSessionBindingIDs.remove(bindingID)
                openWorkerBridgeConnectionTasks[bindingID]?.cancel()
                openWorkerBridgeConnectionTasks.removeValue(forKey: bindingID)
                openWorkerBridges.removeValue(forKey: bindingID)
                reloadOpenWorkerState()
            } else if event.type != "assistant_message" {
                if interaction == nil {
                    scheduleOpenWorkerStateReload()
                } else {
                    reloadOpenWorkerState()
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startOpenWorkerPolling(bindingID: UUID) {
        guard openWorkerPollTasks[bindingID] == nil else { return }
        openWorkerPollTasks[bindingID] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, let service else { break }
                guard self.runtimeSessionBindings.contains(where: {
                    $0.id == bindingID && $0.state != .detached
                        && self.registeredEndpoint(id: $0.endpointID)?.status == .active
                }) else {
                    break
                }
                if let result = try? await service
                    .syncOpenWorkerSessionReportingChanges(
                    bindingID: bindingID,
                    includeArtifacts: false
                ) {
                    if result.didChange {
                        self.reloadOpenWorkerState()
                    }
                    await self.dispatchNextOpenWorkerMessage(bindingID: bindingID)
                }
            }
            self?.openWorkerPollTasks.removeValue(forKey: bindingID)
        }
    }
}
