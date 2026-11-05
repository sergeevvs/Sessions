import Foundation
import Testing
import PomodoroCore
@testable import PomodoroApp

@MainActor
struct NotificationPreviewTests {
    @Test(arguments: [false, true])
    func successfulRetryClearsPreviousNotificationError(authorizationFailed: Bool) async throws {
        let suite = "SessionsPreviewTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = SuspendedNotificationBackend()
        let initialFailure = NSError(domain: "NotificationPreview", code: 1,
                                     userInfo: [NSLocalizedDescriptionKey: "Notifications are not allowed"])
        if authorizationFailed {
            backend.authorization = .notDetermined
            backend.authorizationError = initialFailure
        } else {
            backend.additionError = initialFailure
        }
        let service = NotificationService(backend: backend, soundPlayer: {})
        let model = AppModel(defaults: defaults, notifications: service, startLifecycle: false)
        let state = model.engine.state
        await model.testNotifications()
        #expect(model.cachedIntegrationError?.detail == "Notifications are not allowed")

        backend.authorization = .authorized
        backend.authorizationError = nil
        backend.additionError = nil
        await model.testNotifications()
        #expect(model.integrationError == nil)

        // A failed retry must display its new error, not merely hide the old one.
        backend.additionError = NSError(domain: "NotificationPreview", code: 2,
                                       userInfo: [NSLocalizedDescriptionKey: "Delivery failed again"])
        await model.testNotifications()
        #expect(model.cachedIntegrationError?.detail == "Delivery failed again")

        backend.additionError = nil
        await model.testNotifications()
        #expect(backend.pending["pomodoro.test"] != nil)
        #expect(backend.additions.count == 2)
        #expect(model.notificationStatus == .authorized)
        #expect(model.integrationError == nil)
        #expect(model.engine.state == state)
    }

    @Test(arguments: [IntegrationErrorKind.login, .persistence, .schedule])
    func notificationPreviewPreservesErrorsFromOtherOperations(kind: IntegrationErrorKind) async throws {
        let suite = "SessionsPreviewTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = SuspendedNotificationBackend()
        let service = NotificationService(backend: backend, soundPlayer: {})
        let model = AppModel(defaults: defaults, notifications: service, startLifecycle: false)
        service.onError?(IntegrationError(kind: kind, detail: "Failure in another operation"))
        await model.testNotifications()
        #expect(backend.pending["pomodoro.test"] != nil)
        #expect(model.cachedIntegrationError?.detail == "Failure in another operation")
    }

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
