import XCTest
@testable import TunoryCore

final class ResolutionEngineTests: XCTestCase {

    /// Deterministic stub sources: ids >= 100 resolve; anything else 404s.
    private func stubSong(_ id: Int) -> ResolvedSong {
        ResolvedSong(catalogId: id, title: "Song \(id)", artistName: "Artist \(id)",
                     albumTitle: "Album \(id)", durationMilliseconds: 200_000)
    }

    private func makeEngine(search: @escaping (MatchQuery, Int) -> [SongCandidate]) -> ResolutionEngine {
        var sources = ResolutionEngine.Sources()
        sources.resolveIds = { ids in
            var out: [Int: ResolvedSong] = [:]
            for id in ids where id >= 100 {
                out[id] = ResolvedSong(catalogId: id, title: "Song \(id)", artistName: "Artist \(id)",
                                       albumTitle: "Album \(id)", durationMilliseconds: 200_000)
            }
            return out
        }
        sources.search = search
        return ResolutionEngine(sources: sources)
    }

    private func linkLine(_ pos: Int, _ id: Int) -> ParsedLine {
        ParsedLine(pos: pos, rawTitle: "Song \(id)", kind: .link, catalogId: id,
                   link: AppleMusicLink(kind: .song, storefront: "us", catalogId: id, albumId: nil))
    }

    // MARK: link resolution

    func testLinkLineResolvesByIdWithoutSearch() async {
        var searchCalls = 0
        let engine = makeEngine { _, _ in
            searchCalls += 1
            return []
        }
        let results = await engine.resolve(lines: [linkLine(1, 500)])
        XCTAssertEqual(searchCalls, 0, "explicit catalog id must bypass search")
        XCTAssertEqual(results[0].status, .resolved)
        XCTAssertEqual(results[0].resolvedSong?.catalogId, 500)
        XCTAssertEqual(results[0].resolutionPath, .byCatalogId)
    }

    func testLinkLineWithDeadIdIsUnresolved() async {
        let engine = makeEngine { _, _ in [] }
        let results = await engine.resolve(lines: [linkLine(1, 42)])
        XCTAssertEqual(results[0].status, .unresolved)
        XCTAssertEqual(results[0].resolutionPath, .byCatalogId)
    }

    func testUnresolvedLinkDoesNotBlockOtherLines() async {
        let engine = makeEngine { _, _ in [] }
        let results = await engine.resolve(lines: [linkLine(1, 40), linkLine(2, 200)])
        XCTAssertEqual(results[0].status, .unresolved)
        XCTAssertEqual(results[1].status, .resolved)
    }

    // MARK: name-only resolution (explicit review policy)

    func testNameOnlyLineWithSingleExactMatchResolves() async {
        let engine = makeEngine { q, _ in
            [SongCandidate(catalogId: 100, title: q.title, artistName: q.artist ?? "Artist")]
        }
        // Line WITH artist hint: single exact match → auto-resolve.
        let line = ParsedLine(pos: 1, rawTitle: "Song 100 - Artist 100", kind: .name,
                              catalogId: nil, artistHint: "Artist 100", title: "Song 100")
        let results = await engine.resolve(lines: [line])
        XCTAssertEqual(results[0].status, .resolved)
        XCTAssertEqual(results[0].resolutionPath, .bySearchExactMatch)
    }

    func testBareTitleNeverAutoResolvesEvenWithSingleExactCandidate() async {
        // No artist hint: even a single exact candidate must go to review.
        // Bare-title auto-pick is exactly the fuzzy matching the
        // retrospective forbids (two BWV 1041 Andante performances).
        let engine = makeEngine { q, _ in
            [SongCandidate(catalogId: 100, title: q.title, artistName: "Hilary Hahn")]
        }
        let line = ParsedLine(pos: 1, rawTitle: "Mercy", kind: .name, catalogId: nil)
        let results = await engine.resolve(lines: [line])
        XCTAssertEqual(results[0].status, .needsReview)
        XCTAssertEqual(results[0].candidates?.count, 1)
    }

    func testNameOnlyLineWithAmbiguousMatchesRequiresReview() async {
        let engine = makeEngine { q, _ in
            [
                SongCandidate(catalogId: 100, title: q.title, artistName: q.artist ?? "Artist"),
                SongCandidate(catalogId: 200, title: q.title, artistName: q.artist ?? "Artist"),
            ]
        }
        let line = ParsedLine(pos: 1, rawTitle: "Mercy", kind: .name, catalogId: nil)
        let results = await engine.resolve(lines: [line])
        XCTAssertEqual(results[0].status, .needsReview)
        XCTAssertEqual(results[0].candidates?.map(\.catalogId), [100, 200])
        XCTAssertEqual(results[0].resolutionPath, .bySearchReview)
    }

    func testNameOnlyLineWithMultipleExactMatchesRequiresReview() async {
        // Two candidates BOTH exactly match title+artist (different catalog
        // ids, e.g. same recording on two albums). Never auto-pick.
        let engine = makeEngine { q, _ in
            [
                SongCandidate(catalogId: 100, title: q.title, artistName: q.artist ?? "Artist"),
                SongCandidate(catalogId: 101, title: q.title, artistName: q.artist ?? "Artist"),
            ]
        }
        let line = ParsedLine(pos: 1, rawTitle: "Mercy", kind: .name, catalogId: nil)
        let results = await engine.resolve(lines: [line])
        XCTAssertEqual(results[0].status, .needsReview)
    }

    func testNameOnlyLineWithNoCandidatesUnresolved() async {
        let engine = makeEngine { _, _ in [] }
        let results = await engine.resolve(lines: [ParsedLine(pos: 1, rawTitle: "Nothing", kind: .name, catalogId: nil)])
        XCTAssertEqual(results[0].status, .unresolved)
    }

    func testNameOnlyLineWithOnlyNonExactCandidatesRequiresReview() async {
        // Candidates exist but none is an exact match: surface for review,
        // never silently pick the top search result.
        let engine = makeEngine { q, _ in
            [SongCandidate(catalogId: 100, title: q.title + " (Live)", artistName: q.artist ?? "Artist")]
        }
        let line = ParsedLine(pos: 1, rawTitle: "Mercy", kind: .name, catalogId: nil)
        let results = await engine.resolve(lines: [line])
        XCTAssertEqual(results[0].status, .needsReview)
        XCTAssertEqual(results[0].candidates?.count, 1)
    }

    // MARK: ordering & batching

    func testResolutionPreservesInputOrder() async {
        let engine = makeEngine { q, _ in
            [SongCandidate(catalogId: 100, title: q.title, artistName: q.artist ?? "Artist")]
        }
        let lines = (1...10).map { ParsedLine(pos: $0, rawTitle: "Song \($0)", kind: .name, catalogId: nil) }
        let results = await engine.resolve(lines: lines)
        XCTAssertEqual(results.map(\.pos), Array(1...10))
    }

    func testResolveByIdsIsCalledOnceForAllLinkLines() async {
        // Batching invariant: one by-id request for the whole batch.
        var resolveCalls = 0
        var sources = ResolutionEngine.Sources()
        sources.resolveIds = { ids in
            resolveCalls += 1
            var out: [Int: ResolvedSong] = [:]
            for id in ids where id >= 100 {
                out[id] = ResolvedSong(catalogId: id, title: "S\(id)", artistName: "A\(id)",
                                       albumTitle: nil, durationMilliseconds: 1000)
            }
            return out
        }
        sources.search = { _, _ in [] }
        let engine = ResolutionEngine(sources: sources)
        let lines = (1...5).map { linkLine($0, 100 + $0) }
        _ = await engine.resolve(lines: lines)
        XCTAssertEqual(resolveCalls, 1, "by-id resolution must be batched")
    }

    // MARK: manifest verification (sanity-check strings vs catalog record)

    func testLinkResolutionCrossChecksTitleWhenManifestProvidesName() async {
        // If the manifest/paste carries a name and the resolved catalog song
        // title diverges wildly, flag for review instead of trusting the id.
        var sources = ResolutionEngine.Sources()
        sources.resolveIds = { _ in
            [999: ResolvedSong(catalogId: 999, title: "Totally Different Title",
                               artistName: "Someone Else", albumTitle: nil, durationMilliseconds: 1000)]
        }
        sources.search = { _, _ in [] }
        let engine = ResolutionEngine(sources: sources)
        let line = ParsedLine(pos: 1, rawTitle: "Expected Song Name", kind: .link, catalogId: 999,
                              link: AppleMusicLink(kind: .song, storefront: "us", catalogId: 999, albumId: nil))
        let results = await engine.resolve(lines: [line])
        XCTAssertEqual(results[0].status, .needsReview,
                       "id/name divergence must surface for review, not auto-accept")
    }

    // MARK: review confirmation

    func testConfirmPicksCandidateFromRankedList() async {
        let engine = makeEngine { _, _ in [] }
        let line = ParsedLine(pos: 3, rawTitle: "Ambiguous", kind: .name, catalogId: nil)
        let prior = LineResolution(pos: 3, status: .needsReview, rawTitle: "Ambiguous",
                                   candidates: [SongCandidate(catalogId: 100, title: "Ambiguous", artistName: "A"),
                                                SongCandidate(catalogId: 200, title: "Ambiguous", artistName: "B")])
        let after = await engine.confirm(pos: 3, candidateId: 200, line: line, prior: prior)
        XCTAssertEqual(after.status, .resolved)
        XCTAssertEqual(after.resolvedSong?.catalogId, 200)
        XCTAssertEqual(after.resolutionPath, .byReviewConfirmation)
    }

    func testConfirmRejectsCandidateOutsideRankedList() async {
        let engine = makeEngine { _, _ in [] }
        let line = ParsedLine(pos: 1, rawTitle: "X", kind: .name, catalogId: nil)
        let prior = LineResolution(pos: 1, status: .needsReview, rawTitle: "X",
                                   candidates: [SongCandidate(catalogId: 100, title: "X", artistName: "A")])
        let after = await engine.confirm(pos: 1, candidateId: 999, line: line, prior: prior)
        XCTAssertEqual(after.status, .needsReview, "unranked candidate must be rejected")
    }

    func testConfirmOnDeadIdStaysNeedsReview() async {
        let engine = makeEngine { _, _ in [] }
        let line = ParsedLine(pos: 1, rawTitle: "Dead", kind: .name, catalogId: nil)
        let prior = LineResolution(pos: 1, status: .needsReview, rawTitle: "Dead",
                                   candidates: [SongCandidate(catalogId: 42, title: "Dead", artistName: "A")])
        let after = await engine.confirm(pos: 1, candidateId: 42, line: line, prior: prior)
        // Fail-closed policy: dead id keeps the line in review (the human
        // must see the failure and re-pick); it is not silently dropped.
        XCTAssertEqual(after.status, .needsReview)
        XCTAssertEqual(after.candidates?.count, 1, "ranked list must survive a failed confirm")
    }

    // MARK: end-to-end over the real manifest fixture

    func testRealManifestResolvesAll17ByLinks() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/valid-manifest.json")
        let data = try Data(contentsOf: url)
        let manifest = try ManifestParser.parse(data: data)
        XCTAssertEqual(manifest.entries.count, 17)

        // Stub echoes each manifest entry's real title/artist for its id, so
        // the id/name cross-check passes — as it would with the real catalog.
        let byName = Dictionary(uniqueKeysWithValues:
            manifest.entries.map { ($0.catalogId, $0) })
        var sources = ResolutionEngine.Sources()
        sources.resolveIds = { ids in
            var out: [Int: ResolvedSong] = [:]
            for id in ids {
                guard let e = byName[id] else { continue }
                out[id] = ResolvedSong(catalogId: id, title: e.name, artistName: e.artist,
                                       albumTitle: e.album,
                                       durationMilliseconds: e.durationSeconds.map { $0 * 1000 })
            }
            return out
        }
        sources.search = { _, _ in [] }
        let engine = ResolutionEngine(sources: sources)

        let lines = manifest.entries.map { entry in
            ParsedLine(pos: entry.pos, rawTitle: entry.name, kind: .link, catalogId: entry.catalogId,
                       link: AppleMusicLink(kind: .song, storefront: "us", catalogId: entry.catalogId,
                                            albumId: nil))
        }
        let results = await engine.resolve(lines: lines)
        XCTAssertEqual(results.count, 17)
        XCTAssertTrue(results.allSatisfy { $0.status == .resolved },
                      "all 17 real manifest ids must resolve: \(results.map(\.status))")
        XCTAssertEqual(results.map(\.pos), Array(1...17))
    }
}
