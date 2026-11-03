import Foundation
import Testing
@testable import PomodoroCore

struct StatusItemFormatterTests {
    private let now = Date(timeIntervalSince1970: 1_793_606_400)

    private func engine(fields: Set<StatusItemField>) -> TimerEngine {
        TimerEngine(settings: PomodoroSettings(language: .russian, statusItemFields: fields), now: now)
    }

    @Test func testSharedCountdownFormatterBoundsMalformedInputAndRoundsUp() {
        for (seconds, expected) in [(0.0, "00:00"), (-1.0, "00:00"), (0.1, "00:01"),
                                     (59.1, "01:00"), (10800.0, "180:00"),
                                     (Double.nan, "00:00"), (.infinity, "00:00"),
                                     (-.infinity, "00:00"), (1e30, "76861433640456465:04")] {
            #expect(StatusItemFormatter.formattedTime(seconds) == expected)
        }
    }

    @Test func testDefaultLabelOnlyShowsTime() {
        let engine = TimerEngine(now: now)
        let content = StatusItemFormatter.content(for: engine, at: now)
        #expect(content.title == "25:00")
        #expect(content.symbolName == nil)
    }

    @Test func testTimeAndCountersUseFixedOrderAndSeparator() {
        let timer = engine(fields: [.sessions, .time])
        #expect(StatusItemFormatter.content(for: timer, at: now).title == "25:00 | 0 из 8")
        let all = engine(fields: Set(StatusItemField.allCases))
        let content = StatusItemFormatter.content(for: all, at: now)
        #expect(content.title == "Работа | 25:00 | 0 из 8")
        #expect(content.symbolName?.isEmpty == false)
    }

    @Test func testProgressShowsActualCountEvenAboveGoal() {
        for (completed, goal, expected) in [(0, 8, "0 из 8"), (3, 8, "3 из 8"),
                                             (12, 8, "12 из 8"), (24, 24, "24 из 24")] {
            let settings = PomodoroSettings(language: .russian, dailyGoal: goal, statusItemFields: [.sessions])
            var state = TimerEngine(settings: settings, now: now).state
            state.completedSessions = completed
            let timer = TimerEngine(settings: settings, state: state, now: now)
            #expect(StatusItemFormatter.content(for: timer, at: now).title == expected)
            #expect(StatusItemFormatter.formattedProgress(completed: completed, goal: goal, language: .russian) == expected)
        }
    }

    @Test func testSymbolOnlyHasImageAndNoText() {
        let content = StatusItemFormatter.content(for: engine(fields: [.symbol]), at: now)
        #expect(content.title.isEmpty)
        #expect(content.symbolName?.isEmpty == false)
    }

    @Test func testEmptySelectionFallsBackToTime() {
        let timer = engine(fields: [])
        #expect(timer.settings.statusItemFields == [.time])
        #expect(StatusItemFormatter.content(for: timer, at: now).title == "25:00")
    }

    @Test func testMinutesDoNotWrapAndFractionalCountdownRoundsUp() {
        var timer = TimerEngine(settings: PomodoroSettings(workMinutes: 62), now: now)
        _ = timer.handle(.start, at: now)
        #expect(StatusItemFormatter.content(for: timer, at: now.addingTimeInterval(59)).title == "61:01")
        #expect(StatusItemFormatter.content(for: timer, at: now.addingTimeInterval(59.1)).title == "61:01")
        #expect(StatusItemFormatter.content(for: timer, at: now.addingTimeInterval(3719.9)).title == "00:01")
    }

    @Test func testAccessibilityIncludesPhaseStateTimeAndProgressRegardlessOfFields() {
        var timer = engine(fields: [.symbol])
        _ = timer.handle(.start, at: now)
        _ = timer.handle(.pause, at: now.addingTimeInterval(60))
        let content = StatusItemFormatter.content(for: timer, at: now.addingTimeInterval(500))
        #expect(content.accessibilityLabel.contains("Работа"))
        #expect(content.accessibilityLabel.lowercased().contains("пауза"))
        #expect(content.accessibilityLabel.contains("24:00"))
        #expect(content.accessibilityLabel.contains("0 из 8"))
    }

    @Test func testWaitingBreakShowsFullTimeAndRussianPhase() {
        var timer = engine(fields: [.phase, .time])
        _ = timer.handle(.start, at: now)
        _ = timer.handle(.tick(recovering: false), at: now.addingTimeInterval(1500))
        let content = StatusItemFormatter.content(for: timer, at: now.addingTimeInterval(2000))
        #expect(content.title == "Перерыв | 05:00")
        #expect(content.accessibilityLabel.contains("1 из 8"))
        #expect(content.accessibilityLabel.lowercased().contains("ожидает"))
    }

    @Test func testLongBreakHasDistinctPhaseAndSymbol() {
        var timer = TimerEngine(settings: PomodoroSettings(language: .russian, workMinutes: 1, shortBreakMinutes: 1,
                                longBreakInterval: 2, statusItemFields: [.phase, .symbol]), now: now)
        _ = timer.handle(.start, at: now)
        _ = timer.handle(.tick(recovering: false), at: now.addingTimeInterval(60))
        let shortSymbol = StatusItemFormatter.content(for: timer, at: now).symbolName
        _ = timer.handle(.start, at: now.addingTimeInterval(60))
        _ = timer.handle(.tick(recovering: false), at: now.addingTimeInterval(120))
        _ = timer.handle(.start, at: now.addingTimeInterval(120))
        _ = timer.handle(.tick(recovering: false), at: now.addingTimeInterval(180))
        let content = StatusItemFormatter.content(for: timer, at: now.addingTimeInterval(180))
        #expect(content.title == "Длинный перерыв")
        #expect(content.symbolName?.isEmpty == false)
        #expect(content.symbolName != shortSymbol)
    }

    @Test func testReachedGoalShowsNextBreakWithProgress() {
        var timer = TimerEngine(settings: PomodoroSettings(language: .russian, dailyGoal: 1, statusItemFields: [.time, .symbol]), now: now)
        _ = timer.handle(.start, at: now)
        _ = timer.handle(.tick(recovering: false), at: now.addingTimeInterval(1500))
        let content = StatusItemFormatter.content(for: timer, at: now.addingTimeInterval(1500))
        #expect(content.title == "05:00")
        #expect(content.symbolName == "cup.and.saucer")
        #expect(content.accessibilityLabel.lowercased().contains("ожидает запуска"))
        #expect(content.accessibilityLabel.contains("1 из 1"))
    }
}
