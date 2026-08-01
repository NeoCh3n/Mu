import Foundation
import MuCore
import SwiftUI
import WebKit

enum WorkspaceSurface: String, CaseIterable, Identifiable {
    case chat
    case files
    case browser
    case terminal
    case artifacts

    var id: String { rawValue }

    var title: String {
        self == .artifacts ? "Review" : rawValue.capitalized
    }

    var symbol: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .files: "folder"
        case .browser: "safari"
        case .terminal: "terminal"
        case .artifacts: "shippingbox"
        }
    }
}

struct AgentWorkspaceView: View {
    @EnvironmentObject private var store: AppStore
    let task: TaskRecord
    @State private var surface: WorkspaceSurface = .chat
    @State private var showingEnvironment = false

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeader
                surfaceBar
                Divider()

                HStack(spacing: 0) {
                    surfaceContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if showingEnvironment {
                        Divider()

                        WorkspaceInspector(task: task)
                            .frame(minWidth: 250, idealWidth: 285, maxWidth: 320)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.28))
    }

    private var workspaceHeader: some View {
        HStack(alignment: .center, spacing: 13) {
            if let agent = store.agent(id: task.assignedAgentIdentityID) {
                Text(agent.shortName)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(
                        Color(muHex: agent.accentHex),
                        in: RoundedRectangle(cornerRadius: 11)
                    )
            } else {
                Image(systemName: "person.crop.square.dashed")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)
                    .background(
                        Color.secondary.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 11)
                    )
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(task.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    TaskStatusPill(status: task.status)
                }
                HStack(spacing: 7) {
                    if let agent = store.agent(id: task.assignedAgentIdentityID) {
                        Text("\(agent.displayName) · \(agent.role.displayName)")
                    } else {
                        Text("Unassigned identity")
                    }
                    Text("•")
                    EndpointBadge(
                        endpoint: store.endpoint(id: task.currentEndpointID),
                        fallback: store.endpointDisplayName(id: task.currentEndpointID),
                        isRemoved: store.isEndpointRemoved(id: task.currentEndpointID)
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.captureCheckpoint(taskID: task.id)
            } label: {
                if store.capturingCheckpointTaskIDs.contains(task.id) {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Capturing…")
                    }
                } else {
                    Label("Capture checkpoint", systemImage: "seal")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(MuPalette.violet)
            .disabled(
                (task.status != .running && task.status != .blocked)
                    || store.capturingCheckpointTaskIDs.contains(task.id)
                    || !store.isEndpointRegistered(id: task.currentEndpointID)
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private var surfaceBar: some View {
        HStack(spacing: 5) {
            Button {
                surface = .chat
            } label: {
                Label("Chat", systemImage: WorkspaceSurface.chat.symbol)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        surface == .chat
                            ? MuPalette.violet.opacity(0.12)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(surface == .chat ? MuPalette.violet : .secondary)

            Menu {
                Section("Workspace tools") {
                    ForEach(WorkspaceSurface.allCases.filter { $0 != .chat }) { item in
                        Button {
                            surface = item
                        } label: {
                            Label(item.title, systemImage: item.symbol)
                        }
                    }
                }
                Divider()
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showingEnvironment = true
                    }
                } label: {
                    Label("Environment", systemImage: "sidebar.right")
                }
            } label: {
                Label("Tools", systemImage: "square.grid.2x2")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(.secondary)

            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showingEnvironment.toggle()
                }
            } label: {
                Label(
                    showingEnvironment ? "Hide Environment" : "Environment",
                    systemImage: showingEnvironment ? "sidebar.right" : "sidebar.right"
                )
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    showingEnvironment
                        ? MuPalette.violet.opacity(0.12)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8)
                )
            }
            .buttonStyle(.plain)
            .foregroundStyle(showingEnvironment ? MuPalette.violet : .secondary)
            Text(task.repositoryPath)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 260)
                .layoutPriority(-1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar.opacity(0.45))
    }

    @ViewBuilder
    private var surfaceContent: some View {
        switch surface {
        case .chat:
            WorkspaceChatSurface(task: task)
        case .files:
            WorkspaceFilesSurface(task: task)
        case .browser:
            WorkspaceBrowserSurface(task: task)
        case .terminal:
            WorkspaceTerminalSurface(task: task)
        case .artifacts:
            WorkspaceArtifactsSurface(task: task)
        }
    }
}

private struct WorkspaceChatSurface: View {
    @EnvironmentObject private var store: AppStore
    let task: TaskRecord
    @State private var message = ""
    @State private var isImportedContextExpanded = true
    @State private var isPresentingHistoryFlow = false

    private var entries: [ChatEntry] {
        store.chat(for: task.id)
    }

    private var importedConversations: [ImportedConversation] {
        store.importedConversations(for: task.id)
    }

    private var enabledImportedConversations: [ImportedConversation] {
        importedConversations.filter {
            store.isConversationContextEnabled(
                taskID: task.id,
                conversationID: $0.id
            )
        }
    }

    private var lastHistoryReport: HistoryDiscoveryReport? {
        store.historyDiscoveryReportsByTask[task.id]
    }

    private var discoveredConversationCount: Int {
        lastHistoryReport?.candidates.count ?? 0
    }

    private var unimportedDiscoveredConversationCount: Int {
        guard let lastHistoryReport else { return 0 }
        return lastHistoryReport.candidates.count { candidate in
            !importedConversations.contains { conversation in
                conversation.provider == candidate.provider
                    && conversation.providerInstanceKey
                        == candidate.providerInstanceKey
                    && conversation.nativeSessionID
                        == candidate.nativeSessionID
                    && WorkspacePathIdentity.isExactMatch(
                        conversation.canonicalWorkspacePath,
                        candidate.canonicalWorkspacePath
                    )
            }
        }
    }

    private var isDiscoveringHistory: Bool {
        store.isDiscoveringHistoryTaskIDs.contains(task.id)
    }

    private var bindings: [RuntimeSessionBinding] {
        store.sessionBindings(for: task.id)
    }

    private var openWorkerBindings:
        [RuntimeSessionBinding] {
        bindings.filter {
            store.endpoint(id: $0.endpointID)?.runtimeTypeID
                == ControlPlaneService.openWorkerRuntimeTypeID
        }
    }

    private var primaryBinding: RuntimeSessionBinding? {
        bindings.first(where: { $0.state == .awaitingApproval })
            ?? bindings.first(where: { $0.state == .working })
            ?? bindings.first
    }

    private var interactions: [RuntimeInteractionRequest] {
        store.pendingInteractions(for: task.id)
    }

    private func activity(for binding: RuntimeSessionBinding) -> [LedgerEvent] {
        var summaries = Set([binding.lastActivitySummary])
        return Array(
            store.events(for: task.id)
                .filter {
                    ($0.type.hasPrefix("openworker.")
                        || $0.type.hasPrefix("runtime."))
                        && $0.payload["binding_id"]
                            == binding.id.uuidString
                        && summaries.insert($0.summary).inserted
                }
                .prefix(5)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Workspace chat")
                        .font(.headline)
                    Text(
                        "Use @Agent, @Codex, @Claude, or @OpenWorker "
                            + "to route a bounded Project message."
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    isPresentingHistoryFlow = true
                } label: {
                    if isDiscoveringHistory {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Finding…")
                        }
                    } else {
                        Label(
                            importedConversations.isEmpty
                                ? "Find history"
                                : unimportedDiscoveredConversationCount > 0
                                    ? "Import "
                                        + "\(unimportedDiscoveredConversationCount) more"
                                    : "Import more",
                            systemImage: "clock.arrow.circlepath"
                        )
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isDiscoveringHistory || store.isImportingHistory)

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isImportedContextExpanded.toggle()
                    }
                } label: {
                    StatusPill(
                        label: importedConversations.isEmpty
                            ? "History 0"
                            : "History \(enabledImportedConversations.count)"
                                + " of \(importedConversations.count)",
                        color: enabledImportedConversations.isEmpty
                            ? .secondary
                            : MuPalette.violet,
                        symbol: "clock.badge.checkmark"
                    )
                }
                .buttonStyle(.plain)
                .disabled(importedConversations.isEmpty)
                .help("Show imported history Raw Sources")

                StatusPill(
                    label: primaryBinding.map {
                        bindings.count > 1
                            ? "\(bindings.count) sessions · \($0.state.displayName)"
                            : $0.state.displayName
                    } ?? "Local until @mentioned",
                    color: primaryBinding.map(bindingColor) ?? MuPalette.mint,
                    symbol: primaryBinding?.state == .working ? "bolt.fill" : "lock.doc"
                )
            }
            .padding(18)

            Divider()

            if isDiscoveringHistory,
               let progress =
                store.historyDiscoveryProgressByTask[task.id] {
                HistoryDiscoveryProgressBanner(progress: progress)
                Divider()
            }

            if !openWorkerBindings.isEmpty {
                VStack(spacing: 0) {
                    ForEach(openWorkerBindings) { binding in
                        OpenWorkerSessionBanner(
                            task: task,
                            binding: binding,
                            activity: activity(for: binding),
                            streamingText: store.openWorkerStreamingText[binding.id] ?? ""
                        )
                    }
                }
                Divider()
            }

            if entries.isEmpty
                && interactions.isEmpty
                && importedConversations.isEmpty
                && !hasStreamingOutput {
                EmptyState(
                    symbol: "bubble.left",
                    title: "No workspace messages",
                    message: "Write a local note, or mention @OpenWorker / a routed Agent to start work."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        if !importedConversations.isEmpty {
                            ImportedContextPanel(
                                task: task,
                                conversations: importedConversations,
                                isExpanded: $isImportedContextExpanded,
                                discoveredConversationCount:
                                    discoveredConversationCount
                            )
                        }
                        ForEach(entries) { entry in
                            ChatEntryRow(entry: entry)
                        }
                        ForEach(interactions) { request in
                            OpenWorkerInteractionCard(request: request)
                        }
                        ForEach(openWorkerBindings) { binding in
                            if let stream = store.openWorkerStreamingText[binding.id],
                               !stream.isEmpty {
                                OpenWorkerStreamingRow(
                                    agentName: store.agent(id: binding.agentIdentityID)?
                                        .displayName ?? "OpenWorker",
                                    text: stream
                                )
                            }
                        }
                    }
                    .padding(20)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    ForEach(
                        routeableRuntimeMentions,
                        id: \.self
                    ) { mention in
                        Button("@\(mention)") {
                            insertMention("@\(mention)")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    ForEach(routeableAgents.prefix(4)) { agent in
                        Button("@\(agent.displayName)") {
                            insertMention("@\(agent.displayName)")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Spacer()
                    Text("No mention = local note")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    TextField(
                        "Message this workspace or @Agent to delegate",
                        text: $message,
                        axis: .vertical
                    )
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .onSubmit(send)
                    Button(action: send) {
                        Label(
                            message.contains("@") ? "Route" : "Send",
                            systemImage: "paperplane.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MuPalette.violet)
                    .disabled(
                        message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
            .padding(14)
            .background(.bar.opacity(0.45))
        }
        .sheet(item: $store.pendingOpenWorkerSessionLink) { request in
            OpenWorkerSessionPickerSheet(task: task, request: request)
                .environmentObject(store)
        }
        .sheet(isPresented: $isPresentingHistoryFlow) {
            ConversationHistoryFlowSheet(task: task)
                .environmentObject(store)
        }
        .onAppear {
            if isDiscoveringHistory
                || store.historyImportRequest?.taskID == task.id {
                isPresentingHistoryFlow = true
            }
        }
        .onChange(of: isDiscoveringHistory) { _, discovering in
            if discovering {
                isPresentingHistoryFlow = true
            }
        }
        .onChange(of: store.historyImportRequest?.id) { _, requestID in
            if requestID == task.id {
                isPresentingHistoryFlow = true
            }
        }
    }

    private var hasStreamingOutput: Bool {
        openWorkerBindings.contains {
            !(store.openWorkerStreamingText[$0.id] ?? "").isEmpty
        }
    }

    private var routeableRuntimeMentions:
        [String] {
        let endpoints = store.endpoints.filter {
            $0.status == .active
                && $0.gatewayManifest.supports(
                    .submitInput,
                    endpointIsActive: true
                )
        }
        let codex = endpoints.filter {
            $0.runtimeTypeID
                == ControlPlaneService.codexRuntimeTypeID
        }
        let claude = endpoints.filter {
            $0.runtimeTypeID
                == ControlPlaneService
                .claudeCodeRuntimeTypeID
        }
        var values = codex.map {
            codex.count == 1
                ? "Codex"
                : "codex-"
                    + $0.id.uuidString
                    .lowercased().prefix(8)
        }
        values.append(contentsOf: claude.map {
            claude.count == 1
                ? "Claude"
                : "claude-"
                    + $0.id.uuidString
                    .lowercased().prefix(8)
        })
        if endpoints.contains(where: {
            $0.runtimeTypeID
                == ControlPlaneService
                .openWorkerRuntimeTypeID
        }) {
            values.append("OpenWorker")
        }
        return values.sorted()
    }

    private var routeableAgents: [AgentIdentity] {
        store.agents.filter { agent in
            guard let endpoint = store.registeredEndpoint(id: agent.preferredEndpointID) else {
                return false
            }
            return endpoint.status == .active
                && endpoint.capabilities.contains(.continueRun)
                && endpoint.capabilities.contains(.streamEvents)
        }
    }

    private func send() {
        let value = message
        message = ""
        store.sendChat(taskID: task.id, text: value)
    }

    private func insertMention(_ mention: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        message = trimmed.isEmpty ? "\(mention) " : "\(mention) \(trimmed)"
    }

    private func bindingColor(_ binding: RuntimeSessionBinding) -> Color {
        switch binding.state {
        case .idle, .completed: MuPalette.mint
        case .connecting, .working: MuPalette.violet
        case .awaitingApproval: MuPalette.coral
        case .failed, .disconnected: .red
        case .detached: .secondary
        }
    }
}

private struct ChatEntryRow: View {
    @EnvironmentObject private var store: AppStore
    let entry: ChatEntry

    private var tint: Color {
        switch entry.authorKind {
        case .user: MuPalette.violet
        case .agent: MuPalette.coral
        case .system: MuPalette.mint
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(entry.authorName)
                        .font(.caption.weight(.semibold))
                    if let targetEndpointID = entry.targetEndpointID {
                        Text("→ \(store.endpointDisplayName(id: targetEndpointID))")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(MuPalette.violet)
                    }
                    Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if let deliveryState = entry.deliveryState,
                       deliveryState != .local,
                       deliveryState != .mirrored {
                        Text(deliveryState.rawValue.replacingOccurrences(of: "_", with: " "))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(deliveryColor(deliveryState))
                    }
                }
                MarkdownMessageText(source: entry.text)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if entry.contextSnapshotID != nil {
                    contextReceipt
                }
            }
            Spacer()
        }
        .padding(13)
        .background(
            tint.opacity(entry.authorKind == .system ? 0.055 : 0.08),
            in: RoundedRectangle(cornerRadius: 13)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(tint.opacity(0.12))
        }
    }

    @ViewBuilder
    private var contextReceipt: some View {
        if let snapshot = store.contextSnapshot(id: entry.contextSnapshotID) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "clock.badge.checkmark")
                    Text(
                        "Context \(snapshot.includedMessageIDs.count) messages"
                            + " · \(formattedByteCount(snapshot.utf8ByteCount))"
                    )
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(shortHash(snapshot.contentSHA256))
                        .font(.caption2.monospaced())
                        .help(snapshot.contentSHA256)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(MuPalette.violet)

                Text(truncationSummary(snapshot))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                MuPalette.violet.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(MuPalette.violet.opacity(0.16))
            }
        } else if let snapshotID = entry.contextSnapshotID {
            Label(
                "Context receipt \(snapshotID.uuidString.lowercased().prefix(8)) unavailable",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func truncationSummary(_ snapshot: ContextSnapshot) -> String {
        if snapshot.omittedMessageCount == 0,
           snapshot.truncatedMessageCount == 0 {
            return "No imported messages were omitted or shortened."
        }
        var parts: [String] = []
        if snapshot.omittedMessageCount > 0 {
            parts.append(
                "\(snapshot.omittedMessageCount) omitted"
            )
        }
        if snapshot.truncatedMessageCount > 0 {
            parts.append(
                "\(snapshot.truncatedMessageCount) shortened"
            )
        }
        return "Bounded Context · " + parts.joined(separator: " · ")
    }

    private func shortHash(_ value: String) -> String {
        let normalized = value.hasPrefix("sha256:")
            ? String(value.dropFirst("sha256:".count))
            : value
        return "sha256:\(normalized.prefix(12))…"
    }

    private func formattedByteCount(_ count: Int) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(count),
            countStyle: .file
        )
    }

    private var symbol: String {
        switch entry.authorKind {
        case .user: "person.fill"
        case .agent: "sparkles"
        case .system: "gearshape.fill"
        }
    }

    private func deliveryColor(_ state: ChatDeliveryState) -> Color {
        switch state {
        case .delivered, .mirrored: MuPalette.mint
        case .failed, .ambiguous: .red
        case .cancelled: .secondary
        default: MuPalette.violet
        }
    }
}

private struct MarkdownMessageText: View {
    private let blocks: [MarkdownBlock]

    init(source: String) {
        blocks = MarkdownBlock.parse(source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) {
                entry in
                blockView(entry.element)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text)
                .font(headingFont(level))
                .fontWeight(.semibold)
                .padding(.top, level == 1 ? 2 : 0)
        case .paragraph(let text):
            inlineText(text)
        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) {
                    entry in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("•")
                            .fontWeight(.bold)
                            .accessibilityHidden(true)
                        inlineText(entry.element)
                    }
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) {
                    entry in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("\(entry.offset + 1).")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        inlineText(entry.element)
                    }
                }
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(MuPalette.violet.opacity(0.55))
                    .frame(width: 3)
                inlineText(text)
                    .italic()
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 5) {
                if let language, !language.isEmpty {
                    Text(language.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(text)
                        .font(
                            .system(
                                size: 12,
                                weight: .regular,
                                design: .monospaced
                            )
                        )
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.primary.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 9)
            )
        case .divider:
            Divider()
                .padding(.vertical, 2)
        }
    }

    private func inlineText(_ source: String) -> Text {
        guard let attributed = try? AttributedString(
            markdown: source,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) else {
            return Text(source)
        }
        return Text(attributed)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title3
        case 2: .headline
        default: .subheadline
        }
    }
}

private enum MarkdownBlock: Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case unorderedList([String])
    case orderedList([String])
    case quote(String)
    case code(language: String?, text: String)
    case divider

    static func parse(_ source: String) -> [MarkdownBlock] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(
                in: .whitespaces
            )
            if trimmed.isEmpty {
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                index += 1
                var codeLines: [String] = []
                while index < lines.count {
                    let candidate = lines[index]
                    if candidate.trimmingCharacters(
                        in: .whitespaces
                    ).hasPrefix("```") {
                        index += 1
                        break
                    }
                    codeLines.append(candidate)
                    index += 1
                }
                blocks.append(
                    .code(
                        language: language.isEmpty ? nil : language,
                        text: codeLines.joined(separator: "\n")
                    )
                )
                continue
            }

            if let heading = heading(in: trimmed) {
                blocks.append(
                    .heading(level: heading.level, text: heading.text)
                )
                index += 1
                continue
            }

            if isDivider(trimmed) {
                blocks.append(.divider)
                index += 1
                continue
            }

            if unorderedItem(in: trimmed) != nil {
                var items: [String] = []
                while index < lines.count,
                      let item = unorderedItem(
                          in: lines[index].trimmingCharacters(
                              in: .whitespaces
                          )
                      ) {
                    items.append(item)
                    index += 1
                }
                blocks.append(.unorderedList(items))
                continue
            }

            if orderedItem(in: trimmed) != nil {
                var items: [String] = []
                while index < lines.count,
                      let item = orderedItem(
                          in: lines[index].trimmingCharacters(
                              in: .whitespaces
                          )
                      ) {
                    items.append(item)
                    index += 1
                }
                blocks.append(.orderedList(items))
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(
                        in: .whitespaces
                    )
                    guard candidate.hasPrefix(">") else { break }
                    quoteLines.append(
                        String(candidate.dropFirst())
                            .trimmingCharacters(in: .whitespaces)
                    )
                    index += 1
                }
                blocks.append(
                    .quote(quoteLines.joined(separator: "\n"))
                )
                continue
            }

            var paragraphLines: [String] = []
            while index < lines.count {
                let candidate = lines[index]
                let candidateTrimmed = candidate
                    .trimmingCharacters(in: .whitespaces)
                guard !candidateTrimmed.isEmpty,
                      !candidateTrimmed.hasPrefix("```"),
                      heading(in: candidateTrimmed) == nil,
                      !isDivider(candidateTrimmed),
                      unorderedItem(in: candidateTrimmed) == nil,
                      orderedItem(in: candidateTrimmed) == nil,
                      !candidateTrimmed.hasPrefix(">") else {
                    break
                }
                paragraphLines.append(candidate)
                index += 1
            }
            blocks.append(
                .paragraph(paragraphLines.joined(separator: "\n"))
            )
        }
        return blocks.isEmpty ? [.paragraph(source)] : blocks
    }

    private static func heading(
        in line: String
    ) -> (level: Int, text: String)? {
        let count = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(count),
              line.dropFirst(count).first == " " else {
            return nil
        }
        return (
            count,
            String(line.dropFirst(count + 1))
        )
    }

    private static func unorderedItem(in line: String) -> String? {
        for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }

    private static func orderedItem(in line: String) -> String? {
        guard let dot = line.firstIndex(of: "."),
              dot != line.startIndex,
              line.index(after: dot) < line.endIndex,
              line[line.index(after: dot)] == " ",
              line[..<dot].allSatisfy(\.isNumber) else {
            return nil
        }
        return String(line[line.index(dot, offsetBy: 2)...])
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3,
              let first = compact.first,
              first == "-" || first == "*" || first == "_" else {
            return false
        }
        return compact.allSatisfy { $0 == first }
    }
}

private struct ImportedContextPanel: View {
    @EnvironmentObject private var store: AppStore
    let task: TaskRecord
    let conversations: [ImportedConversation]
    @Binding var isExpanded: Bool
    let discoveredConversationCount: Int

    private var enabledCount: Int {
        conversations.count {
            store.isConversationContextEnabled(
                taskID: task.id,
                conversationID: $0.id
            )
        }
    }

    private var totalMessageCount: Int {
        conversations.reduce(0) { $0 + $1.messageCount }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 9) {
                        Image(
                            systemName: isExpanded
                                ? "chevron.down"
                                : "chevron.right"
                        )
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(MuPalette.violet)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Imported History · Raw Sources")
                                .font(.subheadline.weight(.semibold))
                            Text(
                                historyCountSummary
                                    + " · \(totalMessageCount) visible messages"
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                StatusPill(
                    label: "\(enabledCount) selected",
                    color: enabledCount == 0 ? .secondary : MuPalette.violet,
                    symbol: enabledCount == 0 ? "pause" : "checkmark"
                )
            }

            if isExpanded {
                Text(
                    "These are read-only local copies from other agent tools. "
                        + "This panel shows imported copies, not every conversation "
                        + "found in the Project. "
                        + "They stay visually separate from live Mu messages and "
                        + "never become Project truth automatically. Enabled history "
                        + "is eligible for bounded Context extraction and review; "
                        + "only accepted records may enter a governed Pack."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 9) {
                    ForEach(conversations) { conversation in
                        ImportedConversationCard(
                            task: task,
                            conversation: conversation
                        )
                    }
                }
            }
        }
        .padding(14)
        .background(
            MuPalette.violet.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    MuPalette.violet.opacity(0.18),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        }
    }

    private var historyCountSummary: String {
        let imported =
            "\(conversations.count) imported"
        guard discoveredConversationCount > 0 else {
            return imported
        }
        return imported
            + " · \(discoveredConversationCount) found in last check"
    }
}

private struct ImportedConversationCard: View {
    @EnvironmentObject private var store: AppStore
    let task: TaskRecord
    let conversation: ImportedConversation
    @State private var isExpanded = false
    @State private var isConfirmingRemoval = false

    private var messages: [ImportedConversationMessage] {
        store.importedMessages(for: conversation.id)
    }

    private var isContextEnabled: Bool {
        store.isConversationContextEnabled(
            taskID: task.id,
            conversationID: conversation.id
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    isExpanded.toggle()
                    if isExpanded {
                        store.loadImportedMessages(
                            conversationID: conversation.id
                        )
                    }
                } label: {
                    HStack(alignment: .top, spacing: 9) {
                        Image(
                            systemName: isExpanded
                                ? "chevron.down.circle.fill"
                                : "chevron.right.circle"
                        )
                        .foregroundStyle(MuPalette.violet)
                        .padding(.top, 1)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 7) {
                                Text(conversation.title)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(2)
                                Text(conversation.provider.displayName)
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(providerColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(
                                        providerColor.opacity(0.11),
                                        in: Capsule()
                                    )
                            }

                            RuntimeInstanceIdentityLabel(
                                identity:
                                    conversation.resolvedInstanceIdentity,
                                showsEvidence: false
                            )

                            Text(
                                "\(conversation.nativeSessionID) · "
                                    + "\(conversation.messageCount) messages"
                            )
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 8)

                Toggle(
                    "Select for extraction",
                    isOn: Binding(
                        get: { isContextEnabled },
                        set: { enabled in
                            store.setConversationContextEnabled(
                                taskID: task.id,
                                conversationID: conversation.id,
                                enabled: enabled
                            )
                        }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.caption2)
                .fixedSize()
                .help(
                    isContextEnabled
                        ? "Eligible for bounded candidate extraction and human review; never injected directly"
                        : "Kept as a Raw Source only and excluded from candidate extraction"
                )

                Button(role: .destructive) {
                    isConfirmingRemoval = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove Mu's local copy")
            }

            HStack(spacing: 7) {
                StatusPill(
                    label: resumabilityLabel,
                    color: resumabilityColor,
                    symbol: conversation.resumability == .resumable
                        ? "arrow.triangle.2.circlepath"
                        : "doc.text.magnifyingglass"
                )
                .help(resumabilityHelp)
                if let date = conversation.sourceUpdatedAt {
                    Text(
                        "Updated "
                            + date.formatted(
                                date: .abbreviated,
                                time: .shortened
                            )
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                if conversation.skippedCount > 0 {
                    Text("\(conversation.skippedCount) non-chat items excluded")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if conversation.refreshState == .sourceChanged {
                Label(
                    "The source changed before refresh. Review it before relying on this copy.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption2)
                .foregroundStyle(.red)
            }

            ForEach(conversation.warnings.prefix(2), id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(MuPalette.coral)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isExpanded {
                Divider()
                if messages.isEmpty {
                    Text("No visible user/assistant messages are available in this copy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(messages) { message in
                            ImportedConversationMessageRow(
                                provider: conversation.provider,
                                message: message
                            )
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 11)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(Color.primary.opacity(0.07))
        }
        .alert(
            "Remove local history copy?",
            isPresented: $isConfirmingRemoval
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Remove from Mu", role: .destructive) {
                store.removeImportedConversation(
                    taskID: task.id,
                    conversationID: conversation.id
                )
            }
        } message: {
            Text(
                "Mu will delete this local transcript copy and mark its Raw Source "
                    + "redacted. The original \(conversation.provider.displayName) "
                    + "history is not changed. Immutable audit and delivery hash "
                    + "receipts remain."
            )
        }
    }

    private var providerColor: Color {
        switch conversation.provider {
        case .codex: MuPalette.mint
        case .claudeCode: MuPalette.coral
        case .openWorker: MuPalette.violet
        default: .accentColor
        }
    }

    private var resumabilityLabel: String {
        switch conversation.resumability {
        case .resumable: "Native resumable"
        case .historyOnly: "History only"
        case .unavailable: "Source unavailable"
        }
    }

    private var resumabilityHelp: String {
        switch conversation.resumability {
        case .resumable:
            return "The source supports its native session. Mu keeps this as "
                + "imported Context unless a separate live Runtime binding is available."
        case .historyOnly:
            return "This local copy is available for viewing and Context only."
        case .unavailable:
            return "The original source is unavailable; this local copy remains readable."
        }
    }

    private var resumabilityColor: Color {
        switch conversation.resumability {
        case .resumable: MuPalette.mint
        case .historyOnly: .secondary
        case .unavailable: .red
        }
    }
}

private struct ImportedConversationMessageRow: View {
    let provider: ConversationProvider
    let message: ImportedConversationMessage

    private var roleColor: Color {
        message.role == .user ? MuPalette.violet : MuPalette.coral
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(
                    systemName: message.role == .user
                        ? "person"
                        : "sparkles"
                )
                Text(message.role == .user ? "User" : "Assistant")
                    .font(.caption.weight(.semibold))
                Text("Imported · \(provider.displayName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let phase = message.phase, !phase.isEmpty {
                    Text(phase.replacingOccurrences(of: "_", with: " "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if let date = message.createdAt {
                    Text(
                        date.formatted(
                            date: .abbreviated,
                            time: .shortened
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                if !message.contextEligible {
                    Text("View only")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(roleColor)

            MarkdownMessageText(source: message.text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            roleColor.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(
                    roleColor.opacity(0.16),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        }
    }
}

private struct ConversationHistoryFlowSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let task: TaskRecord
    @State private var selectedProviders: Set<ConversationProvider> = []
    @State private var hasShownImportReview = false

    private var isDiscovering: Bool {
        store.isDiscoveringHistoryTaskIDs.contains(task.id)
    }

    private var progress: HistoryDiscoveryProgress? {
        store.historyDiscoveryProgressByTask[task.id]
    }

    private var importRequest: HistoryImportRequest? {
        guard store.historyImportRequest?.taskID == task.id else {
            return nil
        }
        return store.historyImportRequest
    }

    var body: some View {
        Group {
            if let request = importRequest {
                if WorkspacePathIdentity.isExactMatch(
                    task.repositoryPath,
                    request.report.canonicalWorkspacePath
                ) {
                    ConversationHistoryImportSheet(
                        task: task,
                        request: request
                    )
                    .environmentObject(store)
                } else {
                    HistoryImportMismatchSheet(request: request)
                        .environmentObject(store)
                }
            } else {
                sourceSelection
            }
        }
        .onAppear {
            selectedProviders =
                store.historyDiscoverySelectionsByTask[task.id]
                ?? Set(store.availableHistoryProviders)
            hasShownImportReview = importRequest != nil
        }
        .onChange(of: importRequest?.id) { oldID, newID in
            if newID != nil {
                hasShownImportReview = true
            } else if oldID != nil, hasShownImportReview, !isDiscovering {
                dismiss()
            }
        }
        .onDisappear {
            if importRequest != nil,
               !store.isImportingHistory,
               !isDiscovering {
                store.dismissConversationHistoryImport(taskID: task.id)
            }
        }
        .interactiveDismissDisabled(
            isDiscovering || store.isImportingHistory
        )
    }

    private var sourceSelection: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title2)
                    .foregroundStyle(MuPalette.violet)
                    .frame(width: 42, height: 42)
                    .background(
                        MuPalette.violet.opacity(0.11),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text("Find project history")
                        .font(.title2.weight(.semibold))
                    Text(task.title)
                        .font(.subheadline.weight(.medium))
                    Text(task.repositoryPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(22)

            Divider()

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        "Choose Agent sources",
                        systemImage: "checklist"
                    )
                    .font(.headline)
                    Text(
                        "Mu only checks the sources you select. The check is local and read-only; nothing is copied or sent until you review the matches."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 190), spacing: 10)
                    ],
                    spacing: 10
                ) {
                    ForEach(
                        store.availableHistoryProviders,
                        id: \.self
                    ) { provider in
                        providerToggle(provider)
                    }
                }

                if isDiscovering, let progress {
                    VStack(alignment: .leading, spacing: 11) {
                        HStack {
                            Label(
                                "Read-only check",
                                systemImage: "lock.doc"
                            )
                            .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(
                                "\(progress.completedUnitCount) of "
                                    + "\(progress.totalUnitCount)"
                            )
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                        ProgressView(value: progress.fractionCompleted)
                            .progressViewStyle(.linear)
                            .tint(MuPalette.violet)
                        Text(progressSummary(progress))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if progress.discoveredCandidateCount > 0
                            || progress.issueCount > 0 {
                            Text(
                                "\(progress.discoveredCandidateCount) matches"
                                    + " · \(progress.issueCount) issues"
                            )
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(14)
                    .background(
                        MuPalette.violet.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(
                                MuPalette.violet.opacity(0.18)
                            )
                    }
                } else {
                    Label(
                        "Codex and OpenWorker use native metadata. Claude Code requires inspecting local JSONL records to verify the exact folder.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                }

                Spacer(minLength: 0)
            }
            .padding(22)

            Divider()

            HStack {
                Text(
                    isDiscovering
                        ? "Keep Mu open while the selected sources are checked."
                        : "Matches remain optional Context imports."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isDiscovering)
                Button {
                    store.discoverConversationHistory(
                        taskID: task.id,
                        selectedProviders: selectedProviders
                    )
                } label: {
                    if isDiscovering {
                        HStack(spacing: 7) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking…")
                        }
                    } else {
                        Label(
                            "Start read-only check",
                            systemImage: "magnifyingglass"
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(MuPalette.violet)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    selectedProviders.isEmpty || isDiscovering
                )
            }
            .padding(18)
        }
        .frame(width: 680, height: 560)
    }

    private func providerToggle(
        _ provider: ConversationProvider
    ) -> some View {
        Toggle(
            isOn: Binding(
                get: { selectedProviders.contains(provider) },
                set: { enabled in
                    if enabled {
                        selectedProviders.insert(provider)
                    } else {
                        selectedProviders.remove(provider)
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
                    .lineLimit(1)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(isDiscovering)
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selectedProviders.contains(provider)
                ? MuPalette.violet.opacity(0.075)
                : Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 10)
        )
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

    private func historyProviderDetail(
        _ provider: ConversationProvider
    ) -> String {
        switch provider {
        case .codex: "Desktop, CLI, exec, and editor sessions"
        case .claudeCode: "CLI sessions from local JSONL"
        case .openWorker: "OpenWorker Desktop sessions"
        default: "Registered adapter"
        }
    }

    private func progressSummary(
        _ progress: HistoryDiscoveryProgress
    ) -> String {
        switch progress.stage {
        case .preparing:
            return "Preparing the exact-workspace check…"
        case .discoveringProvider:
            if let provider = progress.provider {
                return "Checking \(provider.displayName)…"
            }
            return "Checking selected sources…"
        case .providerCompleted:
            if let provider = progress.provider {
                return "\(provider.displayName) checked. Continuing…"
            }
            return "A source finished. Continuing…"
        case .completed:
            return "Read-only check complete."
        }
    }
}

private struct HistoryDiscoveryProgressBanner: View {
    let progress: HistoryDiscoveryProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    "Read-only history check",
                    systemImage: "lock.doc"
                )
                .font(.caption.weight(.semibold))
                Spacer()
                Text(
                    "\(progress.completedUnitCount)/"
                        + "\(progress.totalUnitCount)"
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            ProgressView(value: progress.fractionCompleted)
                .progressViewStyle(.linear)
                .tint(MuPalette.violet)
            Text(
                progress.provider.map {
                    "Checking \($0.displayName) for this exact folder…"
                } ?? "Preparing selected history sources…"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(MuPalette.violet.opacity(0.045))
    }
}

private struct ConversationHistoryImportSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let task: TaskRecord
    let request: HistoryImportRequest
    @State private var selectedCandidateIDs: Set<String> = []
    @State private var isConfirmingImport = false

    private var selectedCandidates: [ExternalConversationCandidate] {
        request.report.candidates.filter {
            selectedCandidateIDs.contains($0.id)
        }
    }

    private var visibleProviders: [ConversationProvider] {
        let observed = Set(
            request.report.candidates.map(\.provider)
                + request.report.issues.map(\.provider)
        )
        let selected =
            store.historyDiscoverySelectionsByTask[request.taskID]
            ?? []
        let visible = observed.union(selected)
        let builtIns = ConversationProvider.allCases.filter {
            visible.contains($0)
        }
        let builtInSet = Set(ConversationProvider.allCases)
        let extensions = visible
            .filter { !builtInSet.contains($0) }
            .sorted { $0.rawValue < $1.rawValue }
        return builtIns + extensions
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title2)
                    .foregroundStyle(MuPalette.violet)
                    .frame(width: 42, height: 42)
                    .background(
                        MuPalette.violet.opacity(0.11),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text("Import project conversation history")
                        .font(.title2.weight(.semibold))
                    Text(task.title)
                        .font(.subheadline.weight(.medium))
                    Text(request.report.canonicalWorkspacePath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(22)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    privacyNotice

                    if request.report.candidates.isEmpty {
                        EmptyState(
                            symbol: "clock.badge.questionmark",
                            title: "No matching conversations found",
                            message:
                                "Mu found no user/assistant history for this exact "
                                + "project folder. Provider issues are shown below."
                        )
                        .frame(minHeight: 180)
                    }

                    ForEach(visibleProviders, id: \.self) { provider in
                        providerSection(provider)
                    }
                }
                .padding(22)
            }

            Divider()

            HStack(spacing: 12) {
                Text(
                    selectedCandidateIDs.isEmpty
                        ? "Select one or more conversations. Nothing is selected by default."
                        : "\(selectedCandidateIDs.count) conversation"
                            + (selectedCandidateIDs.count == 1 ? "" : "s")
                            + " selected"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    store.dismissConversationHistoryImport(
                        taskID: request.taskID
                    )
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(store.isImportingHistory)

                Button {
                    isConfirmingImport = true
                } label: {
                    if store.isImportingHistory {
                        HStack(spacing: 7) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Importing…")
                        }
                    } else {
                        Label(
                            "Review & import",
                            systemImage: "square.and.arrow.down"
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(MuPalette.violet)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    selectedCandidateIDs.isEmpty || store.isImportingHistory
                )
            }
            .padding(18)
        }
        .frame(width: 760, height: 700)
        .alert(
            "Import and enable as Context?",
            isPresented: $isConfirmingImport
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Import & enable Context") {
                store.importConversationHistory(
                    taskID: request.taskID,
                    candidates: selectedCandidates
                )
            }
        } message: {
            Text(importConfirmationMessage)
        }
    }

    private var importConfirmationMessage: String {
        let count = selectedCandidates.count
        let noun = count == 1 ? "conversation" : "conversations"
        return "Mu will copy \(count) selected \(noun) into its local database "
            + "and enable their visible user/assistant text as bounded Context "
            + "for the next eligible cross-agent message. The original histories "
            + "are not changed."
    }

    private var privacyNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "Read-only, local import",
                systemImage: "lock.doc"
            )
            .font(.subheadline.weight(.semibold))
            Text(
                "Mu copies only visible user and assistant text into its local "
                    + "database. Reasoning, thinking, tool calls and results, system "
                    + "messages, and developer instructions are not imported. "
                    + "Discovery and import do not send content to an Agent."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Text(
                "Selecting a conversation and confirming Import also authorizes Mu "
                    + "to use that local copy as bounded, quoted Context the next "
                    + "time this Task moves to another Agent or native session."
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(MuPalette.violet)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(
            MuPalette.mint.opacity(0.075),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(MuPalette.mint.opacity(0.20))
        }
    }

    @ViewBuilder
    private func providerSection(
        _ provider: ConversationProvider
    ) -> some View {
        let candidates = request.report.candidates.filter {
            $0.provider == provider
        }
        let issues = request.report.issues.filter {
            $0.provider == provider
        }
        let instanceCount = Set(
            candidates.map {
                $0.resolvedInstanceIdentity.stableInstanceKey
            }
        ).count
        let candidateIDs = Set(candidates.map(\.id))
        let areAllSelected =
            !candidateIDs.isEmpty
                && candidateIDs.isSubset(
                    of: selectedCandidateIDs
                )
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(provider.displayName, systemImage: providerSymbol(provider))
                    .font(.headline)
                Spacer()
                Text(
                    "\(candidates.count) match"
                        + (candidates.count == 1 ? "" : "es")
                        + " · \(instanceCount) instance"
                        + (instanceCount == 1 ? "" : "s")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if !candidates.isEmpty {
                    Button(
                        areAllSelected ? "Clear" : "Select all"
                    ) {
                        if areAllSelected {
                            selectedCandidateIDs.subtract(candidateIDs)
                        } else {
                            selectedCandidateIDs.formUnion(candidateIDs)
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
                }
            }

            ForEach(issues) { issue in
                Label(issue.message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(MuPalette.coral)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        MuPalette.coral.opacity(0.065),
                        in: RoundedRectangle(cornerRadius: 9)
                    )
            }

            ForEach(candidates) { candidate in
                ConversationHistoryCandidateRow(
                    candidate: candidate,
                    isSelected: selectedCandidateIDs.contains(candidate.id)
                ) {
                    if selectedCandidateIDs.contains(candidate.id) {
                        selectedCandidateIDs.remove(candidate.id)
                    } else {
                        selectedCandidateIDs.insert(candidate.id)
                    }
                }
            }
        }
        .padding(14)
        .background(
            Color.primary.opacity(0.028),
            in: RoundedRectangle(cornerRadius: 13)
        )
    }

    private func providerSymbol(_ provider: ConversationProvider) -> String {
        switch provider {
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .claudeCode: "terminal"
        case .openWorker: "person.line.dotted.person.fill"
        default: "cpu"
        }
    }
}

private struct HistoryImportMismatchSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let request: HistoryImportRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(
                "History result no longer matches the selected Project",
                systemImage: "exclamationmark.triangle"
            )
            .font(.title3.weight(.semibold))
            Text(
                "The scan completed for \(request.report.canonicalWorkspacePath). "
                    + "Mu discarded the visual authorization flow instead of applying "
                    + "that result to another project."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            Text(request.report.canonicalWorkspacePath)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            HStack {
                Spacer()
                Button("Close") {
                    store.dismissConversationHistoryImport(
                        taskID: request.taskID
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

private struct ConversationHistoryCandidateRow: View {
    let candidate: ExternalConversationCandidate
    let isSelected: Bool
    let toggleSelection: () -> Void

    var body: some View {
        Button(action: toggleSelection) {
            HStack(alignment: .top, spacing: 12) {
                Image(
                    systemName: isSelected
                        ? "checkmark.square.fill"
                        : "square"
                )
                .font(.title3)
                .foregroundStyle(
                    isSelected ? MuPalette.violet : .secondary
                )

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(
                            candidate.title.isEmpty
                                ? candidate.nativeSessionID
                                : candidate.title
                        )
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        Spacer()
                        StatusPill(
                            label: resumabilityLabel,
                            color: resumabilityColor,
                            symbol: candidate.resumability == .resumable
                                ? "arrow.triangle.2.circlepath"
                                : "doc.text.magnifyingglass"
                        )
                        .help(resumabilityHelp)
                    }

                    RuntimeInstanceIdentityLabel(
                        identity: candidate.resolvedInstanceIdentity
                    )

                    Text(candidate.nativeSessionID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 7) {
                        Text(messageCountLabel)
                        if let date = candidate.updatedAt ?? candidate.createdAt {
                            Text("·")
                            Text(
                                date.formatted(
                                    date: .abbreviated,
                                    time: .shortened
                                )
                            )
                        }
                        if candidate.isArchived {
                            Text("· Archived")
                        }
                        Text("· \(accessLabel)")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                    if let detail = runtimeDetail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    ForEach(candidate.warnings.prefix(2), id: \.self) { warning in
                        Label(
                            warning,
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption2)
                        .foregroundStyle(MuPalette.coral)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isSelected
                ? MuPalette.violet.opacity(0.075)
                : Color.primary.opacity(0.028),
            in: RoundedRectangle(cornerRadius: 11)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(
                    isSelected
                        ? MuPalette.violet.opacity(0.32)
                        : Color.primary.opacity(0.065)
                )
        }
        .accessibilityLabel(
            "\(isSelected ? "Selected" : "Not selected"), "
                + "\(candidate.provider.displayName), \(candidate.title)"
        )
    }

    private var runtimeDetail: String? {
        let values: [String] = [candidate.agentLabel, candidate.model].compactMap {
            candidateValue -> String? in
            guard let value = candidateValue, !value.isEmpty else { return nil }
            return value
        }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private var accessLabel: String {
        switch candidate.accessKind {
        case .vendorProtocol: "Native protocol"
        case .localReadOnlyArtifact: "Local read-only file"
        }
    }

    private var messageCountLabel: String {
        if let count = candidate.discoveredMessageCount {
            return "\(count) visible messages"
        }
        if !candidate.messages.isEmpty {
            return "\(candidate.messages.count) visible messages"
        }
        return "Messages loaded on import"
    }

    private var resumabilityLabel: String {
        switch candidate.resumability {
        case .resumable: "Native resumable"
        case .historyOnly: "History only"
        case .unavailable: "Unavailable"
        }
    }

    private var resumabilityHelp: String {
        switch candidate.resumability {
        case .resumable:
            return "The source can resume this native session. Mu is importing "
                + "its history as Context; this badge does not promise live Mu continuation."
        case .historyOnly:
            return "Mu can import and use this conversation as Context, but cannot resume it."
        case .unavailable:
            return "The source is currently unavailable; import may require reconnecting it."
        }
    }

    private var resumabilityColor: Color {
        switch candidate.resumability {
        case .resumable: MuPalette.mint
        case .historyOnly: .secondary
        case .unavailable: .red
        }
    }
}

private struct OpenWorkerSessionBanner: View {
    @EnvironmentObject private var store: AppStore
    let task: TaskRecord
    let binding: RuntimeSessionBinding
    let activity: [LedgerEvent]
    let streamingText: String

    private var contextRoutingStatus: ImportedContextRoutingStatus? {
        store.importedContextRoutingStatus(
            taskID: task.id,
            bindingID: binding.id
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: binding.state == .working ? "bolt.fill" : "link")
                    .foregroundStyle(binding.state == .working ? MuPalette.violet : MuPalette.mint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        "\(store.agent(id: binding.agentIdentityID)?.displayName ?? "OpenWorker")"
                            + " · \(binding.state.displayName)"
                    )
                        .font(.subheadline.weight(.semibold))
                    Text(
                        "\(binding.nativeSessionID) · \(binding.nativeAgentName)"
                            + (binding.model.map { " · \($0)" } ?? "")
                    )
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                Spacer()
                if binding.state == .working || binding.state == .awaitingApproval {
                    Button("Interrupt") {
                        store.interruptOpenWorker(binding)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                if let endpoint = store.registeredEndpoint(id: binding.endpointID) {
                    Button {
                        store.openRuntimeApplication(endpoint)
                    } label: {
                        Label("Open", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            Text(binding.lastActivitySummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let status = contextRoutingStatus,
               status.state == .requiresRelink
                || status.state == .blockedSourceWorkspace {
                contextRoutingWarning(status)
            }

            if !activity.isEmpty {
                HStack(spacing: 7) {
                    ForEach(activity.prefix(3)) { event in
                        Text(event.summary)
                            .font(.caption2)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.045), in: Capsule())
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(MuPalette.violet.opacity(binding.state == .working ? 0.06 : 0.025))
    }

    private func contextRoutingWarning(
        _ status: ImportedContextRoutingStatus
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(MuPalette.coral)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    status.state == .requiresRelink
                        ? "Imported Context needs a matching OpenWorker session"
                        : "An enabled Context source no longer matches this Project"
                )
                .font(.caption.weight(.semibold))
                Text(status.reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if status.state == .requiresRelink {
                    Text(
                        "Project: \(status.taskWorkspacePath)\n"
                            + "Session: \(status.bindingWorkspacePath)"
                    )
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if status.state == .requiresRelink {
                Button("Create matching session") {
                    store.relinkOpenWorkerForImportedContext(
                        taskID: task.id,
                        bindingID: binding.id
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(MuPalette.violet)
                .controlSize(.small)
                .disabled(!status.canSafelyDetachForRelink)
                .help(
                    status.canSafelyDetachForRelink
                        ? "Detach this mismatched link and create a session for the Project folder"
                        : "Wait until this OpenWorker session is idle"
                )
            }
        }
        .padding(10)
        .background(
            MuPalette.coral.opacity(0.075),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(MuPalette.coral.opacity(0.20))
        }
    }
}

private struct OpenWorkerStreamingRow: View {
    let agentName: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(agentName) · OpenWorker live")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MuPalette.violet)
                MarkdownMessageText(source: text)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(13)
        .background(MuPalette.violet.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
    }
}

private struct OpenWorkerInteractionCard: View {
    @EnvironmentObject private var store: AppStore
    let request: RuntimeInteractionRequest
    @State private var answer = ""
    @State private var selectedOptions: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(request.title, systemImage: symbol)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                StatusPill(
                    label: "Action required",
                    color: MuPalette.coral,
                    symbol: "exclamationmark"
                )
            }
            if !request.detail.isEmpty {
                MarkdownMessageText(source: request.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let arguments = request.payload["arguments"], arguments != "{}" {
                Text(arguments)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
            actions
        }
        .padding(14)
        .background(MuPalette.coral.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(MuPalette.coral.opacity(0.22))
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch request.kind {
        case .approval:
            HStack {
                Button("Approve once") {
                    store.respondToOpenWorkerApproval(request, allow: true)
                }
                .buttonStyle(.borderedProminent)
                .tint(MuPalette.violet)
                Button("Deny") {
                    store.respondToOpenWorkerApproval(request, allow: false)
                }
                .buttonStyle(.bordered)
            }
        case .plan:
            HStack {
                Button("Approve plan") {
                    store.respondToOpenWorkerPlan(request, approved: true)
                }
                .buttonStyle(.borderedProminent)
                .tint(MuPalette.violet)
                Button("Reject") {
                    store.respondToOpenWorkerPlan(request, approved: false)
                }
                .buttonStyle(.bordered)
            }
        case .question:
            questionActions
        case .directory:
            Text("Folder grants stay in OpenWorker Desktop so Mu never broadens filesystem access implicitly.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var questionActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !questionOptions.isEmpty {
                ForEach(questionOptions, id: \.self) { option in
                    Button {
                        if allowsMultipleAnswers {
                            if selectedOptions.contains(option) {
                                selectedOptions.remove(option)
                            } else {
                                selectedOptions.insert(option)
                            }
                        } else {
                            selectedOptions = [option]
                        }
                    } label: {
                        Label(
                            option,
                            systemImage: selectedOptions.contains(option)
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                    }
                    .buttonStyle(.plain)
                }
                Button(allowsMultipleAnswers ? "Send selections" : "Send selection") {
                    let value = questionOptions
                        .filter(selectedOptions.contains)
                        .joined(separator: ", ")
                    store.answerOpenWorkerQuestion(request, answer: value)
                    selectedOptions.removeAll()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedOptions.isEmpty)
            }
            if allowsTextAnswer {
                HStack {
                    TextField("Answer OpenWorker", text: $answer)
                        .textFieldStyle(.roundedBorder)
                    Button("Send") {
                        store.answerOpenWorkerQuestion(request, answer: answer)
                        answer = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            } else if questionOptions.isEmpty {
                Text("Answer this structured question in OpenWorker Desktop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var questionOptions: [String] {
        guard let raw = request.payload["options"], !raw.isEmpty else {
            return []
        }
        if let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let decoded = object as? [String] {
            return decoded
        }
        return raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    private var allowsTextAnswer: Bool {
        request.payload["allow_text"].flatMap(Bool.init) ?? true
    }

    private var allowsMultipleAnswers: Bool {
        request.payload["multi"].flatMap(Bool.init) ?? false
    }

    private var symbol: String {
        switch request.kind {
        case .approval: "checkmark.shield"
        case .directory: "folder.badge.questionmark"
        case .plan: "list.bullet.clipboard"
        case .question: "questionmark.bubble"
        }
    }
}

private struct OpenWorkerSessionPickerSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let task: TaskRecord
    let request: OpenWorkerSessionLinkRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose the OpenWorker session")
                        .font(.title2.weight(.semibold))
                    Text(
                        "Linking preserves one native session in both Mu and OpenWorker Desktop."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    store.refreshOpenWorkerSessions()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(store.isLoadingOpenWorkerSessions)
            }

            Button {
                store.createOpenWorkerSession(for: request)
                dismiss()
            } label: {
                HStack {
                    Image(systemName: "plus.bubble")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Create a new native session")
                            .font(.headline)
                        Text(task.repositoryPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                }
                .padding(12)
            }
            .buttonStyle(.plain)
            .background(MuPalette.violet.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))

            Divider()
            Text("EXISTING OPENWORKER SESSIONS")
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(.tertiary)

            if store.isLoadingOpenWorkerSessions {
                ProgressView("Loading native sessions…")
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else if store.availableOpenWorkerSessions.isEmpty {
                EmptyState(
                    symbol: "rectangle.stack.badge.questionmark",
                    title: "No existing sessions found",
                    message: "Open OpenWorker or create a new native session for this Project."
                )
                .frame(minHeight: 180)
            } else {
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(store.availableOpenWorkerSessions) { session in
                            sessionRow(session)
                        }
                    }
                }
                .frame(minHeight: 220, maxHeight: 380)
            }

            HStack {
                Text("Nothing is sent until you choose a session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    store.dismissOpenWorkerSessionLink()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 650, height: 590)
        .onAppear {
            store.refreshOpenWorkerSessions()
        }
    }

    private func sessionRow(_ session: OpenWorkerSessionSummary) -> some View {
        let sameWorkspace = WorkspacePathIdentity.isExactMatch(
            session.workspace,
            task.repositoryPath
        )
        return Button {
            store.linkOpenWorkerSession(session, for: request)
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: session.liveness == "working" ? "bolt.fill" : "bubble.left")
                    .foregroundStyle(session.liveness == "working" ? MuPalette.violet : MuPalette.mint)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title?.isEmpty == false ? session.title! : session.sessionID)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Text("\(session.sessionID) · \(session.agent) · \(session.model)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(session.workspace)
                        .font(.caption2.monospaced())
                        .foregroundStyle(sameWorkspace ? MuPalette.mint : MuPalette.coral)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !sameWorkspace {
                        Text(
                            "Different folder — unavailable for this Project. "
                                + "Create a matching session above."
                        )
                            .font(.caption2)
                            .foregroundStyle(MuPalette.coral)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(session.liveness?.capitalized ?? "Idle")
                        .font(.caption2.weight(.semibold))
                    Text("\(session.messages) messages")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!sameWorkspace)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .opacity(sameWorkspace ? 1 : 0.66)
        .help(
            sameWorkspace
                ? "Link this exact-workspace OpenWorker session"
                : "Mu does not link OpenWorker sessions from another folder"
        )
    }
}

@MainActor
private final class WorkspaceFilesModel: ObservableObject {
    @Published var files: [WorkspaceFile] = []
    @Published var selectedPath: String?
    @Published var preview = "Select a text file to preview it."
    @Published var error: String?
    @Published var isLoading = true

    private let rootPath: String
    private let service = WorkspaceService()
    private var hasLoaded = false
    private var previewGeneration = 0

    init(rootPath: String) {
        self.rootPath = rootPath
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        isLoading = true

        let rootPath = rootPath
        let outcome = await Task.detached(priority: .userInitiated) {
            do {
                return (files: try WorkspaceService().files(at: rootPath), error: String?.none)
            } catch {
                return (files: [WorkspaceFile](), error: error.localizedDescription)
            }
        }.value

        guard !Task.isCancelled else {
            hasLoaded = false
            isLoading = false
            return
        }
        files = outcome.files
        error = outcome.error
        isLoading = false
    }

    func select(_ file: WorkspaceFile) async {
        previewGeneration += 1
        let generation = previewGeneration
        selectedPath = file.relativePath
        guard !file.isDirectory else {
            preview = "Folder: \(file.relativePath)"
            return
        }

        preview = "Loading \(file.relativePath)…"
        let rootPath = rootPath
        let relativePath = file.relativePath
        let outcome = await Task.detached(priority: .userInitiated) {
            do {
                return try WorkspaceService().readTextFile(
                    rootPath: rootPath,
                    relativePath: relativePath
                )
            } catch {
                return "Preview unavailable: \(error.localizedDescription)"
            }
        }.value

        guard !Task.isCancelled,
              generation == previewGeneration,
              selectedPath == relativePath else {
            return
        }
        preview = outcome
    }
}

private struct WorkspaceFilesSurface: View {
    let task: TaskRecord
    @StateObject private var model: WorkspaceFilesModel

    init(task: TaskRecord) {
        self.task = task
        _model = StateObject(
            wrappedValue: WorkspaceFilesModel(rootPath: task.repositoryPath)
        )
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                surfaceTitle(
                    "Files",
                    subtitle: "Read-only tree · \(model.files.count) visible items",
                    symbol: "folder"
                )
                Divider()
                if model.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = model.error {
                    EmptyState(
                        symbol: "exclamationmark.triangle",
                        title: "Files unavailable",
                        message: error
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(model.files) { file in
                                Button {
                                    Task {
                                        await model.select(file)
                                    }
                                } label: {
                                    HStack(spacing: 7) {
                                        Image(systemName: file.isDirectory ? "folder.fill" : fileSymbol(file))
                                            .foregroundStyle(file.isDirectory ? MuPalette.violet : .secondary)
                                            .frame(width: 16)
                                        Text(file.name)
                                            .lineLimit(1)
                                        Spacer()
                                    }
                                    .font(.caption)
                                    .padding(.leading, CGFloat(file.depth) * 13)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(
                                        model.selectedPath == file.relativePath
                                            ? MuPalette.violet.opacity(0.11)
                                            : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 7)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(8)
                    }
                }
            }
            .frame(minWidth: 210, idealWidth: 245, maxWidth: 320)

            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "doc.text")
                    Text(model.selectedPath ?? "Preview")
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(13)
                Divider()
                ScrollView([.horizontal, .vertical]) {
                    Text(model.preview)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(16)
                }
            }
            .frame(minWidth: 320)
        }
        .task(id: task.id) {
            await model.loadIfNeeded()
        }
    }

    private func fileSymbol(_ file: WorkspaceFile) -> String {
        let suffix = URL(fileURLWithPath: file.name).pathExtension.lowercased()
        return switch suffix {
        case "swift": "swift"
        case "md", "txt": "doc.plaintext"
        case "json", "yml", "yaml", "toml": "curlybraces"
        case "png", "jpg", "jpeg", "gif": "photo"
        default: "doc"
        }
    }
}

@MainActor
private final class BrowserSession: ObservableObject {
    let webView: WKWebView

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func loadFile(_ url: URL, readAccessRoot: URL) {
        webView.loadFileURL(url, allowingReadAccessTo: readAccessRoot)
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
}

private struct BrowserWebView: NSViewRepresentable {
    let session: BrowserSession

    func makeNSView(context: Context) -> WKWebView {
        session.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

private struct WorkspaceBrowserSurface: View {
    let task: TaskRecord
    @StateObject private var session = BrowserSession()
    @State private var address = "https://github.com"
    @State private var hasLoaded = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: session.goBack) {
                    Image(systemName: "chevron.left")
                }
                Button(action: session.goForward) {
                    Image(systemName: "chevron.right")
                }
                Button(action: session.reload) {
                    Image(systemName: "arrow.clockwise")
                }
                TextField("Enter an HTTPS URL", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(load)
                Button("Load", action: load)
                    .buttonStyle(.borderedProminent)
                    .tint(MuPalette.violet)
                Button {
                    loadReadme()
                } label: {
                    Label("README", systemImage: "doc.richtext")
                }
                .help("Open the workspace README without using the network")
            }
            .buttonStyle(.borderless)
            .padding(12)
            .background(.bar.opacity(0.45))

            Divider()

            if hasLoaded {
                BrowserWebView(session: session)
            } else {
                EmptyState(
                    symbol: "safari",
                    title: "Browser ready",
                    message: error
                        ?? "Enter a URL to open it in an isolated, non-persistent WebKit session."
                )
            }
        }
    }

    private func load() {
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.contains("://") {
            value = "https://" + value
        }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            error = "Mu currently accepts HTTP or HTTPS URLs in this browser."
            hasLoaded = false
            return
        }
        address = value
        error = nil
        hasLoaded = true
        session.load(url)
    }

    private func loadReadme() {
        let root = URL(fileURLWithPath: task.repositoryPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let readme = root
            .appending(path: "README.md")
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard readme.path.hasPrefix(root.path + "/"),
              FileManager.default.fileExists(atPath: readme.path) else {
            error = "README.md was not found inside this workspace."
            hasLoaded = false
            return
        }
        address = readme.path
        error = nil
        hasLoaded = true
        session.loadFile(readme, readAccessRoot: root)
    }
}

private struct WorkspaceTerminalSurface: View {
    @EnvironmentObject private var store: AppStore
    let task: TaskRecord
    @State private var result: TerminalResult?
    @State private var isRunning = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Terminal snapshots")
                        .font(.headline)
                    Text("Fixed read-only commands · no interactive shell")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                } else if let result {
                    StatusPill(
                        label: "Exit \(result.exitCode)",
                        color: result.exitCode == 0 ? MuPalette.mint : MuPalette.coral,
                        symbol: result.exitCode == 0 ? "checkmark" : "exclamationmark"
                    )
                }
            }
            .padding(18)

            HStack(spacing: 8) {
                ForEach(TerminalPreset.allCases) { preset in
                    Button(preset.title) {
                        run(preset)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRunning)
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)

            Divider()

            ScrollView([.horizontal, .vertical]) {
                Text(terminalText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, minHeight: 320, alignment: .topLeading)
                    .padding(18)
            }
            .background(Color.black.opacity(0.88))
        }
    }

    private var terminalText: String {
        guard let result else {
            return "$ Select a read-only command snapshot above.\n"
                + "# Mu does not expose an interactive shell in this build."
        }
        return "$ \(result.command)\n\n\(result.output)"
    }

    private func run(_ preset: TerminalPreset) {
        isRunning = true
        let service = store.workspaceService
        let path = task.repositoryPath
        Task {
            let value = await Task.detached(priority: .userInitiated) {
                Result { try service.run(preset, at: path) }
            }.value
            switch value {
            case .success(let terminalResult):
                result = terminalResult
            case .failure(let failure):
                result = TerminalResult(
                    command: preset.title,
                    output: failure.localizedDescription,
                    exitCode: -1
                )
            }
            isRunning = false
        }
    }
}

private struct WorkspaceArtifactsSurface: View {
    @EnvironmentObject private var store: AppStore
    let task: TaskRecord

    private var checkpoints: [CheckpointRecord] {
        store.checkpoints(for: task.id)
    }

    private var runsWithOutput: [RunRecord] {
        store.runs(for: task.id).filter { $0.nativeOutput != nil }
    }

    private var runtimeArtifacts: [RuntimeArtifactRecord] {
        store.runtimeArtifacts(for: task.id)
    }

    private var projectArtifacts: [ProjectArtifactRecord] {
        store.projectArtifacts(for: task.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    SectionHeader(
                        title: "Artifacts",
                        subtitle: "Checkpoint evidence and runtime output with explicit provenance."
                    )
                    Spacer()
                    StatusPill(
                        label:
                            "\(checkpoints.count + projectArtifacts.count + runsWithOutput.count + runtimeArtifacts.count) items",
                        color: MuPalette.mint,
                        symbol: "shippingbox"
                    )
                }

                if checkpoints.isEmpty
                    && projectArtifacts.isEmpty
                    && runtimeArtifacts.isEmpty {
                    Panel {
                        EmptyState(
                            symbol: "shippingbox",
                            title: "No artifacts yet",
                            message: "Capture a checkpoint to seal Git and repository evidence."
                        )
                        .frame(minHeight: 240)
                    }
                }

                ForEach(checkpoints) { checkpoint in
                    Panel(
                        title: "Checkpoint \(checkpoint.contentHash.prefix(12))…",
                        subtitle:
                            checkpoint.createdAt.formatted(date: .abbreviated, time: .shortened)
                            + " · "
                            + store.endpointDisplayName(
                                id: checkpoint.sourceEndpointID,
                                fallback: "Unknown runtime"
                            )
                    ) {
                        VStack(alignment: .leading, spacing: 10) {
                            artifactFact("HEAD", checkpoint.content.repository.headCommit)
                            artifactFact("BRANCH", checkpoint.content.repository.branch)
                            artifactFact(
                                "WORKTREE",
                                checkpoint.content.repository.isDirty ? "Dirty evidence sealed" : "Clean"
                            )
                            if let uri = checkpoint.content.repository.trackedPatchURI {
                                artifactFact("TRACKED PATCH", uri)
                            }
                            if let uri = checkpoint.content.repository.untrackedManifestURI {
                                artifactFact("UNTRACKED MANIFEST", uri)
                            }
                        }
                    }
                }

                ForEach(projectArtifacts) { artifact in
                    Panel(
                        title: artifact.title,
                        subtitle:
                            "Project Artifact · "
                            + artifact.kind.rawValue
                                .replacingOccurrences(
                                    of: "_",
                                    with: " "
                                )
                            + " · v\(artifact.version)"
                    ) {
                        VStack(
                            alignment: .leading,
                            spacing: 10
                        ) {
                            HStack {
                                StatusPill(
                                    label:
                                        artifact.status
                                        .rawValue.capitalized,
                                    color:
                                        artifact.status
                                            == .accepted
                                        ? MuPalette.mint
                                        : artifact.status
                                            == .rejected
                                            ? .red
                                            : MuPalette.coral,
                                    symbol:
                                        artifact.status
                                            == .accepted
                                        ? "checkmark"
                                        : "shippingbox"
                                )
                                Spacer()
                                Text(
                                    artifact.createdAt
                                        .formatted(
                                            date:
                                                .abbreviated,
                                            time:
                                                .shortened
                                        )
                                )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            artifactFact(
                                "SHA256",
                                artifact.sha256
                            )
                            artifactFact(
                                "URI",
                                artifact.uri
                            )
                            if let provider =
                                artifact.metadata[
                                    "provider"
                                ] {
                                artifactFact(
                                    "PRODUCER",
                                    provider
                                )
                            }
                        }
                    }
                }

                ForEach(runsWithOutput) { run in
                    Panel(
                        title: "\(run.actorName) runtime output",
                        subtitle:
                            store.endpointDisplayName(
                                id: run.endpointID,
                                fallback: "Unknown runtime"
                            )
                            + " · Run \(run.id.uuidString.lowercased())"
                    ) {
                        Text(run.nativeOutput ?? "")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                ForEach(runtimeArtifacts) { artifact in
                    Panel(
                        title: artifact.name,
                        subtitle:
                            "OpenWorker · \(artifact.nativeSessionID) · "
                            + artifact.modifiedAt.formatted(
                                date: .abbreviated,
                                time: .shortened
                            )
                    ) {
                        VStack(alignment: .leading, spacing: 10) {
                            artifactFact("NATIVE PATH", artifact.relativePath)
                            artifactFact("KIND", artifact.kind)
                            artifactFact(
                                "SIZE",
                                ByteCountFormatter.string(
                                    fromByteCount: artifact.byteCount,
                                    countStyle: .file
                                )
                            )
                            HStack {
                                Text(
                                    store.endpointDisplayName(
                                        id: artifact.endpointID,
                                        fallback: "Unknown Runtime"
                                    )
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                Spacer()
                                if artifact.absolutePath != nil {
                                    Button("Reveal in Finder") {
                                        store.revealRuntimeArtifact(artifact)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}

private struct WorkspaceInspector: View {
    @EnvironmentObject private var store: AppStore
    let task: TaskRecord

    private var currentRun: RunRecord? {
        store.runs(for: task.id).first { $0.id == task.currentRunID }
    }

    private var project: ProjectRecord? {
        store.projectRecord(for: task.id)
    }

    private var projectLink: TaskProjectLink? {
        store.projectLink(for: task.id)
    }

    private var workspace: ProjectWorkspaceRecord? {
        store.projectWorkspace(for: task.id)
    }

    private var actor: ProjectActorRecord? {
        store.projectActor(
            id:
                currentRun?.actorID
                ?? projectLink?.assignedToActorID
                ?? task.assignedActorID
        )
    }

    private var principal: PrincipalRecord? {
        store.principal(
            id:
                currentRun?.principalID
                ?? actor?.principalID
                ?? projectLink?
                    .costOwnerPrincipalID
        )
    }

    private var activeLease: TaskLeaseRecord? {
        store.activeLease(for: task.id)
    }

    private var contextSources: [ContextSourceRecord] {
        store.kernelContextSources(for: task.id)
    }

    private var contextRecords: [ContextRecord] {
        store.kernelContextRecords(for: task.id)
    }

    private var contextConflicts: [ContextConflictRecord] {
        store.kernelContextConflicts(for: task.id)
    }

    private var contextPacks: [ProjectContextPackRecord] {
        store.kernelContextPacks(for: task.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Environment")
                        .font(.headline)
                    Text("Project state, Agents, runtime, and portable context")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Label("State saves continuously", systemImage: "checkmark.circle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(MuPalette.mint)
                }

                inspectorSection("OBJECTIVE") {
                    Text(task.objective)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }

                inspectorSection("PROJECT CONTRACT") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(project?.displayName ?? "Legacy Project")
                            .font(.subheadline.weight(.semibold))
                        if let project {
                            Text(project.id.uuidString.lowercased())
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        HStack(spacing: 6) {
                            Label(
                                actor?.displayName
                                    ?? "Unassigned Actor",
                                systemImage:
                                    actor?.kind == .human
                                    ? "person"
                                    : "cpu"
                            )
                            Text("·")
                            Text(
                                principal?.displayName
                                    ?? "No Principal"
                            )
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if let workspace {
                    inspectorSection("WORKSPACE") {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(
                                workspace.isolationKind.rawValue
                                    .replacingOccurrences(
                                        of: "_",
                                        with: " "
                                    )
                                    .capitalized
                            )
                            .font(.caption.weight(.semibold))
                            Text(workspace.repositoryPath)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                            if let revision =
                                workspace.baseRevision {
                                Text("Base \(revision)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                inspectorSection("TASK LEASE") {
                    if let activeLease {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                StatusPill(
                                    label: "Active",
                                    color: MuPalette.mint,
                                    symbol: "lock.fill"
                                )
                                Text(
                                    "Fence \(activeLease.fencingToken)"
                                )
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            }
                            Text(
                                "Expires "
                                    + activeLease.expiresAt
                                    .formatted(
                                        date: .omitted,
                                        time: .standard
                                    )
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    } else {
                        Label(
                            "No active lease",
                            systemImage: "lock.open"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                inspectorSection("AGENT IDENTITY") {
                    if let agent = store.agent(id: task.assignedAgentIdentityID) {
                        HStack(spacing: 9) {
                            Text(agent.shortName)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(
                                    Color(muHex: agent.accentHex),
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.displayName)
                                    .font(.subheadline.weight(.semibold))
                                Text(agent.role.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("Unassigned")
                            .foregroundStyle(.secondary)
                    }
                }

                inspectorSection("RUNTIME BOUNDARY") {
                    VStack(alignment: .leading, spacing: 7) {
                        EndpointBadge(
                            endpoint: store.endpoint(id: task.currentEndpointID),
                            fallback: store.endpointDisplayName(id: task.currentEndpointID),
                            isRemoved: store.isEndpointRemoved(id: task.currentEndpointID)
                        )
                        if let endpoint = store.endpoint(id: task.currentEndpointID) {
                            if store.isEndpointRemoved(id: task.currentEndpointID) {
                                Text("Removed from registry · control unavailable")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            Text(endpoint.provenance.displayName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(
                                endpoint.gatewayManifest
                                    .controlMode.rawValue
                                    .replacingOccurrences(
                                        of: "_",
                                        with: " "
                                    )
                                    .capitalized
                                + " · "
                                + endpoint.gatewayManifest
                                    .observationFidelity
                                    .displayName
                            )
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(MuPalette.violet)
                            Text(endpoint.guaranteeNote)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if let currentRun {
                    inspectorSection("CURRENT RUN") {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(currentRun.purpose.rawValue.capitalized)
                                .font(.subheadline.weight(.medium))
                            Text(currentRun.state.rawValue.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(
                                store.endpointDisplayName(
                                    id: currentRun.endpointID,
                                    fallback: "Unknown runtime"
                                )
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            Text(currentRun.id.uuidString.lowercased())
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let threadID = currentRun.nativeThreadID {
                                Text("Thread \(threadID)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            if let turnID = currentRun.nativeTurnID {
                                Text("Turn \(turnID)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            if currentRun.state == .active,
                               let endpoint = store.endpoint(
                                   id: currentRun.endpointID
                               ) {
                                if endpoint.runtimeTypeID
                                    == ControlPlaneService
                                    .codexRuntimeTypeID {
                                    Button(
                                        "Interrupt Codex",
                                        role: .destructive
                                    ) {
                                        store.interruptCodex(
                                            currentRun
                                        )
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                } else if endpoint.runtimeTypeID
                                    == ControlPlaneService
                                    .claudeCodeRuntimeTypeID {
                                    Button(
                                        "Interrupt Claude Code",
                                        role: .destructive
                                    ) {
                                        store
                                            .interruptClaudeCode(
                                                currentRun
                                            )
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }

                inspectorSection("PROJECT CONTEXT") {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 6) {
                            StatusPill(
                                label:
                                    "\(contextSources.filter { $0.state == .active }.count) sources",
                                color: MuPalette.mint,
                                symbol: "tray.full"
                            )
                            StatusPill(
                                label:
                                    "\(contextRecords.filter { $0.status == .accepted }.count) accepted",
                                color: MuPalette.violet,
                                symbol: "checkmark.seal"
                            )
                        }
                        HStack(spacing: 6) {
                            StatusPill(
                                label:
                                    "\(contextRecords.filter { $0.status == .candidate }.count) candidates",
                                color: .orange,
                                symbol: "clock"
                            )
                            StatusPill(
                                label:
                                    "\(contextConflicts.filter { $0.status == .unresolved }.count) conflicts",
                                color:
                                    contextConflicts.contains {
                                        $0.status == .unresolved
                                    }
                                    ? MuPalette.coral
                                    : .secondary,
                                symbol: "exclamationmark.triangle"
                            )
                        }

                        if let source = contextSources.first {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Latest source")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(
                                    source.runtimeProvider?
                                        .displayName
                                        ?? source.sourceType.rawValue
                                            .replacingOccurrences(
                                                of: "_",
                                                with: " "
                                            )
                                            .capitalized
                                )
                                .font(.caption)
                                Text(
                                    source.state.rawValue.capitalized
                                        + " · raw provenance"
                                )
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            }
                        }

                        if let pack = contextPacks.first {
                            Divider()
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Latest immutable pack")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(
                                    pack.selectionPolicyVersion
                                        ?? "Legacy Project pack"
                                )
                                .font(.caption)
                                Text(
                                    "\(pack.includedContextRecordIDs?.count ?? 0) records"
                                        + " · "
                                        + pack.createdAt.formatted(
                                            date: .abbreviated,
                                            time: .shortened
                                        )
                                )
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            }
                        } else if contextSources.isEmpty
                                    && contextRecords.isEmpty {
                            Text("No Context Kernel state yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(
                                "Raw and candidate state is excluded until "
                                    + "a governed pack is built."
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                        }
                    }
                }

                let bindings = store.sessionBindings(for: task.id)
                if !bindings.isEmpty {
                    inspectorSection("NATIVE SESSIONS") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(bindings) { binding in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(
                                            store.endpointDisplayName(
                                                id: binding.endpointID,
                                                fallback: "Unknown Runtime"
                                            )
                                        )
                                        .font(.caption.weight(.semibold))
                                        Spacer()
                                        Text(binding.state.displayName)
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(
                                                binding.state == .working
                                                    ? MuPalette.violet
                                                    : binding.state == .awaitingApproval
                                                        ? MuPalette.coral
                                                        : .secondary
                                            )
                                    }
                                    Text(binding.nativeSessionID)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(
                                        "\(binding.nativeAgentName)"
                                            + (binding.model.map { " · \($0)" } ?? "")
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }

                inspectorSection("CONSTRAINTS") {
                    if task.constraints.isEmpty {
                        Text("No blocking constraints")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(task.constraints, id: \.self) { constraint in
                                Label(constraint, systemImage: "lock")
                                    .font(.caption)
                            }
                        }
                    }
                }

                inspectorSection("EVIDENCE") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label(
                                "\(store.projectArtifacts(for: task.id).count) artifacts",
                                systemImage: "shippingbox"
                            )
                            Spacer()
                            Text(
                                "\(store.projectReviews(for: task.id).count) reviews"
                            )
                        }
                        HStack {
                            Label(
                                "\(store.projectApprovals(for: task.id).filter { $0.decision == .pending }.count) approvals",
                                systemImage: "checkmark.shield"
                            )
                            Spacer()
                            Text(
                                "\(store.events(for: task.id).count) events"
                            )
                        }
                        .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
            .padding(16)
        }
        .background(.bar.opacity(0.25))
    }

    private func inspectorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 11)
        )
    }
}

private func surfaceTitle(_ title: String, subtitle: String, symbol: String) -> some View {
    HStack(spacing: 10) {
        Image(systemName: symbol)
            .foregroundStyle(MuPalette.violet)
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        Spacer()
    }
    .padding(14)
}

private func artifactFact(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
        Text(label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.tertiary)
            .frame(width: 130, alignment: .leading)
        Text(value.isEmpty ? "—" : value)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .lineLimit(2)
        Spacer()
    }
}
