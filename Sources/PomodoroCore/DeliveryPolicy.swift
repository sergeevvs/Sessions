import Foundation

public enum NotificationAuthorization: Sendable {
    case notDetermined, authorized, denied
}

public struct ScheduledNotification: Equatable, Sendable {
    public let phaseID: UUID
    public let deadline: Date
    public let title: String
    public let body: String
    public let soundEnabled: Bool

    public init(phaseID: UUID, deadline: Date, title: String, body: String, soundEnabled: Bool) {
        self.phaseID = phaseID
        self.deadline = deadline
        self.title = title
        self.body = body
        self.soundEnabled = soundEnabled
    }
}

public enum CompletionDeliveryPolicy {
    public static func shouldPlayFallbackSound(settings: PomodoroSettings,
                                              authorization: NotificationAuthorization,
                                              recovering: Bool) -> Bool {
        settings.soundEnabled && !recovering &&
            (!settings.notificationsEnabled || authorization != .authorized)
    }

    public static func notification(for engine: TimerEngine) -> ScheduledNotification? {
        guard engine.settings.notificationsEnabled, engine.state.status == .running,
              let deadline = engine.state.deadline else { return nil }
        // Preview the reducer at the saved deadline. This uses its calendar/day
        // attribution and goal rules without changing the running engine.
        var preview = engine
        let completion = preview.handle(.tick(recovering: true), at: deadline)
        let reachesGoal = completion.contains {
            if case .phaseCompleted(_, _, reachedGoal: true, _) = $0 { return true }
            return false
        }
        let language = engine.settings.language
        let body: String
        if reachesGoal {
            body = language.text("План на сегодня выполнен. Отличная работа!", "Today’s goal is complete. Great work!")
        } else if engine.state.phase == .work {
            body = language.text("Рабочая сессия завершена. Пора отдохнуть.", "Work session complete. Time for a break.")
        } else {
            body = language.text("Перерыв завершён. Можно вернуться к работе.", "Break complete. Time to get back to work.")
        }
        return ScheduledNotification(phaseID: engine.state.phaseID, deadline: deadline,
                                     title: "Sessions", body: body,
                                     soundEnabled: engine.settings.soundEnabled)
    }
}
