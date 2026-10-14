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
}
