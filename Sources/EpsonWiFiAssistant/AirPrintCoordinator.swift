import Foundation
import AppKit
import Network
import SystemConfiguration
import CryptoKit
import PrinterCore

private struct BridgeHeartbeat: Codable, Sendable {
    let version: Int
    let id: UUID
    let printer: String
    let ready: Bool
    let hosting: Bool
}

private struct HomeInterface {
    let address: String
    let mask: String
    let signature: String
    static func current() -> HomeInterface? {
        guard let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let name = global["PrimaryInterface"] as? String, name.hasPrefix("en"),
              let service = global["PrimaryService"] as? String,
              let serviceState = SCDynamicStoreCopyValue(nil, "State:/Network/Service/\(service)/IPv4" as CFString) as? [String: Any],
              let networkSignature = serviceState["NetworkSignature"] as? String, !networkSignature.isEmpty,
              let state = SCDynamicStoreCopyValue(nil, "State:/Network/Interface/\(name)/IPv4" as CFString) as? [String: Any],
              let address = (state["Addresses"] as? [String])?.first,
              let mask = (state["SubnetMasks"] as? [String])?.first,
              NetworkVerification.usableIPv4(address) else { return nil }
        let signature = SHA256.hash(data: Data(networkSignature.utf8)).map { String(format: "%02x", $0) }.joined()
        return HomeInterface(address: address, mask: mask, signature: signature)
    }
    func contains(_ peer: String) -> Bool {
        func number(_ ip: String) -> UInt32? {
            let parts = ip.split(separator: ".").compactMap { UInt8($0) }
            guard parts.count == 4 else { return nil }
            return parts.reduce(0) { ($0 << 8) | UInt32($1) }
        }
        guard let local = number(address), let remote = number(peer), let subnet = number(mask) else { return false }
        return local & subnet == remote & subnet
    }
}

private enum HeartbeatClient {
    static func fetch(address: String, port: Int) -> Data? {
        guard (1...65535).contains(port), let port = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
        let connection = NWConnection(host: NWEndpoint.Host(address), port: port, using: .tcp)
        let queue = DispatchQueue(label: "EpsonLegacyConnect.peer")
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var received = Data()
        var result: Data?
        var finished = false
        func finish(_ data: Data?) {
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return }
            finished = true; result = data; semaphore.signal()
        }
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 2048) { data, _, complete, error in
                if let data { received.append(data) }
                if received.count > 4096 { finish(nil) }
                else if received.contains(10) { finish(received.prefix { $0 != 10 }) }
                else if complete || error != nil { finish(nil) }
                else { receive() }
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: receive()
            case .failed, .cancelled: finish(nil)
            default: break
            }
        }
        connection.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + 2)
        connection.cancel()
        lock.lock(); defer { lock.unlock() }
        return result
    }
}

/// Experimental opt-in bridge. The system IPP server handles client protocol;
/// our backend forwards only validated documents to the chosen local queue.
@MainActor final class AirPrintCoordinator: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published private(set) var enabled = false
    @Published private(set) var busy = false
    @Published private(set) var status = L("AirPrint bridge is off.")
    @Published private(set) var hosting = false
    private let id: UUID
    private var printerID = ""
    private var printerHost = ""
    private var queueName = ""
    private var home: HomeInterface?
    private var listener: NWListener?
    private var peerService: NetService?
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var loop: Task<Void, Never>?
    private var server: Process?
    private var spool: URL?
    private var logHandle: FileHandle?
    private var heartbeat = Data()
    private var generation = UUID()

    override init() {
        id = UserDefaults.standard.string(forKey: "assistant.bridgeID").flatMap(UUID.init(uuidString:)) ?? UUID()
        super.init()
        UserDefaults.standard.set(id.uuidString, forKey: "assistant.bridgeID")
        browser.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(shutdown), name: NSApplication.willTerminateNotification, object: nil)
    }
    func enable(queue: String, host: String, approveNetwork: Bool = false) async {
        guard !enabled, !busy else { return }
        generation = UUID()
        let session = generation
        busy = true
        defer { busy = false }
        do {
            guard PrinterCare.validQueue(queue), let home = HomeInterface.current(),
                  FileManager.default.isExecutableFile(atPath: "/usr/bin/ippeveprinter"),
                  let backend = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("EpsonAirPrintBackend"),
                  FileManager.default.isExecutableFile(atPath: backend.path) else {
                throw ComponentFiles.failure("AirPrint needs a Wi-Fi or Ethernet connection and the complete app build.")
            }
            if approveNetwork {
                UserDefaults.standard.set(home.signature, forKey: "assistant.airPrintNetwork")
            }
            guard UserDefaults.standard.string(forKey: "assistant.airPrintNetwork") == home.signature else {
                throw ComponentFiles.failure("AirPrint is paused on this network. Choose Enable on this network only on your trusted home network.")
            }
            let ppd = String(decoding: try Data(contentsOf: URL(fileURLWithPath: "/etc/cups/ppd/\(queue).ppd")), as: UTF8.self)
            guard ppd.contains("*ModelName: \"EPSON Epson Stylus Photo 1500\"") else { throw ConfigurationError.unsupportedModel }
            self.home = home; queueName = queue; printerHost = host
            printerID = SHA256.hash(data: Data(host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(home.address), port: .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.enabled, self.generation == session else { connection.cancel(); return }
                    let data = self.heartbeat
                    connection.start(queue: .global(qos: .utility))
                    connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.enabled, self.generation == session else { return }
                    if case .ready = state, let port = self.listener?.port {
                        let service = NetService(domain: "local.", type: "_elc-airprint._tcp.", name: self.id.uuidString, port: Int32(port.rawValue))
                        service.delegate = self
                        service.setTXTRecord(NetService.data(fromTXTRecord: ["address": Data(home.address.utf8), "printer": Data(self.printerID.utf8)]))
                        self.peerService = service; service.publish()
                    }
                    if case .failed = state { self.disable(); self.status = L("AirPrint peer discovery could not start. Check Local Network permission.") }
                }
            }
            enabled = true
            updateHeartbeat(ready: false)
            listener.start(queue: .global(qos: .utility))
            browser.searchForServices(ofType: "_elc-airprint._tcp.", inDomain: "local.")
            status = L("Checking eligible Macs before choosing an AirPrint host…")
            loop = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                while !Task.isCancelled, self?.generation == session {
                    await self?.elect(session: session)
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { break }
                }
            }
        } catch { status = error.localizedDescription }
    }
    func disable() {
        generation = UUID()
        enabled = false; loop?.cancel(); loop = nil
        browser.stop(); services.forEach { $0.stop() }; services = []
        peerService?.stop(); peerService = nil
        listener?.cancel(); listener = nil
        stopServer()
        status = L("AirPrint bridge is off.")
    }
    @objc private func shutdown() { disable() }
    private func updateHeartbeat(ready: Bool) {
        let value = BridgeHeartbeat(version: 1, id: id, printer: printerID, ready: ready, hosting: hosting)
        let data = ((try? JSONEncoder().encode(value)) ?? Data()) + Data([10])
        heartbeat = data
    }
    private func elect(session: UUID) async {
        guard enabled, generation == session, let home else { return }
        guard HomeInterface.current()?.signature == home.signature && HomeInterface.current()?.address == home.address else {
            disable(); status = L("The Mac's network changed. Enable AirPrint again on your home network."); return
        }
        if let server, !server.isRunning {
            self.server = nil; hosting = false
            status = L("The AirPrint service stopped. Check the bridge status before retrying.")
        }
        let host = printerHost
        let queue = queueName
        let ready = await Task.detached {
            FileManager.default.fileExists(atPath: "/etc/cups/ppd/\(queue).ppd") &&
            FileManager.default.isExecutableFile(atPath: "/Library/Printers/EPSON/InkjetPrinter2/Filter/rastertoescpII.app/Contents/MacOS/rastertoescpII") &&
            NetworkVerification.printPortReachable(host)
        }.value
        guard enabled, generation == session, !Task.isCancelled else { return }
        updateHeartbeat(ready: ready)
        var candidates = [BridgeCandidate(id: id, printerID: printerID, lastSeen: Date(), driverReady: ready, printerReachable: ready, hosting: hosting)]
        let endpoints = services.prefix(16).compactMap { service -> (UUID, String, Int)? in
            guard let other = UUID(uuidString: service.name), other != id, service.port > 0,
                  let txt = service.txtRecordData() else { return nil }
            let values = NetService.dictionary(fromTXTRecord: txt)
            guard values["printer"].flatMap({ String(data: $0, encoding: .utf8) }) == printerID,
                  let address = values["address"].flatMap({ String(data: $0, encoding: .utf8) }), home.contains(address) else { return nil }
            return (other, address, service.port)
        }
        let peers = await withTaskGroup(of: BridgeHeartbeat?.self, returning: [BridgeHeartbeat].self) { group in
            for (id, address, port) in endpoints {
                group.addTask {
                    guard let data = HeartbeatClient.fetch(address: address, port: port),
                          let value = try? JSONDecoder().decode(BridgeHeartbeat.self, from: data), value.version == 1, value.id == id else { return nil }
                    return value
                }
            }
            var values: [BridgeHeartbeat] = []
            for await value in group { if let value { values.append(value) } }
            return values
        }
        guard enabled, generation == session, !Task.isCancelled else { return }
        candidates += peers.map { BridgeCandidate(id: $0.id, printerID: $0.printer, lastSeen: Date(), driverReady: $0.ready, printerReachable: $0.ready, hosting: $0.hosting) }
        let leader = BridgeElection.leader(for: printerID, candidates: candidates, now: Date())
        if leader == id {
            if server == nil {
                do { try await startServer(session: session); status = L("This Mac is providing AirPrint. Verify printing from your iPhone or iPad.") }
                catch { if enabled, generation == session { status = error.localizedDescription } }
            }
        } else {
            stopServer()
            status = leader == nil ? L("Waiting for the printer and an eligible Mac.") : L("Another eligible Mac is providing AirPrint. This Mac is on standby.")
        }
        updateHeartbeat(ready: ready)
    }
    private func startServer(session: UUID) async throws {
        guard enabled, generation == session, !Task.isCancelled else { throw CancellationError() }
        guard let home, let backend = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("EpsonAirPrintBackend") else { throw ConfigurationError.invalidReply }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EpsonAirPrint-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        spool = directory
        let log = directory.appendingPathComponent("service.log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ippeveprinter")
        guard let localHost = SCDynamicStoreCopyLocalHostName(nil) as String? else { throw ConfigurationError.invalidReply }
        process.arguments = ["--no-web-forms", "-n", localHost + ".local", "-p", "8631", "-r", "_universal", "-P", "/etc/cups/ppd/\(queueName).ppd", "-c", backend.path, "-d", directory.path, "Epson Legacy Connect AirPrint"]
        var environment = ProcessInfo.processInfo.environment
        environment["ELC_QUEUE_NAME"] = queueName; environment["ELC_SPOOL_ROOT"] = directory.path
        process.environment = environment
        process.standardOutput = handle; process.standardError = handle
        try process.run()
        server = process; logHandle = handle
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let address = home.address
        let verified = await Task.detached {
            guard let result = try? CommandRunner.run("/usr/bin/ipptool", ["-tv", "ipp://\(address):8631/ipp/print", "/usr/share/cups/ipptool/get-printer-attributes.test"], timeout: 5) else { return false }
            return result.status == 0 && !result.timedOut &&
                PrinterCare.attribute("printer-make-and-model", in: result.output) == "EPSON SP 1500 Series" &&
                PrinterCare.attribute("document-format-supported", in: result.output)?.contains("image/urf") == true
        }.value
        guard enabled, generation == session, !Task.isCancelled, process.isRunning, verified else {
            if server === process { stopServer() }
            throw ComponentFiles.failure("The AirPrint endpoint could not be verified. Check whether another service uses port 8631 and review the bridge status.")
        }
        hosting = true
    }
    private func stopServer() {
        if let server, server.isRunning { server.terminate() }
        server = nil; hosting = false
        try? logHandle?.close(); logHandle = nil
        // Do not remove a spool directory while its server or upload may still
        // be closing. Kept private for recovery; documents are normally removed
        // by ippeveprinter when each job finishes.
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard service.name != id.uuidString, services.count < 32 else { return }
        service.delegate = self; services.append(service); service.resolve(withTimeout: 3)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0 == service }
    }
    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        disable(); status = L("AirPrint peer discovery could not start. Check Local Network permission.")
    }
}
