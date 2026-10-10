import SwiftUI
import UniformTypeIdentifiers
import TunoryCore

struct ImportView: View {
    @ObservedObject var authModel: MusicAuthViewModel
    @ObservedObject var model: ImportViewModel
    var isWorkflowBusy = false
    var onOpenStatus: () -> Void = {}
    let onAllResolved: () -> Void
    @State private var pastedText = ""
    @State private var showOpenPanel = false
    @FocusState private var isEditingInput: Bool

    private var inputDisabled: Bool { model.isBusy || isWorkflowBusy }
    private var allResolved: Bool {
        !model.resolutions.isEmpty && model.resolutions.allSatisfy { $0.status == .resolved }
    }

    var body: some View {
        TunoryScreen {
            TunoryNotice(title: "Choose the recordings first", message: "Load a manifest or paste one recording per line. Resolution and review are read-only; no library or playlist changes happen here.", symbol: "checklist")
            if isWorkflowBusy {
                TunoryNotice(title: "Another import is running", message: "Review its progress or recovery result before starting a new import.", symbol: "hourglass")
            }
            if authModel.state != .authorized {
                TunoryNotice(title: "Apple Music access is needed", message: "You can prepare input now. Enable access on Status before resolving recordings.", symbol: "lock")
                Button("Review Apple Music Access", action: onOpenStatus)
                    .accessibilityIdentifier("import.authorization")
            }
            GroupBox("Song list") {
                VStack(alignment: .leading, spacing: 12) {
                    Button("Choose Manifest JSON…") { isEditingInput = false; showOpenPanel = true }
                        .buttonStyle(.bordered).disabled(inputDisabled)
                        .accessibilityIdentifier("import.chooseManifest")
                    Text("Or paste titles, artist — title pairs, or Apple Music song links, one per line.")
                        .font(.callout).foregroundStyle(.secondary)
                    TextEditor(text: $pastedText)
                        .focused($isEditingInput)
                        .font(.body)
                        .frame(minHeight: 140, idealHeight: 180, maxHeight: 240)
                        .accessibilityLabel("Song list")
                        .accessibilityHint("One recording per line. Titles, artist and title pairs, or Apple Music song links.")
                        .accessibilityIdentifier("import.pastedText")
                        .disabled(inputDisabled)
                        .onChange(of: pastedText) { _, _ in model.inputDidChange() }
                    Button("Parse Pasted List") {
                        isEditingInput = false
                        model.importPastedList(pastedText)
                    }
                        .buttonStyle(.bordered)
                        .disabled(inputDisabled || !PastedListParser.isActionable(pastedText))
                        .accessibilityIdentifier("import.parse")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            statusSection
            if let warning = model.sourceWarning {
                Label(warning, systemImage: "exclamationmark.triangle").textSelection(.enabled)
                    .accessibilityIdentifier("import.catalogError")
                Text("An incomplete request does not prove there is no matching recording. Check connectivity, then retry; all recording choices will be rechecked.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Retry Catalog Resolution") { Task { await model.resolve() } }
                    .buttonStyle(.bordered).disabled(inputDisabled || !model.authGranted)
                    .accessibilityIdentifier("import.retryResolution")
            }
            if model.hasInput, model.resolutions.isEmpty, !model.isBusy, model.sourceWarning == nil {
                Button("Resolve Against Apple Music") { Task { await model.resolve() } }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!model.authGranted || isWorkflowBusy)
                    .accessibilityIdentifier("import.resolve")
            }
            if !model.resolutions.isEmpty {
                GroupBox("Recording review") {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(model.resolutions, id: \.pos) { row in
                            ResolutionRow(row: row, isConfirming: model.confirmingPositions.contains(row.pos),
                                          canReview: !isWorkflowBusy && model.authGranted) { id in
                                Task { await model.confirm(pos: row.pos, candidateId: id) }
                            }
                            if row.pos != model.resolutions.last?.pos { Divider() }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                TunoryActions {
                    Button("Configure Playlist") { if model.canContinueReview && !isWorkflowBusy { onAllResolved() } }
                        .buttonStyle(.borderedProminent).disabled(!model.canContinueReview || isWorkflowBusy)
                        .accessibilityIdentifier("import.continue")
                    Button("Clear Review") { model.reset() }
                        .buttonStyle(.bordered).disabled(isWorkflowBusy || model.isBusy)
                        .accessibilityIdentifier("import.reset")
                }
                if !allResolved { Text("Confirm every recording before continuing. Unresolved lines need corrected input.").font(.callout).foregroundStyle(.secondary) }
            }
        }
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isEditingInput {
                    Button("Done") { isEditingInput = false }
                        .accessibilityIdentifier("import.dismissKeyboard")
                }
            }
        }
        #endif
        .fileImporter(isPresented: $showOpenPanel, allowedContentTypes: [.json]) { result in
            guard !inputDisabled else { return }
            switch result {
            case .success(let url): model.importManifest(from: url)
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { model.setParseError(error.localizedDescription) }
            }
        }
    }

    @ViewBuilder private var statusSection: some View {
        switch model.phase {
        case .idle:
            Text("Choose a file or parse your list to begin.").foregroundStyle(.secondary)
        case .parsed(let count):
            Label("\(count) recording(s) parsed. Ready to resolve exact identities.", systemImage: "doc.text")
        case .resolving(_, let total):
            ProgressView("Resolving \(total) recording(s)…")
                .accessibilityIdentifier("import.resolving")
            Text("Waiting for catalog evidence. Input is protected while this request is running.")
                .font(.callout).foregroundStyle(.secondary)
        case .review(let needsReview, let unresolved, let resolved):
            VStack(alignment: .leading, spacing: 8) {
                Label("\(resolved) confirmed", systemImage: "checkmark.circle")
                if needsReview > 0 { Label("\(needsReview) need your choice", systemImage: "person.crop.circle.badge.questionmark") }
                if unresolved > 0 { Label("\(unresolved) unresolved", systemImage: "exclamationmark.triangle") }
            }.accessibilityIdentifier("import.reviewSummary")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Import needs attention", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(message).textSelection(.enabled)
                Text("Correct the input or access issue and try again. No Apple Music writes have occurred.")
                    .font(.callout).foregroundStyle(.secondary)
            }.accessibilityIdentifier("import.error")
        }
    }
}

struct ResolutionRow: View {
    let row: LineResolution
    var isConfirming = false
    var canReview = true
    let onPick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(row.pos). \(row.rawTitle)").font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            switch row.status {
            case .resolved:
                if let song = row.resolvedSong {
                    Label("Confirmed recording", systemImage: "checkmark.circle")
                    Text("\(song.title) — \(song.artistName)")
                    if let album = song.albumTitle { Text(album).font(.callout).foregroundStyle(.secondary) }
                    Text("Catalog ID \(song.catalogId)").font(.caption.monospacedDigit()).textSelection(.enabled)
                }
            case .needsReview:
                Label("Choose the exact recording", systemImage: "person.crop.circle.badge.questionmark")
                if isConfirming { ProgressView("Verifying your choice…") }
                ForEach(row.candidates ?? []) { candidate in
                    Button { onPick(candidate.catalogId) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(candidate.title).font(.body)
                            Text(candidate.artistName).font(.callout)
                            if let album = candidate.albumTitle { Text(album).font(.callout).foregroundStyle(.secondary) }
                            if let duration = candidate.durationMilliseconds {
                                Text("Duration: \(duration / 1000) seconds").font(.caption)
                            }
                            Text("Catalog ID \(candidate.catalogId)").font(.caption.monospacedDigit())
                        }.frame(maxWidth: .infinity, minHeight: TunoryTheme.minimumControlHeight, alignment: .leading)
                        .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.bordered).disabled(isConfirming || !canReview)
                    .accessibilityLabel("Use \(candidate.title) by \(candidate.artistName), catalog ID \(candidate.catalogId)")
                    .accessibilityIdentifier("import.candidate.\(row.pos).\(candidate.catalogId)")
                }
            case .unresolved:
                Label("No confirmed catalog match", systemImage: "exclamationmark.triangle")
                Text("Correct the song title and artist, or use an Apple Music song link, then parse again.")
                    .font(.callout).foregroundStyle(.secondary)
            case .pending:
                Label("Waiting for resolution", systemImage: "hourglass")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("import.recording.\(row.pos)")
    }
}
