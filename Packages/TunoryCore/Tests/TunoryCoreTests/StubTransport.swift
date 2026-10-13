import Foundation
@testable import TunoryCore

/// Deterministic in-memory AMTransport for engine tests. Every response is
/// pre-scripted; nothing is fabricated — unscripted calls throw, so tests
/// prove exactly which REST surface each operation touches.
final class StubTransport: AMTransport, @unchecked Sendable {

    struct Call: Equatable {
        let name: String
        let detail: String
    }

    private let lock = NSLock()
    private var callsRecorded: [Call] = []

    /// catalogId -> catalog song (nil = 404).
    var catalogSongs: [Int: AMCatalogSong] = [:]
    /// Pages of library songs, in order; nil = single empty page.
    var libraryPages: [[AMLibrarySong]] = [[]]
    /// Pages of playlists.
    var playlistPages: [[AMLibraryPlaylist]] = []
    /// playlistId -> stored tracks.
    var playlistTracks: [String: [AMLibrarySong]] = [:]
    /// When true (default), a 2xx appendLibrarySong mutates playlistTracks
    /// by appending the resolved library song — the stub behaves like the
    /// real server, whose state reflects accepted writes.
    var appendsMutateTracks: Bool = true
    /// When > 0, getPlaylistTracks hides that many of the most recently
    /// appended tracks — simulating propagation lag. Each read decrements
    /// it, so the write "becomes visible" on a later fresh read.
    var appendVisibilityLag: Int = 0
    /// catalogId -> HTTP status for library adds.
    var libraryAddStatuses: [Int: Int] = [:]
    /// When true, a 2xx addCatalogSongToLibrary makes the song appear in
    /// the NEXT full library enumeration — the real server's behavior
    /// (§11: the 202 is an acknowledgment; presence is proven by a later
    /// fresh read). Off by default so scripted tests stay deterministic.
    var addsBecomeVisibleInLibrary: Bool = false
    /// With addsBecomeVisibleInLibrary, hides the add from the next N
    /// enumerations (propagation lag; 0 = visible on the next one).
    var libraryAddVisibilityLag: Int = 0
    private var pendingAdds: [(song: AMLibrarySong, hiddenFor: Int)] = []
    /// (playlistId, librarySongId) -> HTTP status for appends.
    var appendStatuses: [String: Int] = [:]
    /// When non-nil, the closure replaces the scripted status for a call.
    var libraryAddHook: ((Int) -> Int)?
    var appendHook: ((String, String) -> Int)?
    /// When non-nil, createPlaylist returns exactly this status (and this
    /// resource, if any) instead of the default 201-and-become-discoverable.
    var createPlaylistStatus: Int?
    var createdPlaylistResource: AMLibraryPlaylist?
    /// The id the stub's server-side state uses for a created playlist.
    let createdPlaylistId = "p.created"
    /// When > 0 at the moment of a default (201) create, the created
    /// playlist is hidden from the next N playlist-page reads — scripting
    /// the run-69 iCloud propagation lag deterministically. Each read
    /// that filters it out decrements the counter; after that the
    /// playlist is discoverable like the real server.
    var createVisibilityLag: Int = 0
    private var createdPlaylistHiddenFor = 0
    /// When non-nil, called at the start of each full library enumeration
    /// (first page fetch) with the 1-based enumeration ordinal; returns
    /// the pages to serve for that enumeration. Deterministic retry tests.
    var libraryEnumerationHook: ((Int) -> [[AMLibrarySong]])?
    private var enumerationIndex = 0

    /// library-song id -> song body, used to resolve appended ids into
    /// AMLibrarySong values (the real server stores full resources).
    var librarySongsById: [String: AMLibrarySong] = [:]

    func record(_ name: String, _ detail: String = "") {
        lock.lock()
        callsRecorded.append(Call(name: name, detail: detail))
        lock.unlock()
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return callsRecorded
    }

    /// Synchronous mutation under the lock (async-safe: no suspension point
    /// between lock and unlock).
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func appendStored(playlistId: String, song: AMLibrarySong) {
        withLock {
            playlistTracks[playlistId, default: []].append(song)
        }
    }

    func storedTracks(playlistId: String) -> [AMLibrarySong] {
        withLock {
            var tracks = playlistTracks[playlistId] ?? []
            if appendVisibilityLag > 0, !tracks.isEmpty {
                appendVisibilityLag -= 1
                tracks = Array(tracks.dropLast())
            }
            return tracks
        }
    }

    func getCatalogSong(catalogId: Int, storefront: String) async throws -> (song: AMCatalogSong?, httpStatus: Int) {
        record("catalog", "\(storefront)/\(catalogId)")
        if let song = catalogSongs[catalogId] {
            return (song, 200)
        }
        return (nil, 404)
    }

    func getLibrarySongsPage(cursor: String?) async throws -> (items: [AMLibrarySong], next: String?) {
        record("libraryPage", cursor ?? "first")
        if cursor == nil, let hook = libraryEnumerationHook {
            enumerationIndex += 1
            libraryPages = hook(enumerationIndex)
        }
        if cursor == nil {
            // A new enumeration begins: promote pending adds whose hidden
            // count reached 0; others stay hidden (decrement). Models the
            // real server where a 202 eventually becomes visible in a
            // fresh read (§11).
            withLock {
                for i in pendingAdds.indices where pendingAdds[i].hiddenFor > 0 {
                    pendingAdds[i].hiddenFor -= 1
                }
                let due = pendingAdds.filter { $0.hiddenFor == 0 }
                pendingAdds = pendingAdds.filter { $0.hiddenFor > 0 }
                if !due.isEmpty {
                    if libraryPages.isEmpty {
                        libraryPages = due.map { [$0.song] }
                    } else {
                        libraryPages[0] = (libraryPages[0] ?? []) + due.map { $0.song }
                    }
                }
            }
        }
        let index = cursor.map { Int($0) ?? 0 } ?? 0
        guard index < libraryPages.count else { return ([], nil) }
        let items = libraryPages[index]
        let next = index + 1 < libraryPages.count ? String(index + 1) : nil
        return (items, next)
    }

    func getLibraryPlaylistsPage(cursor: String?) async throws -> (items: [AMLibraryPlaylist], next: String?) {
        record("playlistPage", cursor ?? "first")
        let index = cursor.map { Int($0) ?? 0 } ?? 0
        guard index < playlistPages.count else { return ([], nil) }
        var items = playlistPages[index]
        // Run-69 lag scripting: the created playlist may be absent from the
        // next N playlist-page reads (iCloud eventual consistency).
        withLock {
            if createdPlaylistHiddenFor > 0 {
                createdPlaylistHiddenFor -= 1
                items = items.filter { $0.id != createdPlaylistId }
            }
        }
        let next = index + 1 < playlistPages.count ? String(index + 1) : nil
        return (items, next)
    }

    func getPlaylistTracks(playlistId: String) async throws -> [AMLibrarySong] {
        record("playlistTracks", playlistId)
        return storedTracks(playlistId: playlistId)
    }

    func addCatalogSongToLibrary(catalogId: Int) async throws -> Int {
        record("libraryAdd", String(catalogId))
        let status: Int
        if let hook = libraryAddHook { return hook(catalogId) }
        status = libraryAddStatuses[catalogId] ?? 202
        if (200..<300).contains(status), addsBecomeVisibleInLibrary {
            // Real-server behavior: the accepted add becomes visible to a
            // later fresh read (possibly after propagation lag).
            withLock {
                pendingAdds.append((Fixtures.librarySong(libraryId: "i.\(catalogId)", catalogId: catalogId),
                                     libraryAddVisibilityLag))
            }
        }
        return status
    }

    func appendLibrarySong(toPlaylist playlistId: String, librarySongId: String) async throws -> Int {
        record("append", "\(playlistId):\(librarySongId)")
        let status: Int
        if let hook = appendHook {
            status = hook(playlistId, librarySongId)
        } else {
            status = appendStatuses[librarySongId] ?? 204
        }
        if (200..<300).contains(status), appendsMutateTracks,
           let song = librarySongsById[librarySongId] {
            appendStored(playlistId: playlistId, song: song)
        }
        return status
    }

    func createPlaylist(named name: String) async throws -> (playlist: AMLibraryPlaylist?, httpStatus: Int) {
        record("createPlaylist", name)
        if let status = createPlaylistStatus {
            return (createdPlaylistResource, status)
        }
        // Default: behave like the real server — 201, and the created
        // playlist becomes discoverable by exact name in playlistPages.
        let resource = AMLibraryPlaylist(
            id: createdPlaylistId,
            attributes: .init(name: name, canEdit: true, shareUrl: nil))
        withLock {
            playlistTracks[createdPlaylistId] = []
            if playlistPages.isEmpty {
                playlistPages = [[resource]]
            } else {
                var pages = playlistPages
                var last = pages.removeLast()
                last.append(resource)
                pages.append(last)
                playlistPages = pages
            }
            createdPlaylistHiddenFor = createVisibilityLag
        }
        return (resource, 201)
    }
}

// MARK: - Fixture builders

enum Fixtures {

    static func manifestEntry(pos: Int, catalogId: Int,
                              name: String? = nil,
                              artist: String? = nil) -> ManifestEntry {
        ManifestEntry(pos: pos, catalogId: catalogId,
                      name: name ?? "Song \(pos)",
                      artist: artist ?? "Artist \(pos)",
                      album: nil, durationSeconds: nil, url: nil)
    }

    /// Manifest with sequential positions 1...N and the given catalog ids.
    static func manifest(ids: [Int]) -> ParsedManifest {
        ParsedManifest(entries: ids.enumerated().map { index, id in
            manifestEntry(pos: index + 1, catalogId: id)
        })
    }

    /// The real 17-entry "After Hours" manifest from the fixture file.
    static func afterHoursManifest() throws -> ParsedManifest {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/valid-manifest.json")
        return try ManifestParser.parse(data: try Data(contentsOf: url))
    }

    static func catalogSong(catalogId: Int, name: String, artist: String) -> AMCatalogSong {
        AMCatalogSong(id: String(catalogId),
                      attributes: .init(name: name, artistName: artist,
                                        albumName: nil, durationInMillis: nil))
    }

    static func librarySong(libraryId: String, catalogId: Int?) -> AMLibrarySong {
        AMLibrarySong(
            id: libraryId,
            attributes: .init(name: nil, artistName: nil,
                             playParams: catalogId.map { .init(catalogId: $0) }),
            relationships: nil)
    }

    /// §11 discipline: identity only via relationships.catalog (no playParams).
    static func librarySongViaRelationship(libraryId: String, catalogId: Int) -> AMLibrarySong {
        AMLibrarySong(
            id: libraryId,
            attributes: .init(name: nil, artistName: nil, playParams: nil),
            relationships: .init(catalog: .init(data: [.init(id: String(catalogId), type: "songs")])))
    }

    /// No catalog identity at all (upload / local file).
    static func unidentifiedLibrarySong(libraryId: String) -> AMLibrarySong {
        AMLibrarySong(id: libraryId,
                      attributes: .init(name: nil, artistName: nil, playParams: nil),
                      relationships: nil)
    }

    static func playlist(id: String, name: String, canEdit: Bool = true) -> AMLibraryPlaylist {
        AMLibraryPlaylist(id: id, attributes: .init(name: name, canEdit: canEdit, shareUrl: nil))
    }

    /// A transport scripted for the classic happy-path scenario: catalog
    /// complete, some library entries missing, empty target playlist.
    /// Library songs are registered by id so accepted appends are stored
    /// like the real server does.
    static func happyPathTransport(manifest: ParsedManifest,
                                   playlistName: String,
                                   libraryHas: [Int]) -> StubTransport {
        let t = StubTransport()
        for entry in manifest.entries {
            t.catalogSongs[entry.catalogId] = catalogSong(catalogId: entry.catalogId,
                                                           name: entry.name, artist: entry.artist)
            let song = librarySong(libraryId: "i.\(entry.catalogId)", catalogId: entry.catalogId)
            t.librarySongsById[song.id] = song
        }
        t.playlistPages = [[playlist(id: "p.test", name: playlistName)]]
        let libraryItems = libraryHas.enumerated().map { index, cid in
            librarySong(libraryId: "i.\(cid)", catalogId: cid)
        }
        t.libraryPages = [libraryItems]
        t.playlistTracks["p.test"] = []
        return t
    }
}
