import AppKit
import UserNotifications
import PomodoroCore

@MainActor
protocol NotificationBackend: AnyObject {
    func notificationAuthorization() async -> NotificationAuthorization
    func requestAuthorization() async throws
    func pendingIdentifiers() async -> [String]
    func removePending(identifiers: [String])
    func add(_ notification: ScheduledNotification, identifier: String) async throws
}

@MainActor
private final class SystemNotificationBackend: NotificationBackend {
    let center = UNUserNotificationCenter.current()

    func notificationAuthorization() async -> NotificationAuthorization {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        @unknown default: return .denied
        }
    }

    func requestAuthorization() async throws {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
    }

    func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }

    func removePending(identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func add(_ notification: ScheduledNotification, identifier: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = notification.soundEnabled ? .default : nil
        let interval = notification.deadline.timeIntervalSinceNow
        guard interval > 0 else { return }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(interval, 0.1), repeats: false)
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }
}

enum IntegrationErrorKind {
    case schedule, authorization, show, login, persistence

    func prefix(language: AppLanguage) -> String {
        switch self {
        case .schedule: language.text("Не удалось запланировать уведомление", "Could not schedule notification")
        case .authorization: language.text("Не удалось запросить уведомления", "Could not request notification permission")
        case .show: language.text("Не удалось показать уведомление", "Could not show notification")
        case .login: language.text("Не удалось изменить автозапуск", "Could not change launch at login")
        case .persistence: language.text("Не удалось сохранить таймер", "Could not save timer")
        }
    }
}

struct IntegrationError {
    let kind: IntegrationErrorKind
    let detail: String
    func message(language: AppLanguage) -> String { "\(kind.prefix(language: language)): \(detail)" }
}

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private static let phasePrefix = "pomodoro.phase."
    private let backend: any NotificationBackend
    private let soundPlayer: () -> Void
    private var desired: ScheduledNotification?
    private var revision = 0
    private var synchronizing = false
    private var scheduledRequests: [String: ScheduledNotification] = [:]
    private var completingRequests: [String: ScheduledNotification] = [:]
    private(set) var authorization: NotificationAuthorization = .notDetermined
    var onAuthorizationChanged: ((NotificationAuthorization) -> Void)?
    var onError: ((IntegrationError) -> Void)?
    var onNotificationOpened: (() -> Void)?

    init(backend: (any NotificationBackend)? = nil,
         soundPlayer: @escaping () -> Void = { NSSound(named: "Glass")?.play() }) {
        let backend = backend ?? SystemNotificationBackend()
        self.backend = backend
        self.soundPlayer = soundPlayer
        super.init()
        (backend as? SystemNotificationBackend)?.center.delegate = self
    }

    // A single worker owns all add/remove operations. New calls update its desired
    // state synchronously, even while an older OS operation is suspended.
    func synchronize(with engine: TimerEngine) async {
        guard !Task.isCancelled else { return }
        updateDesiredState(with: engine)
        await synchronizePending()
    }

    // The model calls this before creating a Task, so a paused/reset phase is
    // invalidated immediately, before a suspended OS operation can resume.
    func updateDesiredState(with engine: TimerEngine) {
        desired = CompletionDeliveryPolicy.notification(for: engine)
        revision += 1
    }

    func phaseCompleted(_ phaseID: UUID, recovering: Bool) {
        let identifier = Self.phasePrefix + phaseID.uuidString
        // Freeze the eligible configuration, not just its phase ID: a suspended
        // add may still carry sound/alert settings invalidated before completion.
        if !recovering, let desired, desired.phaseID == phaseID {
            completingRequests[identifier] = desired
        } else {
            completingRequests[identifier] = nil
        }
    }

    func synchronizePending() async {
        guard !synchronizing else { return }
        synchronizing = true
        defer { synchronizing = false }

        while true {
            let currentRevision = revision
            let candidate = desired
            let identifiers = await backend.pendingIdentifiers()
            guard revision == currentRevision else { continue }
            let status = await backend.notificationAuthorization()
            updateAuthorization(status)
            guard revision == currentRevision else { continue }
            scheduledRequests = scheduledRequests.filter { identifiers.contains($0.key) }
            let matchingIdentifier: String?
            if let candidate, status == .authorized {
                let identifier = Self.phasePrefix + candidate.phaseID.uuidString
                matchingIdentifier = scheduledRequests[identifier] == candidate ? identifier : nil
            } else {
                matchingIdentifier = nil
            }
            // A refresh may resume after the deadline but before the model tick.
            // Keep a matching scheduled request; completion/recovery decides its fate.
            // Never touch requests belonging to another feature or application.
            backend.removePending(identifiers: identifiers.filter {
                guard $0.hasPrefix(Self.phasePrefix) else { return false }
                if $0 == matchingIdentifier { return false }
                if let completion = completingRequests[$0], scheduledRequests[$0] == completion {
                    return false
                }
                scheduledRequests[$0] = nil
                return true
            })
            if let candidate, matchingIdentifier == nil,
               candidate.deadline > Date(), status == .authorized {
                let identifier = Self.phasePrefix + candidate.phaseID.uuidString
                do {
                    try await backend.add(candidate, identifier: identifier)
                    scheduledRequests[identifier] = candidate
                } catch {
                    if revision == currentRevision { onError?(IntegrationError(kind: .schedule, detail: error.localizedDescription)) }
                }
                if revision != currentRevision {
                    // No replacement can be added until this worker removes the
                    // obsolete in-flight request, including one with the same ID.
                    if completingRequests[identifier] != candidate {
                        backend.removePending(identifiers: [identifier])
                        scheduledRequests[identifier] = nil
                    }
                    continue
                }
            }
            if revision == currentRevision {
                // Retain only completions still pending in the OS; delivered ones
                // require no cleanup and are never removed from Notification Center.
                completingRequests = completingRequests.filter { identifiers.contains($0.key) }
                return
            }
        }
    }

    func requestAuthorization() async {
        if await backend.notificationAuthorization() == .notDetermined {
            do { try await backend.requestAuthorization() }
            catch { onError?(IntegrationError(kind: .authorization, detail: error.localizedDescription)) }
        }
        updateAuthorization(await backend.notificationAuthorization())
    }

    func testNotification(soundEnabled: Bool, language: AppLanguage = .english) async {
        await requestAuthorization()
        guard authorization == .authorized else { return }
        let notification = ScheduledNotification(
            phaseID: UUID(), deadline: Date().addingTimeInterval(1),
            title: "Sessions", body: language.text("Проверка уведомлений. Всё готово к работе.", "Notification test. Everything is ready."),
            soundEnabled: soundEnabled)
        do { try await backend.add(notification, identifier: "pomodoro.test") }
        catch { onError?(IntegrationError(kind: .show, detail: error.localizedDescription)) }
    }

    func playSound() {
        soundPlayer()
    }

    private func updateAuthorization(_ status: NotificationAuthorization) {
        authorization = status
        onAuthorizationChanged?(status)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        await MainActor.run { self.onNotificationOpened?() }
    }
}
