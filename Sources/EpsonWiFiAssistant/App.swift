import SwiftUI
import PrinterCore
import PDFKit
import UniformTypeIdentifiers
import ApplicationServices

@main
struct EpsonWiFiAssistantApp: App {
    @StateObject private var model = AssistantModel()
    init() {
        if let index = CommandLine.arguments.firstIndex(of: "--verify-scan"), CommandLine.arguments.count > index + 1 {
            do {
                let configuration = USBConfiguration(componentPath: CommandLine.arguments[index + 1])
                guard let printer = try configuration.printers().first else { throw ConfigurationError.noPrinter }
                try configuration.startWirelessScan(printer)
                print("Printer accepted Wi-Fi scan")
                for _ in 0..<10 {
                    Thread.sleep(forTimeInterval: 1)
                    let networks = try configuration.wirelessNetworks(printer)
                    print("Visible networks: \(networks.count); security modes: \(Set(networks.map(\.securityType)).sorted())")
                    if !networks.isEmpty { exit(0) }
                }
                exit(2)
            } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--inspect-group"), CommandLine.arguments.count > index + 2 {
            do {
                let configuration = USBConfiguration(componentPath: CommandLine.arguments[index + 1])
                guard let printer = try configuration.printers().first else { throw ConfigurationError.noPrinter }
                let reply = try configuration.readData(printer, groups: [CommandLine.arguments[index + 2]])
                // Research output is field metadata only; never print stored credentials.
                let document = try XMLDocument(data: reply)
                for node in try document.nodes(forXPath: "//*") {
                    guard let element = node as? XMLElement else { continue }
                    let id = element.attribute(forName: "id")?.stringValue ?? ""
                    let result = element.attribute(forName: "return")?.stringValue ?? ""
                    let safeValue = ["ijcp:WlanType", "ijcp:SecurityType", "ijcp:SSIDScan"].contains(id) ? (element.stringValue ?? "") : ""
                    print("\(element.localName ?? "?") \(id) \(result) \(safeValue)")
                }
                exit(0)
            } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--read-network"), CommandLine.arguments.count > index + 1 {
            do {
                let configuration = USBConfiguration(componentPath: CommandLine.arguments[index + 1])
                guard let printer = try configuration.printers().first else { throw ConfigurationError.noPrinter }
                let network = try configuration.readNetwork(printer)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                FileHandle.standardOutput.write(try encoder.encode(network))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(1)
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--inspect-care"), CommandLine.arguments.count > index + 1 {
            do {
                let actions = try PrinterCare.capabilities(queue: CommandLine.arguments[index + 1])
                print("Driver advertises: " + actions.map(\.rawValue).joined(separator: ", "))
                exit(0)
            } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
        }
        if CommandLine.arguments.contains("--diagnose") {
            let snapshot = PrinterDiagnostics.capture()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(snapshot) { FileHandle.standardOutput.write(data) }
            exit(0)
        }
        NSApplication.shared.setActivationPolicy(.regular)
    }
    var body: some Scene {
        WindowGroup("Epson Legacy Connect", id: "main") {
            ContentView().environmentObject(model)
                .environment(\.locale, model.language.locale)
                .frame(minWidth: 900, minHeight: 660)
                .task {
                    while !Task.isCancelled {
                        await model.refresh()
                        do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { break }
                    }
                }
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1080, height: 760)
    }
}

@MainActor final class PrinterStatusMenu: NSObject {
    weak var model: AssistantModel?
    private let item: NSStatusItem
    private let popover = NSPopover()
    init(model: AssistantModel) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.button?.image = NSImage(systemSymbolName: "printer", accessibilityDescription: "Epson Legacy Connect")
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "Epson Legacy Connect"
        item.button?.target = self
        item.button?.action = #selector(toggle)
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: 560)
        popover.contentViewController = NSHostingController(rootView: PrinterQuickPanel(model: model, discovery: model.discovery, open: { [weak self] destination in
            self?.popover.performClose(nil)
            self?.model?.destination = destination
            self?.model?.showDashboard?()
        }))
    }
    func remove() { popover.performClose(nil); NSStatusBar.system.removeStatusItem(item) }
    func show() { toggle() }
    @objc private func toggle() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = item.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.title = L("Printer menu")
        popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
    }
}

struct PrinterQuickPanel: View {
    @ObservedObject var model: AssistantModel
    @ObservedObject var discovery: PrinterDiscovery
    let open: (Destination) -> Void
    private func inkColor(_ name: String) -> Color {
        if name.contains("Cyan") { return .cyan }
        if name.contains("Magenta") { return .pink }
        if name.contains("Yellow") { return .yellow }
        return .primary
    }
    private func shortcut(_ title: String, _ symbol: String, _ destination: Destination) -> some View {
        Button { open(destination) } label: {
            VStack(alignment: .leading, spacing: 9) {
                Image(systemName: symbol).font(.system(size: 19, weight: .medium)).foregroundStyle(.teal)
                Text(L(title)).font(.system(size: 12, weight: .semibold)).lineLimit(2)
            }.frame(maxWidth: .infinity, minHeight: 57, alignment: .leading).padding(13)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
                .contentShape(RoundedRectangle(cornerRadius: 13))
        }.buttonStyle(.plain).accessibilityLabel(L(title))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 11) {
                if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"), let icon = NSImage(contentsOfFile: path) {
                    Image(nsImage: icon).resizable().frame(width: 46, height: 46).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(discovery.printers.first?.name ?? "Epson Legacy Connect").font(.system(size: 14, weight: .bold)).lineLimit(1)
                    Text(L("Your printer, at a glance")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button { open(.overview) } label: { Image(systemName: "arrow.up.forward.app").font(.system(size: 16)) }
                    .buttonStyle(.plain).help(L("Open printer dashboard")).accessibilityLabel(L("Open printer dashboard"))
            }
            HStack(spacing: 9) {
                Circle().fill(model.printerReachable == true ? Color.teal : Color.orange).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L(model.printerReachable == true ? "Printer reachable" : "Connection needs checking")).font(.system(size: 12, weight: .semibold))
                    if let date = model.lastHealthCheck {
                        Text(L("Last checked %@.", date.formatted(.dateTime.locale(model.language.locale).hour().minute())))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.refreshing || model.checkingHealth { ProgressView().controlSize(.small) }
                else { Image(systemName: "wifi").foregroundStyle(.secondary) }
            }.padding(12).background(.teal.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
            if model.menuShowsInk, let inks = model.snapshot?.inks, !inks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Ink reported by the driver")).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    HStack(spacing: 9) {
                        ForEach(inks) { ink in
                            VStack(spacing: 5) {
                                Capsule().fill(inkColor(ink.name).opacity(0.15)).frame(height: 6)
                                    .overlay(alignment: .leading) {
                                        GeometryReader { geometry in
                                            Capsule().fill(inkColor(ink.name)).frame(width: geometry.size.width * Double(ink.percent ?? 0) / 100)
                                        }
                                    }
                                Text(ink.percent.map { "\($0)%" } ?? "—").font(.system(size: 10, weight: .medium, design: .rounded))
                            }.frame(maxWidth: .infinity)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(L(ink.name) + ": " + (ink.percent.map { "\($0)%" } ?? L("Unknown")))
                        }
                    }
                    Text(L("Readings may be cached.")).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                shortcut("Print a photo or PDF", "photo.on.rectangle", .printing)
                shortcut("Print jobs", "list.bullet.rectangle", .jobs)
                shortcut("Printer care", "wrench.and.screwdriver", .maintenance)
                if model.menuShowsSetup { shortcut("Wi-Fi setup", "wifi", .wifi) }
            }
            Divider()
            HStack {
                Button { Task { await model.refresh() } } label: { Label(L("Refresh"), systemImage: "arrow.clockwise") }
                    .buttonStyle(.plain).font(.system(size: 11)).disabled(model.refreshing)
                Spacer()
                Button { open(.diagnostics) } label: { Image(systemName: "stethoscope") }
                    .buttonStyle(.plain).help(L("Diagnostics")).accessibilityLabel(L("Diagnostics"))
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.plain).padding(.leading, 10).help(L("Quit Epson Legacy Connect")).accessibilityLabel(L("Quit Epson Legacy Connect"))
            }.foregroundStyle(.secondary)
        }.padding(20).frame(width: 380).background(.regularMaterial)
            .environment(\.locale, model.language.locale)
    }
}

enum Destination: String, CaseIterable, Identifiable {
    case overview = "Your printer", wifi = "Wi-Fi setup", driver = "Printer driver"
    case airprint = "AirPrint", printing = "Print", jobs = "Print jobs", maintenance = "Maintenance", power = "Power", diagnostics = "Diagnostics"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: return "printer"
        case .wifi: return "wifi"
        case .driver: return "shippingbox"
        case .airprint: return "iphone.and.arrow.forward"
        case .printing: return "photo.on.rectangle"
        case .jobs: return "list.bullet.rectangle"
        case .maintenance: return "wrench.and.screwdriver"
        case .power: return "power"
        case .diagnostics: return "waveform.path.ecg"
        }
    }
}

@MainActor final class AssistantModel: ObservableObject {
    @Published var language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "assistant.language") ?? "system") ?? .system {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "assistant.language") }
    }
    @Published var showMenuBar = UserDefaults.standard.object(forKey: "assistant.menuBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showMenuBar, forKey: "assistant.menuBar"); updateStatusMenu() }
    }
    @Published var menuShowsInk = UserDefaults.standard.object(forKey: "assistant.menuInk") as? Bool ?? true {
        didSet { UserDefaults.standard.set(menuShowsInk, forKey: "assistant.menuInk") }
    }
    @Published var menuShowsSetup = UserDefaults.standard.object(forKey: "assistant.menuSetup") as? Bool ?? true {
        didSet { UserDefaults.standard.set(menuShowsSetup, forKey: "assistant.menuSetup") }
    }
    @Published var showingMenuPreferences = false
    private var statusMenu: PrinterStatusMenu?
    func openQuickMenu() { statusMenu?.show() }
    var showDashboard: (() -> Void)?
    func updateStatusMenu() {
        if showMenuBar && statusMenu == nil { statusMenu = PrinterStatusMenu(model: self) }
        if !showMenuBar { statusMenu?.remove(); statusMenu = nil }
    }
    @Published var destination: Destination? = .overview
    @Published var snapshot: PrinterSnapshot?
    @Published var refreshing = false
    @Published var ssid = "" {
        didSet {
            if !connecting && oldValue != ssid { connectionVerified = false; connectionStatus = "" }
        }
    }
    @Published var password = ""
    @Published var healthMessage = ""
    @Published var checkingHealth = false
    @Published var printerReachable: Bool?
    @Published var lastHealthCheck: Date?
    @Published var setupRepairBusy = false
    @Published var powerTimer: PowerOffTimer = .alwaysOn
    @Published var network: NetworkState?
    @Published var checkingNetwork = false
    @Published var networkError: String?
    @Published var networkCheckedAt: Date?
    @Published var setupStep = 1
    @Published var networks: [WirelessNetwork] = []
    @Published var scanning = false
    @Published var scanStatus = ""
    @Published var networkSearch = ""
    @Published var connecting = false
    @Published var connectionStatus = ""
    @Published var connectionVerified = false
    let discovery = PrinterDiscovery()
    let bridge = AirPrintCoordinator()
    @Published var airPrintPreferred = UserDefaults.standard.bool(forKey: "assistant.airPrint") {
        didSet { UserDefaults.standard.set(airPrintPreferred, forKey: "assistant.airPrint") }
    }
    func updateBridge(approveNetwork: Bool = false) async {
        if !airPrintPreferred { bridge.disable(); return }
        guard !bridge.enabled, !bridge.busy,
              let queue = snapshot?.queues.first(where: { $0.id == selectedQueue && $0.isNetwork }),
              let host = URL(string: queue.uri)?.host else { return }
        await bridge.enable(queue: queue.id, host: host, approveNetwork: approveNetwork)
    }
    @Published var queueMessage = ""
    @Published var addingQueue = false
    @Published var cancelAddingQueue = false
    @Published var preparingUSB = false
    @Published var showingUSBLicence = false
    @Published var usbLicenceText = ""
    @Published var selectedQueue = ""
    @Published var documentURL: URL?
    @Published var documentPreview: NSImage?
    @Published var printMessage = ""
    @Published var printJobs: [PrintJob] = []
    @Published var jobsMessage = ""
    @Published var loadingJobs = false
    @Published var pendingCancel: PrintJob?
    @Published var confirmingCancel = false
    func chooseDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .jpeg, .png, .tiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = L("Choose a PDF or photo to print.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        documentURL = nil; documentPreview = nil; printMessage = ""
        if url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else {
                printMessage = L("This PDF could not be opened or is password protected."); return
            }
            documentPreview = document.page(at: 0)?.thumbnail(of: NSSize(width: 420, height: 420), for: .cropBox)
        } else {
            guard let image = NSImage(contentsOf: url), image.isValid else { printMessage = L("This photo could not be opened."); return }
            documentPreview = image
        }
        documentURL = url
    }
    func printDocument() {
        guard let url = documentURL, PrinterCare.validQueue(selectedQueue),
              let printer = PMPrinterCreateFromPrinterID(selectedQueue as CFString) else {
            printMessage = L("Add and select a printer on this Mac first."); return
        }
        defer { PMRelease(UnsafeRawPointer(printer)) }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        guard PMSessionSetCurrentPMPrinter(OpaquePointer(info.pmPrintSession()), printer) == noErr else {
            printMessage = L("The selected printer could not be opened. Refresh the printer list and retry."); return
        }
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        let operation: NSPrintOperation?
        if url.pathExtension.lowercased() == "pdf" {
            operation = PDFDocument(url: url)?.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true)
        } else if let image = NSImage(contentsOf: url) {
            let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 540, height: 720))
            imageView.image = image
            imageView.imageScaling = .scaleProportionallyUpOrDown
            operation = NSPrintOperation(view: imageView, printInfo: info)
        } else { operation = nil }
        guard let operation else { printMessage = L("The document could not be prepared for printing."); return }
        operation.jobTitle = url.lastPathComponent
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.printPanel.options.formUnion([.showsPaperSize, .showsOrientation, .showsScaling, .showsPreview])
        printMessage = operation.run() ? L("Sent to macOS printing. Open Print jobs to check progress.") : L("Printing was cancelled or could not finish. Check the queue before retrying.")
        Task { await refreshJobs() }
    }
    func refreshJobs(preserveMessage: Bool = false) async {
        guard !loadingJobs else { return }
        guard !selectedQueue.isEmpty else { jobsMessage = L("Add a wireless printer on this Mac first."); printJobs = []; return }
        loadingJobs = true
        defer { loadingJobs = false }
        let queue = selectedQueue
        let result = await Task.detached { Result { try PrintJobs.pending(queue: queue) } }.value
        switch result {
        case .success(let jobs):
            printJobs = jobs
            if !preserveMessage { jobsMessage = jobs.isEmpty ? L("No pending jobs in this queue.") : "" }
        case .failure(let error): jobsMessage = error.localizedDescription
        }
    }
    func cancelJob() async {
        guard !loadingJobs, let job = pendingCancel else { return }
        pendingCancel = nil
        loadingJobs = true
        let result = await Task.detached { Result { try PrintJobs.cancel(job) } }.value
        switch result {
        case .success: jobsMessage = L("The job was cancelled. A page already sent to the printer may still finish.")
        case .failure(let error): jobsMessage = error.localizedDescription
        }
        loadingJobs = false
        await refreshJobs(preserveMessage: true)
    }
    @Published var careActions: [CareAction] = []
    @Published var checkingCare = false
    @Published var careBusy = false
    @Published var careMessage = ""
    @Published var pendingCare: CareAction?
    @Published var confirmCare = false
    @Published var showingReplacement = false
    @Published var replacementStep = 0
    func loadCare() async {
        guard !checkingCare, !careBusy else { return }
        checkingCare = true
        careActions = []
        defer { checkingCare = false }
        guard !selectedQueue.isEmpty else { careMessage = L("Add a wireless printer on this Mac first."); return }
        let queue = selectedQueue
        let result = await Task.detached { Result { try PrinterCare.capabilities(queue: queue) } }.value
        switch result {
        case .success(let actions): careActions = actions; careMessage = actions.isEmpty ? L("This printer driver does not advertise maintenance commands.") : L("Available commands were read from this printer's installed driver.")
        case .failure(let error): careMessage = error.localizedDescription
        }
    }
    func performCare() async {
        guard !careBusy, let action = pendingCare, careActions.contains(action) else { return }
        pendingCare = nil
        careBusy = true
        defer { careBusy = false }
        careMessage = L("Submitting maintenance request…")
        let queue = selectedQueue
        let result = await Task.detached { Result { try PrinterCare.submit(action, queue: queue) } }.value
        switch result {
        case .failure(let error): careMessage = error.localizedDescription
        case .success(let number):
            careMessage = L("Request accepted by macOS. Waiting for the driver…")
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let state = await Task.detached { try? PrinterCare.jobState(number) }.value
                if state == .completed {
                    careMessage = L("The driver finished this request. Check the printer; job completion does not verify the physical result.")
                    await refresh()
                    return
                }
                if state == .aborted || state == .canceled || state == .stopped || state == .held {
                    careMessage = L("The maintenance job was stopped or held. Open the print queue before trying again.")
                    return
                }
            }
            careMessage = L("The request is still unconfirmed. Check the print queue and printer before repeating it.")
        }
    }
    func prepareUSB() async {
        guard !preparingUSB else { return }
        preparingUSB = true
        networkError = nil
        do {
            let prepared = try await OfficialComponents.shared.prepareUSBComponent()
            let html = try Data(contentsOf: prepared.licence)
            guard html.count < 1_000_000 else { throw ConfigurationError.invalidReply }
            usbLicenceText = try NSAttributedString(data: html, options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil).string
            showingUSBLicence = true
        } catch { networkError = error.localizedDescription }
        preparingUSB = false
    }
    func acceptUSBLicence() {
        UserDefaults.standard.set(ComponentFiles.usbConsentVersion, forKey: "assistant.usbLicence")
        showingUSBLicence = false
        Task { await checkNetwork() }
    }
    @Published var checkingInstaller = false
    @Published var installerMessage = ""
    func installDriver() async {
        guard !checkingInstaller else { return }
        checkingInstaller = true
        installerMessage = L("Verifying the Epson installer…")
        let result: Result<URL, Error>
        do { result = .success(try await OfficialComponents.shared.driverInstaller()) }
        catch { result = .failure(error) }
        switch result {
        case .success(let url):
            if NSWorkspace.shared.open(url) {
                installerMessage = L("Complete the Epson installation in the macOS Installer, then refresh this page.")
            } else { installerMessage = L("macOS could not open the installer.") }
        case .failure(let error): installerMessage = error.localizedDescription
        }
        checkingInstaller = false
    }
    func addPrinter(_ printer: NetworkPrinter) async {
        guard !addingQueue else { return }
        addingQueue = true
        cancelAddingQueue = false
        defer { addingQueue = false }
        guard let profile = PrinterProfiles.match(printer.model) else { queueMessage = L("This printer model is not supported yet."); return }
        if !FileManager.default.fileExists(atPath: profile.ppdPath) || !PrinterDiagnostics.driverStatus().filterAvailable {
            queueMessage = L("Downloading and verifying the official Epson driver…")
            do {
                let package = try await OfficialComponents.shared.driverInstaller()
                guard !cancelAddingQueue else { queueMessage = L("Setup cancelled."); return }
                guard NSWorkspace.shared.open(package) else { throw ComponentFiles.failure("macOS could not open the installer.") }
                queueMessage = L("Complete the macOS Installer. This app will add the printer automatically afterward.")
                let deadline = Date().addingTimeInterval(300)
                while Date() < deadline && !cancelAddingQueue {
                    if FileManager.default.fileExists(atPath: profile.ppdPath) && PrinterDiagnostics.driverStatus().filterAvailable { break }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
                guard !cancelAddingQueue else { queueMessage = L("Setup cancelled."); return }
                guard FileManager.default.fileExists(atPath: profile.ppdPath), PrinterDiagnostics.driverStatus().filterAvailable else { throw ComponentFiles.failure("Driver installation was not confirmed. You can retry after completing the installer.") }
            } catch { queueMessage = error.localizedDescription; return }
        }
        queueMessage = L("Adding and verifying the wireless print queue…")
        let result = await Task.detached { Result { try WirelessQueue.install(host: printer.host, model: printer.model) } }.value
        switch result {
        case .success(let queue): selectedQueue = queue; queueMessage = L("The wireless printer is ready on this Mac."); await refresh()
        case .failure(let error): queueMessage = error.localizedDescription
        }
    }
    func connectWiFi() async {
        guard !connecting, !scanning, !checkingNetwork else { return }
        do { try WiFiCredentials.validate(ssid: ssid, password: password) }
        catch { networkError = error.localizedDescription; return }
        connecting = true
        connectionVerified = false
        networkError = nil
        setupStep = 3
        connectionStatus = "Sending network settings over USB…"
        let selectedSSID = ssid
        let selectedPassword = password
        password = ""
        let preparation = await Task.detached { () -> Result<(USBConfiguration, USBPrinter), Error> in
            Result {
                guard let path = USBConfiguration.bundledComponent() else { throw ConfigurationError.componentMissing }
                let configuration = USBConfiguration(componentPath: path)
                let printers = try configuration.printers()
                guard printers.count == 1, let printer = printers.first else { throw ConfigurationError.noPrinter }
                try configuration.configureWiFi(printer, ssid: selectedSSID, password: selectedPassword)
                return (configuration, printer)
            }
        }.value
        switch preparation {
        case .failure(let error):
            networkError = error.localizedDescription
            connectionStatus = "Setup was not confirmed. Check the printer connection before retrying."
        case .success(let (configuration, printer)):
            connectionStatus = "Settings accepted. Waiting for the router to assign an address…"
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let state = await Task.detached { () -> (NetworkState, WirelessState, Bool)? in
                    guard let network = try? configuration.readNetwork(printer),
                          let wireless = try? configuration.readWirelessState(printer) else { return nil }
                    return (network, wireless, NetworkVerification.printPortReachable(network.address))
                }.value
                guard let (network, wireless, reachable) = state else { continue }
                self.network = network
                networkCheckedAt = Date()
                if network.hasAssignedAddress && wireless.ssid == selectedSSID && reachable {
                    connectionVerified = true
                    connectionStatus = "Connected. Your printer is reachable at \(network.address)."
                    break
                }
                connectionStatus = network.hasAssignedAddress ? "Address assigned. Checking the printer on your local network…" : "Waiting for Wi-Fi and an address from the router…"
            }
            if !connectionVerified {
                networkError = "The printer has not confirmed a working connection. Check the network name and password, keep this Mac on the same home network, and check that the router allows 2.4 GHz WPA2 devices."
                connectionStatus = "Connection could not be verified. Your USB printing setup is still available."
            }
        }
        connecting = false
    }
    func scanNetworks() async {
        guard !scanning, !checkingNetwork, !connecting else { return }
        scanning = true
        networkError = nil
        networks = []
        networkSearch = ""
        scanStatus = "Asking the printer to search for networks…"
        let result = await Task.detached { () -> Result<[WirelessNetwork], Error> in
            Result {
                guard let path = USBConfiguration.bundledComponent() else { throw ConfigurationError.componentMissing }
                let configuration = USBConfiguration(componentPath: path)
                let printers = try configuration.printers()
                guard printers.count == 1, let printer = printers.first else { throw ConfigurationError.noPrinter }
                try configuration.startWirelessScan(printer)
                for _ in 0..<30 {
                    Thread.sleep(forTimeInterval: 1)
                    if try configuration.wirelessScanStatus(printer) == .complete {
                        return try configuration.wirelessNetworks(printer)
                    }
                }
                throw ComponentFiles.failure("The Wi-Fi scan timed out. Try searching again.")
            }
        }.value
        switch result {
        case .success(let found): networks = found; scanStatus = found.isEmpty ? "No networks found. Move the printer closer to the router or enter its network name below." : "Found \(found.count) networks visible to your printer. Select your home network."
        case .failure(let error): networkError = error.localizedDescription; scanStatus = "Search could not finish. You can retry."
        }
        scanning = false
    }
    func checkNetwork() async {
        guard !checkingNetwork else { return }
        checkingNetwork = true
        networkError = nil
        let result = await Task.detached { () -> Result<NetworkState, Error> in
            Result {
                guard let path = USBConfiguration.bundledComponent() else { throw ConfigurationError.componentMissing }
                let configuration = USBConfiguration(componentPath: path)
                let printers = try configuration.printers()
                guard printers.count == 1, let printer = printers.first else { throw ConfigurationError.noPrinter }
                return try configuration.readNetwork(printer)
            }
        }.value
        switch result {
        case .success(let state): network = state; networkCheckedAt = Date(); setupStep = 2
        case .failure(let error): networkError = error.localizedDescription
        }
        checkingNetwork = false
    }
    func checkHealth() async {
        guard !checkingHealth else { return }
        checkingHealth = true
        defer { checkingHealth = false }
        let host = discovery.printers.first?.host ?? snapshot?.queues.first(where: { $0.id == selectedQueue && $0.isNetwork }).flatMap { URL(string: $0.uri)?.host }
        guard let host else {
            printerReachable = nil
            lastHealthCheck = Date()
            healthMessage = snapshot?.usbPresent == true ? L("USB is connected. Set up Wi-Fi to make this printer available on your network.") : L("No network printer found. Check power, use the main home Wi-Fi, and connect USB if the printer needs new router settings.")
            return
        }
        let reachable = await Task.detached { NetworkVerification.printPortReachable(host) }.value
        printerReachable = reachable
        lastHealthCheck = Date()
        if !reachable {
            healthMessage = L("The printer's network port is not responding. Check power and the main Wi-Fi network. A stored print queue alone does not prove a connection.")
        } else if snapshot?.driver.ready != true {
            healthMessage = L("The printer is reachable. Its Epson driver needs attention on this Mac.")
        } else if snapshot?.queues.contains(where: { $0.isNetwork }) != true {
            healthMessage = L("The printer is reachable. Add its wireless queue to this Mac to print.")
        } else { healthMessage = L("The printer is reachable and its driver and wireless queue are installed.") }
    }
    func repairSetup() async {
        guard !setupRepairBusy, !addingQueue else { return }
        setupRepairBusy = true
        defer { setupRepairBusy = false }
        if let printer = discovery.printers.first {
            await addPrinter(printer)
        } else if snapshot?.driver.ready != true {
            await installDriver()
        } else {
            healthMessage = L("Check the printer's power and Wi-Fi first. USB setup can change its router settings; the app will not overwrite them automatically.")
        }
        await refresh()
        await checkHealth()
    }
    func refresh(rescan: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        discovery.start(restart: rescan)
        let result = await Task.detached { PrinterDiagnostics.capture() }.value
        snapshot = result
        if !result.queues.contains(where: { $0.id == selectedQueue }) {
            selectedQueue = result.queues.first(where: { $0.isNetwork })?.id ?? result.queues.first?.id ?? ""
        }
        refreshing = false
        await checkHealth()
        await updateBridge()
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AssistantModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 10) {
                    if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"), let icon = NSImage(contentsOfFile: path) {
                        Image(nsImage: icon).resizable().frame(width: 36, height: 36).accessibilityHidden(true)
                    }
                    VStack(alignment: .leading) {
                        Text("Epson Legacy").font(.headline)
                        Text("ASSISTANT").font(.caption2.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 16).padding(.top, 20)
                List(Destination.allCases, selection: $model.destination) { destination in
                    Label(LocalizedStringKey(destination.rawValue), systemImage: destination.symbol).tag(destination)
                        .padding(.vertical, 5)
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 5) {
                    Picker("Language", selection: $model.language) {
                        ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
                    }.disabled(model.connecting)
                    Toggle("Show in menu bar", isOn: $model.showMenuBar).font(.caption)
                    Button("Menu preferences") { model.showingMenuPreferences = true }.font(.caption)
                    Text("Legacy Connect").font(.caption.weight(.semibold))
                    Text("v2 Preview · Hardware testing in progress")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(16)
            }.navigationSplitViewColumnWidth(220)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(LocalizedStringKey((model.destination ?? .overview).rawValue)).font(.largeTitle.bold())
                            Text("Epson Legacy Connect").foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.refreshing { ProgressView().controlSize(.small) }
                        if model.showMenuBar {
                            Button { model.openQuickMenu() } label: { Label("Printer menu", systemImage: "menubar.rectangle") }
                        }
                        Button { Task { await model.refresh(rescan: true) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                            .disabled(model.refreshing)
                    }
                    switch model.destination ?? .overview {
                    case .overview: OverviewView(discovery: model.discovery)
                    case .wifi: WiFiView()
                    case .driver: DriverView()
                    case .airprint: AirPrintView(bridge: model.bridge)
                    case .printing: PrintView()
                    case .jobs: JobsView()
                    case .maintenance: MaintenanceView()
                    case .power: PowerView()
                    case .diagnostics: DiagnosticsView()
                    }
                }.padding(32).frame(maxWidth: 1100, alignment: .leading)
            }.background(Color(nsColor: .windowBackgroundColor))
        }.tint(.teal)
        .onAppear {
            model.showDashboard = { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            model.updateStatusMenu()
        }
        .sheet(isPresented: $model.showingMenuPreferences) { MenuPreferencesView(model: model) }
        .sheet(isPresented: $model.showingReplacement) { CartridgeReplacementView().environmentObject(model) }
        .sheet(isPresented: $model.showingUSBLicence) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Epson component licence").font(.title2.bold())
                Text("The USB setup component was downloaded from Epson. Review its licence before enabling it.").foregroundStyle(.secondary)
                ScrollView { Text(model.usbLicenceText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(minHeight: 300)
                HStack {
                    Button("Cancel") { model.showingUSBLicence = false }
                    Spacer()
                    Button("Accept and enable") { model.acceptUSBLicence() }.buttonStyle(.borderedProminent)
                }
            }.padding(28).frame(width: 700, height: 520)
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.primary.opacity(0.07)))
    }
}

struct OverviewView: View {
    @EnvironmentObject var model: AssistantModel
    @ObservedObject var discovery: PrinterDiscovery
    var wifiDetected: Bool { !discovery.printers.isEmpty }
    var body: some View {
        HealthView(discovery: model.discovery)
        NetworkPrintersView(discovery: model.discovery)
        if !wifiDetected { Card {
            HStack(spacing: 30) {
                Image(systemName: "printer.fill").font(.system(size: 80)).foregroundStyle(.teal.gradient)
                    .frame(width: 150, height: 145).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 12) {
                    Text(L(wifiDetected ? "Change router settings" : (model.snapshot?.usbPresent == true ? "Connected by USB" : "Connect your printer"))).font(.title2.bold())
                    Text(L(wifiDetected ? "Your printer is already on Wi-Fi. Connect USB only when you want to change its network settings." : (model.snapshot?.usbPresent == true ? "Your printer is detected. USB is used to send its Wi-Fi settings during setup." : "Turn the printer on and connect it to this Mac with a USB cable.")))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Set up Wi-Fi") { model.destination = .wifi }.buttonStyle(.borderedProminent)
                }
            }
        }
        }
        HStack(alignment: .top, spacing: 16) {
            Card {
                Label("Printer driver", systemImage: "shippingbox").font(.headline)
                Text(L(model.snapshot?.driver.ready == true ? "Installed" : "Needs attention")).font(.title3.bold())
                Text(model.snapshot?.driver.version.map { L("Epson driver %@", $0) } ?? L("Checking installed software…")).foregroundStyle(.secondary)
                Button("View driver") { model.destination = .driver }
            }
            Card {
                Label("Network connection", systemImage: "wifi").font(.headline)
                Text(wifiDetected ? L("Found on Wi-Fi") : (model.network.map { $0.hasAssignedAddress ? $0.address : L("Waiting for setup") } ?? L("Not verified"))).font(.title3.bold())
                Text(L(wifiDetected ? (model.snapshot?.queues.contains(where: { $0.isNetwork }) == true ? "The printer is ready. You can print without USB." : "Network printer discovered. Add it to this Mac to start printing.") : (model.network == nil ? "Read the printer's own settings to check its connection." : "Network address read directly from the printer over USB."))).foregroundStyle(.secondary)
                Button("Open setup") { model.destination = .wifi }
            }
        }
        if let snapshot = model.snapshot, !snapshot.inks.isEmpty {
            Card {
                Text("Ink reported by the driver").font(.headline)
                HStack(alignment: .top, spacing: 16) {
                    ForEach(snapshot.inks) { ink in
                        VStack(spacing: 8) {
                            ProgressView(value: Double(ink.percent ?? 0), total: 100).tint(color(ink.name))
                            Text(ink.percent.map { "\($0)%" } ?? L("Unknown")).font(.headline)
                            Text(L(ink.name)).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity)
                    }
                }
                Text(L("Queue readings can be cached. Last checked %@.", snapshot.capturedAt.formatted(.dateTime.locale(model.language.locale).hour().minute().second())))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    func color(_ name: String) -> Color {
        if name.contains("Cyan") { return .cyan }
        if name.contains("Magenta") { return .pink }
        if name.contains("Yellow") { return .yellow }
        return .primary
    }
}

struct HealthView: View {
    @EnvironmentObject var model: AssistantModel
    @ObservedObject var discovery: PrinterDiscovery
    var body: some View {
        Card {
            HStack {
                Label("Printer health", systemImage: model.printerReachable == true ? "checkmark.circle.fill" : "stethoscope").font(.headline)
                Spacer()
                if model.checkingHealth || model.setupRepairBusy { ProgressView().controlSize(.small) }
                Button("Check now") { Task { await model.checkHealth() } }.disabled(model.checkingHealth)
            }
            Text(model.healthMessage.isEmpty ? L("Checking your printer…") : model.healthMessage).foregroundStyle(.secondary)
            if let date = model.lastHealthCheck { Text(L("Last checked %@.", date.formatted(.dateTime.locale(model.language.locale).hour().minute().second()))).font(.caption).foregroundStyle(.secondary) }
            HStack {
                if model.printerReachable == true && model.snapshot?.driver.ready == true && model.snapshot?.queues.contains(where: { $0.isNetwork }) == true {
                    Button("Print a photo or PDF") { model.destination = .printing }.buttonStyle(.borderedProminent)
                    Button("Print jobs") { model.destination = .jobs }
                } else {
                    Button("Repair setup on this Mac") { Task { await model.repairSetup() } }
                        .disabled(model.setupRepairBusy || model.addingQueue || model.checkingInstaller)
                    Button("Wi-Fi setup") { model.destination = .wifi }
                }
            }
        }.task(id: discovery.printers.map(\.host).joined(separator: ",")) { await model.checkHealth() }
    }
}

struct NetworkPrintersView: View {
    @EnvironmentObject var model: AssistantModel
    @ObservedObject var discovery: PrinterDiscovery
    var body: some View {
        Card {
            Label("Printers on your Wi-Fi", systemImage: "wifi").font(.headline)
            if discovery.printers.isEmpty {
                Text("Looking for your Epson printer on this network…").foregroundStyle(.secondary)
            }
            ForEach(discovery.printers) { printer in
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(printer.name).font(.title3.bold())
                        Text(printer.host).foregroundStyle(.secondary)
                        Text("Discovered directly on your local network. USB is optional for printing.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.snapshot?.queues.contains(where: { $0.isNetwork && URL(string: $0.uri)?.host?.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() == printer.host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() }) == true {
                        Label("Ready on this Mac", systemImage: "checkmark.circle.fill").foregroundStyle(.teal)
                    } else {
                        Button("Add to this Mac") { Task { await model.addPrinter(printer) } }
                            .buttonStyle(.borderedProminent).disabled(model.addingQueue)
                    }
                }
            }
            if let error = discovery.error { Text(error).foregroundStyle(.orange) }
            if !model.queueMessage.isEmpty { Text(model.queueMessage).foregroundStyle(.secondary) }
            if model.addingQueue {
                HStack { ProgressView().controlSize(.small); Button("Cancel setup") { model.cancelAddingQueue = true } }
            }
        }
    }
}

struct WiFiView: View {
    @EnvironmentObject var model: AssistantModel
    var validation: String? {
        do { try WiFiCredentials.validate(ssid: model.ssid, password: model.password); return nil }
        catch { return error.localizedDescription }
    }
    var body: some View {
        Card {
            Text("Connect once. Print wirelessly.").font(.title2.bold())
            Text("Use USB to configure the printer for your router. WPS is not needed. After setup, the printer will use its own Wi-Fi connection.")
                .foregroundStyle(.secondary)
            Divider()
            if USBConfiguration.bundledComponent() == nil {
                Text("USB setup needs an official Epson communication component. It is downloaded directly from Epson, not included in the public app.").foregroundStyle(.secondary)
                Button("Prepare USB setup") { Task { await model.prepareUSB() } }.disabled(model.preparingUSB)
                if model.preparingUSB { ProgressView("Downloading and verifying Epson components…") }
            }
            HStack(spacing: 20) {
                ForEach(1...3, id: \.self) { step in
                    HStack(spacing: 8) {
                        Image(systemName: step < model.setupStep ? "checkmark.circle.fill" : "\(step).circle.fill")
                        Text(L(["Check printer", "Choose network", "Verify connection"][step - 1])).font(.callout.weight(.medium))
                    }.foregroundStyle(step <= model.setupStep ? Color.teal : Color.secondary)
                    if step < 3 { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
                }
            }.accessibilityElement(children: .combine)
            Label(L(model.snapshot?.usbPresent == true ? "Printer detected over USB" : "Connect the printer by USB"), systemImage: model.snapshot?.usbPresent == true ? "checkmark.circle.fill" : "cable.connector")
            HStack {
                Button(L(model.network == nil ? "Check printer connection" : "Check again")) { Task { await model.checkNetwork() } }
                    .disabled(model.checkingNetwork || model.scanning || model.connecting || model.snapshot?.usbPresent != true)
                if model.checkingNetwork { ProgressView().controlSize(.small); Text("Reading printer settings…").foregroundStyle(.secondary) }
            }
            if let network = model.network {
                LabeledContent("Printer network address", value: network.hasAssignedAddress ? network.address : L("No address assigned"))
                LabeledContent("Printer identity", value: network.macAddress)
                if let checked = model.networkCheckedAt { Text(L("Read from the printer at %@.", checked.formatted(.dateTime.locale(model.language.locale).hour().minute().second()))).font(.caption).foregroundStyle(.secondary) }
            }
            if let error = model.networkError {
                Label(L(error), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("Keep USB connected, close other Epson utilities and retry. If USB stops responding, turn the printer off and on.").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Text("Choose your home network").font(.headline)
                Spacer()
                Button(L(model.networks.isEmpty ? "Find networks" : "Search again")) { Task { await model.scanNetworks() } }
                    .disabled(model.scanning || model.checkingNetwork || model.connecting || model.snapshot?.usbPresent != true)
                if model.scanning { ProgressView().controlSize(.small) }
            }
            if !model.scanStatus.isEmpty { Text(model.scanning || model.networks.isEmpty ? L(model.scanStatus) : L("Found %d networks visible to your printer. Select your home network.", model.networks.count)).font(.caption).foregroundStyle(.secondary) }
            if !model.networks.isEmpty {
                TextField("Search found networks", text: $model.networkSearch).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search found networks")
            }
            if !model.networkSearch.isEmpty, model.networks.allSatisfy({ !$0.ssid.localizedCaseInsensitiveContains(model.networkSearch) }) {
                Text("No matching networks. Clear the search or enter a network name below.").foregroundStyle(.secondary)
            }
            ForEach(model.networks.filter { model.networkSearch.isEmpty || $0.ssid.localizedCaseInsensitiveContains(model.networkSearch) }) { network in
                Button { model.ssid = network.ssid; model.setupStep = 2 } label: {
                    HStack {
                        Image(systemName: model.ssid == network.ssid ? "checkmark.circle.fill" : "wifi")
                        Text(network.ssid)
                        Spacer()
                        Text(network.securityType == 4 ? "WPA2" : L("WPA2 required in this build")).font(.caption).foregroundStyle(.secondary)
                    }.padding(10).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(model.connecting || model.scanning || network.securityType != 4)
                    .background(model.ssid == network.ssid ? Color.teal.opacity(0.12) : Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(L("Select network %@", network.ssid))
            }
            TextField("Wi-Fi network name (SSID)", text: $model.ssid).textFieldStyle(.roundedBorder).accessibilityLabel("Wi-Fi network name").disabled(model.connecting)
            SecureField("Wi-Fi password", text: $model.password).textFieldStyle(.roundedBorder).accessibilityLabel("Wi-Fi password").disabled(model.connecting)
            Text("Your password is sent directly to this printer over USB when you connect. It is never saved by this app or sent to a cloud service.")
                .font(.caption).foregroundStyle(.secondary)
            if !model.ssid.isEmpty, !model.connectionVerified, !model.connecting, let validation { Text(validation).font(.caption).foregroundStyle(.orange) }
            if !model.connectionStatus.isEmpty {
                Label(model.connectionVerified ? L("Connected. Your printer is reachable at %@.", model.network?.address ?? "") : L(model.connectionStatus), systemImage: model.connectionVerified ? "checkmark.circle.fill" : "wifi")
                    .foregroundStyle(model.connectionVerified ? Color.teal : Color.secondary)
            }
            HStack {
                Button("Connect printer to Wi-Fi") { Task { await model.connectWiFi() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(validation != nil || model.snapshot?.usbPresent != true || model.connecting || model.scanning || model.checkingNetwork)
                if model.connecting { ProgressView().controlSize(.small) }
            }
            if model.connectionVerified {
                Text("The printer now uses its own Wi-Fi connection. Setting up a wireless print queue on this Mac is the next step.").foregroundStyle(.secondary)
                Button("Finish setup on this Mac") { model.destination = .overview; Task { await model.refresh(rescan: true) } }.buttonStyle(.borderedProminent)
            }
        }.onDisappear { model.password = "" }
        Card {
            Text("For Google Nest and future routers").font(.headline)
            Text("This printer uses 2.4 GHz and WPA/WPA2. Use the main home network. If a router's WPA3 compatibility mode prevents connection, check its legacy-device settings.")
                .foregroundStyle(.secondary)
        }
    }
}

struct DriverView: View {
    @EnvironmentObject var model: AssistantModel
    var body: some View {
        Card {
            Label(L(model.snapshot?.driver.ready == true ? "Epson driver is installed" : "Epson driver needs attention"), systemImage: "shippingbox.fill").font(.title2.bold())
            Text(L("Installed version: %@", model.snapshot?.driver.version ?? L("Not found")))
            Text(L("Photo raster filter: %@", L(model.snapshot?.driver.filterAvailable == true ? "Available" : "Not found")))
            Divider()
            Text("The app obtains the official Epson driver when needed and verifies its contents and Epson signature before opening the macOS Installer. A previously downloaded installer works offline.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Install Epson driver") { Task { await model.installDriver() } }.buttonStyle(.borderedProminent)
                    .disabled(model.checkingInstaller)
                if model.checkingInstaller { ProgressView().controlSize(.small) }
            }
            Text(model.installerMessage).foregroundStyle(.secondary)
            Text("macOS may ask for an administrator password. You can review Epson's licence in the installer.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct AirPrintView: View {
    @EnvironmentObject var model: AssistantModel
    @ObservedObject var bridge: AirPrintCoordinator
    var body: some View {
        Card {
            Label(L("AirPrint for iPhone and iPad"), systemImage: "iphone.and.arrow.forward").font(.title2.bold())
            Text(L("An eligible Mac running this utility can provide AirPrint for your wireless Epson printer. The app automatically chooses one host; other eligible Macs wait on standby.")).foregroundStyle(.secondary)
            Toggle(L("Enable quiet AirPrint hosting"), isOn: Binding(get: { model.airPrintPreferred }, set: { value in
                model.airPrintPreferred = value
                Task { await model.updateBridge(approveNetwork: value) }
            })).disabled(bridge.busy)
            if bridge.busy { ProgressView().controlSize(.small) }
            Label(bridge.status, systemImage: bridge.hosting ? "checkmark.circle.fill" : "info.circle").foregroundStyle(bridge.hosting ? Color.teal : Color.secondary)
            if model.selectedQueue.isEmpty { Text(L("Add a wireless printer on this Mac first.")).foregroundStyle(.orange) }
            Text(L("Routine hosting is silent. Keep at least one eligible Mac awake with the utility running. macOS may request Local Network or incoming-connection permission.")).font(.caption).foregroundStyle(.secondary)
            Text(L("Experimental: physical iPhone/iPad printing and multi-Mac takeover are not verified yet. Jobs already accepted by an unavailable Mac are not automatically replayed on another Mac.")).font(.caption).foregroundStyle(.orange)
            Text(L("This does not change the printer's firmware or enable global macOS printer sharing. Other people on the reachable home network can submit print jobs while hosting is enabled.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L("Enable on this network")) { Task { await model.updateBridge(approveNetwork: true) } }.disabled(bridge.busy || bridge.enabled || !model.airPrintPreferred)
                Button(L("Menu preferences")) { model.showingMenuPreferences = true }
            }
        }
    }
}

struct QueuePicker: View {
    @EnvironmentObject var model: AssistantModel
    var body: some View {
        if let queues = model.snapshot?.queues, !queues.isEmpty {
            Picker("Printer queue", selection: $model.selectedQueue) {
                ForEach(queues) { Text($0.id).tag($0.id) }
            }.disabled(model.careBusy || model.loadingJobs)
        } else {
            Text("Add a wireless printer on this Mac first.").foregroundStyle(.secondary)
            Button("Your printer") { model.destination = .overview }
        }
    }
}

struct PrintView: View {
    @EnvironmentObject var model: AssistantModel
    var body: some View {
        Card {
            Label("Print a photo or PDF", systemImage: "photo.on.rectangle").font(.title2.bold())
            QueuePicker()
            Text("Use the Epson driver controls in the print dialog for paper size, photo paper, quality, color and borderless options supported by your printer.").foregroundStyle(.secondary)
            if let image = model.documentPreview {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 300)
                    .accessibilityLabel("Selected document preview")
            }
            if let url = model.documentURL { Text(url.lastPathComponent).font(.headline).textSelection(.enabled) }
            HStack {
                Button("Choose photo or PDF") { model.chooseDocument() }
                Button("Print…") { model.printDocument() }.buttonStyle(.borderedProminent)
                    .disabled(model.documentURL == nil || model.selectedQueue.isEmpty)
            }
            if !model.printMessage.isEmpty { Text(model.printMessage).foregroundStyle(.secondary) }
        }
    }
}

struct JobsView: View {
    @EnvironmentObject var model: AssistantModel
    var body: some View {
        Card {
            Label("Print jobs", systemImage: "list.bullet.rectangle").font(.title2.bold())
            QueuePicker()
            Button("Refresh jobs") { Task { await model.refreshJobs() } }.disabled(model.loadingJobs)
            if model.loadingJobs { ProgressView().controlSize(.small) }
            ForEach(model.printJobs) { job in
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L("Job %d", job.id)).font(.headline)
                        Text(job.owner + " · " + ByteCountFormatter.string(fromByteCount: Int64(job.bytes), countStyle: .file)).foregroundStyle(.secondary)
                        Text(job.submitted).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel job", role: .destructive) { model.pendingCancel = job; model.confirmingCancel = true }
                        .disabled(!job.mayCancel || model.loadingJobs)
                }
            }
            if !model.jobsMessage.isEmpty { Text(model.jobsMessage).foregroundStyle(.secondary) }
            Text("Only your own pending jobs can be cancelled here. Pages already sent to the printer may still print.").font(.caption).foregroundStyle(.secondary)
        }
        .task { await model.refreshJobs() }
        .onChange(of: model.selectedQueue) { _ in Task { await model.refreshJobs() } }
        .confirmationDialog(L("Cancel job %d?", model.pendingCancel?.id ?? 0), isPresented: $model.confirmingCancel, titleVisibility: .visible) {
            Button("Cancel job", role: .destructive) { Task { await model.cancelJob() } }
            Button("Keep job", role: .cancel) { model.pendingCancel = nil }
        }
    }
}

struct MaintenanceView: View {
    @EnvironmentObject var model: AssistantModel
    var body: some View {
        Card {
            Label("Printer care", systemImage: "wrench.and.screwdriver").font(.title2.bold())
            Text("Start with a nozzle check. Clean only if the pattern has missing lines.").foregroundStyle(.secondary)
            if let queues = model.snapshot?.queues, !queues.isEmpty {
                Picker("Printer queue", selection: $model.selectedQueue) {
                    ForEach(queues) { Text($0.id).tag($0.id) }
                }.disabled(model.careBusy || model.checkingCare)
                Button("Check available controls") { Task { await model.loadCare() } }
                    .disabled(model.careBusy || model.checkingCare)
            }
            if model.checkingCare || model.careBusy { ProgressView().controlSize(.small) }
            ForEach(model.careActions) { action in
                Divider()
                Text(action.title).font(.headline)
                Text(action.instructions).foregroundStyle(.secondary)
                Button(action.title) {
                    model.pendingCare = action
                    model.confirmCare = true
                }.disabled(model.careBusy || model.checkingCare)
            }
            if !model.careMessage.isEmpty { Text(model.careMessage).textSelection(.enabled).foregroundStyle(.secondary) }
            Button("Open print queue") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Print Center.app"))
            }
            Divider()
            Label("Replace ink cartridges", systemImage: "drop.fill").font(.headline)
            Text("A guided 1500W replacement flow using the printer's ink button. This does not send a carriage-movement command.").foregroundStyle(.secondary)
            Button("Replace cartridges…") { model.replacementStep = 0; model.showingReplacement = true }
                .disabled(model.careBusy || model.snapshot?.queues.isEmpty != false)
            Text("Alignment and power settings require separate model-specific commands and are still under verification.").font(.caption).foregroundStyle(.secondary)
        }
        .task { await model.loadCare() }
        .onChange(of: model.selectedQueue) { _ in Task { await model.loadCare() } }
        .confirmationDialog(model.pendingCare?.title ?? L("Printer care"), isPresented: $model.confirmCare, titleVisibility: .visible) {
            Button(model.pendingCare?.title ?? L("Continue")) { Task { await model.performCare() } }
            Button("Cancel", role: .cancel) { model.pendingCare = nil }
        } message: { Text(model.pendingCare?.instructions ?? "") }
    }
}

struct MenuPreferencesView: View {
    @ObservedObject var model: AssistantModel
    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 18) {
                Text(L("Make the menu yours")).font(.title2.bold())
                Text(L("Keep the controls you use most close at hand.")).foregroundStyle(.secondary)
                Toggle(L("Show in menu bar"), isOn: $model.showMenuBar)
                Toggle(L("Show ink levels"), isOn: $model.menuShowsInk)
                Toggle(L("Show Wi-Fi setup shortcut"), isOn: $model.menuShowsSetup)
                Text(L("The preview uses your printer's current readings. Cached ink data is labelled.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Done")) { model.showingMenuPreferences = false }.buttonStyle(.borderedProminent)
            }.frame(width: 230)
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Menu preview")).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                PrinterQuickPanel(model: model, discovery: model.discovery) { destination in
                    model.destination = destination
                    model.showingMenuPreferences = false
                }.clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.08)))
            }
        }.padding(28).frame(height: 620)
    }
}

struct CartridgeReplacementView: View {
    @EnvironmentObject var model: AssistantModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Image(systemName: "drop.fill").font(.title).foregroundStyle(.teal)
                Text(L("Replace ink cartridges")).font(.title2.bold())
            }
            Text(L("Epson Stylus Photo 1500 / 1500W")).foregroundStyle(.secondary)
            ProgressView(value: Double(model.replacementStep + 1), total: Double(CartridgeGuide.titles.count))
            Text(L("Step %d of %d", model.replacementStep + 1, CartridgeGuide.titles.count)).font(.caption).foregroundStyle(.secondary)
            Text(L(CartridgeGuide.titles[model.replacementStep])).font(.title3.bold())
            Text(L(CartridgeGuide.instructions[model.replacementStep])).fixedSize(horizontal: false, vertical: true)
            Text(L("Advance only after you have completed the physical step. The app cannot verify carriage movement yet.")).font(.caption).foregroundStyle(.secondary)
            Link(L("Epson's illustrated replacement guide"), destination: URL(string: "https://support.epson-europe.com/onlineguides/en/sp1500w/html/ink_3.htm")!)
            Spacer(minLength: 0)
            HStack {
                Button(L("Close guide")) { model.showingReplacement = false }
                Spacer()
                if model.replacementStep > 0 { Button(L("Back")) { model.replacementStep -= 1 } }
                if model.replacementStep + 1 < CartridgeGuide.titles.count {
                    Button(L("I completed this step")) { model.replacementStep += 1 }.buttonStyle(.borderedProminent)
                } else {
                    Button(L("Finish guide")) { model.showingReplacement = false }.buttonStyle(.borderedProminent)
                }
            }
        }.padding(30).frame(width: 600, height: 430)
    }
}

struct PowerView: View {
    @EnvironmentObject var model: AssistantModel
    var body: some View {
        Card {
            Label("Keep the printer available", systemImage: "power").font(.title2.bold())
            Text("Always on disables the printer's automatic power-off timer. The printer can still enter its normal sleep mode.").foregroundStyle(.secondary)
            Picker("Automatic power-off", selection: $model.powerTimer) {
                ForEach(PowerOffTimer.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.menu)
            Text("Current printer setting: Not read yet").font(.caption).foregroundStyle(.secondary)
            Button("Apply to printer") {}.buttonStyle(.borderedProminent).disabled(true)
            Text("These are the model's documented options. The control will be enabled after setting and readback are verified on the hardware.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct DevelopmentCard: View {
    let title: String
    let message: String
    let symbol: String
    var body: some View { Card { Label(L(title), systemImage: symbol).font(.title2.bold()); Text(L(message)).foregroundStyle(.secondary) } }
}

struct DiagnosticsView: View {
    @EnvironmentObject var model: AssistantModel
    var body: some View {
        Card {
            Text("Connection checks").font(.title2.bold())
            if let snapshot = model.snapshot {
                LabeledContent("Mac", value: snapshot.systemVersion)
                LabeledContent("USB hardware", value: L(snapshot.usbPresent ? "Epson 1500 detected" : "Not detected"))
                LabeledContent("Matching printer queues", value: "\(snapshot.queues.count)")
                Divider()
                Text(snapshot.status).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                ForEach(snapshot.warnings, id: \.self) { warning in
                    Label(L(warning), systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
                Text("USB-free Wi-Fi printing and settings persistence were verified on a 1500W. Mobile printing and additional models still need hardware verification.").foregroundStyle(.secondary)
            } else { ProgressView("Checking your printer…") }
        }
    }
}
