import Foundation

// MARK: - Interrupted-import recovery (Phase 6)
//
// The task: "Persist credential-free checkpoints. Reconcile against Apple's
// actual state on restart. If write outcome uncertain, read Library/playlist
// before attempting another write."
//
// §20 discipline applied to recovery:
//  - A checkpoint records only what a FRESH READ proved at the moment it was
//    captured — never an issued-but-unverified write. A 202/204 is an
//    acknowledgment (§11/§14); only the subsequent read-back turns it into a
//    checkpoint claim.
//  - Recovery NEVER replays the checkpoint's plan. It re-derives everything
//    from Apple's actual current state (fresh preflight + fresh library
//    enumeration) and only uses the checkpoint as a cross-check. If reality
//    does not honor every proven claim, recovery stops for human direction
//    (fail-closed), exactly like every other §20 stop condition.
//  - The checkpoint is credential-free by construction: playlist identity,
//    manifest catalog IDs, and the count of tracks proven stored. No
//    tokens, no library-song-id secrets beyond opaque IDs Apple already
//    returns to any read, no signing state.

/// Credential-free, Codable record of what a fresh read PROVED about an
/// interrupted transaction. Codable so the CLI/GUI can persist it; Equatable
/// for tests. `capturedAtMillisSinceEpoch` is recorded for audit ordering
/// only — recovery never branches on wall-clock time (deterministic).
public struct TransactionCheckpoint: Equatable, Codable, Sendable {
    public let playlistId: String
    public let playlistName: String
    /// The manifest sequence the interrupted transaction targeted.
    public let manifestCatalogIds: [Int]
    /// How many leading manifest tracks a fresh read PROVED stored, in
    /// order, when the checkpoint was captured. Proven means observed by
    /// classifyPlaylist as empty/correctPrefix/exactComplete at that moment.
    public let provenStoredPrefixCount: Int
    /// The catalog IDs the library was PROVEN to contain at capture time
    /// (from a verified library enumeration). Recovery may rely on these
    /// only after its own fresh enumeration re-proves them.
    public let provenLibraryCatalogIds: [Int]
    public let capturedAtMillisSinceEpoch: Int64

    public init(playlistId: String, playlistName: String,
                manifestCatalogIds: [Int],
                provenStoredPrefixCount: Int,
                provenLibraryCatalogIds: [Int],
                capturedAtMillisSinceEpoch: Int64) {
        self.playlistId = playlistId
        self.playlistName = playlistName
        self.manifestCatalogIds = manifestCatalogIds
        self.provenStoredPrefixCount = provenStoredPrefixCount
        self.provenLibraryCatalogIds = provenLibraryCatalogIds
        self.capturedAtMillisSinceEpoch = capturedAtMillisSinceEpoch
    }
}

/// What to do after reconciling a persisted checkpoint against Apple's
/// actual state on restart.
public enum RecoveryDecision: Equatable, Sendable {
    /// The playlist currently stores `storedCatalogIds` (fresh read) and
    /// the next append would target manifest suffix position
    /// `resumeFromPosition`. Recovery may proceed by re-deriving a plan —
    /// NOT by replaying the old one.
    case resume(playlist: PlaylistInfo, storedCatalogIds: [Int],
                resumeFromPosition: Int)
    /// Apple's state already matches the full manifest: nothing to do.
    case alreadyComplete(playlist: PlaylistInfo)
    /// Reality diverged from the checkpoint's proven claims (or the
    /// playlist is unsafe). Human direction required; no writes.
    case stop(AMError)
}

/// Deterministic, pure reconciliation of a persisted checkpoint against the
/// server's freshly-read state. The caller supplies fresh evidence (reads);
/// this type decides. No wall-clock or network branching — fully testable.
public enum RecoveryPlanner {

    /// Cross-checks the checkpoint against a fresh preflight.
    ///
    /// Fail-closed rules:
    ///  1. The discovered playlist must be the SAME playlist the checkpoint
    ///     recorded (id AND name) — a deleted/recreated playlist with the
    ///     same name has unknown history and must not be written.
    ///  2. The manifest must be identical to the checkpoint's. A changed
    ///     order/set means the persisted prefix claim no longer means what
    ///     it meant; the old transaction is dead, not resumable.
    ///  3. The fresh playlist classification must be a safe state (§13).
    ///  4. The fresh stored prefix must be AT LEAST the proven prefix —
    ///     tracks that a fresh read once proved stored must still be
    ///     present, else the write outcome became uncertain and recovery
    ///     must read (this IS the read; diverged state stops).
    ///
    /// On pass: resume re-derives its plan from the FRESH state alone, so a
    /// resume is exactly as safe as a first run (§19 idempotency).
    public static func reconcile(checkpoint: TransactionCheckpoint,
                                 manifest: ParsedManifest,
                                 preflight: PlaylistPreflightResult) -> RecoveryDecision {
        // Rule 2: manifest identity.
        let expectedIds = manifest.entries.map(\.catalogId)
        guard expectedIds == checkpoint.manifestCatalogIds else {
            return .stop(.checkpointDiverged(
                reason: "manifest changed since the checkpoint was captured"))
        }

        // Rule 1 + 3: fresh discovery/classification.
        guard case .ok(let info, let state, _) = preflight else {
            if case .stop(let error) = preflight { return .stop(error) }
            return .stop(.playlistNotFound(name: checkpoint.playlistName))
        }
        guard info.id == checkpoint.playlistId, info.name == checkpoint.playlistName else {
            return .stop(.checkpointDiverged(
                reason: "playlist \(info.id) is not the checkpointed playlist \(checkpoint.playlistId)"))
        }
        guard state.isSafeToWrite else {
            return .stop(.playlistNotSafeToWrite(playlistId: info.id, state: state))
        }

        // Rule 4: the proven prefix must survive in the fresh state.
        let freshPrefix: Int
        switch state {
        case .empty: freshPrefix = 0
        case .correctPrefix(let count): freshPrefix = count
        case .exactComplete: freshPrefix = expectedIds.count
        default: return .stop(.playlistNotSafeToWrite(playlistId: info.id, state: state))
        }
        guard freshPrefix >= checkpoint.provenStoredPrefixCount else {
            return .stop(.checkpointDiverged(
                reason: "checkpoint proved \(checkpoint.provenStoredPrefixCount) stored tracks but a fresh read shows only \(freshPrefix)"))
        }

        let stored = Array(expectedIds.prefix(freshPrefix))
        if freshPrefix == expectedIds.count {
            return .alreadyComplete(playlist: info)
        }
        return .resume(playlist: info, storedCatalogIds: stored,
                      resumeFromPosition: freshPrefix + 1)
    }

    /// Builds a checkpoint from an interrupted phase-7 execute. §14's
    /// write discipline (append one step → prove by fresh read → only then
    /// issue the next write) makes the proven-count rule uniform: the step
    /// the stop names — or, for a transport stop, the last recorded step —
    /// is the FIRST UNPROVEN step, and every earlier step was proven by its
    /// own fresh read.
    ///
    /// `appendOutcomes` are the recorded outcomes in order;
    /// `provenStoredCountBeforeExecute` is the safe-prefix count the
    /// execute-phase preflight observed before the first write (the plan's
    /// firstPos - 1, which executeAppendPlan's drift check enforces).
    public static func checkpointAfterInterruptedExecute(
        plan: AppendPlan,
        appendOutcomes: [AppendOutcome],
        stoppedBy: AMError?,
        provenStoredCountBeforeExecute: Int,
        provenLibraryCatalogIds: [Int],
        capturedAtMillisSinceEpoch: Int64) -> TransactionCheckpoint {

        // Stopped runs: the last recorded outcome is never proven —
        //   • playlistAppendFailed: it failed its own write;
        //   • playlistVerificationFailed: its fresh read never confirmed;
        //   • any other stop (transport/cancellation): it may have fired
        //     after the write was recorded but before/during its verifying
        //     read, so its outcome is uncertain.
        // An empty outcome list (stop before any write) proves nothing.
        // A run with no stop completed the loop: every recorded step was
        // verified before the loop advanced past it.
        let provenSteps = stoppedBy == nil
            ? appendOutcomes.count
            : max(0, appendOutcomes.count - 1)

        return TransactionCheckpoint(
            playlistId: plan.playlistId,
            playlistName: plan.playlistName,
            manifestCatalogIds: plan.manifestCatalogIds,
            provenStoredPrefixCount: provenStoredCountBeforeExecute + provenSteps,
            provenLibraryCatalogIds: provenLibraryCatalogIds,
            capturedAtMillisSinceEpoch: capturedAtMillisSinceEpoch)
    }
}
