import AppKit
import Observation
import PomodoroCore

@MainActor
@Observable
final class AppModel {
    static let persistenceKey = "Pomodoro.session.v1"

    private(set) var engine: TimerEngine
    private(set) var now: Date
    private(set) var notificationStatus: NotificationAuthorization
    private(set) var loginItemEnabled: Bool
    private(set) var cachedIntegrationError: IntegrationError?
    var integrationError: String? { cachedIntegrationError?.message(language: engine.settings.language) }
    var onNotificationOpened: (() -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let notifications: NotificationService
    @ObservationIgnored private let loginItems: LoginItemService
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var synchronizationTask: Task<Void, Never>?
    @ObservationIgnored private var authorizationTask: Task<Void, Never>?
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored private var lifecycleEnabled = false

    init(defaults: UserDefaults = .standard,
         notifications: NotificationService? = nil,
         loginItems: LoginItemService? = nil,
         clock: @escaping () -> Date = Date.init,
         startLifecycle: Bool = true) {
        let now = clock()
        let notifications = notifications ?? NotificationService()
        let loginItems = loginItems ?? LoginItemService()
        self.defaults = defaults
        self.notifications = notifications
        self.loginItems = loginItems
        self.clock = clock
        self.now = now
        self.engine = SessionPersistence.restoreForLaunch(defaults.data(forKey: Self.persistenceKey), now: now)
        self.notificationStatus = notifications.authorization
        self.loginItemEnabled = loginItems.isEnabled
        notifications.onAuthorizationChanged = { [weak self] in self?.notificationStatus = $0 }
        notifications.onError = { [weak self] in self?.cachedIntegrationError = $0 }
        notifications.onNotificationOpened = { [weak self] in self?.onNotificationOpened?() }
        persist()
        synchronizeNotifications()
        if startLifecycle { installLifecycle() }
    }

    isolated deinit {
        timer?.invalidate()
        synchronizationTask?.cancel()
        authorizationTask?.cancel()
        for (center, token) in observers { center.removeObserver(token) }
    }

    func send(_ action: TimerAction) {
        guard !sleeping else { return }
        let instant = clock()
        let previousState = engine.state
        let previousSettings = engine.settings
        var updatedEngine = engine
        let events = updatedEngine.handle(action, at: instant)
        let changed = previousState != updatedEngine.state || previousSettings != updatedEngine.settings
        if changed || previousState.status == .running || updatedEngine.state.status == .running {
            now = instant
        }
        if changed { engine = updatedEngine }
        for event in events {
            if case let .phaseCompleted(id, _, _, recovering) = event {
                notifications.phaseCompleted(id, recovering: recovering)
                if CompletionDeliveryPolicy.shouldPlayFallbackSound(
                    settings: previousSettings, authorization: notificationStatus, recovering: recovering) {
                    notifications.playSound()
                }
            }
        }
        if changed {
            persist()
            synchronizeNotifications()
        }
        if case .start = action, engine.state.status == .running {
            requestNotificationPermissionIfNeeded()
        } else if !previousSettings.notificationsEnabled && engine.settings.notificationsEnabled {
            requestNotificationPermissionIfNeeded()
        }
        scheduleNextTick(at: instant)
    }

    func updateSettings(_ transform: (inout PomodoroSettings) -> Void) {
        var settings = engine.settings
        transform(&settings)
        send(.updateSettings(settings))
    }

    func testNotification() {
        Task { [weak self] in
            guard let self else { return }
            await notifications.testNotification(soundEnabled: engine.settings.soundEnabled, language: engine.settings.language)
        }
    }

    func testSound() { notifications.playSound() }

    func setLaunchAtLogin(_ enabled: Bool) {
        cachedIntegrationError = nil
        do { try loginItems.setEnabled(enabled) }
        catch { cachedIntegrationError = IntegrationError(kind: .login, detail: error.localizedDescription) }
        loginItemEnabled = loginItems.isEnabled
    }

    func handleSleep() {
        sleeping = true
        timer?.invalidate()
        timer = nil
    }

    func handleWake() {
        sleeping = false
        send(.tick(recovering: true))
        // Refresh system permission and pending requests even without a transition.
        synchronizeNotifications()
        loginItemEnabled = loginItems.isEnabled
    }

    func handleTimeZoneChange() {
        send(.tick(recovering: false))
        // Calendar-dependent notification predictions can change even when the
        // reducer leaves the current phase and day state unchanged.
        synchronizeNotifications()
    }

    private func persist() {
        do {
            let session = PersistedSession(settings: engine.settings, state: engine.state)
            defaults.set(try SessionPersistence.encode(session), forKey: Self.persistenceKey)
        } catch { cachedIntegrationError = IntegrationError(kind: .persistence, detail: error.localizedDescription) }
    }

    private func synchronizeNotifications() {
        notifications.updateDesiredState(with: engine)
        synchronizationTask?.cancel()
        synchronizationTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await notifications.synchronizePending()
        }
    }

    private func requestNotificationPermissionIfNeeded() {
        guard engine.settings.notificationsEnabled, notificationStatus == .notDetermined,
              authorizationTask == nil else { return }
        authorizationTask = Task { [weak self] in
            guard let self else { return }
            await notifications.requestAuthorization()
            authorizationTask = nil
            // Read the live engine after the permission prompt, never its old snapshot.
            synchronizeNotifications()
        }
    }

    private func installLifecycle() {
        lifecycleEnabled = true
        scheduleNextTick(at: now)
        observe(NSWorkspace.willSleepNotification, center: NSWorkspace.shared.notificationCenter) { $0.handleSleep() }
        observe(NSWorkspace.didWakeNotification, center: NSWorkspace.shared.notificationCenter) { $0.handleWake() }
        observe(.NSCalendarDayChanged, center: .default) { $0.send(.tick(recovering: false)) }
        observe(.NSSystemClockDidChange, center: .default) { $0.send(.tick(recovering: false)) }
        observe(.NSSystemTimeZoneDidChange, center: .default) { $0.handleTimeZoneChange() }
        observe(NSApplication.didBecomeActiveNotification, center: .default) { model in
            model.loginItemEnabled = model.loginItems.isEnabled
            model.synchronizeNotifications()
        }
    }

    private func scheduleNextTick(at instant: Date) {
        guard lifecycleEnabled, !sleeping else { return }
        timer?.invalidate()
        let fireDate = TimerRefreshSchedule.nextFireDate(for: engine, at: instant)
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.send(.tick(recovering: false)) }
        }
        timer.tolerance = engine.state.status == .running ? 0.01 : 1
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func observe(_ name: Notification.Name, center: NotificationCenter,
                         action: @escaping @MainActor (AppModel) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { action(self) }
            }
        }
        observers.append((center, token))
    }
}
