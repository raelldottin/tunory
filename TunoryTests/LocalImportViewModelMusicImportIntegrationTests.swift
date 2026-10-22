import XCTest
import TunoryCore
@testable import Tunory

// Integration-level proof of the Music.app import-flow contract
// (kanban task t_0dc47722). Everything runs through the musicEngine
// injection seam with a programmable MusicScripting stub: no live
// Music.app, no library writes. The contract proven here:
//   1. explicit confirmation gates every import - no write is issued
//      at any stage before the operator's explicit importToMusic call
//      (the confirmation dialog's only caller);
//   2. immediately before each write, the engine re-surveys Music.app
//      state - the global call log interleaves searchLibrary/add per
//      file (never a batched survey-then-write), and each add's own
//      fresh survey is visible in the log;
//   3. a state change between the UI survey and the import write is
//      caught by the pre-write recheck (survey failure, disappeared
//      file, prior verified import) and stops the write - the flow
//      fails closed;
//   4. only approved MISSING recordings are imported: unresolved
//      needsReview and failed surveys are never written; an explicitly
//      resolved needsReview is honored only while it stays ambiguous;
//   5. the journal records .attempted before each add and .verified
//      after the read-back, at the integrated flow level;
//   6. the review UI's evidence is exposed by the model: for every
//      ambiguous candidate, the library tracks the survey matched.
@MainActor
final class LocalImportViewModelMusicImportIntegrationTests: XCTestCase {

    // MARK: - Stubs

    /// Programmable MusicScripting that records every call in global
    /// order. `searchResults` are consumed one per searchLibrary call -
    /// preflight surveys first, then post-conversion UI surveys, then
    /// the engine's own import-time re-surveys - so tests can script
    /// state changes between the UI survey and the write. `[]` means
    /// "library has no candidate" (noCandidate); `nil` means the survey
    /// itself failed (Music busy/error - fail closed); `[track]` means
    /// a metadata candidate exists (needsReview for a tagless fixture).
    private final class RecordingMusicScripting: MusicScripting, @unchecked Sendable {
        private let lock = NSLock()
        private let searchResults: [[MusicTrackRef]?]
        private var calls = 0
        private(set) var added: [URL] = []
        private(set) var callLog: [String] = []

        init(searchResults: [[MusicTrackRef]?]) { self.searchResults = searchResults }

        func musicVersion() async -> String? { "1.0-stub" }
        func libraryTrackCount() async -> Int? { 0 }

        func searchLibrary(query: String) async -> [MusicTrackRef]? {
            lock.lock(); defer { lock.unlock() }
            callLog.append("searchLibrary")
            let idx = calls
            calls += 1
            return idx < searchResults.count ? searchResults[idx] : []
        }

        func track(withPersistentID id: String) async -> MusicTrackRef? {
            lock.lock(); defer { lock.unlock() }
            callLog.append("track")
            return MusicTrackRef(persistentID: id, name: nil,
                                 locationPath: nil, durationSeconds: nil)
        }

        func add(file: URL) async -> String? {
            lock.lock(); defer { lock.unlock() }
            callLog.append("add")
            added.append(file)
            return "STUB-\(added.count)"
        }

        func addedFiles() -> [URL] {
            lock.lock(); defer { lock.unlock() }
            return added
        }

        func log() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return callLog
        }
    }

    /// Permissive claim recorder: these tests prove the import-flow
    /// contract, not sandbox enforcement (that is the security-scope
    /// tests' contract); every begin succeeds so claims never mask
    /// flow behavior.
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
            .appendingPathComponent("tunory-musicimport-\(UUID().uuidString)", isDirectory: true)
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
        // basename with an .m4a extension.
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

    private func makeModel(scripting: MusicScripting,
                          localJournal: URL? = nil,
                          musicJournal: URL? = nil) -> LocalImportViewModel {
        LocalImportViewModel(engine: LocalImportEngine(),
                             musicEngine: MusicImportEngine(scripting: scripting),
                             journalDirectory: localJournal ?? journalDirectory,
                             musicJournalDirectory: musicJournal ?? journalDirectory,
                             securityScopedAccess: PermissiveSecurityScopedAccess())
    }

    /// Drive the flow to a completed survey (preflight + convert +
    /// survey) over the given sources and output directory.
    /// `searchResults` must therefore carry at least the preflight
    /// surveys plus the post-conversion surveys, in call order.
    private func surveyedModel(scripting: MusicScripting,
                               sources: [URL],
                               outputDirectory: URL,
                               localJournal: URL? = nil,
                               musicJournal: URL? = nil,
                               expectedConversions: Int) async -> LocalImportViewModel {
        let model = makeModel(scripting: scripting,
                              localJournal: localJournal,
                              musicJournal: musicJournal)
        model.select(files: sources)
        await model.analyze(outputDirectory: outputDirectory)
        await model.convertSelected()
        XCTAssertEqual(model.outcomes.filter { $0.status == .converted }.count,
                      expectedConversions,
                      "fixture: all candidates must convert before the survey is meaningful")
        await model.surveyMusicLibrary()
        return model
    }

    /// A library track that collides with a tagless converted candidate
    /// by metadata but not by content: the engine classifies needsReview.
    private var reviewCollision: MusicTrackRef {
        MusicTrackRef(persistentID: "LIB-A", name: "tone-a",
                      artist: "Artist A", album: "Album A",
                      locationPath: sourceA.path, durationSeconds: 3.0)
    }

    // MARK: - 1. Explicit confirmation gates every import

    /// No write is issued at select/analyze/preflight/convert/survey.
    /// The only path that writes is the explicit importToMusic call -
    /// the confirmation dialog's sole caller.
    func testNoWriteIsIssuedBeforeTheExplicitImportCall() async throws {
        let scripting = RecordingMusicScripting(searchResults: [[], [], [], [], [], []])
        let model = makeModel(scripting: scripting)
        model.select(files: [sourceA, sourceB, sourceC])
        await model.analyze(outputDirectory: outputDirectory)
        XCTAssertTrue(scripting.addedFiles().isEmpty)
        await model.convertSelected()
        XCTAssertTrue(scripting.addedFiles().isEmpty, "preflight+convert must not write to Music")
        await model.surveyMusicLibrary()
        XCTAssertTrue(scripting.addedFiles().isEmpty, "survey is read-only")
        XCTAssertFalse(scripting.log().contains("add"),
                       "no add command may be issued before confirmation")
        XCTAssertEqual(model.step, .musicReview)

        // The explicit operator call is what initiates the writes.
        await model.importToMusic()
        XCTAssertEqual(scripting.addedFiles().count, 3)
    }

    // MARK: - 2. Per-write recheck of Music.app state

    /// Every add is immediately preceded by its own fresh library
    /// survey, and every survey precedes its add (never a batched
    /// survey-then-write). The import-time surveys are NEW calls: 3
    /// preflight + 3 UI survey + 3 import-time = 9 searchLibrary calls.
    func testEveryWriteIsImmediatelyPrecededByItsOwnFreshSurvey() async throws {
        let scripting = RecordingMusicScripting(
            searchResults: [[], [], [], [], [], [], [], [], []])
        let model = await surveyedModel(scripting: scripting,
                                        sources: [sourceA, sourceB, sourceC],
                                        outputDirectory: outputDirectory,
                                        expectedConversions: 3)
        await model.importToMusic()

        let log = scripting.log()
        // 3 preflight + 3 UI surveys + 3 fresh import-time surveys.
        XCTAssertEqual(log.filter { $0 == "searchLibrary" }.count, 9,
                       "each imported file must get a fresh survey, not a reused UI result")
        XCTAssertEqual(log.filter { $0 == "add" }.count, 3)
        // The write phase interleaves per file: survey, add, read-back.
        XCTAssertEqual(Array(log.dropFirst(6)),
                       ["searchLibrary", "add", "track",
                        "searchLibrary", "add", "track",
                        "searchLibrary", "add", "track"],
                       "each write must be immediately preceded by its own Music.app re-survey")
        // Belt-and-braces invariant over the whole log.
        for (index, entry) in log.enumerated() where entry == "add" {
            XCTAssertEqual(log[index - 1], "searchLibrary",
                           "an add at index \(index) was not preceded by a survey")
        }
    }

    // MARK: - 3. State changes between survey and write fail closed

    /// A candidate that looked missing during the UI survey but whose
    /// import-time survey FAILS (Music busy) is never written: the flow
    /// reports .failed, journals the failure, and journals no .attempted
    /// record (the write was never initiated).
    func testImportTimeSurveyFailureStopsTheWrite() async throws {
        // 1 file: preflight [], UI survey [], import-time survey nil.
        let scripting = RecordingMusicScripting(searchResults: [[], [], nil])
        let model = makeModel(scripting: scripting)
        model.select(files: [sourceA])
        await model.analyze(outputDirectory: outputDirectory)
        await model.convertSelected()
        await model.surveyMusicLibrary()
        XCTAssertEqual(model.musicImportReadyFiles, [destA], "fixture: candidate looked missing")

        await model.importToMusic()
        XCTAssertTrue(scripting.addedFiles().isEmpty,
                      "a failed import-time survey must stop the write")
        XCTAssertEqual(model.musicResultsSummary.failed, 1)
        XCTAssertEqual(model.musicResultsSummary.imported, 0)

        let journal = MusicImportJournal(directory: journalDirectory)
        let (records, _) = try journal.load()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].filePath, destA.path)
        XCTAssertEqual(records[0].state, .failed, "the failed survey is journaled")
        XCTAssertFalse(records.contains { $0.state == .attempted },
                       "intent must never be journaled for a write that was stopped")
    }

    /// A candidate that disappears between the UI survey and the import
    /// is caught by the pre-write existence check: .failed, no add for
    /// it, and the remaining candidate imports normally.
    func testImportTimeFileDisappearanceIsCaughtBeforeAnyWrite() async throws {
        // 2 files: preflight [], [] ; UI survey [], [] ; import-time [], [].
        let scripting = RecordingMusicScripting(searchResults: [[], [], [], [], [], []])
        let model = makeModel(scripting: scripting)
        model.select(files: [sourceA, sourceB])
        await model.analyze(outputDirectory: outputDirectory)
        await model.convertSelected()
        await model.surveyMusicLibrary()
        XCTAssertEqual(model.musicImportReadyFiles, [destA, destB])

        // External state change: the first candidate vanishes.
        try FileManager.default.removeItem(at: destA)

        await model.importToMusic()
        XCTAssertEqual(scripting.addedFiles(), [destB],
                       "the vanished candidate must not be written; its neighbor imports")
        XCTAssertEqual(model.musicOutcomes.filter { $0.status == .failed }.count, 1)
        XCTAssertEqual(model.musicOutcomes.filter { $0.status == .imported }.count, 1)
    }

    /// A candidate the UI survey classified ready, whose import-time
    /// reconciliation finds a PRIOR VERIFIED import (second run), is
    /// skipped even though the user confirmed: confirmation authorizes
    /// a missing-recording import, never a duplicate. The skip fires
    /// before any import-time survey or add (idempotent re-run).
    func testPriorVerifiedImportIsSkippedEvenAfterConfirmation() async throws {
        let musicJournal = journalDirectory.appendingPathComponent("music", isDirectory: true)

        // First run: destA imports and is journaled .verified.
        let first = RecordingMusicScripting(searchResults: [[], [], []])
        let model1 = makeModel(scripting: first, musicJournal: musicJournal)
        model1.select(files: [sourceA])
        await model1.analyze(outputDirectory: outputDirectory)
        await model1.convertSelected()
        await model1.surveyMusicLibrary()
        await model1.importToMusic()
        XCTAssertEqual(first.addedFiles(), [destA])
        XCTAssertEqual(model1.musicResultsSummary.imported, 1)

        // Reset the conversion side so run 2 re-produces the same
        // destination path (the engine refuses to overwrite a valid
        // existing output, which would take the skipValidOutput path).
        try FileManager.default.removeItem(at: destA)
        let localJournal2 = journalDirectory.appendingPathComponent("local2", isDirectory: true)

        // Second run, fresh conversion journal, SAME music journal: the
        // prior verified record for destA must short-circuit the write.
        let second = RecordingMusicScripting(searchResults: [[], [], []])
        let model2 = makeModel(scripting: second,
                               localJournal: localJournal2,
                               musicJournal: musicJournal)
        model2.select(files: [sourceA])
        await model2.analyze(outputDirectory: outputDirectory)
        await model2.convertSelected()
        XCTAssertEqual(model2.outcomes.filter { $0.status == .converted }.count, 1)
        await model2.surveyMusicLibrary()
        XCTAssertEqual(model2.musicImportReadyFiles, [destA],
                       "fixture: the UI survey sees a clean library")

        await model2.importToMusic()
        XCTAssertTrue(second.addedFiles().isEmpty,
                      "a prior verified import must never be re-added")
        XCTAssertEqual(model2.musicResultsSummary.skipped, 1)
        XCTAssertEqual(model2.musicResultsSummary.imported, 0)
        XCTAssertFalse(second.log().contains("add"),
                       "the skip must fire before any write command")
    }

    // MARK: - 4. Only approved missing recordings are imported

    /// Full spectrum across three candidates: needsReview (destA),
    /// noCandidate (destB), failed survey (destC). Without resolution
    /// only the missing recording is written; the ambiguous one and
    /// the failed one never are.
    func testUnresolvedReviewAndFailedSurveysAreNeverWritten() async throws {
        let scripting = RecordingMusicScripting(
            searchResults: [[], [], [], [reviewCollision], [], nil])
        let model = await surveyedModel(scripting: scripting,
                                        sources: [sourceA, sourceB, sourceC],
                                        outputDirectory: outputDirectory,
                                        expectedConversions: 3)
        XCTAssertEqual(model.musicFilesNeedingReview, [destA])
        XCTAssertEqual(model.musicImportReadyFiles, [destB])
        XCTAssertEqual(model.musicSurveyFailures, [destC.path])

        await model.importToMusic(reviewResolved: false)
        XCTAssertEqual(scripting.addedFiles(), [destB],
                       "unresolved review files and failed surveys are never written")
        XCTAssertEqual(model.musicResultsSummary.imported, 1)
    }

    /// With the explicit resolution, the still-ambiguous file is
    /// written too - and the journal proves intent was recorded before
    /// each write and verification after it, per file. Import order is
    /// deterministic: ready files in survey order, then the resolved
    /// review files (importToMusic builds ready + resolved).
    func testExplicitResolutionImportsStillAmbiguousFilesWithJournalIntentOrdering() async throws {
        // Fresh directories: the engine refuses to overwrite a valid
        // existing output, so the second run needs its own output/journals.
        let out = work.appendingPathComponent("out2", isDirectory: true)
        let localJournal = work.appendingPathComponent("local", isDirectory: true)
        let musicJournal = work.appendingPathComponent("music", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let destA2 = out.appendingPathComponent("tone-a.m4a")
        let destB2 = out.appendingPathComponent("tone-b.m4a")

        let scripting = RecordingMusicScripting(
            searchResults: [[], [], [], [reviewCollision], [], nil,
                            // import-time re-surveys (destB2, destA2):
                            [], [reviewCollision]])
        let model = await surveyedModel(scripting: scripting,
                                        sources: [sourceA, sourceB, sourceC],
                                        outputDirectory: out,
                                        localJournal: localJournal,
                                        musicJournal: musicJournal,
                                        expectedConversions: 3)
        XCTAssertEqual(model.musicFilesNeedingReview, [destA2])

        await model.importToMusic(reviewResolved: true)
        XCTAssertEqual(scripting.addedFiles(), [destB2, destA2],
                       "deterministic order: ready files first, then resolved review files")

        let journal = MusicImportJournal(directory: musicJournal)
        let (records, _) = try journal.load()
        // Per file, in import order (destB2 then destA2): .attempted
        // (before the add) then .verified (after the read-back).
        XCTAssertEqual(records.map(\.filePath), [destB2.path, destB2.path, destA2.path, destA2.path])
        XCTAssertEqual(records.map(\.state), [.attempted, .verified, .attempted, .verified],
                       "intent must be journaled before each write and verification after it")
    }

    // MARK: - 5. Non-destructive command surface

    /// The only write command the flow ever issues is `add`: the global
    /// call log contains only read commands (searchLibrary, track,
    /// liveness probes) and add. No delete/replace/set exists on the
    /// scripting surface, and none appears in the log.
    func testFlowIssuesOnlyReadCommandsAndAdd() async throws {
        let scripting = RecordingMusicScripting(searchResults: [[], [], [], [], [], []])
        let model = makeModel(scripting: scripting)
        model.select(files: [sourceA, sourceB])
        await model.analyze(outputDirectory: outputDirectory)
        await model.convertSelected()
        await model.surveyMusicLibrary()
        await model.importToMusic()

        let allowed: Set<String> = ["musicVersion", "libraryTrackCount", "searchLibrary", "track", "add"]
        for entry in scripting.log() {
            XCTAssertTrue(allowed.contains(entry),
                          "unexpected command issued by the flow: \(entry)")
        }
        XCTAssertEqual(scripting.addedFiles().count, 2)
    }

    // MARK: - 6. Review evidence for the confirmation UI

    /// The model exposes, per ambiguous candidate, the library tracks
    /// the survey matched - the evidence the confirmation UI renders.
    func testMusicReviewEvidenceExposesMatchedLibraryTracks() async throws {
        let scripting = RecordingMusicScripting(
            searchResults: [[], [], [], [reviewCollision], [], []])
        let model = await surveyedModel(scripting: scripting,
                                        sources: [sourceA, sourceB, sourceC],
                                        outputDirectory: outputDirectory,
                                        expectedConversions: 3)
        XCTAssertEqual(model.musicFilesNeedingReview, [destA])
        XCTAssertEqual(model.musicReviewEvidence.map { $0.file }, [destA])
        XCTAssertEqual(model.musicReviewEvidence.first?.candidates, [reviewCollision],
                       "the review UI must see exactly the tracks the engine matched")
        XCTAssertFalse(model.musicReviewEvidence.contains { $0.file == destB })
        XCTAssertFalse(model.musicReviewEvidence.contains { $0.file == destC })
    }

    /// Same contract before conversion: ambiguous preflight matches
    /// expose their library tracks, and only those.
    func testPreflightReviewEvidenceExposesMatchedLibraryTracks() async throws {
        // The preflight collision must NOT content-match the surveyed
        // source itself, or the engine correctly classifies the source
        // an exact duplicate instead of needsReview.
        let collision = MusicTrackRef(persistentID: "LIB-A", name: "tone-a",
                                      artist: "Artist A", album: "Album A",
                                      locationPath: sourceC.path, durationSeconds: 3.0)
        let scripting = RecordingMusicScripting(searchResults: [[collision], [], []])
        let model = makeModel(scripting: scripting)
        model.select(files: [sourceA, sourceB, sourceC])
        await model.analyze(outputDirectory: outputDirectory)
        await model.preflightMusicLibrary()
        XCTAssertEqual(model.step, .musicPreflightReview)
        XCTAssertEqual(model.preflightReviewFiles, [sourceA])
        XCTAssertEqual(model.preflightReviewEvidence.map { $0.file }, [sourceA])
        XCTAssertEqual(model.preflightReviewEvidence.first?.candidates, [collision])
        XCTAssertFalse(model.preflightReviewEvidence.contains { $0.file == sourceB })
    }

    // MARK: - Survey progress indicator

    /// The survey progress index is nil at idle (before any survey and
    /// after each survey completes); the View renders it live.
    func testSurveyingIndexIsIdleOutsideTheSurvey() async throws {
        let scripting = RecordingMusicScripting(searchResults: [[], [], [], [], [], []])
        let model = makeModel(scripting: scripting)
        XCTAssertNil(model.surveyingIndex, "idle before any survey")
        model.select(files: [sourceA, sourceB, sourceC])
        await model.analyze(outputDirectory: outputDirectory)
        await model.convertSelected()
        XCTAssertNil(model.surveyingIndex, "idle after the preflight survey completes")
        await model.surveyMusicLibrary()
        XCTAssertNil(model.surveyingIndex, "idle after the post-conversion survey completes")
        await model.importToMusic()
        XCTAssertNil(model.surveyingIndex, "idle after the import run")
    }
}
