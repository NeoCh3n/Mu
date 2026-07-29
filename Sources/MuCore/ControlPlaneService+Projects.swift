import Foundation

extension ControlPlaneService {
    @discardableResult
    public func renameProject(
        repositoryPath: String,
        displayName: String
    ) throws -> ProjectPreference {
        let canonicalPath = WorkspacePathIdentity.canonicalPath(
            repositoryPath
        )
        let trimmedName = displayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedName.isEmpty else {
            throw MuError.invalidTransition("Project name is required.")
        }
        guard trimmedName.utf8.count <= 240 else {
            throw MuError.invalidTransition(
                "Project name must be 240 bytes or fewer."
            )
        }
        try requireProjectTasks(repositoryPath: canonicalPath)

        let now = Date()
        var preference =
            try projectPreference(repositoryPath: canonicalPath)
            ?? ProjectPreference(
                repositoryPath: canonicalPath,
                createdAt: now,
                updatedAt: now
            )
        let previousName = preference.displayName
        preference.displayName = trimmedName
        preference.isRemoved = false
        preference.updatedAt = now
        try store.withTransaction {
            try store.upsertProjectPreference(preference)
            try store.appendEvent(
                LedgerEvent(
                    type: "project.renamed",
                    summary: "Renamed Project to “\(trimmedName)”.",
                    payload: [
                        "repository_path": canonicalPath,
                        "previous_name": previousName ?? "",
                        "display_name": trimmedName
                    ]
                )
            )
        }
        return preference
    }

    /// Removes a Project from Mu's catalog without deleting its Task records,
    /// repository folder, or external Agent history.
    @discardableResult
    public func removeProject(
        repositoryPath: String
    ) throws -> ProjectPreference {
        let canonicalPath = WorkspacePathIdentity.canonicalPath(
            repositoryPath
        )
        try requireProjectTasks(repositoryPath: canonicalPath)

        let now = Date()
        var preference =
            try projectPreference(repositoryPath: canonicalPath)
            ?? ProjectPreference(
                repositoryPath: canonicalPath,
                createdAt: now,
                updatedAt: now
            )
        preference.isRemoved = true
        preference.updatedAt = now
        try store.withTransaction {
            try store.upsertProjectPreference(preference)
            try store.appendEvent(
                LedgerEvent(
                    type: "project.removed",
                    summary: "Removed a Project from Mu's catalog.",
                    payload: [
                        "repository_path": canonicalPath,
                        "display_name": preference.displayName ?? ""
                    ]
                )
            )
        }
        return preference
    }

    /// Makes an existing Project visible again, preserving any custom name.
    @discardableResult
    public func restoreProject(
        repositoryPath: String
    ) throws -> ProjectPreference? {
        let canonicalPath = WorkspacePathIdentity.canonicalPath(
            repositoryPath
        )
        guard var preference =
            try projectPreference(repositoryPath: canonicalPath),
            preference.isRemoved else {
            return nil
        }
        preference.isRemoved = false
        preference.updatedAt = Date()
        try store.upsertProjectPreference(preference)
        return preference
    }

    private func projectPreference(
        repositoryPath: String
    ) throws -> ProjectPreference? {
        try store.fetchProjectPreferences()
            .filter {
                WorkspacePathIdentity.isExactMatch(
                    $0.repositoryPath,
                    repositoryPath
                )
            }
            .max { $0.updatedAt < $1.updatedAt }
    }

    private func requireProjectTasks(
        repositoryPath: String
    ) throws {
        guard try store.fetchTasks().contains(where: {
            WorkspacePathIdentity.isExactMatch(
                $0.repositoryPath,
                repositoryPath
            )
        }) else {
            throw MuError.recordNotFound(
                "Project \(repositoryPath)"
            )
        }
    }
}
