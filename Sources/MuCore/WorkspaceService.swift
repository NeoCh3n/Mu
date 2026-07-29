import Foundation

public struct WorkspaceFile: Identifiable, Hashable, Sendable {
    public var id: String { relativePath }
    public var relativePath: String
    public var name: String
    public var isDirectory: Bool
    public var depth: Int
    public var size: Int64?

    public init(
        relativePath: String,
        name: String,
        isDirectory: Bool,
        depth: Int,
        size: Int64? = nil
    ) {
        self.relativePath = relativePath
        self.name = name
        self.isDirectory = isDirectory
        self.depth = depth
        self.size = size
    }
}

public enum TerminalPreset: String, CaseIterable, Identifiable, Sendable {
    case status
    case diffStat
    case recentCommits
    case directory

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .status: "git status"
        case .diffStat: "git diff --stat"
        case .recentCommits: "git log -8"
        case .directory: "ls -la"
        }
    }
}

public struct TerminalResult: Hashable, Sendable {
    public var command: String
    public var output: String
    public var exitCode: Int32

    public init(command: String, output: String, exitCode: Int32) {
        self.command = command
        self.output = output
        self.exitCode = exitCode
    }
}

public final class WorkspaceService: @unchecked Sendable {
    private let fileManager = FileManager.default
    private let skippedDirectories: Set<String> = [
        ".git", ".build", "build", "DerivedData", "node_modules", ".pnpm-store"
    ]

    public init() {}

    public func files(
        at rootPath: String,
        maximumDepth: Int = 4,
        maximumItems: Int = 500
    ) throws -> [WorkspaceFile] {
        guard maximumDepth >= 0, maximumItems > 0 else { return [] }

        let root = URL(fileURLWithPath: rootPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MuError.invalidRepository("Workspace directory does not exist.")
        }

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .isHiddenKey
        ]
        var result: [WorkspaceFile] = []
        func visit(
            directory: URL,
            relativePrefix: String,
            depth: Int
        ) throws {
            guard result.count < maximumItems else { return }
            let children = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants]
            )
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }

            for child in children {
                guard result.count < maximumItems else { return }
                let name = child.lastPathComponent
                let values = try child.resourceValues(forKeys: keys)
                let isSymbolicLink = values.isSymbolicLink == true
                let childIsDirectory = values.isDirectory == true && !isSymbolicLink

                if childIsDirectory && skippedDirectories.contains(name) {
                    continue
                }
                if values.isHidden == true && name != ".gitignore" {
                    continue
                }

                let relativePath = relativePrefix.isEmpty
                    ? name
                    : "\(relativePrefix)/\(name)"
                result.append(
                    WorkspaceFile(
                        relativePath: relativePath,
                        name: name,
                        isDirectory: childIsDirectory,
                        depth: depth,
                        size: values.fileSize.map(Int64.init)
                    )
                )

                if childIsDirectory && depth < maximumDepth {
                    try visit(
                        directory: child,
                        relativePrefix: relativePath,
                        depth: depth + 1
                    )
                }
            }
        }

        try visit(directory: root, relativePrefix: "", depth: 0)
        return result
    }

    public func readTextFile(
        rootPath: String,
        relativePath: String,
        maximumBytes: Int = 512_000
    ) throws -> String {
        let root = URL(fileURLWithPath: rootPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let file = root
            .appending(path: relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/") else {
            throw MuError.invalidTransition("File is outside the selected workspace.")
        }
        let data = try Data(contentsOf: file, options: [.mappedIfSafe])
        guard data.count <= maximumBytes else {
            throw MuError.invalidTransition("File is larger than the \(maximumBytes / 1_000) KB preview limit.")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw MuError.invalidTransition("Binary files are not rendered in the text preview.")
        }
        return text
    }

    public func run(_ preset: TerminalPreset, at rootPath: String) throws -> TerminalResult {
        let executable: String
        let arguments: [String]
        switch preset {
        case .status:
            executable = "/usr/bin/git"
            arguments = ["-C", rootPath, "status", "--short", "--branch"]
        case .diffStat:
            executable = "/usr/bin/git"
            arguments = ["-C", rootPath, "diff", "--stat"]
        case .recentCommits:
            executable = "/usr/bin/git"
            arguments = ["-C", rootPath, "log", "--oneline", "--decorate", "-8"]
        case .directory:
            executable = "/bin/ls"
            arguments = ["-la", rootPath]
        }

        let capture = try ProcessCapture.run(
            executableURL: URL(fileURLWithPath: executable),
            arguments: arguments
        )
        let combined = String(
            decoding: capture.standardOutput + capture.standardError,
            as: UTF8.self
        )
        return TerminalResult(
            command: preset.title,
            output: combined.isEmpty ? "(no output)" : combined,
            exitCode: capture.terminationStatus
        )
    }
}
