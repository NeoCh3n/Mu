import Foundation

struct ProcessCapture {
    var standardOutput: Data
    var standardError: Data
    var terminationStatus: Int32

    static func run(
        executableURL: URL,
        arguments: [String]
    ) throws -> ProcessCapture {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        let output = LockedProcessData()
        let error = LockedProcessData()
        let readers = DispatchGroup()

        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            output.store(outputPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }

        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            error.store(errorPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }

        process.waitUntilExit()
        readers.wait()

        return ProcessCapture(
            standardOutput: output.value,
            standardError: error.value,
            terminationStatus: process.terminationStatus
        )
    }
}

private final class LockedProcessData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var value: Data {
        lock.withLock { storage }
    }

    func store(_ data: Data) {
        lock.withLock {
            storage = data
        }
    }
}
