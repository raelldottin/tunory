import Foundation

/// Deterministic resolution pipeline over parsed lines.
///
/// Invariants (docs/apple-music-integration-retrospective.md §10, §19):
///  1. Catalog IDs are authoritative identity. A line carrying a song link
///     resolves strictly by ID — never by search.
///  2. Search never silently picks. Auto-resolve happens only when exactly
///     ONE exact title+artist match exists; anything else surfaces for
///     explicit human review.
///  3. A link ID whose resolved title diverges from the provided name is
///     flagged for review (id may be stale/wrong), never auto-accepted.
///  4. Review confirmation re-verifies the chosen ID against the catalog
///     before accepting it.
///  5. Line order is preserved end-to-end; one line's failure never blocks
///     another.
public final class ResolutionEngine: Sendable {

    /// Abstract catalog access so the engine is testable without MusicKit.
    public struct Sources: Sendable {
        /// Batch by-id lookup: returns the subset of ids that exist.
        public var resolveIds: @Sendable ([Int]) async -> [Int: ResolvedSong] = { _ in [:] }
        /// Catalog search for name-only lines.
        public var search: @Sendable (MatchQuery, Int) async -> [SongCandidate] = { _, _ in [] }

        public init() {}
    }

    private let sources: Sources
    private let confirmations: Confirmations

    /// Records human confirmations (pos -> chosen catalog id) for audit.
    /// `confirm` writes here; late/replay confirmations re-verify by ID.
    public final class Confirmations: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Int: Int] = [:]

        public init() {}

        public func record(pos: Int, catalogId: Int) {
            lock.lock(); defer { lock.unlock() }
            storage[pos] = catalogId
        }

        public func recorded(pos: Int) -> Int? {
            lock.lock(); defer { lock.unlock() }
            return storage[pos]
        }

        public var all: [Int: Int] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }

    public init(sources: Sources, confirmations: Confirmations = Confirmations()) {
        self.sources = sources
        self.confirmations = confirmations
    }

    // MARK: - Resolution

    public func resolve(lines: [ParsedLine]) async -> [LineResolution] {
        var results: [LineResolution] = []

        // Phase 1: batch-resolve all link lines by ID in one request.
        let linkIds = lines.compactMap { $0.catalogId }
        var byId: [Int: ResolvedSong] = [:]
        if !linkIds.isEmpty {
            byId = await sources.resolveIds(linkIds)
        }

        for line in lines {
            if let id = line.catalogId, line.kind == .link {
                results.append(resolveLinkLine(line, id: id, byId: byId))
                continue
            }
            // Name-only: search + explicit-review policy.
            let query = MatchQuery(title: line.title, artist: line.artistHint)
            let rawCandidates = await sources.search(query, MatchEngine.defaultCandidateLimit * 2)
            let ranked = MatchEngine.rank(candidates: rawCandidates, query: query)
            results.append(resolveNameLine(line, ranked: ranked))
        }
        return results
    }

    private func resolveLinkLine(_ line: ParsedLine, id: Int,
                                 byId: [Int: ResolvedSong]) -> LineResolution {
        guard let song = byId[id] else {
            return LineResolution(pos: line.pos, status: .unresolved,
                                   rawTitle: line.rawTitle, resolutionPath: .byCatalogId)
        }
        // Invariant 3: if a display name was provided and it diverges from the
        // resolved title, surface for review instead of trusting the ID.
        if providedNameDiverges(line.rawTitle, resolvedTitle: song.title) {
            return LineResolution(pos: line.pos, status: .needsReview,
                                   rawTitle: line.rawTitle,
                                   resolvedSong: song,
                                   candidates: [SongCandidate(catalogId: song.catalogId,
                                                               title: song.title,
                                                               artistName: song.artistName,
                                                               albumTitle: song.albumTitle,
                                                               durationMilliseconds: song.durationMilliseconds)],
                                   resolutionPath: .byCatalogId)
        }
        return LineResolution(pos: line.pos, status: .resolved,
                              rawTitle: line.rawTitle, resolvedSong: song,
                              resolutionPath: .byCatalogId)
    }

    /// Divergence check: significant token overlap required between the
    /// provided name and the resolved title. Classical titles vary in
    /// formatting, so the bar is token overlap, not equality.
    private func providedNameDiverges(_ provided: String, resolvedTitle: String) -> Bool {
        let pTokens = Set(MatchEngine.normalize(provided)
            .components(separatedBy: " ").filter { !$0.isEmpty })
        let rTokens = Set(MatchEngine.normalize(resolvedTitle)
            .components(separatedBy: " ").filter { !$0.isEmpty })
        guard !pTokens.isEmpty, !rTokens.isEmpty else { return false }
        let shared = pTokens.intersection(rTokens)
        let denominator = Double(min(pTokens.count, rTokens.count))
        let ratio = Double(shared.count) / denominator
        return ratio < 0.5
    }

    private func resolveNameLine(_ line: ParsedLine,
                                 ranked: [RankedCandidate]) -> LineResolution {
        guard !ranked.isEmpty else {
            return LineResolution(pos: line.pos, status: .unresolved,
                                  rawTitle: line.rawTitle, resolutionPath: .bySearchReview)
        }
        // Invariant 2: auto-resolve only when the line carries an artist hint
        // AND exactly one exact title+artist match exists. Bare titles never
        // auto-resolve — that is precisely the fuzzy title-matching the
        // retrospective rejects for classical repertoire.
        let exacts = ranked.filter(\.isExact)
        if let hint = line.artistHint, !hint.isEmpty, exacts.count == 1, let only = exacts.first {
            return LineResolution(pos: line.pos, autoResolvedWith: only, rawTitle: line.rawTitle)
        }
        // Everything else needs review, ranked list attached.
        let candidates = ranked.map(\.candidate)
        return LineResolution(pos: line.pos, status: .needsReview,
                              rawTitle: line.rawTitle, candidates: candidates,
                              resolutionPath: .bySearchReview)
    }

    // MARK: - Review confirmation

    /// Applies a human review decision. Fail-closed policy:
    ///  1. The chosen id must be in the prior ranked candidate list.
    ///  2. The id is ALWAYS re-verified by catalog lookup — never trusted
    ///     from the candidate snapshot (which may be stale or adversarially
    ///     substituted upstream).
    public func confirm(pos: Int, candidateId: Int, line: ParsedLine,
                        prior: LineResolution) async -> LineResolution {
        confirmations.record(pos: pos, catalogId: candidateId)

        guard let inList = prior.candidates?.first(where: { $0.catalogId == candidateId }) else {
            return LineResolution(pos: pos, status: .needsReview, rawTitle: line.rawTitle,
                                  candidates: prior.candidates, resolutionPath: .byReviewConfirmation)
        }
        _ = inList  // membership checked; data deliberately NOT trusted

        let looked = await sources.resolveIds([candidateId])
        guard let song = looked[candidateId] else {
            return LineResolution(pos: pos, status: .needsReview, rawTitle: line.rawTitle,
                                  candidates: prior.candidates, resolutionPath: .byReviewConfirmation)
        }
        return LineResolution(pos: pos, status: .resolved, rawTitle: line.rawTitle,
                              resolvedSong: song, candidates: prior.candidates,
                              resolutionPath: .byReviewConfirmation)
    }

    public var recordedConfirmations: [Int: Int] {
        confirmations.all
    }
}

extension LineResolution {
    init(pos: Int, autoResolvedWith ranked: RankedCandidate, rawTitle: String) {
        let c = ranked.candidate
        self.init(pos: pos, status: .resolved, rawTitle: rawTitle,
                  resolvedSong: ResolvedSong(catalogId: c.catalogId, title: c.title,
                                              artistName: c.artistName, albumTitle: c.albumTitle,
                                              durationMilliseconds: c.durationMilliseconds),
                  resolutionPath: .bySearchExactMatch)
    }
}
