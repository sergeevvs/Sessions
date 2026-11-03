import Foundation
import Testing
@testable import PomodoroCore

struct DeliveryPolicyTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func englishCompletionMessagesCoverBreakAndGoal() {
        var goal = TimerEngine(settings: PomodoroSettings(language: .english, dailyGoal: 1), now: now)
        _ = goal.handle(.start, at: now)
        #expect(CompletionDeliveryPolicy.notification(for: goal)?.body == "Today’s goal is complete. Great work!")
        var rest = TimerEngine(settings: PomodoroSettings(language: .english), now: now)
        _ = rest.handle(.skip, at: now)
        _ = rest.handle(.start, at: now)
        #expect(CompletionDeliveryPolicy.notification(for: rest)?.body == "Break complete. Time to get back to work.")
    }

    @Test func testDeniedNotificationsUseSoundOnlyWhenNotRecovering() {
        let settings = PomodoroSettings()
        #expect(CompletionDeliveryPolicy.shouldPlayFallbackSound(
            settings: settings, authorization: .denied, recovering: false))
        #expect(!CompletionDeliveryPolicy.shouldPlayFallbackSound(
            settings: settings, authorization: .denied, recovering: true))
    }

    @Test func soundAndAlertPreferencesAreIndependent() {
        var settings = PomodoroSettings()
        #expect(!CompletionDeliveryPolicy.shouldPlayFallbackSound(
            settings: settings, authorization: .authorized, recovering: false))
        #expect(CompletionDeliveryPolicy.shouldPlayFallbackSound(
            settings: settings, authorization: .notDetermined, recovering: false))
        settings.notificationsEnabled = false
        #expect(CompletionDeliveryPolicy.shouldPlayFallbackSound(
            settings: settings, authorization: .authorized, recovering: false))
        settings.soundEnabled = false
        #expect(!CompletionDeliveryPolicy.shouldPlayFallbackSound(
            settings: settings, authorization: .denied, recovering: false))
    }

    @Test func onlyRunningEnabledPhaseHasScheduledNotification() {
        var engine = TimerEngine(now: now)
        #expect(CompletionDeliveryPolicy.notification(for: engine) == nil)
        _ = engine.handle(.start, at: now)
        let request = CompletionDeliveryPolicy.notification(for: engine)
        #expect(request?.phaseID == engine.state.phaseID)
        #expect(request?.deadline == now.addingTimeInterval(25 * 60))
        #expect(request?.soundEnabled == true)
        _ = engine.handle(.pause, at: now)
        #expect(CompletionDeliveryPolicy.notification(for: engine) == nil)
        _ = engine.handle(.start, at: now)
        var settings = engine.settings
        settings.notificationsEnabled = false
        _ = engine.handle(.updateSettings(settings), at: now)
        #expect(CompletionDeliveryPolicy.notification(for: engine) == nil)
        settings.notificationsEnabled = true
        _ = engine.handle(.updateSettings(settings), at: now)
        _ = engine.handle(.tick(recovering: false), at: now.addingTimeInterval(25 * 60))
        #expect(engine.state.status == .waiting)
        #expect(CompletionDeliveryPolicy.notification(for: engine) == nil)
    }

    @Test func soundChangesSameRequestAndFinalWorkAnnouncesGoal() {
        var engine = TimerEngine(settings: PomodoroSettings(language: .russian, dailyGoal: 1), now: now)
        _ = engine.handle(.start, at: now)
        let original = CompletionDeliveryPolicy.notification(for: engine)
        #expect(original?.body.contains("План на сегодня выполнен") == true)
        var settings = engine.settings
        settings.soundEnabled = false
        _ = engine.handle(.updateSettings(settings), at: now)
        let silent = CompletionDeliveryPolicy.notification(for: engine)
        #expect(original?.phaseID == silent?.phaseID)
        #expect(original?.deadline == silent?.deadline)
        #expect(original != silent)
        #expect(silent?.soundEnabled == false)
        _ = engine.handle(.tick(recovering: false), at: now.addingTimeInterval(25 * 60))
        #expect(engine.state.status == .waiting)
        #expect(CompletionDeliveryPolicy.notification(for: engine) == nil)
    }

    @Test func breakNotificationOffersReturnToWork() {
        var engine = TimerEngine(settings: .init(language: .russian), now: now)
        _ = engine.handle(.skip, at: now)
        _ = engine.handle(.start, at: now)
        #expect(CompletionDeliveryPolicy.notification(for: engine)?.body.contains("работе") == true)
    }
    @Test func loweringGoalDuringRunningBreakKeepsOrdinaryBreakNotification() {
        var engine = TimerEngine(settings: .init(language: .russian), now: now)
        _ = engine.handle(.start, at: now)
        let end = now.addingTimeInterval(25 * 60)
        _ = engine.handle(.tick(recovering: false), at: end)
        _ = engine.handle(.start, at: end)
        var settings = engine.settings
        settings.dailyGoal = 1
        _ = engine.handle(.updateSettings(settings), at: end)
        #expect(CompletionDeliveryPolicy.notification(for: engine)?.body.contains("Можно вернуться к работе") == true)
    }

    @Test func notificationPredictsGoalUsingDeadlineCalendarDay() throws {
        let calendar = Calendar.current
        let start = try #require(calendar.date(bySettingHour: 23, minute: 50, second: 0, of: now))
        let state = TimerState(phase: .work, status: .ready, phaseID: UUID(), deadline: nil,
                               remainingSeconds: 1500, durationSeconds: 1500,
                               completedSessions: 7, dayStart: calendar.startOfDay(for: start))
        var engine = TimerEngine(settings: .init(language: .russian), state: state, now: start, calendar: calendar)
        _ = engine.handle(.start, at: start)
        #expect(CompletionDeliveryPolicy.notification(for: engine)?.body.contains("Пора отдохнуть") == true)
    }

}
