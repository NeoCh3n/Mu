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
            NewThreadSheet()
                .environmentObject(store)
        }
        .sheet(isPresented: $store.isCreatingAgent) {
            NewAgentSheet()
                .environmentObject(store)
        }
        .sheet(isPresented: $store.isRegisteringRuntime) {
            RegisterRuntimeSheet(provider: store.runtimeSetupProvider)
                .environmentObject(store)
        }
        .sheet(item: $store.runtimeConfigurationEndpoint) { endpoint in
            RuntimeSettingsSheet(endpoint: endpoint)
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
            VStack(alignment: .trailing, spacing: 10) {
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
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if let notice = store.completionToast {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(MuPalette.mint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(muText(store.interfaceLanguage, "Task completed", "任务已完成"))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                            Text(notice.message)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(2)
                        }
                        Button {
                            store.dismissCompletionToast()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(muText(store.interfaceLanguage, "Dismiss task completion notification", "关闭任务完成通知"))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(22)
        }
        .animation(.snappy, value: store.transientMessage)
        .animation(.snappy, value: store.completionToast)
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
                        Text(muText(store.interfaceLanguage, "Runtime control plane", "运行时控制平面"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 14)

            // Settings is intentionally kept out of the primary navigation;
            // the single Local control plane entry below is its home.
            List(AppSection.allCases.filter { $0 != .settings }) { section in
                let isSelected = store.section == section
                Button {
                    store.section = section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.symbol)
                            .frame(width: 18)
                            Text(section.localizedTitle(for: store.interfaceLanguage))
                            .fontWeight(isSelected ? .semibold : .regular)
                        Spacer(minLength: 8)
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
                .accessibilityLabel(section.localizedTitle(for: store.interfaceLanguage))
                .accessibilityValue(
                    sidebarAccessibilityValue(
                        isSelected: isSelected
                    )
                )
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .help(section.localizedTitle(for: store.interfaceLanguage))
                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                .listRowSeparator(.hidden)
            }
            .listStyle(.sidebar)

            VStack(alignment: .leading, spacing: 9) {
                Divider()
                Button {
                    store.section = .settings
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(MuPalette.mint)
                            .frame(width: 7, height: 7)
                        Text(muText(store.interfaceLanguage, "Local control plane", "本地控制平面"))
                            .font(.caption.weight(.medium))
                        Spacer()
                        Image(systemName: "gearshape")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help(muText(store.interfaceLanguage, "Configure local control plane", "配置本地控制平面"))
                Text(muText(store.interfaceLanguage, "No hosted relay · SQLite + CAS", "无需托管中继 · SQLite + CAS"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(muText(store.interfaceLanguage, "State saves continuously", "状态会自动保存"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
        }
        .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 270)
    }

    private func sidebarAccessibilityValue(
        isSelected: Bool
    ) -> String {
        var parts: [String] = []
        if isSelected {
            parts.append("Selected")
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
        case .settings:
            ControlPlaneSettingsView()
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

    private var participatingAgents: [AgentIdentity] {
        let ids = Set(activeTasks.compactMap(\.assignedAgentIdentityID))
        return store.visibleAgentIdentities.filter { ids.contains($0.id) }
    }

    private func agents(in project: ProjectGroup) -> [AgentIdentity] {
        let ids = Set(project.tasks.compactMap(\.assignedAgentIdentityID))
        return store.visibleAgentIdentities.filter { ids.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .bottom) {
                    SectionHeader(
                        title: muText(store.interfaceLanguage, "Control plane", "控制平面"),
                        subtitle: muText(store.interfaceLanguage, "Projects organize portable Task state across runtime boundaries.", "Projects 将可移植的任务状态组织在不同运行时边界之上。")
                    )
                    Spacer()
                    Button {
                        store.openNewTask()
                    } label: {
                        Label(muText(store.interfaceLanguage, "New project", "新建 Project"), systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MuPalette.violet)
                }

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4),
                    spacing: 14
                ) {
                    MetricCard(
                        title: muText(store.interfaceLanguage, "Active Projects", "活跃 Projects"),
                        value: "\(activeProjects.count)",
                        detail: "\(activeTasks.count) \(muText(store.interfaceLanguage, "active Tasks", "个活跃任务"))",
                        color: MuPalette.violet,
                        symbol: "bolt.fill"
                    )
                    MetricCard(
                        title: muText(store.interfaceLanguage, "Active Tasks", "活跃任务"),
                        value: "\(activeTasks.count)",
                        detail: muText(store.interfaceLanguage, "Across current Projects", "当前 Projects 中"),
                        color: MuPalette.coral,
                        symbol: "bubble.left.and.bubble.right"
                    )
                    MetricCard(
                        title: muText(store.interfaceLanguage, "Agents in work", "参与中的 Agents"),
                        value: "\(participatingAgents.count)",
                        detail: muText(store.interfaceLanguage, "Assigned to active Tasks", "已分配到活跃任务"),
                        color: MuPalette.mint,
                        symbol: "person.2.fill"
                    )
                    MetricCard(
                        title: muText(store.interfaceLanguage, "Connected runtimes", "已连接运行时"),
                        value: "\(store.endpoints.filter { $0.status == .active }.count)",
                        detail: muText(store.interfaceLanguage, "Ready to receive work", "已准备接收工作"),
                        color: .blue,
                        symbol: "point.3.connected.trianglepath.dotted"
                    )
                }

                Panel(
                    title: muText(store.interfaceLanguage, "Current Projects", "当前 Projects"),
                    subtitle: muText(store.interfaceLanguage, "What is in progress and which Agents are participating", "当前进展和参与的 Agents")
                ) {
                    if projects.isEmpty {
                        compactEmpty(
                            symbol: "folder",
                            title: muText(store.interfaceLanguage, "No Projects yet", "还没有 Projects"),
                            message: muText(store.interfaceLanguage, "Create a Project to give Agents a shared workspace.", "创建 Project，为 Agents 提供共享工作区。")
                        )
                    } else {
                        VStack(spacing: 0) {
                            ForEach(projects.prefix(6)) { project in
                                Button {
                                    if let task = project.tasks.first(where: { !$0.status.isTerminal })
                                        ?? project.tasks.first {
                                        store.selectTask(task)
                                    }
                                    store.section = .tasks
                                } label: {
                                    DashboardProjectRow(
                                        project: project,
                                        agents: agents(in: project)
                                    )
                                }
                                .buttonStyle(.plain)
                                if project.id != projects.prefix(6).last?.id {
                                    Divider().padding(.leading, 42)
                                }
                            }
                        }
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    Panel(
                        title: muText(store.interfaceLanguage, "Active work", "当前工作"),
                        subtitle: muText(
                            store.interfaceLanguage,
                            "Threads, ownership, and runtime state",
                            "Thread、负责人和运行时状态"
                        )
                    ) {
                        if activeTasks.isEmpty {
                            compactEmpty(
                                symbol: "checklist",
                                title: muText(store.interfaceLanguage, "No active Threads", "没有活跃 Thread"),
                                message: muText(store.interfaceLanguage, "Create a Thread inside a Project to begin a portable execution record.", "在 Project 中创建 Thread，开始一条可移植的执行记录。")
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
                        title: muText(store.interfaceLanguage, "Agents in the room", "当前参与的 Agents"),
                        subtitle: muText(store.interfaceLanguage, "Identities currently attached to active work", "当前活跃工作中的身份")
                    ) {
                        if participatingAgents.isEmpty {
                            compactEmpty(
                                symbol: "person.2",
                                title: muText(store.interfaceLanguage, "No active Agent assignments", "没有活跃的 Agent 分配"),
                                message: muText(store.interfaceLanguage, "Agents will appear here when a Project Task starts.", "Project 任务开始后，Agent 会显示在这里。")
                            )
                        } else {
                            VStack(spacing: 0) {
                                ForEach(participatingAgents) { agent in
                                    DashboardAgentRow(
                                        agent: agent,
                                        taskCount: store.activeTasks(for: agent.id).count
                                    )
                                    if agent.id != participatingAgents.last?.id {
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
                            Text(muText(store.interfaceLanguage, "Honest integration boundary", "真实集成边界"))
                                .font(.headline)
                            Text(
                                muText(store.interfaceLanguage, "The bundled endpoints are offline conformance fixtures. Mu will not label a vendor runtime as controlled until an adapter probe proves it.", "内置 endpoint 是离线一致性测试 fixture。只有适配器检查通过后，Mu 才会将 vendor runtime 标记为可控。")
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(muText(store.interfaceLanguage, "Manage agents & runtimes", "管理 Agents 和运行时")) {
                            store.section = .agents
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
                    Label(muText(store.interfaceLanguage, "Refresh", "刷新"), systemImage: "arrow.clockwise")
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

private struct DashboardProjectRow: View {
    let project: ProjectGroup
    let agents: [AgentIdentity]

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9)
                .fill(MuPalette.violet.opacity(0.12))
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(MuPalette.violet)
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 7) {
                    Text("\(project.activeTaskCount) active · \(project.taskCount) total")
                    if !agents.isEmpty {
                        Text("·")
                        Text(agents.map(\.displayName).joined(separator: ", "))
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 10)
    }
}

private struct DashboardAgentRow: View {
    let agent: AgentIdentity
    let taskCount: Int

    var body: some View {
        HStack(spacing: 12) {
            Text(agent.shortName)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
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
            Spacer()
            Text("\(taskCount) Task\(taskCount == 1 ? "" : "s")")
                .font(.caption.weight(.medium))
                .foregroundStyle(MuPalette.violet)
        }
        .padding(.vertical, 9)
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
