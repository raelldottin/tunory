import Foundation

// MARK: - Canonical manifest building (review state → ParsedManifest)
//
// The GUI's recording-review screen ends in a list of per-line decisions.
// This is the ONE canonical path from that state to the transaction
// manifest: positions are re-derived 1...N from display order, identities
// are taken ONLY from confirmed/resolved catalog IDs, and every ManifestParser
// invariant (uniqueness, non-blank names/artists, sequential positions) is
// enforced here exactly as if the manifest came from a file — the transaction
// therefore derives from the same canonical validation either way.

public extension ManifestParser {

    /// Builds a manifest from reviewed lines. `lineCount`/`catalogIdForLine`
    /// supply the display order and the confirmed identity per position;
    /// `nameForLine`/`artistForLine` supply display data. A nil catalogId
    /// (never resolved / no review decision) is a stop — the caller surfaces
    /// it beside the affected item.
    static func build(lineCount: Int,
                      catalogIdForLine: (Int) -> Int?,
                      nameForLine: (Int) -> String,
                      artistForLine: (Int) -> String) throws -> ParsedManifest {
        guard lineCount > 0 else { throw ManifestError.emptyManifest }

        var seen: [Int: [Int]] = [:]
        for pos in 1...lineCount {
            guard let catalogId = catalogIdForLine(pos) else {
                throw ManifestError.unresolvedLine(pos: pos)
            }
            guard catalogId > 0 else { throw ManifestError.invalidCatalogId(pos: pos) }
            seen[catalogId, default: []].append(pos)
        }
        if let dup = seen.first(where: { $0.value.count > 1 }) {
            throw ManifestError.duplicateCatalogId(catalogId: dup.key, positions: dup.value)
        }
        for pos in 1...lineCount {
            guard !nameForLine(pos).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ManifestError.blankName(pos: pos)
            }
            guard !artistForLine(pos).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ManifestError.blankArtist(pos: pos)
            }
        }
        let entries = (1...lineCount).map { pos -> ManifestEntry in
            ManifestEntry(pos: pos,
                          catalogId: catalogIdForLine(pos)!,
                          name: nameForLine(pos).trimmingCharacters(in: .whitespacesAndNewlines),
                          artist: artistForLine(pos).trimmingCharacters(in: .whitespacesAndNewlines),
                          album: nil, durationSeconds: nil, url: nil)
        }
        return ParsedManifest(entries: entries)
    }
}
