import SwiftUI
import TunoryCore

struct TransactionProgressView: View {
    @ObservedObject var model: TransactionViewModel
    var onViewResults: (() -> Void)? = nil
    private let canonicalOrder: [TransactionPhaseOutcome.Kind] = [
        .catalogGate, .preflight, .reconcile, .libraryAdd, .libraryVerify, .plan, .execute, .finalReadback
    ]

    var body: some View {
        TunoryScreen {
            TunoryNotice(title: "Building your playlist", message: "Tunory checks fresh Apple Music evidence at each phase. Keep the app open until it finishes; an interruption may leave partial progress.", symbol: "music.note.list")
            if model.isRunning {
                ProgressView("Import in progress…").accessibilityIdentifier("transaction.running")
            } else {
                Label(model.report?.succeeded == true ? "Verified completion" : "Import stopped", systemImage: model.report?.succeeded == true ? "checkmark.seal" : "exclamationmark.triangle")
                    .font(.headline).accessibilityIdentifier("transaction.outcome")
            }
            GroupBox("Phase evidence") {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(canonicalOrder, id: \.self) { kind in
                        let evidence = model.phaseLog.first { $0.kind == kind }
                        VStack(alignment: .leading, spacing: 4) {
                            Label(label(kind), systemImage: evidence == nil ? "circle" : "doc.text.magnifyingglass")
                                .font(.headline)
                            if let evidence {
                                Text(evidence.report).font(.callout).textSelection(.enabled)
                            } else {
                                Text(model.isRunning ? "Awaiting evidence" : "No completed evidence for this phase")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }.accessibilityIdentifier("transaction.phase.\(String(describing: kind))")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let stopped = model.phaseLog.last(where: { $0.kind == .stopped }) {
                Label(stopped.report, systemImage: "exclamationmark.octagon").textSelection(.enabled)
            }
            if let message = model.failureMessage { Text(message).textSelection(.enabled) }
            if let message = model.persistenceWarning { Label(message, systemImage: "externaldrive.badge.exclamationmark") }
            if model.stage == .finished {
                Button("View Results") { onViewResults?() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("transaction.viewResults")
            }
        }
    }

    private func label(_ kind: TransactionPhaseOutcome.Kind) -> String {
        switch kind {
        case .catalogGate: return String(localized: "Verify recordings")
        case .preflight: return String(localized: "Find target playlist")
        case .reconcile: return String(localized: "Read library state")
        case .libraryAdd: return String(localized: "Add missing library recordings")
        case .libraryVerify: return String(localized: "Verify library additions")
        case .plan: return String(localized: "Build append plan")
        case .execute: return String(localized: "Append playlist in order")
        case .finalReadback: return String(localized: "Verify final playlist")
        case .stopped: return String(localized: "Stopped")
        }
    }
}
