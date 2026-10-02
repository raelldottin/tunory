import Foundation

// MARK: - Phase 9: canonical recovery orchestration (GUI + CLI)
//
// Phase 6 defined WHAT recovery decides (RecoveryPlanner: pure, fail-closed
// reconciliation of a checkpoint against freshly-read state). The Phase 6
// CLI `recover` verb then hand-rolled the sequencing around it (rebuild the
// manifest from checkpoint catalog IDs, preflight, decide, and on resume
// hand the fresh state to the canonical TransactionRunner). Phase 9 gives
// the GUI a recovery path without the CLI — and the §19/§20 lesson is that
// two hand-rolled orchestrations of the same decision sequence WILL drift.
// So the sequencing moves here, canonical in TunoryCore, and the CLI verb
// becomes a thin adapter over these same steps (byte-identical output).
//
// Every rule is unchanged from the proven Phase 6 behavior:
//   • the manifest is rebuilt ONLY from the checkpoint's catalog IDs via
//     ManifestParser.build (one canonical validated path; corrupted
//     checkpoints fail closed BEFORE any network traffic);
//   • reads are fresh (preflight + a new runner run) — the checkpoint is a
//     cross-check, never replayed;
//   • on resume the SAME canonical §20 transaction runs, re-deriving its
//     plan from reality;
//   • NO write is ever attempted before a fresh read proves the state safe
//     (the runner's own preflight enforces §13/§20).
//
// The steps are deliberately split so the CLI can interleave its streaming
// output between them exactly as it always has:
//   manifest(for:)  — canonical rebuild, throws on corruption;
//   decide(...)     — fresh preflight + pure planner decision (no writes);
//   resume(...)     — the canonical §20 transaction over fresh state;
//   run(...)        — GUI convenience: all three in order.

/// The outcome of a full recovery attempt. Every field is canonical
/// evidence; presentation derives, never decides.
public struct RecoveryOutcome: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The playlist already stores the full manifest: nothing to do.
        case alreadyComplete(playlist: PlaylistInfo)
        /// The resumed canonical transaction finished with this report.
        case resumed(report: TransactionReport)
        /// Recovery stopped for human direction (§20 fail-closed). The
        /// error is the exact stop condition.
        case stopped(AMError)
    }

    public let kind: Kind
    /// The manifest recovery ran against (rebuilt from checkpoint IDs).
    public let manifest: ParsedManifest
    /// The checkpoint recovery decided on.
    public let checkpoint: TransactionCheckpoint
    /// The decision RecoveryPlanner made from the fresh preflight.
    public let decision: RecoveryDecision

    public init(kind: Kind, manifest: ParsedManifest,
                checkpoint: TransactionCheckpoint, decision: RecoveryDecision) {
        self.kind = kind
        self.manifest = manifest
        self.checkpoint = checkpoint
        self.decision = decision
    }
}

/// The ONE canonical recovery sequence. The CLI and the GUI call this; it
/// owns the manifest rebuild, the fresh reads, the planner decision, and
/// the resumed transaction — nothing else may sequence a recovery.
public enum RecoveryFlow {

    /// Rebuilds the manifest a checkpoint was captured against, through the
    /// ONE canonical validated path (ManifestParser.build): identity from
    /// the checkpoint's catalog IDs (authoritative §10), nominal display
    /// fields — exactly what the CLI recover verb has always built. A
    /// corrupted checkpoint (empty, duplicate ids) fails closed here,
    /// before any network traffic.
    public static func manifest(for checkpoint: TransactionCheckpoint) throws -> ParsedManifest {
        try ManifestParser.build(
            lineCount: checkpoint.manifestCatalogIds.count,
            catalogIdForLine: { pos in
                pos - 1 < checkpoint.manifestCatalogIds.count
                    ? checkpoint.manifestCatalogIds[pos - 1] : nil
            },
            nameForLine: { pos in "Recording \(pos)" },
            artistForLine: { _ in "Unknown" })
    }

    /// Fresh-read decision step: preflights the checkpointed playlist name
    /// against Apple's ACTUAL state and reconciles the checkpoint with it
    /// (pure, fail-closed). Performs NO writes. The caller acts on the
    /// decision — `resume` only for `.resume`.
    public static func decide(checkpoint: TransactionCheckpoint,
                              manifest: ParsedManifest,
                              engine: RESTEngine) async -> RecoveryDecision {
        let preflight = await engine.preflightPlaylist(named: checkpoint.playlistName,
                                                       manifest: manifest)
        return RecoveryPlanner.reconcile(checkpoint: checkpoint,
                                         manifest: manifest,
                                         preflight: preflight)
    }

    /// Resume step: the canonical §20 transaction over fresh state. Only
    /// valid after `decide` returned `.resume` — the runner re-runs every
    /// gate and re-derives the plan from reality; the checkpoint's role
    /// ended at its cross-check. Never replayed, never extended.
    public static func resume(checkpoint: TransactionCheckpoint,
                              manifest: ParsedManifest,
                              engine: RESTEngine,
                              onPhase: ((TransactionPhaseOutcome) -> Void)? = nil) async -> TransactionReport {
        let runner = TransactionRunner(engine: engine)
        return await runner.run(manifest: manifest,
                                playlistName: checkpoint.playlistName,
                                onPhase: onPhase)
    }

    /// GUI convenience: the whole sequence in order (rebuild → decide →
    /// act). A checkpoint that decodes but fails canonical manifest
    /// validation surfaces as a `.stopped(.checkpointDiverged)` outcome —
    /// user-initiated recovery must never crash on a corrupt file.
    public static func run(checkpoint: TransactionCheckpoint,
                           engine: RESTEngine,
                           onPhase: ((TransactionPhaseOutcome) -> Void)? = nil) async -> RecoveryOutcome {
        // 1. Canonical manifest rebuild (fail-closed on corruption).
        let manifest: ParsedManifest
        do {
            manifest = try Self.manifest(for: checkpoint)
        } catch {
            let reason = "saved checkpoint is not a valid manifest: \(String(describing: error))"
            return RecoveryOutcome(kind: .stopped(.checkpointDiverged(reason: reason)),
                                   manifest: ParsedManifest(entries: []),
                                   checkpoint: checkpoint,
                                   decision: .stop(.checkpointDiverged(reason: reason)))
        }

        // 2. Fresh-read decision (no writes).
        let decision = await Self.decide(checkpoint: checkpoint,
                                         manifest: manifest,
                                         engine: engine)

        // 3. Act on the decision.
        switch decision {
        case .alreadyComplete(let info):
            return RecoveryOutcome(kind: .alreadyComplete(playlist: info),
                                   manifest: manifest,
                                   checkpoint: checkpoint, decision: decision)
        case .stop(let error):
            return RecoveryOutcome(kind: .stopped(error),
                                   manifest: manifest,
                                   checkpoint: checkpoint, decision: decision)
        case .resume:
            let report = await Self.resume(checkpoint: checkpoint,
                                            manifest: manifest,
                                            engine: engine,
                                            onPhase: onPhase)
            return RecoveryOutcome(
                kind: report.succeeded
                    ? .resumed(report: report)
                    : .stopped(report.phases.last(where: { $0.kind == .stopped })?.error
                               ?? .transport("resumed transaction did not verify")),
                manifest: manifest,
                checkpoint: checkpoint, decision: decision)
        }
    }
}
