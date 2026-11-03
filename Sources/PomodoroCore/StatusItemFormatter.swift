import Foundation

public struct StatusItemContent: Equatable, Sendable {
    public var title: String
    public var symbolName: String?
    public var accessibilityLabel: String

    public init(title: String, symbolName: String?, accessibilityLabel: String) {
        self.title = title
        self.symbolName = symbolName
        self.accessibilityLabel = accessibilityLabel
    }
}

public enum StatusItemFormatter {
    public static func content(for engine: TimerEngine, at now: Date) -> StatusItemContent {
        let fields = engine.settings.validated().statusItemFields
        let language = engine.settings.language
        let phase = phaseName(engine.state.phase, language: language)
        let time = formattedTime(engine.remaining(at: now))
        let progress = formattedProgress(completed: engine.state.completedSessions, goal: engine.settings.dailyGoal, language: language)
        let label = "\(phase), \(statusName(engine.state.status, language: language)), \(time), \(progress)"
        return StatusItemContent(
            title: title(fields: fields, phase: phase, time: time,
                         progress: progress),
            symbolName: fields.contains(.symbol) ? symbolName(for: engine) : nil,
            accessibilityLabel: label)
    }

    private static func title(fields: Set<StatusItemField>, phase: String, time: String,
                              progress: String) -> String {
        var parts: [String] = []
        if fields.contains(.phase) { parts.append(phase) }
        if fields.contains(.time) { parts.append(time) }
        if fields.contains(.sessions) { parts.append(progress) }
        return parts.joined(separator: " | ")
    }

    public static func formattedProgress(completed: Int, goal: Int, language: AppLanguage = .english) -> String {
        "\(completed) \(language.text("из", "of")) \(goal)"
    }

    public static func formattedTime(_ remaining: TimeInterval) -> String {
        // Bound before integer conversion, including externally supplied snapshots.
        let safe = remaining.isFinite ? min(max(remaining, 0), Double(Int.max / 2)) : 0
        let seconds = Int(safe.rounded(.up))
        let minutes = String(seconds / 60)
        let remainder = String(seconds % 60)
        return "\(minutes.count < 2 ? "0" : "")\(minutes):\(remainder.count < 2 ? "0" : "")\(remainder)"
    }

    private static func phaseName(_ phase: TimerPhase, language: AppLanguage) -> String {
        switch phase {
        case .work: language.text("Работа", "Work")
        case .shortBreak: language.text("Перерыв", "Break")
        case .longBreak: language.text("Длинный перерыв", "Long break")
        }
    }

    private static func statusName(_ status: TimerStatus, language: AppLanguage) -> String {
        switch status {
        case .ready: language.text("Готов к запуску", "Ready")
        case .running: language.text("Идёт", "Running")
        case .paused: language.text("Пауза", "Paused")
        case .waiting: language.text("Ожидает запуска", "Waiting to start")
        case .dayComplete: language.text("План выполнен", "Goal complete")
        }
    }

    private static func symbolName(for engine: TimerEngine) -> String {
        if engine.state.status == .dayComplete { return "checkmark" }
        switch engine.state.phase {
        case .work: return "timer"
        case .shortBreak: return "cup.and.saucer"
        case .longBreak: return "leaf"
        }
    }
}
