import SwiftUI
import UniformTypeIdentifiers
import TunoryCore

/// Import & resolution screen: JSON manifest or pasted list in, explicit
/// per-line review out. No library mutation happens here.
struct ImportView: View {
    @ObservedObject var model: ImportViewModel
    let authModel: MusicAuthViewModel
    /// Fired when the user explicitly continues with all lines resolved.
    let onAllResolved: () -> Void
    @State private var pastedText: String = ""
    @State private var showOpenPanel = false

    init(authModel: MusicAuthViewModel,
         model: ImportViewModel,
         onAllResolved: @escaping () -> Void) {
        self.authModel = authModel
        self.model = model
        self.onAllResolved = onAllResolved
    }

    private var allResolved: Bool {
        !model.resolutions.isEmpty
            && model.resolutions.allSatisfy { $0.status == .resolved }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    inputSection
                    statusSection
                    resolutionList
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .fileImporter(isPresented: $showOpenPanel,
                      allowedContentTypes: [.json],
                      onCompletion: { result in
                          switch result {
                          case .success(let url):
                              // Sandboxed read: the picked URL is only readable
                              // inside start/stopAccessingSecurityScopedResource,
                              // which importManifest(from:) performs around the
                              // single immediate read.
                              model.importManifest(from: url)
                          case .failure(let error):
                              model.setParseError(error.localizedDescription)
                          }
                      })
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("Import & Review")
                .font(.title2.bold())
            Spacer()
            if allResolved {
                Button("Continue →") { onAllResolved() }
                    .buttonStyle(.borderedProminent)
            } else if case .review = model.phase {
                Button("Start Over") { model.reset() }
            }
        }
        .padding(16)
    }

    private var inputSection: some View {
        Group {
            switch model.phase {
            case .idle, .failed, .parsed:
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("Choose Manifest JSON…") { showOpenPanel = true }
                        Text("or paste a song list below")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    TextEditor(text: $pastedText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 120)
                        .border(Color.secondary.opacity(0.3))
                    HStack {
                        Button("Parse Pasted List") {
                            model.importPastedList(pastedText)
                        }
                        .disabled(!PastedListParser.isActionable(pastedText))
                        if case .parsed(let n) = model.phase {
                            Text("\(n) lines parsed — ready to resolve.")
                                .foregroundStyle(.secondary)
                            Button("Resolve Against Apple Music") {
                                Task { await model.resolve() }
                            }
                        }
                        if !model.authGranted {
                            Label("Apple Music access needed to resolve",
                                  systemImage: "lock")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            default:
                EmptyView()
            }
        }
    }

    private var statusSection: some View {
        Group {
            switch model.phase {
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
            case .resolving(let progress, let total):
                ProgressView(value: Double(progress), total: Double(max(total, 1))) {
                    Text("Resolving \(progress)/\(total)…")
                }
            case .review(let needsReview, let unresolved, let resolved):
                Text("Resolved \(resolved) · Needs review \(needsReview) · Unresolved \(unresolved)")
                    .font(.callout)
            default:
                EmptyView()
            }
        }
    }

    private var resolutionList: some View {
        Group {
            if !model.resolutions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.resolutions, id: \.pos) { row in
                        ResolutionRow(row: row) { candidateId in
                            Task { await model.confirm(pos: row.pos, candidateId: candidateId) }
                        }
                        Divider()
                    }
                }
            }
        }
    }
}

/// One resolved/pending line: shows identity (per the explicit-review
/// invariant, catalog ids are shown — never just titles).
private struct ResolutionRow: View {
    let row: LineResolution
    let onPick: (Int) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(row.pos).")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)

            VStack(alignment: .leading, spacing: 4) {
                Text(row.rawTitle)
                    .font(.body.weight(.medium))

                switch row.status {
                case .resolved:
                    if let song = row.resolvedSong {
                        Text("\(song.title) — \(song.artistName)")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Text("Catalog ID \(song.catalogId)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                case .needsReview:
                    Text("Review required — pick the intended recording:")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    if let candidates = row.candidates {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(candidates) { candidate in
                                Button {
                                    onPick(candidate.catalogId)
                                } label: {
                                    HStack {
                                        Text("\(candidate.title) — \(candidate.artistName)")
                                            .font(.caption)
                                            .lineLimit(1)
                                        if let album = candidate.albumTitle {
                                            Text("(\(album))")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Text("#\(candidate.catalogId)")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .padding(4)
                                .background(Color.secondary.opacity(0.08),
                                            in: RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }
                case .unresolved:
                    Text("No match found in the Apple Music catalog.")
                        .font(.caption)
                        .foregroundStyle(.red)
                case .pending:
                    Text("Pending")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }
}
