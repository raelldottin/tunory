import XCTest
@testable import TunoryCore

final class MatchEngineTests: XCTestCase {

    private func candidate(_ title: String, _ artist: String, _ album: String? = nil,
                           catalogId: Int = 1) -> SongCandidate {
        SongCandidate(catalogId: catalogId, title: title, artistName: artist, albumTitle: album)
    }

    func testExactMatchRequiresBothTitleAndArtistNormalized() {
        let query = MatchQuery(title: "the lark ascending", artist: "hilary hahn")
        let exact = candidate("The Lark Ascending", "Hilary Hahn")
        let wrongTitle = candidate("Lark Ascending", "Hilary Hahn")
        let wrongArtist = candidate("The Lark Ascending", "Hilary Hahn Trio")
        XCTAssertTrue(MatchEngine.isExact(exact, query: query))
        XCTAssertFalse(MatchEngine.isExact(wrongTitle, query: query))
        XCTAssertFalse(MatchEngine.isExact(wrongArtist, query: query))
    }

    func testExactMatchWithFeaturedArtistSuffix() {
        // "Hilary Hahn, London Symphony Orchestra & Sir Colin Davis" vs query "hilary hahn"
        let query = MatchQuery(title: "the lark ascending", artist: "hilary hahn")
        let c = candidate("The Lark Ascending", "Hilary Hahn, London Symphony Orchestra & Sir Colin Davis")
        XCTAssertTrue(MatchEngine.isExact(c, query: query))
    }

    func testNormalizationIgnoresPunctuationAndCase() {
        let query = MatchQuery(title: "sonata for violin solo no 1 in g minor bwv 1001 iii siciliana", artist: "hilary hahn")
        let c = candidate("Sonata for Violin Solo No. 1 in G Minor, BWV 1001: III. Siciliana", "Hilary Hahn")
        XCTAssertTrue(MatchEngine.isExact(c, query: query))
    }

    func testFeaturedSuffixOnlyCountsAsExactWhenQueryArtistIsPrefix() {
        let query = MatchQuery(title: "mercy", artist: "hilary hahn")
        let featuring = candidate("Mercy", "Hilary Hahn & Cory Smythe")
        XCTAssertTrue(MatchEngine.isExact(featuring, query: query))
        let notPrefix = candidate("Mercy", "Cory Smythe & Hilary Hahn")
        XCTAssertFalse(MatchEngine.isExact(notPrefix, query: query))
    }

    func testScoreOrdersExactAbovePartial() {
        let query = MatchQuery(title: "the lark ascending", artist: "hilary hahn")
        let exact = candidate("The Lark Ascending", "Hilary Hahn", catalogId: 1)
        let partial = candidate("The Lark Ascending", "Someone Else", catalogId: 2)
        XCTAssertGreaterThan(
            MatchEngine.score(candidate: exact, query: query),
            MatchEngine.score(candidate: partial, query: query))
    }

    func testRankExactFirstThenScoreThenCatalogIdTiebreak() {
        let query = MatchQuery(title: "mercy", artist: "hilary hahn")
        let cands = [
            candidate("Mercy", "Hilary Hahn & Cory Smythe", catalogId: 30),
            candidate("Mercy", "Hilary Hahn & Cory Smythe", catalogId: 10),
            candidate("Mercy Dance", "Hilary Hahn", catalogId: 5),
            candidate("Mercy", "Nobody", catalogId: 3),
        ]
        let ranked = MatchEngine.rank(candidates: cands, query: query)
        XCTAssertEqual(ranked[0].candidate.catalogId, 10)
        XCTAssertEqual(ranked[1].candidate.catalogId, 30)
        let scores = ranked.map(\.score)
        let tail = scores.dropFirst(2)
        XCTAssertTrue(zip(tail, tail.dropFirst()).allSatisfy(>=),
                      "tail must be non-increasing: \(scores)")
    }

    func testRankLimitsCandidateCount() {
        let query = MatchQuery(title: "x", artist: "y")
        let cands = (1...25).map { candidate("X \($0)", "Y") }
        let ranked = MatchEngine.rank(candidates: cands, query: query, limit: 5)
        XCTAssertEqual(ranked.count, 5)
    }

    func testRankDropsUnrelatedCandidates() {
        let query = MatchQuery(title: "the lark ascending", artist: "hilary hahn")
        let unrelated = candidate("Completely Unrelated Song", "Unknown Artist")
        XCTAssertTrue(MatchEngine.rank(candidates: [unrelated], query: query).isEmpty)
    }

    func testRankEmptyInput() {
        XCTAssertEqual(MatchEngine.rank(candidates: [], query: MatchQuery(title: "a", artist: "b")), [])
    }

    func testRankIsInputOrderIndependent() {
        let query = MatchQuery(title: "mercy", artist: "hilary hahn")
        let base = [
            candidate("Mercy", "Hilary Hahn & Cory Smythe", catalogId: 30),
            candidate("Mercy", "Hilary Hahn & Cory Smythe", catalogId: 10),
            candidate("Mercy Dance", "Hilary Hahn", catalogId: 5),
            candidate("Mercy", "Nobody", catalogId: 3),
        ]
        let reference = MatchEngine.rank(candidates: base, query: query).map(\.candidate.catalogId)
        for seed in 0..<20 {
            var rng = SeededGenerator(seed: UInt64(seed))
            let shuffled = base.shuffled(using: &rng)
            let out = MatchEngine.rank(candidates: shuffled, query: query).map(\.candidate.catalogId)
            XCTAssertEqual(out, reference, "rank must be input-order independent (seed \(seed))")
        }
    }

    func testNormalizationIsIdempotentAndStripsPunctuation() {
        let adversarial = [
            "Sonata for Violin Solo No. 1 in G Minor, BWV 1001: III. Siciliana",
            "Sofðu unga ástin mín (arr. Jarle Storløkken)",
            "3 Gymnopédies: III. Lent et grave",
            "Den första gång jag såg dig (arr. Helseth & Nordstoga)",
            "  weird \t spacing and nbsp chars ",
            "EM-DASH — and “smart quotes” 'single'",
            "14 Songs, Op. 34: No. 14, Vocalise",
        ]
        for raw in adversarial {
            let once = MatchEngine.normalize(raw)
            let twice = MatchEngine.normalize(once)
            XCTAssertEqual(once, twice, "normalization must be idempotent for: \(raw)")
            XCTAssertFalse(once.contains(where: { ".,:;!?()[]\"'".contains($0) }),
                           "punctuation should be stripped for: \(raw)")
        }
    }

    func testFeaturedArtistSplit() {
        XCTAssertEqual(MatchEngine.featuredPrefix("Hilary Hahn, London Symphony Orchestra & Sir Colin Davis"),
                       "hilary hahn")
        XCTAssertEqual(MatchEngine.featuredPrefix("Hilary Hahn & Cory Smythe"), "hilary hahn")
        XCTAssertEqual(MatchEngine.featuredPrefix("Solo Artist"), "solo artist")
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var x = state
        x ^= x >> 12
        x ^= x << 25
        x ^= x >> 27
        return x &* 2685821657736338717
    }
}
