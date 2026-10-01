import Foundation

/// A parsed Apple Music catalog URL. Only `?i=` song ids (album links) or
/// `/song/.../{id}` legacy paths carry a song catalog id; album/playlist
/// links never silently promote another id to song identity.
public struct AppleMusicLink: Equatable, Sendable {
    public let kind: AppleMusicLinkKind
    public let storefront: String
    /// Song catalog id; nil for album/playlist links.
    public let catalogId: Int?
    /// Album id for album-style links (also present on song links).
    public let albumId: Int?

    public init(kind: AppleMusicLinkKind, storefront: String, catalogId: Int?, albumId: Int?) {
        self.kind = kind
        self.storefront = storefront
        self.catalogId = catalogId
        self.albumId = albumId
    }
}

extension AppleMusicLink {

    /// Parses an Apple Music catalog URL into typed identity. Catalog song
    /// IDs are the authoritative recording identity; only unambiguous song
    /// ids are extracted, and only from genuine music.apple.com hosts.
    public static func parse(_ raw: String) -> AppleMusicLink? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else { return nil }

        // Exact host check — "music.apple.com.evil.com" must not pass.
        guard host == "music.apple.com" || host == "music.apple.com." else { return nil }

        // Storefront: first path component ("us", "gb", ...).
        let segments = url.path.split(separator: "/").map(String.init)
        guard let storefront = segments.first, !storefront.isEmpty,
              storefront.range(of: "^[a-z]{2}$", options: .regularExpression) != nil
        else { return nil }

        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems ?? []

        switch segments.dropFirst().first {
        case "album":
            // album/{slug}/{albumId}?i={songId}
            guard segments.count >= 3,
                  let albumId = Int(segments.last!), albumId > 0 else { return nil }
            if let iValue = queryItems.first(where: { $0.name == "i" })?.value {
                // A present-but-malformed song id fails the whole parse:
                // never silently degrade to an album link.
                guard let songId = Int(iValue), songId > 0 else { return nil }
                return AppleMusicLink(kind: .song, storefront: storefront,
                                      catalogId: songId, albumId: albumId)
            }
            return AppleMusicLink(kind: .album, storefront: storefront,
                                  catalogId: nil, albumId: albumId)

        case "song":
            // legacy: song/{slug}/{songId}
            guard segments.count >= 3,
                  let songId = Int(segments.last!), songId > 0 else { return nil }
            return AppleMusicLink(kind: .song, storefront: storefront,
                                  catalogId: songId, albumId: nil)

        case "playlist":
            return AppleMusicLink(kind: .playlist, storefront: storefront,
                                  catalogId: nil, albumId: nil)

        default:
            return nil
        }
    }
}
