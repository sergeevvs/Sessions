import Foundation
import Testing
import PomodoroCore
@testable import PomodoroApp

struct TimerRefreshScheduleTests {
    let now = Date(timeIntervalSince1970: 1_793_606_400)

    @Test func hiddenRunningSymbolOnlySleepsUntilDeadline() {
        var timer = TimerEngine(settings: .init(statusItemFields: [.symbol]), now: now)
        _ = timer.handle(.start, at: now)
        #expect(TimerRefreshSchedule.nextFireDate(for: timer, at: now) == now.addingTimeInterval(1500))
    }

    @Test func visibleOrAccessibleCountdownRequestsSecondsEvenWithSymbolOnlyMenuBar() {
        var timer = TimerEngine(settings: .init(statusItemFields: [.symbol]), now: now)
        _ = timer.handle(.start, at: now)
        let next = TimerRefreshSchedule.nextFireDate(for: timer, at: now, needsSeconds: true)
        #expect((1...1.02).contains(next.timeIntervalSince(now)))
        let almostDone = now.addingTimeInterval(1499.9995)
        #expect(TimerRefreshSchedule.nextFireDate(for: timer, at: almostDone, needsSeconds: true) == timer.state.deadline)
    }

    @Test func hiddenRunningWithoutSecondsStillResetsProgressAtLocalMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 3,
                                                                   hour: 23, minute: 50)))
        let midnight = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 4)))
        var timer = TimerEngine(settings: .init(statusItemFields: [.sessions]), now: start, calendar: calendar)
        _ = timer.handle(.start, at: start)
        #expect(TimerRefreshSchedule.nextFireDate(for: timer, at: start, calendar: calendar) == midnight)
    }

    @Test func firstRefreshChangesCounterOneSecondAfterStart() {
        var timer = TimerEngine(now: now)
        _ = timer.handle(.start, at: now)
        let next = TimerRefreshSchedule.nextFireDate(for: timer, at: now)
        #expect((1...1.02).contains(next.timeIntervalSince(now)))
        #expect(StatusItemFormatter.formattedTime(timer.remaining(at: next)) == "24:59")
    }

    @Test func fractionalRemainingRefreshesAtNextVisibleBoundaryWithoutPassingDeadline() {
        var timer = TimerEngine(now: now)
        _ = timer.handle(.start, at: now)
        let later = now.addingTimeInterval(0.75)
        let next = TimerRefreshSchedule.nextFireDate(for: timer, at: later)
        #expect((0.25...0.27).contains(next.timeIntervalSince(later)))
        #expect(StatusItemFormatter.formattedTime(timer.remaining(at: next)) == "24:59")
        let almostDone = now.addingTimeInterval(1499.9995)
        #expect(TimerRefreshSchedule.nextFireDate(for: timer, at: almostDone) == timer.state.deadline)
    }

    @Test func idleAndPausedOnlyNeedNextLocalMidnightIncludingDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        let expected = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2)))
        var timer = TimerEngine(now: day, calendar: calendar)
        #expect(TimerRefreshSchedule.nextFireDate(for: timer, at: day, calendar: calendar) == expected)
        #expect(expected.timeIntervalSince(day) == 25 * 3600)
        _ = timer.handle(.start, at: day)
        _ = timer.handle(.pause, at: day.addingTimeInterval(10))
        #expect(TimerRefreshSchedule.nextFireDate(for: timer, at: day.addingTimeInterval(10), calendar: calendar) == expected)
    }
}
