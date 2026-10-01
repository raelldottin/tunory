import Foundation

// MARK: - Phase 7: Hermes automation result (canonical derivation)
//
// The Hermes automation interface exchanges FILES, not credentials:
//   1. Hermes writes a validated manifest (same ManifestParser contract as
//      every other front-end) to stdin or a container path;
//   2. Hermes launches the SIGNED app with the `run` verb;
//   3. the app performs the authorized MusicKit operations via the ONE
//      canonical §20 TransactionRunner (MusicDataRequestTransport keeps
//      developer and user tokens inside MusicKit — nothing is exported);
//   4. the app writes ONE structured result file. This type IS that file.
//
// Determinism rules:
//   • This derivation is a PURE function of (manifest, TransactionReport).
//     No wall-clock, no network, no UI state. Same inputs → same bytes.
//   • It never re-decides anything: every mutation decision and every
//     proof verdict comes from the canonical evidence in the report.
//   • Acknowledgment is never conflated with proof (§11/§14/§16):
//     `libraryAddHttpStatus` / `appendHttpStatus` carry what the server
//     ACKNOWLEDGED; `inLibraryAfter` / `storedAtPosition` carry what a
//     FRESH READ proved. `succeeded` is the final read-back verdict only.

/// Machine-readable error payload, mirroring the CLI's ErrorReport contract
/// (one stable `kind` string per §20 stop condition).
public struct AutomationErrorPayload: Equatable, Codable, Sendable {
    public let kind: String
    public let detail: String

    public init(kind: String, detail: String) {
        self.kind = kind
        self.detail = detail
    }

    /// Canonical mapping from AMError — the ONE place a stop condition gets
    /// its stable automation name (the CLI's ErrorReport uses the same
    /// strings; keep both in sync).
    public init(error: AMError) {
        let kind: String
        let detail: String
        switch error {
        case .transport(let message): kind = "transport"; detail = message
        case .notAuthorized: kind = "notAuthorized"; detail = "MusicKit authorization required"
        case .catalogLookupFailed(let id, let status):
            kind = "catalogLookupFailed"; detail = "catalog id \(id) http \(status)"
        case .libraryAddFailed(let id, let status):
            kind = "libraryAddFailed"; detail = "catalog id \(id) http \(status)"
        case .playlistCreationFailed(let status):
            kind = "playlistCreationFailed"; detail = "http \(status)"
        case .playlistAppendFailed(let pos, let id, _, let status):
            kind = "playlistAppendFailed"; detail = "pos \(pos) catalog id \(id) http \(status)"
        case .playlistNotFound(let name): kind = "playlistNotFound"; detail = name
        case .playlistAmbiguous(let name, let count):
            kind = "playlistAmbiguous"; detail = "\(name) matched \(count) playlists"
        case .playlistNotEditable(let id): kind = "playlistNotEditable"; detail = id
        case .playlistNotSafeToWrite(let id, let state):
            kind = "playlistNotSafeToWrite"; detail = "playlist \(id) state \(state)"
        case .librarySongMissing(let id):
            kind = "librarySongMissing"; detail = "catalog id \(id) absent from library"
        case .playlistVerificationFailed(let reason):
            kind = "playlistVerificationFailed"; detail = reason
        case .paginationAborted(let pages):
            kind = "paginationAborted"; detail = "stopped after \(pages) pages"
        case .malformedResponse(let message): kind = "malformedResponse"; detail = message
        case .checkpointDiverged(let reason):
            kind = "checkpointDiverged"; detail = reason
        }
        self.kind = kind
        self.detail = detail
    }
}

/// The structured per-recording row of the automation result file:
/// track identity, Library status, playlist status, position, errors —
/// exactly the fields the Phase 7 contract requires, position by position
/// in manifest order.
public struct AutomationTrackResult: Equatable, Codable, Sendable {
    public let pos: Int
    /// Authoritative recording identity (§10): the manifest catalog ID,
    /// proven to exist in the storefront catalog when the gate passed.
    public let catalogId: Int
    /// Gate 3 verdict for this recording (true = proven in catalog).
    public let catalogVerified: Bool
    /// Display title/artist as the manifest declared (sanity data only).
    public let name: String
    public let artist: String
    /// A fresh enumeration proved the recording in the Library BEFORE any
    /// adds were issued (phase-3 evidence).
    public let inLibraryBefore: Bool
    /// A library add was issued (§11). `libraryAddHttpStatus` is the
    /// server's ACKNOWLEDGMENT — never proof; proof is `inLibraryAfter`.
    public let libraryAddIssued: Bool
    public let libraryAddHttpStatus: Int?
    /// A fresh read proved the recording in the Library after adds (phase-5
    /// evidence; the §11 verdict). False when verification never ran or
    /// could not prove presence.
    public let inLibraryAfter: Bool
    /// A playlist append was issued for this recording (§14). The HTTP
    /// status is the server's acknowledgment of that one write.
    public let appendIssued: Bool
    public let appendHttpStatus: Int?
    /// The independent final read-back (§16) proved the EXACT catalog ID
    /// stored at this manifest position. False when the read-back never
    /// ran, never verified, or stores something else here.
    public let storedAtPosition: Bool
    /// Position-scoped machine error for this recording, if any canonical
    /// evidence blames it (catalog gate, library add, append, read-back).
    public let error: AutomationErrorPayload?

    public init(pos: Int, catalogId: Int, catalogVerified: Bool,
                name: String, artist: String,
                inLibraryBefore: Bool, libraryAddIssued: Bool,
                libraryAddHttpStatus: Int?, inLibraryAfter: Bool,
                appendIssued: Bool, appendHttpStatus: Int?,
                storedAtPosition: Bool, error: AutomationErrorPayload?) {
        self.pos = pos
        self.catalogId = catalogId
        self.catalogVerified = catalogVerified
        self.name = name
        self.artist = artist
        self.inLibraryBefore = inLibraryBefore
        self.libraryAddIssued = libraryAddIssued
        self.libraryAddHttpStatus = libraryAddHttpStatus
        self.inLibraryAfter = inLibraryAfter
        self.appendIssued = appendIssued
        self.appendHttpStatus = appendHttpStatus
        self.storedAtPosition = storedAtPosition
        self.error = error
    }
}

/// The complete automation result file: one JSON object describing the
/// whole transaction and every recording. `succeeded` is derived ONLY from
/// the canonical `report.succeeded` (final read-back verified the exact
/// manifest sequence) — never from acknowledgments.
public struct AutomationResult: Equatable, Codable, Sendable {
    public let playlistName: String
    public let playlistId: String?
    /// Playlist state the preflight classified BEFORE any write (§13).
    public let playlistStateBefore: String?
    public let succeeded: Bool
    /// Terminal §20 stop condition, when the transaction stopped.
    public let error: AutomationErrorPayload?
    /// The canonical phase sequence in execution order, as stable labels
    /// (deterministic audit trail of how far the transaction got).
    public let phases: [String]
    /// Per-recording rows, manifest order, position 1...N.
    public let tracks: [AutomationTrackResult]
    /// Fresh-read proof summary for the playlist (final §16 read-back),
    /// when the transaction reached it.
    public let playlistVerified: Bool?
    /// The credential-free checkpoint for an interrupted execute, when one
    /// was derived (Phase 6 recovery artifact; pass to `recover`).
    public let checkpoint: TransactionCheckpoint?
    /// Captured purely for audit ordering; recovery never branches on it.
    public let capturedAtMillisSinceEpoch: Int64

    public init(playlistName: String, playlistId: String?,
                playlistStateBefore: String?, succeeded: Bool,
                error: AutomationErrorPayload?, phases: [String],
                tracks: [AutomationTrackResult],
                playlistVerified: Bool?, checkpoint: TransactionCheckpoint?,
                capturedAtMillisSinceEpoch: Int64) {
        self.playlistName = playlistName
        self.playlistId = playlistId
        self.playlistStateBefore = playlistStateBefore
        self.succeeded = succeeded
        self.error = error
        self.phases = phases
        self.tracks = tracks
        self.playlistVerified = playlistVerified
        self.checkpoint = checkpoint
        self.capturedAtMillisSinceEpoch = capturedAtMillisSinceEpoch
    }
}

/// The ONE canonical derivation from transaction evidence to the
/// automation result. Pure and deterministic: same (manifest, report,
/// capturedAt) → identical result.
public enum AutomationResultBuilder {

    /// Stable phase labels, identical to the CLI's `phaseLabel` contract
    /// (the GUI's ProgressView shows the same names).
    public static func phaseLabel(_ kind: TransactionPhaseOutcome.Kind) -> String {
        switch kind {
        case .catalogGate: return "catalog"
        case .preflight: return "preflight"
        case .reconcile: return "reconcile"
        case .libraryAdd: return "library-add"
        case .libraryVerify: return "library-verify"
        case .plan: return "plan"
        case .execute: return "append"
        case .finalReadback: return "final-readback"
        case .stopped: return "stopped"
        }
    }

    /// Derives the full automation result. `capturedAtMillisSinceEpoch` is
    /// recorded for audit only; the derivation never branches on it.
    public static func build(manifest: ParsedManifest,
                             report: TransactionReport,
                             capturedAtMillisSinceEpoch: Int64) -> AutomationResult {
        // --- Index canonical evidence by position (single pass) ---
        var gateByPos: [Int: CatalogValidationReport.Entry] = [:]
        var addByPos: [Int: LibraryAddOutcome] = [:]
        var appendByPos: [Int: AppendOutcome] = [:]
        var preflight: PlaylistPreflightResult?
        var missingBefore: [Int] = []
        var stoppedError: AMError?

        for phase in report.phases {
            if let gate = phase.catalogReport {
                for entry in gate.entries where gateByPos[entry.pos] == nil {
                    gateByPos[entry.pos] = entry
                }
            }
            if let found = phase.preflight { preflight = found }
            if let missing = phase.missingFromLibraryBeforeAdds {
                missingBefore = missing
            }
            for add in phase.libraryAddOutcomes ?? [] {
                addByPos[add.pos] = add
            }
            for append in phase.appendOutcomes ?? [] where appendByPos[append.pos] == nil {
                appendByPos[append.pos] = append
            }
            if phase.kind == .stopped { stoppedError = phase.error }
        }
        let missingBeforeSet = Set(missingBefore)

        // --- Fresh-read proofs ---
        let libraryVerifiedAfter = report.libraryVerification?.verified == true
        var verifiedCatalogIds = Set<Int>()
        if let map = report.libraryVerification?.catalogToLibraryId {
            verifiedCatalogIds = Set(map.keys)
        }
        let readback = report.finalReadback

        // --- Playlist identity + pre-write state ---
        var playlistId: String?
        var stateBefore: String?
        if case .ok(let info, let state, _)? = preflight {
            playlistId = info.id
            stateBefore = state.label
        }

        // --- Per-recording rows in manifest order ---
        let tracks: [AutomationTrackResult] = manifest.entries.map { entry in
            let gate = gateByPos[entry.pos]
            let add = addByPos[entry.pos]
            let append = appendByPos[entry.pos]

            // §16 proof: the exact catalog ID stored at this position.
            var storedHere = false
            if let readback, readback.verified {
                storedHere = readback.actualCatalogIds.indices.contains(entry.pos - 1)
                    && readback.actualCatalogIds[entry.pos - 1] == entry.catalogId
            }

            // Position-scoped error: only canonical evidence that blames
            // THIS recording, in gate → add → append order.
            var rowError: AutomationErrorPayload?
            if let gate, !gate.ok {
                rowError = AutomationErrorPayload(
                    kind: "catalogLookupFailed",
                    detail: "catalog id \(entry.catalogId) http \(gate.httpStatus.map(String.init) ?? "nil")")
            } else if let add, !add.ok {
                rowError = AutomationErrorPayload(
                    kind: "libraryAddFailed",
                    detail: "catalog id \(entry.catalogId) http \(add.httpStatus)")
            } else if let append, !append.ok {
                rowError = AutomationErrorPayload(
                    kind: "playlistAppendFailed",
                    detail: "pos \(entry.pos) catalog id \(entry.catalogId) http \(append.httpStatus)")
            } else if stoppedError == .librarySongMissing(catalogId: entry.catalogId) {
                rowError = AutomationErrorPayload(
                    kind: "librarySongMissing",
                    detail: "catalog id \(entry.catalogId) absent from library")
            }

            return AutomationTrackResult(
                pos: entry.pos,
                catalogId: entry.catalogId,
                catalogVerified: gate?.ok ?? false,
                name: entry.name,
                artist: entry.artist,
                inLibraryBefore: !missingBeforeSet.contains(entry.catalogId),
                libraryAddIssued: add != nil,
                libraryAddHttpStatus: add?.httpStatus,
                inLibraryAfter: libraryVerifiedAfter
                    && verifiedCatalogIds.contains(entry.catalogId),
                appendIssued: append != nil,
                appendHttpStatus: append?.httpStatus,
                storedAtPosition: storedHere,
                error: rowError)
        }

        // --- Checkpoint for an interrupted execute (Phase 6) ---
        let checkpoint = TransactionRunner.checkpoint(
            forInterruptedExecuteIn: report,
            capturedAtMillisSinceEpoch: capturedAtMillisSinceEpoch)

        return AutomationResult(
            playlistName: report.playlistName,
            playlistId: playlistId,
            playlistStateBefore: stateBefore,
            succeeded: report.succeeded,
            error: stoppedError.map(AutomationErrorPayload.init(error:)),
            phases: report.phases.map { phaseLabel($0.kind) },
            tracks: tracks,
            playlistVerified: readback?.verified,
            checkpoint: checkpoint,
            capturedAtMillisSinceEpoch: capturedAtMillisSinceEpoch)
    }
}
