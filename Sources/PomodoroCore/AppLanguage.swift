public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case russian = "ru"
    case english = "en"

    public var nativeName: String { self == .russian ? "Русский" : "English" }
    public func text(_ russian: String, _ english: String) -> String {
        self == .russian ? russian : english
    }
}
