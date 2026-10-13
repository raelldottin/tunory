import XCTest
@testable import TunoryCore

final class RESTEngineTests: XCTestCase {

    // Convenience: engine over a fresh stub.
    private func makeEngine(_ transport: StubTransport) -> RESTEngine {
        RESTEngine(transport: transport, config: .init(
            storefront: "us",
            maxLibraryPages: 100,
            maxPlaylistPages: 20,
            propagateDelayMilliseconds: 0,
            verificationRetries: 3,
            verificationBackoffMilliseconds: 0,
            appendVerificationRetries: 3,
            appendVerificationBackoffMilliseconds: 0,
            createRediscoveryRetries: 3,
            createRediscoveryBackoffMilliseconds: 0))
    }

    // MARK: - §13 classification (pure, exhaustive over safe/unsafe states)

    private let manifestIds = [101, 102, 103, 104]

    private func classify(_ trackIds: [Int?]) -> PlaylistState {
        let manifest = Fixtures.manifest(ids: manifestIds)
        let tracks = trackIds.map { id in
            id.map { Fixtures.librarySong(libraryId: "i.\($0)", catalogId: $0) }
                ?? Fixtures.unidentifiedLibrarySong(libraryId: "i.unknown")
        }
        return RESTEngine.classifyPlaylist(tracks: tracks, manifest: manifest)
    }

    func testClassifyEmpty() {
        XCTAssertEqual(classify([]), .empty)
    }

    func testClassifyExactComplete() {
        XCTAssertEqual(classify([101, 102, 103, 104]), .exactComplete)
    }

    func testClassifyCorrectPrefix() {
        XCTAssertEqual(classify([101, 102]), .correctPrefix(count: 2))
        XCTAssertEqual(classify([101]), .correctPrefix(count: 1))
    }

    func testClassifyWrongOrder() {
        XCTAssertEqual(classify([102, 101]), .wrongOrder)
        XCTAssertEqual(classify([101, 103, 102]), .wrongOrder)
    }

    func testClassifyDuplicates() {
        XCTAssertEqual(classify([101, 101]), .containsDuplicates)
        XCTAssertEqual(classify([101, 102, 102, 103]), .containsDuplicates)
    }

    func testClassifyUnrelatedTracks() {
        XCTAssertEqual(classify([101, 999]), .containsUnrelatedTracks)
        XCTAssertEqual(classify([999]), .containsUnrelatedTracks)
    }

    func testClassifyUnidentifiableTracks() {
        XCTAssertEqual(classify([101, nil]), .containsUnidentifiableTracks)
    }

    func testOnlySafeStatesAreSafeToWrite() {
        XCTAssertTrue(PlaylistState.empty.isSafeToWrite)
        XCTAssertTrue(PlaylistState.correctPrefix(count: 2).isSafeToWrite)
        XCTAssertTrue(PlaylistState.exactComplete.isSafeToWrite)
        XCTAssertFalse(PlaylistState.wrongOrder.isSafeToWrite)
        XCTAssertFalse(PlaylistState.containsDuplicates.isSafeToWrite)
        XCTAssertFalse(PlaylistState.containsUnrelatedTracks.isSafeToWrite)
        XCTAssertFalse(PlaylistState.containsUnidentifiableTracks.isSafeToWrite)
    }

    func testMissingSuffix() {
        let manifest = Fixtures.manifest(ids: manifestIds)
        XCTAssertEqual(RESTEngine.missingSuffix(state: .empty, manifest: manifest), manifestIds)
        XCTAssertEqual(RESTEngine.missingSuffix(state: .correctPrefix(count: 2), manifest: manifest),
                       [103, 104])
        XCTAssertEqual(RESTEngine.missingSuffix(state: .exactComplete, manifest: manifest), [])
        // Unsafe states never produce a suffix.
        XCTAssertEqual(RESTEngine.missingSuffix(state: .wrongOrder, manifest: manifest), [])
    }

    // MARK: - §11 library identity (playParams primary, relationship fallback)

    func testLibrarySongCatalogIdPrefersPlayParams() {
        let both = AMLibrarySong(
            id: "i.1",
            attributes: .init(name: nil, artistName: nil, playParams: .init(catalogId: 111)),
            relationships: .init(catalog: .init(data: [.init(id: "222", type: "songs")])))
        XCTAssertEqual(both.catalogId, 111, "playParams.catalogId must win (§11)")
    }

    func testLibrarySongCatalogIdFallsBackToRelationship() {
        let viaRelationship = Fixtures.librarySongViaRelationship(libraryId: "i.1", catalogId: 222)
        XCTAssertEqual(viaRelationship.catalogId, 222)
    }

    func testLibrarySongWithoutIdentityIsNil() {
        XCTAssertNil(Fixtures.unidentifiedLibrarySong(libraryId: "i.x").catalogId)
    }

    func testPlayParamsCatalogIdDecodesFromStringOrNumber() throws {
        let numberData = Data("{\"catalogId\": 1436241421}".utf8)
        let stringData = Data("{\"catalogId\": \"1436241421\"}".utf8)
        let asNumber = try JSONDecoder().decode(AMLibrarySong.PlayParams.self, from: numberData)
        let asString = try JSONDecoder().decode(AMLibrarySong.PlayParams.self, from: stringData)
        XCTAssertEqual(asNumber.catalogId, 1436241421)
        XCTAssertEqual(asString.catalogId, 1436241421)
    }

    func testLibraryPageDecodesFromRealShape() throws {
        // Real payload shape from the proven run (§11): identity in
        // playParams, relationship often absent.
        let json = """
        {"data":[{"id":"i.abc","type":"library-songs","attributes":{"name":"The Lark Ascending","artistName":"Hilary Hahn","playParams":{"id":"i.abc","kind":"song","catalogId":1436241421}}}],"next":"/v1/me/library/songs?offset=100"}
        """
        let page = try JSONDecoder().decode(AMPage<AMLibrarySong>.self, from: Data(json.utf8))
        XCTAssertEqual(page.data?.count, 1)
        XCTAssertEqual(page.data?.first?.catalogId, 1436241421)
        XCTAssertEqual(page.next, "/v1/me/library/songs?offset=100")
    }

    // MARK: - Catalog validation (Gate 3)

    func testCatalogValidationPassesForCompleteCatalog() async throws {
        let manifest = Fixtures.manifest(ids: [101, 102])
        let transport = StubTransport()
        transport.catalogSongs[101] = Fixtures.catalogSong(catalogId: 101, name: "Song 1", artist: "Artist 1")
        transport.catalogSongs[102] = Fixtures.catalogSong(catalogId: 102, name: "Song 2", artist: "Artist 2")

        let report = await makeEngine(transport).validateCatalog(manifest: manifest)

        XCTAssertTrue(report.passed)
        XCTAssertEqual(report.entries.map(\.pos), [1, 2])
        XCTAssertTrue(report.entries.allSatisfy { !$0.nameDiverged })
    }

    func testCatalogValidationFailsOn404() async throws {
        let manifest = Fixtures.manifest(ids: [101, 999])
        let transport = StubTransport()
        transport.catalogSongs[101] = Fixtures.catalogSong(catalogId: 101, name: "Song 1", artist: "Artist 1")

        let report = await makeEngine(transport).validateCatalog(manifest: manifest)

        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.entries[0].ok, true)
        XCTAssertEqual(report.entries[1].ok, false)
        XCTAssertEqual(report.entries[1].httpStatus, 404)
    }

    func testCatalogValidationFlagsDivergentNameWithoutFailingGate() async throws {
        // §10: divergence is review information, never silently accepted
        // nor a hidden pass.
        let manifest = Fixtures.manifest(ids: [101])
        let transport = StubTransport()
        transport.catalogSongs[101] = Fixtures.catalogSong(
            catalogId: 101, name: "Completely Different Recording", artist: "Someone Else")

        let report = await makeEngine(transport).validateCatalog(manifest: manifest)

        XCTAssertTrue(report.passed, "existence gate passes — id is authoritative")
        XCTAssertTrue(report.entries[0].nameDiverged, "divergence must be surfaced")
    }

    // MARK: - Library reconciliation

    func testReconcileSplitsPresentAndMissingInManifestOrder() {
        let manifest = Fixtures.manifest(ids: [101, 102, 103])
        let library = [101: "i.101", 103: "i.103"]

        let reconciliation = RESTEngine.reconcile(manifest: manifest, library: library)

        XCTAssertEqual(reconciliation.present, [101: "i.101", 103: "i.103"])
        XCTAssertEqual(reconciliation.missing.map(\.catalogId), [102])
        XCTAssertEqual(reconciliation.missing.map(\.pos), [2])
    }

    func testAddMissingIssuesOneRequestPerRecordingInOrder() async throws {
        let manifest = Fixtures.manifest(ids: [101, 102, 103])
        let transport = StubTransport()
        transport.libraryAddStatuses = [:]  // default 202

        let missing = [manifest.entries[1], manifest.entries[2]]
        let outcomes = try await makeEngine(transport).addMissingToLibrary(missing)

        XCTAssertEqual(outcomes.map(\.catalogId), [102, 103])
        XCTAssertEqual(outcomes.map(\.httpStatus), [202, 202])
        XCTAssertEqual(transport.calls.filter { $0.name == "libraryAdd" }.map(\.detail),
                       ["102", "103"])
    }

    func testAddMissingStopsAtFirstFailure() async {
        let manifest = Fixtures.manifest(ids: [101, 102, 103])
        let transport = StubTransport()
        transport.libraryAddStatuses = [102: 403]

        do {
            _ = try await makeEngine(transport).addMissingToLibrary(Array(manifest.entries.dropFirst()))
            XCTFail("must throw")
        } catch let error as AMError {
            XCTAssertEqual(error, .libraryAddFailed(catalogId: 102, httpStatus: 403))
            // 103 must never be attempted after 102 failed.
            XCTAssertFalse(transport.calls.contains { $0.name == "libraryAdd" && $0.detail == "103" })
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testVerifyLibraryRetriesUntilPresent() async throws {
        let manifest = Fixtures.manifest(ids: [101, 102])
        let transport = StubTransport()
        // Enumeration 1: 102 missing (Apple's add hasn't propagated yet).
        // Enumeration 2: complete. Proves verification re-reads instead of
        // trusting the 202 acknowledgment.
        let incomplete = [[Fixtures.librarySong(libraryId: "i.101", catalogId: 101)]]
        let complete = [[Fixtures.librarySong(libraryId: "i.101", catalogId: 101),
                         Fixtures.librarySong(libraryId: "i.102", catalogId: 102)]]
        transport.libraryEnumerationHook = { ordinal in
            ordinal == 1 ? incomplete : complete
        }

        let verification = await makeEngine(transport).verifyLibrary(manifest: manifest)

        XCTAssertTrue(verification.verified, "retry must observe the late addition")
        XCTAssertEqual(verification.attempts, 2)
        XCTAssertEqual(verification.catalogToLibraryId[102], "i.102")
    }

    func testVerifyLibraryFailsAfterBoundedRetries() async {
        let manifest = Fixtures.manifest(ids: [101, 102])
        let transport = StubTransport()
        transport.libraryPages = [[Fixtures.librarySong(libraryId: "i.101", catalogId: 101)]]

        let verification = await makeEngine(transport).verifyLibrary(manifest: manifest)

        XCTAssertFalse(verification.verified)
        XCTAssertEqual(verification.missingCatalogIds, [102])
        XCTAssertEqual(verification.attempts, 3, "bounded retries")
    }

    // MARK: - Playlist discovery + preflight

    func testPreflightEmptyPlaylistIsSafe() async throws {
        let manifest = Fixtures.manifest(ids: [101, 102])
        let transport = Fixtures.happyPathTransport(manifest: manifest,
                                                    playlistName: "Target",
                                                    libraryHas: [101, 102])

        let result = await makeEngine(transport).preflightPlaylist(named: "Target", manifest: manifest)

        guard case .ok(let playlist, let state, let missing) = result else {
            return XCTFail("expected ok, got \(result)")
        }
        XCTAssertEqual(playlist.id, "p.test")
        XCTAssertEqual(playlist.canEdit, true)
        XCTAssertEqual(state, .empty)
        XCTAssertEqual(missing, [101, 102])
    }

    func testPreflightStopsWhenPlaylistMissing() async throws {
        let manifest = Fixtures.manifest(ids: [101])
        let transport = StubTransport()
        transport.playlistPages = [[]]
        transport.libraryPages = [[]]

        let result = await makeEngine(transport).preflightPlaylist(named: "Absent", manifest: manifest)

        XCTAssertEqual(result, .stop(.playlistNotFound(name: "Absent")))
    }

    func testPreflightStopsOnDuplicateNames() async throws {
        let manifest = Fixtures.manifest(ids: [101])
        let transport = StubTransport()
        transport.playlistPages = [[Fixtures.playlist(id: "p.1", name: "Twin"),
                                    Fixtures.playlist(id: "p.2", name: "Twin")]]
        transport.libraryPages = [[]]

        let result = await makeEngine(transport).preflightPlaylist(named: "Twin", manifest: manifest)

        XCTAssertEqual(result, .stop(.playlistAmbiguous(name: "Twin", count: 2)))
    }

    func testPreflightStopsWhenNotEditable() async throws {
        let manifest = Fixtures.manifest(ids: [101])
        let transport = StubTransport()
        transport.playlistPages = [[Fixtures.playlist(id: "p.locked", name: "Locked", canEdit: false)]]
        transport.libraryPages = [[]]

        let result = await makeEngine(transport).preflightPlaylist(named: "Locked", manifest: manifest)

        XCTAssertEqual(result, .stop(.playlistNotEditable(playlistId: "p.locked")))
    }

    func testPreflightStopsOnUnsafeStates() async throws {
        let manifest = Fixtures.manifest(ids: [101, 102, 103])
        for tracks in [[102, 101], [101, 101], [101, 999], [101, nil]] {
            let transport = StubTransport()
            transport.playlistPages = [[Fixtures.playlist(id: "p.x", name: "X")]]
            transport.libraryPages = [[]]
            transport.playlistTracks["p.x"] = tracks.map {
                $0.map { Fixtures.librarySong(libraryId: "i.\($0)", catalogId: $0) }
                    ?? Fixtures.unidentifiedLibrarySong(libraryId: "i.u")
            }

            let result = await makeEngine(transport).preflightPlaylist(named: "X", manifest: manifest)

            guard case .stop(.playlistNotSafeToWrite(_, let state)) = result else {
                return XCTFail("expected stop for tracks \(tracks), got \(result)")
            }
            XCTAssertFalse(state.isSafeToWrite)
        }
    }

    // MARK: - Plan derivation

    func testPlanFromEmptyPlaylistCoversWholeManifest() async throws {
        let manifest = Fixtures.manifest(ids: [101, 102, 103])
        let transport = Fixtures.happyPathTransport(manifest: manifest,
                                                    playlistName: "Target",
                                                    libraryHas: [101, 102, 103])
        let engine = makeEngine(transport)
        let preflight = await engine.preflightPlaylist(named: "Target", manifest: manifest)
        let library = try await engine.enumerateLibrary()

        let plan = try RESTEngine.deriveAppendPlan(preflight: preflight, manifest: manifest,
                                                   library: library).get()

        XCTAssertEqual(plan.steps.map(\.pos), [1, 2, 3])
        XCTAssertEqual(plan.steps.map(\.catalogId), [101, 102, 103])
        XCTAssertEqual(plan.steps.map(\.librarySongId), ["i.101", "i.102", "i.103"])
        XCTAssertEqual(plan.manifestCatalogIds, [101, 102, 103])
    }

    func testPlanFromCorrectPrefixCoversSuffixOnly() async throws {
        let manifest = Fixtures.manifest(ids: [101, 102, 103, 104])
        let transport = Fixtures.happyPathTransport(manifest: manifest,
                                                    playlistName: "Target",
                                                    libraryHas: [101, 102, 103, 104])
        transport.playlistTracks["p.test"] = [
            Fixtures.librarySong(libraryId: "i.101", catalogId: 101),
            Fixtures.librarySong(libraryId: "i.102", catalogId: 102),
        ]
        let engine = makeEngine(transport)
        let preflight = await engine.preflightPlaylist(named: "Target", manifest: manifest)
        let library = try await engine.enumerateLibrary()

        let plan = try RESTEngine.deriveAppendPlan(preflight: preflight, manifest: manifest,
                                                   library: library).get()

        XCTAssertEqual(plan.steps.map(\.catalogId), [103, 104], "correct prefix is preserved")
        XCTAssertEqual(plan.steps.map(\.pos), [3, 4])
    }

    func testPlanFromExactCompleteIsEmpty() async throws {
        let manifest = Fixtures.manifest(ids: [101, 102])
        let transport = Fixtures.happyPathTransport(manifest: manifest,
                                                    playlistName: "Target",
                                                    libraryHas: [101, 102])
        transport.playlistTracks["p.test"] = [
            Fixtures.librarySong(libraryId: "i.101", catalogId: 101),
            Fixtures.librarySong(libraryId: "i.102", catalogId: 102),
        ]
        let engine = makeEngine(transport)
        let preflight = await engine.preflightPlaylist(named: "Target", manifest: manifest)
        let library = try await engine.enumerateLibrary()

        let plan = try RESTEngine.deriveAppendPlan(preflight: preflight, manifest: manifest,
                                                   library: library).get()

        XCTAssertTrue(plan.steps.isEmpty)
    }

    func testPlanFailsClosedWhenLibraryIdUnknown() async throws {
        let manifest = Fixtures.manifest(ids: [101, 102])
        let transport = Fixtures.happyPathTransport(manifest: manifest,
                                                    playlistName: "Target",
                                                    libraryHas: [101])  // 102 never reconciled
        let engine = makeEngine(transport)
        let preflight = await engine.preflightPlaylist(named: "Target", manifest: manifest)
        let library = try await engine.enumerateLibrary()

        let result = RESTEngine.deriveAppendPlan(preflight: preflight, manifest: manifest,
                                                 library: library)

        XCTAssertEqual(result, .failure(.librarySongMissing(catalogId: 102)))
    }

    // MARK: - Plan execution (append-only discipline)

    func testExecutePlanAppendsEachStepInOrder() async throws {
        let manifest = Fixtures.manifest(ids: [101, 102, 103])
        let transport = Fixtures.happyPathTransport(manifest: manifest,
                                                    playlistName: "Target",
                                                    libraryHas: [101, 102, 103])
        let engine = makeEngine(transport)
        let preflight = await engine.preflightPlaylist(named: "Target", manifest: manifest)
        let library = try await engine.enumerateLibrary()
        let plan = try RESTEngine.deriveAppendPlan(preflight: preflight, manifest: manifest,
                                                   library: library).get()

        let outcomes = try await engine.executeAppendPlan(plan)

        XCTAssertEqual(outcomes.map(\.catalogId), [101, 102, 103])
        XCTAssertEqual(transport.calls.filter { $0.name == "append" }.map(\.detail),
                       ["p.test:i.101", "p.test:i.102", "p.test:i.103"],
                       "appends must follow plan order exactly")
    }

    func testExecutePlanStopsOnDrift() async throws {
        // Someone adds a track between plan and execute: the fresh
        // preflight must catch it and refuse to write.
        let manifest = Fixtures.manifest(ids: [101, 102, 103])
        let transport = Fixtures.happyPathTransport(manifest: manifest,
                                                    playlistName: "Target",
                                                    libraryHas: [101, 102, 103])
        let engine = makeEngine(transport)
        let preflight = await engine.preflightPlaylist(named: "Target", manifest: manifest)
        let library = try await engine.enumerateLibrary()
        let plan = try RESTEngine.deriveAppendPlan(preflight: preflight, manifest: manifest,
                                                   library: library).get()

        // Drift: playlist now contains an unrelated track.
        transport.playlistTracks["p.test"] = [Fixtures.librarySong(libraryId: "i.999", catalogId: 999)]

        do {
            _ = try await engine.executeAppendPlan(plan)
            XCTFail("must refuse to execute on drifted state")
        } catch let error as AMError {
            guard case .playlistNotSafeToWrite = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertFalse(transport.calls.contains { $0.name == "append" },
                           "no write may be issued after drift detection")
        }
    }

    func testExecutePlanStopsAtFirstAppendFailure() async throws {
        let manifest = Fixtures.manifest(ids: [101, 102, 103])
        let transport = Fixtures.happyPathTransport(manifest: manifest,
                                                    playlistName: "Target",
                                                    libraryHas: [101, 102, 103])
        transport.appendStatuses = ["i.102": 500]
        let engine = makeEngine(transport)
        let preflight = await engine.preflightPlaylist(named: "Target", manifest: manifest)
        let library = try await engine.enumerateLibrary()
        let plan = try RESTEngine.deriveAppendPlan(preflight: preflight, manifest: manifest,
                                                   library: library).get()

        do {
            _ = try await engine.executeAppendPlan(plan)
            XCTFail("must throw on append failure")
        } catch let error as AMError {
            XCTAssertEqual(error, .playlistAppendFailed(pos: 2, catalogId: 102,
                                                        librarySongId: "i.102", httpStatus: 500))
            XCTAssertFalse(transport.calls.contains { $0.name == "append" && $0.detail == "p.test:i.103" },
                          "no further writes after a failure")
        }
    }

    // MARK: - Independent final verification (§16)

    func testVerifyPlaylistPassesExactSequence() {
        let manifest = Fixtures.manifest(ids: [101, 102, 103])
        let tracks = manifest.entries.map { Fixtures.librarySong(libraryId: "i.\($0.catalogId)",
                                                                 catalogId: $0.catalogId) }

        let verification = RESTEngine.verifyPlaylist(playlistId: "p", manifest: manifest,
                                                     tracks: tracks, shareUrl: "https://…")

        XCTAssertTrue(verification.verified)
        XCTAssertTrue(verification.orderingPass)
        XCTAssertTrue(verification.duplicates.isEmpty)
        XCTAssertTrue(verification.unexpectedCatalogIds.isEmpty)
        XCTAssertEqual(verification.unidentifiableTrackCount, 0)
    }

    func testVerifyPlaylistCatchesEveryFailureMode() {
        let manifest = Fixtures.manifest(ids: [101, 102, 103])
        func verify(_ trackIds: [Int?]) -> PlaylistVerification {
            let tracks = trackIds.map {
                $0.map { Fixtures.librarySong(libraryId: "i.\($0)", catalogId: $0) }
                    ?? Fixtures.unidentifiedLibrarySong(libraryId: "i.u")
            }
            return RESTEngine.verifyPlaylist(playlistId: "p", manifest: manifest,
                                             tracks: tracks, shareUrl: nil)
        }

        XCTAssertFalse(verify([101, 102]).verified, "too short")
        XCTAssertFalse(verify([101, 102, 103, 101]).verified, "duplicate appended")
        XCTAssertFalse(verify([101, 102, 999]).verified, "unexpected track")
        XCTAssertFalse(verify([101, 103, 102]).verified, "wrong order")
        XCTAssertFalse(verify([101, 102, nil]).verified, "unidentifiable track")
        XCTAssertTrue(verify([101, 102, 103]).verified)

        let dup = verify([101, 101, 102, 103])
        XCTAssertEqual(dup.duplicates, [101], "duplicates listed deterministically")
        XCTAssertFalse(dup.orderingPass)
    }

    // MARK: - End-to-end transaction over the real 17-track manifest

    /// The full Phase 4 sequence, run against a scripted live-equivalent
    /// server: catalog validation → preflight → library reconciliation →
    /// plan → execution → fresh-read verification. Proves the canonical
    /// flow derives one plan and executes it exactly.
    func testEndToEndTransactionOverRealManifest() async throws {
        let manifest = try Fixtures.afterHoursManifest()
        XCTAssertEqual(manifest.entries.count, 17)

        // Library already holds 12 of the 17; playlist is empty.
        let presentIds = Array(manifest.entries.map(\.catalogId).prefix(12))
        let transport = Fixtures.happyPathTransport(manifest: manifest,
                                                    playlistName: "After Hours — Violin & Trumpet",
                                                    libraryHas: presentIds)
        let engine = makeEngine(transport)

        // Gate 3: catalog 17/17.
        let catalogReport = await engine.validateCatalog(manifest: manifest)
        XCTAssertTrue(catalogReport.passed)
        XCTAssertEqual(catalogReport.entries.count, 17)

        // Preflight: unique, editable, empty.
        let preflight = await engine.preflightPlaylist(named: "After Hours — Violin & Trumpet",
                                                       manifest: manifest)
        guard case .ok(_, .empty, let missing) = preflight else {
            return XCTFail("expected safe preflight, got \(preflight)")
        }
        XCTAssertEqual(missing.count, 17)

        // Library reconciliation: 5 missing, in manifest order.
        let library = try await engine.enumerateLibrary()
        let reconciliation = RESTEngine.reconcile(manifest: manifest, library: library)
        XCTAssertEqual(reconciliation.present.count, 12)
        XCTAssertEqual(reconciliation.missing.map(\.pos), [13, 14, 15, 16, 17])

        // Add missing (one request each), then fresh-read verify.
        let addOutcomes = try await engine.addMissingToLibrary(reconciliation.missing)
        XCTAssertEqual(addOutcomes.map(\.httpStatus), Array(repeating: 202, count: 5))
        XCTAssertEqual(transport.calls.filter { $0.name == "libraryAdd" }.count, 5)

        // The library now contains all 17: script the fresh read.
        transport.libraryPages = [manifest.entries.map {
            Fixtures.librarySong(libraryId: "i.\($0.catalogId)", catalogId: $0.catalogId)
        }]
        let libraryVerification = await engine.verifyLibrary(manifest: manifest)
        XCTAssertTrue(libraryVerification.verified)
        XCTAssertEqual(libraryVerification.attempts, 1)

        // Plan covers the full manifest, positions 1...17.
        let plan = try RESTEngine.deriveAppendPlan(preflight: preflight, manifest: manifest,
                                                   library: libraryVerification.catalogToLibraryId).get()
        XCTAssertEqual(plan.steps.map(\.pos), Array(1...17))
        XCTAssertEqual(plan.steps.map(\.catalogId), manifest.entries.map(\.catalogId))

        // Execute exactly the plan.
        let appendOutcomes = try await engine.executeAppendPlan(plan)
        XCTAssertEqual(appendOutcomes.count, 17)
        XCTAssertEqual(appendOutcomes.map(\.httpStatus), Array(repeating: 204, count: 17))
        XCTAssertEqual(transport.calls.filter { $0.name == "append" }.map(\.detail),
                       manifest.entries.map { "p.test:i.\($0.catalogId)" })

        // Independent read-back (§16): server state == manifest exactly.
        transport.playlistTracks["p.test"] = manifest.entries.map {
            Fixtures.librarySong(libraryId: "i.\($0.catalogId)", catalogId: $0.catalogId)
        }
        let tracks = try await transport.getPlaylistTracks(playlistId: "p.test")
        let verification = RESTEngine.verifyPlaylist(playlistId: "p.test", manifest: manifest,
                                                     tracks: tracks, shareUrl: nil)
        XCTAssertTrue(verification.verified)
        XCTAssertTrue(verification.orderingPass)
        XCTAssertEqual(verification.unexpectedCatalogIds, [])
        XCTAssertEqual(verification.duplicates, [])
    }

    /// Idempotency (§19): a completed playlist preflights as
    /// exactComplete, derives an empty plan, and issues no writes.
    func testIdempotentRerunOnCompletePlaylist() async throws {
        let manifest = try Fixtures.afterHoursManifest()
        let completeTracks = manifest.entries.map {
            Fixtures.librarySong(libraryId: "i.\($0.catalogId)", catalogId: $0.catalogId)
        }
        let transport = StubTransport()
        for entry in manifest.entries {
            transport.catalogSongs[entry.catalogId] = Fixtures.catalogSong(
                catalogId: entry.catalogId, name: entry.name, artist: entry.artist)
        }
        transport.playlistPages = [[Fixtures.playlist(id: "p.done",
                                                       name: "After Hours — Violin & Trumpet")]]
        transport.playlistTracks["p.done"] = completeTracks
        transport.libraryPages = [completeTracks]
        let engine = makeEngine(transport)

        let preflight = await engine.preflightPlaylist(named: "After Hours — Violin & Trumpet",
                                                       manifest: manifest)
        guard case .ok(_, let state, let missing) = preflight else {
            return XCTFail("got \(preflight)")
        }
        XCTAssertEqual(state, .exactComplete)
        XCTAssertTrue(missing.isEmpty)

        let library = try await engine.enumerateLibrary()
        let plan = try RESTEngine.deriveAppendPlan(preflight: preflight, manifest: manifest,
                                                   library: library).get()
        XCTAssertTrue(plan.steps.isEmpty)

        let outcomes = try await engine.executeAppendPlan(plan)
        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertFalse(transport.calls.contains { $0.name == "append" })
    }

    // MARK: - §14 per-step write discipline

    /// Task requirement: "sequential insertion with verification before
    /// advancing." After every append, execution must re-read the playlist
    /// and prove the stored prefix grew by exactly that one track before
    /// the next write. Proven by counting fresh reads: one per step.
    func testExecutePlanReVerifiesAfterEveryStep() async throws {
        let manifest = Fixtures.manifest(ids: [101, 102, 103])
        let transport = Fixtures.happyPathTransport(manifest: manifest,
                                                    playlistName: "Target",
                                                    libraryHas: [101, 102, 103])
        let engine = makeEngine(transport)
        let preflight = await engine.preflightPlaylist(named: "Target", manifest: manifest)
        let library = try await engine.enumerateLibrary()
        let plan = try RESTEngine.deriveAppendPlan(preflight: preflight, manifest: manifest,
                                                   library: library).get()

        _ = try await engine.executeAppendPlan(plan)

        // Reads recorded: test's own preflight (1) + executeAppendPlan's
        // fresh re-preflight (1) + one verification read per step (3).
        let trackReads = transport.calls.filter { $0.name == "playlistTracks" }.count
        XCTAssertEqual(trackReads, plan.steps.count + 2,
                       "re-preflight plus one fresh read after each append")
        XCTAssertEqual(transport.playlistTracks["p.test"]?.map(\.catalogId), [101, 102, 103])
    }

    /// Propagation lag (§14: "allow bounded propagation; re-verify state"):
    /// if the first post-append read lags one attempt behind, verification
    /// retries and succeeds on the next read — the transaction advances
    /// only once the state is actually known.
    func testExecutePlanRetriesWhenPropagationLags() async throws {
        let manifest = Fixtures.manifest(ids: [101, 102])
        let transport = Fixtures.happyPathTransport(manifest: manifest,
                                                    playlistName: "Target",
                                                    libraryHas: [101, 102])
        transport.appendsMutateTracks = false   // server "delays" visibility
        var appendCount = 0
        transport.appendHook = { playlistId, librarySongId in
            appendCount += 1
            if let song = transport.librarySongsById[librarySongId] {
                transport.playlistTracks[playlistId, default: []].append(song)
            }
            transport.appendVisibilityLag = (appendCount == 1) ? 1 : 0
            return 204
        }
        let engine = makeEngine(transport)
        let preflight = await engine.preflightPlaylist(named: "Target", manifest: manifest)
        let library = try await engine.enumerateLibrary()
        let plan = try RESTEngine.deriveAppendPlan(preflight: preflight, manifest: manifest,
                                                   library: library).get()

        let outcomes = try await engine.executeAppendPlan(plan)
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertEqual(transport.playlistTracks["p.test"]?.map(\.catalogId), [101, 102])
    }

    /// Run-71 regression: the post-append read may lag SEVERAL attempts
    /// (iCloud eventual consistency, observed ~60s live) before the
    /// stored prefix is provable. With a dedicated append-verification
    /// budget, the engine keeps re-reading and eventually confirms —
    /// the transaction advances only on proof, never on patience expiry.
    func testExecutePlanConfirmsWhenAppendReadLagsSeveralAttempts() async throws {
        let manifest = Fixtures.manifest(ids: [101, 102])
        let transport = Fixtures.happyPathTransport(manifest: manifest,
                                                    playlistName: "Target",
                                                    libraryHas: [101, 102])
        transport.appendsMutateTracks = false
        var appendCount = 0
        transport.appendHook = { playlistId, librarySongId in
            appendCount += 1
            if let song = transport.librarySongsById[librarySongId] {
                transport.playlistTracks[playlistId, default: []].append(song)
            }
            // Lag the first append THREE reads deep — beyond the old
            // library-verification budget, within the new append budget.
            transport.appendVisibilityLag = (appendCount == 1) ? 3 : 0
            return 204
        }
        let engine = RESTEngine(transport: transport, config: .init(
            storefront: "us", maxLibraryPages: 100, maxPlaylistPages: 20,
            propagateDelayMilliseconds: 0,
            verificationRetries: 1, verificationBackoffMilliseconds: 0,
            appendVerificationRetries: 5, appendVerificationBackoffMilliseconds: 0,
            createRediscoveryRetries: 1, createRediscoveryBackoffMilliseconds: 0))
        let preflight = await engine.preflightPlaylist(named: "Target", manifest: manifest)
        let library = try await engine.enumerateLibrary()
        let plan = try RESTEngine.deriveAppendPlan(preflight: preflight, manifest: manifest,
                                                   library: library).get()

        let outcomes = try await engine.executeAppendPlan(plan)
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertEqual(transport.playlistTracks["p.test"]?.map(\.catalogId), [101, 102])
    }

    /// Property sweep (run-71 class): for every stale-read depth d from 0
    /// to the append budget, verifyStoredPrefix either confirms (d within
    /// budget) or STOPs with playlistVerificationFailed (d exceeds it) —
    /// never advances on an unproven step, never fabricates success.
    func testAppendVerificationBudgetBoundaryProperty() async throws {
        let ids = [101, 102]
        for d in 0...5 {
            let manifest = Fixtures.manifest(ids: ids)
            let transport = Fixtures.happyPathTransport(manifest: manifest,
                                                        playlistName: "Target",
                                                        libraryHas: ids)
            transport.appendsMutateTracks = false
            var appendCount = 0
            transport.appendHook = { playlistId, librarySongId in
                appendCount += 1
                if let song = transport.librarySongsById[librarySongId] {
                    transport.playlistTracks[playlistId, default: []].append(song)
                }
                transport.appendVisibilityLag = (appendCount == 1) ? d : 0
                return 204
            }
            let budget = 4
            let engine = RESTEngine(transport: transport, config: .init(
                storefront: "us", maxLibraryPages: 100, maxPlaylistPages: 20,
                propagateDelayMilliseconds: 0,
                verificationRetries: 1, verificationBackoffMilliseconds: 0,
                appendVerificationRetries: budget, appendVerificationBackoffMilliseconds: 0,
                createRediscoveryRetries: 1, createRediscoveryBackoffMilliseconds: 0))
            let preflight = await engine.preflightPlaylist(named: "Target", manifest: manifest)
            let library = try await engine.enumerateLibrary()
            let plan = try RESTEngine.deriveAppendPlan(preflight: preflight, manifest: manifest,
                                                       library: library).get()

            do {
                let outcomes = try await engine.executeAppendPlan(plan)
                XCTAssertTrue(d < budget, "depth \(d) must not confirm within budget \(budget)")
                XCTAssertEqual(outcomes.count, 2)
            } catch let error as AMError {
                guard case .playlistVerificationFailed = error else {
                    return XCTFail("depth \(d): unexpected error \(error)")
                }
                XCTAssertTrue(d >= budget, "depth \(d) within budget \(budget) must confirm, not stop")
                XCTAssertEqual(transport.calls.filter { $0.name == "append" }.count, 1,
                               "no second write after an unproven first")
            }
        }
    }

    /// A write that never becomes visible is a stop condition: execution
    /// must not advance to the next step after a permanently-lagging append.
    func testExecutePlanStopsWhenWriteNeverBecomesVisible() async throws {
        let manifest = Fixtures.manifest(ids: [101, 102])
        let transport = Fixtures.happyPathTransport(manifest: manifest,
                                                    playlistName: "Target",
                                                    libraryHas: [101, 102])
        transport.appendsMutateTracks = false   // accepted but never stored
        let engine = makeEngine(transport)
        let preflight = await engine.preflightPlaylist(named: "Target", manifest: manifest)
        let library = try await engine.enumerateLibrary()
        let plan = try RESTEngine.deriveAppendPlan(preflight: preflight, manifest: manifest,
                                                   library: library).get()

        do {
            _ = try await engine.executeAppendPlan(plan)
            XCTFail("must stop when a write never becomes visible")
        } catch let error as AMError {
            guard case .playlistVerificationFailed = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(transport.calls.filter { $0.name == "append" }.count, 1,
                           "the second write must never be issued")
        }
    }

    /// Adversarial: a concurrent editor inserts a foreign track between the
    /// first and second appends. The post-append verification read must
    /// catch the unsafe state and stop — no further writes, deterministic
    /// failure.
    func testExecutePlanStopsOnConcurrentForeignInsert() async throws {
        let manifest = Fixtures.manifest(ids: [101, 102])
        let transport = Fixtures.happyPathTransport(manifest: manifest,
                                                    playlistName: "Target",
                                                    libraryHas: [101, 102])
        var appendedFirst = false
        transport.appendHook = { playlistId, librarySongId in
            if !appendedFirst {
                appendedFirst = true
                if let song = transport.librarySongsById[librarySongId] {
                    transport.playlistTracks[playlistId, default: []].append(song)
                }
                // Concurrent editor drops a foreign track in behind us.
                transport.playlistTracks[playlistId]!.append(
                    Fixtures.librarySong(libraryId: "i.foreign", catalogId: 999))
            } else {
                if let song = transport.librarySongsById[librarySongId] {
                    transport.playlistTracks[playlistId, default: []].append(song)
                }
            }
            return 204
        }
        let engine = makeEngine(transport)
        let preflight = await engine.preflightPlaylist(named: "Target", manifest: manifest)
        let library = try await engine.enumerateLibrary()
        let plan = try RESTEngine.deriveAppendPlan(preflight: preflight, manifest: manifest,
                                                   library: library).get()

        do {
            _ = try await engine.executeAppendPlan(plan)
            XCTFail("must stop on concurrent foreign insert")
        } catch let error as AMError {
            guard case .playlistVerificationFailed = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(transport.calls.filter { $0.name == "append" }.count, 1,
                           "no write may follow an unsafe observed state")
        }
    }
}
