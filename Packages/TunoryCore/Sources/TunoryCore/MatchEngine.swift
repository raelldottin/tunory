import Foundation

/// Deterministic matching between a pasted/query string and catalog
/// candidates. Exact identity is normalized title + artist-prefix match;
/// everything else is ranked but NEVER auto-picked (explicit review policy).
public struct MatchQuery: Equatable, Sendable {
    public let title: String
    public let artist: String?
    public let album: String?

    public init(title: String, artist: String?, album: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
    }
}

public struct RankedCandidate: Equatable, Sendable, Identifiable {
    public let candidate: SongCandidate
    public let score: Int
    public let isExact: Bool

    public var id: Int { candidate.catalogId }
}

public enum MatchEngine {

    // MARK: - Normalization

    /// Lowercase; strip punctuation and diacritic-insensitive folding; collapse
    /// whitespace. Idempotent by construction.
    public static func normalize(_ s: String) -> String {
        let lowered = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                locale: Locale(identifier: "en_US"))
        let allowed = lowered.unicodeScalars.filter { scalar in
            scalar == " " || (scalar.properties.isAlphabetic || scalar.properties.numericType != nil)
        }
        let collapsed = String(String.UnicodeScalarView(allowed))
        return collapsed
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // No trailing space → idempotent: normalize(normalize(x)) == normalize(x)
    }

    /// The leading artist segment before featured-actor separators
    /// ("Hilary Hahn, LSO & Sir Colin Davis" → "hilary hahn").
    /// Splits the ORIGINAL string (which still contains separators), then
    /// normalizes each side.
    public static func featuredPrefix(_ artist: String) -> String {
        let separators = [",", "&", " and ", " feat ", " ft ", " with ", " x "]
        var cut: String.Index? = artist.endIndex
        for sep in separators {
            var searchStart = artist.startIndex
            while let r = artist.range(of: sep, options: .caseInsensitive,
                                      range: searchStart..<artist.endIndex) {
                if r.lowerBound < (cut ?? artist.endIndex) {
                    cut = r.lowerBound
                }
                searchStart = r.upperBound
            }
        }
        if let cut, cut < artist.endIndex {
            let prefix = String(artist[..<cut]).trimmingCharacters(in: .whitespaces)
            if !prefix.isEmpty {
                return normalize(prefix)
            }
        }
        return normalize(artist)
    }

    // MARK: - Exact identity

    /// Exact match: normalized title equal AND normalized query artist equal
    /// to the candidate artist OR to its featured prefix.
    public static func isExact(_ candidate: SongCandidate, query: MatchQuery) -> Bool {
        let nTitle = normalize(candidate.title)
        let qTitle = normalize(query.title)
        guard nTitle == qTitle else { return false }
        guard let qArtist = query.artist, !qArtist.isEmpty else { return false }
        let nArtist = normalize(candidate.artistName)
        let prefix = featuredPrefix(candidate.artistName)
        return nArtist == normalize(qArtist) || prefix == normalize(qArtist)
    }

    // MARK: - Scoring (integer, deterministic)

    /// Scores a candidate against a query. Higher is better. Exact matches
    /// always outrank partial ones.
    public static func score(candidate: SongCandidate, query: MatchQuery) -> Int {
        let qTitle = normalize(query.title)
        let cTitle = normalize(candidate.title)

        var score = 0

        // Title component (0..50)
        if cTitle == qTitle {
            score += 50
        } else if cTitle.contains(qTitle) || qTitle.contains(cTitle) {
            score += 30
        } else if let ratio = substringRatio(needle: qTitle, haystack: cTitle), ratio >= 0.5 {
            score += Int(Double(ratio) * 20.0)
        }

        // Artist component (0..30)
        if let qArtist = query.artist, !qArtist.isEmpty {
            let qA = normalize(qArtist)
            let cA = normalize(candidate.artistName)
            let cPrefix = featuredPrefix(candidate.artistName)
            if cA == qA || cPrefix == qA {
                score += 30
            } else if cA.contains(qA) || qA.contains(cA) {
                score += 15
            } else if let ratio = substringRatio(needle: qA, haystack: cA), ratio >= 0.5 {
                score += Int(Double(ratio) * 10.0)
            }
        }

        // Album bonus (0..10)
        if let qAlbum = query.album, let cAlbum = candidate.albumTitle,
           normalize(cAlbum).contains(normalize(qAlbum)) {
            score += 10
        }

        return score
    }

    /// Fraction (0...1) of needle's characters present in order in haystack
    /// (longest-common-subsequence over normalized strings), or nil when
    /// either side is empty. Bounded work for adversarial inputs.
    private static func substringRatio(needle: String, haystack: String) -> Double? {
        guard !needle.isEmpty, !haystack.isEmpty else { return nil }
        let n = Array(needle)
        let h = Array(haystack)
        if n.count > 400 || h.count > 400 { return nil }
        var prev = [Int](repeating: 0, count: h.count + 1)
        for i in 1...n.count {
            var cur = [Int](repeating: 0, count: h.count + 1)
            for j in 1...h.count {
                cur[j] = n[i - 1] == h[j - 1] ? prev[j - 1] + 1 : max(prev[j], cur[j - 1])
            }
            prev = cur
        }
        return Double(prev[h.count]) / Double(n.count)
    }

    // MARK: - Ranking

    public static let defaultCandidateLimit = 5

    /// Ranks candidates deterministically:
    /// exact matches first, then descending score, then ascending catalog id
    /// as final tiebreak. Candidates with no title overlap at all are dropped.
    public static func rank(candidates: [SongCandidate],
                            query: MatchQuery,
                            limit: Int = defaultCandidateLimit) -> [RankedCandidate] {
        let qTitle = normalize(query.title)
        var scored: [(RankedCandidate)] = []
        for c in candidates {
            let s = score(candidate: c, query: query)
            let cTitle = normalize(c.title)
            // Drop candidates sharing no tokens with the query title.
            let qTokens = Set(qTitle.components(separatedBy: " "))
            let cTokens = Set(cTitle.components(separatedBy: " "))
            let overlap = !qTokens.intersection(cTokens).isEmpty
            let exact = isExact(c, query: query)
            guard overlap || exact else { continue }
            scored.append(RankedCandidate(candidate: c, score: s, isExact: exact))
        }
        let ranked = scored.sorted { a, b in
            if a.isExact != b.isExact { return a.isExact }
            if a.score != b.score { return a.score > b.score }
            return a.candidate.catalogId < b.candidate.catalogId
        }
        return Array(ranked.prefix(limit))
    }
}
