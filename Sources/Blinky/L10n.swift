import Foundation

/// Localized string from Localizable.strings. Keys are the English texts,
/// so English needs no table and a missing translation falls back to English.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// Localized format string with arguments: `L("Paused until %@", time)`.
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), locale: Locale.current, arguments: args)
}

/// App language override (System / English / Russian). Applied on next launch.
enum AppLanguage {
    static let options: [(code: String, title: String)] = [
        ("", "System"), ("en", "English"), ("ru", "Русский"),
    ]

    static var current: String {
        // Only the app's own override counts, not the system-wide language list.
        let own = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
        return (own?["AppleLanguages"] as? [String])?.first.flatMap { code in
            options.first { !$0.code.isEmpty && code.hasPrefix($0.code) }?.code
        } ?? ""
    }

    static func set(_ code: String) {
        if code.isEmpty {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        }
    }
}
