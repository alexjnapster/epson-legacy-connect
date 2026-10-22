import Foundation
import IOKit

public struct DriverStatus: Codable, Sendable {
    public let installed: Bool
    public let version: String?
    public let filterAvailable: Bool
    public var ready: Bool { installed && filterAvailable }
}

public struct PrinterSnapshot: Codable, Sendable {
    public let capturedAt: Date
    public let systemVersion: String
    public let usbPresent: Bool
    public let queues: [PrinterQueue]
    public let driver: DriverStatus
    public let status: String
    public let inks: [InkLevel]
    public let warnings: [String]
}

public enum PrinterDiagnostics {
    public static func usbPresent() -> Bool {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return false }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }
        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            let vendor = IORegistryEntryCreateCFProperty(device, "idVendor" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
            let product = IORegistryEntryCreateCFProperty(device, "idProduct" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
            if vendor?.intValue == 0x04b8 && product?.intValue == 0x0030 { return true }
        }
        return false
    }

    public static func driverStatus() -> DriverStatus {
        let file = "/Library/Printers/PPDs/Contents/Resources/EPSON Epson Stylus Photo 1500.gz"
        let filter = "/Library/Printers/EPSON/InkjetPrinter2/Filter/rastertoescpII.app/Contents/MacOS/rastertoescpII"
        let installed = FileManager.default.fileExists(atPath: file)
        let result = installed ? try? CommandRunner.run("/usr/bin/gzip", ["-cd", file]) : nil
        let version = result?.output.split(separator: "\n").first { $0.hasPrefix("*FileVersion:") }
            .map { String($0).replacingOccurrences(of: "*FileVersion:", with: "").trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
        return DriverStatus(installed: installed, version: version,
                            filterAvailable: FileManager.default.isExecutableFile(atPath: filter))
    }

    public static func capture() -> PrinterSnapshot {
        var warnings = [String]()
        let queuesResult = try? CommandRunner.run("/usr/bin/lpstat", ["-v"])
        let queues = PrinterQueue.parse(queuesResult?.output ?? "").filter {
            $0.id.localizedCaseInsensitiveContains("Epson_Stylus_Photo_1500") ||
            $0.id.hasPrefix("Epson_Photo_1500_") ||
            $0.uri.localizedCaseInsensitiveContains("Stylus%20Photo%201500")
        }
        if queuesResult == nil || queuesResult?.status != 0 { warnings.append("Could not read macOS printer queues.") }
        let driver = driverStatus()
        var status = "No printer queue found"
        var inks: [InkLevel] = []
        if let queue = queues.first(where: { $0.isNetwork }) ?? queues.first {
            let result = try? CommandRunner.run("/usr/bin/lpstat", ["-p", queue.id])
            status = result?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Printer status unavailable"
            let attributes = try? CommandRunner.run("/usr/bin/ipptool", ["-tv", "ipp://localhost/printers/\(queue.id)", "/usr/share/cups/ipptool/get-printer-attributes.test"])
            if let attributes, attributes.status == 0, !attributes.timedOut {
                func attribute(_ name: String) -> String? {
                    guard let line = attributes.output.split(separator: "\n").first(where: {
                        $0.trimmingCharacters(in: .whitespaces).hasPrefix(name + " (")
                    }), let range = line.range(of: " = ") else { return nil }
                    return String(line[range.upperBound...])
                }
                inks = InkLevel.parse(names: attribute("marker-names"), levels: attribute("marker-levels"))
            } else { warnings.append("Ink readings are unavailable. Stored queue status is not proof the printer is reachable.") }
        }
        if queues.count > 1 { warnings.append("Multiple queues refer to this model. No queue has been removed or changed.") }
        return PrinterSnapshot(capturedAt: Date(), systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                               usbPresent: usbPresent(), queues: queues, driver: driver,
                               status: status, inks: inks, warnings: warnings)
    }
}
