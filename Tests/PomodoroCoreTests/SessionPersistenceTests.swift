import Foundation
import Testing
@testable import PomodoroCore

struct SessionPersistenceTests {
    @Test func launchPreparesWorkInsteadOfAnUnstartedBreak() throws {
        for phase in [TimerPhase.shortBreak, .longBreak] {
            for status in [TimerStatus.ready, .waiting] {
                let settings = PomodoroSettings(workMinutes: 35)
                var state = TimerEngine(settings: settings, now: now, calendar: calendar).state
                state.phase = phase; state.status = status; state.completedSessions = 3
                let data = try SessionPersistence.encode(.init(settings: settings, state: state))
                let restored = SessionPersistence.restoreForLaunch(data, now: now, calendar: calendar)
                #expect(restored.state.phase == .work)
                #expect(restored.state.status == .ready)
                #expect(restored.remaining(at: now) == 2100)
                #expect(restored.state.completedSessions == 3)
                #expect(restored.settings == settings)
            }
        }
    }

    @Test func launchKeepsActiveAndPausedBreaks() throws {
        for status in [TimerStatus.running, .paused] {
            var timer = TimerEngine(now: now, calendar: calendar)
            _ = timer.handle(.skip, at: now)
            _ = timer.handle(.start, at: now)
            if status == .paused { _ = timer.handle(.pause, at: now) }
            let restored = SessionPersistence.restoreForLaunch(try snapshot(timer), now: now, calendar: calendar)
            #expect(restored.state == timer.state)
        }
    }

    @Test func launchAfterExpiredWorkPreparesWorkAndCountsCompletionOnce() throws {
        var timer = TimerEngine(settings: .init(automaticTransitions: true), now: now, calendar: calendar)
        _ = timer.handle(.start, at: now)
        let later = now.addingTimeInterval(1600)
        let restored = SessionPersistence.restoreForLaunch(try snapshot(timer), now: later, calendar: calendar)
        #expect(restored.state.phase == .work)
        #expect(restored.state.status == .ready)
        #expect(restored.state.completedSessions == 1)
        #expect(restored.remaining(at: later) == 1500)
        let again = SessionPersistence.restoreForLaunch(try snapshot(restored), now: later, calendar: calendar)
        #expect(again.state == restored.state)
    }
    private let now = Date(timeIntervalSince1970: 1_793_606_400)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func snapshot(_ timer: TimerEngine) throws -> Data {
        try SessionPersistence.encode(PersistedSession(settings: timer.settings, state: timer.state))
    }

    private func modified(_ data: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        change(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func defaultSettingsUseEnglishAndSystemAppearance() {
        #expect(PomodoroSettings().language == .english)
        #expect(PomodoroSettings().theme == .system)
    }

    @Test func appearanceAndLanguageRoundTrip() throws {
        for (theme, rawValue) in [(AppTheme.system, "system"), (.light, "light"), (.dark, "dark")] {
            let timer = TimerEngine(settings: .init(language: .russian, theme: theme), now: now, calendar: calendar)
            let restored = SessionPersistence.decode(try snapshot(timer), now: now, calendar: calendar)
            #expect(restored.settings.theme == theme)
            #expect(restored.settings.language == .russian)
            let object = try #require(JSONSerialization.jsonObject(with: snapshot(timer)) as? [String: Any])
            let settings = try #require(object["settings"] as? [String: Any])
            #expect(settings["theme"] as? String == rawValue)
        }
    }

    @Test func invalidAppearancePreservesRunningAndPausedRussianSessions() throws {
        for paused in [false, true] {
            var timer = TimerEngine(settings: .init(language: .russian, workMinutes: 30), now: now, calendar: calendar)
            _ = timer.handle(.start, at: now)
            if paused { _ = timer.handle(.pause, at: now.addingTimeInterval(10)) }
            for value: Any? in [nil, NSNull(), "unknown"] {
                let data = try modified(snapshot(timer)) { object in
                    var settings = object["settings"] as! [String: Any]
                    settings["theme"] = value
                    object["settings"] = settings
                }
                let restored = SessionPersistence.decode(data, now: now, calendar: calendar)
                #expect(restored.settings.theme == .system)
                #expect(restored.settings.language == .russian)
                #expect(restored.settings.workMinutes == 30)
                #expect(restored.state == timer.state)
            }
        }
    }

    @Test func omittedLanguageHelpersUseEnglish() {
        #expect(StatusItemFormatter.formattedProgress(completed: 3, goal: 8) == "3 of 8")
        #expect(CycleSummary.formattedDuration(minutes: 65) == "1 hr 5 min")
    }

    @Test func englishLegacySettingsDriveOutputAndPersist() throws {
        var timer = TimerEngine(now: now, calendar: calendar)
        _ = timer.handle(.start, at: now)
        _ = timer.handle(.pause, at: now.addingTimeInterval(100))
        let data = try modified(snapshot(timer)) { object in
            object["settings"] = ["language": "en", "statusItemFields": ["phase", "sessions"]]
        }
        let restored = SessionPersistence.decode(data, now: now, calendar: calendar)
        #expect(restored.state == timer.state)
        #expect(StatusItemFormatter.content(for: restored, at: now).title == "Work | 0 of 8")
        #expect(StatusItemFormatter.content(for: restored, at: now).accessibilityLabel.contains("Paused"))
        let encoded = try snapshot(restored)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let settings = try #require(object["settings"] as? [String: Any])
        #expect(settings["language"] as? String == "en")
        var running = restored
        _ = running.handle(.start, at: now)
        #expect(CompletionDeliveryPolicy.notification(for: running)?.body == "Work session complete. Time for a break.")
    }

    @Test func unknownOrMissingLanguageDefaultsWithoutLosingState() throws {
        var timer = TimerEngine(now: now, calendar: calendar)
        _ = timer.handle(.start, at: now)
        _ = timer.handle(.pause, at: now.addingTimeInterval(10))
        for value: Any? in [nil, "xx", NSNull()] {
            let data = try modified(snapshot(timer)) { object in
                var settings = object["settings"] as! [String: Any]
                settings["language"] = value
                object["settings"] = settings
            }
            let restored = SessionPersistence.decode(data, now: now, calendar: calendar)
            #expect(restored.settings.language == .english)
            #expect(restored.state == timer.state)
        }
    }

    @Test func englishDurationAndLiveLanguageChange() {
        #expect(CycleSummary.formattedDuration(minutes: 245, language: .english) == "4 hr 5 min")
        #expect(CycleSummary.formattedDuration(minutes: 60, language: .english) == "1 hr")
        #expect(CycleSummary.formattedDuration(minutes: 5, language: .english) == "5 min")
        var timer = TimerEngine(settings: PomodoroSettings(language: .russian, statusItemFields: [.phase, .sessions]), now: now)
        let state = timer.state
        var settings = timer.settings
        settings.language = .english
        _ = timer.handle(.updateSettings(settings), at: now)
        #expect(timer.state == state)
        #expect(StatusItemFormatter.content(for: timer, at: now).title == "Work | 0 of 8")
    }

    @Test func testLegacyCounterSelectionMigratesWithoutLosingPausedState() throws {
        var timer = TimerEngine(now: now, calendar: calendar)
        _ = timer.handle(.start, at: now)
        _ = timer.handle(.pause, at: now.addingTimeInterval(100))
        var state = timer.state
        state.completedSessions = 3
        let original = try SessionPersistence.encode(PersistedSession(settings: timer.settings, state: state))
        for fields in [["completed"], ["goal"], ["completed", "goal"], ["time", "goal"]] {
            let data = try modified(original) { object in
                object["settings"] = ["language": "ru", "workMinutes": 30, "dailyGoal": 8, "statusItemFields": fields]
            }
            let restored = SessionPersistence.decode(data, now: now, calendar: calendar)
            #expect(restored.state == state)
            #expect(restored.settings.workMinutes == 30)
            #expect(StatusItemFormatter.content(for: restored, at: now).title ==
                    (fields.contains("time") ? "23:20 | 3 из 8" : "3 из 8"))
            let encoded = try snapshot(restored)
            let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            let settings = try #require(object["settings"] as? [String: Any])
            let savedFields = try #require(settings["statusItemFields"] as? [String])
            #expect(Set(savedFields) == (fields.contains("time") ? ["time", "sessions"] : ["sessions"]))
        }
    }

    @Test func testFieldSelectionsWithoutLegacyCountersAndInvalidSelections() throws {
        let original = try snapshot(TimerEngine(now: now, calendar: calendar))
        for (fields, expected) in [(["symbol", "time"], Set<StatusItemField>([.symbol, .time])),
                                   (["sessions"], [.sessions]),
                                   (["time", "unknown"], [.time]), ([], [.time])] {
            let data = try modified(original) { object in
                object["settings"] = ["statusItemFields": fields]
            }
            let restored = SessionPersistence.decode(data, now: now, calendar: calendar)
            #expect(restored.settings.statusItemFields == expected)
        }
    }

    @Test func testCorruptSessionFallsBackToDefaults() {
        let restored = SessionPersistence.decode(Data("broken".utf8), now: now)
        #expect(restored.settings == PomodoroSettings())
        #expect(restored.state.status == .ready)
        for data in [nil, Data(), Data("{}".utf8), Data("null".utf8)] {
            let timer = SessionPersistence.decode(data, now: now, calendar: calendar)
            #expect(timer.settings == PomodoroSettings())
            #expect(timer.remaining(at: now) == 1500)
            #expect(timer.state.status == .ready)
        }
    }

    @Test func testRunningRoundTripRetainsDeadlineIdentityAndElapsedTime() throws {
        var timer = TimerEngine(now: now, calendar: calendar)
        _ = timer.handle(.start, at: now)
        let data = try snapshot(timer)
        let restored = SessionPersistence.decode(data, now: now.addingTimeInterval(100), calendar: calendar)
        #expect(restored.state == timer.state)
        #expect(restored.remaining(at: now.addingTimeInterval(100)) == 1400)
        let saved = try JSONDecoder().decode(PersistedSession.self, from: data)
        #expect(saved.version == 1)
    }

    @Test func testPausedRoundTripPreservesRemainderAndOriginalDurationAfterSettingsChange() throws {
        var timer = TimerEngine(now: now, calendar: calendar)
        _ = timer.handle(.start, at: now)
        _ = timer.handle(.pause, at: now.addingTimeInterval(100))
        var settings = timer.settings
        settings.workMinutes = 1
        _ = timer.handle(.updateSettings(settings), at: now.addingTimeInterval(100))
        let restored = SessionPersistence.decode(try snapshot(timer), now: now.addingTimeInterval(500), calendar: calendar)
        #expect(restored.settings.workMinutes == 1)
        #expect(restored.state == timer.state)
        #expect(restored.remaining(at: now.addingTimeInterval(500)) == 1400)
    }

    @Test func testOversizedFinitePausedDurationsResetForEveryPhase() throws {
        for (phase, maximum, fallback) in [(TimerPhase.work, 10800.0, 1500.0),
                                            (.shortBreak, 3600.0, 300.0),
                                            (.longBreak, 7200.0, 900.0)] {
            for invalid in [maximum + 1, 1e30] {
                var state = TimerEngine(now: now, calendar: calendar).state
                state.phase = phase
                state.status = .paused
                state.durationSeconds = invalid
                state.remainingSeconds = invalid
                let data = try SessionPersistence.encode(PersistedSession(settings: .init(), state: state))
                let restored = SessionPersistence.decode(data, now: now, calendar: calendar)
                #expect(restored.state.status == .ready)
                #expect(restored.state.phase == phase)
                #expect(restored.remaining(at: now) == fallback)
                #expect(restored.state.completedSessions == 0)
            }
        }
    }

    @Test func testMaximumCapturedDurationsSurviveSmallerSettingsOnRestoration() throws {
        for (phase, maximum) in [(TimerPhase.work, 10800.0), (.shortBreak, 3600.0), (.longBreak, 7200.0)] {
            for status in [TimerStatus.running, .paused] {
                let settings = PomodoroSettings(workMinutes: 1, shortBreakMinutes: 1, longBreakMinutes: 1)
                var state = TimerEngine(settings: settings, now: now, calendar: calendar).state
                state.phase = phase
                state.status = status
                state.durationSeconds = maximum
                state.remainingSeconds = maximum - 30
                state.deadline = status == .running ? now.addingTimeInterval(maximum - 30) : nil
                let data = try SessionPersistence.encode(PersistedSession(settings: settings, state: state))
                let restored = SessionPersistence.decode(data, now: now, calendar: calendar)
                #expect(restored.state == state)
                #expect(restored.remaining(at: now) == maximum - 30)
            }
        }
    }

    @Test func testMissingOptionalSettingsRetainDefaultsAndRunningState() throws {
        var timer = TimerEngine(now: now, calendar: calendar)
        _ = timer.handle(.start, at: now)
        let data = try modified(snapshot(timer)) { object in
            object["settings"] = ["workMinutes": 25]
        }
        let restored = SessionPersistence.decode(data, now: now.addingTimeInterval(100), calendar: calendar)
        #expect(restored.settings == PomodoroSettings())
        #expect(restored.settings.longBreakEnabled)
        #expect(restored.state == timer.state)
        #expect(restored.remaining(at: now.addingTimeInterval(100)) == 1400)
    }

    @Test func testMalformedOptionalSettingsUseDefaultsWithoutLosingPause() throws {
        var timer = TimerEngine(now: now, calendar: calendar)
        _ = timer.handle(.start, at: now)
        _ = timer.handle(.pause, at: now.addingTimeInterval(100))
        let data = try modified(snapshot(timer)) { object in
            object["settings"] = ["workMinutes": "bad", "longBreakEnabled": NSNull(),
                                  "dailyGoal": 12, "statusItemFields": ["unknown"]]
        }
        let restored = SessionPersistence.decode(data, now: now, calendar: calendar)
        #expect(restored.state == timer.state)
        #expect(restored.settings.workMinutes == 25)
        #expect(restored.settings.longBreakEnabled)
        #expect(restored.settings.dailyGoal == 12)
        #expect(restored.settings.statusItemFields == [.time])
    }

    @Test func testInvalidNumbersNormalizeAndEmptySelectionRemainsVisible() throws {
        let timer = TimerEngine(now: now, calendar: calendar)
        let data = try modified(snapshot(timer)) { object in
            object["settings"] = ["workMinutes": -1, "shortBreakMinutes": 100,
                                  "longBreakMinutes": 0, "longBreakInterval": 100,
                                  "dailyGoal": 0, "statusItemFields": []]
        }
        let restored = SessionPersistence.decode(data, now: now, calendar: calendar)
        #expect(restored.settings.workMinutes == 1)
        #expect(restored.settings.shortBreakMinutes == 60)
        #expect(restored.settings.longBreakMinutes == 1)
        #expect(restored.settings.longBreakInterval == 12)
        #expect(restored.settings.dailyGoal == 1)
        #expect(restored.settings.statusItemFields == [.time])
        #expect(restored.remaining(at: now) == 60)
    }

    @Test func testExpiredRecoveryCountsOnlyOnceAndWaitsDespiteAutomaticMode() throws {
        var timer = TimerEngine(settings: PomodoroSettings(automaticTransitions: true), now: now, calendar: calendar)
        _ = timer.handle(.start, at: now)
        let later = now.addingTimeInterval(20000)
        let restored = SessionPersistence.decode(try snapshot(timer), now: later, calendar: calendar)
        #expect(restored.state.completedSessions == 1)
        #expect(restored.state.phase == .shortBreak)
        #expect(restored.state.status == .waiting)
        #expect(restored.state.deadline == nil)
        #expect(restored.remaining(at: later) == 300)
        let again = SessionPersistence.decode(try snapshot(restored), now: later, calendar: calendar)
        #expect(again.state == restored.state)
    }

    @Test func testRecoveryAttributesYesterdayWorkBeforeDayRollover() throws {
        let yesterday = calendar.startOfDay(for: now).addingTimeInterval(-3600)
        var timer = TimerEngine(now: yesterday, calendar: calendar)
        _ = timer.handle(.start, at: yesterday)
        let restored = SessionPersistence.decode(try snapshot(timer), now: now, calendar: calendar)
        #expect(restored.state.completedSessions == 0)
        #expect(restored.state.status == .waiting)
        #expect(restored.state.dayStart == calendar.startOfDay(for: now))
    }

    @Test func testReadyAndWaitingRecoveryRestoreFullConfiguredDuration() throws {
        for status in [TimerStatus.ready, .waiting] {
            let timer = TimerEngine(now: now, calendar: calendar)
            var state = timer.state
            state.status = status
            state.remainingSeconds = 0
            let data = try SessionPersistence.encode(PersistedSession(settings: timer.settings, state: state))
            let restored = SessionPersistence.decode(data, now: now, calendar: calendar)
            #expect(restored.state.status == status)
            #expect(restored.remaining(at: now) == 1500)
        }
    }

    @Test func testInvalidRunningStateResetsSafelyWithoutAwardingSession() throws {
        let timer = TimerEngine(now: now, calendar: calendar)
        var state = timer.state
        state.status = .running
        state.deadline = nil
        state.durationSeconds = -1
        state.remainingSeconds = -10
        state.completedSessions = -5
        let data = try SessionPersistence.encode(PersistedSession(settings: timer.settings, state: state))
        let restored = SessionPersistence.decode(data, now: now, calendar: calendar)
        #expect(restored.state.status == .ready)
        #expect(restored.remaining(at: now) == 1500)
        #expect(restored.state.completedSessions == 0)
    }

    @Test func testUnsupportedVersionAndMalformedStateDefaultSafely() throws {
        let timer = TimerEngine(settings: PomodoroSettings(workMinutes: 30), now: now, calendar: calendar)
        for data in [try modified(snapshot(timer)) { $0["version"] = 99 },
                     try modified(snapshot(timer)) { $0["state"] = ["status": "unknown"] }] {
            let restored = SessionPersistence.decode(data, now: now, calendar: calendar)
            #expect(restored.settings == PomodoroSettings())
            #expect(restored.state.status == .ready)
            #expect(restored.remaining(at: now) == 1500)
        }
    }
}
