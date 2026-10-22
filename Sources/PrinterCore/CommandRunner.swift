import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: String
    public let timedOut: Bool
}

/// Bounded subprocess invocation. Arguments are never interpreted by a shell.
public enum CommandRunner {
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 8) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        // A regular temporary file avoids pipe-buffer deadlocks for long output.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: scratch.path, contents: nil,
                                              attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: scratch) }
        let handle = try FileHandle(forWritingTo: scratch)
        defer { try? handle.close() }
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            let grace = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.025) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        let data = try Data(contentsOf: scratch)
        return CommandResult(status: process.terminationStatus,
                             output: String(decoding: data, as: UTF8.self), timedOut: timedOut)
    }
}
