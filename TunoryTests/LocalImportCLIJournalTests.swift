import XCTest
import TunoryCore
@testable import Tunory

// C2/C6 (macos-sandbox-write-access-design.md §6): the `local-import`
// CLI verb must journal into the app container home — constructed
// through LocalImportJournal.defaultDirectory(), the same value the
// GUI injects — never into the user-picked output directory. The
// destination receives only converted audio and transient temp files
// (design D5; AC4/AC5).
//
// `journalDirectory` on the verb is a test seam: production callers
// omit it and the canonical default applies. These tests inject a
// test-owned stand-in so the observation never writes into the real
// container home.

@MainActor
final class LocalImportCLIJournalTests: XCTestCase {

    // MARK: - Fixtures (test-owned temp dirs)

    private var work: URL!
    private var outputDirectory: URL!
    private var journalDirectory: URL!
    private var source: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunory-clijournal-\(UUID().uuidString)", isDirectory: true)
        outputDirectory = work.appendingPathComponent("out", isDirectory: true)
        journalDirectory = work.appendingPathComponent("journal", isDirectory: true)
        source = work.appendingPathComponent("tone.wav")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
        try makeWAV(at: source, frequency: 440)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: work)
    }

    /// Minimal valid mono 16-bit PCM WAV (~1 s). AVFoundation decodes it;
    /// no ffmpeg needed.
    private func makeWAV(at url: URL, frequency: Double) throws {
        let sampleRate = 44_100.0
        let seconds = 1.0
        let frames = Int(sampleRate * seconds)
        var samples = [Int16](repeating: 0, count: frames)
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            let v = sin(2 * .pi * frequency * t) * 0.4
            samples[i] = Int16(v * Double(Int16.max))
        }
        var data = Data()
        func append(_ s: String) { data.append(s.data(using: .ascii)!) }
        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        append("RIFF"); append32(UInt32(36 + frames * 2)); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)
        append32(UInt32(sampleRate)); append32(UInt32(sampleRate * 2)); append16(2); append16(16)
        append("data"); append32(UInt32(frames * 2))
        for s in samples { append16(UInt16(bitPattern: s)) }
        try data.write(to: url)
    }

    // MARK: - Tests

    /// A clean conversion journals into the container home, and the
    /// user-picked output directory receives ONLY the converted audio
    /// — no journal file (D5 makes this a new observable).
    func testLocalImportVerbJournalsIntoContainerNotOutputDirectory() async throws {
        let exitCode = await CLI.runLocalImport(args: ["local-import",
                                                       outputDirectory.path,
                                                       source.path],
                                                journalDirectory: journalDirectory)
        XCTAssertEqual(exitCode, 0, "a valid WAV must convert cleanly through the verb (exit 0)")

        // Destination received the converted audio…
        let converted = outputDirectory.appendingPathComponent("tone.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: converted.path),
                      "the verb must write the converted copy into the output directory")

        // …and NOTHING else journal-shaped (D5)…
        let journalInOutput = outputDirectory.appendingPathComponent(LocalImportJournal.fileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalInOutput.path),
                       "the output directory must not receive the conversion journal (D5): \(journalInOutput.path)")

        // …while the journal itself landed in the container-home
        // stand-in with exactly one record for the conversion.
        let journal = LocalImportJournal(directory: journalDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.fileURL.path),
                      "the verb must journal through the container-home directory (C2)")
        let records = (try journal.load()).records
        XCTAssertEqual(records.count, 1, "one converted file must journal exactly one record")
        XCTAssertEqual(records.first?.sourcePath, source.path)
        XCTAssertEqual(records.first?.destinationPath, converted.path,
                       "records stay path-keyed on the destination, surface-agnostic (AC7)")
    }

    /// Re-running the verb against the same output with the same
    /// journal home classifies the already-converted destination as
    /// skipped-valid (guard semantics unchanged across surfaces) and
    /// appends no new record — one journal, idempotent outcome.
    func testReplayThroughSharedJournalSkipsValidDestination() async throws {
        _ = await CLI.runLocalImport(args: ["local-import",
                                            outputDirectory.path,
                                            source.path],
                                     journalDirectory: journalDirectory)
        let first = (try LocalImportJournal(directory: journalDirectory).load()).records
        XCTAssertEqual(first.count, 1)

        let exitCode = await CLI.runLocalImport(args: ["local-import",
                                                       outputDirectory.path,
                                                       source.path],
                                                journalDirectory: journalDirectory)
        XCTAssertEqual(exitCode, 0, "a journaled valid destination must skip cleanly, not conflict")
        let second = (try LocalImportJournal(directory: journalDirectory).load()).records
        XCTAssertEqual(second.count, 1, "skipped-valid must not append a record")
    }
}
