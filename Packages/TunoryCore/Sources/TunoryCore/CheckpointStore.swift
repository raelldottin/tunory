import Foundation

// MARK: - Phase 9: checkpoint persistence (GUI recovery)
//
// Phase 6 proved interrupted-execute checkpoints: the credential-free record
// of what a fresh read PROVED about an interrupted transaction. The CLI
// persists them at an explicit --checkpoint path; the GUI needs the same
// durability without a CLI, so an interrupted run survives an app relaunch.
//
// This store is deliberately mechanical: save, load, clear — no policy. The
// checkpoint stays credential-free by construction (TransactionCheckpoint
// carries only playlist identity, manifest catalog IDs, and proven counts).
// Persistence NEVER turns a checkpoint into proof: recovery still reconciles
// against Apple's actual state by fresh reads (RecoveryPlanner fail-closed).
//
// One slot: the newest interrupted transaction wins. Any earlier unfinished
// transaction's playlist state remains §20-safe (appends are proven-ordered),
// and a fresh import to the same playlist re-derives from reality — the
// checkpoint is an aid, never an authority.

/// File-backed store for the newest interrupted-transaction checkpoint.
/// Pure Foundation: injectable directory (tests use a temp directory; the
/// app uses its sandboxed Application Support).
public struct CheckpointStore: Sendable {

    /// What a load found on disk. `unreadable` is distinct from `none`: a
    /// corrupt file must be surfaced ("saved progress was found but could
    /// not be read"), never silently ignored — the user decides whether to
    /// dismiss it.
    public enum LoadResult: Equatable, Sendable {
        case none
        case unreadable(String)
        case checkpoint(TransactionCheckpoint)
    }

    /// Directory the checkpoint file lives in (created on save).
    public let directory: URL

    /// The single checkpoint slot's file.
    public let fileURL: URL

    public init(directory: URL) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("checkpoint.json")
    }

    /// The app's default location: Application Support/Tunory (the app
    /// sandbox resolves this inside the app container).
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask)[0]
        return base.appendingPathComponent("Tunory", isDirectory: true)
    }

    /// Atomically writes the checkpoint, creating the directory when
    /// missing. Overwrites any previous checkpoint (single slot).
    public func save(_ checkpoint: TransactionCheckpoint) throws {
        try FileManager.default.createDirectory(at: directory,
                                               withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(checkpoint)
        try data.write(to: fileURL, options: [.atomic])
    }

    /// Reads the stored checkpoint. Missing file -> .none; a file that is
    /// present but undecodable -> .unreadable (fail-visible, never hidden).
    public func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .none
        }
        do {
            let data = try Data(contentsOf: fileURL)
            return .checkpoint(try JSONDecoder().decode(TransactionCheckpoint.self,
                                                       from: data))
        } catch {
            return .unreadable(String(describing: error))
        }
    }

    /// Best-effort removal of the stored checkpoint (the user dismissed
    /// recovery, or a verified success superseded it). Missing file is not
    /// an error.
    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Clears the stored checkpoint when a VERIFIED success proves the
    /// transaction it describes is complete. Strict identity: only the same
    /// playlist AND the same manifest sequence are superseded — a success
    /// for a different transaction says nothing about a stored checkpoint.
    /// Returns whether a checkpoint was removed.
    @discardableResult
    public func clearIfSuperseded(bySuccessWith playlistId: String,
                                  manifestCatalogIds: [Int]) -> Bool {
        guard case .checkpoint(let existing) = load(),
              existing.playlistId == playlistId,
              existing.manifestCatalogIds == manifestCatalogIds else {
            return false
        }
        clear()
        return true
    }
}
