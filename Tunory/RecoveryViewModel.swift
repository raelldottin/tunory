import Foundation
import Combine
import MusicKit
import TunoryCore

/// Drives the GUI's interrupted-transaction recovery: load the persisted
/// checkpoint (if any) → show the user what was interrupted → on explicit
/// action, run the canonical RecoveryFlow (fresh reads, fail-closed
/// reconciliation, resumed §20 transaction).
///
/// ALL decisions live in TunoryCore (RecoveryPlanner + RecoveryFlow +
/// TransactionRunner). This model only:
///   • loads/saves/clears the persisted checkpoint slot via CheckpointStore;
///   • turns RecoveryOutcome into presentation state;
///   • never issues any write before the user's explicit Resume action,
///     and even then the write only happens after RecoveryFlow's own fresh
///     reads prove the state safe (§13/§20 enforced in the core).
@MainActor
final class RecoveryViewModel: ObservableObject {

    /// Which recovery state the screen is in. Every state is explicit —
    /// no state is silently skipped, including "found but unreadable".
    enum Stage: Equatable {
        /// No persisted checkpoint (or it was dismissed): nothing to do.
        case idle
        /// A checkpoint exists on disk; the user must decide explicitly.
        case available(checkpoint: TransactionCheckpoint)
        /// The saved progress could not be decoded — surfaced, not hidden.
        case unreadable(String)
        /// Fresh reads are running / the resumed transaction is running.
        case running
        /// The resumed transaction finished (success or stop) — evidence
        /// is in `report`; `isResumedSuccess` distinguishes the two.
        case finished
    }

    /// Exactly what the user is being asked to act on (from the fresh
    /// evidence, never guessed): resumed progress display state.
    @Published private(set) var stage: Stage = .idle
    @Published private(set) var persistenceWarning: String?
    @Published private(set) var alreadyComplete = false
    @Published private(set) var phaseLog: [TransactionPhaseOutcome] = []
    @Published private(set) var report: TransactionReport?
    @Published private(set) var recoveryFailure: String?
    @Published private(set) var rows: [TrackResultRow] = []

    private let store: CheckpointStore
    /// Closure the view model uses to construct a live engine; injectable
    /// so previews/tests can drive a scripted transport.
    private let makeEngine: () -> RESTEngine
    private let authorizationStatus: () -> MusicAuthorization.Status
    private var runID = UUID()

    var isRunning: Bool { stage == .running }

    /// True when the persisted checkpoint slot holds something the user
    /// should decide on (available OR unreadable). Drives the launch-time
    /// banner; read-only.
    var hasPending: Bool {
        switch stage {
        case .available, .unreadable: return true
        case .idle, .running, .finished: return false
        }
    }

    init(store: CheckpointStore = CheckpointStore(directory: CheckpointStore.defaultDirectory()),
         authorizationStatus: @escaping () -> MusicAuthorization.Status = { MusicAuthorization.currentStatus },
         makeEngine: @escaping () -> RESTEngine = { RESTEngine(transport: MusicDataRequestTransport()) }) {
        self.store = store
        self.makeEngine = makeEngine
        self.authorizationStatus = authorizationStatus
    }

    /// Loads the persisted checkpoint slot at launch (or after any change).
    /// Read-only: touches nothing but the app's own checkpoint file.
    func loadPersisted() {
        guard !isRunning else { return }
        reset()
        switch store.load() {
        case .none:
            stage = .idle
        case .unreadable(let detail):
            stage = .unreadable(detail)
        case .checkpoint(let checkpoint):
            stage = .available(checkpoint: checkpoint)
        }
    }

    /// The user explicitly dismissed recovery: remove the persisted
    /// checkpoint (their call — Apple's state is untouched) and return to
    /// the normal flow.
    func dismiss() {
        guard !isRunning else { return }
        do {
            try store.clearReportingFailure()
            reset()
        } catch {
            persistenceWarning = String(localized: "Saved progress could not be dismissed: \(error.localizedDescription). The checkpoint is retained.")
        }
    }

    /// Starts the canonical recovery: fresh reads, fail-closed decision,
    /// resumed transaction — NO write before the fresh reads prove safe.
    /// The user pressed Resume; the core still owns every write decision.
    func resume() async {
        guard case .available(let checkpoint) = stage else { return }
        guard authorizationStatus() == .authorized else {
            recoveryFailure = "Apple Music access is required. Enable it on the Status screen first."
            stage = .finished
            return
        }
        stage = .running
        let id = UUID()
        runID = id
        alreadyComplete = false
        persistenceWarning = nil
        phaseLog = []
        report = nil
        recoveryFailure = nil
        rows = []

        let outcome = await RecoveryFlow.run(checkpoint: checkpoint,
                                             engine: makeEngine()) { [weak self] phase in
            Task { @MainActor in
                guard let self, self.runID == id, self.isRunning else { return }
                self.insert(phase)
            }
        }

        switch outcome.kind {
        case .alreadyComplete:
            // Fresh reads proved the playlist already matches the full
            // manifest: nothing to write, nothing to resume. Clear the
            // slot (superseded by reality) and say so.
            alreadyComplete = true
            clearSuperseded(checkpoint: checkpoint)
            recoveryFailure = nil
            report = nil
            stage = .finished
        case .resumed(let report):
            self.report = report
            phaseLog = report.phases.sorted { $0.ordinal < $1.ordinal }
            rows = Self.deriveRows(manifest: outcome.manifest, report: report)
            // The resumed run targeted the checkpoint's transaction: clear
            // the slot only when that exact transaction verified.
            if report.succeeded {
                clearSuperseded(checkpoint: checkpoint)
            } else if let updated = TransactionRunner.checkpoint(
                forInterruptedExecuteIn: report,
                capturedAtMillisSinceEpoch: Int64(Date().timeIntervalSince1970 * 1000)) {
                do {
                    try store.save(updated)
                } catch {
                    persistenceWarning = String(localized: "New recovery progress could not be saved: \(error.localizedDescription). The earlier checkpoint is retained; fresh reads are still required.")
                }
            }
            stage = .finished
        case .stopped(let error):
            recoveryFailure = Self.explain(error)
            report = nil
            rows = []
            stage = .finished
        }
    }

    func reset() {
        guard !isRunning else { return }
        runID = UUID()
        alreadyComplete = false
        persistenceWarning = nil
        stage = .idle
        phaseLog = []
        report = nil
        recoveryFailure = nil
        rows = []
    }

    // MARK: - Derived presentation (pure)

    private func clearSuperseded(checkpoint: TransactionCheckpoint) {
        let cleared = store.clearIfSuperseded(bySuccessWith: checkpoint.playlistId,
                                             manifestCatalogIds: checkpoint.manifestCatalogIds)
        if !cleared, store.load() != .none {
            persistenceWarning = String(localized: "The playlist is verified, but saved progress remains on disk. Review it before dismissing it.")
        }
    }

    private func insert(_ phase: TransactionPhaseOutcome) {
        guard !phaseLog.contains(where: { $0.ordinal == phase.ordinal }) else { return }
        if let index = phaseLog.firstIndex(where: { $0.ordinal > phase.ordinal }) {
            phaseLog.insert(phase, at: index)
        } else {
            phaseLog.append(phase)
        }
    }

    /// Rows for the resumed run: identity from the checkpoint-rebuilt
    /// manifest (catalog IDs only — the checkpoint carries no titles), so
    /// the results screen stays per-recording without guessing names.
    static func deriveRows(manifest: ParsedManifest,
                           report: TransactionReport) -> [TrackResultRow] {
        var addByPos: [Int: LibraryAddOutcome] = [:]
        var appendByPos: [Int: AppendOutcome] = [:]
        for phase in report.phases {
            for add in phase.libraryAddOutcomes ?? [] { addByPos[add.pos] = add }
            for append in phase.appendOutcomes ?? [] { appendByPos[append.pos] = append }
        }

        return manifest.entries.map { entry in
            TrackResultRow(
                pos: entry.pos,
                title: entry.name,
                artist: entry.artist,
                catalogId: entry.catalogId,
                libraryAdded: addByPos[entry.pos]?.ok == true,
                appended: appendByPos[entry.pos]?.ok == true,
                verified: report.finalReadback.map { readback in
                    readback.actualCatalogIds.indices.contains(entry.pos - 1)
                        && readback.actualCatalogIds[entry.pos - 1] == entry.catalogId
                        && readback.verified
                },
                problem: {
                    if let add = addByPos[entry.pos], !add.ok {
                        return "Add to Library failed (HTTP \(add.httpStatus))."
                    }
                    if let append = appendByPos[entry.pos], !append.ok {
                        return "Playlist append failed (HTTP \(append.httpStatus))."
                    }
                    return Self.positionProblem(stoppedError(in: report),
                                                pos: entry.pos, catalogId: entry.catalogId)
                }())
        }
    }

    private static func stoppedError(in report: TransactionReport) -> AMError? {
        report.phases.last(where: { $0.kind == .stopped })?.error
    }

    private static func positionProblem(_ error: AMError?, pos: Int, catalogId: Int) -> String? {
        guard let error else { return nil }
        switch error {
        case .catalogLookupFailed(let id, let status):
            return id == catalogId ? "Catalog lookup failed (HTTP \(status))." : nil
        case .libraryAddFailed(let id, let status):
            return id == catalogId ? "Add to Library failed (HTTP \(status))." : nil
        case .librarySongMissing(let id):
            return id == catalogId ? "Could not prove this recording is in your Library." : nil
        case .playlistAppendFailed(let p, _, _, _):
            return p == pos ? "Playlist append failed at this position." : nil
        default:
            return nil
        }
    }

    /// Human-readable stop explanation, matching ResultsView's wording
    /// (single wording source is out of scope here; this covers recovery-
    /// specific presentation).
    static func explain(_ error: AMError) -> String {
        switch error {
        case .transport(let message): return "Network or transport failure: \(message)"
        case .notAuthorized: return "Apple Music access was lost."
        case .catalogLookupFailed(let id, let status):
            return "A recording (catalog ID \(id)) could not be found in the Apple Music catalog (HTTP \(status))."
        case .libraryAddFailed(let id, let status):
            return "Adding catalog ID \(id) to your Library failed (HTTP \(status))."
        case .playlistCreationFailed(let status):
            return "Creating the playlist failed (HTTP \(status))."
        case .playlistAppendFailed(let pos, let id, _, let status):
            return "Appending position \(pos) (catalog ID \(id)) failed (HTTP \(status))."
        case .playlistNotFound(let name):
            return "No playlist named “\(name)” exists (creation was disabled)."
        case .playlistAmbiguous(let name, let count):
            return "\(count) playlists are named “\(name)” — the target must be unique. Rename one and retry."
        case .playlistNotEditable(let id):
            return "Playlist \(id) is not editable."
        case .playlistNotSafeToWrite(_, let state):
            return "The playlist is in an unsafe state (\(state)) — it was not modified. Resolve it manually and retry."
        case .librarySongMissing(let id):
            return "Catalog ID \(id) could not be proven present in your Library."
        case .playlistVerificationFailed(let reason):
            return "Verification failed: \(reason)"
        case .paginationAborted(let pages):
            return "Library pagination aborted after \(pages) pages."
        case .malformedResponse(let message):
            return "Unexpected Apple Music response: \(message)"
        case .checkpointDiverged(let reason):
            return "The saved progress no longer matches Apple Music (\(reason)). Resolve the playlist manually, then retry."
        }
    }
}
