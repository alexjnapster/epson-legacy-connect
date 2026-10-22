import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english = "en", ukrainian = "uk"
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .system: return L("System language")
        case .english: return "English"
        case .ukrainian: return "Українська"
        }
    }
    public var locale: Locale {
        Locale(identifier: self == .system ? Locale.preferredLanguages.first ?? "en" : rawValue)
    }
}

/// The app's own language setting never changes the macOS language preference.
public func L(_ key: String, _ arguments: CVarArg...) -> String {
    let selected = UserDefaults.standard.string(forKey: "assistant.language") ?? "system"
    let language = selected == "system" ? (Locale.preferredLanguages.first?.hasPrefix("uk") == true ? "uk" : "en") : selected
    let bundle = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? Bundle.main
    let value = bundle.localizedString(forKey: key, value: key, table: nil)
    return arguments.isEmpty ? value : String(format: value, locale: Locale(identifier: language), arguments: arguments)
}
