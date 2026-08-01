import AppKit
import MuCore
import SwiftUI

struct NewTaskSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = CreateTaskDraft()
    @State private var selectedHistoryProviders =
        Set(ConversationProvider.allCases)
    @State private var isShowingAdvancedDetails = false

    private var existingProjectPath: String? {
        store.pendingTaskProjectPath
    }

    private var existingProjectName: String? {
        existingProjectPath.map {
            URL(fileURLWithPath: $0).lastPathComponent
        }
    }

    private var isAddingTaskToExistingProject: Bool {
        existingProjectPath != nil
    }

    private var isValid: Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.repositoryPath.isEmpty
            && draft.sourceEndpointID != nil
            && draft.agentIdentityID != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader(
                title: isAddingTaskToExistingProject
                    ? "New Task in \(existingProjectName ?? "Project")"
                    : "Import folder as a Project",
                subtitle: isAddingTaskToExistingProject
                    ? "Start another Task in this Project workspace."
                    : "Choose a Project folder and create its first Task.",
                symbol: isAddingTaskToExistingProject
                    ? "plus.bubble"
                    : "folder.badge.plus"
            )

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    fieldGroup("PROJECT FOLDER") {
                        VStack(alignment: .leading, spacing: 10) {
                            if isAddingTaskToExistingProject {
                                HStack(spacing: 11) {
                                    Image(systemName: "folder.fill")
                                        .font(.title3)
                                        .foregroundStyle(MuPalette.violet)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(existingProjectName ?? "Project")
                                            .font(.subheadline.weight(.semibold))
                                        Text(draft.repositoryPath)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer()
                                }
                                .padding(11)
                                .background(
                                    Color.primary.opacity(0.045),
                                    in: RoundedRectangle(
                                        cornerRadius: 9,
                                        style: .continuous
                                    )
                                )
                            } else {
                                HStack {
                                    TextField(
                                        "/path/to/project",
                                        text: $draft.repositoryPath
                                    )
                                    .textFieldStyle(.roundedBorder)
                                    Button("Choose…") { chooseTaskFolder() }
                                }
                            }

                            Label(
                                isAddingTaskToExistingProject
                                    ? "This Task shares the Project folder, files, and related Agent history."
                                    : "This exact folder becomes the Project and is used to match history and native sessions.",
                                systemImage: "scope"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }

                    fieldGroup("RELATED HISTORY · OPTIONAL") {
                        VStack(alignment: .leading, spacing: 11) {
                            Text(
                                "After creation, Mu can perform a local read-only check for conversations tied to this exact folder. Every match identifies its Desktop, CLI, editor, or native session before you import it as Context."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                            LazyVGrid(
                                columns: [
                                    GridItem(
                                        .adaptive(minimum: 180),
                                        spacing: 9
                                    )
                                ],
                                spacing: 9
                            ) {
                                ForEach(
                                    store.availableHistoryProviders,
                                    id: \.self
                                ) { provider in
                                    historyProviderToggle(provider)
                                }
                            }
                        }
                    }

                    fieldGroup(
                        isAddingTaskToExistingProject
                            ? "TASK"
                            : "FIRST TASK"
                    ) {
                        TextField("Task title", text: $draft.title)
                            .textFieldStyle(.roundedBorder)
                    }
                    fieldGroup("OBJECTIVE") {
                        TextEditor(text: $draft.objective)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(height: 88)
                            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                    }
                    fieldGroup("AGENT IDENTITY") {
                        Picker("Agent identity", selection: $draft.agentIdentityID) {
                            Text("Choose an agent").tag(UUID?.none)
                            ForEach(store.selectableAgentIdentities) { agent in
                                Text("\(agent.displayName) · \(agent.role.displayName)")
                                    .tag(Optional(agent.id))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onChange(of: draft.agentIdentityID) { _, newAgentID in
                            guard let agent = store.agent(id: newAgentID),
                                  let preferredID = agent.preferredEndpointID,
                                  store.initialTaskEndpoints.contains(where: {
                                      $0.id == preferredID
                                  }) else {
                                return
                            }
                            draft.sourceEndpointID = preferredID
                        }
                    }
                    fieldGroup("SOURCE RUNTIME") {
                        Picker("Source runtime", selection: $draft.sourceEndpointID) {
                            Text("Choose an endpoint").tag(UUID?.none)
                            ForEach(store.initialTaskEndpoints) { endpoint in
                                Text(endpoint.muRuntimePickerLabel)
                                    .tag(Optional(endpoint.id))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    DisclosureGroup(
                        "Success criteria, constraints, and pending steps",
                        isExpanded: $isShowingAdvancedDetails
                    ) {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(alignment: .top, spacing: 14) {
                                fieldGroup("SUCCESS CRITERIA · ONE PER LINE") {
                                    lineEditor(
                                        text: $draft.successCriteria,
                                        placeholder: "Build succeeds\nCore workflow is verified"
                                    )
                                }
                                fieldGroup("BLOCKING CONSTRAINTS · ONE PER LINE") {
                                    lineEditor(
                                        text: $draft.constraints,
                                        placeholder: "No remote data upload\nDo not overwrite user changes"
                                    )
                                }
                            }
                            fieldGroup("PENDING STEPS · ONE PER LINE") {
                                lineEditor(
                                    text: $draft.pendingSteps,
                                    placeholder: "Implement the next slice\nRun tests\nPackage the app",
                                    height: 92
                                )
                            }
                        }
                        .padding(.top, 12)
                    }
                    .font(.subheadline.weight(.semibold))
                }
                .padding(24)
            }

            Divider()

            HStack {
                Text(
                    selectedHistoryProviders.isEmpty
                        ? "No history will be inspected. You can use Find history later."
                        : "History discovery is read-only; import remains a separate choice."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    store.isCreatingTask = false
                    store.pendingTaskProjectPath = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(
                    createButtonTitle
                ) {
                    store.createTask(
                        from: draft,
                        discoverHistoryProviders: selectedHistoryProviders
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(MuPalette.violet)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(18)
        }
        .frame(width: 760, height: 760)
        .onAppear {
            if let existingProjectPath {
                draft.repositoryPath = existingProjectPath
            }
            if draft.agentIdentityID == nil {
                draft.agentIdentityID = store.preselectedAgentID
                    ?? store.selectableAgentIdentities.first?.id
            }
            if draft.sourceEndpointID == nil {
                let preferredID = store.agent(id: draft.agentIdentityID)?.preferredEndpointID
                if let preferredID,
                   store.initialTaskEndpoints.contains(where: { $0.id == preferredID }) {
                    draft.sourceEndpointID = preferredID
                } else {
                    draft.sourceEndpointID = store.initialTaskEndpoints.first?.id
                }
            }
            store.preselectedAgentID = nil
        }
        .onDisappear {
            store.pendingTaskProjectPath = nil
        }
    }

    private var createButtonTitle: String {
        if isAddingTaskToExistingProject {
            return selectedHistoryProviders.isEmpty
                ? "Create Task"
                : "Create Task & find history"
        }
        return selectedHistoryProviders.isEmpty
            ? "Create Project & Task"
            : "Create & find history"
    }

    private func chooseTaskFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose the Project folder"
        panel.prompt = "Import folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            guard let folder = panel.url else { return }
            draft.repositoryPath = folder.path
            if draft.title.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty {
                draft.title = folder.lastPathComponent
            }
            if draft.objective.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty {
                draft.objective =
                    "Continue the existing work in \(folder.lastPathComponent)."
            }
        }
    }

    private func historyProviderToggle(
        _ provider: ConversationProvider
    ) -> some View {
        Toggle(
            isOn: Binding(
                get: { selectedHistoryProviders.contains(provider) },
                set: { enabled in
                    if enabled {
                        selectedHistoryProviders.insert(provider)
                    } else {
                        selectedHistoryProviders.remove(provider)
                    }
                }
            )
        ) {
            VStack(alignment: .leading, spacing: 3) {
                Label(
                    provider.displayName,
                    systemImage: historyProviderSymbol(provider)
                )
                .font(.subheadline.weight(.semibold))
                Text(historyProviderDetail(provider))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selectedHistoryProviders.contains(provider)
                ? MuPalette.violet.opacity(0.075)
                : Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 9)
        )
    }

    private func historyProviderDetail(
        _ provider: ConversationProvider
    ) -> String {
        switch provider {
        case .codex:
            "Desktop and each CLI/exec/editor session are identified separately"
        case .claudeCode:
            "CLI sessions; terminal name is shown only when recorded"
        case .openWorker:
            "OpenWorker Desktop and its native sessions"
        default:
            "Registered Agent history adapter"
        }
    }

    private func historyProviderSymbol(
        _ provider: ConversationProvider
    ) -> String {
        switch provider {
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .claudeCode: "terminal"
        case .openWorker: "person.line.dotted.person.fill"
        default: "cpu"
        }
    }

    private func lineEditor(
        text: Binding<String>,
        placeholder: String,
        height: CGFloat = 112
    ) -> some View {
        ZStack(alignment: .topLeading) {
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
            }
            TextEditor(text: text)
                .font(.subheadline)
                .scrollContentBackground(.hidden)
                .padding(7)
        }
        .frame(height: height)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct NewAgentSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = CreateAgentDraft()

    private let accentOptions = [
        ("Violet", "#6E4CEB"),
        ("Coral", "#F46E4D"),
        ("Mint", "#36B892"),
        ("Blue", "#2F80ED"),
        ("Amber", "#D98B23"),
        ("Rose", "#D64F7D")
    ]

    private var isValid: Bool {
        !draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader(
                title: "Add agent identity",
                subtitle: "Create a reusable Mu work profile independently from its runtime.",
                symbol: "person.crop.square.badge.plus"
            )
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        fieldGroup("DISPLAY NAME") {
                            TextField("e.g. Maya", text: $draft.displayName)
                                .textFieldStyle(.roundedBorder)
                        }
                        fieldGroup("SHORT LABEL · OPTIONAL") {
                            TextField("Auto-generated", text: $draft.shortName)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    fieldGroup("ROLE") {
                        Picker("Role", selection: $draft.role) {
                            ForEach(AgentRole.allCases, id: \.self) { role in
                                Text(role.displayName).tag(role)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }

                    fieldGroup("SUMMARY") {
                        TextEditor(text: $draft.summary)
                            .accessibilityLabel("Agent summary")
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(height: 92)
                            .background(
                                Color.primary.opacity(0.045),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                    }

                    fieldGroup("PREFERRED RUNTIME · OPTIONAL") {
                        Picker("Preferred runtime", selection: $draft.preferredEndpointID) {
                            Text("No preference").tag(UUID?.none)
                            ForEach(store.endpoints) { endpoint in
                                Text(
                                    "\(endpoint.muInstanceDisplayName) · "
                                        + endpoint.status.rawValue
                                )
                                    .tag(Optional(endpoint.id))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    fieldGroup("CAPABILITY TAGS · COMMA OR NEWLINE SEPARATED") {
                        TextField(
                            "research, implementation, review",
                            text: $draft.capabilityTags
                        )
                        .textFieldStyle(.roundedBorder)
                    }

                    fieldGroup("ACCENT") {
                        HStack(spacing: 10) {
                            ForEach(accentOptions, id: \.1) { option in
                                Button {
                                    draft.accentHex = option.1
                                } label: {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(Color(muHex: option.1))
                                            .frame(width: 14, height: 14)
                                        Text(option.0)
                                            .font(.caption)
                                        if draft.accentHex == option.1 {
                                            Image(systemName: "checkmark")
                                                .font(.caption2.weight(.bold))
                                        }
                                    }
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 7)
                                    .background(
                                        draft.accentHex == option.1
                                            ? Color(muHex: option.1).opacity(0.12)
                                            : Color.primary.opacity(0.035),
                                        in: Capsule()
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Label(
                        "Deleting an identity later preserves ledger history and unassigns its Tasks.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(24)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") {
                    store.isCreatingAgent = false
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Add agent") {
                    store.createAgent(from: draft)
                }
                .buttonStyle(.borderedProminent)
                .tint(MuPalette.violet)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(18)
        }
        .frame(width: 690, height: 660)
    }
}

struct RegisterRuntimeSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = RegisterRuntimeDraft()

    private let manualProvenance: [IntegrationProvenance] = [
        .vendorProtocol, .vendorSDK, .vendorCLI, .artifactOnly
    ]

    private var isValid: Bool {
        !draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.runtimeTypeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader(
                title: "Register runtime",
                subtitle: "Add an honest endpoint definition without pretending an adapter is live.",
                symbol: "point.3.connected.trianglepath.dotted"
            )
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    fieldGroup("DISPLAY NAME") {
                        TextField("e.g. Pi RPC", text: $draft.displayName)
                            .textFieldStyle(.roundedBorder)
                    }
                    fieldGroup("RUNTIME TYPE ID") {
                        TextField(
                            "vendor.runtime/adapter",
                            text: $draft.runtimeTypeID
                        )
                        .textFieldStyle(.roundedBorder)
                        Text("Stable namespace/adapter form, for example earendil.pi/coding-agent-rpc.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    HStack(spacing: 14) {
                        fieldGroup("SURFACE") {
                            Picker(
                                "Surface",
                                selection: $draft.surfaceKind
                            ) {
                                Text("Desktop")
                                    .tag(
                                        AgentRuntimeSurfaceKind
                                            .desktopApplication
                                    )
                                Text("Terminal CLI")
                                    .tag(
                                        AgentRuntimeSurfaceKind
                                            .terminalCLI
                                    )
                                Text("Local service")
                                    .tag(
                                        AgentRuntimeSurfaceKind
                                            .localService
                                    )
                                Text("Remote service")
                                    .tag(
                                        AgentRuntimeSurfaceKind
                                            .remoteService
                                    )
                            }
                            .labelsHidden()
                        }
                        fieldGroup("INSTANCE LABEL") {
                            TextField(
                                "e.g. Claude · Terminal 2",
                                text: $draft.instanceLabel
                            )
                            .textFieldStyle(.roundedBorder)
                        }
                        fieldGroup("TERMINAL ID · OPTIONAL") {
                            TextField(
                                "e.g. ttys003",
                                text:
                                    $draft
                                    .terminalIdentifier
                            )
                            .textFieldStyle(.roundedBorder)
                            .disabled(
                                draft.surfaceKind
                                    != .terminalCLI
                            )
                        }
                    }

                    HStack(spacing: 14) {
                        fieldGroup("LOCATION") {
                            Picker("Location", selection: $draft.location) {
                                ForEach(EndpointLocation.allCases, id: \.self) { location in
                                    Text(location.rawValue.capitalized).tag(location)
                                }
                            }
                            .labelsHidden()
                        }
                        fieldGroup("PROVENANCE") {
                            Picker("Provenance", selection: $draft.provenance) {
                                ForEach(manualProvenance, id: \.self) { provenance in
                                    Text(provenance.displayName).tag(provenance)
                                }
                            }
                            .labelsHidden()
                        }
                        fieldGroup("PERMISSIONS") {
                            Picker("Permissions", selection: $draft.permissionModel) {
                                ForEach(PermissionModel.allCases, id: \.self) { model in
                                    Text(
                                        model.rawValue
                                            .replacingOccurrences(of: "_", with: " ")
                                            .capitalized
                                    )
                                    .tag(model)
                                }
                            }
                            .labelsHidden()
                        }
                    }

                    fieldGroup("EXECUTABLE · OPTIONAL") {
                        HStack {
                            TextField("/path/to/runtime", text: $draft.executablePath)
                                .textFieldStyle(.roundedBorder)
                            Button("Choose…") { chooseExecutable() }
                        }
                    }

                    fieldGroup("NOTES · OPTIONAL") {
                        TextEditor(text: $draft.notes)
                            .accessibilityLabel("Runtime notes")
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(height: 100)
                            .background(
                                Color.primary.opacity(0.045),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                    }

                    Panel {
                        Label(
                            "Manual definitions start Offline with zero capabilities. "
                                + "A runtime-specific adapter and successful probe must promote them.",
                            systemImage: "lock.shield"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") {
                    store.isRegisteringRuntime = false
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Register runtime") {
                    store.registerRuntime(from: draft)
                }
                .buttonStyle(.borderedProminent)
                .tint(MuPalette.violet)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(18)
        }
        .frame(width: 700, height: 680)
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Choose a runtime executable"
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            draft.executablePath = panel.url?.path ?? draft.executablePath
        }
    }
}

struct HandoffProposalSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var checkpoint: CheckpointRecord
    @State private var receiverEndpointID: UUID?

    private var compatibleEndpoints: [RuntimeEndpoint] {
        store.endpoints(excluding: checkpoint.sourceEndpointID).filter {
            $0.status == .active
                && $0.capabilities.contains(.start)
                && $0.capabilities.contains(.replan)
        }
    }

    private var receiver: RuntimeEndpoint? {
        store.endpoint(id: receiverEndpointID)
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader(
                title: "Propose handoff",
                subtitle: "Transfer responsibility through a sealed Checkpoint and mandatory Replan.",
                symbol: "arrow.left.arrow.right.square.fill"
            )
            Divider()

            VStack(alignment: .leading, spacing: 18) {
                Panel(title: "Sealed input", subtitle: checkpoint.contentHash) {
                    HStack(spacing: 24) {
                        checkpointFact("OBJECTIVE", checkpoint.content.objective, wide: true)
                        checkpointFact("BRANCH", checkpoint.content.repository.branch)
                        checkpointFact("HEAD", String(checkpoint.content.repository.headCommit.prefix(10)))
                    }
                }

                fieldGroup("RECEIVER ENDPOINT") {
                    Picker("Receiver", selection: $receiverEndpointID) {
                        Text("Choose a compatible receiver").tag(UUID?.none)
                        ForEach(compatibleEndpoints) { endpoint in
                            Text(endpoint.muRuntimePickerLabel)
                                .tag(Optional(endpoint.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let receiver {
                    Panel {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                EndpointBadge(endpoint: receiver)
                                Spacer()
                                StatusPill(
                                    label: "Start + Replan",
                                    color: MuPalette.mint,
                                    symbol: "checkmark"
                                )
                            }
                            Text(receiver.guaranteeNote)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Divider()
                            Label(
                                "Acceptance creates a new Run. The source stays owner until that transaction commits.",
                                systemImage: "lock.shield"
                            )
                            .font(.caption)
                        }
                    }
                } else if compatibleEndpoints.isEmpty {
                    Label(
                        "No other active endpoint currently advertises both Start and Replan.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(MuPalette.coral)
                }

                Spacer()
            }
            .padding(24)

            Divider()
            HStack {
                Text("Cross-runtime Continue is prohibited in the first slice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    store.checkpointForHandoff = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Propose handoff") {
                    if let receiverEndpointID {
                        store.proposeHandoff(
                            checkpoint: checkpoint,
                            receiverEndpointID: receiverEndpointID
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(MuPalette.violet)
                .keyboardShortcut(.defaultAction)
                .disabled(receiverEndpointID == nil)
            }
            .padding(18)
        }
        .frame(width: 660, height: 540)
        .onAppear {
            receiverEndpointID = compatibleEndpoints.first?.id
        }
    }

    private func checkpointFact(_ label: String, _ value: String, wide: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.monospaced())
                .lineLimit(wide ? 2 : 1)
        }
        .frame(maxWidth: wide ? .infinity : nil, alignment: .leading)
    }
}

struct RejectHandoffSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var handoff: HandoffRecord
    @State private var reason = ""

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader(
                title: "Reject handoff",
                subtitle: "Ownership remains with the sender and the reason enters the ledger.",
                symbol: "xmark.square.fill"
            )
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                fieldGroup("REASON") {
                    TextEditor(text: $reason)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(height: 120)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                }
                Text("Rejection does not delete the Checkpoint or rewrite prior events.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(24)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") {
                    store.handoffToReject = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Reject") {
                    store.rejectHandoff(handoff, reason: reason)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(.defaultAction)
            }
            .padding(18)
        }
        .frame(width: 520, height: 360)
    }
}

private func sheetHeader(title: String, subtitle: String, symbol: String) -> some View {
    HStack(spacing: 14) {
        Image(systemName: symbol)
            .font(.title2)
            .foregroundStyle(MuPalette.violet)
            .frame(width: 42, height: 42)
            .background(MuPalette.violet.opacity(0.11), in: RoundedRectangle(cornerRadius: 12))
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
    }
    .padding(20)
}

private func fieldGroup<Content: View>(
    _ label: String,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 7) {
        Text(label)
            .font(.caption2.weight(.bold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
        content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
}
