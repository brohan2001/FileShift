import Foundation
import Darwin

/// Ensures only one FileShift instance manages a folder at a time (e.g. if it was
/// installed both via Homebrew and via install.sh). Uses an advisory `flock`, which
/// the kernel releases automatically if the process exits or crashes.
public final class InstanceLock {
    private let fd: Int32

    /// Returns nil if another live process already holds the lock.
    public init?(path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = open(path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return nil
        }
        ftruncate(fd, 0)
        let pid = "\(getpid())\n"
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        self.fd = fd
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
