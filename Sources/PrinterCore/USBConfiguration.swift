import Foundation
import NativeUSB

public struct USBPrinter: Identifiable, Sendable {
    public let id: String
    public let model: String
    public let address: Data
}

public struct NetworkState: Codable, Sendable {
    public let macAddress: String
    public let address: String
    public let addressMode: String
    public let hardwareType: String
    public var hasAssignedAddress: Bool { !address.isEmpty && address != "0.0.0.0" }
}

public struct WirelessNetwork: Identifiable, Sendable {
    public var id: String { "\(ssid):\(securityType)" }
    public let ssid: String
    public let securityType: Int
    public let signal: Int
}

public struct WirelessState: Sendable {
    public let ssid: String
    public let signal: Int
    public let setupProcess: Int
}

public enum WirelessScanStatus: Int, Sendable {
    case running = 1, complete = 2
    public static func parse(_ reply: Data) throws -> WirelessScanStatus {
        let groups = try ConfigurationResponse.parse(reply)
        guard let value = groups["ijcp:SSIDScan"]?["ijcp:SSIDScan"], let code = Int(value),
              let status = Self(rawValue: code) else {
            throw ComponentFiles.failure("The printer could not complete its Wi-Fi scan. Try searching again.")
        }
        return status
    }
}

public enum ConfigurationError: LocalizedError {
    case componentMissing, invalidReply, printerRejected, unsupportedModel, noPrinter
    public var errorDescription: String? {
        switch self {
        case .componentMissing: return L("The verified Epson USB setup component is missing from this app.")
        case .invalidReply: return L("The printer returned an invalid configuration response.")
        case .printerRejected: return L("The printer did not accept this configuration request.")
        case .unsupportedModel: return L("This USB device is not a supported Epson Stylus Photo 1500.")
        case .noPrinter: return L("No supported Epson printer was found over USB.")
        }
    }
}

public struct USBConfiguration {
    public let componentPath: String
    public init(componentPath: String) { self.componentPath = componentPath }

    public static func bundledComponent() -> String? {
        let candidates: [String?] = [Bundle.main.resourceURL?.appendingPathComponent("Vendor/XIOCBTm.plugin").path,
            "/Applications/Epson Software/Epson Connect Printer Setup.app/Contents/PlugIns/BS/XIOCBTm.plugin"]
        if let existing = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0) }) { return existing }
        let cached = ComponentFiles.directory.appendingPathComponent("XIOCBTm.plugin").path
        return UserDefaults.standard.string(forKey: "assistant.usbLicence") == ComponentFiles.usbConsentVersion && FileManager.default.fileExists(atPath: cached) ? cached : nil
    }

    public func printers() throws -> [USBPrinter] {
        var error: NSError?
        guard let data = EWEnumerate(componentPath, &error) else { throw error ?? ConfigurationError.invalidReply as NSError }
        guard let result = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let printers = result["InfoPrinterList"] as? [[String: Any]] else { throw ConfigurationError.invalidReply }
        return printers.compactMap { item -> USBPrinter? in
            guard let name = item["InfoPrinterName"] as? String,
                  PrinterProfiles.match(name) != nil,
                  let address = item["InfoAddress"] as? Data,
                  let id = item["InfoTargetName"] as? String else { return nil }
            return USBPrinter(id: id, model: name, address: address)
        }
    }

    public static func readRequest(groups: [String], messageID: UUID = UUID()) throws -> Data {
        guard !groups.isEmpty, groups.allSatisfy({ $0.range(of: #"^[A-Za-z][A-Za-z0-9]*$"#, options: .regularExpression) != nil }) else {
            throw ConfigurationError.invalidReply
        }
        let names = groups.map { "<wec:Name>ijcp:\($0)</wec:Name>" }.joined()
        return Data("""
        <?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope" xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:wec="http://schemas.epson.net/ws/2008/07/config" xmlns:ijcp="http://schemas.epson.net/ws/2008/07/config-data/ijcp"><soap:Header><wsa:Action>http://schemas.epson.net/ws/2008/07/config/GetData</wsa:Action><wsa:MessageID>urn:uuid:\(messageID.uuidString)</wsa:MessageID></soap:Header><soap:Body><wec:GetDataRequest><wec:RequestedDataSet>\(names)</wec:RequestedDataSet></wec:GetDataRequest></soap:Body></soap:Envelope>
        """.utf8)
    }

    public func readNetwork(_ printer: USBPrinter) throws -> NetworkState {
        let reply = try readData(printer, groups: ["NWDataInfo"])
        let groups = try ConfigurationResponse.parse(reply, expectedResponse: "GetDataResponse")
        guard let fields = groups["ijcp:NWDataInfo"],
              let address = fields["ijcp:IPAddress"], let mac = fields["ijcp:MACAddress"] else {
            throw ConfigurationError.invalidReply
        }
        return NetworkState(macAddress: mac, address: address,
                            addressMode: fields["ijcp:IPAddressMode"] ?? "",
                            hardwareType: fields["ijcp:HardwareType"] ?? "")
    }

    public func readData(_ printer: USBPrinter, groups: [String]) throws -> Data {
        let request = try Self.readRequest(groups: groups)
        return try exchange(printer, request: request)
    }

    private func exchange(_ printer: USBPrinter, request: Data) throws -> Data {
        var error: NSError?
        guard let reply = EWExchange(componentPath, printer.address, request, &error) else { throw error ?? ConfigurationError.invalidReply as NSError }
        return reply
    }

    /// Reconstructed from EpsonNet Setup's IJCP serializer. XML APIs escape
    /// all values, including ampersands in network names and passwords.
    public static func setRequest(groups: [(String, [(String, String)])]) throws -> Data {
        let namePattern = #"^[A-Za-z][A-Za-z0-9]*$"#
        guard !groups.isEmpty else { throw ConfigurationError.invalidReply }
        let data = XMLElement(name: "Data", uri: "http://schemas.epson.net/ws/2008/07/config-data")
        data.addNamespace(XMLNode.namespace(withName: "", stringValue: "http://schemas.epson.net/ws/2008/07/config-data") as! XMLNode)
        data.addNamespace(XMLNode.namespace(withName: "ijcp", stringValue: "http://schemas.epson.net/ws/2008/07/config-data/ijcp") as! XMLNode)
        for (name, fields) in groups {
            guard name.range(of: namePattern, options: .regularExpression) != nil, !fields.isEmpty else { throw ConfigurationError.invalidReply }
            let group = XMLElement(name: "Group")
            group.addAttribute(XMLNode.attribute(withName: "id", stringValue: "ijcp:\(name)") as! XMLNode)
            for (key, value) in fields {
                guard key.range(of: namePattern, options: .regularExpression) != nil else { throw ConfigurationError.invalidReply }
                let field = XMLElement(name: "d", stringValue: value)
                field.addAttribute(XMLNode.attribute(withName: "id", stringValue: "ijcp:\(key)") as! XMLNode)
                group.addChild(field)
            }
            data.addChild(group)
        }
        return Data("""
        <?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope" xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:wec="http://schemas.epson.net/ws/2008/07/config"><soap:Header><wsa:Action>http://schemas.epson.net/ws/2008/07/config/SetData</wsa:Action><wsa:MessageID>urn:uuid:\(UUID().uuidString)</wsa:MessageID></soap:Header><soap:Body><wec:SetDataRequest>\(data.xmlString)</wec:SetDataRequest></soap:Body></soap:Envelope>
        """.utf8)
    }

    public func startWirelessScan(_ printer: USBPrinter) throws {
        let request = try Self.setRequest(groups: [("SSIDScan", [("SSIDScan", "1")])])
        let reply = try exchange(printer, request: request)
        let groups = try ConfigurationResponse.parse(reply, expectedResponse: "SetDataResponse")
        guard groups["ijcp:SSIDScan"] != nil else { throw ConfigurationError.invalidReply }
    }

    public func wirelessScanStatus(_ printer: USBPrinter) throws -> WirelessScanStatus {
        try WirelessScanStatus.parse(readData(printer, groups: ["SSIDScan"]))
    }

    public static func wifiRequest(ssid: String, password: String) throws -> Data {
        try WiFiCredentials.validate(ssid: ssid, password: password)
        // Observed infrastructure APs report WlanType=0, WPA2=4. Epson's
        // converter maps EnableWirelessLAN directly to LanMode and AutoIP to 0.
        return try setRequest(groups: [
            ("NWDataInfo", [("LanMode", "1"), ("IPAddressMode", "0")]),
            ("WLANDataInfo", [("WlanType", "0"), ("SSIDEdit", ssid),
                              ("AssociationMode", "0"), ("SecurityType", "4"), ("SecurityKey", password)])
        ])
    }

    public func configureWiFi(_ printer: USBPrinter, ssid: String, password: String) throws {
        guard PrinterProfiles.match(printer.model)?.wifiHardwareVerified == true else { throw ConfigurationError.unsupportedModel }
        let request = try Self.wifiRequest(ssid: ssid, password: password)
        let reply = try exchange(printer, request: request)
        let groups = try ConfigurationResponse.parse(reply, expectedResponse: "SetDataResponse")
        guard groups["ijcp:NWDataInfo"] != nil, groups["ijcp:WLANDataInfo"] != nil else { throw ConfigurationError.invalidReply }
    }

    public func readWirelessState(_ printer: USBPrinter) throws -> WirelessState {
        let reply = try readData(printer, groups: ["WLANDataInfo"])
        let groups = try ConfigurationResponse.parse(reply)
        guard let fields = groups["ijcp:WLANDataInfo"], let ssid = fields["ijcp:SSIDCurrent"] else { throw ConfigurationError.invalidReply }
        // Deliberately discard SecurityKey. It never enters the UI model or logs.
        return WirelessState(ssid: ssid, signal: fields["ijcp:SignalLevel"].flatMap(Int.init) ?? 0,
                             setupProcess: fields["ijcp:WlanSetupProcess"].flatMap(Int.init) ?? -1)
    }

    public func wirelessNetworks(_ printer: USBPrinter) throws -> [WirelessNetwork] {
        let reply = try readData(printer, groups: ["SSIDList"])
        guard reply.count <= 1024 * 1024, !String(decoding: reply, as: UTF8.self).uppercased().contains("<!DOCTYPE") else { throw ConfigurationError.invalidReply }
        let document = try XMLDocument(data: reply, options: .nodeLoadExternalEntitiesNever)
        let lists = try document.nodes(forXPath: "//*[local-name()='List' and @id='ijcp:SSIDList']")
        guard lists.count == 1, let list = lists.first as? XMLElement,
              list.uri == "http://schemas.epson.net/ws/2008/07/config-data",
              list.attribute(forName: "return")?.stringValue == "true" else { throw ConfigurationError.printerRejected }
        var networks: [String: WirelessNetwork] = [:]
        for node in list.children ?? [] {
            guard let group = node as? XMLElement, group.localName == "Group",
                  group.attribute(forName: "id")?.stringValue == "ijcp:SSIDInfo" else { continue }
            var fields: [String: String] = [:]
            for case let field as XMLElement in group.children ?? [] where field.localName == "d" {
                if let id = field.attribute(forName: "id")?.stringValue { fields[id] = field.stringValue }
            }
            guard let ssid = fields["ijcp:SSID"], !ssid.isEmpty,
                  let security = fields["ijcp:SecurityType"].flatMap(Int.init) else { continue }
            let item = WirelessNetwork(ssid: ssid, securityType: security, signal: fields["ijcp:SignalLevel"].flatMap(Int.init) ?? 0)
            if networks[item.id].map({ $0.signal >= item.signal }) != true { networks[item.id] = item }
        }
        return networks.values.sorted { $0.signal > $1.signal }
    }
}

/// Parser for Epson's actual IJCP response format. It rejects SOAP faults,
/// rejected groups, invalid roots and malformed XML before returning any values.
public final class ConfigurationResponse: NSObject, XMLParserDelegate {
    private var groups: [String: [String: String]] = [:]
    private var group: String?
    private var field: String?
    private var value = ""
    private var rejected = false
    private var sawResponse = false
    private var depth = 0
    private var fieldDepth = 0
    private var validEnvelope = false
    private var bodyDepth = 0
    private var responseDepth = 0
    private var dataDepth = 0
    private var groupDepth = 0
    private var expectedResponse = "GetDataResponse"

    public static func parse(_ data: Data, expectedResponse: String = "GetDataResponse") throws -> [String: [String: String]] {
        guard data.count <= 1024 * 1024,
              !String(decoding: data, as: UTF8.self).uppercased().contains("<!DOCTYPE") else {
            throw ConfigurationError.invalidReply
        }
        let delegate = ConfigurationResponse()
        delegate.expectedResponse = expectedResponse
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.validEnvelope else { throw ConfigurationError.invalidReply }
        guard !delegate.rejected else { throw ConfigurationError.printerRejected }
        guard delegate.sawResponse else { throw ConfigurationError.invalidReply }
        return delegate.groups
    }

    public func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        if depth == 1 {
            validEnvelope = element == "Envelope" && namespaceURI == "http://www.w3.org/2003/05/soap-envelope"
        }
        if depth == 2, element == "Body", namespaceURI == "http://www.w3.org/2003/05/soap-envelope" { bodyDepth = depth }
        if element == "Fault", namespaceURI == "http://www.w3.org/2003/05/soap-envelope" { rejected = true }
        if ["GetDataResponse", "SetDataResponse"].contains(element), namespaceURI == "http://schemas.epson.net/ws/2008/07/config" {
            guard bodyDepth == 2, depth == 3, !sawResponse, element == expectedResponse else { rejected = true; return }
            sawResponse = true; responseDepth = depth
        }
        if element == "Data", namespaceURI == "http://schemas.epson.net/ws/2008/07/config-data", responseDepth == 3, depth == 4 { dataDepth = depth }
        if element == "Group", namespaceURI == "http://schemas.epson.net/ws/2008/07/config-data" {
            guard dataDepth == 4, depth == 5, let id = attributes["id"], id.hasPrefix("ijcp:"), group == nil else { rejected = true; return }
            guard attributes["return"] == "true" else { rejected = true; return }
            group = id
            groupDepth = depth
            if groups[id] != nil { rejected = true }
            groups[id] = [:]
        }
        if element == "d", namespaceURI == "http://schemas.epson.net/ws/2008/07/config-data", group != nil {
            guard depth == groupDepth + 1, field == nil, let id = attributes["id"], id.hasPrefix("ijcp:") else { rejected = true; return }
            if let result = attributes["return"], result != "true" { rejected = true; return }
            field = id
            fieldDepth = depth
            value = ""
        }
    }
    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        if field != nil { value += string }
    }
    public func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        if element == "d", depth == fieldDepth, let group, let field {
            if groups[group]?[field] != nil { rejected = true }
            groups[group]?[field] = value
            self.field = nil
        }
        if element == "Group", depth == groupDepth { group = nil; groupDepth = 0 }
        if element == "Data", depth == dataDepth { dataDepth = 0 }
        if depth == responseDepth { responseDepth = 0 }
        if element == "Body", depth == bodyDepth { bodyDepth = 0 }
        depth -= 1
    }
}
