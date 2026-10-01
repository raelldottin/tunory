import Foundation
import Combine
import MusicKit
import TunoryCore

/// Drives the GUI's Review → Add to Library → Create playlist transaction.
///
/// ALL financial/mutation decisions live in TunoryCore (RESTEngine +
/// TransactionRunner); this model only:
///   • builds the canonical manifest from the review state via
///     ManifestParser.build (same invariants as a parsed file),
///   • runs the ONE canonical §20 sequence,
///   • derives presentation rows from the returned evidence.
/// It never decides what to write, when to write, or whether a write
/// succeeded.
@MainActor
final class TransactionViewModel: ObservableObject {

    enum Stage: Equatable {
        case ready
        case running
        case finished
    }

    @Published private(set) var stage: Stage = .ready
    /// Phase outcomes, insertion-sorted by `ordinal` so display order is
    /// deterministic regardless of task-hop arrival order.
    @Published private(set) var phaseLog: [TransactionPhaseOutcome] = []
    @Published private(set) var report: TransactionReport?
    /// Manifest-build or pre-run failure (shown beside affected state,
    /// not as a blanket banner when a position is known).
    @Published private(set) var failureMessage: String?
    @Published private(set) var failurePosition: Int?

    var playlistName: String = ""
    var createIfMissing: Bool = true

    /// The per-track result rows for the results screen (derived from the
    /// canonical evidence: catalog-gate outcomes, library-add outcomes,
    /// append outcomes, and the final read-back — position by position).
    @Published private(set) var rows: [TrackResultRow] = []

    var isRunning: Bool { stage == .running }

    // MARK: - Entry

    /// Starts the transaction from the completed review state.
    /// `resolutions` must be fully resolved (no pending/needsReview/
    /// unresolved lines) — the view gates the button; the model still
    /// fail-closes via ManifestParser.build on any gap.
    func start(resolutions: [LineResolution]) async {
        guard stage != .running else { return }
        guard MusicAuthorization.currentStatus == .authorized else {
            failureMessage = "Apple Music access is required. Enable it on the Status screen first."
            failurePosition = nil
            stage = .finished
            return
        }
        let name = playlistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            failureMessage = "Enter a playlist name."
            failurePosition = nil
            stage = .finished
            return
        }

        // Canonical manifest: positions 1...N in review order; identity
        // ONLY from confirmed resolutions; file-grade validation.
        let manifest: ParsedManifest
        do {
            manifest = try ManifestParser.build(
                lineCount: resolutions.count,
                catalogIdForLine: { pos in
                    resolutions.first(where: { $0.pos == pos })?.resolvedSong?.catalogId
                },
                nameForLine: { pos in
                    resolutions.first(where: { $0.pos == pos })?.resolvedSong?.title
                        ?? resolutions.first(where: { $0.pos == pos })?.rawTitle
                        ?? ""
                },
                artistForLine: { pos in
                    resolutions.first(where: { $0.pos == pos })?.resolvedSong?.artistName ?? ""
                })
        } catch {
            (failureMessage, failurePosition) = Self.describeBuildFailure(error)
            stage = .finished
            return
        }

        stage = .running
        phaseLog = []
        report = nil
        rows = []
        failureMessage = nil
        failurePosition = nil

        let engine = RESTEngine(transport: MusicDataRequestTransport())
        let runner = TransactionRunner(engine: engine)
        let outcome = await runner.run(manifest: manifest,
                                       playlistName: name,
                                       missingPlaylistPolicy: createIfMissing ? .create : .stop) { [weak self] phase in
            // Hop to the UI actor; ordinal insertion keeps order
            // deterministic even if hops were delivered out of order.
            Task { @MainActor in
                self?.insert(phase)
            }
        }
        report = outcome
        rows = Self.deriveRows(resolutions: resolutions, report: outcome)
        stage = .finished
    }

    func reset() {
        stage = .ready
        phaseLog = []
        report = nil
        rows = []
        failureMessage = nil
        failurePosition = nil
    }

    // MARK: - Derived presentation (pure)

    private func insert(_ phase: TransactionPhaseOutcome) {
        if let index = phaseLog.firstIndex(where: { $0.ordinal > phase.ordinal }) {
            phaseLog.insert(phase, at: index)
        } else {
            phaseLog.append(phase)
        }
    }

    /// One row per reviewed recording: everything the results screen shows
    /// comes from the canonical evidence, keyed by manifest position.
    static func deriveRows(resolutions: [LineResolution],
                           report: TransactionReport) -> [TrackResultRow] {
        // Index canonical per-recording evidence by position.
        var addByPos: [Int: LibraryAddOutcome] = [:]
        var appendByPos: [Int: AppendOutcome] = [:]
        for phase in report.phases {
            for add in phase.libraryAddOutcomes ?? [] {
                addByPos[add.pos] = add
            }
            for append in phase.appendOutcomes ?? [] {
                appendByPos[append.pos] = append
            }
        }

        var stoppedError: AMError?
        if let stopped = report.phases.last, stopped.kind == .stopped {
            stoppedError = stopped.error
        }

        return resolutions.sorted { $0.pos < $1.pos }.map { line in
            let catalogId = line.resolvedSong?.catalogId ?? 0
            var problem: String?

            if let add = addByPos[line.pos], !add.ok {
                problem = "Add to Library failed (HTTP \(add.httpStatus))."
            } else if let append = appendByPos[line.pos], !append.ok {
                problem = "Playlist append failed (HTTP \(append.httpStatus))."
            } else if let error = stoppedError {
                problem = Self.positionProblem(error, pos: line.pos, catalogId: catalogId)
            }
            // Final read-back verdict when the transaction reached it.
            if let readback = report.finalReadback,
               readback.expectedCatalogIds.indices.contains(line.pos - 1) {
                let actual = readback.actualCatalogIds[line.pos - 1]
                let expected = readback.expectedCatalogIds[line.pos - 1]
                if actual != expected {
                    if problem == nil {
                        problem = actual == nil
                            ? "Position \(line.pos) stores an unidentifiable track."
                            : "Position \(line.pos) stores catalog ID \(actual!), expected \(expected)."
                    }
                }
            }

            return TrackResultRow(
                pos: line.pos,
                title: line.resolvedSong?.title ?? line.rawTitle,
                artist: line.resolvedSong?.artistName ?? "",
                catalogId: catalogId,
                libraryAdded: addByPos[line.pos] != nil,
                appended: appendByPos[line.pos] != nil,
                verified: report.finalReadback.map { readback in
                    readback.actualCatalogIds.indices.contains(line.pos - 1)
                        && readback.actualCatalogIds[line.pos - 1] == catalogId
                        && readback.verified
                },
                problem: problem)
        }
    }

    /// Maps a canonical stop error onto the affected position where the
    /// error carries one; nil means "not about this line".
    private static func positionProblem(_ error: AMError, pos: Int, catalogId: Int) -> String? {
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

    private static func describeBuildFailure(_ error: Error) -> (String, Int?) {
        guard let manifestError = error as? ManifestError else {
            return (error.localizedDescription, nil)
        }
        switch manifestError {
        case .emptyManifest: return ("No recordings to import.", nil)
        case .unresolvedLine(let pos): return ("This recording was never confirmed — resolve or remove it first.", pos)
        case .invalidCatalogId(let pos): return ("Invalid catalog ID.", pos)
        case .duplicateCatalogId(let id, let positions):
            return ("Catalog ID \(id) appears at positions \(positions.map(String.init).joined(separator: ", ")) — each recording must be unique.", positions.first)
        case .blankName(let pos): return ("Missing title.", pos)
        case .blankArtist(let pos): return ("Missing artist.", pos)
        case .nonSequentialPositions(let found, _):
            return ("Line order broken (found \(found)).", found.first)
        case .invalidDuration(let pos): return ("Invalid duration.", pos)
        case .invalidURL(let pos): return ("Invalid Apple Music URL.", pos)
        case .malformedJSON(let detail): return ("Internal manifest error: \(detail)", nil)
        }
    }
}

/// Presentation-only row for the results screen. Every field is derived
/// from the canonical TransactionReport; nothing here decides anything.
struct TrackResultRow: Identifiable, Equatable {
    let pos: Int
    let title: String
    let artist: String
    let catalogId: Int
    /// A library add was issued for this recording.
    let libraryAdded: Bool
    /// A playlist append was issued for this recording.
    let appended: Bool
    /// The final read-back proved this exact recording at this position.
    let verified: Bool?
    /// Human-readable problem beside the affected item (nil = clean).
    let problem: String?

    var id: Int { pos }
}
