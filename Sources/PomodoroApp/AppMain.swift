import AppKit

@main
@MainActor
struct PomodoroApp {
    static let reopenNotification = Notification.Name("local.pomodoro.menubar.showTimer")
    static func main() {
        let application = NSApplication.shared
        let instance = AppInstanceLock()
        do {
            guard try instance.acquire() else {
                let identifier = Bundle.main.bundleIdentifier ?? "local.pomodoro.menubar"
                NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                    .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }?
                    .activate(options: [.activateAllWindows])
                DistributedNotificationCenter.default().postNotificationName(
                    reopenNotification, object: identifier, userInfo: nil, deliverImmediately: true)
                return
            }
        } catch {
            NSLog("Sessions could not acquire its instance lock: %@", error.localizedDescription)
            return
        }
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
        withExtendedLifetime(instance) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var model: AppModel?
    private var statusBarController: StatusBarController?
    private var reopenObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        self.model = model
        statusBarController = StatusBarController(model: model)
        reopenObserver = DistributedNotificationCenter.default().addObserver(
            forName: PomodoroApp.reopenNotification, object: Bundle.main.bundleIdentifier, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.statusBarController?.showPopover() }
        }
        if CommandLine.arguments.contains("--show-timer") {
            // Present only on an explicit launch, after AppKit finishes launch setup.
            DispatchQueue.main.async { [weak self] in
                self?.statusBarController?.showPopover()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusBarController?.showPopover()
        return false
    }
}
