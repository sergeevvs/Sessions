import Foundation
import PomodoroCore

enum TimerRefreshSchedule {
    static func nextFireDate(for engine: TimerEngine, at now: Date,
                             calendar: Calendar = .autoupdatingCurrent) -> Date {
        if engine.state.status == .running, let deadline = engine.state.deadline {
            let remaining = engine.remaining(at: now)
            guard remaining > 0 else { return now }
            // Refresh just past the next ceil-rounded display boundary. This
            // preserves the full first second without waiting for a global tick.
            let untilBoundary = remaining - max(0, ceil(remaining) - 1)
            return min(deadline, now.addingTimeInterval(untilBoundary + 0.001))
        }
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            ?? now.addingTimeInterval(24 * 60 * 60)
    }
}
