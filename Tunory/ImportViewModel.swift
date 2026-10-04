import Foundation
import Combine
import MusicKit
import TunoryCore

/// Drives the import flow: manifest JSON file or pasted list → parsed lines
/// → resolution → explicit review. Resolution decisions live in TunoryCore;
/// this view model only orchestrates UI state. It NEVER writes to the user's
/// library (Phase 3 concern).
@MainActor
final class ImportViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case parsed(lines: Int)               // parse OK, not yet resolved
        case resolving(progress: Int, total: Int)
        case review(needsReview: Int, unresolved: Int, resolved: Int)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var resolutions: [LineResolution] = []
    @Published private(set) var authGranted: Bool = false

    private var engine: ResolutionEngine?
    private var pendingLines: [ParsedLine] = []
    private let authModel: MusicAuthViewModel

    init(authModel: MusicAuthViewModel) {
        self.authModel = authModel
        refreshAuth()
    }

    func refreshAuth() {
        authGranted = MusicAuthorization.currentStatus == .authorized
    }

    // MARK: - Import entry points

    /// Imports a JSON manifest from a file URL (open-panel selected).
    ///
    /// The app is sandboxed: a URL handed over by the file importer is only
    /// readable inside a security-scoped resource session
    /// (start/stopAccessingSecurityScopedResource). The panel's consent alone
    /// (the com.apple.macl grant) does not make a bare Data(contentsOf:)
    /// readable — it fails with NSFileReadNoPermissionError under the sandbox.
    /// No bookmark is persisted: the file is read exactly once, immediately.
    func importManifest(from url: URL) {
        do {
            let data: Data
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            data = try Data(contentsOf: url)
            let manifest = try ManifestParser.parse(data: data)
            let lines = manifest.entries.map { entry in
                ParsedLine(pos: entry.pos, rawTitle: entry.name, kind: .link,
                           catalogId: entry.catalogId,
                           link: AppleMusicLink(kind: .song, storefront: "us",
                                                catalogId: entry.catalogId, albumId: nil),
                           title: entry.name)
            }
            pendingLines = lines
            phase = .parsed(lines: lines.count)
        } catch {
            let message: String
            if case ManifestError.emptyManifest = error {
                message = "The manifest is empty."
            } else {
                message = "Invalid manifest: \(describe(error))"
            }
            phase = .failed(message)
        }
    }

    /// Imports a pasted song list (names and/or Apple Music links).
    func importPastedList(_ text: String) {
        let lines = PastedListParser.parse(text)
        guard !lines.isEmpty else {
            phase = .failed("No usable lines found in the pasted text.")
            return
        }
        pendingLines = lines
        phase = .parsed(lines: lines.count)
    }

    /// Surfaces a UI-level failure (e.g. open-panel error).
    func setParseError(_ message: String) {
        phase = .failed(message)
    }

    // MARK: - Resolution

    func resolve() async {
        guard !pendingLines.isEmpty else { return }
        refreshAuth()
        guard authGranted else {
            phase = .failed("Apple Music access is required to resolve songs. "
                            + "Enable it on the main screen first.")
            return
        }
        phase = .resolving(progress: 0, total: pendingLines.count)
        engine = ResolutionEngine(sources: MusicKitSources.make())
        let results = await engine!.resolve(lines: pendingLines)
        resolutions = results
        let needsReview = results.filter { $0.status == .needsReview }.count
        let unresolved = results.filter { $0.status == .unresolved }.count
        let resolved = results.filter { $0.status == .resolved }.count
        phase = .review(needsReview: needsReview, unresolved: unresolved, resolved: resolved)
    }

    /// Applies an explicit review decision on one line.
    func confirm(pos: Int, candidateId: Int) async {
        guard let engine,
              let index = resolutions.firstIndex(where: { $0.pos == pos }),
              let line = pendingLines.first(where: { $0.pos == pos }) else { return }
        let prior = resolutions[index]
        let after = await engine.confirm(pos: pos, candidateId: candidateId,
                                         line: line, prior: prior)
        resolutions[index] = after
        let needsReview = resolutions.filter { $0.status == .needsReview }.count
        let unresolved = resolutions.filter { $0.status == .unresolved }.count
        let resolved = resolutions.filter { $0.status == .resolved }.count
        phase = .review(needsReview: needsReview, unresolved: unresolved, resolved: resolved)
    }

    func reset() {
        phase = .idle
        resolutions = []
        pendingLines = []
        engine = nil
    }

    private func describe(_ error: Error) -> String {
        if let manifestError = error as? ManifestError {
            switch manifestError {
            case .malformedJSON: return "the file is not valid JSON."
            case .emptyManifest: return "no entries."
            case .invalidCatalogId(let pos): return "entry \(pos) has an invalid catalog id."
            case .duplicateCatalogId(let id, let positions):
                return "catalog id \(id) appears at positions \(positions)."
            case .blankName(let pos): return "entry \(pos) has an empty name."
            case .blankArtist(let pos): return "entry \(pos) has an empty artist."
            case .nonSequentialPositions: return "positions must be 1...N in order."
            case .invalidDuration(let pos): return "entry \(pos) has an invalid duration."
            case .invalidURL(let pos): return "entry \(pos) has a non-Apple-Music URL."
            case .unresolvedLine(let pos): return "line \(pos) has no confirmed recording."
            }
        }
        return error.localizedDescription
    }
}
