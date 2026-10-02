import SwiftUI
import TunoryCore

/// Results screen: the final status with per-track errors beside affected
/// items. Every row field derives from the canonical TransactionReport
/// (TrackResultRow); this view decides nothing.
struct ResultsView: View {
    @ObservedObject var model: TransactionViewModel
    let onRestart: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let report = model.report {
                    summary(report)
                }
                if !model.divergenceNotes.isEmpty {
                    divergenceSection
                }
                if let message = model.failureMessage {
                    // Manifest-build failures point at the affected line.
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
                rows
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    private var header: some View {
        HStack {
            if let report = model.report {
                Image(systemName: report.succeeded ? "checkmark.seal.fill" : "xmark.octagon")
                    .foregroundStyle(report.succeeded ? .green : .orange)
                Text(report.succeeded ? "Playlist complete" : "Finished with problems")
                    .font(.title2.bold())
            } else {
                Image(systemName: "xmark.octagon")
                    .foregroundStyle(.orange)
                Text("Could not start")
                    .font(.title2.bold())
            }
            Spacer()
            Button("Start Over", action: onRestart)
        }
    }

    private func summary(_ report: TransactionReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // A stopped transaction surfaces its exact stop reason (§20),
            // never a bare "problems" banner.
            if let stopped = report.phases.last(where: { $0.kind == .stopped }),
               let error = stopped.error {
                Label(Self.stopExplanation(error), systemImage: "exclamationmark.octagon")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            if let readback = report.finalReadback {
                if readback.verified {
                    Text("Verified by a fresh read: \(readback.expectedCatalogIds.count) recordings, exact order, 0 duplicates.")
                        .font(.callout)
                } else {
                    Text("Final read-back did NOT verify: orderingPass=\(readback.orderingPass), duplicates=\(readback.duplicates), unexpected=\(readback.unexpectedCatalogIds), unidentifiable=\(readback.unidentifiableTrackCount).")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            if let shareUrl = report.finalReadback?.shareUrl {
                if let url = URL(string: shareUrl) {
                    Link(destination: url) {
                        Label("Open in Apple Music", systemImage: "arrow.up.right.square")
                    }
                }
            }
            Text("Playlist: \(report.playlistName)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Human-readable stop reason for the exact §20 condition (presentation
    /// only; the decision itself was made canonically).
    private static func stopExplanation(_ error: AMError) -> String {
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

    /// §10 divergence section: the catalog gate found recordings whose
    /// requested names diverge from what the catalog returns at those IDs.
    /// Identity is the catalog ID (the gate passed); these are review
    /// notes so the mismatch is never silently accepted. All text comes
    /// from EvidencePresentation — one wording, one place.
    private var divergenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Some recordings differ from their requested names", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("The catalog IDs are exact (that is the identity Tunory writes); the names below are what Apple Music returns at those IDs. Review them before relying on the playlist's names.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(model.divergenceNotes, id: \.pos) { note in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(note.pos).")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Asked for: \(note.requestedName)")
                            .font(.callout)
                        Text(EvidencePresentation.divergenceText(for: note))
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                        Text("Catalog ID \(note.catalogId)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.rows) { row in
                ResultRow(row: row)
                Divider()
            }
        }
    }
}

private struct ResultRow: View {
    let row: TrackResultRow

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(row.pos).")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(row.title) — \(row.artist)")
                    .font(.body.weight(.medium))
                Text("Catalog ID \(row.catalogId)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    if row.libraryAdded {
                        Label("Added to Library", systemImage: "music.note.list")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if row.appended {
                        Label("Appended", systemImage: "text.append")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if row.verified == true {
                        Label("Verified", systemImage: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    if let problem = row.problem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }
}
