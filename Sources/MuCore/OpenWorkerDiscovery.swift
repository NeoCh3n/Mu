import Foundation

/// A read-only description of a locally installed OpenWorker desktop app.
public struct OpenWorkerDiscoveryResult: Hashable, Sendable {
    public let appURL: URL
    public let version: String
    public let bundleID: String
    public let executableURL: URL

    public init(
        appURL: URL,
        version: String,
        bundleID: String,
        executableURL: URL
    ) {
        self.appURL = appURL
        self.version = version
        self.bundleID = bundleID
        self.executableURL = executableURL
    }
}

/// Discovers OpenWorker from its macOS application bundle without starting it
/// or attempting to access its private sidecar credentials.
public enum OpenWorkerDiscovery {
    public static let defaultAppURL = URL(
        fileURLWithPath: "/Applications/OpenWorker.app",
        isDirectory: true
    )

    public static func discover(
        at appURL: URL = defaultAppURL,
        fileManager: FileManager = .default
    ) -> OpenWorkerDiscoveryResult? {
        let normalizedAppURL = appURL.standardizedFileURL
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(
            atPath: normalizedAppURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return nil
        }

        let infoPlistURL = normalizedAppURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)

        guard
            let data = try? Data(contentsOf: infoPlistURL, options: .mappedIfSafe),
            let propertyList = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ),
            let info = propertyList as? [String: Any],
            let version = nonemptyString(
                info["CFBundleShortVersionString"]
            ),
            let bundleID = nonemptyString(info["CFBundleIdentifier"]),
            let executableName = safeExecutableName(
                info["CFBundleExecutable"]
            )
        else {
            return nil
        }

        let executableURL = normalizedAppURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(executableName, isDirectory: false)
            .standardizedFileURL

        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            return nil
        }

        return OpenWorkerDiscoveryResult(
            appURL: normalizedAppURL,
            version: version,
            bundleID: bundleID,
            executableURL: executableURL
        )
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private static func safeExecutableName(_ value: Any?) -> String? {
        guard let name = nonemptyString(value),
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\\"),
              URL(fileURLWithPath: name).lastPathComponent == name
        else {
            return nil
        }

        return name
    }
}
