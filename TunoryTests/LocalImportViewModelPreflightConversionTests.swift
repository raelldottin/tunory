import XCTest
import TunoryCore
@testable import Tunory

// App-layer integration proof for card t_21d15d73 (phase 11 req 2):
// conversion must run ONLY for the tracks the duplicate preflight
// approved. Sources already in the Music library (exact duplicate or
// verified same-recording), failed surveys and — without explicit
// resolution — ambiguous matches are NEVER converted. Originals are
// never modified.
@MainActor
final class LocalImportViewModelPreflightConversionTests: XCTestCase {

    // MARK: - Sequenced scripting

    private final class PreflightSequencedMusicScripting: MusicScripting, @unchecked Sendable {
        private let lock = NSLock()
        private let results: [[MusicTrackRef]?]
        private var calls = 0
        private var added: [URL] = []

        init(results: [[MusicTrackRef]?]) { self.results = results }

        func musicVersion() async -> String? { "1.0-stub" }
        func libraryTrackCount() async -> Int? { 0 }
        func searchLibrary(query: String) async -> [MusicTrackRef]? {
            lock.lock(); defer { lock.unlock() }
            let idx = calls
            calls += 1
            if idx < results.count { return results[idx] }
            return []
        }
        func track(withPersistentID id: String) async -> MusicTrackRef? {
            MusicTrackRef(persistentID: id, name: nil,
                          locationPath: nil, durationSeconds: nil)
        }
        func add(file: URL) async -> String? {
            lock.lock(); defer { lock.unlock() }
            added.append(file)
            return "STUB-\(added.count)"
        }
        func addedFiles() -> [URL] { lock.lock(); defer { lock.unlock() }; return added }
    }

    private final class PermissiveSecurityScopedAccess: SecurityScopedAccessClaiming, @unchecked Sendable {
        func begin(url: URL) -> Bool { true }
        func end(url: URL) {}
    }

    // MARK: - Fixtures

    private var work: URL!
    private var outputDirectory: URL!
    private var journalDirectory: URL!
    private var sourceA: URL!
    private var sourceB: URL!
    private var sourceC: URL!
    private var ffmpegURL: URL?

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunory-preflightconv-\(UUID().uuidString)", isDirectory: true)
        outputDirectory = work.appendingPathComponent("out", isDirectory: true)
        journalDirectory = work.appendingPathComponent("journal", isDirectory: true)
        sourceA = work.appendingPathComponent("tone-a.wav")
        sourceB = work.appendingPathComponent("tone-b.wav")
        sourceC = work.appendingPathComponent("tone-c.wav")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
        try makeWAV(at: sourceA, frequency: 440)
        try makeWAV(at: sourceB, frequency: 660)
        try makeWAV(at: sourceC, frequency: 880)
        ffmpegURL = Self.locateFFmpeg()
    }

    override func tearDown() { try? FileManager.default.removeItem(at: work) }

    static func locateFFmpeg() -> URL? {
        [URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
         URL(fileURLWithPath: "/usr/local/bin/ffmpeg")].first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func makeWAV(at url: URL, frequency: Double) throws {
        let sampleRate = 44_100.0, seconds = 1.0
        let frames = Int(sampleRate * seconds)
        var samples = [Int16](repeating: 0, count: frames)
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            samples[i] = Int16(sin(2 * .pi * frequency * t) * 0.4 * Double(Int16.max))
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

    private func makeFLAC(at url: URL, title: String, artist: String, album: String,
                          albumArtist: String, disc: Int, track: Int) throws {
        guard let ffmpeg = ffmpegURL else { throw XCTSkip("ffmpeg not installed") }
        var args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-f", "lavfi",
                    "-i", "sine=frequency=440:duration=3", "-f", "flac", "-c:a", "flac",
                    "-metadata", "title=\(title)", "-metadata", "artist=\(artist)",
                    "-metadata", "album=\(album)", "-metadata", "ALBUMARTIST=\(albumArtist)",
                    "-metadata", "DISCNUMBER=\(disc)", "-metadata", "TRACKNUMBER=\(track)",
                    url.path]
        let task = Process()
        task.executableURL = ffmpeg
        task.arguments = args
        let pipe = Pipe()
        task.standardError = pipe
        try task.run()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
    }

    private func makeModel(scripting: PreflightSequencedMusicScripting) -> LocalImportViewModel {
        LocalImportViewModel(engine: LocalImportEngine(),
                             musicEngine: MusicImportEngine(scripting: scripting),
                             journalDirectory: journalDirectory,
                             musicJournalDirectory: journalDirectory,
                             securityScopedAccess: PermissiveSecurityScopedAccess())
    }

    // MARK: - Tests

    func testExactDuplicateSourceIsNeverConverted() async throws {
        let scripting = PreflightSequencedMusicScripting(results: [
            [MusicTrackRef(persistentID: "LIB-A", name: "tone-a",
                           locationPath: sourceA.path)]   // exact duplicate by bytes
        ])
        let model = makeModel(scripting: scripting)
        model.select(files: [sourceA])
        await model.analyze(outputDirectory: outputDirectory)
        let shaBefore = LocalImportEngine.sha256Hex(fileURL: sourceA)
        await model.convertSelected()
        // Preflight classified it as a duplicate -> no conversion.
        XCTAssertEqual(model.step, .results)
        XCTAssertTrue(model.outcomes.isEmpty,
                      "an exact duplicate must never be converted")
        let destA = outputDirectory.appendingPathComponent("tone-a.m4a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destA.path),
                       "no converted output may be produced for a duplicate")
        XCTAssertEqual(LocalImportEngine.sha256Hex(fileURL: sourceA), shaBefore,
                       "original must remain byte-identical")
        XCTAssertEqual(model.preflightExcludedFiles, [sourceA])
        XCTAssertTrue(model.preflightReadyFiles.isEmpty)
    }

    func testVerifiedExistingSourceIsNeverConverted() async throws {
        guard ffmpegURL != nil else { throw XCTSkip("ffmpeg not installed") }
        let tagged = work.appendingPathComponent("tagged.flac")
        try makeFLAC(at: tagged, title: "Golden Hour", artist: "Artist",
                     album: "Album", albumArtist: "Album Artist",
                     disc: 1, track: 7)
        // Library track with matching six axes but DIFFERENT bytes
        // (pointed at sourceB.wav) -> verifiedExisting, not exactDuplicate.
        let scripting = PreflightSequencedMusicScripting(results: [
            [MusicTrackRef(persistentID: "LIB-V", name: "Golden Hour",
                           artist: "Artist", album: "Album",
                           albumArtist: "Album Artist", discNumber: 1,
                           trackNumber: 7, locationPath: sourceB.path,
                           durationSeconds: 3.0)]
        ])
        let model = makeModel(scripting: scripting)
        model.select(files: [tagged])
        await model.analyze(outputDirectory: outputDirectory)
        let shaBefore = LocalImportEngine.sha256Hex(fileURL: tagged)
        await model.convertSelected()
        XCTAssertEqual(model.step, .results)
        XCTAssertTrue(model.outcomes.isEmpty,
                      "a verified-existing recording must never be converted")
        let dest = outputDirectory.appendingPathComponent("tagged.m4a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertEqual(LocalImportEngine.sha256Hex(fileURL: tagged), shaBefore)
        XCTAssertEqual(model.preflightExcludedFiles, [tagged])
    }

    func testAmbiguousSourceRequiresExplicitResolutionBeforeConversion() async throws {
        // Streaming library track (no location) -> needsReview.
        let scripting = PreflightSequencedMusicScripting(results: [
            [MusicTrackRef(persistentID: "LIB-R", name: "tone-a",
                           locationPath: nil)]
        ])
        let model = makeModel(scripting: scripting)
        model.select(files: [sourceA])
        await model.analyze(outputDirectory: outputDirectory)
        await model.convertSelected()
        // Stops for explicit resolution; nothing converted yet.
        XCTAssertEqual(model.step, .musicPreflightReview)
        XCTAssertTrue(model.outcomes.isEmpty)
        XCTAssertEqual(model.preflightReviewFiles, [sourceA])
        let destA = outputDirectory.appendingPathComponent("tone-a.m4a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destA.path))

        // Without resolution, still no conversion.
        await model.convertAfterPreflight(reviewResolved: false)
        XCTAssertEqual(model.step, .results)
        XCTAssertTrue(model.outcomes.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destA.path))

        // With explicit resolution, converts.
        await model.preflightMusicLibrary()
        await model.convertAfterPreflight(reviewResolved: true)
        XCTAssertEqual(model.outcomes.filter { $0.status == .converted }.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destA.path))
    }

    func testFailedPreflightSurveyIsNeverConverted() async throws {
        let scripting = PreflightSequencedMusicScripting(results: [
            nil   // survey failure (Music busy / script error)
        ])
        let model = makeModel(scripting: scripting)
        model.select(files: [sourceA])
        await model.analyze(outputDirectory: outputDirectory)
        let shaBefore = LocalImportEngine.sha256Hex(fileURL: sourceA)
        await model.convertSelected()
        XCTAssertEqual(model.step, .results)
        XCTAssertTrue(model.outcomes.isEmpty,
                      "a failed (uncertain) survey must never be converted")
        let destA = outputDirectory.appendingPathComponent("tone-a.m4a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destA.path))
        XCTAssertEqual(LocalImportEngine.sha256Hex(fileURL: sourceA), shaBefore)
        XCTAssertEqual(model.preflightFailures, [sourceA.path])
        XCTAssertTrue(model.preflightReadyFiles.isEmpty)
    }

    func testOnlyPreflightApprovedSourcesConvert() async throws {
        let scripting = PreflightSequencedMusicScripting(results: [
            [MusicTrackRef(persistentID: "LIB-A", name: "tone-a",
                           locationPath: sourceA.path)],   // exact duplicate
            [],                                            // missing -> convert
            nil                                            // failed survey
        ])
        let model = makeModel(scripting: scripting)
        model.select(files: [sourceA, sourceB, sourceC])
        await model.analyze(outputDirectory: outputDirectory)
        let shas = [LocalImportEngine.sha256Hex(fileURL: sourceA),
                    LocalImportEngine.sha256Hex(fileURL: sourceB),
                    LocalImportEngine.sha256Hex(fileURL: sourceC)]
        await model.convertSelected()
        XCTAssertEqual(model.step, .results)
        // Only sourceB (missing) converted.
        XCTAssertEqual(model.outcomes.count, 1)
        XCTAssertEqual(model.outcomes[0].sourcePath, sourceB.path)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: outputDirectory.appendingPathComponent("tone-b.m4a").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outputDirectory.appendingPathComponent("tone-a.m4a").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outputDirectory.appendingPathComponent("tone-c.m4a").path))
        // Originals unchanged.
        XCTAssertEqual(LocalImportEngine.sha256Hex(fileURL: sourceA), shas[0])
        XCTAssertEqual(LocalImportEngine.sha256Hex(fileURL: sourceB), shas[1])
        XCTAssertEqual(LocalImportEngine.sha256Hex(fileURL: sourceC), shas[2])
        XCTAssertEqual(model.preflightExcludedFiles, [sourceA])
        XCTAssertEqual(model.preflightReadyFiles, [sourceB])
        XCTAssertEqual(model.preflightFailures, [sourceC.path])
    }
}
