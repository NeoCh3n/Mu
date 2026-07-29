import CryptoKit
import Foundation

public extension Data {
    var muSHA256: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}

public final class ArtifactStore {
    public let rootURL: URL

    public init(rootURL: URL) throws {
        self.rootURL = rootURL
        try FileManager.default.createDirectory(
            at: rootURL.appending(path: "sha256", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
    }

    @discardableResult
    public func put(_ data: Data) throws -> (uri: String, sha256: String) {
        let hash = data.muSHA256
        let url = artifactURL(for: hash)

        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try Data(contentsOf: url)
            guard existing.muSHA256 == hash else {
                throw MuError.artifactWriteFailed("Existing CAS object does not match its path.")
            }
        } else {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                throw MuError.artifactWriteFailed(error.localizedDescription)
            }
        }

        return ("local-cas://sha256/\(hash)", hash)
    }

    public func artifactURL(for hash: String) -> URL {
        rootURL
            .appending(path: "sha256", directoryHint: .isDirectory)
            .appending(path: hash)
    }

    public func verify(uri: String, expectedSHA256: String) -> Bool {
        guard uri == "local-cas://sha256/\(expectedSHA256)" else { return false }
        guard let data = try? Data(contentsOf: artifactURL(for: expectedSHA256)) else {
            return false
        }
        return data.muSHA256 == expectedSHA256
    }
}

public enum CheckpointHasher {
    public static func hash(_ content: CheckpointContent) throws -> String {
        let data = try MuCoding.makeEncoder().encode(content)
        return "sha256:\(data.muSHA256)"
    }
}
