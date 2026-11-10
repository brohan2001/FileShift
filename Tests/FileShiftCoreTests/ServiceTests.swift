import XCTest
@testable import FileShiftCore

/// End-to-end tests of the running service (watcher + stability detection + shifter)
/// against a sandbox directory, with browser download patterns simulated faithfully.
final class ServiceTests: XCTestCase {
    var sb: Sandbox!
    var service: FileShiftService!

    /// Stability window used in tests: 3 samples x 0.1 s.
    let interval = 0.1
    let samples = 3

    override func setUp() {
        sb = Sandbox()
    }

    override func tearDown() {
        service?.stop()
        service = nil
        sb = nil
    }

    func startService() {
        var c = FileShiftService.Configuration(directory: sb.dir, journalDirectory: sb.journalDir, logFile: sb.logFile)
        c.sampleInterval = interval
        c.requiredStableSamples = samples
        c.debounce = 0.05
        service = try! FileShiftService(config: c)
        service.start()
        XCTAssertTrue(waitUntil(5) { self.service.status == .active }, "service did not become active: \(service.status)")
    }

    // MARK: Browser simulations

    /// Firefox: 0-byte placeholder at the final name + `<name>.part`; data written to .part;
    /// on completion .part is renamed over the placeholder.
    @discardableResult
    func firefoxDownload(_ name: String, chunks: Int = 10, chunkDelay: TimeInterval = 0.15) -> String {
        let final = sb.path(name), part = final + ".part"
        FileManager.default.createFile(atPath: final, contents: Data())
        FileManager.default.createFile(atPath: part, contents: Data())
        let fh = FileHandle(forWritingAtPath: part)!
        var all = Data()
        for i in 0..<chunks {
            let chunk = "\(name) chunk \(i) \(UUID().uuidString)\n".data(using: .utf8)!
            fh.write(chunk)
            all.append(chunk)
            Thread.sleep(forTimeInterval: chunkDelay)
        }
        try! fh.close()
        XCTAssertEqual(rename(part, final), 0)
        return Sandbox.sha(all)
    }

    /// Chrome: writes `Unconfirmed NNN.crdownload`, renames to final name when done.
    func chromeDownload(_ name: String, chunks: Int = 10, chunkDelay: TimeInterval = 0.1) -> String {
        let tmp = sb.path("Unconfirmed \(Int.random(in: 1000...9999)).crdownload")
        FileManager.default.createFile(atPath: tmp, contents: Data())
        let fh = FileHandle(forWritingAtPath: tmp)!
        var all = Data()
        for i in 0..<chunks {
            let chunk = "chrome \(name) \(i) \(UUID().uuidString)\n".data(using: .utf8)!
            fh.write(chunk); all.append(chunk)
            Thread.sleep(forTimeInterval: chunkDelay)
        }
        try! fh.close()
        XCTAssertEqual(rename(tmp, sb.path(name)), 0)
        return Sandbox.sha(all)
    }

    // MARK: Tests

    func testPreexistingFilesAreIgnored() {
        let v0 = sb.create("report.pdf"), v1 = sb.create("report(1).pdf"), v2 = sb.create("report(2).pdf")
        startService()
        Thread.sleep(forTimeInterval: 1.0)
        assertState(sb, ["report.pdf": v0, "report(1).pdf": v1, "report(2).pdf": v2])
        // A user rename of an existing file into a duplicate-looking name is also ignored.
        let n = sb.create("notes.txt")
        Thread.sleep(forTimeInterval: 0.5) // let it be classified as known
        XCTAssertEqual(rename(sb.path("notes.txt"), sb.path("report(3).pdf")), 0)
        Thread.sleep(forTimeInterval: 1.0)
        assertState(sb, ["report.pdf": v0, "report(1).pdf": v1, "report(2).pdf": v2, "report(3).pdf": n])
    }

    // 1/2/4 via the live service, Firefox pattern.
    func testFirefoxDownloadIsVersioned() {
        let v0 = sb.create("report.pdf"), v1 = sb.create("report(1).pdf"), v2 = sb.create("report(2).pdf")
        startService()
        let new = firefoxDownload("report(3).pdf")
        XCTAssertTrue(waitUntil { self.sb.snapshot()["report.pdf"] == new })
        Thread.sleep(forTimeInterval: 1.0)  // make sure nothing else happens afterwards (no reprocessing)
        assertState(sb, ["report.pdf": new, "report(1).pdf": v0, "report(2).pdf": v1, "report(3).pdf": v2])
        XCTAssertEqual(service.committedCount, 1, "our own renames must not trigger further processing")
    }

    func testFirstDownloadViaServiceDoesNothing() {
        startService()
        let a = firefoxDownload("report.pdf", chunks: 3)
        Thread.sleep(forTimeInterval: 1.0)
        assertState(sb, ["report.pdf": a])
        XCTAssertEqual(service.committedCount, 0)
    }

    // 10. Incomplete downloads must never be touched.
    func test10_incompleteFirefoxDownloadNotTouched() {
        let v0 = sb.create("report.pdf")
        startService()
        let done = expectation(description: "download finished")
        var newSha = ""
        // Slow download: ~3 s, far longer than the 0.3 s stability window.
        DispatchQueue.global().async {
            newSha = self.firefoxDownload("report(1).pdf", chunks: 20, chunkDelay: 0.15)
            done.fulfill()
        }
        // While it is downloading, the original must stay put and the placeholder untouched.
        for _ in 0..<25 {
            Thread.sleep(forTimeInterval: 0.1)
            if FileManager.default.fileExists(atPath: sb.path("report(1).pdf.part")) {
                XCTAssertEqual(sb.snapshot()["report.pdf"], v0, "renamed while still downloading!")
            }
        }
        wait(for: [done], timeout: 10)
        XCTAssertTrue(waitUntil { self.sb.snapshot()["report.pdf"] == newSha })
        assertState(sb, ["report.pdf": newSha, "report(1).pdf": v0])
    }

    /// Firefox on macOS may write the data to a randomly named temp file (or outside the folder),
    /// so the 0-byte placeholder at the final name has no `<name>.part` companion for a while.
    /// The placeholder must never be versioned (regression: CI E2E left an empty report(1).pdf).
    func test10_placeholderWithoutCompanionNotVersioned() {
        let v0 = sb.create("report.pdf")
        startService()
        let final = sb.path("report(1).pdf"), part = sb.path("Xk3fQ9aZ.pdf.part")
        FileManager.default.createFile(atPath: final, contents: Data())
        FileManager.default.createFile(atPath: part, contents: Data())
        let fh = FileHandle(forWritingAtPath: part)!
        var all = Data()
        // ~1.5 s: five times the 0.3 s stability window.
        for i in 0..<15 {
            let c = "chunk \(i) \(UUID().uuidString)\n".data(using: .utf8)!
            fh.write(c); all.append(c)
            Thread.sleep(forTimeInterval: 0.1)
            XCTAssertEqual(sb.snapshot()["report.pdf"], v0, "empty placeholder was versioned (i=\(i))")
        }
        try! fh.close()
        XCTAssertEqual(rename(part, final), 0)
        XCTAssertTrue(waitUntil { self.sb.snapshot()["report.pdf"] == Sandbox.sha(all) })
        Thread.sleep(forTimeInterval: 0.5)
        assertState(sb, ["report.pdf": Sandbox.sha(all), "report(1).pdf": v0])
        XCTAssertEqual(service.committedCount, 1)
    }

    func test10_slowWriterWithoutTempFileWaitsForStability() {
        let v0 = sb.create("data.bin")
        startService()
        // Writes directly to the final name in small increments (like curl -o), every 50 ms for ~2 s.
        let fh: FileHandle = {
            FileManager.default.createFile(atPath: sb.path("data(1).bin"), contents: Data())
            return FileHandle(forWritingAtPath: sb.path("data(1).bin"))!
        }()
        var all = Data()
        for i in 0..<40 {
            let c = "line \(i) \(UUID().uuidString)\n".data(using: .utf8)!
            fh.write(c); all.append(c)
            Thread.sleep(forTimeInterval: 0.05)
            XCTAssertEqual(sb.snapshot()["data.bin"], v0, "renamed while still being written (i=\(i))")
        }
        try! fh.close()
        XCTAssertTrue(waitUntil { self.sb.snapshot()["data.bin"] == Sandbox.sha(all) })
        assertState(sb, ["data.bin": Sandbox.sha(all), "data(1).bin": v0])
    }

    func test10_chromeAndSafariTempPatterns() {
        let v0 = sb.create("report.pdf")
        startService()
        // Chrome style.
        let c = chromeDownload("report (1).pdf")
        XCTAssertTrue(waitUntil { self.sb.snapshot()["report.pdf"] == c })
        // Safari style: a "<name>.download" bundle folder holding the data, moved out on completion.
        // (Safari picks the next free name, "report (2).pdf".)
        let bundle = sb.path("report (2).pdf.download")
        try! FileManager.default.createDirectory(atPath: bundle, withIntermediateDirectories: false)
        let inner = (bundle as NSString).appendingPathComponent("report (2).pdf")
        let sData = "safari \(UUID())".data(using: .utf8)!
        FileManager.default.createFile(atPath: inner, contents: sData)
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(sb.snapshot()["report.pdf"], c, "nothing may happen while the .download bundle exists")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sb.path("report (2).pdf")))
        XCTAssertEqual(rename(inner, sb.path("report (2).pdf")), 0)
        try! FileManager.default.removeItem(atPath: bundle) // empty test folder we created
        XCTAssertTrue(waitUntil { self.sb.snapshot()["report.pdf"] == Sandbox.sha(sData) })
        assertState(sb, ["report.pdf": Sandbox.sha(sData), "report (1).pdf": c, "report (2).pdf": v0])
    }

    // 9. Simultaneous downloads, finishing in a known order.
    func test09_simultaneousDownloadsStaggered() {
        let v0 = sb.create("report.pdf")
        startService()
        let group = DispatchGroup()
        var shas = [String](repeating: "", count: 3)
        let lock = NSLock()
        // All three start together; they finish ~0.8 s apart (well beyond the stability window).
        for i in 0..<3 {
            let name = "report(\(i + 1)).pdf"
            FileManager.default.createFile(atPath: sb.path(name), contents: Data())       // reserve names first,
            FileManager.default.createFile(atPath: sb.path(name + ".part"), contents: Data()) // as Firefox does
        }
        for i in 0..<3 {
            group.enter()
            DispatchQueue.global().async {
                let name = "report(\(i + 1)).pdf"
                let part = self.sb.path(name + ".part")
                let fh = FileHandle(forWritingAtPath: part)!
                var all = Data()
                for j in 0..<(5 + i * 8) {
                    let c = "\(name) \(j) \(UUID())\n".data(using: .utf8)!
                    fh.write(c); all.append(c)
                    Thread.sleep(forTimeInterval: 0.1)
                }
                try! fh.close()
                rename(part, self.sb.path(name))
                lock.lock(); shas[i] = Sandbox.sha(all); lock.unlock()
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
        // Finish order: (1), (2), (3) => newest is (3).
        let expected = ["report.pdf": shas[2], "report(1).pdf": shas[1], "report(2).pdf": shas[0], "report(3).pdf": v0]
        XCTAssertTrue(waitUntil(10) { self.sb.snapshot() == expected && self.service.pendingCount == 0 })
        Thread.sleep(forTimeInterval: 0.5)
        assertState(sb, expected)
    }

    // 9. Simultaneous downloads finishing at the same instant.
    func test09_simultaneousDownloadsSameInstant() {
        let v0 = sb.create("doc.pdf"), v1 = sb.create("doc(1).pdf")
        startService()
        var shas: [String] = []
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 3) { i in
            let name = "doc(\(i + 2)).pdf"
            let data = "same-instant \(i) \(UUID())".data(using: .utf8)!
            FileManager.default.createFile(atPath: sb.path(name), contents: data)
            lock.lock(); shas.append(Sandbox.sha(data)); lock.unlock()
        }
        XCTAssertTrue(waitUntil(10) {
            self.service.pendingCount == 0 && self.sb.snapshot().count == 5 && self.sb.snapshot()["doc(4).pdf"] == v1
        })
        Thread.sleep(forTimeInterval: 0.5)
        let snap = sb.snapshot()
        XCTAssertEqual(Set(snap.keys), ["doc.pdf", "doc(1).pdf", "doc(2).pdf", "doc(3).pdf", "doc(4).pdf"])
        XCTAssertEqual(Set(snap.values), Set(shas + [v0, v1]), "all content preserved")
        XCTAssertEqual(snap["doc(4).pdf"], v1, "oldest version is furthest back")
        XCTAssertEqual(snap["doc(3).pdf"], v0)
        XCTAssertTrue(shas.contains(snap["doc.pdf"]!), "a new download holds the clean name")
        XCTAssertEqual(sb.pendingJournals(), 0)
    }

    func testSubfolderChangesIgnored() {
        startService()
        let sub = sb.path("sub")
        try! FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: false)
        let a = "a".data(using: .utf8)!, b = "b".data(using: .utf8)!
        FileManager.default.createFile(atPath: (sub as NSString).appendingPathComponent("x.pdf"), contents: a)
        FileManager.default.createFile(atPath: (sub as NSString).appendingPathComponent("x(1).pdf"), contents: b)
        Thread.sleep(forTimeInterval: 1.0)
        let names = try! SafeFS.listDirectory(sub).sorted()
        XCTAssertEqual(names, ["x(1).pdf", "x.pdf"])
        XCTAssertEqual(FileManager.default.contents(atPath: (sub as NSString).appendingPathComponent("x.pdf")), a)
    }

    func testPauseAndResume() {
        let v0 = sb.create("r.txt")
        startService()
        service.pause()
        XCTAssertTrue(waitUntil { self.service.status == .paused })
        let n1 = sb.create("r(1).txt")
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(sb.snapshot(), ["r.txt": v0, "r(1).txt": n1], "no changes while paused")
        service.resume()
        XCTAssertTrue(waitUntil { self.service.status == .active })
        Thread.sleep(forTimeInterval: 0.5)
        // Files that arrived while paused are treated as pre-existing.
        XCTAssertEqual(sb.snapshot(), ["r.txt": v0, "r(1).txt": n1])
        let n2 = sb.create("r(2).txt")
        XCTAssertTrue(waitUntil { self.sb.snapshot()["r.txt"] == n2 })
        assertState(sb, ["r.txt": n2, "r(1).txt": v0, "r(2).txt": n1])
    }

    func testStartupRecoversInterruptedTransaction() throws {
        let v0 = sb.create("report.pdf"), new = sb.create("report(1).pdf")
        let shifter = sb.shifter()
        shifter.afterStep = { i, _ in if i == 0 { throw SimulatedCrash() } }  // incoming now hidden in staging
        XCTAssertThrowsError(try shifter.process(name: "report(1).pdf"))
        XCTAssertEqual(sb.hiddenStagingFiles().count, 1)
        startService()
        assertState(sb, ["report.pdf": new, "report(1).pdf": v0])
    }

    func testLogRecordsOperations() throws {
        sb.create("report.pdf")
        startService()
        sb.create("report(1).pdf")
        XCTAssertTrue(waitUntil { self.service.committedCount == 1 })
        let text = try String(contentsOfFile: sb.logFile, encoding: .utf8)
        XCTAssertTrue(text.contains("begin: report(1).pdf -> report.pdf"))
        XCTAssertTrue(text.contains("step 1: report.pdf -> report(1).pdf"))
        XCTAssertTrue(text.contains("committed"))
        XCTAssertFalse(service.log.recent().isEmpty)
    }
}
