import Foundation
import Testing

struct TimeZoneChangeTests {
    @Test func productionCalendarTracksTimeZoneChangesWithoutChangingFixedCalendars() throws {
        // Mutating NSTimeZone.default affects only this child process, never another
        // parallel Swift Testing case or the user's system time-zone setting.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = ["AppLanguage", "AppTheme", "Settings", "TimerEngine", "SessionPersistence", "DeliveryPolicy"]
        var program = try sources.map {
            try String(contentsOf: root.appendingPathComponent("Sources/PomodoroCore/\($0).swift"), encoding: .utf8)
        }.joined(separator: "\n")
        program += #"""

        func check(_ condition: Bool, _ message: String) {
            if !condition { print("FAIL: \(message)"); exit(1) }
        }
        NSTimeZone.default = TimeZone(secondsFromGMT: 0)!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = utc.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 20, minute: 50))!
        let settings = PomodoroSettings(language: .russian, dailyGoal: 4)
        var initial = TimerEngine(settings: settings, now: start, calendar: utc).state
        initial.completedSessions = 3
        var live = TimerEngine(settings: settings, state: initial, now: start)
        _ = live.handle(.start, at: start)
        let saved = try SessionPersistence.encode(PersistedSession(settings: settings, state: live.state))
        let restored = SessionPersistence.decode(saved, now: start)
        var fixed = SessionPersistence.decode(saved, now: start, calendar: utc)
        let identity = live.state.phaseID
        let deadline = start.addingTimeInterval(1500)
        check(CompletionDeliveryPolicy.notification(for: live)?.body.contains("План на сегодня выполнен") == true,
              "UTC completion should initially reach the goal")

        NSTimeZone.default = TimeZone(secondsFromGMT: 3 * 3600)!
        let shifted = start.addingTimeInterval(300)
        _ = live.handle(.tick(recovering: false), at: shifted)
        let restoredAfterChange = SessionPersistence.decode(saved, now: shifted)
        let reconciledState = live.state
        let midnight = start.addingTimeInterval(600) // 21:00 UTC = 00:00 in the new zone.
        for useRestored in [false, true] {
            var timer = useRestored ? restored : live
            _ = timer.handle(.tick(recovering: false), at: midnight)
            check(timer.state.status == .running, "local midnight must preserve a running phase")
            check(timer.state.phaseID == identity && timer.state.deadline == deadline, "deadline and identity must survive")
            check(timer.state.completedSessions == 0, "count must reset at new local midnight")
            check(timer.state.dayStart == midnight, "stored day must use new zone")
            check(CompletionDeliveryPolicy.notification(for: timer)?.body.contains("Пора отдохнуть") == true,
                  "notification prediction must use the new completion day")
            _ = timer.handle(.tick(recovering: false), at: deadline)
            check(timer.state.completedSessions == 1 && timer.state.phase == .shortBreak,
                  "completion must belong to new local day and restart the long-break cycle")
            check(timer.state.status == .waiting, "next phase must wait")
            check(timer.handle(.tick(recovering: false), at: deadline).isEmpty, "completion must remain idempotent")
        }
        check(reconciledState == restoredAfterChange.state, "live and restored day reconciliation must agree")
        _ = fixed.handle(.tick(recovering: false), at: midnight)
        check(fixed.state.completedSessions == 3, "explicit UTC calendar must remain deterministic")
        _ = fixed.handle(.tick(recovering: false), at: deadline)
        check(fixed.state.completedSessions == 4 && fixed.state.status == .waiting,
              "fixed UTC completion must retain its original day")
        // A prediction must be recalculated without requiring a reducer transition.
        NSTimeZone.default = TimeZone(secondsFromGMT: 0)!
        let lateStart = start.addingTimeInterval(100 * 60) // 22:30 UTC.
        let lateSettings = PomodoroSettings(language: .russian, workMinutes: 45, dailyGoal: 4)
        var lateState = TimerEngine(settings: lateSettings, now: lateStart, calendar: utc).state
        lateState.completedSessions = 3
        var late = TimerEngine(settings: lateSettings, state: lateState, now: lateStart)
        _ = late.handle(.start, at: lateStart)
        check(CompletionDeliveryPolicy.notification(for: late)?.body.contains("План на сегодня выполнен") == true,
              "23:15 UTC deadline initially reaches the goal")
        let unchanged = late.state
        NSTimeZone.default = TimeZone(secondsFromGMT: 3600)!
        check(CompletionDeliveryPolicy.notification(for: late)?.body.contains("Пора отдохнуть") == true,
              "23:15 UTC deadline becomes tomorrow in UTC+1")
        check(late.state == unchanged, "prediction refresh must not require changing stored day or phase")
        print("PASS: live/restored timezone rollover, running identity, prediction, fixed calendar")
        """#
        let script = directory.appendingPathComponent("main.swift")
        try program.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swift", "-module-cache-path", root.appendingPathComponent(".build/test-caches/swift").path, script.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let message = String(decoding: data, as: UTF8.self)
        #expect(process.terminationStatus == 0, "\(message)")
        #expect(message.contains("PASS: live/restored timezone rollover"), "\(message)")
    }
}
