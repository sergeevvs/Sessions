public enum StatusItemField: String, Codable, CaseIterable, Sendable {
    case symbol, phase, time, sessions

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if value == "completed" || value == "goal" {
            self = .sessions
        } else if let field = Self(rawValue: value) {
            self = field
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown status item field")
        }
    }
}

public struct PomodoroSettings: Codable, Equatable, Sendable {
    public var language: AppLanguage
    public var theme: AppTheme
    public var workMinutes: Int
    public var shortBreakMinutes: Int
    public var longBreakMinutes: Int
    public var longBreakEnabled: Bool
    public var longBreakInterval: Int
    public var dailyGoal: Int
    public var automaticTransitions: Bool
    public var soundEnabled: Bool
    public var notificationsEnabled: Bool
    public var statusItemFields: Set<StatusItemField>

    public init(language: AppLanguage = .english, theme: AppTheme = .system,
                workMinutes: Int = 25, shortBreakMinutes: Int = 5,
                longBreakMinutes: Int = 15, longBreakEnabled: Bool = true,
                longBreakInterval: Int = 4, dailyGoal: Int = 8,
                automaticTransitions: Bool = false, soundEnabled: Bool = true,
                notificationsEnabled: Bool = true,
                statusItemFields: Set<StatusItemField> = [.time]) {
        self.language = language
        self.theme = theme
        self.workMinutes = workMinutes
        self.shortBreakMinutes = shortBreakMinutes
        self.longBreakMinutes = longBreakMinutes
        self.longBreakEnabled = longBreakEnabled
        self.longBreakInterval = longBreakInterval
        self.dailyGoal = dailyGoal
        self.automaticTransitions = automaticTransitions
        self.soundEnabled = soundEnabled
        self.notificationsEnabled = notificationsEnabled
        self.statusItemFields = statusItemFields
    }

    private enum CodingKeys: String, CodingKey {
        case language, theme, workMinutes, shortBreakMinutes, longBreakMinutes, longBreakEnabled
        case longBreakInterval, dailyGoal, automaticTransitions, soundEnabled
        case notificationsEnabled, statusItemFields
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        language = (try? values.decode(AppLanguage.self, forKey: .language)) ?? language
        theme = (try? values.decode(AppTheme.self, forKey: .theme)) ?? theme
        workMinutes = (try? values.decode(Int.self, forKey: .workMinutes)) ?? workMinutes
        shortBreakMinutes = (try? values.decode(Int.self, forKey: .shortBreakMinutes)) ?? shortBreakMinutes
        longBreakMinutes = (try? values.decode(Int.self, forKey: .longBreakMinutes)) ?? longBreakMinutes
        longBreakEnabled = (try? values.decode(Bool.self, forKey: .longBreakEnabled)) ?? longBreakEnabled
        longBreakInterval = (try? values.decode(Int.self, forKey: .longBreakInterval)) ?? longBreakInterval
        dailyGoal = (try? values.decode(Int.self, forKey: .dailyGoal)) ?? dailyGoal
        automaticTransitions = (try? values.decode(Bool.self, forKey: .automaticTransitions)) ?? automaticTransitions
        soundEnabled = (try? values.decode(Bool.self, forKey: .soundEnabled)) ?? soundEnabled
        notificationsEnabled = (try? values.decode(Bool.self, forKey: .notificationsEnabled)) ?? notificationsEnabled
        statusItemFields = (try? values.decode(Set<StatusItemField>.self, forKey: .statusItemFields)) ?? statusItemFields
        self = validated()
    }

    public func validated() -> PomodoroSettings {
        var result = self
        result.workMinutes = min(max(workMinutes, 1), 180)
        result.shortBreakMinutes = min(max(shortBreakMinutes, 1), 60)
        result.longBreakMinutes = min(max(longBreakMinutes, 1), 120)
        result.longBreakInterval = min(max(longBreakInterval, 2), 12)
        result.dailyGoal = min(max(dailyGoal, 1), 24)
        if result.statusItemFields.isEmpty { result.statusItemFields = [.time] }
        return result
    }
}
