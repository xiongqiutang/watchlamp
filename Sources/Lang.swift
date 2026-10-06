import Foundation

/// UI language. Follows the system unless picked in the menu; strings live in Resources/<code>.lproj.
enum Lang {
    static let choices: [(code: String, name: String)] = [
        ("en", "English"), ("de", "Deutsch"), ("es", "Español"), ("fr", "Français"), ("it", "Italiano"),
        ("pt-BR", "Português (Brasil)"), ("ru", "Русский"), ("ar", "العربية"),
        ("ja", "日本語"), ("ko", "한국어"), ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"),
    ]
    private(set) static var bundle = Bundle.main
    private(set) static var code: String?

    /// The language the menus are shown in.
    static var active: String { code ?? Bundle.main.preferredLocalizations.first ?? "en" }

    /// Right-to-left languages (Arabic) mirror the board.
    static var rtl: Bool { NSLocale.characterDirection(forLanguage: active) == .rightToLeft }

    #if DEVTOOLS
    static func use(lprojAt path: String) {
        guard let picked = Bundle(path: path) else { return }
        bundle = picked
        code = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
    #endif

    /// `nil` follows the system's preferred languages.
    static func use(_ code: String?) {
        if let code, let path = Bundle.main.path(forResource: code, ofType: "lproj"), let picked = Bundle(path: path) {
            bundle = picked
            self.code = code
        } else {
            bundle = .main
            self.code = nil
        }
    }
}

/// Localized string; the English text is the key, so a missing translation shows English.
func L(_ key: String) -> String { Lang.bundle.localizedString(forKey: key, value: key, table: nil) }
func L(_ key: String, _ args: CVarArg...) -> String { String(format: L(key), arguments: args) }
