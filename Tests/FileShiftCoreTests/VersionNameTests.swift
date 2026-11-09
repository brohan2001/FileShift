import XCTest
@testable import FileShiftCore

final class VersionNameTests: XCTestCase {
    func p(_ s: String) -> VersionName? { VersionName.parse(s) }

    func testFirefoxAndChromeStyles() {
        XCTAssertEqual(p("report(3).pdf"), VersionName(base: "report", ext: ".pdf", number: 3, spaced: false))
        XCTAssertEqual(p("report (3).pdf"), VersionName(base: "report", ext: ".pdf", number: 3, spaced: true))
    }

    func testMultipleDots() {
        XCTAssertEqual(p("my.project.final(2).pdf")?.cleanName, "my.project.final.pdf")
        XCTAssertEqual(p("my.project.final (2).pdf")?.base, "my.project.final")
        XCTAssertEqual(p("archive(1).tar.gz")?.ext, ".tar.gz")
        XCTAssertEqual(p("archive.tar(1).gz")?.cleanName, "archive.tar.gz")
    }

    func testNoExtensionSpacesParensUnicode() {
        XCTAssertEqual(p("Makefile(1)")?.cleanName, "Makefile")
        XCTAssertEqual(p("Q3 report (final) (2).docx")?.cleanName, "Q3 report (final).docx")
        XCTAssertEqual(p("Song (2)(1).mp3")?.cleanName, "Song (2).mp3")
        XCTAssertEqual(p("Résumé – 日本語 😀(4).pdf")?.cleanName, "Résumé – 日本語 😀.pdf")
        XCTAssertEqual(p("IMG_0001(12).JPG")?.number, 12)
    }

    func testNonDuplicates() {
        XCTAssertNil(p("report.pdf"))
        XCTAssertNil(p("report (1) final.pdf"))
        XCTAssertNil(p("report(0).pdf"))
        XCTAssertNil(p("report(01).pdf"))
        XCTAssertNil(p("(1).pdf"))
        XCTAssertNil(p(".hidden(1).txt"))
        XCTAssertNil(p("report(a).pdf"))
    }

    func testFormatting() {
        let v = p("my.project.final(2).pdf")!
        XCTAssertEqual(v.name(forSlot: 0, spaced: false), "my.project.final.pdf")
        XCTAssertEqual(v.name(forSlot: 5, spaced: false), "my.project.final(5).pdf")
        XCTAssertEqual(v.name(forSlot: 5, spaced: true), "my.project.final (5).pdf")
    }

    func testTemporaryRules() {
        for n in ["a.pdf.part", "Unconfirmed 1234.crdownload", "a.pdf.download", "x.tmp", ".DS_Store", ".fileshift-abc.pdf", "A.PDF.PART"] {
            XCTAssertTrue(DownloadRules.isTemporaryOrHidden(n), n)
        }
        XCTAssertFalse(DownloadRules.isTemporaryOrHidden("report(1).pdf"))
    }
}
