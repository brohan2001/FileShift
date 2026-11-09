import Foundation
import CryptoKit
import XCTest
@testable import FileShiftCore

/// An isolated sandbox under the system temp directory. Never ~/Downloads.
final class Sandbox {
    let root: String
    let dir: String       // plays the role of "Downloads"
    let journalDir: String
    let logFile: String
    let log: ActivityLog

    init(_ label: String = #function) {
        let base = FileManager.default.temporaryDirectory.path
        root = (base as NSString).appendingPathComponent("FileShiftTests-\(UUID().uuidString)")
        dir = (root as NSString).appendingPathComponent("dl")
        journalDir = (root as NSString).appendingPathComponent("journal")
        logFile = (root as NSString).appendingPathComponent("test.log")
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!.path
        precondition(!dir.hasPrefix(downloads), "refusing to run tests inside the real Downloads folder")
        precondition(dir.contains("FileShiftTests-"))
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        log = ActivityLog(filePath: logFile)
    }

    deinit {
        // Only the sandbox we created is removed.
        if root.contains("FileShiftTests-") { try? FileManager.default.removeItem(atPath: root) }
    }

    func path(_ name: String) -> String { (dir as NSString).appendingPathComponent(name) }

    func journal() -> Journal { try! Journal(directory: journalDir) }

    func shifter() -> VersionShifter { VersionShifter(directory: dir, journal: journal(), log: log) }

    /// Creates a file with unique content and returns that content's SHA-256.
    @discardableResult
    func create(_ name: String, content: String? = nil) -> String {
        let data = (content ?? "content of \(name) / \(UUID().uuidString)\n").data(using: .utf8)!
        precondition(FileManager.default.createFile(atPath: path(name), contents: data))
        return Self.sha(data)
    }

    static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// name (NFC) -> sha256 for every entry (including hidden ones) in the sandbox dir.
    func snapshot() -> [String: String] {
        var out: [String: String] = [:]
        for name in (try? SafeFS.listDirectory(dir)) ?? [] {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: path(name), isDirectory: &isDir)
            if isDir.boolValue { out[name.precomposedStringWithCanonicalMapping] = "<dir>"; continue }
            let data = FileManager.default.contents(atPath: path(name)) ?? Data()
            out[name.precomposedStringWithCanonicalMapping] = Self.sha(data)
        }
        return out
    }

    func pendingJournals() -> Int { journal().pending().count }

    func hiddenStagingFiles() -> [String] {
        ((try? SafeFS.listDirectory(dir)) ?? []).filter { $0.hasPrefix(Recovery.stagingPrefix) }
    }
}

/// Asserts the directory contains exactly `expected` (name -> sha).
func assertState(_ sb: Sandbox, _ expected: [String: String], file: StaticString = #filePath, line: UInt = #line) {
    let actual = sb.snapshot()
    let exp = Dictionary(uniqueKeysWithValues: expected.map { ($0.key.precomposedStringWithCanonicalMapping, $0.value) })
    if actual != exp {
        let names = { (d: [String: String]) in d.keys.sorted().joined(separator: ", ") }
        XCTFail("directory mismatch\n expected: \(names(exp))\n actual:   \(names(actual))\n(or contents differ)", file: file, line: line)
        for (k, v) in exp where actual[k] != v {
            XCTFail("  \(k): expected content \(v.prefix(8)), got \(actual[k].map { String($0.prefix(8)) } ?? "missing")", file: file, line: line)
        }
    }
    XCTAssertEqual(sb.pendingJournals(), 0, "journal not cleared", file: file, line: line)
    XCTAssertEqual(sb.hiddenStagingFiles(), [], "staging file left behind", file: file, line: line)
}

/// Polls `cond` until true or timeout.
func waitUntil(_ timeout: TimeInterval = 10, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if cond() { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return cond()
}

