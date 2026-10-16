import XCTest
import TunoryCore
@testable import Tunory

// GAP A (phase 11): GUI folder selection. The folder picker hands
// user-selected FOLDERS to the ViewModel; the ViewModel must route them
// to the SAME canonical planner as file selection (never a second
// decision path), must claim the folder grant (sandbox claims the
// folder the powerbox handed us, not rebuilt file URLs), and must not
// count non-directory URLs as folder selections.
//
// Unit tests run unsandboxed: they prove the ViewModel routing and the
// claim contract at the transport boundary (same standard as the
// t_d07f9a4d security-scope suite), not signed-sandbox proof.

@MainActor
final class LocalImportFolderSelectionTests: XCTestCase {

    // MARK: - Recording fake (same contract as the security-scope suite)

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
    private var albumA: URL!
    private var albumB: URL!
    private var outputDirectory: URL!
    private var journalDirectory: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunory-foldersel-\(UUID().uuidString)", isDirectory: true)
        albumA = work.appendingPathComponent("AlbumA", isDirectory: true)
        albumB = work.appendingPathComponent("AlbumB", isDirectory: true)
        outputDirectory = work.appendingPathComponent("out", isDirectory: true)
        journalDirectory = work.appendingPathComponent("journal", isDirectory: true)
        try FileManager.default.createDirectory(at: albumA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: albumB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
        try makeWAV(at: albumA.appendingPathComponent("01 Track.wav"), frequency: 440)
        try makeWAV(at: albumB.appendingPathComponent("01 Track.wav"), frequency: 660)
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

    /// Two selected folders plan with per-album prefixes and both folder
    /// grants are claimed and released during analyze.
    func testFolderSelectionPlansPerAlbumAndClaimsFolderGrants() async throws {
        let access = RecordingSecurityScopedAccess(granted: [albumA, albumB, outputDirectory])
        let model = makeModel(access: access)
        model.select(folders: [albumA, albumB])
        XCTAssertEqual(model.selectedCount, 2, "both selected folders must be tracked")
        await model.analyze(outputDirectory: outputDirectory)

        // Claim contract: the folder grants themselves (the URLs the
        // powerbox handed us) are claimed before the engine walks them.
        XCTAssertGreaterThanOrEqual(access.beginCount(for: albumA.standardizedFileURL.path), 1,
                                    "analyze must claim the granted folder URL itself")
        XCTAssertGreaterThanOrEqual(access.beginCount(for: albumB.standardizedFileURL.path), 1,
                                    "analyze must claim the granted folder URL itself")
        XCTAssertGreaterThanOrEqual(access.beginCount(for: outputDirectory.standardizedFileURL.path), 1,
                                    "analyze must claim the destination grant")
        access.assertBalanced()

        // Same canonical plan as the engine: per-album prefixes.
        XCTAssertEqual(model.step, .review)
        XCTAssertEqual(model.rows.count, 2)
        XCTAssertEqual(Set(model.rows.map(\.relativePath)),
                       ["AlbumA/01 Track.wav", "AlbumB/01 Track.wav"],
                       "folder selection must carry album-folder prefixes into the plan")
        for row in model.rows {
            XCTAssertEqual(row.decision, .convert,
                           "valid WAVs must classify as convert from content")
        }
    }

    /// One selected folder behaves exactly like the single-root batch
    /// walk: no prefix (engine contract: prefix only when >1 root).
    func testSingleFolderSelectionHasNoPrefix() async throws {
        let access = RecordingSecurityScopedAccess(granted: [albumA, outputDirectory])
        let model = makeModel(access: access)
        model.select(folders: [albumA])
        await model.analyze(outputDirectory: outputDirectory)
        access.assertBalanced()
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(model.rows.first?.relativePath, "01 Track.wav",
                       "single-folder selection must not add a prefix")
    }

    /// A non-directory URL must not be treated as a folder selection.
    func testFolderSelectionRejectsNonDirectories() async throws {
        let access = RecordingSecurityScopedAccess(granted: [albumA, outputDirectory])
        let model = makeModel(access: access)
        let fileURL = albumA.appendingPathComponent("01 Track.wav")
        model.select(folders: [fileURL])
        XCTAssertEqual(model.selectedCount, 0,
                       "a file URL handed to folder selection must be ignored")
        await model.analyze(outputDirectory: outputDirectory)
        XCTAssertEqual(model.step, .select,
                       "analyze without a valid selection must stay on the select step")
        access.assertBalanced()
    }

    /// Folder grants flow through the whole pipeline: convert claims the
    /// folder grants too (sources are re-read from within them).
    func testFolderGrantsClaimedThroughConvert() async throws {
        let access = RecordingSecurityScopedAccess(granted: [albumA, albumB, outputDirectory])
        let model = makeModel(access: access)
        model.select(folders: [albumA, albumB])
        await model.analyze(outputDirectory: outputDirectory)
        access.resetEvents()

        await model.convertSelected()
        XCTAssertGreaterThanOrEqual(access.beginCount(for: albumA.standardizedFileURL.path), 1,
                                    "convert must claim the source folder grant (encode re-reads files inside)")
        XCTAssertGreaterThanOrEqual(access.beginCount(for: albumB.standardizedFileURL.path), 1,
                                    "convert must claim the source folder grant (encode re-reads files inside)")
        XCTAssertGreaterThanOrEqual(access.beginCount(for: outputDirectory.standardizedFileURL.path), 1,
                                    "convert must claim the destination grant")
        access.assertBalanced()

        let summary = model.resultsSummary
        XCTAssertEqual(summary.converted, 2)
        XCTAssertEqual(summary.failed, 0)
        // Destination layout: per-album subfolders under the output dir.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: outputDirectory.appendingPathComponent("AlbumA/01 Track.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: outputDirectory.appendingPathComponent("AlbumB/01 Track.m4a").path))
    }

    /// The same folder handed twice (panel quirk) selects once.
    func testDuplicateFolderSelectionCountsOnce() async throws {
        let access = RecordingSecurityScopedAccess(granted: [albumA, outputDirectory])
        let model = makeModel(access: access)
        model.select(folders: [albumA, albumA])
        XCTAssertEqual(model.selectedCount, 1,
                       "the same folder handed twice must count once")
        await model.analyze(outputDirectory: outputDirectory)
        XCTAssertEqual(model.rows.count, 1,
                       "the same folder handed twice must plan exactly once")
        access.assertBalanced()
    }

    /// Reset drops folder grants exactly like file grants.
    func testResetDropsFolderGrants() async throws {
        let access = RecordingSecurityScopedAccess(granted: [albumA, outputDirectory])
        let model = makeModel(access: access)
        model.select(folders: [albumA])
        model.reset()
        access.resetEvents()
        await model.analyze(outputDirectory: outputDirectory)
        XCTAssertEqual(access.beginCount(for: albumA.standardizedFileURL.path), 0,
                       "reset must drop stale folder grants")
        XCTAssertEqual(access.beginCount(for: outputDirectory.standardizedFileURL.path), 0,
                       "reset must drop the stale destination grant")
        access.assertBalanced()
        XCTAssertEqual(model.step, .select)
    }
}
