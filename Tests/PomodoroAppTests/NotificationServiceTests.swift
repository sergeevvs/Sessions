import Foundation
import Testing
import PomodoroCore
@testable import PomodoroApp

@MainActor
final class SuspendedNotificationBackend: NotificationBackend {
    var pending: [String: ScheduledNotification] = [:]
    var additions: [ScheduledNotification] = []
    var holdAuthorization = false
    var holdAdd = false
    var authorizationWaiter: CheckedContinuation<NotificationAuthorization, Never>?
    var addWaiter: CheckedContinuation<Void, Never>?
    var authorization: NotificationAuthorization = .authorized
    var authorizationError: Error?
    var additionError: Error?

    func notificationAuthorization() async -> NotificationAuthorization {
        if holdAuthorization {
            return await withCheckedContinuation { authorizationWaiter = $0 }
        }
        return authorization
    }
    func requestAuthorization() async throws {
        if let authorizationError { throw authorizationError }
    }
    func pendingIdentifiers() async -> [String] { Array(pending.keys) }
    func removePending(identifiers: [String]) {
        for id in identifiers { pending[id] = nil }
    }
    func add(_ notification: ScheduledNotification, identifier: String) async throws {
        if holdAdd { await withCheckedContinuation { addWaiter = $0 } }
        if let additionError { throw additionError }
        pending[identifier] = notification
        additions.append(notification)
    }
}

@MainActor
struct NotificationServiceTests {
    @Test func languageChangeReplacesPendingAndTestNotification() async {
        let backend = SuspendedNotificationBackend()
        let service = NotificationService(backend: backend)
        let now = Date()
        var engine = TimerEngine(settings: .init(language: .russian), now: now)
        _ = engine.handle(.start, at: now)
        await service.synchronize(with: engine)
        let original = engine.state
        var settings = engine.settings
        settings.language = .english
        _ = engine.handle(.updateSettings(settings), at: now)
        await service.synchronize(with: engine)
        #expect(engine.state == original)
        #expect(backend.pending.values.first?.title == "Sessions")
        #expect(backend.pending.values.first?.body == "Work session complete. Time for a break.")
        await service.testNotification(soundEnabled: false, language: .english)
        #expect(backend.pending["pomodoro.test"]?.title == "Sessions")
        #expect(backend.pending["pomodoro.test"]?.body == "Notification test. Everything is ready.")
    }

    @Test func testNotificationDefaultsToEnglish() async {
        let backend = SuspendedNotificationBackend()
        let service = NotificationService(backend: backend)
        await service.testNotification(soundEnabled: false)
        #expect(backend.pending["pomodoro.test"]?.body == "Notification test. Everything is ready.")
    }

    @Test func pauseDuringAuthorizationNeverAddsStaleRequest() async {
        let backend = SuspendedNotificationBackend()
        backend.holdAuthorization = true
        let service = NotificationService(backend: backend)
        var engine = TimerEngine(now: Date())
        _ = engine.handle(.start, at: Date())
        let running = engine
        let synchronization = Task { await service.synchronize(with: running) }
        while backend.authorizationWaiter == nil { await Task.yield() }
        _ = engine.handle(.pause, at: Date())
        await service.synchronize(with: engine)
        backend.holdAuthorization = false
        backend.authorizationWaiter?.resume(returning: .authorized)
        await synchronization.value
        #expect(backend.additions.isEmpty)
        #expect(backend.pending.isEmpty)
    }

    @Test func soundReplacementWaitsForOldAddAndSurvivesCleanup() async {
        let backend = SuspendedNotificationBackend()
        backend.holdAdd = true
        let service = NotificationService(backend: backend)
        var engine = TimerEngine(now: Date())
        _ = engine.handle(.start, at: Date())
        let running = engine
        let synchronization = Task { await service.synchronize(with: running) }
        while backend.addWaiter == nil { await Task.yield() }
        var settings = engine.settings
        settings.soundEnabled = false
        _ = engine.handle(.updateSettings(settings), at: Date())
        await service.synchronize(with: engine)
        backend.holdAdd = false
        backend.addWaiter?.resume()
        await synchronization.value
        #expect(backend.pending.count == 1)
        #expect(backend.pending.values.first?.soundEnabled == false)
        #expect(backend.additions.count == 2)
    }

    @Test func pauseWhileAddIsInFlightRemovesItAfterCompletion() async {
        let backend = SuspendedNotificationBackend()
        backend.holdAdd = true
        let service = NotificationService(backend: backend)
        var engine = TimerEngine(now: Date())
        _ = engine.handle(.start, at: Date())
        let running = engine
        let synchronization = Task { await service.synchronize(with: running) }
        while backend.addWaiter == nil { await Task.yield() }
        _ = engine.handle(.pause, at: Date())
        await service.synchronize(with: engine)
        backend.holdAdd = false
        backend.addWaiter?.resume()
        await synchronization.value
        #expect(backend.pending.isEmpty)
    }
    @Test func naturalCompletionPreservesTheOnlyScheduledDelivery() async {
        let backend = SuspendedNotificationBackend()
        let service = NotificationService(backend: backend)
        let now = Date()
        var engine = TimerEngine(now: now)
        _ = engine.handle(.start, at: now)
        await service.synchronize(with: engine)
        let phaseID = engine.state.phaseID
        _ = engine.handle(.tick(recovering: false), at: now.addingTimeInterval(25 * 60))
        service.phaseCompleted(phaseID, recovering: false)
        await service.synchronize(with: engine)
        #expect(backend.pending.count == 1)
        #expect(backend.additions.count == 1)
    }

    @Test func recoveryCancelsOldDeliveryAndNeverAddsAnother() async {
        let backend = SuspendedNotificationBackend()
        let service = NotificationService(backend: backend)
        let now = Date()
        var engine = TimerEngine(now: now)
        _ = engine.handle(.start, at: now)
        await service.synchronize(with: engine)
        let phaseID = engine.state.phaseID
        _ = engine.handle(.tick(recovering: true), at: now.addingTimeInterval(25 * 60))
        service.phaseCompleted(phaseID, recovering: true)
        await service.synchronize(with: engine)
        #expect(backend.pending.isEmpty)
        #expect(backend.additions.count == 1)
    }

    @Test(arguments: [false, true])
    func completionDoesNotProtectInFlightRequestInvalidatedBySettings(disableAlerts: Bool) async {
        let backend = SuspendedNotificationBackend()
        backend.holdAdd = true
        let service = NotificationService(backend: backend)
        let now = Date()
        var engine = TimerEngine(now: now)
        _ = engine.handle(.start, at: now)
        let running = engine
        let synchronization = Task { await service.synchronize(with: running) }
        while backend.addWaiter == nil { await Task.yield() }
        var settings = engine.settings
        if disableAlerts { settings.notificationsEnabled = false }
        else { settings.soundEnabled = false }
        _ = engine.handle(.updateSettings(settings), at: now)
        await service.synchronize(with: engine)
        let phaseID = engine.state.phaseID
        _ = engine.handle(.tick(recovering: false), at: now.addingTimeInterval(25 * 60))
        service.phaseCompleted(phaseID, recovering: false)
        await service.synchronize(with: engine)
        backend.holdAdd = false
        backend.addWaiter?.resume()
        await synchronization.value
        #expect(backend.pending.isEmpty)
        #expect(backend.additions.count == 1)
    }

    @Test func refreshAcrossDeadlinePreservesExistingMatchingRequest() async throws {
        let backend = SuspendedNotificationBackend()
        let service = NotificationService(backend: backend)
        let now = Date()
        let deadline = now.addingTimeInterval(0.15)
        let state = TimerState(phase: .work, status: .running, phaseID: UUID(),
                               deadline: deadline, remainingSeconds: 0.15,
                               durationSeconds: 1500, completedSessions: 0,
                               dayStart: Calendar.current.startOfDay(for: now))
        let engine = TimerEngine(state: state, now: now)
        await service.synchronize(with: engine)
        #expect(backend.pending.count == 1)
        backend.holdAuthorization = true
        let refresh = Task { await service.synchronize(with: engine) }
        while backend.authorizationWaiter == nil { await Task.yield() }
        let remaining = deadline.timeIntervalSinceNow
        if remaining > 0 { try await Task.sleep(for: .seconds(remaining + 0.01)) }
        backend.holdAuthorization = false
        backend.authorizationWaiter?.resume(returning: .authorized)
        await refresh.value
        #expect(backend.pending.count == 1)
        #expect(backend.additions.count == 1)
        #expect(backend.pending.values.first?.phaseID == state.phaseID)
    }

}
