import Foundation
import Testing
@testable import PomodoroApp

struct AppInstanceLockTests {
    @Test func onlyOneOwnerAndExitReleasesOwnership() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var first: AppInstanceLock? = AppInstanceLock(url: url)
        let second = AppInstanceLock(url: url)
        #expect(try first!.acquire())
        #expect(try !second.acquire())
        first = nil
        #expect(try second.acquire())
    }
}
