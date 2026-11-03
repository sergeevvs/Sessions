import AppKit
import UserNotifications

@MainActor
enum CompletionSound {
    private static let resourceName = "SessionsCompletion"
    private static let resourceExtension = "wav"

    static var fileURL: URL? {
        Bundle.main.url(forResource: resourceName, withExtension: resourceExtension)
            ?? Bundle.module.url(forResource: resourceName, withExtension: resourceExtension)
    }

    static let notification = UNNotificationSound(
        named: UNNotificationSoundName("\(resourceName).\(resourceExtension)"))

    private static let player: NSSound? = {
        guard let url = fileURL else { return nil }
        return NSSound(contentsOf: url, byReference: false)
    }()

    static func play() {
        player?.stop()
        player?.play()
    }
}
