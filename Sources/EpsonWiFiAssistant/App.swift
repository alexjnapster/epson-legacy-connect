import SwiftUI
import PrinterCore

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
        WindowGroup("Epson Legacy Connect") {
            ContentView().environmentObject(model)
                .environment(\.locale, model.language.locale)
                .frame(minWidth: 900, minHeight: 660)
                .task { await model.refresh() }
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1080, height: 760)
    }
}

enum Destination: String, CaseIterable, Identifiable {
    case overview = "Your printer", wifi = "Wi-Fi setup", driver = "Printer driver"
    case maintenance = "Maintenance", power = "Power", diagnostics = "Diagnostics"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: return "printer"
        case .wifi: return "wifi"
        case .driver: return "shippingbox"
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
    @Published var destination: Destination? = .overview
    @Published var snapshot: PrinterSnapshot?
    @Published var refreshing = false
    @Published var ssid = ""
    @Published var password = ""
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
    @Published var queueMessage = ""
    @Published var addingQueue = false
    @Published var cancelAddingQueue = false
    @Published var preparingUSB = false
    @Published var showingUSBLicence = false
    @Published var usbLicenceText = ""
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
                guard FileManager.default.fileExists(atPath: profile.ppdPath) else { throw ComponentFiles.failure("Driver installation was not confirmed. You can retry after completing the installer.") }
            } catch { queueMessage = error.localizedDescription; return }
        }
        queueMessage = L("Adding and verifying the wireless print queue…")
        let result = await Task.detached { Result { try WirelessQueue.install(host: printer.host, model: printer.model) } }.value
        switch result {
        case .success: queueMessage = L("The wireless printer is ready on this Mac."); await refresh()
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
        guard !scanning, !checkingNetwork else { return }
        scanning = true
        networkError = nil
        scanStatus = "Asking the printer to search for networks…"
        let result = await Task.detached { () -> Result<[WirelessNetwork], Error> in
            Result {
                guard let path = USBConfiguration.bundledComponent() else { throw ConfigurationError.componentMissing }
                let configuration = USBConfiguration(componentPath: path)
                guard let printer = try configuration.printers().first else { throw ConfigurationError.noPrinter }
                try configuration.startWirelessScan(printer)
                for _ in 0..<15 {
                    Thread.sleep(forTimeInterval: 1)
                    let networks = try configuration.wirelessNetworks(printer)
                    if !networks.isEmpty { return networks }
                }
                return []
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
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        discovery.start()
        let result = await Task.detached { PrinterDiagnostics.capture() }.value
        snapshot = result
        refreshing = false
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AssistantModel
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 10) {
                    Image(systemName: "printer.filled").font(.title2).foregroundStyle(.teal)
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
                    Text("Legacy Connect").font(.caption.weight(.semibold))
                    Text("Development build · Hardware testing in progress")
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
                        Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                            .disabled(model.refreshing)
                    }
                    switch model.destination ?? .overview {
                    case .overview: OverviewView(discovery: model.discovery)
                    case .wifi: WiFiView()
                    case .driver: DriverView()
                    case .maintenance: DevelopmentCard(title: "Printer care", message: "Nozzle checks, head cleaning, alignment and ink status will be integrated after their commands are verified against this printer.", symbol: "wrench.and.screwdriver")
                    case .power: PowerView()
                    case .diagnostics: DiagnosticsView()
                    }
                }.padding(32).frame(maxWidth: 1100, alignment: .leading)
            }.background(Color(nsColor: .windowBackgroundColor))
        }.tint(.teal)
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
        NetworkPrintersView(discovery: model.discovery)
        Card {
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
                Text(L(wifiDetected ? "Network printer discovered. Add it to this Mac to start printing." : (model.network == nil ? "Read the printer's own settings to check its connection." : "Network address read directly from the printer over USB."))).foregroundStyle(.secondary)
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
                    Button("Add to this Mac") { Task { await model.addPrinter(printer) } }
                        .buttonStyle(.borderedProminent).disabled(model.addingQueue)
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
                        Text(network.securityType == 4 ? "WPA2" : L("Security mode %d", network.securityType)).font(.caption).foregroundStyle(.secondary)
                    }.padding(10).contentShape(Rectangle())
                }.buttonStyle(.plain)
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
                    Label(warning, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
                Text("Wi-Fi provisioning and mobile printing have not passed end-to-end verification yet.").foregroundStyle(.secondary)
            } else { ProgressView("Checking your printer…") }
        }
    }
}
