import Foundation
import Testing
@testable import PomodoroCore

struct TimerNavigationTests {
    private let now = Date(timeIntervalSince1970: 1_793_606_400)
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 0)!
        return result
    }

    @Test(arguments: [false, true])
    func forwardAdvancesCountAndFollowsConfiguredBreaks(longBreaks: Bool) {
        var timer = TimerEngine(settings: .init(longBreakEnabled: longBreaks, longBreakInterval: 2,
                                                dailyGoal: 2, automaticTransitions: true),
                                now: now, calendar: calendar)
        let stages: [(TimerPhase, Int, TimeInterval)] = [
            (.shortBreak, 1, 300), (.work, 1, 1500),
            (longBreaks ? .longBreak : .shortBreak, 2, longBreaks ? 900 : 300),
            (.work, 2, 1500), (.shortBreak, 3, 300)
        ]
        for (phase, count, duration) in stages {
            #expect(timer.handle(.skip, at: now).isEmpty)
            #expect(timer.state.phase == phase)
            #expect(timer.state.completedSessions == count)
            #expect(timer.state.status == .waiting)
            #expect(timer.remaining(at: now) == duration)
            #expect(timer.state.deadline == nil)
        }
    }

    @Test(arguments: [false, true])
    func backTraversesBreakAndWorkWithoutGoingBelowFirstWork(longBreaks: Bool) {
        var timer = TimerEngine(settings: .init(longBreakEnabled: longBreaks, longBreakInterval: 2),
                                now: now, calendar: calendar)
        for _ in 0..<4 { _ = timer.handle(.skip, at: now) }
        // Work 3 → Break 2 → Work 2 → Break 1 → Work 1.
        let stages: [(TimerPhase, Int)] = [
            (longBreaks ? .longBreak : .shortBreak, 2), (.work, 1),
            (.shortBreak, 1), (.work, 0)
        ]
        for (phase, count) in stages {
            #expect(timer.handle(.reset, at: now).isEmpty)
            #expect(timer.state.phase == phase)
            #expect(timer.state.completedSessions == count)
            #expect(timer.state.status == .ready)
            #expect(timer.state.deadline == nil)
        }
        let firstWork = timer.state
        _ = timer.handle(.reset, at: now)
        #expect(timer.state == firstWork)
    }

    @Test(arguments: [TimerPhase.work, .shortBreak, .longBreak], [TimerStatus.running, .paused])
    func activePhaseResetsBeforeMovingBack(phase: TimerPhase, status: TimerStatus) {
        let duration: TimeInterval = phase == .work ? 1500 : phase == .shortBreak ? 300 : 900
        let state = TimerState(phase: phase, status: status, phaseID: UUID(),
                              deadline: status == .running ? now.addingTimeInterval(100) : nil,
                              remainingSeconds: 100, durationSeconds: duration,
                              completedSessions: 2, dayStart: calendar.startOfDay(for: now))
        var timer = TimerEngine(settings: .init(longBreakInterval: 2), state: state,
                                now: now, calendar: calendar)
        #expect(timer.handle(.reset, at: now).isEmpty)
        #expect(timer.state.phase == phase)
        #expect(timer.state.status == .ready)
        #expect(timer.remaining(at: now) == duration)
        #expect(timer.state.completedSessions == 2)
        #expect(timer.state.phaseID != state.phaseID)
        #expect(timer.state.deadline == nil)
        _ = timer.handle(.reset, at: now)
        #expect(timer.state.phase == (phase == .work ? .longBreak : .work))
        #expect(timer.state.completedSessions == (phase == .work ? 2 : 1))
    }

    @Test func naturalAutomaticCycleContinuesBeyondGoalAndOnlyAnnouncesItOnce() {
        var timer = TimerEngine(settings: .init(workMinutes: 1, shortBreakMinutes: 1,
                                                longBreakInterval: 2, dailyGoal: 1,
                                                automaticTransitions: true), now: now, calendar: calendar)
        _ = timer.handle(.start, at: now)
        let first = timer.handle(.tick(recovering: false), at: now.addingTimeInterval(60))
        #expect(first.count == 1)
        if case .phaseCompleted(_, .work, reachedGoal: true, recovering: false) = first.first {} else {
            Issue.record("First work must announce the reached target")
        }
        #expect(timer.state.phase == .shortBreak)
        #expect(timer.state.status == .running)
        let rest = timer.handle(.tick(recovering: false), at: now.addingTimeInterval(120))
        if case .phaseCompleted(_, .shortBreak, reachedGoal: false, recovering: false) = rest.first {} else {
            Issue.record("Break must not announce the work target again")
        }
        let extra = timer.handle(.tick(recovering: false), at: now.addingTimeInterval(180))
        if case .phaseCompleted(_, .work, reachedGoal: false, recovering: false) = extra.first {} else {
            Issue.record("Extra work must have an ordinary completion")
        }
        #expect(timer.state.completedSessions == 2)
        #expect(timer.state.phase == .longBreak)
        #expect(timer.state.status == .running)
    }

    @Test func legacyCompletedDayCanContinueAndRewind() throws {
        var state = TimerEngine(now: now, calendar: calendar).state
        state.completedSessions = 8
        state.status = .dayComplete
        state.remainingSeconds = 0
        let data = try SessionPersistence.encode(.init(settings: .init(), state: state))
        var timer = SessionPersistence.restoreForLaunch(data, now: now, calendar: calendar)
        #expect(timer.state.status == .ready)
        #expect(timer.state.phase == .work)
        #expect(timer.state.completedSessions == 8)
        #expect(timer.remaining(at: now) == 1500)
        _ = timer.handle(.reset, at: now)
        #expect(timer.state.phase == .longBreak)
        #expect(timer.state.completedSessions == 8)
        _ = timer.handle(.reset, at: now)
        #expect(timer.state.phase == .work)
        #expect(timer.state.completedSessions == 7)
    }

    @Test func progressBeyondTwentyFourSurvivesSavingAndStillNavigates() throws {
        var timer = TimerEngine(now: now, calendar: calendar)
        for _ in 0..<60 { _ = timer.handle(.skip, at: now) }
        #expect(timer.state.completedSessions == 30)
        let data = try SessionPersistence.encode(.init(settings: timer.settings, state: timer.state))
        timer = SessionPersistence.restoreForLaunch(data, now: now, calendar: calendar)
        #expect(timer.state.completedSessions == 30)
        _ = timer.handle(.skip, at: now)
        #expect(timer.state.completedSessions == 31)
    }

    @Test func malformedMaximumCountDoesNotOverflowOnForwardOrCompletion() {
        var state = TimerEngine(now: now, calendar: calendar).state
        state.completedSessions = .max
        var timer = TimerEngine(state: state, now: now, calendar: calendar)
        _ = timer.handle(.skip, at: now)
        #expect(timer.state.completedSessions == .max)
        state.status = .running
        state.deadline = now.addingTimeInterval(1)
        timer = TimerEngine(state: state, now: now, calendar: calendar)
        _ = timer.handle(.tick(recovering: false), at: now.addingTimeInterval(1))
        #expect(timer.state.completedSessions == .max)
    }
}
