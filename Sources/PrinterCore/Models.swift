import Foundation

public struct PrinterQueue: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let uri: String
    public var isUSB: Bool { uri.hasPrefix("usb://") }
    public var isNetwork: Bool { ["dnssd://", "lpd://", "socket://", "ipp://", "ipps://"].contains { uri.hasPrefix($0) } }

    public static func parse(_ output: String) -> [PrinterQueue] {
        output.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("device for "), let split = line.range(of: ": ") else { return nil }
            let name = String(line[line.index(line.startIndex, offsetBy: 11)..<split.lowerBound])
            let uri = String(line[split.upperBound...])
            guard name.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
                  !uri.isEmpty else { return nil }
            return PrinterQueue(id: name, uri: uri)
        }
    }
}

public struct InkLevel: Identifiable, Codable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    /// nil means the driver did not supply a valid measured percentage.
    public let percent: Int?

    public static func parse(names: String?, levels: String?) -> [InkLevel] {
        guard let names, let levels else { return [] }
        let labels = names.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let values = levels.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard labels.count == values.count else { return [] }
        return zip(labels, values).map { name, value in
            let number = Int(value.trimmingCharacters(in: .whitespaces))
            return InkLevel(name: name.trimmingCharacters(in: .whitespaces),
                            percent: number.flatMap { (0...100).contains($0) ? $0 : nil })
        }
    }
}

public enum PowerOffTimer: Int, CaseIterable, Identifiable, Codable, Sendable {
    case alwaysOn = 0, twoHours = 2, fourHours = 4, eightHours = 8, twelveHours = 12
    public var id: Int { rawValue }
    public var label: String { self == .alwaysOn ? L("Always on") : L("After %d hours", rawValue) }
}

public enum WiFiValidationError: LocalizedError, Equatable {
    case emptySSID, ssidTooLong, invalidPassword, invalidSSID
    public var errorDescription: String? {
        switch self {
        case .emptySSID: return L("Enter your Wi-Fi network name.")
        case .ssidTooLong: return L("The Wi-Fi name must fit within 32 UTF-8 bytes.")
        case .invalidSSID: return L("The Wi-Fi name contains an unsupported control character.")
        case .invalidPassword: return L("Use an 8–63 character WPA/WPA2 password, or a 64-digit hexadecimal key.")
        }
    }
}

public enum WiFiCredentials {
    public static func validate(ssid: String, password: String) throws {
        guard !ssid.isEmpty else { throw WiFiValidationError.emptySSID }
        guard ssid.utf8.count <= 32 else { throw WiFiValidationError.ssidTooLong }
        guard !ssid.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw WiFiValidationError.invalidSSID
        }
        let bytes = Array(password.utf8)
        let passphrase = (8...63).contains(bytes.count) && bytes.allSatisfy { (32...126).contains($0) }
        let hex = bytes.count == 64 && bytes.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
        guard passphrase || hex else { throw WiFiValidationError.invalidPassword }
    }
}
