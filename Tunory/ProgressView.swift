import SwiftUI
import TunoryCore

/// Progress screen: live phase evidence from the canonical §20 sequence
/// (Review → Add to Library → Create playlist). Displays only what the
/// TransactionRunner reports — it never computes progress itself.
/// (Named TransactionProgressView to avoid shadowing SwiftUI.ProgressView.)
struct TransactionProgressView: View {
    @ObservedObject var model: TransactionViewModel
    /// Shown when the transaction has finished (stage == .finished).
    var onViewResults: (() -> Void)? = nil

    private let canonicalOrder: [TransactionPhaseOutcome.Kind] = [
        .catalogGate, .preflight, .reconcile, .libraryAdd, .libraryVerify,
        .plan, .execute, .finalReadback
    ]

    private func label(_ kind: TransactionPhaseOutcome.Kind) -> String {
        switch kind {
        case .catalogGate: return "Verify recordings"
        case .preflight: return "Find playlist"
        case .reconcile: return "Reconcile Library"
        case .libraryAdd: return "Add to Library"
        case .libraryVerify: return "Verify Library"
        case .plan: return "Build plan"
        case .execute: return "Append to playlist"
        case .finalReadback: return "Final verification"
        case .stopped: return "Stopped"
        }
    }

    private func status(for kind: TransactionPhaseOutcome.Kind) -> (text: String, done: Bool)? {
        guard let outcome = model.phaseLog.first(where: { $0.kind == kind }) else { return nil }
        return (outcome.report, true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Building your playlist")
                .font(.title2.bold())
            Text(model.isRunning
                 ? "Running the verified sequence — no step is trusted until a fresh read proves it."
                 : "Transaction complete.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            ForEach(canonicalOrder, id: \.self) { kind in
                let state = status(for: kind)
                HStack(alignment: .top, spacing: 10) {
                    if state == nil {
                        Image(systemName: model.isRunning ? "circle" : "minus")
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label(kind))
                            .font(.body.weight(state == nil ? .regular : .semibold))
                        if let detail = state?.text {
                            Text(detail)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                }
            }

            // The stop phase renders as an explicit red row (never hidden).
            if let stopped = model.phaseLog.first(where: { $0.kind == .stopped }),
               let error = stopped.error {
                Label(stopped.report, systemImage: "exclamationmark.octagon.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if model.stage == .finished, let onViewResults {
                HStack {
                    Spacer()
                    Button("View Results", action: onViewResults)
                        .buttonStyle(.borderedProminent)
                }
                .padding(.top, 8)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
