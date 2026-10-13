import XCTest
@testable import TunoryCore

/// Phase 6: comprehensive test suite for the canonical transaction, one
/// file per required scenario (task t_7fc0d343). Every scenario drives the
/// canonical §20 sequence through TransactionRunner / RESTEngine over the
/// deterministic StubTransport — the same engines the GUI and CLI run, so
/// nothing here re-implements product decisions. Recovery scenarios use the
/// credential-free TransactionCheckpoint + RecoveryPlanner.
final class Phase6ScenarioTests: XCTestCase {

    private func makeRunner(_ transport: StubTransport) -> TransactionRunner {
        TransactionRunner(engine: RESTEngine(transport: transport, config: .init(
            storefront: "us",
            maxLibraryPages: 100,
            maxPlaylistPages: 20,
            propagateDelayMilliseconds: 0,
            verificationRetries: 3,
            verificationBackoffMilliseconds: 0,
            appendVerificationRetries: 3,
            appendVerificationBackoffMilliseconds: 0,
            createRediscoveryRetries: 3,
            createRediscoveryBackoffMilliseconds: 0)))
    }

    private func transportFor(ids: [Int], playlistName: String,
                              libraryHas: [Int],
                              playlistTracks: [Int] = []) -> StubTransport {
        let manifest = Fixtures.manifest(ids: ids)
        let t = Fixtures.happyPathTransport(manifest: manifest,
                                            playlistName: playlistName,
                                            libraryHas: libraryHas)
        t.addsBecomeVisibleInLibrary = true
        t.playlistTracks["p.test"] = playlistTracks.map {
            Fixtures.librarySong(libraryId: "i.\($0)", catalogId: $0)
        }
        return t
    }

    // MARK: - Scenario 1: wrong-performer rejection
    //
    // §10/§11: catalog IDs are authoritative identity, but a catalog ID
    // that resolves to a DIFFERENT performer than the manifest claims is
    // exactly the "wrong performer" trap. The engine must surface the
    // divergence (nameDiverged) for review — never silently accept it,
    // never silently fail the existence gate either. And when the
    // manifest's own identity is wrong (catalog ID absent), Gate 3 must
    // stop the whole transaction before any write.
    func testWrongPerformerSurfacesAsDivergenceAndStopsBeforeWrites() async {
        // Case A: catalog ID exists but names a different recording/artist
        // than the manifest claims → gate passes (id is authoritative),
        // divergence is RECORDED for review.
        let manifestA = Fixtures.manifest(ids: [101])
        let t = transportFor(ids: [101], playlistName: "P", libraryHas: [101])
        t.catalogSongs[101] = Fixtures.catalogSong(
            catalogId: 101, name: "Completely Different Recording", artist: "Someone Else Entirely")
        let engine = RESTEngine(transport: t, config: .init(
            storefront: "us", propagateDelayMilliseconds: 0,
            verificationRetries: 1, verificationBackoffMilliseconds: 0))
        let reportA = await engine.validateCatalog(manifest: manifestA)
        XCTAssertTrue(reportA.passed, "existence gate keyed on ID, not text")
        XCTAssertTrue(reportA.entries[0].nameDiverged, "divergence must surface for review")

        // Case B: the manifest claims a performer/recording that does not
        // exist in the catalog at all (the practical wrong-performer
        // failure after research) → Gate 3 stops; ZERO writes anywhere.
        let ids = [101, 999999]
        let t2 = transportFor(ids: ids, playlistName: "P", libraryHas: ids)
        t2.catalogSongs[999999] = nil
        let manifestB = Fixtures.manifest(ids: ids)
        let report = await makeRunner(t2).run(manifest: manifestB, playlistName: "P")

        XCTAssertFalse(report.succeeded)
        guard case .catalogLookupFailed(let id, _)? = report.phases.last?.error else {
            return XCTFail("expected catalogLookupFailed, got \(report.phases)")
        }
        XCTAssertEqual(id, 999999)
        XCTAssertEqual(t2.calls.filter { $0.name == "append" }.count, 0)
        XCTAssertEqual(t2.calls.filter { $0.name == "libraryAdd" }.count, 0)
        XCTAssertEqual(t2.calls.filter { $0.name == "createPlaylist" }.count, 0)
        XCTAssertEqual(t2.calls.filter { $0.name == "playlistTracks" }.count, 0)
    }

    // MARK: - Scenario 2: album IDs mistaken for songs
    //
    // §10 link discipline: an album link carries NO song catalog id. The
    // parser must never promote the album id to song identity, a malformed
    // ?i= must fail the whole parse (not degrade to album), and a manifest
    // line carrying an album link as its URL stays valid only because the
    // authoritative catalogId field is separate. The transaction appends
    // by the manifest's catalog ID — never by an album id.
    func testAlbumIDsAreNeverMistakenForSongIdentity() async throws {
        // Album link: kind .album, catalogId nil — album id is NOT song id.
        let album = try XCTUnwrap(AppleMusicLink.parse(
            "https://music.apple.com/us/album/mercy/1440767384"))
        XCTAssertEqual(album.kind, .album)
        XCTAssertEqual(album.albumId, 1440767384)
        XCTAssertNil(album.catalogId, "album id must never masquerade as song identity")

        // Album-style URL WITH ?i= is a SONG link whose albumId is separate.
        let songInAlbum = try XCTUnwrap(AppleMusicLink.parse(
            "https://music.apple.com/us/album/mercy/1440767384?i=1440767734"))
        XCTAssertEqual(songInAlbum.kind, .song)
        XCTAssertEqual(songInAlbum.catalogId, 1440767734)
        XCTAssertEqual(songInAlbum.albumId, 1440767384)

        // Malformed ?i= fails the whole parse: no silent degradation.
        XCTAssertNil(AppleMusicLink.parse(
            "https://music.apple.com/us/album/mercy/1440767384?i=notanumber"))

        // A pasted album link becomes a link-kind line whose catalog id is
        // nil (AppleMusicLink parses; song identity is absent) →
        // resolution can never auto-pick by album id.
        let parsed = PastedListParser.parse(
            "https://music.apple.com/us/album/mercy/1440767384")
        XCTAssertEqual(parsed.count, 1)
        XCTAssertNil(parsed[0].catalogId, "album id must never become song identity")
        XCTAssertEqual(parsed[0].kind, .link)
        XCTAssertNil(parsed[0].link?.catalogId)

        // Transaction-level: the manifest's catalogId drives appends; an
        // album-id collision (playlist stores the ALBUM id as a track)
        // classifies as unrelated → stop, never "close enough".
        let ids = [101, 102]
        let t = transportFor(ids: ids, playlistName: "P", libraryHas: ids)
        t.playlistTracks["p.test"] = [Fixtures.librarySong(libraryId: "i.album",
                                                           catalogId: 1440767384)]
        let manifest = Fixtures.manifest(ids: ids)
        let report = await makeRunner(t).run(manifest: manifest, playlistName: "P")
        XCTAssertFalse(report.succeeded)
        guard case .playlistNotSafeToWrite(_, let state)? = report.phases.last?.error else {
            return XCTFail("expected unsafe-state stop, got \(report.phases)")
        }
        XCTAssertEqual(state, .containsUnrelatedTracks)
        XCTAssertEqual(t.calls.filter { $0.name == "append" }.count, 0)
    }

    // MARK: - Scenario 3: existing Library items
    //
    // Reconciliation must detect every recording already in the Library,
    // never re-add it (duplicate-add risk), and the transaction still
    // completes the playlist append from the verified map.
    func testExistingLibraryItemsAreNotReAdded() async {
        let ids = [101, 102, 103]
        // ALL items already in the library; playlist empty.
        let t = transportFor(ids: ids, playlistName: "P", libraryHas: ids)
        let manifest = Fixtures.manifest(ids: ids)

        let report = await makeRunner(t).run(manifest: manifest, playlistName: "P")

        XCTAssertTrue(report.succeeded)
        XCTAssertEqual(t.calls.filter { $0.name == "libraryAdd" }.count, 0,
                       "no add may be issued for a recording already present")
        XCTAssertEqual(t.calls.filter { $0.name == "libraryPage" }.count, 1,
                       "§12: reconcile enumeration is the fresh read when no adds issued")
        XCTAssertEqual(t.storedTracks(playlistId: "p.test").map(\.catalogId), ids)
        // And with SOME items present, only the missing ones are added.
        let t2 = transportFor(ids: ids, playlistName: "P", libraryHas: [101, 103])
        let report2 = await makeRunner(t2).run(manifest: manifest, playlistName: "P")
        XCTAssertTrue(report2.succeeded)
        XCTAssertEqual(t2.calls.filter { $0.name == "libraryAdd" }.map(\.detail), ["102"],
                       "only the missing recording is added, in manifest order")
    }

    // MARK: - Scenario 4: duplicate playlists
    //
    // §20: the target must be uniquely identifiable. Two same-named
    // playlists stop the transaction before any write; one same-named
    // playlist among many differently-named ones is fine.
    func testDuplicatePlaylistNamesStopBeforeWrites() async {
        let ids = [101]
        let t = transportFor(ids: ids, playlistName: "Twin", libraryHas: ids)
        t.playlistPages = [[Fixtures.playlist(id: "p.a", name: "Twin"),
                           Fixtures.playlist(id: "p.b", name: "Twin")]]
        let manifest = Fixtures.manifest(ids: ids)

        let report = await makeRunner(t).run(manifest: manifest, playlistName: "Twin",
                                             missingPlaylistPolicy: .create)

        XCTAssertFalse(report.succeeded)
        guard case .playlistAmbiguous(let name, let count)? = report.phases.last?.error else {
            return XCTFail("expected playlistAmbiguous, got \(report.phases)")
        }
        XCTAssertEqual(name, "Twin")
        XCTAssertEqual(count, 2)
        XCTAssertEqual(t.calls.filter { $0.name == "append" }.count, 0)
        XCTAssertEqual(t.calls.filter { $0.name == "libraryAdd" }.count, 0)
        XCTAssertEqual(t.calls.filter { $0.name == "createPlaylist" }.count, 0,
                       "ambiguity is not not-found: creation must not fire")

        // Uniqueness among many: same name appears exactly once across
        // pages of other playlists → discovered fine, transaction proceeds.
        let t2 = transportFor(ids: ids, playlistName: "Only One", libraryHas: ids)
        t2.playlistPages = [[Fixtures.playlist(id: "p.other", name: "Something Else"),
                             Fixtures.playlist(id: "p.test", name: "Only One")],
                            [Fixtures.playlist(id: "p.more", name: "Third")]]
        let report2 = await makeRunner(t2).run(manifest: manifest, playlistName: "Only One")
        XCTAssertTrue(report2.succeeded)
    }

    // MARK: - Scenario 5: delayed synchronization
    //
    // §11/§14: a 202/204 is an acknowledgment, never proof. Two lag shapes:
    // a library add that appears only in a LATER enumeration, and a
    // playlist append whose visibility lags one read. Both must be absorbed
    // by bounded fresh-read retries — and the bounded failure stops closed.
    func testDelayedSynchronizationIsAbsorbedByBoundedFreshReads() async {
        // Library add propagation lag: enumeration 1 misses it, 2 sees it.
        let ids = [101, 102]
        let t = transportFor(ids: ids, playlistName: "P", libraryHas: [101])
        t.addsBecomeVisibleInLibrary = true
        t.libraryAddVisibilityLag = 1   // hidden from the first enumeration
        let manifest = Fixtures.manifest(ids: ids)
        let report = await makeRunner(t).run(manifest: manifest, playlistName: "P")
        XCTAssertTrue(report.succeeded,
                      "late-propagating add must be observed by retry, not assumed")

        // Playlist-append propagation lag: first verification read is
        // stale once, then the write becomes visible (§14).
        let t2 = transportFor(ids: ids, playlistName: "P", libraryHas: ids)
        t2.appendsMutateTracks = false
        var appendCount = 0
        t2.appendHook = { playlistId, librarySongId in
            appendCount += 1
            if let song = t2.librarySongsById[librarySongId] {
                t2.playlistTracks[playlistId, default: []].append(song)
            }
            t2.appendVisibilityLag = (appendCount == 1) ? 1 : 0
            return 204
        }
        let report2 = await makeRunner(t2).run(manifest: manifest, playlistName: "P")
        XCTAssertTrue(report2.succeeded)
        XCTAssertEqual(t2.storedTracks(playlistId: "p.test").map(\.catalogId), ids)
    }

    // MARK: - Scenario 6: expired authorization
    //
    // §15: authorization loss is a distinct stop condition. The transport
    // throws AMError.notAuthorized; the runner must preserve that type all
    // the way to the report — never flatten it into a transport error — so
    // the UI can say "Apple Music access was lost" and re-request.
    func testExpiredAuthorizationSurfacesAsNotAuthorizedStop() async {
        let ids = [101, 102]
        let t = transportFor(ids: ids, playlistName: "P", libraryHas: ids)
        // The transport blows up with notAuthorized at the FIRST call —
        // the engine surfaces it mid-transaction.
        struct ExpiredAuthTransport: AMTransport {
            func getCatalogSong(catalogId: Int, storefront: String) async throws
                -> (song: AMCatalogSong?, httpStatus: Int) { throw AMError.notAuthorized }
            func getLibrarySongsPage(cursor: String?) async throws
                -> (items: [AMLibrarySong], next: String?) { throw AMError.notAuthorized }
            func getLibraryPlaylistsPage(cursor: String?) async throws
                -> (items: [AMLibraryPlaylist], next: String?) { throw AMError.notAuthorized }
            func getPlaylistTracks(playlistId: String) async throws -> [AMLibrarySong] {
                throw AMError.notAuthorized
            }
            func addCatalogSongToLibrary(catalogId: Int) async throws -> Int {
                throw AMError.notAuthorized
            }
            func appendLibrarySong(toPlaylist playlistId: String, librarySongId: String) async throws -> Int {
                throw AMError.notAuthorized
            }
            func createPlaylist(named name: String) async throws
                -> (playlist: AMLibraryPlaylist?, httpStatus: Int) { throw AMError.notAuthorized }
        }

        let runner = TransactionRunner(engine: RESTEngine(
            transport: ExpiredAuthTransport(),
            config: .init(storefront: "us", propagateDelayMilliseconds: 0,
                          verificationRetries: 1, verificationBackoffMilliseconds: 0)))
        let manifest = Fixtures.manifest(ids: ids)
        let report = await runner.run(manifest: manifest, playlistName: "P")

        XCTAssertFalse(report.succeeded)
        XCTAssertEqual(report.phases.last?.error, .notAuthorized,
                      "expired authorization must reach the report as itself")
        // A transport stop mid-execute must also preserve the type:
        // a phase-7 stop returns a typed error in the report.
        let t2 = transportFor(ids: ids, playlistName: "P", libraryHas: ids)
        t2.appendStatuses = ["i.101": 401]   // server rejects: credentials expired
        let report2 = await makeRunner(t2).run(manifest: manifest, playlistName: "P")
        XCTAssertFalse(report2.succeeded)
        XCTAssertEqual(report2.phases.last?.error,
                       .playlistAppendFailed(pos: 1, catalogId: 101,
                                             librarySongId: "i.101", httpStatus: 401),
                       "phase-7 stop must carry the typed error, never lose per-step evidence")
    }

    // MARK: - Scenario 7: interrupted imports with recovery
    //
    // The Phase 6 recovery loop: an execute-phase interruption (write
    // outcome uncertain) must produce a credential-free checkpoint whose
    // PROVEN count excludes the uncertain step; restart reconciles the
    // checkpoint against Apple's ACTUAL state by fresh reads; a matching
    // state resumes from reality (never replaying the old plan blindly),
    // and a diverged state stops for human direction.
    func testInterruptedImportProducesCheckpointAndResumesFromActualState() async throws {
        let ids = [101, 102, 103, 104]
        let manifest = Fixtures.manifest(ids: ids)

        // Interruption: append 1 (pos 1) lands and is proven; append 2
        // (pos 2) is acknowledged but its stored write never becomes
        // visible to a fresh read — §14 bounded retries exhaust → stop.
        // Proven count: 1 (pos 1); pos 2's outcome is uncertain.
        let t = transportFor(ids: ids, playlistName: "P", libraryHas: ids)
        t.appendsMutateTracks = false
        var appendCount = 0
        var visible: [AMLibrarySong] = []
        t.appendHook = { playlistId, librarySongId in
            appendCount += 1
            if let song = t.librarySongsById[librarySongId] {
                if appendCount == 1 {
                    visible.append(song)
                    t.playlistTracks[playlistId] = visible
                }
                // append 2+: acknowledged (204) but never stored visibly.
            }
            return 204
        }
        let stoppedReport = await makeRunner(t).run(manifest: manifest, playlistName: "P")
        XCTAssertFalse(stoppedReport.succeeded)
        XCTAssertEqual(appendCount, 2, "stop must occur at the second, unprovable step")

        // 1. Checkpoint from the stopped report's own evidence: proven
        //    count is 1 — pos 1 was proven by its fresh read; pos 2's
        //    acknowledged-but-unverified write is NOT trusted (§14).
        let checkpoint = try XCTUnwrap(
            TransactionRunner.checkpoint(forInterruptedExecuteIn: stoppedReport,
                                         capturedAtMillisSinceEpoch: 1))
        XCTAssertEqual(checkpoint.manifestCatalogIds, ids)
        XCTAssertEqual(checkpoint.playlistId, "p.test")
        XCTAssertEqual(checkpoint.provenStoredPrefixCount, 1,
                       "only the verified step may be claimed as proven")

        // 2. Credential-free persistence round-trip (Codable).
        let data = try JSONEncoder().encode(checkpoint)
        let decoded = try JSONDecoder().decode(TransactionCheckpoint.self, from: data)
        XCTAssertEqual(decoded, checkpoint)

        // 3. Restart: Apple's ACTUAL state (fresh read) is the playlist
        //    with exactly pos 1 stored. Reality EQUALS the checkpoint's
        //    proven claim → reconcile allows resume from position 2.
        let t2 = transportFor(ids: ids, playlistName: "P", libraryHas: ids)
        t2.playlistTracks["p.test"] = [Fixtures.librarySong(libraryId: "i.101", catalogId: 101)]
        let engine = RESTEngine(transport: t2, config: .init(
            storefront: "us", propagateDelayMilliseconds: 0,
            verificationRetries: 3, verificationBackoffMilliseconds: 0))
        let freshPreflight = await engine.preflightPlaylist(named: "P", manifest: manifest)
        let decision = RecoveryPlanner.reconcile(checkpoint: decoded,
                                                 manifest: manifest,
                                                 preflight: freshPreflight)
        guard case .resume(let info, let stored, let resumePos) = decision else {
            return XCTFail("expected resume, got \(decision)")
        }
        XCTAssertEqual(info.id, "p.test")
        XCTAssertEqual(stored, [101])
        XCTAssertEqual(resumePos, 2)

        // 4. Resume = a fresh canonical run; it re-derives its own plan
        //    and finishes, proving the manifest sequence exactly.
        let resumedReport = await makeRunner(t2).run(manifest: manifest, playlistName: "P")
        XCTAssertTrue(resumedReport.succeeded)
        XCTAssertEqual(t2.storedTracks(playlistId: "p.test").map(\.catalogId), ids)
        XCTAssertEqual(t2.calls.filter { $0.name == "append" }.map(\.detail),
                       ["p.test:i.102", "p.test:i.103", "p.test:i.104"],
                       "resume appends only the un-stored suffix")
    }

    /// Adversarial: reality LOST a track the checkpoint proved stored
    /// (foreign deletion between sessions) → recovery must stop, never
    /// resume onto a state that contradicts proven history.
    func testRecoveryStopsWhenRealityContradictsProvenCheckpoint() async {
        let ids = [101, 102, 103]
        let manifest = Fixtures.manifest(ids: ids)
        let checkpoint = TransactionCheckpoint(
            playlistId: "p.test", playlistName: "P",
            manifestCatalogIds: ids,
            provenStoredPrefixCount: 2,   // two tracks were PROVEN stored
            provenLibraryCatalogIds: ids,
            capturedAtMillisSinceEpoch: 1)

        // Actual state: only ONE track remains — contradicts the proof.
        let t = transportFor(ids: ids, playlistName: "P", libraryHas: ids)
        t.playlistTracks["p.test"] = [Fixtures.librarySong(libraryId: "i.101", catalogId: 101)]
        let engine = RESTEngine(transport: t, config: .init(
            storefront: "us", propagateDelayMilliseconds: 0,
            verificationRetries: 1, verificationBackoffMilliseconds: 0))
        let preflight = await engine.preflightPlaylist(named: "P", manifest: manifest)

        let decision = RecoveryPlanner.reconcile(checkpoint: checkpoint,
                                                 manifest: manifest,
                                                 preflight: preflight)
        guard case .stop(.checkpointDiverged(let reason)) = decision else {
            return XCTFail("expected checkpointDiverged stop, got \(decision)")
        }
        XCTAssertTrue(reason.contains("proved 2"), "reason names the contradiction: \(reason)")
    }

    /// Adversarial: same-name REPLACED playlist (different id) must not be
    /// resumable onto — its history is unknown. And a changed manifest
    /// invalidates the checkpoint's meaning entirely.
    func testRecoveryRejectsReplacedPlaylistAndChangedManifest() async {
        let ids = [101, 102]
        let manifest = Fixtures.manifest(ids: ids)
        let t = transportFor(ids: ids, playlistName: "P", libraryHas: ids)
        // A different playlist object now answers to the same name.
        t.playlistPages = [[Fixtures.playlist(id: "p.REPLACED", name: "P")]]
        t.playlistTracks["p.REPLACED"] = []
        let engine = RESTEngine(transport: t, config: .init(
            storefront: "us", propagateDelayMilliseconds: 0,
            verificationRetries: 1, verificationBackoffMilliseconds: 0))
        let checkpoint = TransactionCheckpoint(
            playlistId: "p.test", playlistName: "P",
            manifestCatalogIds: ids, provenStoredPrefixCount: 0,
            provenLibraryCatalogIds: ids, capturedAtMillisSinceEpoch: 1)

        let preflight = await engine.preflightPlaylist(named: "P", manifest: manifest)
        guard case .stop(.checkpointDiverged) = RecoveryPlanner.reconcile(
            checkpoint: checkpoint, manifest: manifest, preflight: preflight) else {
            return XCTFail("replaced playlist must stop")
        }

        // Changed manifest (same playlist, sequence differs): stop.
        let t2 = transportFor(ids: ids, playlistName: "P", libraryHas: ids)
        let engine2 = RESTEngine(transport: t2, config: .init(
            storefront: "us", propagateDelayMilliseconds: 0,
            verificationRetries: 1, verificationBackoffMilliseconds: 0))
        let preflight2 = await engine2.preflightPlaylist(named: "P", manifest: manifest)
        let decision = RecoveryPlanner.reconcile(
            checkpoint: checkpoint,
            manifest: Fixtures.manifest(ids: [101, 202]),   // different sequence
            preflight: preflight2)
        guard case .stop(.checkpointDiverged(let reason)) = decision else {
            return XCTFail("changed manifest must stop, got \(decision)")
        }
        XCTAssertTrue(reason.contains("manifest changed"))
    }

    /// Recovery onto an already-complete playlist: the checkpoint claims
    /// a partial prefix, but reality finished the job (e.g. a later
    /// session completed it). Reconcile reports alreadyComplete — resume
    /// must not issue a single write.
    func testRecoveryRecognizesAlreadyCompleteAndWritesNothing() async {
        let ids = [101, 102]
        let manifest = Fixtures.manifest(ids: ids)
        let t = transportFor(ids: ids, playlistName: "P", libraryHas: ids,
                             playlistTracks: ids)   // reality: complete
        let engine = RESTEngine(transport: t, config: .init(
            storefront: "us", propagateDelayMilliseconds: 0,
            verificationRetries: 1, verificationBackoffMilliseconds: 0))
        let checkpoint = TransactionCheckpoint(
            playlistId: "p.test", playlistName: "P",
            manifestCatalogIds: ids, provenStoredPrefixCount: 1,
            provenLibraryCatalogIds: ids, capturedAtMillisSinceEpoch: 1)
        let preflight = await engine.preflightPlaylist(named: "P", manifest: manifest)

        let decision = RecoveryPlanner.reconcile(checkpoint: checkpoint,
                                                 manifest: manifest,
                                                 preflight: preflight)
        XCTAssertEqual(decision,
                       .alreadyComplete(playlist: PlaylistInfo(id: "p.test", name: "P",
                                                               canEdit: true, shareUrl: nil)))
    }

    /// Checkpoint proven-count derivation is uniform under §14: with an
    /// execute interrupted after N recorded steps, exactly N-1 are proven.
    func testCheckpointProvenCountExcludesUncertainLastStep() {
        let plan = AppendPlan(playlistId: "p.test", playlistName: "P",
                              manifestCatalogIds: [101, 102, 103, 104],
                              steps: (1...4).map {
                                  AppendPlan.Step(pos: $0, catalogId: 100 + $0,
                                                  librarySongId: "i.\(100 + $0)")
                              })
        func outcomes(_ n: Int) -> [AppendOutcome] {
            (1...n).map {
                AppendOutcome(pos: $0, catalogId: 100 + $0,
                              librarySongId: "i.\(100 + $0)", httpStatus: 204)
            }
        }
        // Transport stop mid-execute after 3 recorded steps → 2 proven.
        let cp = RecoveryPlanner.checkpointAfterInterruptedExecute(
            plan: plan, appendOutcomes: outcomes(3),
            stoppedBy: .transport("network dropped"),
            provenStoredCountBeforeExecute: 0,
            provenLibraryCatalogIds: [], capturedAtMillisSinceEpoch: 9)
        XCTAssertEqual(cp.provenStoredPrefixCount, 2)
        // Append failure at the 3rd step → 2 proven.
        let cp2 = RecoveryPlanner.checkpointAfterInterruptedExecute(
            plan: plan, appendOutcomes: outcomes(3),
            stoppedBy: .playlistAppendFailed(pos: 3, catalogId: 103,
                                             librarySongId: "i.103", httpStatus: 500),
            provenStoredCountBeforeExecute: 0,
            provenLibraryCatalogIds: [], capturedAtMillisSinceEpoch: 9)
        XCTAssertEqual(cp2.provenStoredPrefixCount, 2)
        // Stop before ANY write → 0 proven.
        let cp3 = RecoveryPlanner.checkpointAfterInterruptedExecute(
            plan: plan, appendOutcomes: [],
            stoppedBy: .transport("offline"),
            provenStoredCountBeforeExecute: 0,
            provenLibraryCatalogIds: [], capturedAtMillisSinceEpoch: 9)
        XCTAssertEqual(cp3.provenStoredPrefixCount, 0)
        // Resume-from-suffix plan (correctPrefix 2): provenBefore = 2.
        let suffixPlan = AppendPlan(playlistId: "p.test", playlistName: "P",
                                    manifestCatalogIds: [101, 102, 103, 104],
                                    steps: [3, 4].map {
                                        AppendPlan.Step(pos: $0, catalogId: 100 + $0,
                                                        librarySongId: "i.\(100 + $0)")
                                    })
        let cp4 = RecoveryPlanner.checkpointAfterInterruptedExecute(
            plan: suffixPlan, appendOutcomes: outcomes(2),
            stoppedBy: .playlistVerificationFailed(reason: "never visible"),
            provenStoredCountBeforeExecute: 2,
            provenLibraryCatalogIds: [], capturedAtMillisSinceEpoch: 9)
        XCTAssertEqual(cp4.provenStoredPrefixCount, 3,
                       "prefix 2 + first step proven, second step uncertain")
    }

    // MARK: - Scenario 8: playlist-order verification
    //
    // §16: completion is defined by an independent fresh read-back.
    // Ordering is part of the product contract — every append below the
    // exact sequence must fail verification, and a verified report must
    // have proven the sequence (not merely the multiset).
    func testPlaylistOrderVerificationIsExactSequence() async {
        let ids = [101, 102, 103]
        let manifest = Fixtures.manifest(ids: ids)
        func verify(_ trackIds: [Int]) -> PlaylistVerification {
            RESTEngine.verifyPlaylist(
                playlistId: "p", manifest: manifest,
                tracks: trackIds.map { Fixtures.librarySong(libraryId: "i.\($0)", catalogId: $0) },
                shareUrl: nil)
        }

        XCTAssertTrue(verify(ids).verified)
        XCTAssertFalse(verify([102, 101, 103]).verified,
                       "swap of two positions must fail")
        XCTAssertFalse(verify([103, 102, 101]).verified, "reversed order must fail")
        XCTAssertFalse(verify([101, 103, 102]).verified)
        XCTAssertTrue(verify([102, 101, 103]).orderingPass == false)
        // A correct multiset in the wrong order is still a failure:
        XCTAssertEqual(verify([102, 101, 103]).duplicates, [])
        XCTAssertEqual(verify([102, 101, 103]).unexpectedCatalogIds, [])
        XCTAssertFalse(verify([102, 101, 103]).verified,
                       "same set, wrong order: sequence IS the contract")
        // Extra track after a correct prefix fails:
        XCTAssertFalse(verify([101, 102, 103, 101]).verified)

        // Live-shape: per-step §14 verification already refuses a server
        // that permutes storage mid-run (the stop happens at execute, so
        // the final read-back is never reached — order violations never
        // survive that long). The remaining surface: an external actor
        // permutes the playlist AFTER a verified completion — the next
        // run's preflight must classify wrongOrder and stop with zero
        // writes (§13/§20), never "repair" by re-appending.
        let t = transportFor(ids: ids, playlistName: "P", libraryHas: ids)
        let first = await makeRunner(t).run(manifest: manifest, playlistName: "P")
        XCTAssertTrue(first.succeeded)
        XCTAssertEqual(t.storedTracks(playlistId: "p.test").map(\.catalogId), ids)

        // External reorder: [101, 103, 102].
        t.playlistTracks["p.test"] = [
            Fixtures.librarySong(libraryId: "i.101", catalogId: 101),
            Fixtures.librarySong(libraryId: "i.103", catalogId: 103),
            Fixtures.librarySong(libraryId: "i.102", catalogId: 102),
        ]
        let second = await makeRunner(t).run(manifest: manifest, playlistName: "P")
        XCTAssertFalse(second.succeeded, "a permuted playlist must never verify")
        guard case .playlistNotSafeToWrite(_, let state)? = second.phases.last?.error else {
            return XCTFail("expected unsafe-state stop, got \(second.phases)")
        }
        XCTAssertEqual(state, .wrongOrder)
        XCTAssertEqual(t.calls.filter { $0.name == "append" }.count, 3,
                      "only the FIRST run's appends; the second run wrote nothing")
        XCTAssertEqual(t.storedTracks(playlistId: "p.test").map(\.catalogId),
                       [101, 103, 102], "the permuted state is preserved, not mutated")
    }

    // MARK: - Adversarial property: prefix monotonicity of a safe resume
    //
    // For EVERY safe-state combination, a resume that reconciles a
    // checkpoint whose proven prefix is ≤ the fresh prefix must be allowed
    // (or alreadyComplete), and a checkpoint exceeding it must diverge —
    // exhaustively, not by example.
    func testRecoveryPrefixRuleIsMonotonicAndFailClosed() {
        let ids = [101, 102, 103, 104]
        let manifest = Fixtures.manifest(ids: ids)
        let info = PlaylistInfo(id: "p.test", name: "P", canEdit: true, shareUrl: nil)

        for freshPrefix in 0...ids.count {
            let tracks = (0..<freshPrefix).map {
                Fixtures.librarySong(libraryId: "i.\(ids[$0])", catalogId: ids[$0])
            }
            let state = RESTEngine.classifyPlaylist(tracks: tracks, manifest: manifest)
            let preflight: PlaylistPreflightResult = .ok(playlist: info, state: state,
                                                         missingCatalogIds: [])
            for provenPrefix in 0...ids.count {
                let checkpoint = TransactionCheckpoint(
                    playlistId: "p.test", playlistName: "P",
                    manifestCatalogIds: ids,
                    provenStoredPrefixCount: provenPrefix,
                    provenLibraryCatalogIds: ids,
                    capturedAtMillisSinceEpoch: 0)
                let decision = RecoveryPlanner.reconcile(checkpoint: checkpoint,
                                                          manifest: manifest,
                                                          preflight: preflight)
                if provenPrefix <= freshPrefix {
                    // Allowed: resume or already-complete.
                    switch decision {
                    case .resume(_, let stored, let resumePos):
                        XCTAssertEqual(stored, Array(ids.prefix(freshPrefix)))
                        XCTAssertEqual(resumePos, freshPrefix + 1)
                    case .alreadyComplete:
                        XCTAssertEqual(freshPrefix, ids.count)
                    case .stop(let error):
                        XCTFail("proven \(provenPrefix) ≤ fresh \(freshPrefix) must not stop: \(error)")
                    }
                } else {
                    // Fail-closed: proven exceeds reality.
                    guard case .stop(.checkpointDiverged) = decision else {
                        XCTFail("proven \(provenPrefix) > fresh \(freshPrefix) must diverge: \(decision)")
                        continue
                    }
                }
            }
        }
    }
}
