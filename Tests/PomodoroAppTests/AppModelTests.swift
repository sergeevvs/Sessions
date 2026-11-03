import Foundation
import Testing
import PomodoroCore
import Observation
@testable import PomodoroApp

@MainActor
struct AppModelTests {
    @Test func manualNavigationPersistsProgressWithoutPlayingCompletionSound() throws {
        let suite = "PomodoroTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 60 * 60)
        var sounds = 0
        let service = NotificationService(backend: ModelNotificationBackend(), soundPlayer: { sounds += 1 })
        let model = AppModel(defaults: defaults, notifications: service, clock: { now }, startLifecycle: false)
        model.send(.start)
        now = now.addingTimeInterval(10)
        model.send(.skip)
        #expect(model.engine.state.completedSessions == 1)
        #expect(model.engine.state.phase == .shortBreak)
        #expect(model.engine.state.deadline == nil)
        let forward = SessionPersistence.decode(defaults.data(forKey: AppModel.persistenceKey), now: now)
        #expect(forward.state == model.engine.state)
        model.send(.reset)
        #expect(model.engine.state.completedSessions == 0)
        #expect(model.engine.state.phase == .work)
        #expect(model.engine.state.status == .ready)
        let backward = SessionPersistence.decode(defaults.data(forKey: AppModel.persistenceKey), now: now)
        #expect(backward.state == model.engine.state)
        #expect(sounds == 0)
    }

    @Test func ordinaryTickPublishesClockButNotUnchangedEngine() throws {
        let suite = "PomodoroTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date()
        let model = AppModel(defaults: defaults, notifications: NotificationService(backend: ModelNotificationBackend()),
                             clock: { now }, startLifecycle: false)
        model.send(.start)
        let engineChanged = ObservationFlag()
        withObservationTracking { _ = model.engine } onChange: { engineChanged.mark() }
        now = now.addingTimeInterval(1)
        model.send(.tick(recovering: false))
        #expect(!engineChanged.value)
        #expect(model.now == now)
        model.send(.pause)
        #expect(engineChanged.value)
    }

    @Test func idleTickDoesNotPublishAnyDisplayChange() throws {
        let suite = "PomodoroTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date()
        let model = AppModel(defaults: defaults, notifications: NotificationService(backend: ModelNotificationBackend()),
                             clock: { now }, startLifecycle: false)
        let displayChanged = ObservationFlag()
        withObservationTracking { _ = model.engine; _ = model.now } onChange: { displayChanged.mark() }
        now = now.addingTimeInterval(1)
        model.send(.tick(recovering: false))
        #expect(!displayChanged.value)
    }
    @Test func changingLanguagePersistsStateAndTranslatesCachedError() throws {
        let suite = "PomodoroTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = NotificationService(backend: ModelNotificationBackend())
        let model = AppModel(defaults: defaults, notifications: service, startLifecycle: false)
        model.updateSettings { $0.language = .russian }
        model.send(.start)
        model.send(.pause)
        let state = model.engine.state
        service.onError?(IntegrationError(kind: .schedule, detail: "OS detail"))
        #expect(model.integrationError == "Не удалось запланировать уведомление: OS detail")
        model.updateSettings { $0.language = .english }
        #expect(model.engine.state == state)
        #expect(model.integrationError == "Could not schedule notification: OS detail")
        let restored = SessionPersistence.decode(defaults.data(forKey: AppModel.persistenceKey), now: model.now)
        #expect(restored.settings.language == .english)
        #expect(restored.state == state)
    }

    @Test func changingAppearancePersistsSelectionWithoutChangingPausedTimer() throws {
        let suite = "PomodoroTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, notifications: NotificationService(backend: ModelNotificationBackend()), startLifecycle: false)
        model.send(.start)
        model.send(.pause)
        let state = model.engine.state
        model.updateSettings { $0.theme = .dark }
        #expect(model.engine.state == state)
        let restored = SessionPersistence.decode(defaults.data(forKey: AppModel.persistenceKey), now: model.now)
        #expect(restored.settings.theme == .dark)
        #expect(restored.state == state)
    }

    @Test func transitionsPersistButTicksDoNotRewriteSnapshot() throws {
        let suite = "PomodoroTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date()
        let model = AppModel(defaults: defaults, notifications: NotificationService(backend: ModelNotificationBackend()),
                             clock: { now }, startLifecycle: false)
        model.send(.start)
        let started = defaults.data(forKey: AppModel.persistenceKey)
        #expect(started != nil)
        now = now.addingTimeInterval(2)
        model.send(.tick(recovering: false))
        #expect(defaults.data(forKey: AppModel.persistenceKey) == started)
        model.send(.pause)
        #expect(defaults.data(forKey: AppModel.persistenceKey) != started)
        #expect(model.engine.state.status == .paused)
    }

    @Test func timeZoneChangeRefreshesPendingNotificationsWithoutAStateTransition() async throws {
        let suite = "PomodoroTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let backend = ModelNotificationBackend()
        let model = AppModel(defaults: defaults, notifications: NotificationService(backend: backend),
                             clock: { now }, startLifecycle: false)
        for _ in 0..<100 {
            if model.notificationStatus == .denied { break }
            await Task.yield()
        }
        model.send(.start)
        for _ in 0..<100 { await Task.yield() }
        let state = model.engine.state
        #expect(backend.added.isEmpty)
        backend.authorization = .authorized
        // Exercise the lifecycle callback with no clock/day/phase state transition.
        model.handleTimeZoneChange()
        for _ in 0..<100 {
            if !backend.added.isEmpty { break }
            await Task.yield()
        }
        #expect(model.engine.state == state)
        #expect(model.notificationStatus == .authorized)
        let notification = try #require(backend.added.last)
        #expect(notification.phaseID == state.phaseID)
        #expect(notification.deadline == now.addingTimeInterval(1500))
        #expect(notification.body.contains("Time for a break"))
    }

    @Test func sleepRecoveryIsSilentAndNeverStartsFollowingPhase() throws {
        let suite = "PomodoroTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Keep the simulated one-hour sleep within one day, including runs
        // after 23:00 when a wall-clock fixture would reset today's count.
        var now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 60 * 60)
        var sounds = 0
        let notifications = NotificationService(backend: ModelNotificationBackend(), soundPlayer: { sounds += 1 })
        let model = AppModel(defaults: defaults, notifications: notifications, clock: { now }, startLifecycle: false)
        model.updateSettings { $0.automaticTransitions = true }
        model.send(.start)
        model.handleSleep()
        now = now.addingTimeInterval(60 * 60)
        model.send(.tick(recovering: false))
        #expect(model.engine.state.completedSessions == 0)
        model.handleWake()
        #expect(model.engine.state.completedSessions == 1)
        #expect(model.engine.state.status == .waiting)
        #expect(sounds == 0)
    }

    @Test func awakeCompletionPlaysSingleFallbackSound() throws {
        let suite = "PomodoroTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date()
        var sounds = 0
        let notifications = NotificationService(backend: ModelNotificationBackend(), soundPlayer: { sounds += 1 })
        let model = AppModel(defaults: defaults, notifications: notifications, clock: { now }, startLifecycle: false)
        model.send(.start)
        now = now.addingTimeInterval(25 * 60)
        model.send(.tick(recovering: false))
        model.send(.tick(recovering: false))
        #expect(sounds == 1)
        #expect(model.engine.state.completedSessions == 1)
    }
}

private final class ObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false
    var value: Bool { lock.withLock { marked } }
    func mark() { lock.withLock { marked = true } }
}

@MainActor
private final class ModelNotificationBackend: NotificationBackend {
    var authorization: NotificationAuthorization = .denied
    var added: [ScheduledNotification] = []
    func notificationAuthorization() async -> NotificationAuthorization { authorization }
    func requestAuthorization() async throws {}
    func pendingIdentifiers() async -> [String] { [] }
    func removePending(identifiers: [String]) {}
    func add(_ notification: ScheduledNotification, identifier: String) async throws { added.append(notification) }
}
