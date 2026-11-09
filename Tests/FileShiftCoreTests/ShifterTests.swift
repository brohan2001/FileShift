import XCTest
@testable import FileShiftCore

/// Engine-level tests: call the shifter directly on a sandbox directory and
/// verify both names and SHA-256 contents after every operation.
final class ShifterTests: XCTestCase {

    // 1. First download, no duplicate exists.
    func test01_firstDownloadNoDuplicate() throws {
        let sb = Sandbox()
        let a = sb.create("report.pdf")
        let out = try sb.shifter().process(name: "report.pdf")
        guard case .notApplicable = out else { return XCTFail("\(out)") }
        assertState(sb, ["report.pdf": a])
    }

    // 2. Second download of the same file.
    func test02_secondDownload() throws {
        let sb = Sandbox()
        let old = sb.create("report.pdf")
        let new = sb.create("report(1).pdf")
        let out = try sb.shifter().process(name: "report(1).pdf")
        guard case .shifted = out else { return XCTFail("\(out)") }
        assertState(sb, ["report.pdf": new, "report(1).pdf": old])
    }

    // 3. Third and subsequent downloads (simulating the browser each time).
    func test03_thirdAndSubsequentDownloads() throws {
        let sb = Sandbox()
        var history: [String] = [sb.create("report.pdf")]   // history[0] = oldest
        for _ in 1...6 {
            // Browser picks the lowest free "(N)".
            var n = 1
            while FileManager.default.fileExists(atPath: sb.path("report(\(n)).pdf")) { n += 1 }
            history.append(sb.create("report(\(n)).pdf"))
            let out = try sb.shifter().process(name: "report(\(n)).pdf")
            guard case .shifted = out else { return XCTFail("\(out)") }
            // Newest at clean name, then descending age.
            var expected: [String: String] = [:]
            for (age, sha) in history.reversed().enumerated() {
                expected[age == 0 ? "report.pdf" : "report(\(age)).pdf"] = sha
            }
            assertState(sb, expected)
        }
    }

    // 4. Multiple existing versions — the exact example from the brief, both spellings.
    func test04_multipleExistingVersions_firefox() throws {
        let sb = Sandbox()
        let v0 = sb.create("report.pdf"), v1 = sb.create("report(1).pdf"), v2 = sb.create("report(2).pdf")
        let new = sb.create("report(3).pdf")
        _ = try sb.shifter().process(name: "report(3).pdf")
        assertState(sb, ["report.pdf": new, "report(1).pdf": v0, "report(2).pdf": v1, "report(3).pdf": v2])
    }

    func test04_multipleExistingVersions_chrome() throws {
        let sb = Sandbox()
        let v0 = sb.create("report.pdf"), v1 = sb.create("report (1).pdf"), v2 = sb.create("report (2).pdf")
        let new = sb.create("report (3).pdf")
        _ = try sb.shifter().process(name: "report (3).pdf")
        assertState(sb, ["report.pdf": new, "report (1).pdf": v0, "report (2).pdf": v1, "report (3).pdf": v2])
    }

    // 5. Gaps in version numbering.
    func test05_gapsInNumbering() throws {
        let sb = Sandbox()
        // Existing: 0, 1, 4. Browser fills the lowest gap: (2).
        let v0 = sb.create("report.pdf"), v1 = sb.create("report(1).pdf"), v4 = sb.create("report(4).pdf")
        let new = sb.create("report(2).pdf")
        _ = try sb.shifter().process(name: "report(2).pdf")
        assertState(sb, ["report.pdf": new, "report(1).pdf": v0, "report(2).pdf": v1, "report(4).pdf": v4])
    }

    func test05_gapAtOriginal() throws {
        let sb = Sandbox()
        // The user deleted report.pdf; a new (2) arrives. Newest still gets the clean name.
        let v1 = sb.create("report(1).pdf")
        let new = sb.create("report(2).pdf")
        _ = try sb.shifter().process(name: "report(2).pdf")
        assertState(sb, ["report.pdf": new, "report(1).pdf": v1])
    }

    func test05_noFamilyIsLeftAlone() throws {
        let sb = Sandbox()
        let a = sb.create("photo(1).jpg")
        let out = try sb.shifter().process(name: "photo(1).jpg")
        guard case .notApplicable = out else { return XCTFail("\(out)") }
        assertState(sb, ["photo(1).jpg": a])
    }

    // 6. Multiple dots.
    func test06_multipleDots() throws {
        let sb = Sandbox()
        let v0 = sb.create("my.project.final.pdf"), v1 = sb.create("my.project.final(1).pdf"), v2 = sb.create("my.project.final(2).pdf")
        let new = sb.create("my.project.final(3).pdf")
        _ = try sb.shifter().process(name: "my.project.final(3).pdf")
        assertState(sb, ["my.project.final.pdf": new, "my.project.final(1).pdf": v0,
                         "my.project.final(2).pdf": v1, "my.project.final(3).pdf": v2])
    }

    // 7. Spaces, parentheses, Unicode (NFC + NFD).
    func test07_spacesAndParentheses() throws {
        let sb = Sandbox()
        let v0 = sb.create("Q3 report (final draft).docx")
        let v1 = sb.create("Q3 report (final draft)(1).docx")
        let new = sb.create("Q3 report (final draft)(2).docx")
        _ = try sb.shifter().process(name: "Q3 report (final draft)(2).docx")
        assertState(sb, ["Q3 report (final draft).docx": new,
                         "Q3 report (final draft)(1).docx": v0,
                         "Q3 report (final draft)(2).docx": v1])
    }

    func test07_unicodeNFCandNFD() throws {
        let sb = Sandbox()
        let nfc = "Résumé – 日本語 😀"
        let nfd = nfc.decomposedStringWithCanonicalMapping
        XCTAssertNotEqual(Array(nfc.utf8), Array(nfd.utf8))
        let old = sb.create(nfc + ".pdf")
        let new = sb.create(nfd + "(1).pdf")   // incoming arrives in NFD
        let out = try sb.shifter().process(name: nfd + "(1).pdf")
        guard case .shifted = out else { return XCTFail("\(out)") }
        assertState(sb, [nfc + ".pdf": new, nfc + "(1).pdf": old])
    }

    // 8. Different extensions.
    func test08_differentExtensions() throws {
        let sb = Sandbox()
        var expected: [String: String] = [:]
        for (clean, dup1) in [("Makefile", "Makefile(1)"), ("backup.tar.gz", "backup(1).tar.gz"),
                              ("IMG_0042.JPG", "IMG_0042(1).JPG"), ("notes.txt", "notes(1).txt"),
                              ("slides.key", "slides(1).key"), ("data.csv", "data(1).csv")] {
            let old = sb.create(clean)
            let new = sb.create(dup1)
            let out = try sb.shifter().process(name: dup1)
            guard case .shifted = out else { return XCTFail("\(dup1): \(out)") }
            expected[clean] = new
            expected[dup1] = old
        }
        assertState(sb, expected)
    }

    func test08_doesNotTouchOtherFamilies() throws {
        let sb = Sandbox()
        let r = sb.create("report.pdf"), rd = sb.create("report.docx"), r1d = sb.create("report(1).docx")
        let other = sb.create("report-2.pdf")
        let new = sb.create("report(1).pdf")
        _ = try sb.shifter().process(name: "report(1).pdf")
        assertState(sb, ["report.pdf": new, "report(1).pdf": r, "report.docx": rd, "report(1).docx": r1d, "report-2.pdf": other])
    }

    // 12. Existing destination collisions.
    func test12_destinationAppearsDuringTransaction() throws {
        let sb = Sandbox()
        let v0 = sb.create("report.pdf"), v1 = sb.create("report(1).pdf")
        let new = sb.create("report(2).pdf")
        let shifter = sb.shifter()
        var intruder = ""
        // Steps: 0: report(2)->staging, 1: report(1)->report(2), 2: report->report(1), 3: staging->report
        shifter.beforeStep = { i, step in
            if i == 1 { intruder = sb.create(step.to) }   // something else grabs report(2).pdf
        }
        let out = try shifter.process(name: "report(2).pdf")
        guard case .failed = out else { return XCTFail("\(out)") }
        // Nothing overwritten, nothing lost: originals back in place, intruder kept,
        // incoming download rescued under a visible "recovered" name.
        let snap = sb.snapshot()
        XCTAssertEqual(snap["report.pdf"], v0)
        XCTAssertEqual(snap["report(1).pdf"], v1)
        XCTAssertEqual(snap["report(2).pdf"], intruder)
        let recovered = snap.filter { $0.key.contains("FileShift recovered") }
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.value, new)
        XCTAssertTrue(recovered.first!.key.hasSuffix(".pdf"))
        XCTAssertEqual(snap.count, 4)
        XCTAssertEqual(sb.pendingJournals(), 0)
        XCTAssertEqual(sb.hiddenStagingFiles(), [])
    }

    func test12_collisionAtFinalStepRollsBackCleanly() throws {
        let sb = Sandbox()
        let v0 = sb.create("report.pdf")
        let new = sb.create("report(1).pdf")
        let shifter = sb.shifter()
        var intruder = ""
        // Steps: 0: report(1)->staging, 1: report->report(1), 2: staging->report
        shifter.beforeStep = { i, _ in if i == 2 { intruder = sb.create("report.pdf") } }
        let out = try shifter.process(name: "report(1).pdf")
        guard case .failed = out else { return XCTFail("\(out)") }
        let snap = sb.snapshot()
        // Every piece of content survives.
        XCTAssertEqual(Set(snap.values), Set([v0, new, intruder]))
        XCTAssertEqual(snap.count, 3)
        XCTAssertEqual(snap["report.pdf"], intruder)
        XCTAssertEqual(sb.hiddenStagingFiles(), [])
    }

    func test12_bothSpellingsInSameSlot() throws {
        let sb = Sandbox()
        let v0 = sb.create("report.pdf")
        let ff1 = sb.create("report(1).pdf")
        let cr1 = sb.create("report (1).pdf")
        let new = sb.create("report(2).pdf")
        _ = try sb.shifter().process(name: "report(2).pdf")
        assertState(sb, ["report.pdf": new, "report(1).pdf": v0, "report(2).pdf": ff1, "report (2).pdf": cr1])
    }

    func test12_preflightRefusesUnexpectedOccupiedTarget() throws {
        let sb = Sandbox()
        // Clean original exists only in Chrome spelling family; target "report (2).pdf" is
        // occupied by something the chain would need — the shifter must refuse or handle without overwrite.
        let v0 = sb.create("report.pdf"), c1 = sb.create("report (1).pdf"), f2 = sb.create("report(2).pdf")
        let new = sb.create("report(1).pdf")
        _ = try sb.shifter().process(name: "report(1).pdf")
        let snap = sb.snapshot()
        XCTAssertEqual(Set(snap.values), Set([v0, c1, f2, new]), "no content lost")
        XCTAssertEqual(snap.count, 4)
        XCTAssertEqual(snap["report.pdf"], new)
        XCTAssertEqual(sb.pendingJournals(), 0)
    }

    func test_refusesToMoveFoldersOrBlockedOccupants() throws {
        let sb = Sandbox()
        try FileManager.default.createDirectory(atPath: sb.path("Photos"), withIntermediateDirectories: false)
        let new = sb.create("Photos(1)")
        let out = try sb.shifter().process(name: "Photos(1)")
        guard case .notApplicable = out else { return XCTFail("\(out)") }
        XCTAssertEqual(sb.snapshot(), ["Photos": "<dir>", "Photos(1)": new])

        let v0 = sb.create("a.pdf")
        sb.create("a.pdf.part")  // a.pdf itself is still downloading
        let n1 = sb.create("a(1).pdf")
        let out2 = try sb.shifter().process(name: "a(1).pdf")
        guard case .deferred = out2 else { return XCTFail("\(out2)") }
        XCTAssertEqual(sb.snapshot()["a.pdf"], v0)
        XCTAssertEqual(sb.snapshot()["a(1).pdf"], n1)
    }
}
