import XCTest
@testable import FileShiftCore

/// 11. Application interruption during version shifting.
final class RecoveryTests: XCTestCase {

    private func setupFamily(_ sb: Sandbox) -> (v0: String, v1: String, v2: String, new: String) {
        (sb.create("report.pdf"), sb.create("report(1).pdf"), sb.create("report(2).pdf"), sb.create("report(3).pdf"))
    }

    /// Simulated crash after every possible step, then recovery in a fresh "process".
    func test11_crashAfterEachStepThenRecover() throws {
        // Transaction has 5 steps: stage, (2)->(3), (1)->(2), 0->(1), staging->0.
        for k in 0..<5 {
            let sb = Sandbox()
            let f = setupFamily(sb)
            let shifter = sb.shifter()
            shifter.afterStep = { i, _ in if i == k { throw SimulatedCrash() } }
            XCTAssertThrowsError(try shifter.process(name: "report(3).pdf")) { XCTAssertTrue($0 is SimulatedCrash) }
            if k < 4 { XCTAssertEqual(sb.pendingJournals(), 1, "journal must survive the crash (k=\(k))") }

            let report = Recovery(journal: sb.journal(), log: sb.log).recoverAll(orphanScanDirectory: sb.dir)
            XCTAssertTrue(report.problems.isEmpty, "k=\(k): \(report)")
            assertState(sb, ["report.pdf": f.new, "report(1).pdf": f.v0, "report(2).pdf": f.v1, "report(3).pdf": f.v2])
        }
    }

    func test11_crashBeforeFirstRename() throws {
        let sb = Sandbox()
        let f = setupFamily(sb)
        let shifter = sb.shifter()
        shifter.beforeStep = { i, _ in if i == 0 { throw SimulatedCrash() } }
        XCTAssertThrowsError(try shifter.process(name: "report(3).pdf"))
        XCTAssertEqual(sb.pendingJournals(), 1)
        Recovery(journal: sb.journal(), log: sb.log).recoverAll(orphanScanDirectory: sb.dir)
        assertState(sb, ["report.pdf": f.new, "report(1).pdf": f.v0, "report(2).pdf": f.v1, "report(3).pdf": f.v2])
    }

    /// If the world changed while we were down, recovery undoes instead and still loses nothing.
    func test11_crashThenTargetOccupiedFallsBackToUndo() throws {
        let sb = Sandbox()
        let f = setupFamily(sb)
        let shifter = sb.shifter()
        // Crash after step 1 ((2)->(3)): now report(2).pdf is free; something else takes it.
        shifter.afterStep = { i, _ in if i == 1 { throw SimulatedCrash() } }
        XCTAssertThrowsError(try shifter.process(name: "report(3).pdf"))
        let intruder = sb.create("report(2).pdf")
        let report = Recovery(journal: sb.journal(), log: sb.log).recoverAll(orphanScanDirectory: sb.dir)
        XCTAssertEqual(report.rolledBack.count, 1)
        let snap = sb.snapshot()
        XCTAssertEqual(Set(snap.values), Set([f.v0, f.v1, f.v2, f.new, intruder]), "every file's content survives")
        XCTAssertEqual(snap.count, 5)
        XCTAssertEqual(snap["report.pdf"], f.v0)
        XCTAssertEqual(snap["report(1).pdf"], f.v1)
        XCTAssertEqual(snap["report(2).pdf"], intruder)
        XCTAssertEqual(sb.pendingJournals(), 0)
        XCTAssertEqual(sb.hiddenStagingFiles(), [])
    }

    func test11_inProcessErrorRollsBack() throws {
        struct Boom: Error {}
        for k in 0..<4 {
            let sb = Sandbox()
            let f = setupFamily(sb)
            let shifter = sb.shifter()
            shifter.afterStep = { i, _ in if i == k { throw Boom() } }
            let out = try shifter.process(name: "report(3).pdf")
            guard case .failed = out else { return XCTFail("\(out)") }
            assertState(sb, ["report.pdf": f.v0, "report(1).pdf": f.v1, "report(2).pdf": f.v2, "report(3).pdf": f.new])
        }
    }

    func test11_orphanedStagingFileIsMadeVisible() throws {
        let sb = Sandbox()
        let sha = sb.create(".fileshift-20260101-000000-deadbeef.pdf")
        let report = Recovery(journal: sb.journal(), log: sb.log).recoverAll(orphanScanDirectory: sb.dir)
        XCTAssertEqual(report.recoveredFiles.count, 1)
        let snap = sb.snapshot()
        XCTAssertEqual(snap.count, 1)
        XCTAssertEqual(snap.first?.value, sha)
        XCTAssertTrue(snap.first!.key.hasPrefix("FileShift recovered file (FileShift recovered "))
        XCTAssertTrue(snap.first!.key.hasSuffix(".pdf"))
    }

    func test11_corruptJournalIsSetAside() throws {
        let sb = Sandbox()
        let a = sb.create("report.pdf")
        _ = sb.journal() // creates the journal directory
        try "{not json".write(toFile: (sb.journalDir as NSString).appendingPathComponent("x.json"), atomically: true, encoding: .utf8)
        let report = Recovery(journal: sb.journal(), log: sb.log).recoverAll(orphanScanDirectory: sb.dir)
        XCTAssertEqual(report.problems.count, 1)
        XCTAssertEqual(sb.pendingJournals(), 0)
        XCTAssertEqual(sb.snapshot(), ["report.pdf": a])
    }

    /// Real process death: run fileshift-cli, which calls exit(3) right after step k.
    func test11_realProcessKilledMidShift() throws {
        let cli = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("fileshift-cli")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cli.path), "fileshift-cli not built at \(cli.path)")
        for k in 0..<5 {
            let sb = Sandbox()
            let f = setupFamily(sb)
            let status = try run(cli, ["shift", sb.dir, "report(3).pdf", "--journal", sb.journalDir, "--crash-after-step", "\(k)"])
            XCTAssertEqual(status, 3, "process should have died mid-transaction (k=\(k))")
            if k < 4 { XCTAssertGreaterThanOrEqual(sb.pendingJournals(), 1) }
            let rstatus = try run(cli, ["recover", sb.dir, "--journal", sb.journalDir])
            XCTAssertEqual(rstatus, 0)
            assertState(sb, ["report.pdf": f.new, "report(1).pdf": f.v0, "report(2).pdf": f.v1, "report(3).pdf": f.v2])
        }
    }

    private func run(_ exe: URL, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.standardError = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
}
