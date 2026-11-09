import Foundation
import os

/// Append-only log of every operation, plus an in-memory list of recent
/// user-facing activity for the menu.
public final class ActivityLog {
    public enum Level: String { case debug = "DEBUG", info = "INFO", warn = "WARN", error = "ERROR" }

    public struct Entry {
        public let date: Date
        public let level: Level
        public let message: String
    }

    public let filePath: String?
    /// Also print log lines to stderr (CLI use).
    public var echo = false
    public var maxBytes: Int = 1_000_000

    private let lock = NSLock()
    private var recentActivity: [Entry] = []
    private let recentLimit = 50
    private let logger = Logger(subsystem: "io.github.brohan2001.fileshift", category: "engine")
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    public init(filePath: String?) {
        self.filePath = filePath
        if let filePath {
            let dir = (filePath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }

    public func debug(_ msg: String) { write(.debug, msg) }
    public func info(_ msg: String) { write(.info, msg) }
    public func warn(_ msg: String) { write(.warn, msg) }
    public func error(_ msg: String) { write(.error, msg) }

    /// A user-facing event: logged and shown under "Recent Activity".
    public func activity(_ msg: String, level: Level = .info) {
        write(level, msg)
        lock.lock()
        recentActivity.append(Entry(date: Date(), level: level, message: msg))
        if recentActivity.count > recentLimit { recentActivity.removeFirst(recentActivity.count - recentLimit) }
        lock.unlock()
    }

    public func recent(_ n: Int = 15) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return Array(recentActivity.suffix(n))
    }

    private func write(_ level: Level, _ msg: String) {
        switch level {
        case .debug: logger.debug("\(msg, privacy: .public)")
        case .info: logger.info("\(msg, privacy: .public)")
        case .warn: logger.warning("\(msg, privacy: .public)")
        case .error: logger.error("\(msg, privacy: .public)")
        }
        lock.lock(); defer { lock.unlock() }
        let line = "\(formatter.string(from: Date())) [\(level.rawValue)] \(msg)\n"
        if echo { FileHandle.standardError.write(line.data(using: .utf8)!) }
        guard let filePath else { return }
        rotateIfNeeded(filePath)
        if let fh = FileHandle(forWritingAtPath: filePath) ?? createFile(filePath) {
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8)!)
            try? fh.close()
        }
    }

    private func createFile(_ path: String) -> FileHandle? {
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }

    private func rotateIfNeeded(_ path: String) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int, size > maxBytes else { return }
        let old = path + ".1"
        try? FileManager.default.removeItem(atPath: old) // old log generation only
        try? FileManager.default.moveItem(atPath: path, toPath: old)
    }
}
