import XCTest
@testable import TunoryCore

// Music.app import engine tests. Everything runs against deterministic
// fakes: no live Music.app, no Apple Events, no library writes (owner
// rule: live writes are operator-gated; the verifier card t_ed3bfd46
// covers signed-app + TCC behavior). Fixtures are small data files
// generated into test-owned temp dirs at test time.
//
// Invariants under test (task t_31cf5210 body):
//   * exact duplicates are not imported (byte-hash proof);
//   * metadata collisions require explicit review (never auto-resolved);
//   * an uncertain import is reconciled against actual Music.app state
//     before a retry (never a blind re-add);
//   * durable recovery evidence (append-only journal, intent recorded
//     BEFORE the write);
//   * honest stop conditions (failed outcome + journal record, no
//     invented success);
//   * originals unchanged (the engine never writes to the import file).

private extension NSLocking {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }; return body()
    }
}

final class MusicImportEngineTests: XCTestCase {

    var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunory-musicimport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: work)
    }

    // MARK: - Fake scripting surface

    /// Deterministic in-memory Music.app: a fixed library plus a recording
    /// of every command. `nextAddResult` simulates what `add` returns;
    /// `readBackFinds` simulates whether the post-add read-back survey can
    /// observe the added track (false = the classic "add succeeded but
    /// state not yet visible" uncertainty).
    final class FakeMusicScripting: MusicScripting, @unchecked Sendable {
        struct AddCall { let file: URL }

        var library: [MusicTrackRef]
        /// Locations inserted by this fake's own `add` (read-back filter).
        private var addedLocations: Set<String> = []
        var addCalls: [AddCall] = []
        private(set) var searchQueries: [String] = []
        /// Result of the next `add` call: nil simulates Music reporting
        /// failure; a value simulates the returned persistent ID.
        var nextAddResult: String? = "ADDED123"
        /// When true, `add` actually inserts a matching track into the
        /// fake library (simulating a successful import).
        var addActuallyImports = true
        /// When true, `track(withPersistentID:)` returns nil even when
        /// the fake library holds the ID (simulating a failed read-back:
        /// Music busy, script error, timeout).
        var failReadBack = false
        /// When false, `searchLibrary` never returns tracks this fake
        /// added itself (read-back misses even though the add landed).
        var readBackFinds = true
        /// When true, `searchLibrary` returns nil (simulating a failed
        /// survey: Music busy, script error, timeout).
        var failSearch = false
        /// When nonzero, the survey fails only AFTER this many successful
        /// calls (0 = fail immediately when failSearch is true). Used to
        /// simulate a read-back failure after a successful pre-survey.
        var failSearchAfterCalls = 0
        private var searchCallCount = 0
        private let lock = NSLock()

        init(library: [MusicTrackRef] = []) {
            self.library = library
        }

        func musicVersion() async -> String? { "1.7.0" }
        func libraryTrackCount() async -> Int? {
            lock.withLock { library.count }
        }

        func searchLibrary(query: String) async -> [MusicTrackRef]? {
            lock.withLock {
                searchQueries.append(query)
                searchCallCount += 1
                if failSearch {
                    let threshold = failSearchAfterCalls
                    if threshold == 0 || searchCallCount > threshold {
                        return nil
                    }
                }
                var matches = library.filter { $0.name == query }
                if !readBackFinds {
                    matches = matches.filter { !(addedLocations.contains($0.locationPath ?? "")) }
                }
                return matches
            }
        }

        func track(withPersistentID id: String) async -> MusicTrackRef? {
            lock.withLock {
                if failReadBack { return nil }
                return library.first { $0.persistentID == id }
            }
        }

        func add(file: URL) async -> String? {
            lock.withLock {
                addCalls.append(AddCall(file: file))
                guard let id = nextAddResult else { return nil }
                if addActuallyImports {
                    addedLocations.insert(file.path)
                    library.append(MusicTrackRef(
                        persistentID: id,
                        name: file.deletingPathExtension().lastPathComponent,
                        locationPath: file.path,
                        durationSeconds: 3.0))
                }
                return id
            }
        }
    }

    // MARK: - Fixtures

    /// Small deterministic byte payload written to a test-owned file.
    func makeFile(name: String, bytes: [UInt8]) throws -> URL {
        let url = work.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    func makeJournal() -> MusicImportJournal {
        MusicImportJournal(directory: work)
    }

    // MARK: - classify / decision surface (pure logic)

    func test_classify_exactDuplicateByByteHash() throws {
        let bytes: [UInt8] = Array(0..<64).map { UInt8($0 % 251) }
        let importFile = try makeFile(name: "candidate.m4a", bytes: bytes)
        let libraryCopy = try makeFile(name: "library-copy.m4a", bytes: bytes)
        let hash = LocalImportEngine.sha256Hex(fileURL: importFile)
        XCTAssertNotNil(hash)

        let track = MusicTrackRef(persistentID: "AB12", name: "Tone",
                                  locationPath: libraryCopy.path, durationSeconds: 3.0)
        let engine = MusicImportEngine(scripting: FakeMusicScripting())
        let survey = engine.plan(filePath: importFile.path,
                                 candidateHash: hash,
                                 libraryTracks: [track])

        XCTAssertEqual(survey.matchKind, .exactDuplicate)
        XCTAssertEqual(survey.duplicate?.persistentID, "AB12")
        XCTAssertEqual(MusicImportEngine.decision(for: survey), .skipExactDuplicate)
    }

    func test_classify_metadataCandidateDifferentBytes_requiresReview() throws {
        let importFile = try makeFile(name: "candidate.m4a", bytes: [1, 2, 3, 4])
        let libraryFile = try makeFile(name: "library.m4a", bytes: [9, 9, 9, 9])
        let hash = LocalImportEngine.sha256Hex(fileURL: importFile)!

        let track = MusicTrackRef(persistentID: "CD34", name: "Tone",
                                  locationPath: libraryFile.path, durationSeconds: 3.0)
        let engine = MusicImportEngine(scripting: FakeMusicScripting())
        let survey = engine.plan(filePath: importFile.path,
                                 candidateHash: hash,
                                 libraryTracks: [track])

        XCTAssertEqual(survey.matchKind, .needsReview)
        XCTAssertEqual(survey.candidates.count, 1)
        XCTAssertEqual(MusicImportEngine.decision(for: survey), .reviewRequired)
    }

    func test_classify_streamingTrackWithoutLocation_requiresReview() throws {
        let importFile = try makeFile(name: "candidate.m4a", bytes: [1, 2, 3])
        let hash = LocalImportEngine.sha256Hex(fileURL: importFile)!

        let streaming = MusicTrackRef(persistentID: "EF56", name: "Tone",
                                      locationPath: nil, durationSeconds: 3.0)
        let engine = MusicImportEngine(scripting: FakeMusicScripting())
        let survey = engine.plan(filePath: importFile.path,
                                 candidateHash: hash,
                                 libraryTracks: [streaming])

        XCTAssertEqual(survey.matchKind, .needsReview)
        XCTAssertEqual(MusicImportEngine.decision(for: survey), .reviewRequired)
    }

    func test_classify_noLibraryTracks_isImportCandidate() throws {
        let importFile = try makeFile(name: "candidate.m4a", bytes: [1, 2, 3])
        let hash = LocalImportEngine.sha256Hex(fileURL: importFile)!

        let engine = MusicImportEngine(scripting: FakeMusicScripting())
        let survey = engine.plan(filePath: importFile.path,
                                 candidateHash: hash,
                                 libraryTracks: [])

        XCTAssertEqual(survey.matchKind, .noCandidate)
        XCTAssertEqual(MusicImportEngine.decision(for: survey), .importCandidate)
    }

    func test_classify_missingCandidateFile_isUndecodable() throws {
        let missing = work.appendingPathComponent("missing.m4a")
        let engine = MusicImportEngine(scripting: FakeMusicScripting())
        let survey = engine.plan(filePath: missing.path,
                                 candidateHash: nil,
                                 libraryTracks: [])
        XCTAssertEqual(survey.matchKind, .undecodableCandidate)
        XCTAssertEqual(MusicImportEngine.decision(for: survey), .undecodableFile)
    }

    func test_classify_nilHash_isUndecodableNotSilentImport() throws {
        let importFile = try makeFile(name: "candidate.m4a", bytes: [5, 6, 7])
        let engine = MusicImportEngine(scripting: FakeMusicScripting())
        let survey = engine.plan(filePath: importFile.path,
                                 candidateHash: nil,
                                 libraryTracks: [])
        XCTAssertEqual(survey.matchKind, .undecodableCandidate)
        XCTAssertEqual(MusicImportEngine.decision(for: survey), .undecodableFile)
    }

    // MARK: - importFile (write path via fake Music.app)

    func test_importFile_cleanLibrary_importsAndVerifies() async throws {
        let file = try makeFile(name: "tone.m4a", bytes: [1, 2, 3, 4, 5])
        let scripting = FakeMusicScripting()
        let engine = MusicImportEngine(scripting: scripting)
        let journal = makeJournal()

        let outcome = await engine.importFile(file: file,
                                              titleQuery: "tone",
                                              journal: journal,
                                              priorRecords: [])

        XCTAssertEqual(outcome.status, .imported)
        XCTAssertEqual(outcome.persistentID, "ADDED123")
        XCTAssertEqual(scripting.addCalls.count, 1)

        // Journal: attempted (intent BEFORE the write) then verified.
        let (records, _) = try journal.load()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].state, .attempted)
        XCTAssertEqual(records[1].state, .verified)
        XCTAssertEqual(records[1].persistentID, "ADDED123")
        XCTAssertEqual(records[1].observedPersistentID, "ADDED123")
    }

    func test_importFile_exactDuplicateInLibrary_neverCallsAdd() async throws {
        let bytes: [UInt8] = Array(repeating: 7, count: 32)
        let file = try makeFile(name: "tone.m4a", bytes: bytes)
        let libraryCopy = try makeFile(name: "lib.m4a", bytes: bytes)
        let scripting = FakeMusicScripting(library: [
            MusicTrackRef(persistentID: "AB12", name: "tone",
                          locationPath: libraryCopy.path, durationSeconds: 3.0)
        ])
        let engine = MusicImportEngine(scripting: scripting)

        let outcome = await engine.importFile(file: file,
                                              titleQuery: "tone",
                                              journal: makeJournal(),
                                              priorRecords: [])

        XCTAssertEqual(outcome.status, .skippedDuplicate)
        XCTAssertEqual(outcome.persistentID, "AB12")
        XCTAssertEqual(scripting.addCalls.count, 0, "exact duplicate must not be re-imported")
    }

    func test_importFile_metadataCollision_goesToReviewNotAutoImport() async throws {
        let file = try makeFile(name: "tone.m4a", bytes: [1, 2, 3])
        let differentLibraryFile = try makeFile(name: "lib.m4a", bytes: [8, 8, 8])
        let scripting = FakeMusicScripting(library: [
            MusicTrackRef(persistentID: "CD34", name: "tone",
                          locationPath: differentLibraryFile.path, durationSeconds: 3.0)
        ])
        let engine = MusicImportEngine(scripting: scripting)

        let outcome = await engine.importFile(file: file,
                                              titleQuery: "tone",
                                              journal: makeJournal(),
                                              priorRecords: [])

        XCTAssertEqual(outcome.status, .review)
        XCTAssertEqual(outcome.decision, .reviewRequired)
        XCTAssertEqual(scripting.addCalls.count, 0, "collisions must never auto-import")
    }

    func test_importFile_addReturnsNil_recordsFailureHonestly() async throws {
        let file = try makeFile(name: "tone.m4a", bytes: [1, 2, 3])
        let scripting = FakeMusicScripting()
        scripting.nextAddResult = nil
        let engine = MusicImportEngine(scripting: scripting)
        let journal = makeJournal()

        let outcome = await engine.importFile(file: file,
                                             titleQuery: "tone",
                                             journal: journal,
                                             priorRecords: [])

        XCTAssertEqual(outcome.status, .failed)
        XCTAssertNil(outcome.persistentID)
        XCTAssertEqual(scripting.addCalls.count, 1)

        // Journal: attempted (intent) then failed.
        let (records, _) = try journal.load()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].state, .attempted)
        XCTAssertEqual(records[1].state, .failed)
    }

    func test_importFile_readBackDoesNotConfirm_reconcileBeforeRetry() async throws {
        let file = try makeFile(name: "tone.m4a", bytes: [1, 2, 3])
        let scripting = FakeMusicScripting()
        // `add` claims success and the track IS inserted, but the read-back
        // (by persistent ID) fails: the "add succeeded but state not yet
        // observable" uncertainty.
        scripting.failReadBack = true
        let engine = MusicImportEngine(scripting: scripting)
        let journal = makeJournal()

        let outcome = await engine.importFile(file: file,
                                              titleQuery: "tone",
                                              journal: journal,
                                              priorRecords: [])

        // Uncertain: the add returned an ID but the fresh read-back did
        // not confirm. The engine must NOT re-add within the same call,
        // must report failure honestly, and must journal the observation.
        XCTAssertEqual(outcome.status, .failed)
        XCTAssertEqual(outcome.persistentID, "ADDED123")
        XCTAssertEqual(scripting.addCalls.count, 1,
                       "uncertain result must not trigger a blind re-add")
        let (records, _) = try journal.load()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].state, .attempted)
        XCTAssertEqual(records[1].state, .absent)
    }

    func test_importFile_retryAfterUncertain_reconcilesAgainstFreshState() async throws {
        let file = try makeFile(name: "tone.m4a", bytes: [1, 2, 3])
        let scripting = FakeMusicScripting()
        scripting.failReadBack = true
        let journal = makeJournal()
        let engine = MusicImportEngine(scripting: scripting)

        // First import ends uncertain (.absent) - add landed (the fake
        // library now holds a byte-identical "tone" track) but the
        // read-back by persistent ID could not observe it.
        _ = await engine.importFile(file: file, titleQuery: "tone",
                                    journal: journal, priorRecords: [])
        XCTAssertEqual(scripting.addCalls.count, 1)

        // Retry with the prior records: the engine re-derives from FRESH
        // state only. The fresh survey FINDS the previously-added track
        // and the byte-hash proves it identical - so the retry MUST skip
        // (no re-add, no duplicate) and must not invent success. This is
        // the reconcile-before-retry contract: the fresh state, not the
        // stale uncertain record, decides.
        scripting.addCalls = []
        let (prior, _) = try journal.load()
        let outcome2 = await engine.importFile(file: file, titleQuery: "tone",
                                               journal: journal, priorRecords: prior)

        XCTAssertEqual(scripting.addCalls.count, 0,
                       "fresh state proves the track already present - retry must not re-add")
        XCTAssertEqual(outcome2.status, .skippedDuplicate,
                       "reconciliation derives skip from fresh state, never invented success")
        let (records2, _) = try journal.load()
        XCTAssertEqual(records2.filter { $0.state == .absent }.count, 1)
        XCTAssertTrue(records2.allSatisfy { $0.state != .verified },
                      "uncertainty must never be recorded as verified")
    }

    func test_importFile_priorVerifiedRecord_skipsWithoutReAdd() async throws {
        let file = try makeFile(name: "tone.m4a", bytes: [1, 2, 3])
        let scripting = FakeMusicScripting()
        let engine = MusicImportEngine(scripting: scripting)
        let journal = makeJournal()

        let prior: [MusicImportJournalRecord] = [
            MusicImportJournalRecord(filePath: file.path, fileSHA256: "deadbeef",
                                     state: .verified, persistentID: "CAFE01",
                                     observedPersistentID: "CAFE01",
                                     recordedAt: ISO8601DateWithNanoseconds(secondsSinceEpoch: 100)),
        ]
        let outcome = await engine.importFile(file: file, titleQuery: "tone",
                                              journal: journal, priorRecords: prior)
        XCTAssertEqual(outcome.status, .skippedDuplicate)
        XCTAssertEqual(scripting.addCalls.count, 0)
        XCTAssertEqual(outcome.detail, "prior verified import recorded in journal")
    }

    func test_importFile_surveyFails_failsVisibleWithoutAdd() async throws {
        let file = try makeFile(name: "tone.m4a", bytes: [1, 2, 3])
        let scripting = FakeMusicScripting()
        scripting.failSearch = true
        let engine = MusicImportEngine(scripting: scripting)
        let journal = makeJournal()

        let outcome = await engine.importFile(file: file,
                                              titleQuery: "tone",
                                              journal: journal,
                                              priorRecords: [])

        // A failed survey must NEVER be read as "no candidates": the
        // import stops fail-visible, and nothing is written to Music.
        XCTAssertEqual(outcome.status, .failed)
        XCTAssertEqual(scripting.addCalls.count, 0,
                       "a failed duplicate survey must block the add entirely")
        let (records, _) = try journal.load()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].state, .failed)
    }

    func test_importFile_readBackSurveyFails_reportsUncertain() async throws {
        let file = try makeFile(name: "tone.m4a", bytes: [1, 2, 3])
        let scripting = FakeMusicScripting()
        // Pre-survey succeeds, then the read-back (by persistent ID)
        // after a successful add fails: the result must be reported as
        // uncertain, never absent and never verified.
        scripting.failReadBack = true
        let engine = MusicImportEngine(scripting: scripting)
        let journal = makeJournal()

        let outcome = await engine.importFile(file: file,
                                              titleQuery: "tone",
                                              journal: journal,
                                              priorRecords: [])

        XCTAssertEqual(outcome.status, .failed)
        XCTAssertEqual(outcome.persistentID, "ADDED123",
                       "the add DID return an ID - uncertainty, not absence")
        XCTAssertEqual(scripting.addCalls.count, 1)
        let (records, _) = try journal.load()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[1].state, .absent,
                       "uncertain read-back is recorded honestly, never verified")
    }

    func test_importFile_missingFile_failsWithoutAdd() async throws {
        let missing = work.appendingPathComponent("gone.m4a")
        let scripting = FakeMusicScripting()
        let engine = MusicImportEngine(scripting: scripting)
        let journal = makeJournal()

        let outcome = await engine.importFile(file: missing, titleQuery: "x",
                                              journal: journal, priorRecords: [])
        XCTAssertEqual(outcome.status, .failed)
        XCTAssertEqual(outcome.decision, .undecodableFile)
        XCTAssertEqual(scripting.addCalls.count, 0)
        let (records, _) = try journal.load()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].state, .failed)
    }

    func test_importFile_originalFileBytesUnchanged() async throws {
        let file = try makeFile(name: "tone.m4a", bytes: [1, 2, 3, 4, 5])
        let before = LocalImportEngine.sha256Hex(fileURL: file)
        let scripting = FakeMusicScripting()
        let engine = MusicImportEngine(scripting: scripting)

        _ = await engine.importFile(file: file, titleQuery: "tone",
                                    journal: makeJournal(), priorRecords: [])
        let after = LocalImportEngine.sha256Hex(fileURL: file)
        XCTAssertEqual(before, after, "import must never modify the file")
    }

    // MARK: - Explicit review resolution (owner rule: never auto-resolved)

    func test_importFile_metadataCollision_withoutResolution_returnsReviewWithCandidates() async throws {
        let file = try makeFile(name: "tone.m4a", bytes: [1, 2, 3])
        // Library holds a same-name track with DIFFERENT bytes: metadata
        // collision, not an exact duplicate.
        let libraryFile = try makeFile(name: "lib.m4a", bytes: [9, 9, 9])
        let scripting = FakeMusicScripting(library: [
            MusicTrackRef(persistentID: "CD34", name: "tone",
                          locationPath: libraryFile.path, durationSeconds: 3.0),
        ])
        let engine = MusicImportEngine(scripting: scripting)

        let outcome = await engine.importFile(file: file, titleQuery: "tone",
                                              journal: makeJournal(), priorRecords: [])

        XCTAssertEqual(outcome.status, .review)
        XCTAssertEqual(scripting.addCalls.count, 0,
                       "a review outcome must not write to Music")
        XCTAssertEqual(outcome.reviewCandidates.count, 1)
        XCTAssertEqual(outcome.reviewCandidates.first?.persistentID, "CD34",
                       "review candidates are surfaced so the UI can present evidence without a second survey")
    }

    func test_importFile_reviewResolved_proceedsWithExplicitResolution() async throws {
        let file = try makeFile(name: "tone.m4a", bytes: [1, 2, 3])
        let libraryFile = try makeFile(name: "lib.m4a", bytes: [9, 9, 9])
        let scripting = FakeMusicScripting(library: [
            MusicTrackRef(persistentID: "CD34", name: "tone",
                          locationPath: libraryFile.path, durationSeconds: 3.0),
        ])
        let engine = MusicImportEngine(scripting: scripting)
        let journal = makeJournal()

        let outcome = await engine.importFile(file: file, titleQuery: "tone",
                                              journal: journal, priorRecords: [],
                                              reviewResolved: true)

        XCTAssertEqual(outcome.status, .imported)
        XCTAssertEqual(scripting.addCalls.count, 1,
                       "explicit user resolution is the only path past a review")
        XCTAssertEqual(outcome.persistentID, "ADDED123")
        let (records, _) = try journal.load()
        XCTAssertEqual(records.last?.state, .verified)
    }

    func test_importFile_reviewResolved_exactDuplicateStillSkipped() async throws {
        let bytes: [UInt8] = Array(0..<64).map { UInt8($0 % 251) }
        let file = try makeFile(name: "tone.m4a", bytes: bytes)
        let libraryFile = try makeFile(name: "lib.m4a", bytes: bytes)
        let scripting = FakeMusicScripting(library: [
            MusicTrackRef(persistentID: "AB12", name: "tone",
                          locationPath: libraryFile.path, durationSeconds: 3.0),
        ])
        let engine = MusicImportEngine(scripting: scripting)

        let outcome = await engine.importFile(file: file, titleQuery: "tone",
                                              journal: makeJournal(), priorRecords: [],
                                              reviewResolved: true)

        XCTAssertEqual(outcome.status, .skippedDuplicate,
                       "reviewResolved must NEVER override an exact duplicate - fresh-state classify governs")
        XCTAssertEqual(scripting.addCalls.count, 0)
    }

    // MARK: - Canonical title query

    func test_titleQuery_deterministic_basenameWithoutExtension() throws {
        XCTAssertEqual(MusicImportEngine.titleQuery(forFileAt: "/x/y/Song Name.m4a"),
                       "Song Name")
        XCTAssertEqual(MusicImportEngine.titleQuery(forFileAt: "/x/y/Tone.mp3"),
                       "Tone")
        XCTAssertEqual(MusicImportEngine.titleQuery(forFileAt: "nosplit"),
                       "nosplit",
                       "a path with no extension must fall back to the full name")
    }

    // MARK: - Read-only survey

    func test_surveyFile_classifiesWithoutWriting() async throws {
        let bytes: [UInt8] = Array(0..<64).map { UInt8($0 % 251) }
        let file = try makeFile(name: "tone.m4a", bytes: bytes)
        let libraryFile = try makeFile(name: "lib.m4a", bytes: bytes)
        let scripting = FakeMusicScripting(library: [
            MusicTrackRef(persistentID: "AB12", name: "tone",
                          locationPath: libraryFile.path, durationSeconds: 3.0),
        ])
        let engine = MusicImportEngine(scripting: scripting)

        let survey = await engine.surveyFile(file: file)

        XCTAssertEqual(survey?.matchKind, .exactDuplicate)
        XCTAssertEqual(scripting.addCalls.count, 0,
                       "survey is read-only - it must never issue an add")
        XCTAssertEqual(scripting.searchQueries, ["tone"],
                       "survey must use the canonical title query derivation")
    }

    func test_surveyFile_failedSurvey_isNilFailStop() async throws {
        let file = try makeFile(name: "tone.m4a", bytes: [1, 2, 3])
        let scripting = FakeMusicScripting()
        scripting.failSearch = true
        let engine = MusicImportEngine(scripting: scripting)

        let survey = await engine.surveyFile(file: file)

        XCTAssertNil(survey,
                     "a failed survey must be nil (fail-stop), never an empty candidate list")
    }

    func test_journal_defaultDirectory_underApplicationSupport() throws {
        let dir = MusicImportJournal.defaultDirectory()
        XCTAssertTrue(dir.path.contains("Application Support"),
                      "journal must live under Application Support, got \(dir.path)")
        XCTAssertTrue(dir.path.hasSuffix("Tunory/Import"))
    }

    // MARK: - Journal (durable recovery evidence)

    func test_journal_roundtrip_sortedAndAppendOnly() throws {
        let journal = MusicImportJournal(directory: work)
        let older = MusicImportJournalRecord(filePath: "/a", fileSHA256: nil,
                                             state: .failed, persistentID: nil,
                                             observedPersistentID: nil,
                                             recordedAt: ISO8601DateWithNanoseconds(secondsSinceEpoch: 10))
        let newer = MusicImportJournalRecord(filePath: "/b", fileSHA256: "h",
                                             state: .attempted, persistentID: nil,
                                             observedPersistentID: nil,
                                             recordedAt: ISO8601DateWithNanoseconds(secondsSinceEpoch: 20))
        try journal.append([newer])
        try journal.append([older])
        let (records, warning) = try journal.load()
        XCTAssertNil(warning)
        XCTAssertEqual(records.count, 2)
        // Append order is the order: the second append is later in the
        // journal even when its wall-clock field is older.
        XCTAssertEqual(records.map(\.filePath), ["/b", "/a"],
                      "records must be sorted by append order (sequence), not wall clock")
    }

    func test_journal_unreadable_treatedAsEmptyWithWarning() throws {
        let journal = MusicImportJournal(directory: work)
        try Data("not json".utf8).write(to: journal.fileURL)
        let (records, warning) = try journal.load()
        XCTAssertEqual(records.count, 0)
        XCTAssertNotNil(warning, "an unreadable journal must be reported, not silent")
    }

    // MARK: - Liveness

    func test_isMusicReachable_viaVersionProbe() async throws {
        let engine = MusicImportEngine(scripting: FakeMusicScripting())
        let reachable = await engine.isMusicReachable()
        XCTAssertTrue(reachable)

        final class Unreachable: MusicScripting {
            func musicVersion() async -> String? { nil }
            func libraryTrackCount() async -> Int? { nil }
            func searchLibrary(query: String) async -> [MusicTrackRef]? { [] }
            func track(withPersistentID id: String) async -> MusicTrackRef? { nil }
            func add(file: URL) async -> String? { nil }
        }
        let dead = MusicImportEngine(scripting: Unreachable())
        let reachable2 = await dead.isMusicReachable()
        XCTAssertFalse(reachable2)
    }

    // MARK: - GAP C: cross-format duplicate preflight (phase 11, Req 2)
    //
    // A FLAC import candidate and an existing AAC of the SAME recording
    // can never be byte-identical, so the SHA-256 funnel alone would
    // route them to review every time. The classifier therefore also
    // recognizes a metadata-verified same-recording match: all six
    // axes (title, artist, album, album artist, disc, track) present on
    // BOTH sides and exactly equal, and both durations present and
    // within the ±2 s tolerance. Anything less keeps today's
    // conservative behavior: review, never a silent skip or import.

    private func makeCandidate(bytes: [UInt8] = [1, 2, 3, 4],
                                name: String = "candidate.m4a") throws -> URL {
        try makeFile(name: name, bytes: bytes)
    }

    /// Library twin carrying the full six-axis metadata.
    private func makeTwin(id: String = "TW01",
                          title: String? = "Song",
                          artist: String? = "Artist",
                          album: String? = "Album",
                          albumArtist: String? = "Artist",
                          disc: Int? = 1,
                          track: Int? = 3,
                          location: String,
                          duration: Double? = 200.0) -> MusicTrackRef {
        MusicTrackRef(persistentID: id, name: title, artist: artist, album: album,
                      albumArtist: albumArtist, discNumber: disc, trackNumber: track,
                      locationPath: location, durationSeconds: duration)
    }

    private func makeTags(title: String? = "Song",
                          artist: String? = "Artist",
                          album: String? = "Album",
                          albumArtist: String? = "Artist",
                          disc: Int? = 1,
                          track: Int? = 3) -> AudioMetadataTags {
        AudioMetadataTags(title: title, artist: artist, album: album,
                          albumArtist: albumArtist, discNumber: disc,
                          trackNumber: track)
    }

    func test_classify_verifiedExisting_allAxesEqualWithinDurationTolerance() throws {
        let candidate = try makeCandidate()
        let libraryFile = try makeFile(name: "library.aac", bytes: [9, 9, 9, 9])
        let twin = makeTwin(location: libraryFile.path, duration: 201.5)
        let hash = LocalImportEngine.sha256Hex(fileURL: candidate)!

        let survey = MusicImportEngine.classify(filePath: candidate.path,
                                                candidateHash: hash,
                                                candidateTags: makeTags(),
                                                candidateDurationSeconds: 200.0,
                                                libraryTracks: [twin])

        XCTAssertEqual(survey.matchKind, .verifiedExisting,
                       "FLAC candidate vs AAC twin: six axes equal + durations within ±2 s must verify as the same recording")
        XCTAssertEqual(survey.duplicate?.persistentID, "TW01",
                       "the verified twin is carried as evidence for the review/skip UI")
    }

    func test_classify_verifiedExisting_atToleranceEdge() throws {
        let candidate = try makeCandidate()
        let libraryFile = try makeFile(name: "library.aac", bytes: [9, 9, 9, 9])
        // |200.0 - 202.0| == 2.0 exactly: inside the tolerance (inclusive).
        let twin = makeTwin(location: libraryFile.path, duration: 202.0)
        let hash = LocalImportEngine.sha256Hex(fileURL: candidate)!

        let survey = MusicImportEngine.classify(filePath: candidate.path,
                                                candidateHash: hash,
                                                candidateTags: makeTags(),
                                                candidateDurationSeconds: 200.0,
                                                libraryTracks: [twin])

        XCTAssertEqual(survey.matchKind, .verifiedExisting)
    }

    func test_classify_remasterDifferentDuration_requiresReview() throws {
        let candidate = try makeCandidate()
        let libraryFile = try makeFile(name: "library.aac", bytes: [9, 9, 9, 9])
        // Same metadata axes, but a 2003 remaster runs 11 s longer: a
        // DIFFERENT recording - must never verify as the same one.
        let twin = makeTwin(location: libraryFile.path, duration: 211.0)
        let hash = LocalImportEngine.sha256Hex(fileURL: candidate)!

        let survey = MusicImportEngine.classify(filePath: candidate.path,
                                                candidateHash: hash,
                                                candidateTags: makeTags(),
                                                candidateDurationSeconds: 200.0,
                                                libraryTracks: [twin])

        XCTAssertEqual(survey.matchKind, .needsReview,
                       "a remaster (same tags, different duration) is a different recording - review")
    }

    func test_classify_sameDurationDifferentAlbum_requiresReview() throws {
        let candidate = try makeCandidate()
        let libraryFile = try makeFile(name: "library.aac", bytes: [9, 9, 9, 9])
        // Same song on a different album (e.g. greatest hits): not a duplicate.
        let twin = makeTwin(album: "Greatest Hits", location: libraryFile.path)
        let hash = LocalImportEngine.sha256Hex(fileURL: candidate)!

        let survey = MusicImportEngine.classify(filePath: candidate.path,
                                                candidateHash: hash,
                                                candidateTags: makeTags(),
                                                candidateDurationSeconds: 200.0,
                                                libraryTracks: [twin])

        XCTAssertEqual(survey.matchKind, .needsReview,
                       "same recording on a different album is not a duplicate - review")
    }

    func test_classify_discTrackTransposition_requiresReview() throws {
        let candidate = try makeCandidate()
        let libraryFile = try makeFile(name: "library.aac", bytes: [9, 9, 9, 9])
        // Track 3 disc 1 vs track 1 disc 3: both "present and equal" on
        // four axes but transposed on two - a different track.
        let twin = makeTwin(disc: 3, track: 1, location: libraryFile.path)
        let hash = LocalImportEngine.sha256Hex(fileURL: candidate)!

        let survey = MusicImportEngine.classify(filePath: candidate.path,
                                                candidateHash: hash,
                                                candidateTags: makeTags(disc: 1, track: 3),
                                                candidateDurationSeconds: 200.0,
                                                libraryTracks: [twin])

        XCTAssertEqual(survey.matchKind, .needsReview,
                       "disc/track transposition is a different track - review")
    }

    func test_classify_compilationAlbumArtistMismatch_requiresReview() throws {
        let candidate = try makeCandidate()
        let libraryFile = try makeFile(name: "library.aac", bytes: [9, 9, 9, 9])
        // Compilation: same track artist, different album artist.
        let twin = makeTwin(albumArtist: "Various Artists", location: libraryFile.path)
        let hash = LocalImportEngine.sha256Hex(fileURL: candidate)!

        let survey = MusicImportEngine.classify(filePath: candidate.path,
                                                candidateHash: hash,
                                                candidateTags: makeTags(albumArtist: "Artist"),
                                                candidateDurationSeconds: 200.0,
                                                libraryTracks: [twin])

        XCTAssertEqual(survey.matchKind, .needsReview,
                       "compilation album-artist mismatch is a different release - review")
    }

    func test_classify_missingAxisOnEitherSide_requiresReview() throws {
        let candidate = try makeCandidate()
        let libraryFile = try makeFile(name: "library.aac", bytes: [9, 9, 9, 9])
        let hash = LocalImportEngine.sha256Hex(fileURL: candidate)!

        // Library twin has no album artist: identity is not provable.
        let twin = makeTwin(albumArtist: nil, location: libraryFile.path)
        let surveyA = MusicImportEngine.classify(filePath: candidate.path,
                                                 candidateHash: hash,
                                                 candidateTags: makeTags(),
                                                 candidateDurationSeconds: 200.0,
                                                 libraryTracks: [twin])
        XCTAssertEqual(surveyA.matchKind, .needsReview,
                       "a missing axis on the library side cannot prove identity - review")

        // Candidate has no track number: identity is not provable.
        let twinB = makeTwin(location: libraryFile.path)
        let surveyB = MusicImportEngine.classify(filePath: candidate.path,
                                                 candidateHash: hash,
                                                 candidateTags: makeTags(track: nil),
                                                 candidateDurationSeconds: 200.0,
                                                 libraryTracks: [twinB])
        XCTAssertEqual(surveyB.matchKind, .needsReview,
                       "a missing axis on the candidate side cannot prove identity - review")
    }

    func test_classify_missingDurationOnEitherSide_requiresReview() throws {
        let candidate = try makeCandidate()
        let libraryFile = try makeFile(name: "library.aac", bytes: [9, 9, 9, 9])
        let hash = LocalImportEngine.sha256Hex(fileURL: candidate)!

        let twinNoDuration = makeTwin(location: libraryFile.path, duration: nil)
        let surveyA = MusicImportEngine.classify(filePath: candidate.path,
                                                 candidateHash: hash,
                                                 candidateTags: makeTags(),
                                                 candidateDurationSeconds: 200.0,
                                                 libraryTracks: [twinNoDuration])
        XCTAssertEqual(surveyA.matchKind, .needsReview,
                       "no library duration: cannot compare recordings - review")

        let twinB = makeTwin(location: libraryFile.path)
        let surveyB = MusicImportEngine.classify(filePath: candidate.path,
                                                 candidateHash: hash,
                                                 candidateTags: makeTags(),
                                                 candidateDurationSeconds: nil,
                                                 libraryTracks: [twinB])
        XCTAssertEqual(surveyB.matchKind, .needsReview,
                       "no candidate duration: cannot compare recordings - review")
    }

    func test_classify_byteIdenticalStillWinsOverVerifiedExisting() throws {
        // Byte-identical: the strongest identity proof - must keep
        // classifying as exactDuplicate even when metadata would also
        // verify (byte equality outranks metadata verification, and the
        // byte check runs first).
        let bytes: [UInt8] = Array(0..<64).map { UInt8($0 % 251) }
        let candidate = try makeCandidate(bytes: bytes)
        let libraryFile = try makeFile(name: "library.m4a", bytes: bytes)
        let twin = makeTwin(title: "candidate", location: libraryFile.path)
        let hash = LocalImportEngine.sha256Hex(fileURL: candidate)!

        let survey = MusicImportEngine.classify(filePath: candidate.path,
                                                candidateHash: hash,
                                                candidateTags: makeTags(title: "candidate"),
                                                candidateDurationSeconds: 200.0,
                                                libraryTracks: [twin])

        XCTAssertEqual(survey.matchKind, .exactDuplicate)
        XCTAssertEqual(survey.duplicate?.persistentID, "TW01")
    }

    func test_classify_noCandidateTags_metadataCandidate_requiresReview() throws {
        // Compatibility: the pre-GAP C behavior - a metadata candidate
        // with no candidate tags stays a review, never an auto-skip.
        let candidate = try makeCandidate()
        let libraryFile = try makeFile(name: "library.aac", bytes: [9, 9, 9, 9])
        let twin = makeTwin(location: libraryFile.path)
        let hash = LocalImportEngine.sha256Hex(fileURL: candidate)!

        let survey = MusicImportEngine.classify(filePath: candidate.path,
                                                candidateHash: hash,
                                                candidateTags: nil,
                                                candidateDurationSeconds: nil,
                                                libraryTracks: [twin])

        XCTAssertEqual(survey.matchKind, .needsReview,
                       "nil candidate tags must keep the conservative review, same as pre-GAP C")
    }

    func test_classify_verifiedExisting_skipsImportWithoutAdd() async throws {
        // End-to-end through importFile: a verified-existing twin is
        // skipped (skippedDuplicate outcome) and Music is never written.
        let candidate = try makeCandidate()
        let libraryFile = try makeFile(name: "library.aac", bytes: [9, 9, 9, 9])
        let twin = makeTwin(id: "VE09", title: "candidate",
                            location: libraryFile.path, duration: 200.0)
        let scripting = FakeMusicScripting(library: [twin])
        let engine = MusicImportEngine(scripting: scripting)

        let outcome = await engine.importFile(file: candidate,
                                              titleQuery: "candidate",
                                              candidateTags: makeTags(title: "candidate"),
                                              candidateDurationSeconds: 200.0,
                                              journal: makeJournal(),
                                              priorRecords: [])

        XCTAssertEqual(outcome.status, .skippedDuplicate,
                       "a verified-existing recording must skip import")
        XCTAssertEqual(outcome.decision, .skipVerifiedExisting)
        XCTAssertEqual(scripting.addCalls.count, 0,
                       "a verified-existing skip must never write to Music")
        XCTAssertEqual(outcome.persistentID, "VE09")
    }

    func test_classify_verifiedExisting_reviewResolvedDoesNotOverride() async throws {
        // Owner rule mirror of the exactDuplicate case: an explicit user
        // resolution can NEVER override a verified-existing skip - the
        // fresh survey governs.
        let candidate = try makeCandidate()
        let libraryFile = try makeFile(name: "library.aac", bytes: [9, 9, 9, 9])
        let twin = makeTwin(id: "VE10", title: "candidate",
                            location: libraryFile.path, duration: 200.0)
        let scripting = FakeMusicScripting(library: [twin])
        let engine = MusicImportEngine(scripting: scripting)

        let outcome = await engine.importFile(file: candidate,
                                              titleQuery: "candidate",
                                              candidateTags: makeTags(title: "candidate"),
                                              candidateDurationSeconds: 200.0,
                                              journal: makeJournal(),
                                              priorRecords: [],
                                              reviewResolved: true)

        XCTAssertEqual(outcome.status, .skippedDuplicate,
                       "reviewResolved must never override a verified-existing twin")
        XCTAssertEqual(scripting.addCalls.count, 0)
    }

    func test_decision_mapping_verifiedExisting() throws {
        // decision(for:) maps verifiedExisting to skipVerifiedExisting so
        // the import path skips without ever reaching the write.
        let survey = MusicLibraryCandidate(matchKind: .verifiedExisting,
                                           candidates: [],
                                           duplicate: makeTwin(location: "/x"))
        XCTAssertEqual(MusicImportEngine.decision(for: survey), .skipVerifiedExisting)
    }

    // MARK: GAP C item 5 - tag-preferred title query

    func test_surveyFile_prefersTagTitleOverFilename() async throws {
        // The FLAC's tags say "Golden Hour"; the FILENAME says "01_track".
        // Music's `search` is contains-match, so searching the tag title
        // finds the recording the filename query would have missed.
        let bytes: [UInt8] = Array(0..<64).map { UInt8($0 % 251) }
        let file = try makeFile(name: "01_track.flac", bytes: bytes)
        let libraryFile = try makeFile(name: "library.aac", bytes: bytes)
        let scripting = FakeMusicScripting(library: [
            makeTwin(id: "TAG1", title: "Golden Hour", location: libraryFile.path),
        ])
        let engine = MusicImportEngine(scripting: scripting)

        let survey = await engine.surveyFile(file: file,
                                             candidateTags: makeTags(title: "Golden Hour"),
                                             candidateDurationSeconds: 200.0)

        XCTAssertEqual(scripting.searchQueries, ["Golden Hour"],
                       "the search query must prefer the tag title over the filename derivation")
        XCTAssertEqual(survey?.matchKind, .exactDuplicate)
    }

    func test_surveyFile_taglessFallsBackToFilenameQuery() async throws {
        let file = try makeFile(name: "tone.m4a", bytes: [1, 2, 3])
        let scripting = FakeMusicScripting()
        let engine = MusicImportEngine(scripting: scripting)

        let survey = await engine.surveyFile(file: file, candidateTags: nil,
                                             candidateDurationSeconds: nil)

        XCTAssertEqual(scripting.searchQueries, ["tone"],
                       "without tags the canonical filename-derived query is used")
        XCTAssertEqual(survey?.matchKind, .noCandidate)
    }

    func test_importFile_prefersTagTitleQuery() async throws {
        let candidate = try makeCandidate()
        let scripting = FakeMusicScripting()
        let engine = MusicImportEngine(scripting: scripting)

        _ = await engine.importFile(file: candidate,
                                    titleQuery: "candidate",
                                    candidateTags: makeTags(title: "Golden Hour"),
                                    candidateDurationSeconds: 200.0,
                                    journal: makeJournal(),
                                    priorRecords: [])

        XCTAssertEqual(scripting.searchQueries, ["Golden Hour"],
                       "importFile must prefer the tag title as the survey query")
    }

    func test_importFile_taglessKeepsExplicitTitleQuery() async throws {
        let candidate = try makeCandidate()
        let scripting = FakeMusicScripting()
        let engine = MusicImportEngine(scripting: scripting)

        _ = await engine.importFile(file: candidate,
                                    titleQuery: "explicit query",
                                    candidateTags: nil,
                                    candidateDurationSeconds: nil,
                                    journal: makeJournal(),
                                    priorRecords: [])

        XCTAssertEqual(scripting.searchQueries, ["explicit query"],
                       "without tags the caller-provided titleQuery remains the query")
    }
}
