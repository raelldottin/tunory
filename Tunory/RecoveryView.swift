import SwiftUI
import TunoryCore

struct RecoveryView: View {
    @ObservedObject var model: RecoveryViewModel
    var canResume = true
    var onResume: (() -> Void)? = nil
    var onOpenStatus: () -> Void = {}
    @State private var showDismissConfirmation = false

    var body: some View {
        TunoryScreen {
            switch model.stage {
            case .idle:
                TunoryNotice(title: "No saved import progress", message: "If an import is interrupted after safe progress is recorded, its checkpoint appears here. Opening this screen does not contact or change Apple Music.", symbol: "checkmark.circle")
            case .available(let checkpoint): availableState(checkpoint)
            case .unreadable(let detail):
                TunoryNotice(title: "Saved progress could not be read", message: "The checkpoint exists but cannot be decoded. Dismissing it removes only Tunory's recovery pointer, not any tracks or playlists.", symbol: "exclamationmark.triangle")
                Text(detail).font(.callout).textSelection(.enabled)
                dismissButton
            case .running:
                ProgressView("Checking and continuing saved progress…")
                    .accessibilityIdentifier("recovery.running")
                Text("Tunory re-reads the saved proof before continuing. Safe reconciliation may lead to resumed library or playlist writes; completed phase evidence appears below.")
                    .foregroundStyle(.secondary)
                phaseRows
            case .finished:
                finishedState
                phaseRows
                if (model.report?.succeeded != true && !model.alreadyComplete) || model.persistenceWarning != nil {
                    Text("Saved progress is retained. Correct the access or playlist issue before trying again.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Review Saved Progress Again") { model.loadPersisted() }
                        .buttonStyle(.bordered).accessibilityIdentifier("recovery.retry")
                }
            }
            if let warning = model.persistenceWarning {
                Label(warning, systemImage: "externaldrive.badge.exclamationmark").textSelection(.enabled)
            }
        }
        .confirmationDialog("Dismiss saved import progress?", isPresented: $showDismissConfirmation, titleVisibility: .visible) {
            Button("Dismiss Saved Progress", role: .destructive) { model.dismiss() }
            Button("Keep Saved Progress", role: .cancel) {}
        } message: {
            Text("This deletes only Tunory's saved checkpoint. It does not undo any library additions or playlist appends. A new import will re-read Apple Music before writing.")
        }
    }

    private var dismissButton: some View {
        Button("Dismiss Saved Progress", role: .destructive) { showDismissConfirmation = true }
            .buttonStyle(.bordered).disabled(model.isRunning)
            .accessibilityIdentifier("recovery.dismiss")
    }

    private func availableState(_ checkpoint: TransactionCheckpoint) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            TunoryNotice(title: "An import was interrupted", message: "Only the saved verified prefix is proven. Everything after it is uncertain until fresh reads establish the current Apple Music state.", symbol: "arrow.clockwise")
            GroupBox("Saved checkpoint") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(checkpoint.playlistName).font(.headline)
                    Text("Playlist ID: \(checkpoint.playlistId)").font(.caption.monospaced()).textSelection(.enabled)
                    Text("\(checkpoint.provenStoredPrefixCount) of \(checkpoint.manifestCatalogIds.count) recordings were proven stored in order at capture time.")
                    DisclosureGroup("Saved recording identities") {
                        Text(checkpoint.manifestCatalogIds.map(String.init).joined(separator: ", "))
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Resume re-reads Apple Music, compares the saved proof, and continues only if safe. If the playlist diverged, Tunory stops without writing.")
                .foregroundStyle(.secondary)
            if !canResume {
                Text("Apple Music access is required and another import must finish before resuming.")
                Button("Review Access Status", action: onOpenStatus)
                    .accessibilityIdentifier("recovery.authorization")
            }
            TunoryActions {
                Button("Resume Import") {
                    if let onResume { onResume() } else { Task { await model.resume() } }
                }
                    .buttonStyle(.borderedProminent).disabled(!canResume || model.isRunning)
                    .accessibilityIdentifier("recovery.resume")
                dismissButton
            }
        }
    }

    @ViewBuilder private var finishedState: some View {
        if let report = model.report {
            TunoryNotice(title: report.succeeded ? "Recovered playlist verified" : "Recovery stopped", message: "The evidence below comes from the recovery transaction. Partial progress is not complete until the final playlist read verifies it.", symbol: report.succeeded ? "checkmark.seal" : "exclamationmark.octagon")
            if let stopped = report.phases.last(where: { $0.kind == .stopped }), let error = stopped.error {
                Text(RecoveryViewModel.explain(error)).textSelection(.enabled)
            }
            if let readback = report.finalReadback, readback.verified {
                Text("Fresh reads verified \(readback.expectedCatalogIds.count) recordings in order with no duplicates.")
            }
            if !model.rows.isEmpty {
                GroupBox("Recording results") {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(model.rows) { row in ResultRow(row: row) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else if let failure = model.recoveryFailure {
            TunoryNotice(title: "Recovery stopped", message: "Tunory could not prove that continuing was safe. Review the reason below before retrying.", symbol: "exclamationmark.octagon")
            Text(failure).textSelection(.enabled).accessibilityIdentifier("recovery.error")
        } else if model.alreadyComplete {
            TunoryNotice(title: "Playlist already complete", message: "Fresh reads proved the entire saved recording sequence was already present. No resumed writes were needed.", symbol: "checkmark.seal")
        } else {
            TunoryNotice(title: "No completion evidence", message: "Review saved progress again before continuing. A finished request alone does not prove the playlist is complete.", symbol: "exclamationmark.triangle")
        }
    }

    private var phaseRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.phaseLog.sorted { $0.ordinal < $1.ordinal }, id: \.ordinal) { phase in
                Label(phase.report, systemImage: phase.kind == .stopped ? "exclamationmark.octagon" : "doc.text.magnifyingglass")
                    .font(.callout).textSelection(.enabled)
            }
        }
    }
}
