import Darwin
import Foundation

/// A process-lifetime lock, including launches which bypass Launch Services.
final class AppInstanceLock {
    private let url: URL
    private var descriptor: Int32 = -1

    init(url: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("local.pomodoro.menubar.instance.lock")) {
        self.url = url
    }

    func acquire() throws -> Bool {
        if descriptor >= 0 { return true }
        let candidate = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard candidate >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(candidate, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(candidate)
            if code == EWOULDBLOCK || code == EAGAIN { return false }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        descriptor = candidate
        return true
    }

    deinit { if descriptor >= 0 { close(descriptor) } }
}
