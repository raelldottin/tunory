import Foundation

// MARK: - Phase 9: user-facing derivation helpers (pure)
//
// Phase 9 requires explicit user-facing handling of the "divergence" state.
// The catalog gate (Gate 3) already RECORDS per-recording name divergence
// (§10 sanity check) in CatalogValidationReport.Entry.nameDiverged — but the
// GUI results screen had no way to show it without re-deriving matching
// logic in presentation code, which the architecture forbids. This helper
// puts the derivation in TunoryCore, next to the canonical evidence, so
// both front-ends display exactly what the canonical gate recorded.

/// Pure derivations from canonical evidence for user-facing display.
/// Nothing here decides anything — these are read-only projections of what
/// a completed phase already recorded.
public enum EvidencePresentation {

    /// One per-recording note the results screen should show, in manifest
    /// order. Sources:
    ///   • §10 name divergence recorded by the catalog gate (identity is
    ///     the catalog ID; the name mismatch is review information, never
    ///     a silent accept);
    ///   • a diverged catalog row is NOT a failure — the gate passed on ID
    ///     existence — so these surface as review notes, distinct from
    ///     per-row problems.
    public struct CatalogNote: Equatable, Sendable {
        public let pos: Int
        public let catalogId: Int
        /// The manifest-provided name (what the user asked for).
        public let requestedName: String
        /// What the catalog actually returned at that ID.
        public let actualTitle: String?
        public let actualArtist: String?

        public init(pos: Int, catalogId: Int, requestedName: String,
                    actualTitle: String?, actualArtist: String?) {
            self.pos = pos
            self.catalogId = catalogId
            self.requestedName = requestedName
            self.actualTitle = actualTitle
            self.actualArtist = actualArtist
        }
    }

    /// Per-recording catalog divergence notes, in manifest order, from the
    /// canonical Gate 3 report. Empty when no recording diverged.
    public static func catalogDivergenceNotes(from report: CatalogValidationReport) -> [CatalogNote] {
        report.entries
            .filter { entry in
                entry.nameDiverged && entry.ok
            }
            .map { entry in
                CatalogNote(pos: entry.pos,
                            catalogId: entry.catalogId,
                            requestedName: entry.expectedName,
                            actualTitle: entry.actualTitle,
                            actualArtist: entry.actualArtist)
            }
    }

    /// Human-readable one-liner for a divergence note (shared by GUI and
    /// any future CLI reporting — one wording, one place).
    public static func divergenceText(for note: CatalogNote) -> String {
        if let title = note.actualTitle, let artist = note.actualArtist {
            return "Apple Music catalog has “\(title)” by \(artist) at this ID."
        }
        if let title = note.actualTitle {
            return "Apple Music catalog has “\(title)” at this ID."
        }
        return "The catalog recording at this ID does not match the requested name."
    }
}
