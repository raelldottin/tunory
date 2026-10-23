import XCTest
import TunoryCore
@testable import Tunory

// Regression for t_e6a35c8e (pre-conversion duplicate detection,
// fail-closed survey pairing): the Music survey step must pair every
// import candidate with ITS OWN survey outcome. The pre-fix model kept
// only successful surveys and zipped them against all candidates, so
// one failed survey shifted every later pairing - an unsurveyed file
// could land on the auto-import list (fail-closed violation) while a
// surveyed file was silently dropped or misclassified.
//
// Everything runs through the musicEngine injection seam with a
// programmable MusicScripting stub: no live Music.app, no library
// writes. The contract proven here:
//   1. a failed survey excludes that candidate from BOTH the ready
//      list and the review list - it is never re-paired with a
//      neighbor's survey;
//   2. every other candidate's pairing is exactly its own outcome
//      (the exact lists are asserted, not just membership);
//   3. any survey failure makes musicReviewRequired true (an
//      uncertain state never reads as "no review needed");
//   4. importToMusic imports only correctly-paired ready files;
//   5. unresolved conflicts are never auto-imported.
@MainActor
final class LocalImportViewModelMusicSurveyPairingTests: XCTestCase {

    // MARK: - Stubs

    /// Programmable Music.app scripting surface. Search results are
    /// decided per query; a nil value simulates a FAILED survey (Music
    /// busy, script error, timeout). add() records every file it was
    /// asked to import so tests can prove exactly which files were
    /// written.
    private final class StubSearchMusicScripting: MusicScripting, @unchecked Sendable {
        private let lock = NSLock()
        private let searchResults: [String: [MusicTrackRef]?]
        private var added: [URL] = []

        init(searchResults: [String: [MusicTrackRef]?]) {
            self.searchResults = searchResults
        }

        func musicVersion() async -> String? { "1.0-stub" }
        func libraryTrackCount() async -> Int? { 0 }

        func searchLibrary(query: String) async -> [MusicTrackRef]? {
            lock.lock(); defer { lock.unlock() }
            // Match by stem so a tag-derived query that still contains
            // the candidate's basename (e.g. "tone-a") resolves to the
            // same canned result. Unknown queries (none here) default to
            // an empty library rather than a survey failure.
            for (key, value) in searchResults {
                if query.contains(key) { return value }
            }
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

        func addedFiles() -> [URL] {
            lock.lock(); defer { lock.unlock() }
            return added
        }
    }

    /// Sequenced scripting surface (t_21d15d73): the pre-conversion
    /// duplicate preflight (card t_21d15d73) now surveys every SELECTED
    /// SOURCE before conversion, so a single key-based stub can no
    /// longer distinguish the preflight queries from the post-conversion
    /// survey queries. This stub returns `preflight` results for the
    /// first `preflight.count` searchLibrary calls and `post` results
    /// for the remainder — the exact call order of surveyedModel().
    private final class SequencedMusicScripting: MusicScripting, @unchecked Sendable {
        private let lock = NSLock()
        private let preflight: [[MusicTrackRef]?]
        private let post: [[MusicTrackRef]?]
        private var calls = 0
        private var added: [URL] = []

        init(preflight: [[MusicTrackRef]?], post: [[MusicTrackRef]?]) {
            self.preflight = preflight
            self.post = post
        }

        func musicVersion() async -> String? { "1.0-stub" }
        func libraryTrackCount() async -> Int? { 0 }

        func searchLibrary(query: String) async -> [MusicTrackRef]? {
            lock.lock(); defer { lock.unlock() }
            let idx = calls
            calls += 1
            if idx < preflight.count { return preflight[idx] }
            let p = idx - preflight.count
            if p < post.count { return post[p] }
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

        func addedFiles() -> [URL] {
            lock.lock(); defer { lock.unlock() }
            return added
        }
    }

    /// Permissive claim recorder: these tests prove survey pairing, not
    /// sandbox enforcement (that is LocalImportViewModelSecurityScopeTests'
    /// contract); every begin succeeds so claims never mask pairing
    /// behavior.
    private final class PermissiveSecurityScopedAccess: SecurityScopedAccessClaiming, @unchecked Sendable {
        func begin(url: URL) -> Bool { true }
        func end(url: URL) {}
    }

    // MARK: - Fixtures (test-owned temp dirs; never the real library)

    private var work: URL!
    private var sourceA: URL!
    private var sourceB: URL!
    private var sourceC: URL!
    private var outputDirectory: URL!
    private var journalDirectory: URL!
    private var destA: URL!
    private var destB: URL!
    private var destC: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunory-musicpair-\(UUID().uuidString)", isDirectory: true)
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
        // LocalImportEngine names converted outputs after the source
        // basename with an .m4a extension; the survey/import queries for
        // tagless candidates are those basenames without extension.
        destA = outputDirectory.appendingPathComponent("tone-a.m4a")
        destB = outputDirectory.appendingPathComponent("tone-b.m4a")
        destC = outputDirectory.appendingPathComponent("tone-c.m4a")
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

    private func makeModel(scripting: SequencedMusicScripting) -> LocalImportViewModel {
        LocalImportViewModel(engine: LocalImportEngine(),
                             musicEngine: MusicImportEngine(scripting: scripting),
                             journalDirectory: journalDirectory,
                             musicJournalDirectory: journalDirectory,
                             securityScopedAccess: PermissiveSecurityScopedAccess())
    }

    /// Drive the flow to three converted import candidates, then survey.
    /// The pre-conversion duplicate preflight (t_21d15d73) runs inside
    /// convertSelected() and must classify all three sources as
    /// missing (noCandidate) for this fixture to reach conversion; the
    /// post-conversion survey then exercises the canned `post` results.
    private func surveyedModel(scripting: SequencedMusicScripting) async -> LocalImportViewModel {
        let model = makeModel(scripting: scripting)
        model.select(files: [sourceA, sourceB, sourceC])
        await model.analyze(outputDirectory: outputDirectory)
        await model.convertSelected()
        XCTAssertEqual(model.outcomes.filter { $0.status == .converted }.count, 3,
                      "fixture: all three candidates must convert before the survey is meaningful")
        await model.surveyMusicLibrary()
        return model
    }

    // MARK: - Tests

    func testMidListSurveyFailureNeverShiftsPairingAndNeverAutoImports() async throws {
        let scripting = SequencedMusicScripting(
            preflight: [[], [], []],          // all three sources missing -> all convert
            post: [[], nil, []]                // converted candidates: clean, FAILURE, clean
        )
        let model = await surveyedModel(scripting: scripting)
        XCTAssertEqual(model.step, .musicReview)

        // Alignment invariant: one slot per candidate, in candidate
        // order, nil exactly where the survey failed.
        XCTAssertEqual(model.musicSurveys.count, 3)
        XCTAssertEqual(model.musicSurveys[0]?.matchKind, .noCandidate)
        XCTAssertNil(model.musicSurveys[1], "the failed survey must occupy its own slot, not vanish")
        XCTAssertEqual(model.musicSurveys[2]?.matchKind, .noCandidate)

        // (1)+(2) The failed file is absent from BOTH lists and every
        // other candidate is paired with its own survey. The pre-fix
        // successful-only zip produced [destA, destB] here - destB, the
        // UNSURVEYED file, sat on the auto-import list - so the exact
        // list is the regression proof.
        XCTAssertEqual(model.musicImportReadyFiles, [destA, destC])
        XCTAssertTrue(model.musicFilesNeedingReview.isEmpty)

        // The failed candidate surfaces as a failure path, never as a
        // silent skip.
        XCTAssertEqual(model.musicSurveyFailures, [destB.path])

        // (3) An uncertain state requires explicit user action.
        XCTAssertTrue(model.musicReviewRequired)

        // (4) Import (with the explicit resolution the review gate
        // demands) writes ONLY the correctly-paired ready files - the
        // unsurveyed file is never added to the library.
        await model.importToMusic()
        XCTAssertEqual(scripting.addedFiles(), [destA, destC])
        XCTAssertEqual(model.musicResultsSummary.imported, 2)
        XCTAssertEqual(model.musicResultsSummary.skipped, 0)
        XCTAssertEqual(model.musicResultsSummary.review, 0)
        XCTAssertEqual(model.musicResultsSummary.failed, 0)
        XCTAssertEqual(model.step, .musicResults)
    }

    func testReviewPairingIsExactAndUnresolvedConflictsNeverAutoImport() async throws {
        let refA = MusicTrackRef(persistentID: "LIB-A",
                                 name: "tone-a",
                                 locationPath: sourceA.path,
                                 durationSeconds: 3.0)
        let scripting = SequencedMusicScripting(
            preflight: [[], [], []],          // all three sources missing -> all convert
            post: [[refA], nil, []]            // converted: needsReview, FAILURE, clean
        )
        let model = await surveyedModel(scripting: scripting)
        XCTAssertEqual(model.step, .musicReview)

        // Exact pairing survives a mid-list failure on both lists: the
        // review file is destA (not shifted onto destB), the ready file
        // is destC (the pre-fix zip made the FAILED destB ready here).
        XCTAssertEqual(model.musicFilesNeedingReview, [destA])
        XCTAssertEqual(model.musicImportReadyFiles, [destC])
        XCTAssertEqual(model.musicSurveyFailures, [destB.path])
        XCTAssertTrue(model.musicReviewRequired)

        // (5) Without an explicit review resolution, unresolved conflicts
        // and failed files are never imported: only the clean candidate
        // is written.
        await model.importToMusic(reviewResolved: false)
        XCTAssertEqual(scripting.addedFiles(), [destC])
        XCTAssertEqual(model.musicResultsSummary.imported, 1)
        XCTAssertEqual(model.musicResultsSummary.skipped, 0)
        XCTAssertEqual(model.musicResultsSummary.review, 0)
        XCTAssertEqual(model.musicResultsSummary.failed, 0)
    }
}
