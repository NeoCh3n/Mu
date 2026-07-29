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
    case handoffs
    case runtimes
    case ledger

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .agents: "Agents"
        case .tasks: "Projects"
        case .handoffs: "Handoffs"
        case .runtimes: "Runtimes"
        case .ledger: "Ledger"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .agents: "person.2.crop.square.stack"
        case .tasks: "checklist"
        case .handoffs: "arrow.left.arrow.right"
        case .runtimes: "point.3.connected.trianglepath.dotted"
        case .ledger: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        }
    }
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
    var location: EndpointLocation = .local
    var provenance: IntegrationProvenance = .vendorCLI
    var permissionModel: PermissionModel = .unknown
    var executablePath = ""
    var notes = ""
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

@MainActor
final class AppStore: ObservableObject {
    @Published var section: AppSection = .overview
    @Published var tasks: [TaskRecord] = []
    @Published var projectPreferences: [ProjectPreference] = []
    @Published var agents: [AgentIdentity] = []
    @Published var chatEntries: [ChatEntry] = []
    @Published var runs: [RunRecord] = []
    @Published var runtimeSessionBindings: [RuntimeSessionBinding] = []
    @Published var runtimeInteractions: [RuntimeInteractionRequest] = []
    @Published var runtimeArtifacts: [RuntimeArtifactRecord] = []
    @Published var importedConversations: [ImportedConversation] = []
    @Published var taskContextSources: [TaskContextSource] = []
    @Published var contextSnapshots: [ContextSnapshot] = []
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

    private(set) var service: ControlPlaneService?
    let workspaceService = WorkspaceService()
    private var openWorkerBridges: [UUID: OpenWorkerSessionBridge] = [:]
    private var openWorkerBridgeConnectionTasks:
        [UUID: Task<OpenWorkerSessionBridge, Error>] = [:]
    private var openWorkerPollTasks: [UUID: Task<Void, Never>] = [:]
    private var openWorkerLiveTextStates:
        [UUID: OpenWorkerLiveTextState] = [:]
    private var openWorkerStateRefreshTask: Task<Void, Never>?

    init(service: ControlPlaneService? = nil) {
        do {
            self.service = try service ?? ControlPlaneService()
            reload()
            Task { [weak self] in
                await self?.verifyOpenWorkerAndRestoreObservers()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func verifyOpenWorkerAndRestoreObservers() async {
        guard let service else { return }
        if endpointSnapshots.contains(where: {
            $0.id == ControlPlaneService.openWorkerEndpointID
        }) {
            _ = try? await service.probeOpenWorkerEndpoint()
            reload()
        }
        await restoreOpenWorkerObservers()
    }

    var selectedTask: TaskRecord? {
        guard let selectedTaskID else { return nil }
        return tasks.first { $0.id == selectedTaskID }
    }

    var projects: [ProjectCatalog.Project] {
        ProjectCatalog.projects(
            from: tasks,
            preferences: projectPreferences
        )
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

    func checkpoints(for taskID: UUID) -> [CheckpointRecord] {
        checkpoints.filter { $0.taskID == taskID }.sorted { $0.createdAt > $1.createdAt }
    }

    func events(for taskID: UUID) -> [LedgerEvent] {
        events.filter { $0.taskID == taskID }
    }

    func reload() {
        guard let service else { return }
        do {
            let nextTasks = try service.store.fetchTasks()
            let nextProjectPreferences =
                try service.store.fetchProjectPreferences()
            let nextAgents = try service.store.fetchAgents()
            let nextChatEntries = try service.store.fetchChatEntries()
            let nextRuns = try service.store.fetchRuns()
            let nextRuntimeSessionBindings =
                try service.store.fetchRuntimeSessionBindings()
            let nextRuntimeInteractions =
                try service.store.fetchRuntimeInteractions()
            let nextRuntimeArtifacts =
                try service.store.fetchRuntimeArtifacts()
            let nextImportedConversations =
                try service.store.fetchImportedConversations()
            let nextTaskContextSources = try nextTasks.flatMap {
                try service.store.fetchTaskContextSources(taskID: $0.id)
            }
            let nextContextSnapshots =
                try service.store.fetchContextSnapshots()
            let importedConversationIDs =
                Set(nextImportedConversations.map(\.id))
            let nextImportedMessagesByConversation =
                importedMessagesByConversation
                .filter { importedConversationIDs.contains($0.key) }
            let nextCheckpoints = try service.store.fetchCheckpoints()
            let nextHandoffs = try service.store.fetchHandoffs()
            let nextEndpointSnapshots = try service.store.fetchEndpoints()
            let nextEndpoints =
                try service.store.fetchRegisteredEndpoints()
            let nextRegistryTombstones =
                try service.store.fetchRegistryTombstones()
            let nextEvents = try service.store.fetchEvents()

            replaceIfChanged(&tasks, with: nextTasks)
            replaceIfChanged(
                &projectPreferences,
                with: nextProjectPreferences
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
                preferences: nextProjectPreferences
            ).flatMap(\.tasks)
            if selectedTaskID == nil
                || !visibleTasks.contains(where: {
                    $0.id == selectedTaskID
                }) {
                selectedTaskID = visibleTasks.first?.id
            }
        } catch {
            errorMessage = error.localizedDescription
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

    func openNewTask(projectPath: String) {
        preselectedAgentID = nil
        pendingTaskProjectPath = standardizedProjectPath(projectPath)
        collapsedProjectPaths.remove(
            standardizedProjectPath(projectPath)
        )
        isCreatingTask = true
    }

    private func standardizedProjectPath(_ path: String) -> String {
        WorkspacePathIdentity.canonicalPath(path)
    }

    func sendChat(taskID: UUID, text: String) {
        guard let service else { return }
        do {
            let prepared = try service.prepareWorkspaceMessage(
                taskID: taskID,
                text: text
            )
            reload()
            guard let route = prepared.route else {
                transientMessage = "Local workspace note saved."
                return
            }
            if let bindingID = prepared.entry.runtimeSessionBindingID {
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
                notes: draft.notes
            )
            reload()
            isRegisteringRuntime = false
            transientMessage =
                "Runtime “\(endpoint.muInstanceDisplayName)” registered offline pending an adapter probe."
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
            errorMessage = error.localizedDescription
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
            section = .handoffs
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
            let result = Result { try service.probeCodexEndpoint() }
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
                    self.transientMessage = receipt.status == "completed"
                        ? "Codex completed the native read-only run; receipts are in Chat, Artifacts, and Ledger."
                        : "Codex ended with status \(receipt.status). Review the Task receipt."
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
        let criteria = task.successCriteria.isEmpty
            ? ""
            : "\n\nSuccess criteria:\n"
                + task.successCriteria.map { "- \($0)" }.joined(separator: "\n")
        let constraints = task.constraints.isEmpty
            ? ""
            : "\n\nConstraints:\n"
                + task.constraints.map { "- \($0)" }.joined(separator: "\n")
        do {
            let prepared = try service.prepareWorkspaceMessage(
                taskID: task.id,
                text: "@OpenWorker \(task.objective)\(criteria)\(constraints)"
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
        if let contextStatus =
            try? service.importedContextRoutingStatus(
                taskID: binding.taskID,
                bindingID: bindingID
            ),
            contextStatus.blocksAutomaticDispatch {
            // Keep the message queued and let the inline relink UI resolve the
            // deterministic workspace boundary. Retrying every poll would
            // only reproduce the same global error.
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
