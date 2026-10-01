import Foundation

/// Parses and validates the JSON manifest format proven in the Phase 0
/// prototype (17 ordered entries with catalog IDs as authoritative identity).
public enum ManifestParser {

    public static func parse(data: Data) throws -> ParsedManifest {
        let raw: [RawEntry]
        do {
            let decoder = JSONDecoder()
            raw = try decoder.decode([RawEntry].self, from: data)
        } catch {
            throw ManifestError.malformedJSON(String(describing: error))
        }
        return try validate(raw: raw)
    }

    // MARK: - DTO (tolerant decoding, strict validation)

    private struct RawEntry: Decodable {
        let pos: Int
        let catalogId: Int
        let name: String
        let artist: String
        let album: String?
        let dur_s: Int?
        let url: String?
    }

    private static func validate(raw: [RawEntry]) throws -> ParsedManifest {
        guard !raw.isEmpty else { throw ManifestError.emptyManifest }

        var seenIds: [Int: [Int]] = [:]
        for entry in raw {
            guard entry.catalogId > 0 else {
                throw ManifestError.invalidCatalogId(pos: entry.pos)
            }
            guard !entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ManifestError.blankName(pos: entry.pos)
            }
            guard !entry.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ManifestError.blankArtist(pos: entry.pos)
            }
            if let dur = entry.dur_s {
                guard dur > 0 else { throw ManifestError.invalidDuration(pos: entry.pos) }
            }
            if let url = entry.url {
                guard AppleMusicLink.parse(url) != nil else {
                    throw ManifestError.invalidURL(pos: entry.pos)
                }
            }
            seenIds[entry.catalogId, default: []].append(entry.pos)
        }

        if let dup = seenIds.first(where: { $0.value.count > 1 }) {
            throw ManifestError.duplicateCatalogId(catalogId: dup.key, positions: dup.value)
        }

        // Positions must be exactly 1...N without gaps or repeats.
        let sortedByPos = raw.sorted { $0.pos < $1.pos }
        let found = sortedByPos.map(\.pos)
        let expected = Array(1...raw.count)
        guard found == expected else {
            throw ManifestError.nonSequentialPositions(found: found, expected: expected)
        }

        let entries = sortedByPos.map { entry in
            ManifestEntry(
                pos: entry.pos,
                catalogId: entry.catalogId,
                name: entry.name.trimmingCharacters(in: .whitespacesAndNewlines),
                artist: entry.artist.trimmingCharacters(in: .whitespacesAndNewlines),
                album: entry.album?.trimmingCharacters(in: .whitespacesAndNewlines) ?? nil,
                durationSeconds: entry.dur_s,
                url: entry.url
            )
        }
        return ParsedManifest(entries: entries)
    }
}
