import XCTest
@testable import TunoryCore

/// TransactionRunner tests: the canonical §20 sequence that Phase 4 proved
/// live and Phase 5 extracted for the GUI. Adversarial cases prove the
/// stop conditions and the create-playlist gating.
final class TransactionRunnerTests: XCTestCase {

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
        // Real-server behavior: accepted adds become visible to the next
        // fresh enumeration (§11) — the runner's post-add verify depends
        // on this, not on the 202 acknowledgment.
        t.addsBecomeVisibleInLibrary = true
        t.playlistTracks["p.test"] = playlistTracks.map {
            Fixtures.librarySong(libraryId: "i.\($0)", catalogId: $0)
        }
        return t
    }

    // MARK: - Happy path (library already complete → append-only)

    func testFullTransactionAppendsMissingSuffixAndVerifies() async {
        let ids = [101, 102, 103]
        // Library missing one; playlist has a correct prefix of 1.
        let t = transportFor(ids: ids, playlistName: "P", libraryHas: [101, 102],
                              playlistTracks: [101])
        let manifest = Fixtures.manifest(ids: ids)

        var reported: [TransactionPhaseOutcome.Kind] = []
        let report = await makeRunner(t).run(manifest: manifest, playlistName: "P") {
            reported.append($0.kind)
        }

        // Phase order is exactly the canonical sequence.
        XCTAssertEqual(reported, [.catalogGate, .preflight, .reconcile,
                                  .libraryAdd, .libraryVerify, .plan,
                                  .execute, .finalReadback])
        XCTAssertTrue(report.succeeded)
        XCTAssertEqual(report.phases.last?.kind, .finalReadback)
        XCTAssertNil(report.phases.first(where: { $0.kind == .stopped })?.error)

        // Server state: playlist stores the exact manifest sequence.
        XCTAssertEqual(t.storedTracks(playlistId: "p.test").map(\.catalogId),
                       [101, 102, 103])
        // §12: one enumeration for reconcile + one post-add verify —
        // never one per track.
        let libraryPages = t.calls.filter { $0.name == "libraryPage" }
        XCTAssertEqual(libraryPages.count, 2, "reconcile + post-add verify; never per-track")
        // No unexpected mutation: the correct prefix track was preserved.
        XCTAssertTrue(t.calls.contains(StubTransport.Call(name: "append", detail: "p.test:i.103")))
    }

    // MARK: - Idempotent no-op (§13/§19)

    func testExactCompleteIsVerifiedNoOp() async {
        let ids = [101, 102]
        let t = transportFor(ids: ids, playlistName: "P",
                              libraryHas: ids, playlistTracks: ids)
        let manifest = Fixtures.manifest(ids: ids)

        let report = await makeRunner(t).run(manifest: manifest, playlistName: "P")

        XCTAssertTrue(report.succeeded)
        XCTAssertEqual(report.plan?.steps.count, 0)
        XCTAssertEqual(t.calls.filter { $0.name == "append" }.count, 0,
                       "exactComplete must not be re-written")
        XCTAssertEqual(t.calls.filter { $0.name == "libraryAdd" }.count, 0)
        // §12 single-enumeration: reconcile IS the fresh read.
        XCTAssertEqual(t.calls.filter { $0.name == "libraryPage" }.count, 1)
    }

    // MARK: - §20 stop conditions (adversarial)

    func testCatalogGateFailureStopsBeforeAnyWrite() async {
        let ids = [101, 404]
        let t = transportFor(ids: ids, playlistName: "P", libraryHas: ids,
                             playlistTracks: [])
        t.catalogSongs[404] = nil   // one recording does not exist
        let manifest = Fixtures.manifest(ids: ids)

        let report = await makeRunner(t).run(manifest: manifest, playlistName: "P")

        XCTAssertFalse(report.succeeded)
        guard case .catalogLookupFailed(let id, _)? = report.phases.last?.error else {
            return XCTFail("expected catalogLookupFailed, got \(report.phases)")
        }
        XCTAssertEqual(id, 404)
        XCTAssertEqual(t.calls.filter { $0.name == "append" }.count, 0)
        XCTAssertEqual(t.calls.filter { $0.name == "libraryAdd" }.count, 0)
        XCTAssertEqual(t.calls.filter { $0.name == "createPlaylist" }.count, 0)
    }

    func testUnsafePlaylistStateStopsBeforeWrites() async {
        let ids = [101, 102]
        // Playlist stores a track NOT in the manifest → unrelated → stop.
        let t = transportFor(ids: ids, playlistName: "P", libraryHas: ids,
                             playlistTracks: [999])
        let manifest = Fixtures.manifest(ids: ids)

        let report = await makeRunner(t).run(manifest: manifest, playlistName: "P")

        XCTAssertFalse(report.succeeded)
        guard case .playlistNotSafeToWrite(_, let state)? = report.phases.last?.error else {
            return XCTFail("expected playlistNotSafeToWrite, got \(report.phases)")
        }
        XCTAssertEqual(state, .containsUnrelatedTracks)
        XCTAssertEqual(t.calls.filter { $0.name == "append" }.count, 0)
        // The library add phase never runs (preflight stops first).
        XCTAssertEqual(t.calls.filter { $0.name == "libraryAdd" }.count, 0)
    }

    func testAmbiguousPlaylistNameStops() async {
        let ids = [101]
        let t = transportFor(ids: ids, playlistName: "P", libraryHas: ids)
        // Two playlists with the same name.
        t.playlistPages = [[Fixtures.playlist(id: "p.a", name: "P"),
                            Fixtures.playlist(id: "p.b", name: "P")]]
        let manifest = Fixtures.manifest(ids: ids)

        let report = await makeRunner(t).run(manifest: manifest, playlistName: "P")

        XCTAssertFalse(report.succeeded)
        guard case .playlistAmbiguous(let name, let count)? = report.phases.last?.error else {
            return XCTFail("expected playlistAmbiguous, got \(report.phases)")
        }
        XCTAssertEqual(name, "P")
        XCTAssertEqual(count, 2)
    }

    // MARK: - Create-playlist policy (GUI "Create playlist" step)

    func testStopPolicyNeverCreates() async {
        let ids = [101]
        let t = transportFor(ids: ids, playlistName: "P", libraryHas: ids)
        t.playlistPages = []   // no playlists at all
        let manifest = Fixtures.manifest(ids: ids)

        let report = await makeRunner(t).run(manifest: manifest, playlistName: "P",
                                             missingPlaylistPolicy: .stop)

        XCTAssertFalse(report.succeeded)
        guard case .playlistNotFound? = report.phases.last?.error else {
            return XCTFail("expected playlistNotFound, got \(report.phases)")
        }
        XCTAssertEqual(t.calls.filter { $0.name == "createPlaylist" }.count, 0)
    }

    func testCreatePolicyCreatesOnlyAfterUniquenessProofThenCompletes() async {
        let ids = [101, 102]
        let t = transportFor(ids: ids, playlistName: "P", libraryHas: [101])
        t.playlistPages = []   // name proven uniquely absent
        let manifest = Fixtures.manifest(ids: ids)

        var kinds: [TransactionPhaseOutcome.Kind] = []
        let report = await makeRunner(t).run(manifest: manifest, playlistName: "P",
                                            missingPlaylistPolicy: .create) {
            kinds.append($0.kind)
        }

        // Creation happened exactly once, after discovery returned not-found.
        XCTAssertEqual(t.calls.filter { $0.name == "createPlaylist" }.count, 1)
        XCTAssertTrue(report.succeeded)
        // The created playlist received the exact sequence.
        XCTAssertEqual(t.storedTracks(playlistId: t.createdPlaylistId).map(\.catalogId),
                       [101, 102])
        XCTAssertEqual(kinds.first, .catalogGate)
        XCTAssertTrue(kinds.contains(.finalReadback))
        // The stub register the appended songs server-side.
        XCTAssertEqual(t.calls.filter { $0.name == "append" }.count, 2)
    }

    func testCreatePolicyDoesNotCreateWhenNameExistsAmbiguous() async {
        let ids = [101]
        let t = transportFor(ids: ids, playlistName: "P", libraryHas: ids)
        t.playlistPages = [[Fixtures.playlist(id: "p.a", name: "P"),
                            Fixtures.playlist(id: "p.b", name: "P")]]
        let manifest = Fixtures.manifest(ids: ids)

        let report = await makeRunner(t).run(manifest: manifest, playlistName: "P",
                                            missingPlaylistPolicy: .create)

        // Ambiguity is NOT not-found: no creation, stop stands.
        XCTAssertFalse(report.succeeded)
        XCTAssertEqual(t.calls.filter { $0.name == "createPlaylist" }.count, 0)
        guard case .playlistAmbiguous? = report.phases.last?.error else {
            return XCTFail("expected playlistAmbiguous, got \(report.phases)")
        }
    }

    func testCreatePolicyCreationFailureStops() async {
        let ids = [101]
        let t = transportFor(ids: ids, playlistName: "P", libraryHas: ids)
        t.playlistPages = []
        t.createPlaylistStatus = 403   // server refuses
        let manifest = Fixtures.manifest(ids: ids)

        let report = await makeRunner(t).run(manifest: manifest, playlistName: "P",
                                            missingPlaylistPolicy: .create)

        XCTAssertFalse(report.succeeded)
        guard case .playlistCreationFailed(let status)? = report.phases.last?.error else {
            return XCTFail("expected playlistCreationFailed, got \(report.phases)")
        }
        XCTAssertEqual(status, 403)
        XCTAssertEqual(t.calls.filter { $0.name == "libraryAdd" }.count, 0)
        XCTAssertEqual(t.calls.filter { $0.name == "append" }.count, 0)
    }

    /// Run-69 regression: after a proven 201 create, iCloud may not show the
    /// new playlist in the library listing for several reads. The runner's
    /// re-discovery retries ONLY not-found within its bounded budget and
    /// then completes the transaction on proof.
    func testCreatePolicyRediscoverySucceedsWhenCreateLags() async {
        let ids = [101, 102]
        let t = transportFor(ids: ids, playlistName: "P", libraryHas: [101])
        t.playlistPages = []   // name proven uniquely absent
        t.addsBecomeVisibleInLibrary = true
        t.createVisibilityLag = 2   // hidden from the next 2 playlist reads
        let manifest = Fixtures.manifest(ids: ids)

        var reports: [String] = []
        let report = await makeRunner(t).run(manifest: manifest, playlistName: "P",
                                            missingPlaylistPolicy: .create) { phase in
            reports.append(phase.report)
        }

        XCTAssertEqual(t.calls.filter { $0.name == "createPlaylist" }.count, 1,
                       "creation must happen exactly once")
        XCTAssertTrue(report.succeeded)
        XCTAssertEqual(t.storedTracks(playlistId: t.createdPlaylistId).map(\.catalogId),
                       [101, 102])
        XCTAssertTrue(reports.contains { $0.contains("not yet visible (attempt 1/3)") },
                      "each wait must be emitted as evidence: \(reports)")
    }

    /// Adversarial (run-69 class): when the create lag exceeds the
    /// rediscovery budget, the transaction still STOPs with
    /// playlistNotFound — success is never fabricated from the 201.
    func testCreatePolicyStopsWhenCreateLagExceedsRediscoveryBudget() async {
        let ids = [101]
        let t = transportFor(ids: ids, playlistName: "P", libraryHas: ids)
        t.playlistPages = []
        t.createVisibilityLag = 99   // hidden far beyond the test budget
        let manifest = Fixtures.manifest(ids: ids)

        let report = await makeRunner(t).run(manifest: manifest, playlistName: "P",
                                            missingPlaylistPolicy: .create)

        XCTAssertFalse(report.succeeded)
        guard case .playlistNotFound(let name)? = report.phases.last?.error else {
            return XCTFail("expected playlistNotFound, got \(report.phases)")
        }
        XCTAssertEqual(name, "P")
        XCTAssertEqual(t.calls.filter { $0.name == "libraryAdd" }.count, 0,
                       "no write may follow an unproven create")
        XCTAssertEqual(t.calls.filter { $0.name == "append" }.count, 0)
    }

    // MARK: - Drift: plan executes against fresh state, never blind

    func testDriftedPlaylistFailsClosed() async {
        let ids = [101, 102, 103]
        // Playlist empty at preflight; a foreign insert lands between plan
        // and execute — executeAppendPlan's fresh re-preflight must catch.
        let t = transportFor(ids: ids, playlistName: "P",
                             libraryHas: ids, playlistTracks: [])
        let manifest = Fixtures.manifest(ids: ids)

        var drifted = false
        t.appendHook = { playlistId, librarySongId in
            if !drifted, playlistId == "p.test" {
                drifted = true
                // Foreign insert after the first append: next fresh read
                // sees an unrelated track → execute stops.
                t.appendStored(playlistId: "p.test",
                               song: Fixtures.librarySong(libraryId: "i.999", catalogId: 999))
            }
            return 204
        }

        let report = await makeRunner(t).run(manifest: manifest, playlistName: "P")

        XCTAssertFalse(report.succeeded)
        // The stored state contains the foreign track and the transaction
        // never claimed success.
        XCTAssertTrue(t.storedTracks(playlistId: "p.test").map(\.catalogId).contains(999))
        XCTAssertTrue(report.phases.contains { $0.kind == .stopped })
    }
}

/// Local alias matching StubTransport.Call's shape for readable assertions.
private func Cmd(_ name: String, _ detail: String) -> StubTransport.Call {
    StubTransport.Call(name: name, detail: detail)
}
