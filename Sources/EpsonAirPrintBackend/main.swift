import Foundation
import PrinterCore

// Called only by the system IPP server. A job is passed literally to the chosen
// local Epson queue; no shell, shared CUPS administration or cloud is involved.
do {
    let environment = ProcessInfo.processInfo.environment
    guard CommandLine.arguments.count == 2,
          let queue = environment["ELC_QUEUE_NAME"], PrinterCare.validQueue(queue),
          let rootPath = environment["ELC_SPOOL_ROOT"] else { throw ConfigurationError.invalidReply }
    let file = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
    let root = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath()
    guard file.deletingLastPathComponent() == root else { throw ConfigurationError.invalidReply }
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
          let size = attributes[.size] as? NSNumber, size.int64Value > 0, size.int64Value <= 512 * 1024 * 1024 else { throw ConfigurationError.invalidReply }
    let ppd = String(decoding: try Data(contentsOf: URL(fileURLWithPath: "/etc/cups/ppd/\(queue).ppd")), as: UTF8.self)
    guard ppd.contains("*ModelName: \"EPSON Epson Stylus Photo 1500\"") else { throw ConfigurationError.unsupportedModel }
    let args = try AirPrintJob.arguments(queue: queue, file: file.path, environment: environment)
    let result = try CommandRunner.run("/usr/bin/lp", args, timeout: 30)
    guard result.status == 0, !result.timedOut, PrinterCare.jobNumber(in: result.output, queue: queue) != nil else {
        throw ComponentFiles.failure("The local Epson queue did not confirm this AirPrint job. Check the queue before retrying.")
    }
    FileHandle.standardError.write(Data("INFO: Accepted by the local Epson queue.\n".utf8))
    exit(0)
} catch {
    FileHandle.standardError.write(Data(("ERROR: " + error.localizedDescription + "\n").utf8))
    exit(1)
}
