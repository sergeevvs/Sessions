import Foundation

public enum TimerPhase: String, Codable, Sendable {
    case work, shortBreak, longBreak
}

public enum TimerStatus: String, Codable, Sendable {
    // dayComplete remains decodable for snapshots from versions with a hard goal.
    case ready, running, paused, waiting, dayComplete
}

public struct TimerState: Codable, Equatable, Sendable {
    public var phase: TimerPhase
    public var status: TimerStatus
    public var phaseID: UUID
    public var deadline: Date?
    public var remainingSeconds: TimeInterval
    public var durationSeconds: TimeInterval
    public var completedSessions: Int
    public var dayStart: Date

    public init(phase: TimerPhase, status: TimerStatus, phaseID: UUID,
                deadline: Date?, remainingSeconds: TimeInterval,
                durationSeconds: TimeInterval, completedSessions: Int, dayStart: Date) {
        self.phase = phase
        self.status = status
        self.phaseID = phaseID
        self.deadline = deadline
        self.remainingSeconds = remainingSeconds
        self.durationSeconds = durationSeconds
        self.completedSessions = completedSessions
        self.dayStart = dayStart
    }
}

public enum TimerAction: Sendable {
    case start, pause, reset, skip
    case tick(recovering: Bool)
    case updateSettings(PomodoroSettings)
}

public enum TimerEvent: Equatable, Sendable {
    case phaseCompleted(id: UUID, phase: TimerPhase, reachedGoal: Bool, recovering: Bool)
}

public struct TimerEngine: Sendable {
    public private(set) var settings: PomodoroSettings
    public private(set) var state: TimerState
    private let calendar: Calendar

    public init(settings: PomodoroSettings = .init(), state: TimerState? = nil,
                now: Date, calendar: Calendar = .autoupdatingCurrent) {
        self.settings = settings.validated()
        self.calendar = calendar
        let duration = TimeInterval(self.settings.workMinutes * 60)
        self.state = state ?? TimerState(
            phase: .work, status: .ready, phaseID: UUID(), deadline: nil,
            remainingSeconds: duration, durationSeconds: duration,
            completedSessions: 0, dayStart: calendar.startOfDay(for: now))
        validateState(at: now)
        // Preserve an expired deadline until handle can emit its completion event.
        // Rolling over here would assign yesterday's completed work to today.
    }

    public func remaining(at now: Date) -> TimeInterval {
        let seconds: TimeInterval
        if state.status == .dayComplete {
            return 0
        } else if state.status == .running, let deadline = state.deadline {
            seconds = deadline.timeIntervalSince(now)
        } else {
            seconds = state.remainingSeconds
        }
        return min(max(seconds, 0), state.durationSeconds)
    }

    public func progress(at now: Date) -> Double {
        guard state.durationSeconds > 0 else { return 0 }
        return 1 - remaining(at: now) / state.durationSeconds
    }

    public mutating func handle(_ action: TimerAction, at now: Date) -> [TimerEvent] {
        let recovering: Bool
        let automatic: Bool
        if case let .tick(isRecovering) = action {
            recovering = isRecovering
            automatic = !isRecovering && settings.automaticTransitions
        } else {
            recovering = false
            automatic = false
        }

        var events: [TimerEvent] = []
        if state.status == .running, let deadline = state.deadline, deadline <= now {
            // Attribute completion to its saved deadline before reconciling today.
            rollDay(to: deadline)
            let id = state.phaseID
            let phase = state.phase
            advance()
            let reachedGoal = phase == .work && state.completedSessions == settings.dailyGoal
            events.append(.phaseCompleted(id: id, phase: phase,
                                          reachedGoal: reachedGoal, recovering: recovering))
            if automatic { start(at: now) }
        }
        rollDay(to: now)

        // A button targeted the expired phase, never the newly prepared one.
        // Settings still apply after completing the phase under its old settings.
        if case let .updateSettings(newSettings) = action {
            settings = newSettings.validated()
            applySettings()
        } else if events.isEmpty {
            switch action {
            case .start:
                start(at: now)
            case .pause:
                if state.status == .running {
                    state.remainingSeconds = remaining(at: now)
                    state.deadline = nil
                    state.status = .paused
                }
            case .reset:
                resetOrGoBack()
            case .skip:
                advance()
            case .tick, .updateSettings:
                break
            }
        }
        return events
    }

    private func duration(for phase: TimerPhase) -> TimeInterval {
        switch phase {
        case .work: TimeInterval(settings.workMinutes * 60)
        case .shortBreak: TimeInterval(settings.shortBreakMinutes * 60)
        case .longBreak: TimeInterval(settings.longBreakMinutes * 60)
        }
    }

    private func breakAfterWork() -> TimerPhase {
        settings.longBreakEnabled && state.completedSessions % settings.longBreakInterval == 0
            ? .longBreak : .shortBreak
    }

    private mutating func advance() {
        if state.phase == .work {
            // A malformed saved counter must not overflow, while real progress
            // remains free to exceed the daily target and its settings range.
            if state.completedSessions < Int.max { state.completedSessions += 1 }
            prepare(breakAfterWork(), status: .waiting)
        } else {
            prepare(.work, status: .waiting)
        }
    }

    private mutating func resetOrGoBack() {
        if state.status == .running || state.status == .paused {
            prepare(state.phase, status: .ready)
        } else if state.phase == .work {
            guard state.completedSessions > 0 else { return }
            prepare(breakAfterWork(), status: .ready)
        } else {
            state.completedSessions = max(0, state.completedSessions - 1)
            prepare(.work, status: .ready)
        }
    }

    private mutating func prepare(_ phase: TimerPhase, status: TimerStatus) {
        state.phase = phase
        state.status = status
        state.phaseID = UUID()
        state.deadline = nil
        state.durationSeconds = duration(for: phase)
        state.remainingSeconds = state.durationSeconds
    }

    private mutating func start(at now: Date) {
        guard [.ready, .waiting, .paused].contains(state.status) else { return }
        state.deadline = now.addingTimeInterval(state.remainingSeconds)
        state.status = .running
    }

    private mutating func applySettings() {
        if state.status == .ready || state.status == .waiting {
            if state.phase == .longBreak, !settings.longBreakEnabled {
                prepare(.shortBreak, status: state.status)
            } else {
                state.durationSeconds = duration(for: state.phase)
                state.remainingSeconds = state.durationSeconds
            }
        }
    }

    private mutating func rollDay(to date: Date) {
        let day = calendar.startOfDay(for: date)
        guard day != state.dayStart else { return }
        state.dayStart = day
        state.completedSessions = 0
        if state.status == .dayComplete { prepare(.work, status: .ready) }
    }

    private mutating func validateState(at now: Date) {
        state.completedSessions = max(state.completedSessions, 0)
        if !state.dayStart.timeIntervalSinceReferenceDate.isFinite {
            state.dayStart = calendar.startOfDay(for: now)
        }
        if state.status == .dayComplete {
            prepare(.work, status: .ready)
            return
        }
        // Keep the saved absolute day boundary. Reprojecting it into a changed
        // zone here would preserve counts that the live engine correctly resets.
        // handle reconciles both restored and live state with the current day.
        let maximumDuration: TimeInterval
        switch state.phase {
        case .work: maximumDuration = 180 * 60
        case .shortBreak: maximumDuration = 60 * 60
        case .longBreak: maximumDuration = 120 * 60
        }
        // Captured durations may exceed current settings, but never the phase's supported range.
        let validDuration = state.durationSeconds.isFinite && state.durationSeconds > 0 &&
            state.durationSeconds <= maximumDuration
        let validRemainder = state.remainingSeconds.isFinite && state.remainingSeconds >= 0
        let validDeadline = state.deadline?.timeIntervalSinceReferenceDate.isFinite == true
        if !validDuration || !validRemainder || (state.status == .running && !validDeadline) {
            prepare(state.phase, status: .ready)
        } else {
            state.remainingSeconds = min(state.remainingSeconds, state.durationSeconds)
            if state.status != .running { state.deadline = nil }
            if state.status == .dayComplete { state.remainingSeconds = 0 }
        }
    }
}
