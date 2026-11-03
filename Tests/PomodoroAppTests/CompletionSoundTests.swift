import Foundation
import AudioToolbox
import Testing
import UserNotifications
import PomodoroCore
@testable import PomodoroApp

@MainActor
struct CompletionSoundTests {
    @Test func phaseAndTestNotificationsUseTheSystemDefaultSound() async throws {
        let expectedSound = UNNotificationSound.default
        let backend = SuspendedNotificationBackend()
        let service = NotificationService(backend: backend, soundPlayer: {})
        let now = Date()
        var engine = TimerEngine(now: now)
        _ = engine.handle(.start, at: now)
        await service.synchronize(with: engine)
        let phase = try #require(backend.additions.last)
        await service.testNotification(soundEnabled: true)
        let test = try #require(backend.pending["pomodoro.test"])
        #expect(phase.nativeContent.sound == expectedSound)
        #expect(test.nativeContent.sound == expectedSound)
    }

    @Test func disabledSoundLeavesNotificationSilent() {
        let notification = ScheduledNotification(phaseID: UUID(), deadline: Date().addingTimeInterval(60),
                                               title: "Sessions", body: "Complete", soundEnabled: false)
        #expect(notification.nativeContent.sound == nil)
    }

    @Test func standaloneNotificationToneIsAnInstalledSystemSound() throws {
        let url = try #require(CompletionSound.fileURL)
        #expect(url.path.hasPrefix("/System/Library/"))
        var soundID: SystemSoundID = 0
        #expect(AudioServicesCreateSystemSoundID(url as CFURL, &soundID) == noErr)
        defer { AudioServicesDisposeSystemSoundID(soundID) }
        #expect(soundID != 0)
    }
}
