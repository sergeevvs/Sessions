import Foundation
import Testing
import PomodoroCore
@testable import PomodoroApp

@MainActor
struct NotificationPreviewTests {
    @Test(arguments: [false, true], [false, true])
    func previewRespectsSoundAndBannerSelection(sound: Bool, banner: Bool) async throws {
        let suite = "SessionsPreviewTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = PomodoroSettings(soundEnabled: sound, notificationsEnabled: banner)
        let now = Date()
        defaults.set(try SessionPersistence.encode(.init(settings: settings,
                     state: TimerEngine(settings: settings, now: now).state)), forKey: AppModel.persistenceKey)
        let backend = SuspendedNotificationBackend()
        var playedSounds = 0
        let service = NotificationService(backend: backend, soundPlayer: { playedSounds += 1 })
        let model = AppModel(defaults: defaults, notifications: service, clock: { now }, startLifecycle: false)
        let originalState = model.engine.state
        await model.testNotifications()

        #expect(playedSounds == (sound && !banner ? 1 : 0))
        #expect(backend.additions.count == (banner ? 1 : 0))
        if banner {
            #expect(backend.pending["pomodoro.test"]?.soundEnabled == sound)
        }
        #expect(model.engine.state == originalState)
        #expect(model.engine.settings == settings)
    }

    @Test func soundOnlyPreviewDoesNotRequireNotificationPermission() async throws {
        let suite = "SessionsPreviewTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = PomodoroSettings(soundEnabled: true, notificationsEnabled: false)
        defaults.set(try SessionPersistence.encode(.init(settings: settings,
                     state: TimerEngine(settings: settings, now: Date()).state)), forKey: AppModel.persistenceKey)
        let backend = SuspendedNotificationBackend()
        backend.authorization = .denied
        var playedSounds = 0
        let service = NotificationService(backend: backend, soundPlayer: { playedSounds += 1 })
        let model = AppModel(defaults: defaults, notifications: service, startLifecycle: false)
        await model.testNotifications()
        #expect(playedSounds == 1)
        #expect(backend.additions.isEmpty)
    }
}
