import Foundation

public struct PrintJob: Identifiable, Equatable, Sendable {
    public let id: Int
    public let queue: String
    public let owner: String
    public let bytes: Int
    public let submitted: String
    public var mayCancel: Bool { owner == NSUserName() }
    public static func parse(_ output: String, queue: String) -> [PrintJob] {
        guard PrinterCare.validQueue(queue) else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(maxSplits: 3, whereSeparator: { $0.isWhitespace }).map(String.init)
            guard parts.count == 4, parts[0].hasPrefix(queue + "-"),
                  parts[0].dropFirst(queue.count + 1).allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(parts[0].dropFirst(queue.count + 1)), number > 0,
                  let size = Int(parts[2]), size >= 0 else { return nil }
            return PrintJob(id: number, queue: queue, owner: parts[1], bytes: size, submitted: parts[3])
        }
    }
}

public enum PrintJobs {
    public static func pending(queue: String) throws -> [PrintJob] {
        guard PrinterCare.validQueue(queue) else { throw ConfigurationError.invalidReply }
        let result = try CommandRunner.run("/usr/bin/lpstat", ["-W", "not-completed", "-o", queue])
        guard result.status == 0, !result.timedOut else { throw ComponentFiles.failure("Could not read print jobs. Check that the printer is added to this Mac.") }
        return PrintJob.parse(result.output, queue: queue)
    }
    public static func cancel(_ job: PrintJob) throws {
        // Re-read the live queue so a stale or fabricated ID cannot cancel another queue's job.
        guard let current = try pending(queue: job.queue).first(where: { $0.id == job.id }), current.mayCancel else {
            throw ComponentFiles.failure("This job is no longer pending or belongs to another user. No job was cancelled.")
        }
        let result = try CommandRunner.run("/usr/bin/cancel", ["\(current.queue)-\(current.id)"])
        guard result.status == 0, !result.timedOut else { throw ComponentFiles.failure("macOS did not confirm cancellation. Refresh the queue before trying again.") }
        guard try !pending(queue: job.queue).contains(where: { $0.id == job.id }) else {
            throw ComponentFiles.failure("Cancellation is still pending. A page already sent to the printer may finish printing.")
        }
    }
}
