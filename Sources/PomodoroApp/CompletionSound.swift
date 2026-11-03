import AppKit
import AudioToolbox
import UserNotifications

@MainActor
enum CompletionSound {
    static let notification = UNNotificationSound.default

    // macOS 26 uses Rebound for the default notification tone. Read the system
    // resource in place; do not redistribute it or load private framework code.
    static let fileURL = Bundle(path: "/System/Library/PrivateFrameworks/ToneLibrary.framework")?
        .url(forResource: "Rebound-EncoreInfinitum", withExtension: "caf",
             subdirectory: "AlertTones/EncoreInfinitum")

    private static let soundID: SystemSoundID? = {
        guard let url = fileURL else { return nil }
        var identifier: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &identifier) == noErr else { return nil }
        return identifier
    }()

    static func play() {
        if let soundID {
            AudioServicesPlayAlertSound(soundID)
        } else {
            // Keep a system alert if a future macOS version moves the resource.
            NSSound.beep()
        }
    }
}
