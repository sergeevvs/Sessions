public struct CycleSummary: Equatable, Sendable {
    public let workMinutes: Int
    public let breakMinutes: Int
    public let totalMinutes: Int
    public let shortBreakCount: Int
    public let longBreakCount: Int

    public init(settings: PomodoroSettings) {
        let settings = settings.validated()
        let gaps = max(settings.dailyGoal - 1, 0)
        longBreakCount = settings.longBreakEnabled ? gaps / settings.longBreakInterval : 0
        shortBreakCount = gaps - longBreakCount
        workMinutes = settings.dailyGoal * settings.workMinutes
        breakMinutes = shortBreakCount * settings.shortBreakMinutes + longBreakCount * settings.longBreakMinutes
        totalMinutes = workMinutes + breakMinutes
    }

    public static func formattedDuration(minutes: Int, language: AppLanguage = .english) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        let minute = language.text("мин", "min")
        let hour = language.text("ч", "hr")
        if hours == 0 { return "\(remainder) \(minute)" }
        if remainder == 0 { return "\(hours) \(hour)" }
        return "\(hours) \(hour) \(remainder) \(minute)"
    }
}
