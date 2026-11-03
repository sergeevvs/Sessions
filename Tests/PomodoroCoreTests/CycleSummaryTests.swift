import Testing
@testable import PomodoroCore

@Suite struct CycleSummaryTests {
    @Test func defaultsCountOnlyBreaksBetweenWorkSessions() {
        let summary = CycleSummary(settings: PomodoroSettings())
        #expect(summary.workMinutes == 200)
        #expect(summary.breakMinutes == 45)
        #expect(summary.totalMinutes == 245)
        #expect(summary.shortBreakCount == 6)
        #expect(summary.longBreakCount == 1)
    }

    @Test func disabledLongBreaksBecomeShortBreaks() {
        let summary = CycleSummary(settings: PomodoroSettings(longBreakEnabled: false))
        #expect(summary.breakMinutes == 35)
        #expect(summary.totalMinutes == 235)
        #expect(summary.shortBreakCount == 7)
        #expect(summary.longBreakCount == 0)
    }

    @Test func singleSessionHasNoBreak() {
        let summary = CycleSummary(settings: PomodoroSettings(dailyGoal: 1))
        #expect(summary.workMinutes == 25)
        #expect(summary.breakMinutes == 0)
        #expect(summary.totalMinutes == 25)
        #expect(summary.shortBreakCount == 0)
        #expect(summary.longBreakCount == 0)
    }

    @Test func finalSessionDoesNotTriggerLongBreak() {
        let summary = CycleSummary(settings: PomodoroSettings(dailyGoal: 4))
        #expect(summary.totalMinutes == 115)
        #expect(summary.shortBreakCount == 3)
        #expect(summary.longBreakCount == 0)
    }

    @Test func multipleLongBreaksReplaceShortBreaks() {
        let summary = CycleSummary(settings: PomodoroSettings(dailyGoal: 9))
        #expect(summary.workMinutes == 225)
        #expect(summary.breakMinutes == 60)
        #expect(summary.totalMinutes == 285)
        #expect(summary.shortBreakCount == 6)
        #expect(summary.longBreakCount == 2)
    }

    @Test func validatedExtremeSettingsFitAndFormat() {
        let settings = PomodoroSettings(workMinutes: 999, shortBreakMinutes: 999,
                                        longBreakMinutes: 999, longBreakInterval: 0,
                                        dailyGoal: 999).validated()
        let summary = CycleSummary(settings: settings)
        #expect(summary.totalMinutes == 6360)
        #expect(CycleSummary.formattedDuration(minutes: summary.totalMinutes, language: .russian) == "106 ч")
    }

    @Test(arguments: [(245, "4 ч 5 мин"), (45, "45 мин"), (180, "3 ч"), (0, "0 мин")])
    func formatsCompactDurations(minutes: Int, expected: String) {
        #expect(CycleSummary.formattedDuration(minutes: minutes, language: .russian) == expected)
    }
}
