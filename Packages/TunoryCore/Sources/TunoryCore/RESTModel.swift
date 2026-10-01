import Foundation

// MARK: - Apple Music API DTOs
//
// Tolerant decoding (Apple adds fields over time); strict validation lives in
// RESTEngine. Payload shapes follow the proven run documented in
// docs/apple-music-integration-retrospective.md:
//   §11  a library song's catalog identity lives in
//        attributes.playParams.catalogId (primary), with
//        relationships.catalog as fallback — the relationship is absent on
//        many items (notably iTunes-Match-era uploads).
//   §12  pagination follows the `next` cursor; the first page honors
//        limit=100, later pages may return fewer.
//   §13  GET /playlists/{id}/tracks returns HTTP 404 for an empty playlist.
//   §14  appends POST {"data":[{"id": <library-song-id>,
//        "type": "library-songs"}]}.

/// A catalog song resource (GET /v1/catalog/{storefront}/songs/{id}).
public struct AMCatalogSong: Decodable, Equatable, Sendable {
    public let id: String
    public let attributes: Attributes?

    public struct Attributes: Decodable, Equatable, Sendable {
        public let name: String?
        public let artistName: String?
        public let albumName: String?
        public let durationInMillis: Int?
    }

    public init(id: String, attributes: Attributes?) {
        self.id = id
        self.attributes = attributes
    }
}

/// A library song resource (GET /v1/me/library/songs; playlist tracks use
/// the same resource shape).
public struct AMLibrarySong: Decodable, Equatable, Sendable {
    public let id: String
    public let attributes: Attributes?
    public let relationships: Relationships?

    public struct Attributes: Decodable, Equatable, Sendable {
        public let name: String?
        public let artistName: String?
        public let playParams: PlayParams?
    }

    public struct PlayParams: Decodable, Equatable, Sendable {
        /// §11: primary source of the library song's catalog identity.
        /// Observed as both number and string in real payloads; decode both.
        public let catalogId: Int?

        private enum CodingKeys: String, CodingKey { case catalogId }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let asInt = try? container.decode(Int.self, forKey: .catalogId) {
                catalogId = asInt
            } else if let asString = try? container.decode(String.self, forKey: .catalogId),
                      let asInt = Int(asString) {
                catalogId = asInt
            } else {
                catalogId = nil
            }
        }

        public init(catalogId: Int?) {
            self.catalogId = catalogId
        }
    }

    public struct Relationships: Decodable, Equatable, Sendable {
        public let catalog: Catalog?
    }

    public struct Catalog: Decodable, Equatable, Sendable {
        public let data: [CatalogRef]?
    }

    public struct CatalogRef: Decodable, Equatable, Sendable {
        public let id: String
        public let type: String?
    }

    public init(id: String, attributes: Attributes?, relationships: Relationships?) {
        self.id = id
        self.attributes = attributes
        self.relationships = relationships
    }

    /// The catalog ID this library song carries, or nil when it has none
    /// (uploads / local files). §11 discipline: playParams first,
    /// relationships.catalog as fallback. Never invents an identity.
    public var catalogId: Int? {
        if let id = attributes?.playParams?.catalogId {
            return id
        }
        if let ref = relationships?.catalog?.data?.first, let id = Int(ref.id) {
            return id
        }
        return nil
    }
}

/// A library playlist resource (GET /v1/me/library/playlists).
public struct AMLibraryPlaylist: Decodable, Equatable, Sendable {
    public let id: String
    public let attributes: Attributes?

    public struct Attributes: Decodable, Equatable, Sendable {
        public let name: String?
        public let canEdit: Bool?
        public let shareUrl: String?
    }

    public init(id: String, attributes: Attributes?) {
        self.id = id
        self.attributes = attributes
    }
}

/// Collection wrapper shared by Apple Music API list responses.
public struct AMPage<Item: Decodable & Sendable>: Decodable, Sendable {
    /// Items on this page; nil/absent means empty.
    public let data: [Item]?
    /// Relative path of the next page; nil on the last page.
    public let next: String?

    public init(data: [Item]?, next: String?) {
        self.data = data
        self.next = next
    }
}

// MARK: - REST transport contract (MusicKit-free core)
//
// The app layer implements this with MusicDataRequest so that developer and
// user credentials are handled entirely inside MusicKit's in-process token
// machinery (MusicDataRequest.tokenProvider) — never printed, persisted, or
// passed across process boundaries.

public protocol AMTransport: Sendable {
    /// GET /v1/catalog/{storefront}/songs/{catalogId}.
    /// Returns (nil, 404) for a deleted/region-locked recording.
    func getCatalogSong(catalogId: Int, storefront: String) async throws -> (song: AMCatalogSong?, httpStatus: Int)

    /// One page of GET /v1/me/library/songs?limit=100&include=catalog.
    /// `cursor` is the `next` path from the previous page; nil fetches page 1.
    func getLibrarySongsPage(cursor: String?) async throws -> (items: [AMLibrarySong], next: String?)

    /// One page of GET /v1/me/library/playlists?limit=100.
    func getLibraryPlaylistsPage(cursor: String?) async throws -> (items: [AMLibraryPlaylist], next: String?)

    /// GET /v1/me/library/playlists/{playlistId}/tracks, all pages
    /// concatenated (§13: HTTP 404 on an empty playlist maps to []).
    /// Ordered exactly as stored.
    func getPlaylistTracks(playlistId: String) async throws -> [AMLibrarySong]

    /// POST /v1/me/library?ids[songs]={catalogId} — adds one catalog song to
    /// the library (one request per recording for attributable failures,
    /// §11). Returns the raw HTTP status (202 expected).
    func addCatalogSongToLibrary(catalogId: Int) async throws -> Int

    /// POST /v1/me/library/playlists/{playlistId}/tracks with a
    /// library-song id (§14 append shape). Returns the raw HTTP status
    /// (204 expected).
    func appendLibrarySong(toPlaylist playlistId: String, librarySongId: String) async throws -> Int

    /// POST /v1/me/library/playlists with {"attributes":{"name":…}} —
    /// creates a new library playlist. Returns the created resource and the
    /// raw HTTP status (201 expected).
    ///
    /// Callers must invoke this ONLY after discovery proved no playlist
    /// with the name exists (§20: the target must be uniquely
    /// identifiable), and must never treat the 201 response as proof of
    /// editability or state — those gates are fresh reads (the next
    /// preflight re-discovers the playlist by name).
    func createPlaylist(named name: String) async throws -> (playlist: AMLibraryPlaylist?, httpStatus: Int)
}

// MARK: - Errors and stop conditions (§20)

public enum AMError: Error, Equatable, Sendable {
    case transport(String)
    case notAuthorized
    case catalogLookupFailed(catalogId: Int, httpStatus: Int)
    case libraryAddFailed(catalogId: Int, httpStatus: Int)
    case playlistCreationFailed(httpStatus: Int)
    case playlistAppendFailed(pos: Int, catalogId: Int, librarySongId: String, httpStatus: Int)
    case playlistNotFound(name: String)
    case playlistAmbiguous(name: String, count: Int)
    case playlistNotEditable(playlistId: String)
    case playlistNotSafeToWrite(playlistId: String, state: PlaylistState)
    case librarySongMissing(catalogId: Int)
    case playlistVerificationFailed(reason: String)
    case paginationAborted(pages: Int)
    case malformedResponse(String)
    /// Restart reconciliation found the checkpoint's proven claims do not
    /// hold against Apple's actual state (writes vanished, identity or
    /// manifest changed, or the claim is not a manifest prefix). Recovery
    /// stops for human direction — it never auto-writes past uncertainty.
    case checkpointDiverged(reason: String)
}

// MARK: - Playlist state classification (§13)

/// Classification of an existing playlist against the manifest, computed
/// BEFORE any write. Only `empty`, `correctPrefix`, and `exactComplete` are
/// safe to append into; every other state is a stop condition.
public enum PlaylistState: Equatable, Codable, Sendable {
    case empty
    case exactComplete
    case correctPrefix(count: Int)
    case wrongOrder
    case containsDuplicates
    case containsUnrelatedTracks
    case containsUnidentifiableTracks

    public var isSafeToWrite: Bool {
        switch self {
        case .empty, .correctPrefix, .exactComplete: return true
        default: return false
        }
    }

    /// Stable machine label for the automation result contract (Phase 7).
    /// Deterministic, allocation-free; mirrors the CLI/GUI display naming.
    public var label: String {
        switch self {
        case .empty: return "empty"
        case .exactComplete: return "exactComplete"
        case .correctPrefix: return "correctPrefix"
        case .wrongOrder: return "wrongOrder"
        case .containsDuplicates: return "containsDuplicates"
        case .containsUnrelatedTracks: return "containsUnrelatedTracks"
        case .containsUnidentifiableTracks: return "containsUnidentifiableTracks"
        }
    }
}

// MARK: - Reports

/// Gate 3 report: one entry per manifest position, in manifest order.
/// `ok` requires the catalog recording to exist (HTTP 200 with data) — the
/// exact gate the proven run used. `nameDiverged` is the §10 sanity check
/// (same token-overlap bar as ResolutionEngine's link cross-check); it is
/// surfaced as information for review, never silently accepted nor ignored.
public struct CatalogValidationReport: Equatable, Codable, Sendable {
    public struct Entry: Equatable, Codable, Sendable {
        public let pos: Int
        public let catalogId: Int
        public let expectedName: String
        public let ok: Bool
        public let nameDiverged: Bool
        public let actualTitle: String?
        public let actualArtist: String?
        public let httpStatus: Int?
        public let reason: String?

        public init(pos: Int, catalogId: Int, expectedName: String, ok: Bool,
                    nameDiverged: Bool, actualTitle: String?, actualArtist: String?,
                    httpStatus: Int?, reason: String?) {
            self.pos = pos
            self.catalogId = catalogId
            self.expectedName = expectedName
            self.ok = ok
            self.nameDiverged = nameDiverged
            self.actualTitle = actualTitle
            self.actualArtist = actualArtist
            self.httpStatus = httpStatus
            self.reason = reason
        }
    }

    public let entries: [Entry]
    public var passed: Bool { entries.allSatisfy(\.ok) }
    /// True when a catalog lookup failed with AMError.notAuthorized (§15):
    /// the gate could not be evaluated at all — the runner must stop for
    /// re-authorization rather than report missing recordings.
    public let notAuthorized: Bool

    public init(entries: [Entry], notAuthorized: Bool = false) {
        self.entries = entries
        self.notAuthorized = notAuthorized
    }
}

/// Library reconciliation: manifest IDs already in the library (with their
/// library-song ids) and the ones missing, in manifest order.
public struct LibraryReconciliation: Equatable, Sendable {
    public let present: [Int: String]
    public let missing: [ManifestEntry]

    public init(present: [Int: String], missing: [ManifestEntry]) {
        self.present = present
        self.missing = missing
    }
}

/// Verified facts about one discovered playlist.
public struct PlaylistInfo: Equatable, Codable, Sendable {
    public let id: String
    public let name: String
    public let canEdit: Bool
    public let shareUrl: String?

    public init(id: String, name: String, canEdit: Bool, shareUrl: String?) {
        self.id = id
        self.name = name
        self.canEdit = canEdit
        self.shareUrl = shareUrl
    }
}

/// Result of the full playlist preflight (§13 classification + §20 stops).
public enum PlaylistPreflightResult: Equatable, Sendable {
    case ok(playlist: PlaylistInfo, state: PlaylistState, missingCatalogIds: [Int])
    case stop(AMError)
}

/// The immutable append plan derived from a safe preflight plus a verified
/// library map. This is the audit artifact: exactly what execution will
/// append, position by position, in manifest order. Execution may not
/// deviate from it, and the plan is re-validated against a fresh preflight
/// before any write is issued.
public struct AppendPlan: Equatable, Codable, Sendable {
    public struct Step: Equatable, Codable, Sendable {
        public let pos: Int
        public let catalogId: Int
        public let librarySongId: String

        public init(pos: Int, catalogId: Int, librarySongId: String) {
            self.pos = pos
            self.catalogId = catalogId
            self.librarySongId = librarySongId
        }
    }

    public let playlistId: String
    public let playlistName: String
    /// The manifest sequence this plan was derived from (catalog IDs, in
    /// order). Makes the plan self-contained: execution re-checks state
    /// against exactly this sequence, so a manifest that changed between
    /// plan and execute is caught as drift.
    public let manifestCatalogIds: [Int]
    public let steps: [Step]

    public init(playlistId: String, playlistName: String,
                manifestCatalogIds: [Int], steps: [Step]) {
        self.playlistId = playlistId
        self.playlistName = playlistName
        self.manifestCatalogIds = manifestCatalogIds
        self.steps = steps
    }
}

/// One library-add attempt. HTTP status carried verbatim so failures are
/// attributable per recording (§11: one request per recording).
public struct LibraryAddOutcome: Equatable, Codable, Sendable {
    public let pos: Int
    public let catalogId: Int
    public let httpStatus: Int
    public var ok: Bool { (200..<300).contains(httpStatus) }

    public init(pos: Int, catalogId: Int, httpStatus: Int) {
        self.pos = pos
        self.catalogId = catalogId
        self.httpStatus = httpStatus
    }
}

/// One playlist-append attempt (§14: append the exact track, then verify).
public struct AppendOutcome: Equatable, Codable, Sendable {
    public let pos: Int
    public let catalogId: Int
    public let librarySongId: String
    public let httpStatus: Int
    public var ok: Bool { (200..<300).contains(httpStatus) }

    public init(pos: Int, catalogId: Int, librarySongId: String, httpStatus: Int) {
        self.pos = pos
        self.catalogId = catalogId
        self.librarySongId = librarySongId
        self.httpStatus = httpStatus
    }
}

/// Fresh-read library verification (§11 step 4-5: a 202 is acknowledgment
/// only; presence is proven by re-reading the library).
public struct LibraryVerification: Equatable, Codable, Sendable {
    public let verified: Bool
    /// Missing manifest catalog IDs, in manifest order.
    public let missingCatalogIds: [Int]
    public let attempts: Int
    public let catalogToLibraryId: [Int: String]

    public init(verified: Bool, missingCatalogIds: [Int], attempts: Int,
                catalogToLibraryId: [Int: String]) {
        self.verified = verified
        self.missingCatalogIds = missingCatalogIds
        self.attempts = attempts
        self.catalogToLibraryId = catalogToLibraryId
    }
}

/// Independent final read-back of the playlist against the manifest (§16:
/// completion is defined by fresh reads, never by mutation acknowledgments).
public struct PlaylistVerification: Equatable, Codable, Sendable {
    public let playlistId: String
    public let expectedCatalogIds: [Int]
    /// Stored sequence, position by position; nil marks an unidentifiable
    /// track (no catalog identity).
    public let actualCatalogIds: [Int?]
    public let verified: Bool
    public let orderingPass: Bool
    public let duplicates: [Int]
    public let unexpectedCatalogIds: [Int]
    public let unidentifiableTrackCount: Int
    public let shareUrl: String?

    public init(playlistId: String, expectedCatalogIds: [Int], actualCatalogIds: [Int?],
                verified: Bool, orderingPass: Bool, duplicates: [Int],
                unexpectedCatalogIds: [Int], unidentifiableTrackCount: Int,
                shareUrl: String?) {
        self.playlistId = playlistId
        self.expectedCatalogIds = expectedCatalogIds
        self.actualCatalogIds = actualCatalogIds
        self.verified = verified
        self.orderingPass = orderingPass
        self.duplicates = duplicates
        self.unexpectedCatalogIds = unexpectedCatalogIds
        self.unidentifiableTrackCount = unidentifiableTrackCount
        self.shareUrl = shareUrl
    }
}
