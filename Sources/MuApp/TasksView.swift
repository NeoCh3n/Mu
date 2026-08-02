import Foundation
import MuCore
import SwiftUI

struct TasksWorkspaceView: View {
    @EnvironmentObject private var store: AppStore
    @SceneStorage("mu.projects.collapsed-project-paths")
    private var collapsedProjectPathsPayload = ""
    @State private var fullyRevealedProjectIDs: Set<UUID> = []
    @State private var projectToRename: ProjectCatalog.Project?
    @State private var projectRenameValue = ""
    @State private var projectPendingRemoval: ProjectCatalog.Project?

    private var projects: [ProjectCatalog.Project] {
        store.projects
    }

    var body: some View {
        HSplitView {
            taskList
                .frame(minWidth: 250, idealWidth: 300, maxWidth: 360)

            if let task = store.selectedTask {
                AgentWorkspaceView(task: task)
                    .id(task.id)
            } else {
                EmptyState(
                    symbol: "checklist",
                    title: muText(store.interfaceLanguage, "No Task selected", "未选择任务"),
                    message: muText(store.interfaceLanguage, "Choose a Task inside a Project, or create a new one.", "选择 Project 中的任务，或创建一个新任务。")
                )
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    store.openNewTask()
                } label: {
                    Label(muText(store.interfaceLanguage, "New Project", "新建 Project"), systemImage: "plus")
                }
            }
        }
        .onAppear {
            restoreProjectExpansion()
            if let selectedTask = store.selectedTask {
                store.selectTask(selectedTask)
            }
        }
        .onChange(of: store.collapsedProjectPaths) { _, paths in
            persistProjectExpansion(paths)
        }
        .alert(
            "Rename project",
            isPresented: Binding(
                get: { projectToRename != nil },
                set: { isPresented in
                    if !isPresented {
                        projectToRename = nil
                    }
                }
            )
        ) {
            TextField("Project name", text: $projectRenameValue)
            Button("Cancel", role: .cancel) {
                projectToRename = nil
            }
            Button("Rename") {
                guard let projectToRename else { return }
                store.renameProject(
                    path: projectToRename.path,
                    displayName: projectRenameValue
                )
                self.projectToRename = nil
            }
            .disabled(
                projectRenameValue.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            )
        } message: {
            Text(
                "This changes only the name shown in Mu. "
                    + "The folder on disk is not renamed."
            )
        }
        .alert(
            "Remove project from Mu?",
            isPresented: Binding(
                get: { projectPendingRemoval != nil },
                set: { isPresented in
                    if !isPresented {
                        projectPendingRemoval = nil
                    }
                }
            ),
            presenting: projectPendingRemoval
        ) { project in
            Button("Cancel", role: .cancel) {
                projectPendingRemoval = nil
            }
            Button("Remove", role: .destructive) {
                store.removeProject(path: project.path)
                fullyRevealedProjectIDs.remove(project.id)
                projectPendingRemoval = nil
            }
        } message: { project in
            Text(
                "“\(project.name)” will disappear from Mu. "
                    + "Its folder, files, Task records, and external Agent "
                    + "history will not be deleted."
            )
        }
    }

    private var taskList: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(muText(store.interfaceLanguage, "Projects", "Projects"))
                        .font(.title3.weight(.semibold))
                    Text(projectCountSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    store.openNewTask()
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(muText(store.interfaceLanguage, "New Project", "新建 Project"))
                .accessibilityLabel(muText(store.interfaceLanguage, "New Project", "新建 Project"))
            }
            .padding(18)

            Divider()

            if projects.isEmpty {
                EmptyState(
                    symbol: "tray",
                    title: muText(store.interfaceLanguage, "No projects", "还没有 Projects"),
                    message: muText(store.interfaceLanguage, "Create the first project to start the execution ledger.", "创建第一个 Project 以开始执行记录。")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        ForEach(projects) { project in
                            projectSection(project)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                }
            }
        }
        .background(.bar.opacity(0.35))
    }

    private var projectCountSummary: String {
        let visibleTaskCount = projects.reduce(0) {
            $0 + $1.taskCount
        }
        let projectLabel = projects.count == 1 ? "Project" : "Projects"
        let taskLabel = visibleTaskCount == 1 ? "Task" : "Tasks"
        return "\(projects.count) \(projectLabel) · \(visibleTaskCount) \(taskLabel)"
    }

    @ViewBuilder
    private func projectSection(
        _ project: ProjectCatalog.Project
    ) -> some View {
        let isExpanded = store.isProjectExpanded(path: project.path)
        let containsSelectedTask = project.tasks.contains {
            $0.id == store.selectedTaskID
        }
        let isFullyRevealed = fullyRevealedProjectIDs.contains(project.id)
        let visibleTasks = visibleTasks(
            in: project,
            isFullyRevealed: isFullyRevealed
        )

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        store.toggleProject(path: project.path)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(
                            systemName: isExpanded
                                ? "chevron.down"
                                : "chevron.right"
                        )
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)

                        Image(
                            systemName: isExpanded
                                ? "folder.fill"
                                : "folder"
                        )
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(
                            containsSelectedTask
                                ? MuPalette.violet
                                : Color.secondary
                        )
                        .frame(width: 18)

                        Text(project.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 6)

                        Text("\(project.taskCount)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.leading, 7)
                    .padding(.trailing, 5)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(project.path)
                .accessibilityLabel(
                    "\(project.name), \(project.taskCount) "
                        + (project.taskCount == 1 ? "Task" : "Tasks")
                )
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityHint(
                    isExpanded
                        ? "Collapse this Project"
                        : "Expand this Project"
                )

                Button {
                    store.openNewTask(projectPath: project.path)
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New Task in \(project.name)")
                .accessibilityLabel("New Task in \(project.name)")

                Menu {
                    Button {
                        projectRenameValue = project.name
                        projectToRename = project
                    } label: {
                        Label("Rename project", systemImage: "pencil")
                    }

                    Button(role: .destructive) {
                        projectPendingRemoval = project
                    } label: {
                        Label("Remove", systemImage: "xmark")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Project actions")
                .accessibilityLabel("Project actions for \(project.name)")
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(visibleTasks) { task in
                        Button {
                            store.selectTask(task)
                        } label: {
                            TaskTreeRow(
                                task: task,
                                agent: store.agent(
                                    id: task.assignedAgentIdentityID
                                ),
                                isSelected: store.selectedTaskID == task.id
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(task.title)
                        .accessibilityValue(
                            "\(task.status.displayName), "
                                + "\(store.agent(id: task.assignedAgentIdentityID)?.displayName ?? "Unassigned")"
                        )
                        .accessibilityHint(
                            "Open this Task in \(project.name)"
                        )
                        .accessibilityAddTraits(
                            store.selectedTaskID == task.id
                                ? .isSelected
                                : []
                        )
                        .accessibilityRemoveTraits(
                            store.selectedTaskID == task.id
                                ? []
                                : .isSelected
                        )
                    }

                    if project.tasks.count > 6 {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) {
                                if isFullyRevealed {
                                    fullyRevealedProjectIDs.remove(project.id)
                                } else {
                                    fullyRevealedProjectIDs.insert(project.id)
                                }
                            }
                        } label: {
                            Text(
                                isFullyRevealed
                                    ? "Show less"
                                    : "Show \(project.tasks.count - 6) more"
                            )
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 44)
                            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .transition(
                    .opacity.combined(
                        with: .move(edge: .top)
                    )
                )
            }
        }
    }

    private func visibleTasks(
        in project: ProjectCatalog.Project,
        isFullyRevealed: Bool
    ) -> [TaskRecord] {
        guard !isFullyRevealed, project.tasks.count > 6 else {
            return project.tasks
        }
        var tasks = Array(project.tasks.prefix(6))
        guard let selectedTask = project.tasks.first(where: {
            $0.id == store.selectedTaskID
        }), !tasks.contains(where: { $0.id == selectedTask.id }) else {
            return tasks
        }
        tasks.removeLast()
        tasks.append(selectedTask)
        return tasks
    }

    private func restoreProjectExpansion() {
        if collapsedProjectPathsPayload.isEmpty {
            store.collapsedProjectPaths = Set(
                projects.compactMap { project in
                    project.tasks.contains {
                        $0.id == store.selectedTaskID
                    } ? nil : project.path
                }
            )
            return
        }
        guard let data = collapsedProjectPathsPayload.data(using: .utf8),
              let paths = try? JSONDecoder().decode(
                  [String].self,
                  from: data
              ) else {
            return
        }
        store.collapsedProjectPaths = Set(paths)
    }

    private func persistProjectExpansion(_ paths: Set<String>) {
        guard let data = try? JSONEncoder().encode(paths.sorted()),
              let payload = String(data: data, encoding: .utf8) else {
            return
        }
        collapsedProjectPathsPayload = payload
    }
}

private struct TaskTreeRow: View {
    var task: TaskRecord
    var agent: AgentIdentity?
    var isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: statusSymbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(statusColor)
                .frame(width: 12)

            Text(task.title)
                .font(
                    .subheadline.weight(
                        isSelected ? .semibold : .regular
                    )
                )
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)
        }
        .padding(.leading, 37)
        .padding(.trailing, 9)
        .frame(maxWidth: .infinity, minHeight: 36)
        .contentShape(Rectangle())
        .background(
            isSelected
                ? MuPalette.violet.opacity(0.13)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .help(
            "\(task.title)\n\(task.status.displayName)"
                + (agent.map { "\n\($0.displayName)" } ?? "")
        )
    }

    private var statusColor: Color {
        switch task.status {
        case .draft, .ready:
            .secondary
        case .running:
            MuPalette.mint
        case .handoffPending:
            MuPalette.coral
        case .blocked, .failed:
            .red
        case .completed:
            .blue
        case .cancelled:
            .gray
        }
    }

    private var statusSymbol: String {
        switch task.status {
        case .draft, .ready:
            "circle"
        case .running:
            "circle.fill"
        case .handoffPending:
            "arrow.left.arrow.right"
        case .blocked:
            "exclamationmark.circle.fill"
        case .failed:
            "xmark.circle.fill"
        case .completed:
            "checkmark.circle.fill"
        case .cancelled:
            "minus.circle.fill"
        }
    }
}

struct TaskDetailView: View {
    @EnvironmentObject private var store: AppStore
    var task: TaskRecord

    private var taskRuns: [RunRecord] { store.runs(for: task.id) }
    private var taskCheckpoints: [CheckpointRecord] { store.checkpoints(for: task.id) }
    private var taskEvents: [LedgerEvent] { store.events(for: task.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        objectivePanel
                        repositoryPanel
                        replanPanel
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 16) {
                        runPanel
                        checkpointPanel
                        timelinePanel
                    }
                    .frame(width: 360)
                }
            }
            .padding(26)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    TaskStatusPill(status: task.status)
                    if task.currentEndpointID != nil {
                        StatusPill(
                            label: store.endpointDisplayName(id: task.currentEndpointID),
                            color: !store.isEndpointRegistered(id: task.currentEndpointID)
                                ? .secondary
                                : MuPalette.violet,
                            symbol: "cpu"
                        )
                    }
                }
                Text(task.title)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("Task \(task.id.uuidString.lowercased())")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
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
    }

    private var objectivePanel: some View {
        Panel(title: "Objective", subtitle: "Portable intent, not hidden conversation state") {
            Text(task.objective)
                .font(.body)
                .textSelection(.enabled)

            if !task.successCriteria.isEmpty {
                Divider()
                labeledList(
                    title: "Success criteria",
                    symbol: "checkmark.circle",
                    color: MuPalette.mint,
                    values: task.successCriteria
                )
            }
            if !task.constraints.isEmpty {
                Divider()
                labeledList(
                    title: "Constraints",
                    symbol: "exclamationmark.shield",
                    color: MuPalette.coral,
                    values: task.constraints
                )
            }
            if !task.pendingSteps.isEmpty {
                Divider()
                labeledList(
                    title: "Pending work",
                    symbol: "arrow.right.circle",
                    color: MuPalette.violet,
                    values: task.pendingSteps
                )
            }
        }
    }

    private var repositoryPanel: some View {
        Panel(title: "Repository", subtitle: "Artifact source of truth") {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.blue)
                    .frame(width: 34, height: 34)
                    .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(URL(fileURLWithPath: task.repositoryPath).lastPathComponent)
                        .font(.subheadline.weight(.semibold))
                    Text(task.repositoryPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer()
            }

            if let snapshot = taskCheckpoints.first?.content.repository {
                HStack(spacing: 16) {
                    repositoryFact("Branch", snapshot.branch)
                    repositoryFact("HEAD", String(snapshot.headCommit.prefix(10)))
                    repositoryFact("Worktree", snapshot.isDirty ? "Dirty" : "Clean")
                    repositoryFact("Untracked", "\(snapshot.untrackedFiles.count)")
                }
                .padding(.top, 3)
            } else {
                Text("Capture a Checkpoint to inspect branch, commit, diff, and untracked evidence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var replanPanel: some View {
        if let replanRun = taskRuns.first(where: { $0.purpose == .replan }) {
            Panel(
                title: replanRun.nativeThreadID == nil ? "Receiving replan" : "Codex receiving replan",
                subtitle: replanRun.nativeThreadID == nil
                    ? "Generated from sealed portable state"
                    : "Live App Server · read-only · no approval escalation"
            ) {
                if store.dispatchingRunIDs.contains(replanRun.id) {
                    HStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.small)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Codex is reconstructing the receiving plan")
                                .font(.subheadline.weight(.semibold))
                            Text("The Replan sandbox is read-only and cannot mutate the repository.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                } else if let output = replanRun.nativeOutput {
                    Text(.init(output))
                        .font(.subheadline)
                        .textSelection(.enabled)
                    if let threadID = replanRun.nativeThreadID,
                       let turnID = replanRun.nativeTurnID {
                        Divider()
                        Text("Thread \(threadID) · Turn \(turnID)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                } else {
                    ForEach(Array(replanRun.plan.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 11) {
                            Text("\(index + 1)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(MuPalette.violet)
                                .frame(width: 23, height: 23)
                                .background(MuPalette.violet.opacity(0.12), in: Circle())
                            Text(step)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    private var runPanel: some View {
        Panel(title: "Runs", subtitle: "One runtime boundary, one Run") {
            if taskRuns.isEmpty {
                Text("No Runs recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(taskRuns) { run in
                    HStack(spacing: 10) {
                        Image(systemName: run.purpose == .replan ? "arrow.triangle.branch" : "bolt")
                            .foregroundStyle(run.purpose == .replan ? MuPalette.coral : MuPalette.violet)
                            .frame(width: 28, height: 28)
                            .background(
                                (run.purpose == .replan ? MuPalette.coral : MuPalette.violet).opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(run.actorName)
                                .font(.caption.weight(.semibold))
                            Text(
                                "\(run.purpose.rawValue.capitalized) · "
                                    + "\(run.state.rawValue.capitalized) · "
                                    + store.endpointDisplayName(
                                        id: run.endpointID,
                                        fallback: "Unknown runtime"
                                    )
                            )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(run.createdAt.muRelative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if run.id != taskRuns.last?.id {
                        Divider().padding(.leading, 38)
                    }
                }
            }
        }
    }

    private var checkpointPanel: some View {
        Panel(title: "Checkpoints", subtitle: "Immutable, content-addressed state") {
            if taskCheckpoints.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Text("No Checkpoint yet.")
                        .font(.subheadline.weight(.medium))
                    Text("Capture current Git and Task evidence before proposing a Handoff.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(taskCheckpoints.prefix(3)) { checkpoint in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "seal.fill")
                                .foregroundStyle(MuPalette.mint)
                            Text(String(checkpoint.contentHash.prefix(26)) + "…")
                                .font(.caption.monospaced().weight(.medium))
                            Spacer()
                        }
                        HStack {
                            Text(
                                "\(checkpoint.createdAt.muRelative) · "
                                    + store.endpointDisplayName(
                                        id: checkpoint.sourceEndpointID,
                                        fallback: "Unknown runtime"
                                    )
                            )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Button("Handoff") {
                                store.checkpointForHandoff = checkpoint
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(task.status == .handoffPending)
                        }
                    }
                    if checkpoint.id != taskCheckpoints.prefix(3).last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private var timelinePanel: some View {
        Panel(title: "Task ledger", subtitle: "\(taskEvents.count) canonical events") {
            if taskEvents.isEmpty {
                Text("No events.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(taskEvents.prefix(6)) { event in
                    EventCompactRow(event: event)
                }
            }
        }
    }

    private func labeledList(
        title: String,
        symbol: String,
        color: Color,
        values: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Circle()
                        .fill(color.opacity(0.6))
                        .frame(width: 5, height: 5)
                    Text(value)
                        .font(.subheadline)
                }
            }
        }
    }

    private func repositoryFact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.monospaced().weight(.medium))
        }
    }
}
