import Foundation

// MARK: - Manifest model

/// An ordered, immutable manifest entry. The catalog ID is the authoritative
/// recording identity (docs/apple-music-integration-retrospective.md §10);
/// name/artist/album are display and sanity-check data only.
public struct ManifestEntry: Equatable, Sendable, Codable {
    public let pos: Int
    public let catalogId: Int
    public let name: String
    public let artist: String
    public let album: String?
    public let durationSeconds: Int?
    public let url: String?

    public init(pos: Int, catalogId: Int, name: String, artist: String,
                album: String?, durationSeconds: Int?, url: String?) {
        self.pos = pos
        self.catalogId = catalogId
        self.name = name
        self.artist = artist
        self.album = album
        self.durationSeconds = durationSeconds
        self.url = url
    }
}

/// A parsed, validated manifest. Entries are always sorted by `pos`.
public struct ParsedManifest: Equatable, Sendable {
    public let entries: [ManifestEntry]
}

public enum ManifestError: Error, Equatable, Sendable {
    case malformedJSON(String)
    case emptyManifest
    case invalidCatalogId(pos: Int)
    case duplicateCatalogId(catalogId: Int, positions: [Int])
    case blankName(pos: Int)
    case blankArtist(pos: Int)
    case nonSequentialPositions(found: [Int], expected: [Int])
    case invalidDuration(pos: Int)
    case invalidURL(pos: Int)
    /// A reviewed line never received a confirmed recording identity.
    /// Carried here so manifest-building has ONE error surface for the UI.
    case unresolvedLine(pos: Int)
}

// MARK: - Apple Music link model

public enum AppleMusicLinkKind: Equatable, Sendable {
    case song
    case album
    case playlist
}

// MARK: - Pasted line model

public enum ParsedLineKind: Equatable, Sendable {
    case name
    case link
}

public struct ParsedLine: Equatable, Sendable {
    public let pos: Int
    /// The cleaned, human-readable title as it will be displayed.
    public let rawTitle: String
    public let kind: ParsedLineKind
    /// Present when the line is (or contains) an authoritative song link.
    public let catalogId: Int?
    public let link: AppleMusicLink?
    /// Optional artist hint parsed from "Title - Artist" style lines.
    public let artistHint: String?
    /// The title used for matching (rawTitle minus artist hint).
    public let title: String

    public init(pos: Int, rawTitle: String, kind: ParsedLineKind, catalogId: Int?,
                link: AppleMusicLink? = nil, artistHint: String? = nil, title: String? = nil) {
        self.pos = pos
        self.rawTitle = rawTitle
        self.kind = kind
        self.catalogId = catalogId
        self.link = link
        self.artistHint = artistHint
        self.title = title ?? rawTitle
    }
}

// MARK: - Resolution model

public struct SongCandidate: Equatable, Sendable, Identifiable {
    public let catalogId: Int
    public let title: String
    public let artistName: String
    public let albumTitle: String?
    public let durationMilliseconds: Int?

    public var id: Int { catalogId }

    public init(catalogId: Int, title: String, artistName: String,
                albumTitle: String? = nil, durationMilliseconds: Int? = nil) {
        self.catalogId = catalogId
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.durationMilliseconds = durationMilliseconds
    }
}

public struct ResolvedSong: Equatable, Sendable {
    public let catalogId: Int
    public let title: String
    public let artistName: String
    public let albumTitle: String?
    public let durationMilliseconds: Int?

    public init(catalogId: Int, title: String, artistName: String,
                albumTitle: String?, durationMilliseconds: Int?) {
        self.catalogId = catalogId
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.durationMilliseconds = durationMilliseconds
    }
}

public enum ResolutionStatus: Equatable, Sendable {
    case pending
    case resolved
    case needsReview
    case unresolved
}

/// How a line got its identity — audit trail for the explicit-review policy.
public enum ResolutionPath: Equatable, Sendable {
    case byCatalogId
    case bySearchExactMatch
    case bySearchReview
    case byReviewConfirmation
}

public struct LineResolution: Equatable, Sendable {
    public let pos: Int
    public let status: ResolutionStatus
    public let rawTitle: String
    public let resolvedSong: ResolvedSong?
    public let candidates: [SongCandidate]?
    public let resolutionPath: ResolutionPath?

    public init(pos: Int, status: ResolutionStatus, rawTitle: String,
                resolvedSong: ResolvedSong? = nil, candidates: [SongCandidate]? = nil,
                resolutionPath: ResolutionPath? = nil) {
        self.pos = pos
        self.status = status
        self.rawTitle = rawTitle
        self.resolvedSong = resolvedSong
        self.candidates = candidates
        self.resolutionPath = resolutionPath
    }
}
