import Foundation

public struct PersistedSession: Codable, Sendable {
    public var version: Int
    public var settings: PomodoroSettings
    public var state: TimerState

    public init(settings: PomodoroSettings, state: TimerState) {
        self.version = 1
        self.settings = settings
        self.state = state
    }
}

public enum SessionPersistence {
    public static func restoreForLaunch(_ data: Data?, now: Date,
                                        calendar: Calendar = .autoupdatingCurrent) -> TimerEngine {
        let engine = decode(data, now: now, calendar: calendar)
        guard engine.state.phase != .work,
              engine.state.status == .ready || engine.state.status == .waiting else { return engine }
        var state = engine.state
        state.phase = .work
        state.status = .ready
        state.phaseID = UUID()
        state.deadline = nil
        state.durationSeconds = TimeInterval(engine.settings.workMinutes * 60)
        state.remainingSeconds = state.durationSeconds
        return TimerEngine(settings: engine.settings, state: state, now: now, calendar: calendar)
    }

    public static func encode(_ session: PersistedSession) throws -> Data {
        try JSONEncoder().encode(session)
    }

    public static func decode(_ data: Data?, now: Date, calendar: Calendar = .autoupdatingCurrent) -> TimerEngine {
        guard let data,
              let session = try? JSONDecoder().decode(PersistedSession.self, from: data),
              session.version == 1 else {
            return TimerEngine(now: now, calendar: calendar)
        }
        var engine = TimerEngine(settings: session.settings, state: session.state, now: now, calendar: calendar)
        // Recovery resolves the saved deadline before reconciling the day and never
        // auto-starts or exposes a late completion event to notification delivery.
        _ = engine.handle(.tick(recovering: true), at: now)
        // Prepared phases must display their full validated duration. The engine
        // deliberately leaves running/paused captured durations untouched.
        _ = engine.handle(.updateSettings(engine.settings), at: now)
        return engine
    }
}
