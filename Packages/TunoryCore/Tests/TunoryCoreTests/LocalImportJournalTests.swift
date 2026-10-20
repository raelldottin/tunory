import XCTest
import TunoryCore

// C1/C6 (macos-sandbox-write-access-design.md §6): the canonical
// journal home. LocalImportJournal.defaultDirectory() defines the ONE
// place conversion evidence lives — the app container's
// Application Support/Tunory — so GUI and CLI share a single journal
// and user-picked destinations receive only converted audio (D5).
// Mirrors MusicImportJournal.defaultDirectory()'s fallback shape.
//
// Path-contract tests only: they must never write into the real
// container home. Append/load mechanics are covered by
// LocalImportEngineTests on test-owned directories.

final class LocalImportJournalTests: XCTestCase {

    /// The default directory is the app container's
    /// Application Support/Tunory, with the documented
    /// temporaryDirectory last-resort fallback.
    func testDefaultDirectoryIsContainerHome() {
        let url = LocalImportJournal.defaultDirectory()
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first
        let expected = (appSupport ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Tunory", isDirectory: true)
        XCTAssertEqual(url, expected,
                       "defaultDirectory() must resolve through Application Support/Tunory (fallback: temporaryDirectory)")
        XCTAssertEqual(url.lastPathComponent, "Tunory")
    }

    /// A journal constructed at the default directory addresses the
    /// canonical file inside it — the exact path the GUI injects and
    /// the CLI must construct (AC5: one shared journal).
    func testDefaultDirectoryJournalFileURL() {
        let journal = LocalImportJournal(directory: LocalImportJournal.defaultDirectory())
        XCTAssertEqual(journal.fileURL.lastPathComponent, LocalImportJournal.fileName)
        XCTAssertTrue(journal.fileURL.path.hasSuffix("Tunory/\(LocalImportJournal.fileName)"),
                      "journal file must live under Application Support/Tunory, got \(journal.fileURL.path)")
    }
}
