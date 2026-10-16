import Foundation

// MARK: - Music.app import via Apple Events: canonical engine
//
// THE canonical implementation of the Music.app import decision logic.
// The GUI and CLI are thin presentations of this engine; they must never
// re-derive an import decision.
//
// Owner contract (t_dc244b34 §6-§8, task t_31cf5210):
//
//   * Import = Music.app `add` (sdef command, access-group
//     com.apple.Music.library.read-write) of already-converted local files.
//     The Music library database is NEVER touched directly - all writes
//     flow through Music.app's own scripting interface (the app holds the
//     library file open; direct writes would corrupt it).
//   * Duplicate prevention: before any add, a READ-ONLY metadata search
//     (sdef `search library playlist 1 for "<title>"`) finds candidates;
//     a candidate is an exact duplicate only when the file at its
//     `location` is byte-identical (SHA-256) to the import candidate.
//     Ambiguous matches (metadata candidates with different bytes) REQUIRE
//     explicit user review - never auto-resolved (owner rule).
//   * Uncertain imports reconcile against ACTUAL Music.app state before a
//     retry: the recovery journal records intent before the write, and a
//     retry re-derives the decision from fresh state, never from the
//     stale record alone.
//   * Originals unchanged: import candidates are the converted outputs
//     produced by LocalImportEngine; nothing about the source file is
//     modified by this engine.
//
// The scripting surface is a protocol so every decision is testable
// without a live Music.app (fakes in tests; the real adapter is
// NSAppleScript in the app layer). All decisions are deterministic:
// same inputs -> same decision.

/// Read-only snapshot of one track as reported by Music.app.
/// Only fields used for decisions - never a mirror of the whole sdef.
public struct MusicTrackRef: Equatable, Sendable, Codable {
    /// Music.app persistent ID (hex string, stable across launches).
    public let persistentID: String
    /// Track name as shown in Music.app.
    public let name: String?
    /// POSIX path string of the track's file, if any.
    public let locationPath: String?
    /// Track duration in seconds, if reported.
    public let durationSeconds: Double?

    public init(persistentID: String,
                name: String?,
                locationPath: String?,
                durationSeconds: Double?) {
        self.persistentID = persistentID
        self.name = name
        self.locationPath = locationPath
        self.durationSeconds = durationSeconds
    }
}

/// Result of a READ-ONLY library survey for one import candidate.
public struct MusicLibraryCandidate: Equatable, Sendable, Codable {
    public enum MatchKind: String, Equatable, Sendable, Codable {
        /// Music reports a track whose file is byte-identical (SHA-256).
        case exactDuplicate
        /// Metadata candidates exist but none provably identical - the
        /// user must explicitly resolve (owner rule: never auto-resolve).
        case needsReview
        /// No metadata candidate in the library.
        case noCandidate
        /// The import candidate file itself is missing or unreadable:
        /// no honest import decision can be derived from it.
        case undecodableCandidate
    }
    public let matchKind: MatchKind
    /// Metadata candidates found by the read-only search (excluding the
    /// proven exact duplicate, if any). Populated for review UI.
    public let candidates: [MusicTrackRef]
    /// The proven exact duplicate, when matchKind == .exactDuplicate.
    public let duplicate: MusicTrackRef?

    init(matchKind: MatchKind, candidates: [MusicTrackRef], duplicate: MusicTrackRef?) {
        self.matchKind = matchKind
        self.candidates = candidates
        self.duplicate = duplicate
    }
}

/// The Music.app scripting surface this engine depends on. The real
/// adapter sends Apple Events via NSAppleScript (app layer); tests use
/// deterministic fakes. Reads are read-only; `add` is the ONLY write
/// command, and it goes through Music.app itself.
public protocol MusicScripting: Sendable {
    /// Music.app version string, or nil when unreachable.
    func musicVersion() async -> String?

    /// Count of tracks in the library (read-only liveness probe).
    func libraryTrackCount() async -> Int?

    /// READ-ONLY search of the library playlist for tracks whose metadata
    /// matches `query` (sdef `search` command, read access group).
    /// Returns nil when the survey itself failed (Music busy, script
    /// error, timeout): a failed survey must NEVER be treated as an empty
    /// library (that would auto-import duplicates).
    func searchLibrary(query: String) async -> [MusicTrackRef]?

    /// READ-ONLY fetch of one track by its persistent ID. Used to verify
    /// an add read-back exactly (the ID Music returned), rather than by
    /// title search - the added track's name comes from file metadata and
    /// need not match the search query. Returns nil on script failure;
    /// the returned ref's locationPath is the identity evidence.
    func track(withPersistentID id: String) async -> MusicTrackRef?

    /// Add one local file to the library (`add` command, read-write access
    /// group). Returns the persistent ID Music assigned, or nil on
    /// failure.
    func add(file: URL) async -> String?
}

/// Journal record for one Music.app import. Append-only: records are
/// never rewritten; superseding events are new records (LocalImportJournal
/// conventions). The journal is the durable recovery evidence - an
/// uncertain import is reconciled against fresh Music.app state, with the
/// journal supplying intent and prior observations.
public struct MusicImportJournalRecord: Equatable, Sendable, Codable {
    public enum State: String, Equatable, Sendable, Codable {
        /// Add command issued; result not yet confirmed against fresh state.
        case attempted
        /// Verified present in the library by a fresh read-back.
        case verified
        /// Fresh read-back proved the track absent - the add did not land.
        case absent
        /// Add reported failure before/without Music touching the library.
        case failed
    }
    public let filePath: String
    /// SHA-256 of the file bytes at add time (identity for reconciliation).
    public let fileSHA256: String?
    public let state: State
    /// Persistent ID returned by Music.app at add time, if any.
    public let persistentID: String?
    /// Persistent ID observed by the (re)conciliation read-back, if any.
    public let observedPersistentID: String?
    public let recordedAt: ISO8601DateWithNanoseconds
    /// Monotonic append order, assigned by the journal (1, 2, ...).
    /// Wall-clock ties (same second) must NEVER reorder records:
    /// intent-before-write is the recovery evidence contract.
    public let sequence: Int

    public init(filePath: String,
                fileSHA256: String?,
                state: State,
                persistentID: String?,
                observedPersistentID: String?,
                recordedAt: ISO8601DateWithNanoseconds,
                sequence: Int = 0) {
        self.filePath = filePath
        self.fileSHA256 = fileSHA256
        self.state = state
        self.persistentID = persistentID
        self.observedPersistentID = observedPersistentID
        self.recordedAt = recordedAt
        self.sequence = sequence
    }
}

/// Append-only Music import journal (LocalImportJournal conventions:
/// single JSON file, atomically replaced, sorted deterministically).
public struct MusicImportJournal: Sendable {
    public let directory: URL
    public static let fileName = "music-import-journal.json"

    public init(directory: URL) {
        self.directory = directory
    }

    /// Canonical on-disk home for the journal: Application Support /
    /// Tunory / Import. GUI and CLI both resolve their journal through
    /// here so recovery evidence lives in exactly one place.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Tunory", isDirectory: true)
            .appendingPathComponent("Import", isDirectory: true)
    }

    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// Load all records; empty when absent or unreadable. Fail-visible:
    /// an unreadable journal is reported, and treated as empty so the
    /// engine can only skip, never silently re-import.
    public func load() throws -> (records: [MusicImportJournalRecord], warning: String?) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ([], nil)
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let records = try JSONDecoder().decode([MusicImportJournalRecord].self, from: data)
            return (records, nil)
        } catch {
            return ([], "music import journal unreadable (\(error.localizedDescription)); treating as empty - no silent re-imports")
        }
    }

    /// Atomically append records: decode + assign monotonic sequence +
    /// append + sort by sequence + atomic replace. Sorting is by append
    /// order (sequence), never wall clock: intent-before-write ordering
    /// is the recovery evidence contract.
    public func append(_ newRecords: [MusicImportJournalRecord]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (existing, _) = try load()
        let base = existing.map(\.sequence).max() ?? 0
        let stamped = newRecords.enumerated().map { index, record in
            MusicImportJournalRecord(
                filePath: record.filePath,
                fileSHA256: record.fileSHA256,
                state: record.state,
                persistentID: record.persistentID,
                observedPersistentID: record.observedPersistentID,
                recordedAt: record.recordedAt,
                sequence: base + index + 1)
        }
        let merged = (existing + stamped).sorted {
            ($0.sequence, $0.recordedAt.secondsSinceEpoch, $0.filePath)
                < ($1.sequence, $1.recordedAt.secondsSinceEpoch, $1.filePath)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(merged)
        try data.write(to: fileURL, options: [.atomic])
    }
}

/// One file's import decision into Music.app.
public enum MusicImportDecision: String, Equatable, Sendable, Codable {
    /// No exact duplicate; import may proceed (caller confirms target).
    case importCandidate
    /// Byte-identical track already in the library - do not re-import.
    case skipExactDuplicate
    /// Metadata candidates exist but none provably identical - the user
    /// must explicitly resolve (owner rule: never auto-resolve).
    case reviewRequired
    /// The file itself is unreadable - nothing to import.
    case undecodableFile
}

/// Result of one import attempt against Music.app.
public struct MusicImportOutcome: Equatable, Sendable, Codable {
    public enum Status: String, Equatable, Sendable, Codable {
        case imported, skippedDuplicate, review, failed
    }
    public let filePath: String
    public let status: Status
    public let decision: MusicImportDecision?
    public let persistentID: String?
    public let detail: String?
    /// Metadata candidates behind a reviewRequired outcome (empty unless
    /// status == .review). Lets the review UI present the evidence without
    /// a second survey; the engine remains the only decision-maker.
    public let reviewCandidates: [MusicTrackRef]

    public init(filePath: String,
                status: Status,
                decision: MusicImportDecision?,
                persistentID: String?,
                detail: String?,
                reviewCandidates: [MusicTrackRef] = []) {
        self.filePath = filePath
        self.status = status
        self.decision = decision
        self.persistentID = persistentID
        self.detail = detail
        self.reviewCandidates = reviewCandidates
    }
}

/// The canonical Music.app import engine.
public struct MusicImportEngine: Sendable {

    public let scripting: MusicScripting

    public init(scripting: MusicScripting) {
        self.scripting = scripting
    }

    // MARK: - Liveness / capability preflight (read-only)

    /// True when Music.app is running and scriptable. Read-only.
    public func isMusicReachable() async -> Bool {
        await scripting.musicVersion() != nil
    }

    /// Canonical title-query derivation shared by the GUI and CLI: the
    /// import candidate's display name without its extension. Music.app's
    /// `search` matches track names; identity is then proven (or
    /// disproven) by the SHA-256 byte-compare in the duplicate funnel, so
    /// a name-derived query can only widen the survey, never silently
    /// narrow it. Deterministic: same file -> same query.
    public static func titleQuery(forFileAt path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? name : base
    }

    // MARK: - Planning (pure decision logic over read-only surveys)

    /// Survey result for one file, using already-fetched library tracks.
    ///
    /// Duplicate funnel (t_dc244b34 §6): metadata candidate search by
    /// title, then byte-compare each candidate's file at its `location`
    /// against the import candidate. Byte-identical -> exact duplicate
    /// (skip). Metadata match with different/unreadable bytes -> review.
    /// No candidates -> import candidate.
    public func plan(filePath: String,
                     candidateHash: String?,
                     libraryTracks: [MusicTrackRef]) -> MusicLibraryCandidate {
        Self.classify(filePath: filePath,
                      candidateHash: candidateHash,
                      libraryTracks: libraryTracks)
    }

    /// End-to-end READ-ONLY survey of one import candidate against live
    /// library state: derives the canonical title query, runs the metadata
    /// search, and classifies. No write is issued and no journal record is
    /// written. Returns nil when the survey itself fails (Music busy,
    /// script error, timeout) - callers must treat nil as a fail-stop,
    /// never as "no candidates".
    public func surveyFile(file: URL) async -> MusicLibraryCandidate? {
        let query = Self.titleQuery(forFileAt: file.path)
        guard let libraryTracks = await scripting.searchLibrary(query: query) else {
            return nil
        }
        let hash = LocalImportEngine.sha256Hex(fileURL: file)
        return Self.classify(filePath: file.path,
                             candidateHash: hash,
                             libraryTracks: libraryTracks)
    }

    /// Pure classification shared by planning and reconciliation: the
    /// single place a duplicate/collision decision is derived.
    static func classify(filePath: String,
                         candidateHash: String?,
                         libraryTracks: [MusicTrackRef]) -> MusicLibraryCandidate {
        guard FileManager.default.fileExists(atPath: filePath) else {
            return MusicLibraryCandidate(matchKind: .undecodableCandidate,
                                         candidates: [],
                                         duplicate: nil)
        }
        guard let candidateHash else {
            // No hash of the import candidate: identity cannot be proven,
            // so neither an auto-skip nor an auto-import is honest.
            return MusicLibraryCandidate(matchKind: .undecodableCandidate,
                                         candidates: libraryTracks,
                                         duplicate: nil)
        }
        var reviewList: [MusicTrackRef] = []
        for track in libraryTracks {
            guard let loc = track.locationPath else {
                // Streaming/no-file tracks cannot be byte-compared.
                reviewList.append(track)
                continue
            }
            guard let fileHash = LocalImportEngine.sha256Hex(fileURL: URL(fileURLWithPath: loc)) else {
                // Unreadable candidate file: cannot prove or disprove.
                reviewList.append(track)
                continue
            }
            if fileHash == candidateHash {
                return MusicLibraryCandidate(matchKind: .exactDuplicate,
                                             candidates: [],
                                             duplicate: track)
            }
            reviewList.append(track)
        }
        return MusicLibraryCandidate(matchKind: libraryTracks.isEmpty ? .noCandidate : .needsReview,
                                     candidates: reviewList,
                                     duplicate: nil)
    }

    /// Decision for one file, derived only from its survey. Deterministic.
    public static func decision(for survey: MusicLibraryCandidate) -> MusicImportDecision {
        switch survey.matchKind {
        case .noCandidate: return .importCandidate
        case .exactDuplicate: return .skipExactDuplicate
        case .needsReview: return .reviewRequired
        case .undecodableCandidate: return .undecodableFile
        }
    }

    // MARK: - Import (write path, via Music.app only)

    /// Import one confirmed file into the Music library via the sdef
    /// `add` command. Callers must have completed the duplicate review
    /// funnel. Returns the outcome and records journal evidence.
    ///
    /// Retry semantics (task body: "an uncertain import must be reconciled
    /// against actual Music.app state before a retry"): if the add result
    /// is uncertain, this method does NOT re-add. A later invocation
    /// re-surveys the library read-only and only proceeds when fresh
    /// state proves the file absent - otherwise a blind retry could
    /// duplicate the very track it was uncertain about.
    ///
    /// Explicit review resolution: the owner rule is that metadata
    /// collisions are never auto-resolved. When the user has explicitly
    /// resolved a review (caller passes reviewResolved == true), the fresh
    /// survey still runs and still governs: an exact duplicate on fresh
    /// state is ALWAYS skipped (never overridden), but a still-ambiguous
    /// survey proceeds on the explicit user resolution. The journal
    /// records the resolution with the attempt.
    @discardableResult
    public func importFile(file: URL,
                           titleQuery: String,
                           journal: MusicImportJournal,
                           priorRecords: [MusicImportJournalRecord],
                           reviewResolved: Bool = false) async -> MusicImportOutcome {
        let path = file.path

        func record(_ state: MusicImportJournalRecord.State,
                    _ hash: String?,
                    _ returnedID: String?,
                    _ observedID: String?) {
            try? journal.append([MusicImportJournalRecord(
                filePath: path, fileSHA256: hash, state: state,
                persistentID: returnedID, observedPersistentID: observedID,
                recordedAt: ISO8601DateWithNanoseconds())])
        }

        // Preconditions: file present and hashable.
        guard FileManager.default.fileExists(atPath: path) else {
            record(.failed, nil, nil, nil)
            return MusicImportOutcome(filePath: path, status: .failed,
                                      decision: .undecodableFile,
                                      persistentID: nil,
                                      detail: "file missing at import time")
        }
        let hash = LocalImportEngine.sha256Hex(fileURL: file)
        guard let hash else {
            record(.failed, nil, nil, nil)
            return MusicImportOutcome(filePath: path, status: .failed,
                                      decision: .undecodableFile,
                                      persistentID: nil,
                                      detail: "file unreadable (no SHA-256 digest)")
        }

        // Reconciliation against prior journal records: a prior verified
        // import is honored (never re-add), and any prior attempt on this
        // file requires fresh-state reconciliation before a re-add.
        let priorForFile = priorRecords.filter { $0.filePath == path }
        if let priorVerified = priorForFile.last(where: { $0.state == .verified }) {
            return MusicImportOutcome(filePath: path, status: .skippedDuplicate,
                                      decision: .skipExactDuplicate,
                                      persistentID: priorVerified.persistentID,
                                      detail: "prior verified import recorded in journal")
        }

        // Read-only duplicate survey before any write. A failed survey
        // (nil) is a fail-visible STOP: it must never be read as "no
        // candidates" (that would auto-import a possible duplicate).
        guard let libraryTracks = await scripting.searchLibrary(query: titleQuery) else {
            record(.failed, hash, nil, nil)
            return MusicImportOutcome(filePath: path, status: .failed,
                                      decision: .reviewRequired,
                                      persistentID: nil,
                                      detail: "duplicate survey failed - reconcile against Music.app state before importing")
        }
        let survey = Self.classify(filePath: path,
                                   candidateHash: hash,
                                   libraryTracks: libraryTracks)
        switch Self.decision(for: survey) {
        case .skipExactDuplicate:
            return MusicImportOutcome(filePath: path, status: .skippedDuplicate,
                                      decision: .skipExactDuplicate,
                                      persistentID: survey.duplicate?.persistentID,
                                      detail: "byte-identical track already in library")
        case .reviewRequired:
            // The only path past a review is an EXPLICIT user resolution
            // (owner rule: never auto-resolved). Even then, the fresh
            // survey above has already re-derived the decision - an
            // exact duplicate found on fresh state is skipped above, so
            // what proceeds here is only ever the still-ambiguous case
            // the user saw and confirmed.
            guard reviewResolved else {
                return MusicImportOutcome(filePath: path, status: .review,
                                          decision: .reviewRequired,
                                          persistentID: nil,
                                          detail: "metadata candidates need explicit review (not auto-resolved)",
                                          reviewCandidates: survey.candidates)
            }
        case .undecodableFile:
            record(.failed, hash, nil, nil)
            return MusicImportOutcome(filePath: path, status: .failed,
                                      decision: .undecodableFile,
                                      persistentID: nil,
                                      detail: "file unreadable")
        case .importCandidate:
            break
        }

        // Record intent BEFORE the write (durable recovery evidence).
        record(.attempted, hash, nil, nil)

        // The ONLY write: Music.app's own `add` command.
        let returnedID = await scripting.add(file: file)

        guard let returnedID, !returnedID.isEmpty else {
            // Add failed outright: record the failure honestly. A retry
            // must reconcile (the fresh survey above runs first next time).
            record(.failed, hash, nil, nil)
            return MusicImportOutcome(filePath: path, status: .failed,
                                      decision: .importCandidate,
                                      persistentID: nil,
                                      detail: "Music.app add returned no track")
        }

        // Verify against fresh state (read-back) before claiming success.
        // Exact verification by the persistent ID Music just returned:
        // the added track's name comes from file metadata and need not
        // match the title query, so title-search read-back can produce
        // false absences. A failed read-back is UNCERTAIN (may have
        // landed), never proven-absent.
        guard let observed = await scripting.track(withPersistentID: returnedID) else {
            record(.absent, hash, returnedID, nil)
            return MusicImportOutcome(filePath: path, status: .failed,
                                      decision: .importCandidate,
                                      persistentID: returnedID,
                                      detail: "read-back by persistent ID failed - result uncertain, reconcile before retry")
        }
        record(.verified, hash, returnedID, observed.persistentID)
        return MusicImportOutcome(filePath: path, status: .imported,
                                  decision: .importCandidate,
                                  persistentID: observed.persistentID,
                                  detail: "verified present by fresh read-back (persistent ID \(observed.persistentID), location \(observed.locationPath ?? "<none>"))")
    }
}
