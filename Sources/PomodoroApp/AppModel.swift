import AppKit
import Observation
import PomodoroCore

@MainActor
@Observable
final class AppModel {
    static let persistenceKey = "Pomodoro.session.v1"

    private(set) var engine: TimerEngine
    /// The retained popover must not observe the menu bar's live clock while hidden.
    private(set) var now: Date
    private(set) var statusNow: Date
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
    @ObservationIgnored private var popoverVisible = false
    @ObservationIgnored private var statusItemHovered = false
    @ObservationIgnored private var voiceOverEnabled = false
    @ObservationIgnored private var voiceOverObservation: NSKeyValueObservation?

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
        self.statusNow = now
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
            statusNow = instant
            if changed || popoverVisible { now = instant }
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

    func setPopoverVisible(_ visible: Bool) {
        guard popoverVisible != visible else { return }
        popoverVisible = visible
        if visible {
            send(.tick(recovering: false))
        } else {
            scheduleNextTick(at: clock())
        }
    }

    func setStatusItemHovered(_ hovered: Bool) {
        guard statusItemHovered != hovered else { return }
        statusItemHovered = hovered
        send(.tick(recovering: false))
    }

    func setVoiceOverEnabled(_ enabled: Bool) {
        guard voiceOverEnabled != enabled else { return }
        voiceOverEnabled = enabled
        send(.tick(recovering: false))
    }

    func updateSettings(_ transform: (inout PomodoroSettings) -> Void) {
        var settings = engine.settings
        transform(&settings)
        send(.updateSettings(settings))
    }

    func testNotifications() async {
        let settings = engine.settings
        if settings.notificationsEnabled {
            // Retrying owns permission/preview errors. A new failure reports
            // itself through onError; a successful retry leaves no stale alert.
            switch cachedIntegrationError?.kind {
            case .authorization, .show: cachedIntegrationError = nil
            default: break
            }
            await notifications.testNotification(soundEnabled: settings.soundEnabled, language: settings.language)
        }
        if CompletionDeliveryPolicy.shouldPlayFallbackSound(
            settings: settings, authorization: notifications.authorization, recovering: false) {
            notifications.playSound()
        }
    }

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
        voiceOverEnabled = NSWorkspace.shared.isVoiceOverEnabled
        voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled, options: [.new]) { [weak self] workspace, _ in
            let enabled = workspace.isVoiceOverEnabled
            Task { @MainActor [weak self] in self?.setVoiceOverEnabled(enabled) }
        }
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
        let fireDate = TimerRefreshSchedule.nextFireDate(
            for: engine, at: instant, needsSeconds: popoverVisible || statusItemHovered || voiceOverEnabled)
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
