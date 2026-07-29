import Foundation

/// Mu-owned presentation metadata for a repository-backed Project.
///
/// Renaming or removing a Project changes only Mu's catalog. It never renames
/// or deletes the repository folder or history owned by another Agent.
public struct ProjectPreference: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var repositoryPath: String
    public var displayName: String?
    public var isRemoved: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        repositoryPath: String,
        displayName: String? = nil,
        isRemoved: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.repositoryPath = WorkspacePathIdentity.canonicalPath(
            repositoryPath
        )
        self.displayName = displayName
        self.isRemoved = isRemoved
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A repository-backed project and the tasks that belong to it.
public struct ProjectGroup: Identifiable, Hashable, Sendable {
    /// The canonical repository path is also the stable project identity.
    public let id: String
    public let name: String
    public let repositoryPath: String
    public let tasks: [TaskRecord]
    public let updatedAt: Date

    /// A concise alias for views that treat the repository as a folder row.
    public var path: String {
        repositoryPath
    }

    public var taskCount: Int {
        tasks.count
    }

    /// Tasks that can still make progress, including ready, running, and blocked work.
    public var activeTaskCount: Int {
        tasks.lazy.filter { !$0.status.isTerminal }.count
    }

    public var completedTaskCount: Int {
        taskCount(with: .completed)
    }

    public var closedTaskCount: Int {
        tasks.lazy.filter {
            $0.status == .failed || $0.status == .cancelled
        }.count
    }

    public func taskCount(with status: TaskStatus) -> Int {
        tasks.lazy.filter { $0.status == status }.count
    }

    fileprivate init(
        repositoryPath: String,
        displayName: String?,
        tasks: [TaskRecord]
    ) {
        self.id = repositoryPath
        self.repositoryPath = repositoryPath

        let folderName = URL(
            fileURLWithPath: repositoryPath,
            isDirectory: true
        ).lastPathComponent
        let defaultName = folderName.isEmpty ? repositoryPath : folderName
        let trimmedDisplayName = displayName?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        self.name = trimmedDisplayName?.isEmpty == false
            ? trimmedDisplayName!
            : defaultName
        self.tasks = tasks
        self.updatedAt = tasks.map(\.updatedAt).max() ?? .distantPast
    }
}

/// Builds the Projects sidebar model from persisted task records.
public enum ProjectCatalog {
    public typealias Project = ProjectGroup

    public static func groups(
        from tasks: [TaskRecord],
        preferences: [ProjectPreference] = []
    ) -> [ProjectGroup] {
        let preferencesByRepository = preferences
            .sorted { $0.updatedAt < $1.updatedAt }
            .reduce(into: [String: ProjectPreference]()) {
                $0[
                    WorkspacePathIdentity.canonicalPath(
                        $1.repositoryPath
                    )
                ] = $1
            }
        let tasksByRepository = Dictionary(grouping: tasks) {
            WorkspacePathIdentity.canonicalPath($0.repositoryPath)
        }

        return tasksByRepository.compactMap {
            repositoryPath,
            repositoryTasks in
            let preference = preferencesByRepository[repositoryPath]
            guard preference?.isRemoved != true else { return nil }
            return ProjectGroup(
                repositoryPath: repositoryPath,
                displayName: preference?.displayName,
                tasks: repositoryTasks.sorted(by: taskComesBefore)
            )
        }
        .sorted(by: projectComesBefore)
    }

    public static func projects(
        from tasks: [TaskRecord],
        preferences: [ProjectPreference] = []
    ) -> [Project] {
        groups(from: tasks, preferences: preferences)
    }

    private static func taskComesBefore(
        _ lhs: TaskRecord,
        _ rhs: TaskRecord
    ) -> Bool {
        if lhs.status.isTerminal != rhs.status.isTerminal {
            return !lhs.status.isTerminal
        }
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        if lhs.title != rhs.title {
            return lhs.title < rhs.title
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func projectComesBefore(
        _ lhs: ProjectGroup,
        _ rhs: ProjectGroup
    ) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        if lhs.name != rhs.name {
            return lhs.name < rhs.name
        }
        return lhs.repositoryPath < rhs.repositoryPath
    }
}
