import SwiftUI
import TunoryCore

/// Recovery screen (Phase 9): the GUI path for an interrupted transaction.
///
/// Shows what the persisted checkpoint PROVED at capture time (never what
/// it guessed), and offers exactly two explicit actions:
///   • Resume — runs the canonical RecoveryFlow: fresh reads first, a
///     fail-closed reconciliation, and only then (if reality honors the
///     proven claims) the resumed §20 transaction. No write is ever
///     attempted before the fresh reads prove the state safe.
///   • Dismiss — removes the saved progress file (Apple's state is never
///     touched) and returns to the normal flow.
///
/// This view decides nothing; every decision is RecoveryPlanner's, made
/// from fresh reads, and every displayed fact is derived from canonical
/// evidence (checkpoint + RecoveryOutcome).
struct RecoveryView: View {
    @ObservedObject var model: RecoveryViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch model.stage {
                case .idle:
                    idleState
                case .available(let checkpoint):
                    availableState(checkpoint)
                case .unreadable(let detail):
                    unreadableState(detail)
                case .running:
                    runningState
                case .finished:
                    finishedState
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    // MARK: - States

    /// No saved progress: nothing to recover. The card is invisible — this
    /// state never blocks the normal flow.
    private var idleState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No interrupted transactions")
                .font(.title2.bold())
            Text("There is no saved import progress. If an import was interrupted before its checkpoint was saved, start a new import — the transaction re-reads Apple Music state and only makes provably-safe appends.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func availableState(_ checkpoint: TransactionCheckpoint) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotatepath")
                    .foregroundStyle(.orange)
                Text("Resume interrupted import?")
                    .font(.title2.bold())
            }

            Text("A previous import into the playlist “\(checkpoint.playlistName)” was interrupted after fresh reads proved its first \(checkpoint.provenStoredPrefixCount) of \(checkpoint.manifestCatalogIds.count) recordings were stored in order. The saved progress records only what was proven — anything beyond that is uncertain and will be re-derived from Apple Music's actual state.")
                .font(.callout)

            VStack(alignment: .leading, spacing: 8) {
                Text("What was proven (at capture time)")
                    .font(.headline)
                Text("• Playlist: \(checkpoint.playlistName) (\(checkpoint.playlistId))")
                    .font(.callout.monospaced())
                Text("• Recordings proven stored, in order: \(checkpoint.provenStoredPrefixCount) of \(checkpoint.manifestCatalogIds.count)")
                    .font(.callout.monospaced())
                Text("• Catalog IDs: \(checkpoint.manifestCatalogIds.map(String.init).joined(separator: ", "))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(12)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            Text("Resuming re-reads the playlist and your Library right now. If Apple Music's state still honors the proven progress, the import continues from exactly where it was proven; if not, nothing is written and the mismatch is shown for you to resolve.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Button { Task { await model.resume() } } label: {
                    Text("Resume import")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                Button("Dismiss saved progress", role: .destructive) {
                    model.dismiss()
                }
                .disabled(model.isRunning)

                Spacer()
            }
            .padding(.top, 4)

            Text("No write is performed until the fresh reads prove the state is safe — and Resume is your explicit action.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func unreadableState(_ detail: String) -> some View {
        VStack(alignment: .leading,  spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Saved progress could not be read")
                    .font(.title2.bold())
            }
            Text("The recovery file exists but could not be decoded. Recovery information: \(detail)")
                .font(.callout)
            Text("You can dismiss it and start a fresh import — the canonical transaction re-derives everything from Apple Music's actual state, so nothing is lost except the pointer to it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Dismiss saved progress", role: .destructive) {
                model.dismiss()
            }
            .padding(.top, 4)
        }
    }

    private var runningState: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ProgressView()
                Text("Reconciling against Apple Music…")
                    .font(.title3)
            }
            Text("Fresh reads of your Library and the playlist are deciding whether the proven progress still holds. Nothing is written during this step.")
                .font(.callout)
                .foregroundStyle(.secondary)

            phaseRows
        }
    }

    private var finishedState: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let report = model.report {
                HStack {
                    Image(systemName: report.succeeded ? "checkmark.seal.fill" : "xmark.octagon")
                        .foregroundStyle(report.succeeded ? .green : .orange)
                    Text(report.succeeded
                         ? "Playlist completed and verified"
                         : "Recovery stopped")
                        .font(.title2.bold())
                }
                if report.succeeded, let readback = report.finalReadback {
                    Text("Verified by a fresh read: \(readback.expectedCatalogIds.count) recordings, exact order, 0 duplicates.")
                        .font(.callout)
                }
                if let stopped = report.phases.last(where: { $0.kind == .stopped }),
                   let error = stopped.error {
                    Label(RecoveryViewModel.explain(error),
                          systemImage: "exclamationmark.octagon")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            } else if let failure = model.recoveryFailure {
                HStack {
                    Image(systemName: "xmark.octagon")
                        .foregroundStyle(.orange)
                    Text("Recovery stopped")
                        .font(.title2.bold())
                }
                Label(failure, systemImage: "exclamationmark.octagon")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .textSelection(.enabled)
            } else {
                // alreadyComplete path: fresh reads proved the playlist
                // already matches the full manifest.
                HStack {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("Already complete")
                        .font(.title2.bold())
                }
                Text("Apple Music already has the complete playlist — the saved progress was superseded and nothing needed to be written.")
                    .font(.callout)
            }

            phaseRows
        }
    }

    private var phaseRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.phaseLog.sorted { $0.ordinal < $1.ordinal }.enumerated()),
                    id: \.element.ordinal) { _, phase in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: phase.kind == .stopped
                          ? "exclamationmark.octagon.fill"
                          : "checkmark.circle.fill")
                        .foregroundStyle(phase.kind == .stopped ? .red : .green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(phase.report)
                            .font(.caption.monospacedDigit())
                            .textSelection(.enabled)
                    }
                    Spacer()
                }
                .padding(.vertical, 3)
            }
        }
    }
}
