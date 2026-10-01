import XCTest
@testable import TunoryCore

/// Phase 7 tests: the canonical AutomationResult derivation. These prove
/// the structured result file Hermes reads is a pure function of the
/// transaction evidence — never a re-decision, never a conflation of
/// acknowledgment with proof.
final class AutomationResultTests: XCTestCase {

    private func makeRunner(_ transport: StubTransport) -> TransactionRunner {
        TransactionRunner(engine: RESTEngine(transport: transport, config: .init(
            storefront: "us",
            maxLibraryPages: 100,
            maxPlaylistPages: 20,
            propagateDelayMilliseconds: 0,
            verificationRetries: 3,
            verificationBackoffMilliseconds: 0)))
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

    private let capturedAt: Int64 = 1_700_000_000_000

    // MARK: - Happy path

    func testHappyPathDerivesCompleteVerifiedResult() async {
        let ids = [101, 102, 103]
        // Library missing 103; playlist has a correct prefix of 1.
        let t = transportFor(ids: ids, playlistName: "P",
                              libraryHas: [101, 102], playlistTracks: [101])
        let manifest = Fixtures.manifest(ids: ids)
        let report = await makeRunner(t).run(manifest: manifest, playlistName: "P")
        let result = AutomationResultBuilder.build(manifest: manifest,
                                                    report: report,
                                                    capturedAtMillisSinceEpoch: capturedAt)

        // Top level: verified, playlist identity, full phase trail.
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.playlistName, "P")
        XCTAssertEqual(result.playlistId, "p.test")
        XCTAssertEqual(result.playlistStateBefore, "correctPrefix")
        XCTAssertEqual(result.playlistVerified, true)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.phases, ["catalog", "preflight", "reconcile",
                                        "library-add", "library-verify", "plan",
                                        "append", "final-readback"])
        XCTAssertNil(result.checkpoint)

        // Per-recording rows, manifest order.
        XCTAssertEqual(result.tracks.count, 3)
        XCTAssertEqual(result.tracks.map(\.pos), [1, 2, 3])
        XCTAssertEqual(result.tracks.map(\.catalogId), [101, 102, 103])
        XCTAssertTrue(result.tracks.allSatisfy { $0.catalogVerified })
        XCTAssertTrue(result.tracks.allSatisfy { $0.error == nil })

        // 101: already in library AND already stored at pos 1 (the correct
        // prefix is preserved — the plan never re-appends stored tracks).
        XCTAssertEqual(result.tracks[0].inLibraryBefore, true)
        XCTAssertEqual(result.tracks[0].libraryAddIssued, false)
        XCTAssertNil(result.tracks[0].libraryAddHttpStatus)
        XCTAssertEqual(result.tracks[0].inLibraryAfter, true)
        XCTAssertEqual(result.tracks[0].appendIssued, false)
        XCTAssertEqual(result.tracks[0].storedAtPosition, true)

        // 102: in library before; appended to pos 2.
        XCTAssertEqual(result.tracks[1].inLibraryBefore, true)
        XCTAssertEqual(result.tracks[1].appendIssued, true)
        XCTAssertEqual(result.tracks[1].storedAtPosition, true)

        // 103: MISSING before (fresh read), add issued (202 = acknowledged),
        // proven present after, appended, proven stored.
        XCTAssertEqual(result.tracks[2].inLibraryBefore, false)
        XCTAssertEqual(result.tracks[2].libraryAddIssued, true)
        XCTAssertEqual(result.tracks[2].libraryAddHttpStatus, 202)
        XCTAssertEqual(result.tracks[2].inLibraryAfter, true)
        XCTAssertEqual(result.tracks[2].appendIssued, true)
        XCTAssertEqual(result.tracks[2].appendHttpStatus, 204)
        XCTAssertEqual(result.tracks[2].storedAtPosition, true)
    }

    // MARK: - Determinism (pure function)

    func testDerivationIsDeterministic() async {
        let ids = [101, 102]
        let manifest = Fixtures.manifest(ids: ids)
        let t = transportFor(ids: ids, playlistName: "P", libraryHas: ids,
                             playlistTracks: [])
        let report = await makeRunner(t).run(manifest: manifest, playlistName: "P")
        let a = AutomationResultBuilder.build(manifest: manifest, report: report,
                                               capturedAtMillisSinceEpoch: capturedAt)
        let b = AutomationResultBuilder.build(manifest: manifest, report: report,
                                               capturedAtMillisSinceEpoch: capturedAt)
        XCTAssertEqual(a, b)

        // Same evidence → identical encoded bytes (stable contract for
        // Hermes-side hashing/diffing).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let dataA = try! encoder.encode(a)
        let dataB = try! encoder.encode(b)
        XCTAssertEqual(dataA, dataB)
    }

    // MARK: - Codable round-trip (the file contract)

    func testResultRoundTripsThroughJSON() async throws {
        let ids = [101, 102]
        let manifest = Fixtures.manifest(ids: ids)
        let t = transportFor(ids: ids, playlistName: "P", libraryHas: ids,
                             playlistTracks: [])
        let report = await makeRunner(t).run(manifest: manifest, playlistName: "P")
        let result = AutomationResultBuilder.build(manifest: manifest,
                                                    report: report,
                                                    capturedAtMillisSinceEpoch: capturedAt)
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(AutomationResult.self, from: data)
        XCTAssertEqual(decoded, result)
    }

    // MARK: - Stop conditions surface typed errors

    func testCatalogGateStopSurfacesTypedErrorAndRowError() async {
        let ids = [101, 404]
        let t = transportFor(ids: ids, playlistName: "P", libraryHas: ids,
                            playlistTracks: [])
        t.catalogSongs[404] = nil
        let manifest = Fixtures.manifest(ids: ids)
        let report = await makeRunner(t).run(manifest: manifest, playlistName: "P")
        let result = AutomationResultBuilder.build(manifest: manifest,
                                                    report: report,
                                                    capturedAtMillisSinceEpoch: capturedAt)

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.error?.kind, "catalogLookupFailed")
        XCTAssertNil(result.playlistVerified)
        // The failing recording's row blames it; nothing was written.
        let failedRow = result.tracks.first { $0.catalogId == 404 }
        XCTAssertNotNil(failedRow)
        XCTAssertEqual(failedRow?.error?.kind, "catalogLookupFailed")
        XCTAssertEqual(failedRow?.catalogVerified, false)
        XCTAssertEqual(failedRow?.appendIssued, false)
        // No playlist evidence: the stop happened before preflight could
        // even classify a state — the row must not claim storage.
        XCTAssertEqual(failedRow?.storedAtPosition, false)
        XCTAssertTrue(result.phases.contains("stopped"))
    }

    func testUnsafePlaylistStopSurfacesPlaylistError() async {
        let ids = [101, 102]
        // Playlist stores a foreign track → containsUnrelatedTracks → stop.
        let t = transportFor(ids: ids, playlistName: "P", libraryHas: ids,
                             playlistTracks: [999])
        let manifest = Fixtures.manifest(ids: ids)
        let report = await makeRunner(t).run(manifest: manifest, playlistName: "P")
        let result = AutomationResultBuilder.build(manifest: manifest,
                                                    report: report,
                                                    capturedAtMillisSinceEpoch: capturedAt)

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.error?.kind, "playlistNotSafeToWrite")
        XCTAssertEqual(result.playlistStateBefore, nil)
        XCTAssertTrue(result.tracks.allSatisfy { $0.appendIssued == false },
                      "unsafe state must never produce a write")
    }

    func testNotAuthorizedStopSurfacesDistinctly() async {
        let ids = [101]
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
        let manifest = Fixtures.manifest(ids: ids)
        let runner = TransactionRunner(engine: RESTEngine(
            transport: ExpiredAuthTransport(),
            config: .init(storefront: "us", propagateDelayMilliseconds: 0,
                          verificationRetries: 1, verificationBackoffMilliseconds: 0)))
        let report = await runner.run(manifest: manifest, playlistName: "P")
        let result = AutomationResultBuilder.build(manifest: manifest,
                                                    report: report,
                                                    capturedAtMillisSinceEpoch: capturedAt)
        // §15: authorization loss must reach the automation caller as
        // itself — Hermes must re-authorize, not treat it as data failure.
        XCTAssertEqual(result.error?.kind, "notAuthorized")
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.tracks.first?.catalogVerified, false)
    }

    // MARK: - Acknowledgment is never proof (§11/§14)

    func testAcknowledgedButUnprovenLibraryAddIsReportedAsUnproven() async {
        let ids = [101]
        let t = transportFor(ids: ids, playlistName: "P", libraryHas: [],
                             playlistTracks: [])
        // Server acknowledges the add (202) but it NEVER becomes visible:
        // the post-add fresh read cannot prove presence → §11 stop.
        t.addsBecomeVisibleInLibrary = false
        let manifest = Fixtures.manifest(ids: ids)
        let report = await makeRunner(t).run(manifest: manifest, playlistName: "P")
        let result = AutomationResultBuilder.build(manifest: manifest,
                                                    report: report,
                                                    capturedAtMillisSinceEpoch: capturedAt)

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.error?.kind, "librarySongMissing")
        let row = result.tracks[0]
        // The 202 acknowledgment is recorded as exactly that — an issued
        // write with its HTTP status — while the PROOF fields stay false.
        XCTAssertEqual(row.libraryAddIssued, true)
        XCTAssertEqual(row.libraryAddHttpStatus, 202)
        XCTAssertEqual(row.inLibraryAfter, false,
                       "a 202 must never surface as proof of presence")
        XCTAssertEqual(row.storedAtPosition, false)
        XCTAssertEqual(row.error?.kind, "librarySongMissing")
    }

    // MARK: - Interrupted execute produces the checkpoint in the file

    func testInterruptedExecuteCarriesCheckpointInResultFile() async {
        let ids = [101, 102, 103]
        let t = transportFor(ids: ids, playlistName: "P", libraryHas: ids,
                             playlistTracks: [])
        // Step 1 (pos 1, id 101) appends and its fresh read proves it;
        // step 2's write is REJECTED by the server (409) → execute stops
        // mid-plan. Recorded outcomes = 2; the LAST is the first unproven.
        t.appendStatuses = ["i.102": 409]
        let manifest = Fixtures.manifest(ids: ids)
        let report = await makeRunner(t).run(manifest: manifest, playlistName: "P")
        let result = AutomationResultBuilder.build(manifest: manifest,
                                                    report: report,
                                                    capturedAtMillisSinceEpoch: capturedAt)

        XCTAssertFalse(result.succeeded)
        // The checkpoint is embedded in the result file so Hermes can
        // hand it to `recover` without parsing the phase stream.
        XCTAssertNotNil(result.checkpoint)
        XCTAssertEqual(result.checkpoint?.playlistId, "p.test")
        XCTAssertEqual(result.checkpoint?.provenStoredPrefixCount, 1,
                       "pos 1 was proven by its own fresh read; the rejected last step is excluded")
        XCTAssertEqual(result.error?.kind, "playlistAppendFailed")
        // Row evidence: both append attempts recorded; only pos 1 was
        // proven stored before the stop (and no final read-back ran).
        XCTAssertEqual(result.tracks[0].appendIssued, true)
        XCTAssertEqual(result.tracks[0].appendHttpStatus, 204)
        XCTAssertEqual(result.tracks[0].storedAtPosition, false,
                       "stopped run has no final read-back; storage is only in the checkpoint's proven claim")
        XCTAssertEqual(result.tracks[1].appendIssued, true)
        XCTAssertEqual(result.tracks[1].appendHttpStatus, 409)
        XCTAssertEqual(result.tracks[1].error?.kind, "playlistAppendFailed")
        XCTAssertEqual(result.tracks[2].appendIssued, false)
    }

    // MARK: - Idempotent no-op

    func testExactCompleteNoOpReportsAllStored() async {
        let ids = [101, 102]
        let t = transportFor(ids: ids, playlistName: "P", libraryHas: ids,
                             playlistTracks: ids)
        let manifest = Fixtures.manifest(ids: ids)
        let report = await makeRunner(t).run(manifest: manifest, playlistName: "P")
        let result = AutomationResultBuilder.build(manifest: manifest,
                                                    report: report,
                                                    capturedAtMillisSinceEpoch: capturedAt)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.playlistStateBefore, "exactComplete")
        XCTAssertTrue(result.tracks.allSatisfy { $0.appendIssued == false && $0.storedAtPosition == true })
        XCTAssertNil(result.checkpoint)
    }

    // MARK: - Phase label stability

    func testPhaseLabelsMatchCLIContract() {
        XCTAssertEqual(AutomationResultBuilder.phaseLabel(.catalogGate), "catalog")
        XCTAssertEqual(AutomationResultBuilder.phaseLabel(.preflight), "preflight")
        XCTAssertEqual(AutomationResultBuilder.phaseLabel(.reconcile), "reconcile")
        XCTAssertEqual(AutomationResultBuilder.phaseLabel(.libraryAdd), "library-add")
        XCTAssertEqual(AutomationResultBuilder.phaseLabel(.libraryVerify), "library-verify")
        XCTAssertEqual(AutomationResultBuilder.phaseLabel(.plan), "plan")
        XCTAssertEqual(AutomationResultBuilder.phaseLabel(.execute), "append")
        XCTAssertEqual(AutomationResultBuilder.phaseLabel(.finalReadback), "final-readback")
        XCTAssertEqual(AutomationResultBuilder.phaseLabel(.stopped), "stopped")
    }
}
