import Foundation

/// Phase 3 engine: catalog validation, library reconciliation, playlist
/// discovery, playlist state classification, and plan-driven, append-only
/// playlist insertion with fresh-read verification.
///
/// Invariants (docs/apple-music-integration-retrospective.md §10-§19):
///  1. Catalog IDs are authoritative identity — every comparison is by ID,
///     never by title matching.
///  2. A 202 library-add acknowledgment is never proof of presence; all
///     verification is by fresh reads.
///  3. Writes happen only in provably-safe playlist states (empty /
///     correctPrefix / exactComplete), as append-only operations, one at a
///     time, in manifest order, with the plan re-validated against a fresh
///     preflight before the first write.
///  4. The plan is derived once, executed exactly, and verified by an
///     independent full read-back.
///  5. At most one full library enumeration per phase (§12: never
///     full-scan the library per track); the catalog→library map is cached
///     for the run.
public final class RESTEngine: Sendable {

    public struct Config: Sendable {
        public var storefront: String
        public var maxLibraryPages: Int
        public var maxPlaylistPages: Int
        public var propagateDelayMilliseconds: Int
        public var verificationRetries: Int
        public var verificationBackoffMilliseconds: Int

        public init(storefront: String = "us",
                    maxLibraryPages: Int = 1000,
                    maxPlaylistPages: Int = 200,
                    propagateDelayMilliseconds: Int = 500,
                    verificationRetries: Int = 3,
                    verificationBackoffMilliseconds: Int = 1000) {
            self.storefront = storefront
            self.maxLibraryPages = maxLibraryPages
            self.maxPlaylistPages = maxPlaylistPages
            self.propagateDelayMilliseconds = propagateDelayMilliseconds
            self.verificationRetries = verificationRetries
            self.verificationBackoffMilliseconds = verificationBackoffMilliseconds
        }
    }

    public let config: Config
    private let transport: any AMTransport

    public init(transport: any AMTransport, config: Config = Config()) {
        self.transport = transport
        self.config = config
    }

    // MARK: - Catalog validation (Gate 3)

    /// Verifies every manifest catalog ID exists in the storefront catalog.
    /// `ok` requires HTTP 200 with a data payload — the exact gate of the
    /// proven run. Name divergence (§10 sanity check) is recorded but does
    /// not by itself fail the gate; it is review information.
    /// `notAuthorized` is set when any lookup failed with AMError.notAuthorized
    /// (§15: authorization loss is a distinct stop condition — the caller
    /// must stop for re-authorization, not report bad catalog entries).
    public func validateCatalog(manifest: ParsedManifest) async -> CatalogValidationReport {
        var entries: [CatalogValidationReport.Entry] = []
        var sawNotAuthorized = false
        for entry in manifest.entries {
            var ok = false
            var title: String?
            var artist: String?
            var status: Int?
            var reason: String?

            do {
                let (song, httpStatus) = try await transport.getCatalogSong(
                    catalogId: entry.catalogId, storefront: config.storefront)
                status = httpStatus
                if let song, let attributes = song.attributes {
                    title = attributes.name
                    artist = attributes.artistName
                    ok = httpStatus == 200 && song.id == String(entry.catalogId)
                } else {
                    reason = "no data payload (http \(httpStatus))"
                }
            } catch let error as AMError where error == .notAuthorized {
                sawNotAuthorized = true
                reason = "not authorized"
            } catch {
                reason = "transport: \(String(describing: error))"
            }

            let diverged = ok && title.map { RESTEngine.nameDiverges(entry.name, from: $0) } == true
            entries.append(CatalogValidationReport.Entry(
                pos: entry.pos, catalogId: entry.catalogId, expectedName: entry.name,
                ok: ok, nameDiverged: diverged, actualTitle: title,
                actualArtist: artist, httpStatus: status, reason: reason))
        }
        return CatalogValidationReport(entries: entries, notAuthorized: sawNotAuthorized)
    }

    /// Token-overlap divergence check — the same 0.5 bar as Phase 2's
    /// ResolutionEngine link cross-check. Classical titles vary in
    /// formatting, so overlap, not equality, is the bar.
    static func nameDiverges(_ provided: String, from actual: String) -> Bool {
        let pTokens = Set(MatchEngine.normalize(provided)
            .components(separatedBy: " ").filter { !$0.isEmpty })
        let aTokens = Set(MatchEngine.normalize(actual)
            .components(separatedBy: " ").filter { !$0.isEmpty })
        guard !pTokens.isEmpty, !aTokens.isEmpty else { return false }
        let shared = pTokens.intersection(aTokens)
        let ratio = Double(shared.count) / Double(min(pTokens.count, aTokens.count))
        return ratio < 0.5
    }

    // MARK: - Library enumeration + reconciliation

    /// Full library enumeration, once per transaction (§12). Returns
    /// catalogId -> librarySongId. First sighting wins, so the map is
    /// deterministic regardless of server ordering.
    public func enumerateLibrary() async throws -> [Int: String] {
        var out: [Int: String] = [:]
        var cursor: String? = nil
        var pages = 0
        repeat {
            let page = try await transport.getLibrarySongsPage(cursor: cursor)
            for song in page.items where song.catalogId != nil {
                out[song.catalogId!] = song.id
            }
            cursor = page.next
            pages += 1
            if pages > config.maxLibraryPages {
                throw AMError.paginationAborted(pages: pages)
            }
        } while cursor != nil
        return out
    }

    /// Reconciles the manifest against a library map: which manifest IDs are
    /// present (with library ids) and which are missing, in manifest order.
    public static func reconcile(manifest: ParsedManifest,
                                 library: [Int: String]) -> LibraryReconciliation {
        var present: [Int: String] = [:]
        var missing: [ManifestEntry] = []
        for entry in manifest.entries {
            if let libraryId = library[entry.catalogId], !libraryId.isEmpty {
                present[entry.catalogId] = libraryId
            } else {
                missing.append(entry)
            }
        }
        return LibraryReconciliation(present: present, missing: missing)
    }

    /// Adds the missing catalog songs to the library, one request per
    /// recording (§11), returning per-recording outcomes in manifest order.
    /// Throws on the first failure so the caller stops before proceeding.
    public func addMissingToLibrary(_ missing: [ManifestEntry]) async throws -> [LibraryAddOutcome] {
        var outcomes: [LibraryAddOutcome] = []
        for entry in missing {
            let status = try await transport.addCatalogSongToLibrary(catalogId: entry.catalogId)
            outcomes.append(LibraryAddOutcome(pos: entry.pos, catalogId: entry.catalogId,
                                              httpStatus: status))
            if !(200..<300).contains(status) {
                throw AMError.libraryAddFailed(catalogId: entry.catalogId, httpStatus: status)
            }
            if config.propagateDelayMilliseconds > 0 {
                try await Task.sleep(nanoseconds: UInt64(config.propagateDelayMilliseconds) * 1_000_000)
            }
        }
        return outcomes
    }

    /// Fresh-read library verification (§11 step 4-5). Re-enumerates the
    /// library and proves every manifest ID is present, with bounded
    /// retries and backoff. Never trusts the 202 acknowledgments.
    public func verifyLibrary(manifest: ParsedManifest) async -> LibraryVerification {
        var attempt = 0
        var missing: [Int] = []
        var map: [Int: String] = [:]
        while attempt < max(1, config.verificationRetries) {
            attempt += 1
            do {
                map = try await enumerateLibrary()
            } catch {
                // transport failure: retry with backoff; nothing fabricated
                if attempt >= max(1, config.verificationRetries) {
                    let allIds = manifest.entries.map(\.catalogId)
                    return LibraryVerification(verified: false, missingCatalogIds: allIds,
                                               attempts: attempt, catalogToLibraryId: map)
                }
                try? await Task.sleep(nanoseconds: UInt64(config.verificationBackoffMilliseconds) * 1_000_000)
                continue
            }
            missing = manifest.entries
                .filter { map[$0.catalogId] == nil }
                .map(\.catalogId)
            if missing.isEmpty {
                return LibraryVerification(verified: true, missingCatalogIds: [],
                                           attempts: attempt, catalogToLibraryId: map)
            }
            if attempt < config.verificationRetries {
                try? await Task.sleep(nanoseconds: UInt64(config.verificationBackoffMilliseconds) * 1_000_000)
            }
        }
        return LibraryVerification(verified: false, missingCatalogIds: missing,
                                   attempts: attempt, catalogToLibraryId: map)
    }

    // MARK: - Playlist discovery

    /// Finds library playlists with the exact name, following `next`
    /// pagination. Zero or many matches stop the transaction (§20: the
    /// target must be uniquely identifiable).
    public func findPlaylists(named exactName: String) async throws -> [PlaylistInfo] {
        var matches: [PlaylistInfo] = []
        var cursor: String? = nil
        var pages = 0
        repeat {
            let page = try await transport.getLibraryPlaylistsPage(cursor: cursor)
            for playlist in page.items {
                guard let name = playlist.attributes?.name, name == exactName else { continue }
                matches.append(PlaylistInfo(
                    id: playlist.id, name: name,
                    canEdit: playlist.attributes?.canEdit ?? false,
                    shareUrl: playlist.attributes?.shareUrl))
            }
            cursor = page.next
            pages += 1
            if pages > config.maxPlaylistPages {
                throw AMError.paginationAborted(pages: pages)
            }
        } while cursor != nil
        return matches
    }

    /// One uniquely-named, editable playlist, or a stop error (§20).
    /// Authorization loss surfaces as `.stop(.notAuthorized)` (§15), not
    /// as a generic transport failure.
    public func discoverPlaylist(named exactName: String) async -> PlaylistPreflightResult {
        let matches: [PlaylistInfo]
        do {
            matches = try await findPlaylists(named: exactName)
        } catch let error as AMError where error == .notAuthorized {
            return .stop(.notAuthorized)
        } catch {
            return .stop(.transport(String(describing: error)))
        }
        if matches.isEmpty {
            return .stop(.playlistNotFound(name: exactName))
        }
        guard matches.count == 1, let only = matches.first else {
            return .stop(.playlistAmbiguous(name: exactName, count: matches.count))
        }
        guard only.canEdit else {
            return .stop(.playlistNotEditable(playlistId: only.id))
        }
        return .ok(playlist: only, state: .empty, missingCatalogIds: [])
        // NOTE: state/missing are filled by preflightPlaylist, which also
        // reads tracks; discoverPlaylist only proves uniqueness + canEdit.
    }

    /// Creates a new library playlist. STRICT precondition: the caller must
    /// have already run discovery for this exact name and received
    /// `playlistNotFound` — i.e. creation is only legal when the name is
    /// proven uniquely absent. Never trust the 201 acknowledgment: the
    /// caller must re-run the full preflight (fresh reads) before any
    /// write; this method returns only what the server said.
    public func createPlaylist(named name: String) async throws -> (playlist: AMLibraryPlaylist?, httpStatus: Int) {
        try await transport.createPlaylist(named: name)
    }

    /// Direct fresh read of a playlist's stored tracks over the same
    /// transport (§16: verification reads, never mutation acknowledgments).
    public func readPlaylistTracks(playlistId: String) async throws -> [AMLibrarySong] {
        try await transport.getPlaylistTracks(playlistId: playlistId)
    }

    // MARK: - Playlist classification (§13)

    /// Classifies a playlist's stored sequence against the manifest.
    /// Pure function — deterministic and fully unit-testable.
    public static func classifyPlaylist(tracks: [AMLibrarySong],
                                        manifest: ParsedManifest) -> PlaylistState {
        let manifestIds = manifest.entries.map(\.catalogId)
        let trackIds = tracks.map(\.catalogId)
        let n = trackIds.count
        let m = manifestIds.count

        if n == 0 { return .empty }

        // Duplicate catalog IDs among identifiable tracks.
        var seen = Set<Int>()
        var duplicates = false
        for case let id? in trackIds where !seen.insert(id).inserted {
            duplicates = true
        }
        if duplicates { return .containsDuplicates }

        // Tracks whose identity exists but is not in the manifest.
        let unknown = trackIds.filter { $0 != nil && !manifestIds.contains($0!) }
        if !unknown.isEmpty { return .containsUnrelatedTracks }

        // Tracks carrying no catalog identity at all.
        if trackIds.contains(nil) { return .containsUnidentifiableTracks }

        // Longest common prefix with manifest order.
        var prefix = 0
        for i in 0..<min(n, m) where trackIds[i] == manifestIds[i] {
            prefix += 1
        }

        if n == m && prefix == m {
            return .exactComplete
        }
        if prefix == n && n < m {
            return .correctPrefix(count: n)
        }
        return .wrongOrder
    }

    /// The catalog IDs the playlist is missing, in manifest order, given a
    /// safe prefix state.
    public static func missingSuffix(state: PlaylistState,
                                     manifest: ParsedManifest) -> [Int] {
        switch state {
        case .empty:
            return manifest.entries.map(\.catalogId)
        case .correctPrefix(let count):
            return manifest.entries.dropFirst(count).map(\.catalogId)
        default:
            return []
        }
    }

    // MARK: - Preflight

    /// Full playlist preflight: discovery (unique name, canEdit), track
    /// read, classification, and missing-suffix derivation. Returns
    /// `.stop` on any §20 stop condition.
    public func preflightPlaylist(named exactName: String,
                                  manifest: ParsedManifest) async -> PlaylistPreflightResult {
        let discovery = await discoverPlaylist(named: exactName)
        guard case .ok(let info, _, _) = discovery else {
            if case .stop(let error) = discovery { return .stop(error) }
            return .stop(.playlistNotFound(name: exactName))
        }
        let tracks: [AMLibrarySong]
        do {
            tracks = try await transport.getPlaylistTracks(playlistId: info.id)
        } catch let error as AMError where error == .notAuthorized {
            return .stop(.notAuthorized)
        } catch {
            return .stop(.transport(String(describing: error)))
        }
        let state = RESTEngine.classifyPlaylist(tracks: tracks, manifest: manifest)
        guard state.isSafeToWrite else {
            return .stop(.playlistNotSafeToWrite(playlistId: info.id, state: state))
        }
        return .ok(playlist: info, state: state,
                   missingCatalogIds: RESTEngine.missingSuffix(state: state, manifest: manifest))
    }

    // MARK: - Plan derivation

    /// Derives the immutable append plan: the manifest suffix after the
    /// playlist's correct prefix, each paired with its verified library
    /// song ID. Fails if any required library ID is unknown — the caller
    /// must reconcile the library first (§19: reconcile before any writes).
    public static func deriveAppendPlan(preflight: PlaylistPreflightResult,
                                        manifest: ParsedManifest,
                                        library: [Int: String]) -> Result<AppendPlan, AMError> {
        guard case .ok(let info, let state, _) = preflight else {
            if case .stop(let error) = preflight {
                return .failure(error)
            }
            return .failure(.playlistNotFound(name: ""))
        }
        let suffix: [ManifestEntry]
        switch state {
        case .empty:
            suffix = manifest.entries
        case .correctPrefix(let count):
            suffix = Array(manifest.entries.dropFirst(count))
        case .exactComplete:
            return .success(AppendPlan(playlistId: info.id, playlistName: info.name,
                                       manifestCatalogIds: manifest.entries.map(\.catalogId),
                                       steps: []))
        default:
            return .failure(.playlistNotSafeToWrite(playlistId: info.id, state: state))
        }
        var steps: [AppendPlan.Step] = []
        for entry in suffix {
            guard let libraryId = library[entry.catalogId], !libraryId.isEmpty else {
                return .failure(.librarySongMissing(catalogId: entry.catalogId))
            }
            steps.append(AppendPlan.Step(pos: entry.pos, catalogId: entry.catalogId,
                                        librarySongId: libraryId))
        }
        return .success(AppendPlan(playlistId: info.id, playlistName: info.name,
                                  manifestCatalogIds: manifest.entries.map(\.catalogId),
                                  steps: steps))
    }

    // MARK: - Plan execution (append-only, §14)

    /// Executes the plan exactly: one append per step, in manifest order,
    /// stopping on the first failure. Before the first append it re-runs a
    /// fresh preflight against the plan's own embedded manifest sequence
    /// and requires the playlist's stored count to match the plan's first
    /// position (no drift, no concurrent edits).
    ///
    /// `onStep` (optional) fires after each append attempt is recorded,
    /// BEFORE the step is proven — so an interrupting throw cannot lose the
    /// partial evidence (Phase 6 recovery builds its checkpoint from these
    /// outcomes; the last one is always the first unproven step).
    public func executeAppendPlan(_ plan: AppendPlan,
                                  named playlistName: String? = nil,
                                  onStep: ((AppendOutcome) -> Void)? = nil) async throws -> [AppendOutcome] {
        guard !plan.steps.isEmpty else { return [] }

        // Re-verify state against the plan (fail-closed on drift).
        let name = playlistName ?? plan.playlistName
        let manifest = ParsedManifest(entries: plan.manifestCatalogIds.enumerated().map { index, id in
            ManifestEntry(pos: index + 1, catalogId: id, name: "", artist: "",
                          album: nil, durationSeconds: nil, url: nil)
        })
        let fresh = await preflightPlaylist(named: name, manifest: manifest)
        guard case .ok(_, let freshState, _) = fresh else {
            if case .stop(let error) = fresh { throw error }
            throw AMError.playlistVerificationFailed(reason: "preflight re-check failed")
        }
        // The plan's first step must be exactly the next expected position:
        // the stored count must equal firstPos - 1 in manifest position terms.
        let firstPos = plan.steps.first!.pos
        let expectedStored: Int
        switch freshState {
        case .empty: expectedStored = 0
        case .correctPrefix(let count): expectedStored = count
        case .exactComplete: expectedStored = manifest.entries.count
        default:
            throw AMError.playlistNotSafeToWrite(playlistId: plan.playlistId, state: freshState)
        }
        guard expectedStored == firstPos - 1 else {
            throw AMError.playlistVerificationFailed(
                reason: "playlist drifted: stored \(expectedStored) tracks but plan appends pos \(firstPos)")
        }

        var outcomes: [AppendOutcome] = []
        // Tracks confirmed stored so far. Each step's write must be proven
        // by a fresh read before the next write is issued (§14: append the
        // exact track, re-verify state, continue only after the state is
        // known — never re-issue or advance on an uncertain write).
        var stored = expectedStored
        for step in plan.steps {
            let status = try await transport.appendLibrarySong(
                toPlaylist: plan.playlistId, librarySongId: step.librarySongId)
            let outcome = AppendOutcome(pos: step.pos, catalogId: step.catalogId,
                                        librarySongId: step.librarySongId,
                                        httpStatus: status)
            outcomes.append(outcome)
            onStep?(outcome)
            if !(200..<300).contains(status) {
                throw AMError.playlistAppendFailed(pos: step.pos, catalogId: step.catalogId,
                                                   librarySongId: step.librarySongId,
                                                   httpStatus: status)
            }
            if config.propagateDelayMilliseconds > 0 {
                try await Task.sleep(nanoseconds: UInt64(config.propagateDelayMilliseconds) * 1_000_000)
            }
            stored += 1
            try await verifyStoredPrefix(playlistId: plan.playlistId,
                                         manifest: manifest, expectedCount: stored)
        }
        return outcomes
    }

    /// Proves by fresh read that the playlist now stores exactly the first
    /// `expectedCount` manifest tracks, in order, with no duplicates or
    /// foreign entries. Bounded retries with backoff absorb propagation
    /// delay; a read that never confirms is a stop condition (§20), never
    /// a pass.
    private func verifyStoredPrefix(playlistId: String,
                                    manifest: ParsedManifest,
                                    expectedCount: Int) async throws -> Void {
        let maxAttempts = max(1, config.verificationRetries)
        var attempt = 0
        var lastState: PlaylistState?
        while attempt < maxAttempts {
            attempt += 1
            let tracks: [AMLibrarySong]
            do {
                tracks = try await transport.getPlaylistTracks(playlistId: playlistId)
            } catch {
                if attempt >= maxAttempts {
                    throw AMError.playlistVerificationFailed(
                        reason: "after appending \(expectedCount) tracks, tracks read failed: \(String(describing: error))")
                }
                try? await Task.sleep(nanoseconds: UInt64(config.verificationBackoffMilliseconds) * 1_000_000)
                continue
            }
            let state = RESTEngine.classifyPlaylist(tracks: tracks, manifest: manifest)
            lastState = state
            switch state {
            case .correctPrefix(let count) where count == expectedCount:
                return
            case .exactComplete where expectedCount == manifest.entries.count:
                return
            default:
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: UInt64(config.verificationBackoffMilliseconds) * 1_000_000)
                }
            }
        }
        throw AMError.playlistVerificationFailed(
            reason: "playlist stores \(lastState.map(String.init(describing:)) ?? "unreadable") after appending \(expectedCount) tracks; expected correct prefix \(expectedCount)")
    }

    // MARK: - Independent final verification (§16)

    /// Fresh, independent read-back of the playlist. Completion is defined
    /// by this read, not by any mutation acknowledgment. Pure over its
    /// inputs (deterministic, testable); the caller supplies fresh tracks.
    public static func verifyPlaylist(playlistId: String,
                                      manifest: ParsedManifest,
                                      tracks: [AMLibrarySong],
                                      shareUrl: String?) -> PlaylistVerification {
        let expected = manifest.entries.map(\.catalogId)
        let actual: [Int?] = tracks.map(\.catalogId)

        var counts: [Int: Int] = [:]
        for case let id? in actual {
            counts[id, default: 0] += 1
        }
        let duplicates = counts.filter { $0.value > 1 }
            .map(\.key).sorted()   // deterministic order
        let expectedSet = Set(expected)
        let unexpected = actual.compactMap { $0 }.filter { !expectedSet.contains($0) }
        let unidentifiable = actual.filter { $0 == nil }.count
        let orderingPass = actual.map { $0 ?? Int.min } == expected

        // Verified iff exact manifest sequence once each, nothing else.
        let verified = actual.count == expected.count
            && orderingPass
            && duplicates.isEmpty
            && unexpected.isEmpty
            && unidentifiable == 0

        return PlaylistVerification(
            playlistId: playlistId, expectedCatalogIds: expected, actualCatalogIds: actual,
            verified: verified, orderingPass: orderingPass, duplicates: duplicates,
            unexpectedCatalogIds: unexpected, unidentifiableTrackCount: unidentifiable,
            shareUrl: shareUrl)
    }
}
