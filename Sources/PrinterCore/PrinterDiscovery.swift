import Foundation
import Combine

public struct NetworkPrinter: Identifiable, Sendable {
    public var id: String { host.lowercased() }
    public let name: String
    public let host: String
    public let port: Int
    public let model: String
}

@MainActor public final class PrinterDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published public private(set) var printers: [NetworkPrinter] = []
    @Published public private(set) var error: String?
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    public override init() { super.init(); browser.delegate = self }
    public func start() {
        browser.stop()
        services.forEach { $0.stop() }
        services = []; printers = []; error = nil
        browser.searchForServices(ofType: "_pdl-datastream._tcp.", inDomain: "local.")
    }
    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        services.append(service)
        service.resolve(withTimeout: 5)
    }
    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        if let host = service.hostName { printers.removeAll { $0.host == host } }
        services.removeAll { $0 == service }
    }
    public func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName, sender.port == 9100, let data = sender.txtRecordData() else { return }
        let record = NetService.dictionary(fromTXTRecord: data)
        let model = record["usb_MDL"].flatMap { String(data: $0, encoding: .utf8) }
        let manufacturer = record["usb_MFG"].flatMap { String(data: $0, encoding: .utf8) }
        guard let model, PrinterProfiles.match(model) != nil, manufacturer?.uppercased() == "EPSON" else { return }
        let printer = NetworkPrinter(name: sender.name, host: host, port: sender.port, model: model)
        printers.removeAll { $0.id == printer.id }
        printers.append(printer)
        printers.sort { $0.name < $1.name }
    }
    public func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        error = L("Network discovery is unavailable. Check Local Network permission in System Settings.")
    }
}

public enum WirelessQueue {
    public static func install(host: String, model: String = "Epson Stylus Photo 1500") throws -> String {
        guard let profile = PrinterProfiles.match(model) else { throw ConfigurationError.unsupportedModel }
        guard host.range(of: #"^[A-Za-z0-9-]+\.local\.?$"#, options: .regularExpression) != nil else { throw ConfigurationError.invalidReply }
        let device = String(host.split(separator: ".")[0]).uppercased()
        let suffix = device.hasPrefix("EPSON") ? String(device.dropFirst(5)) : device
        let name = profile.id == "photo-1500" ? "Epson_Photo_1500_" + suffix : "Epson_" + profile.id.replacingOccurrences(of: "-", with: "_") + "_" + suffix
        let uri = "socket://\(host):9100"
        let existing = try CommandRunner.run("/usr/bin/lpstat", ["-v"])
        if let queue = PrinterQueue.parse(existing.output).first(where: { $0.id == name }) {
            guard queue.uri == uri else { throw NSError(domain: "PrinterQueue", code: 1, userInfo: [NSLocalizedDescriptionKey: L("An existing queue uses this name with a different address. No queue was changed.")]) }
            return name
        }
        guard FileManager.default.fileExists(atPath: profile.ppdPath) else { throw NSError(domain: "PrinterQueue", code: 2, userInfo: [NSLocalizedDescriptionKey: L("Install the Epson printer driver first.")]) }
        let result = try CommandRunner.run("/usr/sbin/lpadmin", ["-p", name, "-E", "-v", uri,
            "-P", profile.ppdPath,
            "-D", profile.name + " Wi-Fi", "-o", "printer-is-shared=false"])
        guard result.status == 0, !result.timedOut else { throw NSError(domain: "PrinterQueue", code: 3, userInfo: [NSLocalizedDescriptionKey: L("macOS could not add the printer. Administrator access may be required.")]) }
        let check = try CommandRunner.run("/usr/bin/lpstat", ["-v", name])
        guard PrinterQueue.parse(check.output).contains(where: { $0.id == name && $0.uri == uri }) else { throw ConfigurationError.invalidReply }
        return name
    }
}
