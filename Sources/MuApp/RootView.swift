import MuCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .background {
                    LinearGradient(
                        colors: [
                            MuPalette.violet.opacity(0.035),
                            Color.clear,
                            MuPalette.coral.opacity(0.025)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .ignoresSafeArea()
                }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $store.isCreatingTask) {
            NewTaskSheet()
                .environmentObject(store)
        }
        .sheet(isPresented: $store.isCreatingAgent) {
            NewAgentSheet()
                .environmentObject(store)
        }
        .sheet(isPresented: $store.isRegisteringRuntime) {
            RegisterRuntimeSheet()
                .environmentObject(store)
        }
        .sheet(item: $store.checkpointForHandoff) { checkpoint in
            HandoffProposalSheet(checkpoint: checkpoint)
                .environmentObject(store)
        }
        .sheet(item: $store.handoffToReject) { handoff in
            RejectHandoffSheet(handoff: handoff)
                .environmentObject(store)
        }
        .alert(
            "Mu could not complete that action",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "Unknown error")
        }
        .confirmationDialog(
            registryDeletionTitle,
            isPresented: Binding(
                get: { store.pendingRegistryDeletion != nil },
                set: { if !$0 { store.pendingRegistryDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(registryDeletionActionTitle, role: .destructive) {
                store.confirmRegistryDeletion()
            }
            Button("Cancel", role: .cancel) {
                store.pendingRegistryDeletion = nil
            }
        } message: {
            Text(registryDeletionMessage)
        }
        .overlay(alignment: .bottomTrailing) {
            if let message = store.transientMessage {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(MuPalette.mint)
                    Text(message)
                        .font(.subheadline.weight(.medium))
                    Button {
                        store.transientMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(.thickMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
                .padding(22)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: store.transientMessage)
    }

    private var registryDeletionMessage: String {
        switch store.pendingRegistryDeletion {
        case .agent:
            "Tasks and Runs keep their history but become unassigned. "
                + "This Agent will not return after restart."
        case .endpoint:
            "The Runtime definition will be removed from the registry. "
                + "Its endpoint snapshot and linked Tasks, Runs, Checkpoints, and Handoffs stay unchanged. "
                + "New scheduling, Checkpoint capture, and receiver actions through it will stop, "
                + "and it will not return after restart."
        case nil:
            ""
        }
    }

    private var registryDeletionTitle: String {
        switch store.pendingRegistryDeletion {
        case .endpoint(let endpoint):
            "Remove \(endpoint.muInstanceDisplayName) from the registry?"
        case .agent(let agent):
            "Delete \(agent.displayName)?"
        case nil:
            "Remove registry item?"
        }
    }

    private var registryDeletionActionTitle: String {
        switch store.pendingRegistryDeletion {
        case .endpoint:
            "Remove from registry"
        case .agent, nil:
            "Delete permanently"
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [MuPalette.violet, MuPalette.coral],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Text("μ")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Mu")
                        .font(.headline)
                    Text("Runtime control plane")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 14)

            List(AppSection.allCases) { section in
                let isSelected = store.section == section
                let badgeCount = section == .handoffs ? store.pendingHandoffs.count : 0

                Button {
                    store.section = section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.symbol)
                            .frame(width: 18)
                        Text(section.title)
                            .fontWeight(isSelected ? .semibold : .regular)
                        Spacer(minLength: 8)
                        if badgeCount > 0 {
                            Text("\(badgeCount)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(
                                    isSelected ? Color.white : MuPalette.coral
                                )
                                .padding(.horizontal, 7)
                                .frame(minHeight: 18)
                                .background(
                                    isSelected
                                        ? MuPalette.coral
                                        : MuPalette.coral.opacity(0.12),
                                    in: Capsule()
                                )
                                .accessibilityHidden(true)
                        }
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                                .accessibilityHidden(true)
                        }
                    }
                    .foregroundStyle(isSelected ? MuPalette.violet : Color.primary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                    .background(
                        isSelected
                            ? MuPalette.violet.opacity(0.12)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                isSelected
                                    ? MuPalette.violet.opacity(0.24)
                                    : Color.clear
                            )
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(section.title)
                .accessibilityValue(
                    sidebarAccessibilityValue(
                        isSelected: isSelected,
                        badgeCount: badgeCount
                    )
                )
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .help(section.title)
                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                .listRowSeparator(.hidden)
            }
            .listStyle(.sidebar)

            VStack(alignment: .leading, spacing: 9) {
                Divider()
                HStack(spacing: 8) {
                    Circle()
                        .fill(MuPalette.mint)
                        .frame(width: 7, height: 7)
                    Text("Local control plane")
                        .font(.caption.weight(.medium))
                }
                Text("No hosted relay · SQLite + CAS")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
        }
        .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 270)
    }

    private func sidebarAccessibilityValue(
        isSelected: Bool,
        badgeCount: Int
    ) -> String {
        var parts: [String] = []
        if isSelected {
            parts.append("Selected")
        }
        if badgeCount > 0 {
            parts.append("\(badgeCount) pending")
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var detail: some View {
        switch store.section {
        case .overview:
            DashboardView()
        case .agents:
            AgentsView()
        case .tasks:
            TasksWorkspaceView()
        case .handoffs:
            HandoffsView()
        case .runtimes:
            RuntimesView()
        case .ledger:
            LedgerView()
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject private var store: AppStore

    private var activeTasks: [TaskRecord] {
        store.tasks.filter { !$0.status.isTerminal }
    }

    private var projects: [ProjectGroup] {
        store.projects
    }

    private var activeProjects: [ProjectGroup] {
        projects.filter { $0.activeTaskCount > 0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .bottom) {
                    SectionHeader(
                        title: "Control plane",
                        subtitle: "Projects organize portable Task state across runtime boundaries."
                    )
                    Spacer()
                    Button {
                        store.openNewTask()
                    } label: {
                        Label("New project", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MuPalette.violet)
                }

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4),
                    spacing: 14
                ) {
                    MetricCard(
                        title: "Active Projects",
                        value: "\(activeProjects.count)",
                        detail: "\(activeTasks.count) active Tasks",
                        color: MuPalette.violet,
                        symbol: "bolt.fill"
                    )
                    MetricCard(
                        title: "Handoff inbox",
                        value: "\(store.pendingHandoffs.count)",
                        detail: "Explicit acceptance",
                        color: MuPalette.coral,
                        symbol: "arrow.left.arrow.right"
                    )
                    MetricCard(
                        title: "Checkpoints",
                        value: "\(store.checkpoints.count)",
                        detail: "Immutable records",
                        color: MuPalette.mint,
                        symbol: "seal.fill"
                    )
                    MetricCard(
                        title: "Ledger events",
                        value: "\(store.events.count)",
                        detail: "Append-only history",
                        color: .blue,
                        symbol: "list.bullet.rectangle"
                    )
                }

                HStack(alignment: .top, spacing: 16) {
                    Panel(
                        title: "Active work",
                        subtitle: "Tasks, ownership, runtime, and next Handoff state"
                    ) {
                        if activeTasks.isEmpty {
                            compactEmpty(
                                symbol: "checklist",
                                title: "No active Tasks",
                                message: "Create a Task inside a Project to begin a portable execution record."
                            )
                        } else {
                            VStack(spacing: 0) {
                                ForEach(activeTasks.prefix(5)) { task in
                                    Button {
                                        store.selectTask(task)
                                        store.section = .tasks
                                    } label: {
                                        DashboardTaskRow(task: task)
                                    }
                                    .buttonStyle(.plain)
                                    if task.id != activeTasks.prefix(5).last?.id {
                                        Divider().padding(.leading, 42)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)

                    Panel(
                        title: "Recent ledger",
                        subtitle: "Canonical execution facts"
                    ) {
                        if store.events.isEmpty {
                            compactEmpty(
                                symbol: "clock",
                                title: "No events yet",
                                message: "Control-plane activity will appear here."
                            )
                        } else {
                            VStack(spacing: 0) {
                                ForEach(store.events.prefix(5)) { event in
                                    EventCompactRow(event: event)
                                    if event.id != store.events.prefix(5).last?.id {
                                        Divider().padding(.leading, 32)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }

                Panel {
                    HStack(spacing: 14) {
                        Image(systemName: "lock.shield.fill")
                            .font(.title2)
                            .foregroundStyle(MuPalette.violet)
                            .frame(width: 44, height: 44)
                            .background(MuPalette.violet.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Honest integration boundary")
                                .font(.headline)
                            Text(
                                "The bundled endpoints are offline conformance fixtures. "
                                + "Mu will not label a vendor runtime as controlled until an adapter probe proves it."
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("View runtimes") {
                            store.section = .runtimes
                        }
                    }
                }
            }
            .padding(28)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    store.reload()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private func compactEmpty(symbol: String, title: String, message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

private struct DashboardTaskRow: View {
    @EnvironmentObject private var store: AppStore
    var task: TaskRecord

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9)
                .fill(MuPalette.violet.opacity(0.12))
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: "checklist")
                        .foregroundStyle(MuPalette.violet)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                EndpointBadge(
                    endpoint: store.endpoint(id: task.currentEndpointID),
                    fallback: store.endpointDisplayName(id: task.currentEndpointID),
                    isRemoved: store.isEndpointRemoved(id: task.currentEndpointID)
                )
            }
            Spacer()
            TaskStatusPill(status: task.status)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 10)
    }
}

struct EventCompactRow: View {
    var event: LedgerEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(eventColor.opacity(0.16))
                .frame(width: 24, height: 24)
                .overlay {
                    Image(systemName: eventSymbol)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(eventColor)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(event.summary)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                Text("#\(event.sequence) · \(event.occurredAt.muRelative)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 9)
    }

    private var eventColor: Color {
        if event.type.contains("handoff") { return MuPalette.coral }
        if event.type.contains("checkpoint") { return MuPalette.mint }
        if event.type.contains("run") || event.type.contains("replan") { return MuPalette.violet }
        return .blue
    }

    private var eventSymbol: String {
        if event.type.contains("handoff") { return "arrow.left.arrow.right" }
        if event.type.contains("checkpoint") { return "seal" }
        if event.type.contains("replan") { return "arrow.triangle.branch" }
        return "circle.fill"
    }
}
