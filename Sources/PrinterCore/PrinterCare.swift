import Foundation

public enum CareAction: String, CaseIterable, Identifiable, Sendable {
    case nozzleCheck = "PrintSelfTestPage", cleanHeads = "Clean", inkLevels = "ReportLevels"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .nozzleCheck: return L("Print nozzle check")
        case .cleanHeads: return L("Clean print heads")
        case .inkLevels: return L("Request ink levels")
        }
    }
    public var instructions: String {
        switch self {
        case .nozzleCheck: return L("Load a sheet of A4 or Letter plain paper. Check the printed pattern for gaps before deciding whether cleaning is needed.")
        case .cleanHeads: return L("Cleaning uses ink from all cartridges. Run it only if the nozzle pattern has gaps. Leave the printer on until it finishes.")
        case .inkLevels: return L("Ask the Epson driver to refresh ink readings. Some network connections may still return cached or unavailable levels.")
        }
    }
    public var commandFile: Data { Data(("#CUPS-COMMAND\n" + rawValue + (self == .cleanHeads ? " all" : "") + "\n").utf8) }
}

public enum CareJobState: String, Sendable {
    case pending, held = "pending-held", processing, stopped = "processing-stopped", canceled, aborted, completed
    public var terminal: Bool { [.canceled, .aborted, .completed].contains(self) }
}

/// Only local CUPS queues with an Epson driver can receive these commands.
/// A timeout never retries a command: the printer may already be performing it.
public enum PrinterCare {
    public static func validQueue(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,126}$"#, options: .regularExpression) != nil
    }
    public static func attribute(_ name: String, in output: String) -> String? {
        guard let line = output.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(name + " (") }),
              let range = line.range(of: " = ") else { return nil }
        return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }
    public static func supportedActions(in attributes: String) -> [CareAction] {
        guard attribute("printer-make-and-model", in: attributes)?.uppercased().hasPrefix("EPSON ") == true,
              attribute("document-format-supported", in: attributes)?.components(separatedBy: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).contains("application/vnd.cups-command") == true,
              let commands = attribute("printer-commands", in: attributes) else { return [] }
        let names = Set(commands.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        return CareAction.allCases.filter { names.contains($0.rawValue.lowercased()) }
    }
    public static func capabilities(queue: String) throws -> [CareAction] {
        supportedActions(in: try queueAttributes(queue: queue))
    }
    private static func queueAttributes(queue: String) throws -> String {
        guard validQueue(queue) else { throw ConfigurationError.invalidReply }
        // libcups also wakes the on-demand macOS scheduler before ipptool's TCP query.
        let local = try CommandRunner.run("/usr/bin/lpstat", ["-v", queue])
        guard local.status == 0, PrinterQueue.parse(local.output).contains(where: { $0.id == queue }) else { throw ConfigurationError.invalidReply }
        let result = try CommandRunner.run("/usr/bin/ipptool", ["-tv", "ipp://127.0.0.1/printers/\(queue)", "/usr/share/cups/ipptool/get-printer-attributes.test"])
        guard result.status == 0, !result.timedOut else { throw ComponentFiles.failure("Could not read printer maintenance capabilities. Check the local print queue.") }
        return result.output
    }
    public static func jobNumber(in output: String, queue: String) -> Int? {
        guard validQueue(queue), let line = output.split(separator: "\n").first,
              line.hasPrefix("request id is \(queue)-"),
              let token = line.split(separator: " ").dropFirst(3).first else { return nil }
        let number = token.dropFirst(queue.count + 1)
        guard !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(number), value > 0 else { return nil }
        return value
    }
    public static func submit(_ action: CareAction, queue: String) throws -> Int {
        let attributes = try queueAttributes(queue: queue)
        guard supportedActions(in: attributes).contains(action) else { throw ComponentFiles.failure("This printer driver does not advertise that maintenance command.") }
        guard attribute("printer-state", in: attributes) == "idle",
              attribute("printer-is-accepting-jobs", in: attributes) == "true" else {
            throw ComponentFiles.failure("The print queue is busy or paused. Finish existing jobs before starting maintenance.")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".command")
        guard FileManager.default.createFile(atPath: file.path, contents: action.commandFile, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try CommandRunner.run("/usr/bin/lp", ["-d", queue, "-t", "Epson Legacy Connect: " + action.rawValue, "-o", "document-format=application/vnd.cups-command", file.path])
        guard result.status == 0, !result.timedOut, let number = jobNumber(in: result.output, queue: queue) else {
            throw ComponentFiles.failure("The maintenance request was not confirmed. Check the print queue before trying again; do not repeat cleaning automatically.")
        }
        return number
    }
    public static func jobState(_ number: Int) throws -> CareJobState {
        guard number > 0 else { throw ConfigurationError.invalidReply }
        let result = try CommandRunner.run("/usr/bin/ipptool", ["-tv", "ipp://127.0.0.1/jobs/\(number)", "/usr/share/cups/ipptool/get-job-attributes.test"])
        guard result.status == 0, !result.timedOut,
              let value = attribute("job-state", in: result.output), let state = CareJobState(rawValue: value) else { throw ConfigurationError.invalidReply }
        return state
    }
}
