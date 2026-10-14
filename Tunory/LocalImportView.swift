import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TunoryCore

/// Local-file import flow: Select → Analyze → Review (duplicates) →
/// Convert → Results. Every decision shown is derived by the canonical
/// LocalImportEngine; this view presents and collects explicit user
/// confirmation (owner rule: ambiguous duplicates are never auto-resolved).
///
/// The Music.app import step is intentionally not wired to any live
/// library write (no Automation entitlement; live writes need explicit
/// operator approval — t_5ed9e8d3). Results point at the output folder
/// for manual drag-import.
struct LocalImportView: View {
    @ObservedObject var model: LocalImportViewModel

    @State private var showFileImporter = false
    @State private var showConvertConfirmation = false

    var body: some View {
        TunoryScreen {
            switch model.step {
            case .select:      selectBody
            case .analyzing:  analyzingBody
            case .review:     reviewBody
            case .converting: convertingBody
            case .results:    resultsBody
            }
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [UTType.audio],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.select(files: urls) }
        }
    }

    /// Present the powerbox directory picker as a sheet (macOS App
    /// Sandbox: the user must pick the destination folder themselves).
    private func presentOutputPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where converted .m4a copies will be written"
        panel.beginSheetModal(for: NSApp.keyWindow ?? NSApp.windows.first!) { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await model.analyze(outputDirectory: url) }
        }
    }

    // MARK: - Select

    private var selectBody: some View {
        Group {
            TunoryNotice(title: "Import local audio files",
                         message: "Select audio files (FLAC, MP3, M4A, WAV, AIFF). Tunory inspects actual file content — never the filename — and converts only what Music.app cannot use directly. Original files are never modified.",
                         symbol: "folder")
            if model.selectedCount > 0 {
                GroupBox("Selected") {
                    Text("\(model.selectedCount) file(s) selected.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("local.selectedCount")
                }
            }
            TunoryActions {
                Button("Select Files…") { showFileImporter = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("local.selectFiles")
                if model.selectedCount > 0 {
                    Button("Choose Destination…") { presentOutputPicker() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("local.chooseDestination")
                    Button("Clear Selection") { model.reset() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("local.clearSelection")
                }
            }
            profilePicker
        }
    }

    // MARK: - Analyzing

    private var analyzingBody: some View {
        Group {
            ProgressView("Analyzing selected files…")
                .frame(maxWidth: .infinity, alignment: .center)
            Text("Inspecting actual audio content, codecs, and metadata for each file.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: - Review

    private var reviewBody: some View {
        Group {
            TunoryNotice(title: "Review before converting",
                         message: "Tunory classified every file from its actual content. Files with identical bytes are flagged as duplicates and need your explicit decision. Nothing is written until you confirm.",
                         symbol: "checklist")
            if let warning = model.journalWarning {
                Text(warning).font(.callout).foregroundStyle(TunoryTheme.warning)
                    .accessibilityIdentifier("local.journalWarning")
            }
            planSummaryBox
            reviewTable
            if model.pendingReviewCount > 0 {
                Text("\(model.pendingReviewCount) duplicate file(s) need your decision.")
                    .font(.callout).foregroundStyle(TunoryTheme.warning)
                    .accessibilityIdentifier("local.pendingReview")
            }
            TunoryActions {
                Button("Convert Selected…") { showConvertConfirmation = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedForProcessing.isEmpty)
                    .accessibilityIdentifier("local.convert")
                Button("Start Over") { model.reset() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("local.startOver")
            }
        }
        .confirmationDialog("Convert the selected files?",
                            isPresented: $showConvertConfirmation,
                            titleVisibility: .visible) {
            Button("Convert \(model.selectedForProcessing.count) file(s)") {
                Task { await model.convertSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Converted copies are written to the chosen destination. Original files are never modified. Existing destination files are never overwritten.")
        }
    }

    // MARK: - Converting

    private var convertingBody: some View {
        Group {
            let total = max(model.selectedForProcessing.count, 1)
            ProgressView(value: Double((model.convertingIndex ?? 0) + 1), total: Double(total)) {
                Text("Converting \((model.convertingIndex ?? 0) + 1) of \(total)…")
            }
            .accessibilityIdentifier("local.convertingProgress")
            Text("Each output is validated (decodable, correct codec, duration within 1 s) before it is promoted. Invalid outputs are discarded and reported.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: - Results

    private var resultsBody: some View {
        Group {
            let summary = model.resultsSummary
            TunoryNotice(title: "Conversion finished",
                         message: "Converted copies are ready. Drag them into Music.app to add them to your library — Tunory does not write to your Music library.",
                         symbol: "checkmark.circle")
            GroupBox("Results") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Converted: \(summary.converted)")
                    Text("Already converted (skipped): \(summary.skippedValid)")
                    Text("Passed through (no conversion needed): \(summary.passthrough)")
                    Text("Conflicts: \(summary.conflict)")
                    Text("Failed: \(summary.failed)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("local.resultsSummary")
            }
            if let outputDirectory = model.outputDirectory {
                GroupBox("Converted files location") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(outputDirectory.path)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Show in Finder") { NSWorkspace.shared.open(outputDirectory) }
                            .accessibilityIdentifier("local.showInFinder")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            outcomesBox
            TunoryActions {
                Button("Import More Files") { model.reset() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("local.importMore")
            }
        }
    }

    private var outcomesBox: some View {
        GroupBox("Per-file outcomes") {
            VStack(alignment: .leading, spacing: 4) {
                if model.outcomes.isEmpty {
                    Text("Nothing was processed.").foregroundStyle(.secondary)
                }
                ForEach(Array(model.outcomes.enumerated()), id: \.offset) { _, outcome in
                    HStack(alignment: .top) {
                        Text(statusSymbol(outcome.status))
                        VStack(alignment: .leading, spacing: 2) {
                            Text((outcome.sourcePath as NSString).lastPathComponent)
                            Text(outcome.detail ?? outcome.status.rawValue)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusSymbol(_ status: ConversionOutcome.Status) -> String {
        switch status {
        case .converted: return "✓"
        case .skippedValid: return "⏭"
        case .passthrough: return "→"
        case .conflict: return "⚠"
        case .failed: return "✗"
        }
    }

    // MARK: - Shared

    private var profilePicker: some View {
        GroupBox("Conversion profile") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Profile", selection: Binding(
                    get: { model.profile },
                    set: { model.setProfile($0) })) {
                    Text("AAC 256 kbps (reference)").tag(ConversionProfile.aac256)
                    Text("ALAC (lossless, opt-in)").tag(ConversionProfile.alac)
                }
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier("local.profile")
                Text("AAC 256 kbps is the owner's reference profile. ALAC is lossless but only accepts lossless sources; lossy files are never transcoded lossy→lossy.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var planSummaryBox: some View {
        GroupBox("Plan summary") {
            let counts = decisionCounts
            VStack(alignment: .leading, spacing: 8) {
                Text("Convert: \(counts.convert) · Pass through: \(counts.passthrough) · Already done: \(counts.skipValid)")
                Text("Blocked (destination conflict): \(counts.conflict) · Unsupported/corrupt: \(counts.undecodable) · Profile-blocked: \(counts.blockedByProfile)")
                Text("Duplicates flagged for review: \(counts.duplicates)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("local.planSummary")
        }
    }

    private var decisionCounts: (convert: Int, passthrough: Int, skipValid: Int,
                                 conflict: Int, undecodable: Int, blockedByProfile: Int,
                                 duplicates: Int) {
        var convert = 0, passthrough = 0, skipValid = 0, conflict = 0
        var undecodable = 0, blocked = 0, duplicates = 0
        for row in model.rows {
            switch row.decision {
            case .convert: convert &+= 1
            case .passthroughNative: passthrough &+= 1
            case .skipValidOutput: skipValid &+= 1
            case .conflictDestinationValidForeign, .conflictDestinationInvalidForeign: conflict &+= 1
            case .undecodableSource: undecodable &+= 1
            case .blockedByProfile: blocked &+= 1
            }
            if row.requiresReview { duplicates &+= 1 }
        }
        return (convert, passthrough, skipValid, conflict, undecodable, blocked, duplicates)
    }

    private var reviewTable: some View {
        GroupBox("Files") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.rows) { row in
                    ReviewRow(row: row,
                              priorName: priorName(for: row)) { include in
                        model.decide(rowID: row.id, include: include)
                    }
                    Divider()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func priorName(for row: LocalImportViewModel.Row) -> String? {
        guard let prior = row.planEntry.duplicateOfIndex,
              model.rows.indices.contains(prior) else { return nil }
        return model.rows[prior].relativePath
    }
}

/// One review row: file name, probed source codec, decision, and — for
/// duplicates — explicit include/skip controls.
private struct ReviewRow: View {
    let row: LocalImportViewModel.Row
    let priorName: String?
    let decide: (_ include: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.relativePath)
                    .fontWeight(row.requiresReview ? .semibold : .regular)
                Spacer()
                if let codec = row.probe.codec {
                    Text(codec)
                        .font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Text(row.summary)
                    .font(.callout).foregroundStyle(color)
            }
            if let detail = row.probe.failureDetail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            if row.requiresReview {
                if let priorName {
                    Text("Identical bytes as “\(priorName)” — choose whether to also convert this copy.")
                        .font(.caption).foregroundStyle(TunoryTheme.warning)
                }
                HStack {
                    Toggle("Include", isOn: Binding(
                        get: { row.reviewDecision == .include },
                        set: { decide($0) }))
                        .toggleStyle(.button)
                        .accessibilityIdentifier("local.review.include.\(row.id)")
                    if row.reviewDecision != .notReviewed {
                        Text(row.reviewDecision == .include ? "will convert" : "will skip")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var color: Color {
        switch row.decision {
        case .convert: return .primary
        case .passthroughNative, .skipValidOutput: return TunoryTheme.success
        case .conflictDestinationValidForeign, .conflictDestinationInvalidForeign: return TunoryTheme.warning
        case .undecodableSource, .blockedByProfile: return TunoryTheme.failure
        }
    }
}
