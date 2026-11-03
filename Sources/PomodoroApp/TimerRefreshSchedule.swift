import Foundation
import PomodoroCore

enum TimerRefreshSchedule {
    static func nextFireDate(for engine: TimerEngine, at now: Date,
                             needsSeconds: Bool = false,
                             calendar: Calendar = .autoupdatingCurrent) -> Date {
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            ?? now.addingTimeInterval(24 * 60 * 60)
        if engine.state.status == .running, let deadline = engine.state.deadline {
            guard needsSeconds || engine.settings.statusItemFields.contains(.time) else {
                return min(deadline, midnight)
            }
            let remaining = engine.remaining(at: now)
            guard remaining > 0 else { return now }
            // Refresh just past the next ceil-rounded display boundary. This
            // preserves the full first second without waiting for a global tick.
            let untilBoundary = remaining - max(0, ceil(remaining) - 1)
            return min(deadline, midnight, now.addingTimeInterval(untilBoundary + 0.001))
        }
        return midnight
    }
}
