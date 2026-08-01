import Foundation
@testable import MuCore
import Testing

@Suite
struct ProjectCatalogTests {
    @Test
    func tasksInTheSameCanonicalRepositoryBecomeOneProject() throws {
        let older = task(
            id: "11111111-1111-1111-1111-111111111111",
            title: "Older task",
            repositoryPath: "/tmp/mu-project-catalog/AgentCenter",
            updatedAt: 100
        )
        let newer = task(
            id: "22222222-2222-2222-2222-222222222222",
            title: "Newer task",
            repositoryPath: "/tmp/mu-project-catalog/AgentCenter/./",
            updatedAt: 200
        )

        let groups = ProjectCatalog.groups(from: [older, newer])
        let project = try #require(groups.first)

        #expect(groups.count == 1)
        #expect(
            project.id == ProjectRecord.stableID(
                repositoryPath: "/tmp/mu-project-catalog/AgentCenter"
            )
        )
        #expect(project.name == "AgentCenter")
        #expect(project.repositoryPath == "/tmp/mu-project-catalog/AgentCenter")
        #expect(project.tasks.map(\.id) == [newer.id, older.id])
        #expect(project.updatedAt == newer.updatedAt)
    }

    @Test
    func tasksInDifferentRepositoriesRemainSeparateProjects() {
        let alpha = task(
            id: "33333333-3333-3333-3333-333333333333",
            title: "Alpha task",
            repositoryPath: "/tmp/mu-project-catalog/Alpha",
            updatedAt: 100
        )
        let beta = task(
            id: "44444444-4444-4444-4444-444444444444",
            title: "Beta task",
            repositoryPath: "/tmp/mu-project-catalog/Beta",
            updatedAt: 200
        )

        let groups = ProjectCatalog.groups(from: [alpha, beta])

        #expect(groups.count == 2)
        #expect(Set(groups.map(\.repositoryPath)) == [
            "/tmp/mu-project-catalog/Alpha",
            "/tmp/mu-project-catalog/Beta"
        ])
    }

    @Test
    func projectsAndTasksSortByMostRecentUpdate() throws {
        let alphaNewest = task(
            id: "55555555-5555-5555-5555-555555555555",
            title: "Alpha newest",
            repositoryPath: "/tmp/mu-project-catalog/Alpha",
            updatedAt: 400
        )
        let alphaOldest = task(
            id: "66666666-6666-6666-6666-666666666666",
            title: "Alpha oldest",
            repositoryPath: "/tmp/mu-project-catalog/Alpha",
            updatedAt: 100
        )
        let beta = task(
            id: "77777777-7777-7777-7777-777777777777",
            title: "Beta",
            repositoryPath: "/tmp/mu-project-catalog/Beta",
            updatedAt: 300
        )

        let groups = ProjectCatalog.groups(
            from: [alphaOldest, beta, alphaNewest]
        )

        #expect(groups.map(\.name) == ["Alpha", "Beta"])
        let alpha = try #require(groups.first)
        #expect(alpha.tasks.map(\.title) == ["Alpha newest", "Alpha oldest"])
        #expect(alpha.updatedAt == Date(timeIntervalSince1970: 400))
    }

    @Test
    func activeTasksComeBeforeTerminalTasksAndEachSectionIsRecentFirst()
        throws
    {
        let path = "/tmp/mu-project-catalog/ActiveFirst"
        let completedNewest = task(
            id: "81818181-8181-8181-8181-818181818181",
            title: "Completed newest",
            repositoryPath: path,
            status: .completed,
            updatedAt: 500
        )
        let runningNewer = task(
            id: "82828282-8282-8282-8282-828282828282",
            title: "Running newer",
            repositoryPath: path,
            status: .running,
            updatedAt: 300
        )
        let readyOlder = task(
            id: "83838383-8383-8383-8383-838383838383",
            title: "Ready older",
            repositoryPath: path,
            status: .ready,
            updatedAt: 100
        )
        let failedOlder = task(
            id: "84848484-8484-8484-8484-848484848484",
            title: "Failed older",
            repositoryPath: path,
            status: .failed,
            updatedAt: 200
        )

        let project = try #require(
            ProjectCatalog.groups(
                from: [failedOlder, readyOlder, completedNewest, runningNewer]
            ).first
        )

        #expect(
            project.tasks.map(\.title) == [
                "Running newer",
                "Ready older",
                "Completed newest",
                "Failed older"
            ]
        )
        #expect(project.updatedAt == completedNewest.updatedAt)
    }

    @Test
    func projectExposesActiveCompletedClosedAndPerStatusCounts() throws {
        let path = "/tmp/mu-project-catalog/StatusCounts"
        let tasks = [
            task(
                id: "88888888-8888-8888-8888-888888888888",
                title: "Ready",
                repositoryPath: path,
                status: .ready,
                updatedAt: 100
            ),
            task(
                id: "99999999-9999-9999-9999-999999999999",
                title: "Running",
                repositoryPath: path,
                status: .running,
                updatedAt: 200
            ),
            task(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                title: "Blocked",
                repositoryPath: path,
                status: .blocked,
                updatedAt: 300
            ),
            task(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                title: "Completed",
                repositoryPath: path,
                status: .completed,
                updatedAt: 400
            ),
            task(
                id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
                title: "Failed",
                repositoryPath: path,
                status: .failed,
                updatedAt: 500
            ),
            task(
                id: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
                title: "Cancelled",
                repositoryPath: path,
                status: .cancelled,
                updatedAt: 600
            )
        ]

        let project = try #require(
            ProjectCatalog.groups(from: tasks).first
        )

        #expect(project.taskCount == 6)
        #expect(project.activeTaskCount == 3)
        #expect(project.completedTaskCount == 1)
        #expect(project.closedTaskCount == 2)
        #expect(project.taskCount(with: .running) == 1)
        #expect(project.taskCount(with: .draft) == 0)
    }

    @Test
    func equalDatesHaveDeterministicOrdering() throws {
        let path = "/tmp/mu-project-catalog/StableOrder"
        let laterCreated = task(
            id: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE",
            title: "Later created",
            repositoryPath: path,
            createdAt: 200,
            updatedAt: 300
        )
        let earlierCreated = task(
            id: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF",
            title: "Earlier created",
            repositoryPath: path,
            createdAt: 100,
            updatedAt: 300
        )

        let forward = try #require(
            ProjectCatalog.groups(from: [earlierCreated, laterCreated]).first
        )
        let reversed = try #require(
            ProjectCatalog.groups(from: [laterCreated, earlierCreated]).first
        )

        #expect(forward.tasks.map(\.id) == [laterCreated.id, earlierCreated.id])
        #expect(reversed.tasks.map(\.id) == forward.tasks.map(\.id))
    }

    @Test
    func projectPreferencesRenameAndRemoveOnlyTheCatalogEntry() throws {
        let path = "/tmp/mu-project-catalog/Preferences"
        let record = task(
            id: "ABABABAB-ABAB-ABAB-ABAB-ABABABABABAB",
            title: "Visible task",
            repositoryPath: path,
            updatedAt: 100
        )
        let renamed = ProjectPreference(
            repositoryPath: path,
            displayName: "Research workspace",
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        let visible = try #require(
            ProjectCatalog.groups(
                from: [record],
                preferences: [renamed]
            ).first
        )
        #expect(visible.name == "Research workspace")
        #expect(visible.repositoryPath == path)
        #expect(visible.tasks == [record])

        var removed = renamed
        removed.isRemoved = true
        removed.updatedAt = Date(timeIntervalSince1970: 300)
        #expect(
            ProjectCatalog.groups(
                from: [record],
                preferences: [renamed, removed]
            ).isEmpty
        )
    }

    @Test
    func projectRenameAndRemovePersistWithoutDeletingTaskOrFolder()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appending(
                path: "mu-project-actions-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        let workspace = root.appending(
            path: "Workspace",
            directoryHint: .isDirectory
        )
        let dataDirectory = root.appending(
            path: "Data",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let service = try ControlPlaneService(
            dataDirectory: dataDirectory
        )
        let created = try service.createTask(
            title: "Catalog task",
            objective: "Verify project catalog actions.",
            successCriteria: [],
            constraints: [],
            pendingSteps: [],
            repositoryPath: workspace.path,
            sourceEndpointID:
                ControlPlaneService.syntheticEndpointAID
        )

        _ = try service.renameProject(
            repositoryPath: workspace.path,
            displayName: "Renamed in Mu"
        )
        var preferences = try service.store.fetchProjectPreferences()
        var groups = ProjectCatalog.groups(
            from: try service.store.fetchTasks(),
            preferences: preferences
        )
        #expect(groups.first?.name == "Renamed in Mu")

        _ = try service.removeProject(
            repositoryPath: workspace.path
        )
        preferences = try service.store.fetchProjectPreferences()
        groups = ProjectCatalog.groups(
            from: try service.store.fetchTasks(),
            preferences: preferences
        )
        #expect(groups.isEmpty)
        #expect(try service.store.fetchTask(id: created.id) != nil)
        #expect(
            FileManager.default.fileExists(
                atPath: workspace.path
            )
        )

        let restarted = try ControlPlaneService(
            dataDirectory: dataDirectory
        )
        #expect(
            ProjectCatalog.groups(
                from: try restarted.store.fetchTasks(),
                preferences:
                    try restarted.store.fetchProjectPreferences()
            ).isEmpty
        )
        _ = try restarted.restoreProject(
            repositoryPath: workspace.path
        )
        #expect(
            ProjectCatalog.groups(
                from: try restarted.store.fetchTasks(),
                preferences:
                    try restarted.store.fetchProjectPreferences()
            ).first?.name == "Renamed in Mu"
        )
    }

    private func task(
        id: String,
        title: String,
        repositoryPath: String,
        status: TaskStatus = .ready,
        createdAt: TimeInterval = 0,
        updatedAt: TimeInterval
    ) -> TaskRecord {
        TaskRecord(
            id: UUID(uuidString: id)!,
            title: title,
            objective: "Test project grouping.",
            successCriteria: [],
            constraints: [],
            pendingSteps: [],
            repositoryPath: repositoryPath,
            status: status,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }
}
