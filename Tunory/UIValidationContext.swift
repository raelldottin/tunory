#if DEBUG
import Foundation
import MusicKit
import SwiftUI
import TunoryCore

/// Explicit, visibly labeled UI-test mode. Release builds contain none of this
/// adapter; ordinary Debug launches continue to use MusicKit and the real store.
@MainActor
final class UIValidationContext {
    let scenario: String
    let colorScheme: ColorScheme?
    let store: CheckpointStore
    let transport: UIValidationTransport
    private(set) var setupError: String?

    static func fromArguments() -> UIValidationContext? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--ui-validation"), args.indices.contains(index + 1) else { return nil }
        let scenario = args[index + 1]
        guard ["normal", "denied", "restricted", "catalog-failure", "recovery", "corrupt-recovery", "diverged-recovery", "stopped-write", "failed-readback"].contains(scenario) else { return nil }
        return UIValidationContext(scenario: scenario, darkAppearance: args.contains("--ui-dark"), lightAppearance: args.contains("--ui-light"))
    }

    init(scenario: String, darkAppearance: Bool = false, lightAppearance: Bool = false) {
        self.scenario = scenario
        colorScheme = darkAppearance ? .dark : lightAppearance ? .light : nil
        store = CheckpointStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("tunory-ui-validation-\(UUID().uuidString)", isDirectory: true))
        transport = UIValidationTransport(scenario: scenario)
        do {
            if scenario == "recovery" || scenario == "diverged-recovery" {
                try store.save(TransactionCheckpoint(playlistId: "test-owned-playlist", playlistName: "UI Validation Playlist", manifestCatalogIds: [101, 202], provenStoredPrefixCount: 1, provenLibraryCatalogIds: [101, 202], capturedAtMillisSinceEpoch: 1))
            } else if scenario == "corrupt-recovery" {
                try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
                try Data("Test-owned unreadable checkpoint".utf8).write(to: store.fileURL)
            }
        } catch { setupError = error.localizedDescription }
    }

    deinit { try? FileManager.default.removeItem(at: store.directory) }

    var authorization: MusicAuthorization.Status {
        if scenario == "denied" { return .denied }
        if scenario == "restricted" { return .restricted }
        return .authorized
    }

    var opensRecovery: Bool { scenario.contains("recovery") }

    func makeAuth() -> MusicAuthViewModel {
        MusicAuthViewModel(currentStatus: { [authorization] in authorization }, requestAccess: { [authorization] in authorization }, checkCatalog: { 1 })
    }

    func makeResolutionEngine(onFailure: @escaping @Sendable (String) async -> Void) -> ResolutionEngine {
        let scenario = scenario
        var sources = ResolutionEngine.Sources()
        sources.resolveIds = { ids in
            if scenario == "catalog-failure" { await onFailure("Test-owned offline catalog response"); return [:] }
            return Dictionary(uniqueKeysWithValues: ids.compactMap { id in
                guard [101, 202].contains(id) else { return nil }
                return (id, Self.song(id))
            })
        }
        sources.search = { _, _ in
            if scenario == "catalog-failure" { await onFailure("Test-owned offline catalog response"); return [] }
            return [
                SongCandidate(catalogId: 101, title: "First Song", artistName: "Test Artist", albumTitle: "An Album Name Long Enough to Check Accessible Wrapping", durationMilliseconds: 212000),
                SongCandidate(catalogId: 202, title: "First Song — Alternate Session With a Long Recording Identity", artistName: "Another Test Artist With a Long Name", albumTitle: "A Different Album With Complete Metadata", durationMilliseconds: 240000)
            ]
        }
        return ResolutionEngine(sources: sources)
    }

    nonisolated static func song(_ id: Int) -> ResolvedSong {
        ResolvedSong(catalogId: id, title: id == 101 ? "First Song" : "Second Song", artistName: "Test Artist", albumTitle: "UI Validation Album", durationMilliseconds: 212000)
    }

    func makeEngine() -> RESTEngine {
        RESTEngine(transport: transport, config: .init(propagateDelayMilliseconds: 0, verificationRetries: 1, verificationBackoffMilliseconds: 0,
                                                      appendVerificationRetries: 1, appendVerificationBackoffMilliseconds: 0,
                                                      createRediscoveryRetries: 1, createRediscoveryBackoffMilliseconds: 0))
    }
}

/// An in-memory Apple Music substitute used only by the explicit Debug mode.
/// DTOs follow the same canonical core contracts; no network capability exists.
actor UIValidationTransport: AMTransport {
    private let scenario: String
    private var library: Set<Int> = []
    private var stored: [Int] = []
    private var readbacksAfterAppend = 0
    private var playlistName = ""

    init(scenario: String) {
        self.scenario = scenario
        if scenario == "recovery" || scenario == "diverged-recovery" {
            library = [101, 202]
            stored = scenario == "recovery" ? [101] : [202]
            playlistName = "UI Validation Playlist"
        }
    }

    private func decode<T: Decodable>(_ object: [String: Any], as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }

    private func librarySong(_ id: Int) throws -> AMLibrarySong {
        try decode(["id": "test-song-\(id)", "attributes": ["name": id == 101 ? "First Song" : "Second Song", "artistName": "Test Artist", "playParams": ["catalogId": id]]], as: AMLibrarySong.self)
    }

    private func playlist() throws -> AMLibraryPlaylist {
        try decode(["id": "test-owned-playlist", "attributes": ["name": playlistName, "canEdit": true]], as: AMLibraryPlaylist.self)
    }

    func getCatalogSong(catalogId: Int, storefront: String) async throws -> (song: AMCatalogSong?, httpStatus: Int) {
        guard [101, 202].contains(catalogId) else { return (nil, 404) }
        let song = try decode(["id": String(catalogId), "attributes": ["name": catalogId == 101 ? "First Song" : "Second Song", "artistName": "Test Artist", "albumName": "UI Validation Album", "durationInMillis": 212000]], as: AMCatalogSong.self)
        return (song, 200)
    }
    func getLibrarySongsPage(cursor: String?) async throws -> (items: [AMLibrarySong], next: String?) {
        (try library.sorted().map { try librarySong($0) }, nil)
    }
    func getLibraryPlaylistsPage(cursor: String?) async throws -> (items: [AMLibraryPlaylist], next: String?) {
        (playlistName.isEmpty ? [] : [try playlist()], nil)
    }
    func getPlaylistTracks(playlistId: String) async throws -> [AMLibrarySong] {
        if !stored.isEmpty { readbacksAfterAppend += 1 }
        if scenario == "failed-readback", readbacksAfterAppend >= 2, let id = stored.first {
            return try (stored + [id]).map { try librarySong($0) }
        }
        return try stored.map { try librarySong($0) }
    }
    func addCatalogSongToLibrary(catalogId: Int) async throws -> Int {
        if scenario == "stopped-write" { return 500 }
        library.insert(catalogId)
        return 202
    }
    func appendLibrarySong(toPlaylist playlistId: String, librarySongId: String) async throws -> Int {
        guard let id = Int(librarySongId.replacingOccurrences(of: "test-song-", with: "")), library.contains(id) else { return 404 }
        stored.append(id)
        readbacksAfterAppend = 0
        return 204
    }
    func createPlaylist(named name: String) async throws -> (playlist: AMLibraryPlaylist?, httpStatus: Int) {
        playlistName = name
        return (try playlist(), 201)
    }
}
#endif
