import Foundation
import Testing
@testable import PomodoroCore

struct TimerEngineTests {
    private let now = Date(timeIntervalSince1970: 1_793_606_400)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func engine(_ settings: PomodoroSettings = .init()) -> TimerEngine {
        TimerEngine(settings: settings, now: now, calendar: calendar)
    }

    private func restored(phase: TimerPhase = .work, status: TimerStatus = .waiting,
                          completed: Int = 4, settings: PomodoroSettings = .init()) -> TimerEngine {
        let seconds: TimeInterval = phase == .work ? 1500 : phase == .shortBreak ? 300 : 900
        let state = TimerState(phase: phase, status: status, phaseID: UUID(),
                               deadline: status == .running ? now.addingTimeInterval(seconds) : nil,
                               remainingSeconds: seconds, durationSeconds: seconds,
                               completedSessions: completed, dayStart: calendar.startOfDay(for: now))
        return TimerEngine(settings: settings, state: state, now: now, calendar: calendar)
    }

    @Test func testDefaultsPrepareManualTwentyFiveMinuteWork() {
        let timer = engine()
        #expect(timer.state.phase == .work)
        #expect(timer.state.status == .ready)
        #expect(timer.remaining(at: now) == 1500)
        #expect(timer.state.completedSessions == 0)
        #expect(timer.settings.shortBreakMinutes == 5)
        #expect(timer.settings.longBreakMinutes == 15)
        #expect(timer.settings.longBreakEnabled)
        #expect(timer.settings.longBreakInterval == 4)
        #expect(timer.settings.dailyGoal == 8)
        #expect(!timer.settings.automaticTransitions)
        #expect(timer.settings.soundEnabled)
        #expect(timer.settings.notificationsEnabled)
        #expect(timer.settings.statusItemFields == [.time])
    }

    @Test func testSettingsClampAllNumericRangesAndNormalizeAnEmptyStatusSelection() {
        var settings = PomodoroSettings()
        settings.workMinutes = -1
        settings.shortBreakMinutes = 100
        settings.longBreakMinutes = 0
        settings.longBreakInterval = 100
        settings.dailyGoal = 0
        settings.statusItemFields = []
        let validated = settings.validated()
        #expect(validated.workMinutes == 1)
        #expect(validated.shortBreakMinutes == 60)
        #expect(validated.longBreakMinutes == 1)
        #expect(validated.longBreakInterval == 12)
        #expect(validated.dailyGoal == 1)
        #expect(validated.statusItemFields == [.time])
        settings.workMinutes = 1000
        settings.shortBreakMinutes = 0
        settings.longBreakMinutes = 1000
        settings.longBreakInterval = 0
        settings.dailyGoal = 1000
        let other = settings.validated()
        #expect(other.workMinutes == 180)
        #expect(other.shortBreakMinutes == 1)
        #expect(other.longBreakMinutes == 120)
        #expect(other.longBreakInterval == 2)
        #expect(other.dailyGoal == 24)
    }

    @Test func testManualCompletionWaitsAndOnlyEmitsOnce() {
        var timer = engine()
        _ = timer.handle(.start, at: now)
        let id = timer.state.phaseID
        let end = now.addingTimeInterval(1500)
        let events = timer.handle(.tick(recovering: false), at: end)
        assertCompletion(events, id: id, phase: .work, reachedGoal: false, recovering: false)
        #expect(timer.state.completedSessions == 1)
        #expect(timer.state.phase == .shortBreak)
        #expect(timer.state.status == .waiting)
        #expect(timer.remaining(at: end) == 300)
        #expect(timer.state.deadline == nil)
        #expect(timer.state.phaseID != id)
        #expect(timer.handle(.tick(recovering: false), at: end.addingTimeInterval(5000)).isEmpty)
        #expect(timer.state.completedSessions == 1)
    }

    @Test func testAutomaticCompletionStartsNextPhaseFromCurrentTime() {
        var settings = PomodoroSettings()
        settings.automaticTransitions = true
        var timer = engine(settings)
        _ = timer.handle(.start, at: now)
        let tick = now.addingTimeInterval(1503)
        _ = timer.handle(.tick(recovering: false), at: tick)
        #expect(timer.state.phase == .shortBreak)
        #expect(timer.state.status == .running)
        #expect(timer.state.deadline == tick.addingTimeInterval(300))
        _ = timer.handle(.tick(recovering: false), at: tick.addingTimeInterval(300))
        #expect(timer.state.phase == .work)
        #expect(timer.state.completedSessions == 1)
    }

    @Test func testEnabledLongBreakUsesLongBreakAfterFourthWork() {
        var timer = restored(completed: 3)
        _ = timer.handle(.start, at: now)
        _ = timer.handle(.tick(recovering: false), at: now.addingTimeInterval(1500))
        #expect(timer.state.phase == .longBreak)
        #expect(timer.remaining(at: now.addingTimeInterval(1500)) == 900)
    }

    @Test func testDisabledLongBreakUsesShortBreakAfterFourthWork() {
        var settings = PomodoroSettings()
        settings.longBreakEnabled = false
        var now = Date(timeIntervalSince1970: 1_793_606_400)
        var engine = TimerEngine(settings: settings, now: now)
        for index in 1...4 {
            _ = engine.handle(.start, at: now)
            now = now.addingTimeInterval(25 * 60)
            _ = engine.handle(.tick(recovering: false), at: now)
            #expect(engine.state.phase == .shortBreak)
            #expect(engine.state.completedSessions == index)
            #expect(engine.state.status == .waiting)
            if index < 4 {
                _ = engine.handle(.start, at: now)
                now = now.addingTimeInterval(5 * 60)
                _ = engine.handle(.tick(recovering: false), at: now)
            }
        }
    }

    @Test func testDisablingLongBreakReplacesWaitingButKeepsItsSettings() {
        var timer = restored(phase: .longBreak)
        var settings = timer.settings
        settings.longBreakEnabled = false
        _ = timer.handle(.updateSettings(settings), at: now)
        #expect(timer.state.phase == .shortBreak)
        #expect(timer.state.status == .waiting)
        #expect(timer.remaining(at: now) == 300)
        #expect(timer.settings.longBreakMinutes == 15)
        #expect(timer.settings.longBreakInterval == 4)
        settings.longBreakEnabled = true
        _ = timer.handle(.updateSettings(settings), at: now)
        #expect(timer.state.phase == .shortBreak)
    }

    @Test func testDisablingLongBreakPreservesRunningAndPausedLongBreak() {
        for status in [TimerStatus.running, .paused] {
            var timer = restored(phase: .longBreak, status: status)
            let state = timer.state
            var settings = timer.settings
            settings.longBreakEnabled = false
            _ = timer.handle(.updateSettings(settings), at: now)
            #expect(timer.state == state)
        }
    }

    @Test func testSkipAdvancesProgressAndResetDoesNotAutomaticallyStart() {
        var settings = PomodoroSettings()
        settings.automaticTransitions = true
        var timer = engine(settings)
        _ = timer.handle(.start, at: now)
        #expect(timer.handle(.reset, at: now.addingTimeInterval(30)).isEmpty)
        #expect(timer.state.status == .ready)
        #expect(timer.remaining(at: now) == 1500)
        _ = timer.handle(.start, at: now)
        #expect(timer.handle(.skip, at: now.addingTimeInterval(30)).isEmpty)
        #expect(timer.state.phase == .shortBreak)
        #expect(timer.state.status == .waiting)
        #expect(timer.state.completedSessions == 1)
        _ = timer.handle(.skip, at: now.addingTimeInterval(30))
        #expect(timer.state.phase == .work)
        #expect(timer.state.completedSessions == 1)
    }

    @Test func testPauseFreezesRemainderAndResumeUsesNewDeadline() {
        var timer = engine()
        _ = timer.handle(.start, at: now)
        _ = timer.handle(.pause, at: now.addingTimeInterval(100))
        #expect(timer.state.status == .paused)
        #expect(timer.state.deadline == nil)
        #expect(timer.remaining(at: now.addingTimeInterval(1000)) == 1400)
        #expect(abs((timer.progress(at: now)) - (100.0 / 1500)) <= (0.0001))
        _ = timer.handle(.start, at: now.addingTimeInterval(1000))
        #expect(timer.state.deadline == now.addingTimeInterval(2400))
    }

    @Test func testDurationChangePreservesActiveAndPausedButRefreshesReady() {
        var timer = engine()
        var settings = timer.settings
        settings.workMinutes = 30
        _ = timer.handle(.updateSettings(settings), at: now)
        #expect(timer.remaining(at: now) == 1800)
        _ = timer.handle(.start, at: now)
        settings.workMinutes = 40
        _ = timer.handle(.updateSettings(settings), at: now.addingTimeInterval(100))
        #expect(timer.state.durationSeconds == 1800)
        #expect(timer.state.deadline == now.addingTimeInterval(1800))
        _ = timer.handle(.pause, at: now.addingTimeInterval(100))
        settings.workMinutes = 50
        _ = timer.handle(.updateSettings(settings), at: now.addingTimeInterval(500))
        #expect(timer.remaining(at: now) == 1700)
        #expect(timer.state.durationSeconds == 1800)
        _ = timer.handle(.reset, at: now)
        #expect(timer.remaining(at: now) == 3000)
    }

    @Test func testEnablingAutomaticTransitionsWhileWaitingDoesNotStart() {
        var timer = restored()
        var settings = timer.settings
        settings.automaticTransitions = true
        _ = timer.handle(.updateSettings(settings), at: now)
        #expect(timer.state.status == .waiting)
        #expect(timer.state.deadline == nil)
    }

    @Test func testReachingGoalPreparesManualBreakAndAllowsExtraWork() {
        let settings = PomodoroSettings(dailyGoal: 1)
        var timer = engine(settings)
        _ = timer.handle(.start, at: now)
        let id = timer.state.phaseID
        let end = now.addingTimeInterval(1500)
        let events = timer.handle(.tick(recovering: false), at: end)
        assertCompletion(events, id: id, phase: .work, reachedGoal: true, recovering: false)
        #expect(timer.state.status == .waiting)
        #expect(timer.state.phase == .shortBreak)
        #expect(timer.remaining(at: end) == 300)
        #expect(timer.state.deadline == nil)
        _ = timer.handle(.skip, at: end)
        _ = timer.handle(.start, at: end)
        _ = timer.handle(.tick(recovering: false), at: end.addingTimeInterval(1500))
        #expect(timer.state.completedSessions == 2)
        #expect(timer.state.status == .waiting)
        #expect(timer.state.phase == .shortBreak)
    }

    @Test func testLoweringGoalPreservesWaitingPhaseAndActualCount() {
        var timer = restored(phase: .shortBreak, completed: 4)
        var settings = timer.settings
        settings.dailyGoal = 2
        _ = timer.handle(.updateSettings(settings), at: now)
        #expect(timer.state.status == .waiting)
        #expect(timer.state.completedSessions == 4)
    }

    @Test func testLoweringGoalDoesNotInterruptActiveOrPausedPhase() {
        for status in [TimerStatus.running, .paused] {
            var timer = restored(phase: .shortBreak, status: status, completed: 4)
            var settings = timer.settings
            settings.dailyGoal = 2
            _ = timer.handle(.updateSettings(settings), at: now)
            #expect(timer.state.status == status)
            if status == .paused { _ = timer.handle(.start, at: now) }
            _ = timer.handle(.tick(recovering: false), at: now.addingTimeInterval(300))
            #expect(timer.state.status == .waiting)
            #expect(timer.state.completedSessions == 4)
        }
    }

    @Test func testRecoveryCompletesOnlyLaunchedPhaseAndWaits() {
        var settings = PomodoroSettings()
        settings.automaticTransitions = true
        var timer = engine(settings)
        _ = timer.handle(.start, at: now)
        let id = timer.state.phaseID
        let restoredState = timer.state
        timer = TimerEngine(settings: settings, state: restoredState, now: now.addingTimeInterval(20000), calendar: calendar)
        let events = timer.handle(.tick(recovering: true), at: now.addingTimeInterval(20000))
        assertCompletion(events, id: id, phase: .work, reachedGoal: false, recovering: true)
        #expect(timer.state.completedSessions == 1)
        #expect(timer.state.status == .waiting)
        #expect(timer.state.deadline == nil)
        #expect(timer.handle(.tick(recovering: true), at: now.addingTimeInterval(21000)).isEmpty)
    }

    @Test func testExpiredUserActionsResolveCompletionWithoutActingOnNextPhase() {
        let actions: [TimerAction] = [.start, .pause, .reset, .skip]
        for action in actions {
            var settings = PomodoroSettings()
            settings.automaticTransitions = true
            var timer = engine(settings)
            _ = timer.handle(.start, at: now)
            let events = timer.handle(action, at: now.addingTimeInterval(1500))
            #expect(events.count == 1)
            #expect(timer.state.completedSessions == 1)
            #expect(timer.state.phase == .shortBreak)
            #expect(timer.state.status == .waiting)
            #expect(timer.state.deadline == nil)
        }
    }

    @Test func testExpiredSettingsUpdateResolvesUsingOldDurationThenAppliesSettings() {
        var timer = engine()
        _ = timer.handle(.start, at: now)
        var settings = timer.settings
        settings.shortBreakMinutes = 10
        let events = timer.handle(.updateSettings(settings), at: now.addingTimeInterval(1500))
        #expect(events.count == 1)
        #expect(timer.state.completedSessions == 1)
        #expect(timer.state.phase == .shortBreak)
        #expect(timer.remaining(at: now) == 600)
        #expect(timer.state.status == .waiting)
    }

    @Test func testYesterdayDeadlineRecoveredTodayDoesNotCountToday() {
        let yesterday = date(2026, 11, 1, 23, 0)
        var timer = TimerEngine(now: yesterday, calendar: calendar)
        _ = timer.handle(.start, at: yesterday)
        let today = date(2026, 11, 2, 1, 0)
        let snapshot = timer.state
        timer = TimerEngine(state: snapshot, now: today, calendar: calendar)
        let events = timer.handle(.tick(recovering: true), at: today)
        #expect(events.count == 1)
        #expect(timer.state.completedSessions == 0)
        #expect(timer.state.dayStart == date(2026, 11, 2, 0, 0))
        #expect(timer.state.status == .waiting)
    }

    @Test func testWorkCrossingMidnightCountsOnDeadlineDayAndResetsLongBreakCycle() {
        let before = date(2026, 11, 1, 23, 50)
        var state = restored(completed: 3).state
        state.dayStart = date(2026, 11, 1, 0, 0)
        var timer = TimerEngine(state: state, now: before, calendar: calendar)
        _ = timer.handle(.start, at: before)
        _ = timer.handle(.tick(recovering: false), at: date(2026, 11, 2, 0, 0))
        #expect(timer.state.status == .running)
        #expect(timer.state.completedSessions == 0)
        _ = timer.handle(.tick(recovering: false), at: date(2026, 11, 2, 0, 15))
        #expect(timer.state.completedSessions == 1)
        #expect(timer.state.phase == .shortBreak)
    }

    @Test func testPausedPhaseSurvivesMidnightAndCountsWhenResumed() {
        let before = date(2026, 11, 1, 23, 50)
        var timer = TimerEngine(now: before, calendar: calendar)
        _ = timer.handle(.start, at: before)
        _ = timer.handle(.pause, at: before.addingTimeInterval(600))
        let nextDay = date(2026, 11, 2, 12, 0)
        _ = timer.handle(.tick(recovering: true), at: nextDay)
        #expect(timer.state.status == .paused)
        #expect(timer.remaining(at: nextDay) == 900)
        _ = timer.handle(.start, at: nextDay)
        _ = timer.handle(.tick(recovering: false), at: nextDay.addingTimeInterval(900))
        #expect(timer.state.completedSessions == 1)
    }

    @Test func testNewDayRecoveryAfterGoalPreparesWorkWithoutAutoStart() {
        var settings = PomodoroSettings()
        settings.dailyGoal = 1
        settings.automaticTransitions = true
        var timer = engine(settings)
        _ = timer.handle(.start, at: now)
        _ = timer.handle(.tick(recovering: false), at: now.addingTimeInterval(1500))
        _ = timer.handle(.tick(recovering: true), at: now.addingTimeInterval(86400))
        #expect(timer.state.status == .waiting)
        #expect(timer.state.phase == .work)
        #expect(timer.state.completedSessions == 0)
        #expect(timer.state.deadline == nil)
    }

    @Test func testRemainingAndProgressUseDeadlineAndStayBoundedWhenClockMoves() {
        var timer = engine()
        _ = timer.handle(.start, at: now)
        #expect(timer.remaining(at: now.addingTimeInterval(300)) == 1200)
        #expect(abs((timer.progress(at: now.addingTimeInterval(300))) - (0.2)) <= (0.0001))
        #expect(timer.remaining(at: now.addingTimeInterval(-300)) == 1500)
        #expect(timer.progress(at: now.addingTimeInterval(-300)) == 0)
        #expect(timer.remaining(at: now.addingTimeInterval(5000)) == 0)
        #expect(timer.progress(at: now.addingTimeInterval(5000)) == 1)
    }

    @Test func testInvalidRestoredStateUsesSafeCoreValues() {
        var state = restored().state
        state.durationSeconds = .nan
        state.remainingSeconds = -.infinity
        state.completedSessions = -10
        state.status = .running
        state.deadline = nil
        let timer = TimerEngine(state: state, now: now, calendar: calendar)
        #expect(timer.state.status == .ready)
        #expect(timer.remaining(at: now) == 1500)
        #expect(timer.state.completedSessions == 0)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func assertCompletion(_ events: [TimerEvent], id: UUID, phase: TimerPhase,
                                  reachedGoal: Bool, recovering: Bool) {
        #expect(events.count == 1)
        guard let event = events.first else { return }
        switch event {
        case let .phaseCompleted(actualID, actualPhase, actualGoal, actualRecovery):
            #expect(actualID == id)
            #expect(actualPhase == phase)
            #expect(actualGoal == reachedGoal)
            #expect(actualRecovery == recovering)
        }
    }
}
