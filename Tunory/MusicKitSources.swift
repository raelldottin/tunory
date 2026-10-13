import Foundation
import MusicKit
import TunoryCore

/// Bridges MusicKit to ResolutionEngine.Sources. All Apple Music access in
/// the app goes through MusicKit's signed in-process authorization — no
/// developer-token handling, no REST, no third-party infrastructure.
struct MusicKitSources {

    /// Builds engine sources over the live catalog. Requires the
    /// MusicKit authorization to already be granted; callers must check
    /// MusicAuthorization.currentStatus first (Phase 1 invariant).
    static func make(onFailure: @escaping @Sendable (String) async -> Void = { _ in }) -> ResolutionEngine.Sources {
        var sources = ResolutionEngine.Sources()

        sources.resolveIds = { ids in
            guard MusicAuthorization.currentStatus == .authorized, !ids.isEmpty else { return [:] }
            var out: [Int: ResolvedSong] = [:]
            // MusicCatalogResourceRequest takes ids as strings; batch capped
            // at 100 per request (API limit), preserving correctness across
            // batches by simple concatenation.
            for chunk in ids.chunked(into: 100) where !chunk.isEmpty {
                let idStrings = chunk.map { MusicItemID(String($0)) }
                let request = MusicCatalogResourceRequest<Song>(
                    matching: \.id, memberOf: idStrings)
                do {
                    let response = try await request.response()
                    for song in response.items {
                        out[songCatalogId(song)] = ResolvedSong(
                            catalogId: songCatalogId(song),
                            title: song.title,
                            artistName: song.artistName,
                            albumTitle: song.albumTitle,
                            durationMilliseconds: song.duration.map { Int($0 * 1000) }
                        )
                    }
                } catch {
                    // Network/availability errors surface as "unresolved";
                    // the review UI can retry. Never fabricate data.
                    await onFailure(error.localizedDescription)
                    continue
                }
            }
            return out
        }

        sources.search = { query, limit in
            guard MusicAuthorization.currentStatus == .authorized else { return [] }
            // Search term: title, plus artist hint when available.
            var term = query.title
            if let artist = query.artist, !artist.isEmpty {
                term = "\(query.title) \(artist)"
            }
            var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
            request.limit = limit
            do {
                let response = try await request.response()
                return response.songs.map { song in
                    SongCandidate(catalogId: songCatalogId(song),
                                  title: song.title,
                                  artistName: song.artistName,
                                  albumTitle: song.albumTitle,
                                  durationMilliseconds: song.duration.map { Int($0 * 1000) })
                }
            } catch {
                await onFailure(error.localizedDescription)
                return []
            }
        }

        return sources
    }

    /// MusicKit's Song.id.rawValue is the catalog id string.
    nonisolated private static func songCatalogId(_ song: Song) -> Int {
        Int(song.id.rawValue) ?? 0
    }
}

extension Array {
    nonisolated fileprivate func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
