import Foundation

// MARK: - Canonical §20 transaction (GUI and CLI drive the same plan)
//
// Phase 4 proved this exact sequence live against Apple Music (the `transact`
// CLI verb). Phase 5 extracts it into this runner so the SwiftUI interface
// and the CLI orchestration execute the SAME canonical decisions — the UI
// never re-implements a mutation decision the core already owns
// (docs/apple-music-integration-retrospective.md §19, §20):
//
//   1. catalog gate   — every recording must exist (Gate 3)
//   2. preflight      — unique editable playlist, safe state (§13)
//   3. reconcile      — ONE library enumeration (§12), missing set
//   4. add missing    — one POST per recording (§11), stop on failure
//   5. verify library — fresh read; 202 is never proof (§11)
//   6. plan           — immutable plan over the verified library
//   7. execute        — fresh re-preflight (drift check), append-only
//                       writes with per-step fresh-read proof (§14)
//   8. final read-back— independent §16 verification
//
// Every stop condition (§20) is an explicit returned phase, never a silent
// pass; the runner never issues a write in an unsafe state.

/// One phase's outcome in the canonical sequence. The optional payload
/// arrays carry the per-recording evidence for the phase that produced it
/// (nil on every other phase).
public struct TransactionPhaseOutcome: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case catalogGate
        case preflight
        case reconcile
        case libraryAdd
        case libraryVerify
        case plan
        case execute
        case finalReadback
        /// The transaction aborted at this phase; `error` is set.
        case stopped
    }

    public let kind: Kind
    public let report: String
    public let error: AMError?
    /// 1-based sequence number of this phase within its transaction —
    /// deterministic ordering for live consumers regardless of how phase
    /// callbacks are delivered.
    public let ordinal: Int
    /// Per-recording outcomes of phase 4 (library adds), when this phase
    /// performed adds.
    public let libraryAddOutcomes: [LibraryAddOutcome]?
    /// Per-step outcomes of phase 7 (playlist appends), when this phase
    /// executed steps. On a `.stopped` phase this carries the partial
    /// evidence of the interrupted execute — every recorded step in order,
    /// where the LAST entry is the first unproven step (Phase 6 recovery
    /// derives its checkpoint's proven count from exactly this).
    public let appendOutcomes: [AppendOutcome]?
    /// Phase 1 evidence: the full Gate 3 report (identity verification per
    /// recording). Consumed by the Phase 7 automation result so track
    /// identities come from the canonical gate, never re-derived.
    public let catalogReport: CatalogValidationReport?
    /// Phase 2 evidence: the playlist preflight (identity + state + the
    /// missing suffix at classification time).
    public let preflight: PlaylistPreflightResult?
    /// Phase 3 evidence: the manifest catalog IDs a fresh enumeration
    /// proved MISSING from the library before any adds were issued.
    public let missingFromLibraryBeforeAdds: [Int]?

    public init(kind: Kind, report: String, error: AMError? = nil,
                ordinal: Int = 0,
                libraryAddOutcomes: [LibraryAddOutcome]? = nil,
                appendOutcomes: [AppendOutcome]? = nil,
                catalogReport: CatalogValidationReport? = nil,
                preflight: PlaylistPreflightResult? = nil,
                missingFromLibraryBeforeAdds: [Int]? = nil) {
        self.kind = kind
        self.report = report
        self.error = error
        self.ordinal = ordinal
        self.libraryAddOutcomes = libraryAddOutcomes
        self.appendOutcomes = appendOutcomes
        self.catalogReport = catalogReport
        self.preflight = preflight
        self.missingFromLibraryBeforeAdds = missingFromLibraryBeforeAdds
    }
}

/// The complete transaction evidence: every phase outcome in execution
/// order plus the terminal artifacts. `succeeded` mirrors the CLI's
/// exit-0 contract: the final read-back verified the exact sequence.
public struct TransactionReport: Equatable, Sendable {
    public let playlistName: String
    public let phases: [TransactionPhaseOutcome]
    public let plan: AppendPlan?
    public let libraryVerification: LibraryVerification?
    public let finalReadback: PlaylistVerification?
    public let succeeded: Bool

    public init(playlistName: String,
                phases: [TransactionPhaseOutcome],
                plan: AppendPlan?, libraryVerification: LibraryVerification?,
                finalReadback: PlaylistVerification?, succeeded: Bool) {
        self.playlistName = playlistName
        self.phases = phases
        self.plan = plan
        self.libraryVerification = libraryVerification
        self.finalReadback = finalReadback
        self.succeeded = succeeded
    }
}

/// What to do when the named playlist does not exist. The proven §20 flow
/// STOPS on `playlistNotFound` (never guesses a target); creating is a
/// strictly opt-in extension for the GUI's "Create playlist" step, gated
/// behind the same discovery-uniqueness rule.
public enum MissingPlaylistPolicy: Equatable, Sendable {
    case stop
    case create
}

/// Runs the canonical §20 sequence over a RESTEngine. All mutation
/// decisions live in RESTEngine; this type only sequences phases and
/// records evidence.
public struct TransactionRunner: Sendable {

    /// Maps any thrown error to the canonical stop error, PRESERVING typed
    /// AMErrors — `.notAuthorized` in particular must surface as itself
    /// (expired authorization is a distinct stop condition, §15/§20: the
    /// GUI must say "Apple Music access was lost", not "network failure").
    private static func asStopError(_ error: Error) -> AMError {
        if let amError = error as? AMError { return amError }
        return .transport(String(describing: error))
    }

    public let engine: RESTEngine

    /// Builds the credential-free checkpoint for an interrupted phase-7
    /// execute, from a stopped transaction's own evidence. Returns nil when
    /// the stop did not interrupt an execute (no plan, no steps, or a stop
    /// phase that carries no partial append outcomes). The proven-count
    /// rule itself lives in RecoveryPlanner — one canonical derivation.
    public static func checkpoint(forInterruptedExecuteIn report: TransactionReport,
                                  capturedAtMillisSinceEpoch: Int64) -> TransactionCheckpoint? {
        guard let plan = report.plan, !plan.steps.isEmpty,
              let stopped = report.phases.last(where: { $0.kind == .stopped }),
              stopped.error != nil,
              let outcomes = stopped.appendOutcomes else { return nil }
        return RecoveryPlanner.checkpointAfterInterruptedExecute(
            plan: plan,
            appendOutcomes: outcomes,
            stoppedBy: stopped.error,
            provenStoredCountBeforeExecute: (plan.steps.first?.pos ?? 1) - 1,
            provenLibraryCatalogIds: report.libraryVerification?.catalogToLibraryId.keys.sorted() ?? [],
            capturedAtMillisSinceEpoch: capturedAtMillisSinceEpoch)
    }

    public init(engine: RESTEngine) {
        self.engine = engine
    }

    /// Runs the full sequence. Each phase is reported as it completes via
    /// `onPhase` (live progress); the returned report is the evidence.
    @discardableResult
    public func run(manifest: ParsedManifest,
                    playlistName: String,
                    missingPlaylistPolicy: MissingPlaylistPolicy = .stop,
                    onPhase: ((TransactionPhaseOutcome) -> Void)? = nil) async -> TransactionReport {

        var phases: [TransactionPhaseOutcome] = []
        var ordinal = 0
        func nextOrdinal() -> Int { ordinal += 1; return ordinal }
        func emit(_ kind: TransactionPhaseOutcome.Kind, _ report: String,
                  libraryAddOutcomes: [LibraryAddOutcome]? = nil,
                  appendOutcomes: [AppendOutcome]? = nil,
                  catalogReport: CatalogValidationReport? = nil,
                  preflight: PlaylistPreflightResult? = nil,
                  missingFromLibraryBeforeAdds: [Int]? = nil) {
            let outcome = TransactionPhaseOutcome(kind: kind, report: report,
                                                  ordinal: nextOrdinal(),
                                                  libraryAddOutcomes: libraryAddOutcomes,
                                                  appendOutcomes: appendOutcomes,
                                                  catalogReport: catalogReport,
                                                  preflight: preflight,
                                                  missingFromLibraryBeforeAdds: missingFromLibraryBeforeAdds)
            phases.append(outcome)
            onPhase?(outcome)
        }
        func stop(_ error: AMError, at kind: TransactionPhaseOutcome.Kind,
                  plan: AppendPlan? = nil,
                  libraryVerification: LibraryVerification? = nil,
                  partialAppendOutcomes: [AppendOutcome]? = nil) -> TransactionReport {
            let outcome = TransactionPhaseOutcome(kind: .stopped, report: "STOP: \(error)",
                                                  error: error, ordinal: nextOrdinal(),
                                                  appendOutcomes: partialAppendOutcomes)
            phases.append(outcome)
            onPhase?(outcome)
            return TransactionReport(playlistName: playlistName,
                                     phases: phases, plan: plan,
                                     libraryVerification: libraryVerification,
                                     finalReadback: nil, succeeded: false)
        }

        // Phase 1: catalog gate — every recording must exist (Gate 3).
        let catalogReport = await engine.validateCatalog(manifest: manifest)
        emit(.catalogGate, "\(catalogReport.entries.filter { $0.ok }.count)/\(catalogReport.entries.count) catalog recordings verified",
             catalogReport: catalogReport)
        // §15: authorization loss is a distinct stop — never misreported as
        // "recording not found" (the gate could not be evaluated at all).
        guard !catalogReport.notAuthorized else {
            return stop(.notAuthorized, at: .catalogGate)
        }
        guard catalogReport.passed else {
            let bad = catalogReport.entries.first(where: { !$0.ok })
            return stop(.catalogLookupFailed(catalogId: bad?.catalogId ?? -1,
                                             httpStatus: bad?.httpStatus ?? -1),
                        at: .catalogGate)
        }

        // Phase 2: playlist preflight (unique name, canEdit, safe state).
        var preflight = await engine.preflightPlaylist(named: playlistName, manifest: manifest)
        if case .stop(.playlistNotFound) = preflight, missingPlaylistPolicy == .create {
            // Creation is legal ONLY here: discovery paginated every page
            // and matched zero, proving the name uniquely absent (§20).
            // The 201 acknowledgment is never trusted — the full preflight
            // re-runs so the playlist is re-discovered, uniqueness- and
            // canEdit-checked, and classified by fresh reads.
            let created: (playlist: AMLibraryPlaylist?, httpStatus: Int)
            do {
                created = try await engine.createPlaylist(named: playlistName)
            } catch {
                return stop(Self.asStopError(error), at: .preflight)
            }
            guard let resource = created.playlist, (200..<300).contains(created.httpStatus) else {
                return stop(.playlistCreationFailed(httpStatus: created.httpStatus), at: .preflight)
            }
            emit(.preflight, "created playlist \(resource.id) (http \(created.httpStatus)) — re-discovering to prove identity")
            // Run-69 defect: a proven 201 create may not appear in the
            // library listing for tens of seconds (iCloud eventual
            // consistency). The engine retries ONLY not-found within its
            // bounded rediscovery budget; every other stop stands.
            var rediscoveryRetries = 0
            preflight = await engine.preflightAfterCreate(named: playlistName, manifest: manifest) { attempt, max in
                rediscoveryRetries = attempt
                emit(.preflight, "created playlist not yet visible (attempt \(attempt)/\(max)) — waiting for iCloud propagation")
            }
            if rediscoveryRetries > 0 {
                emit(.preflight, "created playlist became visible after \(rediscoveryRetries) re-discovery attempt(s)")
            }
        }
        let playlist: PlaylistInfo
        let state: PlaylistState
        switch preflight {
        case .ok(let info, let s, let missing):
            playlist = info
            state = s
            emit(.preflight, "playlist \(info.id) state \(s), missing \(missing.count)",
                 preflight: preflight)
        case .stop(let error):
            return stop(error, at: .preflight)
        }
        guard playlist.canEdit else {
            return stop(.playlistNotEditable(playlistId: playlist.id), at: .preflight)
        }
        guard state.isSafeToWrite else {
            return stop(.playlistNotSafeToWrite(playlistId: playlist.id, state: state), at: .preflight)
        }

        // Phase 3: reconcile — ONE library enumeration (§12).
        let library: [Int: String]
        do {
            library = try await engine.enumerateLibrary()
        } catch {
            return stop(Self.asStopError(error), at: .reconcile)
        }
        let reconciliation = RESTEngine.reconcile(manifest: manifest, library: library)
        emit(.reconcile, "library: \(reconciliation.present.count) present, \(reconciliation.missing.count) missing",
             missingFromLibraryBeforeAdds: reconciliation.missing.map({ $0.catalogId }))

        // Phase 4: add missing recordings (§11), one request per song.
        if !reconciliation.missing.isEmpty {
            do {
                let outcomes = try await engine.addMissingToLibrary(reconciliation.missing)
                emit(.libraryAdd, "added \(outcomes.count) recordings, statuses \(outcomes.map { $0.httpStatus })",
                     libraryAddOutcomes: outcomes)
            } catch let error as AMError {
                return stop(error, at: .libraryAdd)
            } catch {
                return stop(Self.asStopError(error), at: .libraryAdd)
            }
        } else {
            emit(.libraryAdd, "nothing to add — library already complete", libraryAddOutcomes: [])
        }

        // Phase 5: fresh-read library verification (§11; §12 single-
        // enumeration rule: with no adds issued the reconcile enumeration
        // IS the fresh read; only actual adds trigger the re-read).
        let libraryVerification: LibraryVerification
        if reconciliation.missing.isEmpty {
            libraryVerification = LibraryVerification(
                verified: true, missingCatalogIds: [], attempts: 1,
                catalogToLibraryId: library)
            emit(.libraryVerify, "verified=true (no adds issued; reconcile enumeration is the fresh read) attempts=1 missing=[]")
        } else {
            libraryVerification = await engine.verifyLibrary(manifest: manifest)
            emit(.libraryVerify, "verified=\(libraryVerification.verified) attempts=\(libraryVerification.attempts) missing=\(libraryVerification.missingCatalogIds)")
        }
        guard libraryVerification.verified else {
            return stop(.librarySongMissing(catalogId: libraryVerification.missingCatalogIds.first ?? -1),
                        at: .libraryVerify, libraryVerification: libraryVerification)
        }

        // Phase 6: derive the immutable plan over the verified library.
        let plan: AppendPlan
        switch RESTEngine.deriveAppendPlan(preflight: preflight, manifest: manifest,
                                            library: libraryVerification.catalogToLibraryId) {
        case .success(let p):
            plan = p
        case .failure(let error):
            return stop(error, at: .plan, libraryVerification: libraryVerification)
        }
        emit(.plan, "\(plan.steps.count) steps")

        // Phase 7: execute exactly the plan (fresh re-preflight inside;
        // append-only; per-step fresh-read proof; stop on first failure).
        if !plan.steps.isEmpty {
            // Partial per-step evidence survives a stop (Phase 6): the
            // callback fires as each append attempt is recorded, so a
            // checkpoint can be built even when execute throws.
            var stepOutcomes: [AppendOutcome] = []
            let record: (AppendOutcome) -> Void = { stepOutcomes.append($0) }
            do {
                let outcomes = try await engine.executeAppendPlan(plan, onStep: record)
                emit(.execute, "executed \(outcomes.count) steps, statuses \(outcomes.map { $0.httpStatus })",
                     appendOutcomes: outcomes)
            } catch let error as AMError {
                return stop(error, at: .execute,
                            plan: plan, libraryVerification: libraryVerification,
                            partialAppendOutcomes: stepOutcomes)
            } catch {
                return stop(Self.asStopError(error), at: .execute,
                            plan: plan, libraryVerification: libraryVerification,
                            partialAppendOutcomes: stepOutcomes)
            }
        } else {
            emit(.execute, "no-op: playlist already exactComplete", appendOutcomes: [])
        }

        // Phase 8: independent final read-back (§16).
        let finalTracks: [AMLibrarySong]
        do {
            finalTracks = try await engine.readPlaylistTracks(playlistId: playlist.id)
        } catch {
            return stop(Self.asStopError(error), at: .finalReadback,
                        plan: plan, libraryVerification: libraryVerification)
        }
        let readback = RESTEngine.verifyPlaylist(playlistId: playlist.id,
                                                 manifest: manifest,
                                                 tracks: finalTracks,
                                                 shareUrl: playlist.shareUrl)
        emit(.finalReadback, readback.verified
             ? "verified: exact sequence, \(readback.expectedCatalogIds.count) tracks, 0 duplicates"
             : "NOT verified: orderingPass=\(readback.orderingPass) duplicates=\(readback.duplicates) unexpected=\(readback.unexpectedCatalogIds) unidentifiable=\(readback.unidentifiableTrackCount)")
        return TransactionReport(playlistName: playlistName,
                                 phases: phases, plan: plan,
                                 libraryVerification: libraryVerification,
                                 finalReadback: readback, succeeded: readback.verified)
    }
}
