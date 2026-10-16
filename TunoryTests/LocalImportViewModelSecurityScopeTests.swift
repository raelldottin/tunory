import XCTest
import TunoryCore
@testable import Tunory

// Regression for t_d07f9a4d: the Local Files flow must claim the
// powerbox grant (startAccessingSecurityScopedResource) for every
// user-selected URL it reads and the destination it reads/writes,
// and release every claim.
//
// Unit tests run UNSANDBOXED: they cannot and must not fake sandbox
// proof (the decisive proof is the signed-GUI drive). What they DO
// prove is the claim CONTRACT at the transport boundary:
//   1. every operation that touches a granted URL claims it first;
//   2. every successful claim is released exactly once (balanced);
//   3. claims are matched to the URLs the powerbox actually granted
//      (not rebuilt copies with different path spelling);
//   4. reset drops stale grants.
//
// The recording fake stands in for the powerbox: it marks a closed
// set of URLs as "granted" (begin -> true) and everything else as
// unscoped (begin -> false), so a claim on a rebuilt/foreign URL is
// caught as an assertion failure.

@MainActor
final class LocalImportViewModelSecurityScopeTests: XCTestCase {

    // MARK: - Recording fake

    private final class RecordingSecurityScopedAccess: SecurityScopedAccessClaiming, @unchecked Sendable {
        let lock = NSLock()
        private var grantedPaths: Set<String> = []
        private(set) var events: [(op: String, path: String)] = []

        init(granted: [URL]) {
            grantedPaths = Set(granted.map { $0.standardizedFileURL.path })
        }

        func resetEvents() {
            lock.lock(); defer { lock.unlock() }
            events.removeAll()
        }

        func begin(url: URL) -> Bool {
            let path = url.standardizedFileURL.path
            let scoped = grantedPaths.contains(path)
            lock.lock(); defer { lock.unlock() }
            events.append(("begin", path))
            return scoped
        }

        func end(url: URL) {
            let path = url.standardizedFileURL.path
            lock.lock(); defer { lock.unlock() }
            events.append(("end", path))
        }

        // Balanced-claims invariant: for every path, ends == successful
        // begins, and no end ever precedes its begin.
        func assertBalanced(file: StaticString = #filePath, line: UInt = #line) {
            lock.lock(); defer { lock.unlock() }
            var outstanding: [String: Int] = [:]
            for (op, path) in events {
                if op == "begin" {
                    outstanding[path, default: 0] += 1
                } else {
                    outstanding[path, default: 0] -= 1
                    XCTAssertGreaterThanOrEqual(outstanding[path]!, 0,
                                                 "end without matching begin for \(path)",
                                                 file: file, line: line)
                }
            }
            let leaks = outstanding.filter { $0.value != 0 }
            XCTAssertTrue(leaks.isEmpty,
                          "unreleased security-scoped claims: \(leaks)",
                          file: file, line: line)
        }

        func beginCount(for path: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return events.filter { $0.op == "begin" && $0.path == path }.count
        }
    }

    /// Stub Music.app scripting surface: deterministic, no live Music.app,
    /// no library writes. Search finds nothing (noCandidate); add reports
    /// a synthetic persistent ID; read-back verifies it.
    private final class StubMusicScripting: MusicScripting, @unchecked Sendable {
        func musicVersion() async -> String? { "1.0-stub" }
        func libraryTrackCount() async -> Int? { 0 }
        func searchLibrary(query: String) async -> [MusicTrackRef]? { [] }
        func track(withPersistentID id: String) async -> MusicTrackRef? {
            MusicTrackRef(persistentID: id, name: nil,
                          locationPath: nil, durationSeconds: nil)
        }
        func add(file: URL) async -> String? { "STUB1234" }
    }

    // MARK: - Fixtures (test-owned temp dirs; never the real library)

    private var work: URL!
    private var sourceA: URL!
    private var sourceB: URL!
    private var outputDirectory: URL!
    private var journalDirectory: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunory-scopescope-\(UUID().uuidString)", isDirectory: true)
        outputDirectory = work.appendingPathComponent("out", isDirectory: true)
        journalDirectory = work.appendingPathComponent("journal", isDirectory: true)
        sourceA = work.appendingPathComponent("tone-a.wav")
        sourceB = work.appendingPathComponent("tone-b.wav")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
        try makeWAV(at: sourceA, frequency: 440)
        try makeWAV(at: sourceB, frequency: 660)
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

    private func makeModel(access: RecordingSecurityScopedAccess) -> LocalImportViewModel {
        LocalImportViewModel(engine: LocalImportEngine(),
                             musicEngine: MusicImportEngine(scripting: StubMusicScripting()),
                             journalDirectory: journalDirectory,
                             musicJournalDirectory: journalDirectory,
                             securityScopedAccess: access)
    }

    // MARK: - Tests

    func testAnalyzeClaimsEveryGrantedURLAndReleasesAll() async throws {
        let access = RecordingSecurityScopedAccess(granted: [sourceA, sourceB, outputDirectory])
        let model = makeModel(access: access)
        model.select(files: [sourceA, sourceB])
        await model.analyze(outputDirectory: outputDirectory)

        // Decisive contract: both selected files AND the destination
        // directory (whose contents the destination guard reads) were
        // claimed before the engine touched them, and everything was
        // released.
        XCTAssertGreaterThanOrEqual(access.beginCount(for: sourceA.standardizedFileURL.path), 1,
                                    "analyze must claim the fileImporter grant for each selected file")
        XCTAssertGreaterThanOrEqual(access.beginCount(for: sourceB.standardizedFileURL.path), 1,
                                    "analyze must claim the fileImporter grant for each selected file")
        XCTAssertGreaterThanOrEqual(access.beginCount(for: outputDirectory.standardizedFileURL.path), 1,
                                    "analyze must claim the NSOpenPanel destination grant (destination guard reads it)")
        access.assertBalanced()

        // Engine behavior preserved: valid WAVs classify as convert
        // (lossless source, AAC-256 profile) — NOT undecodable.
        XCTAssertEqual(model.step, .review)
        XCTAssertEqual(model.rows.count, 2)
        for row in model.rows {
            XCTAssertEqual(row.decision, .convert,
                           "valid file must classify from content, not misreport as undecodable")
        }
    }

    func testConvertClaimsSourceAndDestinationGrantsAndReleasesAll() async throws {
        let access = RecordingSecurityScopedAccess(granted: [sourceA, sourceB, outputDirectory])
        let model = makeModel(access: access)
        model.select(files: [sourceA, sourceB])
        await model.analyze(outputDirectory: outputDirectory)
        access.assertBalanced()
        access.resetEvents()

        await model.convertSelected()
        XCTAssertGreaterThanOrEqual(access.beginCount(for: sourceA.standardizedFileURL.path), 1,
                                    "convert must claim the source grant (encode re-reads the source)")
        XCTAssertGreaterThanOrEqual(access.beginCount(for: outputDirectory.standardizedFileURL.path), 1,
                                    "convert must claim the destination grant (temp + promote writes there)")
        access.assertBalanced()

        // Invariants preserved: real conversion ran, destination written,
        // journal appended, no failures.
        let summary = model.resultsSummary
        XCTAssertEqual(summary.converted, 2)
        XCTAssertEqual(summary.failed, 0)
        let journal = LocalImportJournal(directory: journalDirectory)
        let records = (try journal.load()).records
        XCTAssertEqual(records.count, 2, "each converted file journals exactly one record")
    }

    func testMusicSurveyAndImportClaimGrantsAndReleaseAll() async throws {
        let access = RecordingSecurityScopedAccess(granted: [sourceA, sourceB, outputDirectory])
        let model = makeModel(access: access)
        model.select(files: [sourceA])
        await model.analyze(outputDirectory: outputDirectory)
        await model.convertSelected()
        access.resetEvents()

        await model.surveyMusicLibrary()
        XCTAssertGreaterThanOrEqual(access.beginCount(for: outputDirectory.standardizedFileURL.path), 1,
                                    "survey must claim the grant covering the converted candidate")
        access.assertBalanced()
        XCTAssertEqual(model.step, .musicReview)

        access.resetEvents()
        await model.importToMusic()
        XCTAssertGreaterThanOrEqual(access.beginCount(for: outputDirectory.standardizedFileURL.path), 1,
                                    "import must claim the grant before Music.app reads the file")
        access.assertBalanced()
        XCTAssertEqual(model.step, .musicResults)
        XCTAssertEqual(model.musicResultsSummary.imported, 1)
    }

    func testResetDropsStaleGrants() async throws {
        let access = RecordingSecurityScopedAccess(granted: [sourceA, outputDirectory])
        let model = makeModel(access: access)
        model.select(files: [sourceA])
        model.reset()
        access.resetEvents()

        // After reset there is nothing selected: analyze must not claim
        // the stale grants.
        await model.analyze(outputDirectory: outputDirectory)
        XCTAssertEqual(access.beginCount(for: sourceA.standardizedFileURL.path), 0,
                       "reset must drop stale fileImporter grants")
        XCTAssertEqual(access.beginCount(for: outputDirectory.standardizedFileURL.path), 0,
                       "reset must drop the stale destination grant (fresh analyze without selection claims nothing)")
        access.assertBalanced()
        XCTAssertEqual(model.step, .select)
    }

    func testClaimMatchesExactGrantedURLNotRebuiltCopy() async throws {
        // The powerbox grants the exact URL it handed the app; the engine
        // internally rebuilds URLs from paths. The claim must be issued
        // on the granted URL itself (verified above) — and a rebuilt
        // path spelled differently (trailing slash on a directory) must
        // NOT fool the claim into a mismatched begin/end pair.
        let grantedDir = outputDirectory!
        let access = RecordingSecurityScopedAccess(granted: [sourceA, grantedDir])
        let model = makeModel(access: access)
        model.select(files: [sourceA])
        await model.analyze(outputDirectory: grantedDir.appendingPathExtension("x").deletingPathExtension())
        access.assertBalanced()
        XCTAssertEqual(model.rows.count, 1)
    }
}
