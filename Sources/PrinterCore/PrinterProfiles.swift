import Foundation

public struct PrinterProfile: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let aliases: [String]
    public let ppdName: String
    public let wifiHardwareVerified: Bool
    public var ppdPath: String { "/Library/Printers/PPDs/Contents/Resources/" + ppdName + ".gz" }
}

public enum PrinterProfiles {
    public static let all: [PrinterProfile] = [
        .init(id: "photo-1500", name: "Epson Stylus Photo 1500W", aliases: ["Epson Stylus Photo 1500", "Epson Stylus Photo 1500W", "SP 1500 Series"], ppdName: "EPSON Epson Stylus Photo 1500", wifiHardwareVerified: true),
        .init(id: "photo-1430", name: "Epson Stylus Photo 1430", aliases: ["Epson Stylus Photo 1430"], ppdName: "EPSON Epson Stylus Photo 1430", wifiHardwareVerified: false),
        .init(id: "artisan-1430", name: "Epson Artisan 1430", aliases: ["Artisan 1430"], ppdName: "EPSON Artisan 1430", wifiHardwareVerified: false),
        .init(id: "artisan-730", name: "Epson Artisan 730", aliases: ["Artisan 730"], ppdName: "EPSON Artisan 730", wifiHardwareVerified: false),
        .init(id: "artisan-837", name: "Epson Artisan 837", aliases: ["Artisan 837"], ppdName: "EPSON Artisan 837", wifiHardwareVerified: false),
        .init(id: "xp-600", name: "Epson XP-600", aliases: ["XP-600 Series"], ppdName: "EPSON XP-600 Series", wifiHardwareVerified: false),
        .init(id: "xp-700", name: "Epson XP-700", aliases: ["XP-700 Series"], ppdName: "EPSON XP-700 Series", wifiHardwareVerified: false),
        .init(id: "xp-750", name: "Epson XP-750", aliases: ["XP-750 Series"], ppdName: "EPSON XP-750 Series", wifiHardwareVerified: false),
        .init(id: "xp-800", name: "Epson XP-800", aliases: ["XP-800 Series"], ppdName: "EPSON XP-800 Series", wifiHardwareVerified: false),
        .init(id: "xp-850", name: "Epson XP-850", aliases: ["XP-850 Series"], ppdName: "EPSON XP-850 Series", wifiHardwareVerified: false)
    ]
    public static func match(_ model: String) -> PrinterProfile? {
        func normalize(_ text: String) -> String {
            var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            while value.hasPrefix("epson ") { value.removeFirst(6) }
            return value
        }
        let candidate = normalize(model)
        return all.first { profile in profile.aliases.contains { normalize($0) == candidate } }
    }
}
