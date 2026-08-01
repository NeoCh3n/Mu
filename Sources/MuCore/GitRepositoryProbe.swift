import Foundation

public final class GitRepositoryProbe {
    private let artifactStore: ArtifactStore

    public init(artifactStore: ArtifactStore) {
        self.artifactStore = artifactStore
    }

    public func baseRevision(path: String) -> String? {
        let value = try? runGit(
            ["rev-parse", "HEAD"],
            at: path
        ).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return value?.isEmpty == false ? value : nil
    }

    public func capture(path: String) throws -> RepositorySnapshot {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MuError.invalidRepository("The selected directory does not exist.")
        }

        let inside = try? runGit(["rev-parse", "--is-inside-work-tree"], at: path)
        guard inside?.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            throw MuError.invalidRepository("Select a directory inside a Git worktree.")
        }

        let branch = (try? runGit(["branch", "--show-current"], at: path))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let head = (try? runGit(["rev-parse", "HEAD"], at: path))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unborn"
        let statusData = try runGitData(["status", "--porcelain=v1", "-z"], at: path)
        let untrackedData = try runGitData(
            ["ls-files", "--others", "--exclude-standard", "-z"],
            at: path
        )

        var patch = Data()
        if head != "unborn" {
            patch.append(try runGitData(["diff", "--binary", "HEAD"], at: path))
        } else {
            patch.append(try runGitData(["diff", "--binary"], at: path))
            patch.append(try runGitData(["diff", "--binary", "--cached"], at: path))
        }

        let patchReference: (uri: String, sha256: String)? = patch.isEmpty
            ? nil
            : try artifactStore.put(patch)
        let untrackedReference: (uri: String, sha256: String)? = untrackedData.isEmpty
            ? nil
            : try artifactStore.put(untrackedData)

        let untrackedFiles = String(decoding: untrackedData, as: UTF8.self)
            .split(separator: "\0")
            .map(String.init)
            .sorted()

        return RepositorySnapshot(
            path: URL(fileURLWithPath: path).standardizedFileURL.path,
            isGitRepository: true,
            branch: branch.isEmpty ? "detached" : branch,
            baseCommit: head,
            headCommit: head,
            isDirty: !statusData.isEmpty,
            trackedPatchURI: patchReference?.uri,
            trackedPatchSHA256: patchReference?.sha256,
            untrackedManifestURI: untrackedReference?.uri,
            untrackedManifestSHA256: untrackedReference?.sha256,
            untrackedFiles: untrackedFiles
        )
    }

    private func runGit(_ arguments: [String], at path: String) throws -> String {
        String(decoding: try runGitData(arguments, at: path), as: UTF8.self)
    }

    private func runGitData(_ arguments: [String], at path: String) throws -> Data {
        do {
            let capture = try ProcessCapture.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-C", path] + arguments
            )
            guard capture.terminationStatus == 0 else {
                let message = String(decoding: capture.standardError, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw MuError.commandFailed(
                    message.isEmpty
                        ? "git exited with \(capture.terminationStatus)"
                        : message
                )
            }
            return capture.standardOutput
        } catch let error as MuError {
            throw error
        } catch {
            throw MuError.commandFailed(error.localizedDescription)
        }
    }
}
