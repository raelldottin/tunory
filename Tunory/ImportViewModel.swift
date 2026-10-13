import Foundation
import Combine
import TunoryCore

/// Read-only input → resolution → explicit review. Core owns all matching rules.
@MainActor
final class ImportViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case parsed(lines: Int)
        case resolving(progress: Int, total: Int)
        case review(needsReview: Int, unresolved: Int, resolved: Int)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var resolutions: [LineResolution] = []
    @Published private(set) var authGranted = false
    @Published private(set) var confirmingPositions: Set<Int> = []
    @Published private(set) var sourceWarning: String?
    private let authModel: MusicAuthViewModel
    private let makeEngine: @MainActor (@escaping @Sendable (String) async -> Void) -> ResolutionEngine
    private var engine: ResolutionEngine?
    private var pendingLines: [ParsedLine] = []
    private var generation: UInt = 0
    private var resolutionTask: Task<[LineResolution], Never>?
    private var confirmationTasks: [Int: Task<LineResolution, Never>] = [:]

    var isBusy: Bool {
        if case .resolving = phase { return true }
        return !confirmingPositions.isEmpty
    }
    var hasInput: Bool { !pendingLines.isEmpty }
    var canContinueReview: Bool {
        !isBusy && sourceWarning == nil && !resolutions.isEmpty && resolutions.allSatisfy { $0.status == .resolved }
    }

    init(authModel: MusicAuthViewModel,
         makeEngine: @escaping @MainActor (@escaping @Sendable (String) async -> Void) -> ResolutionEngine = { onFailure in
             ResolutionEngine(sources: MusicKitSources.make(onFailure: onFailure))
         }) {
        self.authModel = authModel
        self.makeEngine = makeEngine
        _authGranted = Published(initialValue: authModel.state == .authorized)
    }

    func refreshAuth() {
        authModel.refresh()
        let granted = authModel.state == .authorized
        if authGranted != granted { authGranted = granted }
    }

    func inputDidChange() { reset() }

    func importManifest(from url: URL) {
        reset()
        // The file-picker grant is scoped to this immediate read, including failures.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let manifest = try ManifestParser.parse(data: Data(contentsOf: url))
            pendingLines = manifest.entries.map { entry in
                ParsedLine(pos: entry.pos, rawTitle: entry.name, kind: .link,
                           catalogId: entry.catalogId,
                           link: AppleMusicLink(kind: .song, storefront: "us", catalogId: entry.catalogId, albumId: nil),
                           title: entry.name)
            }
            phase = .parsed(lines: pendingLines.count)
        } catch {
            phase = .failed(String(localized: "Invalid manifest: \(describe(error))"))
        }
    }

    func importPastedList(_ text: String) {
        reset()
        let lines = PastedListParser.parse(text)
        guard !lines.isEmpty else {
            phase = .failed(String(localized: "No usable lines found in the pasted text."))
            return
        }
        pendingLines = lines
        phase = .parsed(lines: lines.count)
    }

    func setParseError(_ message: String) {
        reset()
        phase = .failed(message)
    }

    func resolve() async {
        guard !isBusy, !pendingLines.isEmpty else { return }
        refreshAuth()
        guard authGranted else { accessFailure(); return }
        generation &+= 1
        let revision = generation
        let lines = pendingLines
        sourceWarning = nil
        let engine = makeEngine { [weak self] message in
            guard !Task.isCancelled else { return }
            await self?.recordSourceFailure(message, revision: revision)
        }
        self.engine = engine
        resolutions = []
        phase = .resolving(progress: 0, total: lines.count)
        let task = Task { await engine.resolve(lines: lines) }
        resolutionTask = task
        let results = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        guard revision == generation else { return }
        resolutionTask = nil
        guard !Task.isCancelled, !task.isCancelled else {
            phase = .parsed(lines: lines.count)
            return
        }
        refreshAuth()
        guard authGranted else { accessFailure(); return }
        resolutions = results
        updateReviewCounts()
    }

    func confirm(pos: Int, candidateId: Int) async {
        guard !confirmingPositions.contains(pos), let engine,
              let prior = resolutions.first(where: { $0.pos == pos }),
              prior.status == .needsReview,
              prior.candidates?.contains(where: { $0.catalogId == candidateId }) == true,
              let line = pendingLines.first(where: { $0.pos == pos }) else { return }
        if case .resolving = phase { return }
        refreshAuth()
        guard authGranted else { accessFailure(); return }
        let revision = generation
        confirmingPositions.insert(pos)
        let task = Task { await engine.confirm(pos: pos, candidateId: candidateId, line: line, prior: prior) }
        confirmationTasks[pos] = task
        let after = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        guard revision == generation else { return }
        confirmingPositions.remove(pos)
        confirmationTasks[pos] = nil
        guard !Task.isCancelled, !task.isCancelled else { return }
        refreshAuth()
        guard authGranted else { accessFailure(); return }
        // Re-find the position after suspension; a saved array index is never authoritative.
        guard let index = resolutions.firstIndex(where: { $0.pos == pos }) else { return }
        resolutions[index] = after
        updateReviewCounts()
    }

    func reset() {
        generation &+= 1
        resolutionTask?.cancel()
        confirmationTasks.values.forEach { $0.cancel() }
        resolutionTask = nil
        confirmationTasks = [:]
        confirmingPositions = []
        sourceWarning = nil
        phase = .idle
        resolutions = []
        pendingLines = []
        engine = nil
    }

    private func recordSourceFailure(_ message: String, revision: UInt) {
        guard revision == generation else { return }
        sourceWarning = String(localized: "An Apple Music catalog request did not complete: \(message)")
    }

    private func accessFailure() {
        phase = .failed(String(localized: "Apple Music access is required to resolve songs. Enable access on Status, then try again."))
    }

    private func updateReviewCounts() {
        phase = .review(needsReview: resolutions.filter { $0.status == .needsReview }.count,
                        unresolved: resolutions.filter { $0.status == .unresolved }.count,
                        resolved: resolutions.filter { $0.status == .resolved }.count)
    }

    private func describe(_ error: Error) -> String {
        guard let error = error as? ManifestError else { return error.localizedDescription }
        switch error {
        case .malformedJSON: return String(localized: "The file is not valid manifest JSON.")
        case .emptyManifest: return String(localized: "The manifest is empty.")
        case .invalidCatalogId(let pos): return String(localized: "Recording \(pos) has an invalid catalog ID.")
        case .duplicateCatalogId(let id, let positions): return String(localized: "Catalog ID \(id) is repeated at positions \(positions.map(String.init).joined(separator: ", ")).")
        case .blankName(let pos): return String(localized: "Recording \(pos) has an empty name.")
        case .blankArtist(let pos): return String(localized: "Recording \(pos) has an empty artist.")
        case .nonSequentialPositions: return String(localized: "Positions must run from 1 to the recording count in order.")
        case .invalidDuration(let pos): return String(localized: "Recording \(pos) has an invalid duration.")
        case .invalidURL(let pos): return String(localized: "Recording \(pos) has an invalid Apple Music URL.")
        case .unresolvedLine(let pos): return String(localized: "Recording \(pos) has no confirmed identity.")
        }
    }
}
