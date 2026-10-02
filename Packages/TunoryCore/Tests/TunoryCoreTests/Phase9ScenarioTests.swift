import XCTest
@testable import TunoryCore

// MARK: - Phase 9: beta productization
//
// Phase 9 adds GUI recovery and persistence WITHOUT touching the proven
// transaction semantics (Phases 1-8). These tests prove the new canonical
// surface:
//
//   • CheckpointStore — the persistence slot: save/load/clear, the
//     unreadable-vs-none distinction, and STRICT superseding identity
//     (a success only clears the checkpoint of the SAME transaction).
//   • RecoveryFlow — the canonical recovery sequencing now shared by the
//     CLI and the GUI. Each rule re-proves the Phase 6 semantics at the
//     new orchestration surface:
//       - corrupted checkpoint manifests fail closed before any traffic;
//       - alreadyComplete writes nothing;
//       - resume re-derives from actual state and completes;
//       - divergence stops with no writes;
//       - the resumed transaction is exactly the canonical §20 run
//         (same call sequence the CLI recover verb produces).
//   • EvidencePresentation — §10 divergence notes derived from the
//     canonical gate report, not re-computed by presentation code.

final class Phase9ScenarioTests: XCTestCase {

    // MARK: - Helpers

    private func transportFor(ids: [Int], playlistName: String,
                              libraryHas: [Int]) -> StubTransport {
        Fixtures.happyPathTransport(manifest: Fixtures.manifest(ids: ids),
                                    playlistName: playlistName,
                                    libraryHas: libraryHas)
    }

    private func makeRunner(_ transport: StubTransport) -> TransactionRunner {
        TransactionRunner(engine: RESTEngine(transport: transport, config: .init(
            storefront: "us", propagateDelayMilliseconds: 0,
            verificationRetries: 3, verificationBackoffMilliseconds: 0)))
    }

    private func makeEngine(_ transport: StubTransport) -> RESTEngine {
        RESTEngine(transport: transport, config: .init(
            storefront: "us", propagateDelayMilliseconds: 0,
            verificationRetries: 3, verificationBackoffMilliseconds: 0))
    }

    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase9-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func checkpoint(playlistId: String = "p.test",
                            playlistName: String = "P",
                            manifestIds: [Int],
                            provenPrefix: Int,
                            libraryIds: [Int],
                            capturedAt: Int64 = 1) -> TransactionCheckpoint {
        TransactionCheckpoint(playlistId: playlistId,
                               playlistName: playlistName,
                               manifestCatalogIds: manifestIds,
                               provenStoredPrefixCount: provenPrefix,
                               provenLibraryCatalogIds: libraryIds,
                               capturedAtMillisSinceEpoch: capturedAt)
    }

    // MARK: - CheckpointStore: persistence lifecycle

    func testCheckpointStoreSaveLoadRoundTrip() throws {
        let store = CheckpointStore(directory: tempDirectory())
        XCTAssertEqual(store.load(), .none, "an empty slot must load as none")

        let saved = checkpoint(manifestIds: [101, 102, 103], provenPrefix: 2,
                               libraryIds: [101, 102, 103], capturedAt: 42)
        try store.save(saved)
        guard case .checkpoint(let loaded) = store.load() else {
            return XCTFail("expected a decoded checkpoint, got \(store.load())")
        }
        XCTAssertEqual(loaded, saved)
    }

    func testCheckpointStoreDistinguishesCorruptFileFromEmpty() throws {
        let store = CheckpointStore(directory: tempDirectory())
        try FileManager.default.createDirectory(at: store.directory,
                                                withIntermediateDirectories: true)
        try Data("this is not json".utf8).write(to: store.fileURL)

        guard case .unreadable = store.load() else {
            return XCTFail("a present-but-corrupt file must surface as unreadable, got \(store.load())")
        }
    }

    func testCheckpointStoreClearRemovesSlot() throws {
        let store = CheckpointStore(directory: tempDirectory())
        try store.save(checkpoint(manifestIds: [101], provenPrefix: 0,
                                  libraryIds: [101]))
        store.clear()
        XCTAssertEqual(store.load(), .none)
        // Clearing an empty slot is not an error.
        store.clear()
        XCTAssertEqual(store.load(), .none)
    }

    /// Adversarial: a verified success for a DIFFERENT transaction must
    /// never clear a stored checkpoint — the success says nothing about
    /// that interrupted run.
    func testCheckpointStoreSupersedeIsStrictAboutIdentity() throws {
        let store = CheckpointStore(directory: tempDirectory())
        let stored = checkpoint(playlistId: "p.A", playlistName: "A",
                                 manifestIds: [101, 102], provenPrefix: 1,
                                 libraryIds: [101, 102])
        try store.save(stored)

        // Different playlist: keep.
        XCTAssertFalse(store.clearIfSuperseded(bySuccessWith: "p.B",
                                               manifestCatalogIds: [101, 102]))
        guard case .checkpoint(let kept1) = store.load() else {
            return XCTFail("checkpoint must survive a foreign-playlist success")
        }
        XCTAssertEqual(kept1, stored)

        // Same playlist, different manifest sequence: keep.
        XCTAssertFalse(store.clearIfSuperseded(bySuccessWith: "p.A",
                                               manifestCatalogIds: [101, 103]))
        guard case .checkpoint(let kept2) = store.load() else {
            return XCTFail("checkpoint must survive a different-manifest success")
        }
        XCTAssertEqual(kept2, stored)

        // Exact identity: clear.
        XCTAssertTrue(store.clearIfSuperseded(bySuccessWith: "p.A",
                                             manifestCatalogIds: [101, 102]))
        XCTAssertEqual(store.load(), .none)
    }

    /// The persistence slot is credential-free by construction: the
    /// encoded JSON must not contain any token-shaped secrets (the
    /// checkpoint type carries only playlist identity + catalog IDs +
    /// proven counts — this test fails if anyone adds a field that leaks).
    func testPersistedCheckpointContainsNoCredentialShapedFields() throws {
        let store = CheckpointStore(directory: tempDirectory())
        try store.save(checkpoint(manifestIds: [101, 102], provenPrefix: 1,
                                  libraryIds: [101, 102]))
        let raw = try String(contentsOf: store.fileURL, encoding: .utf8)
        let lowered = raw.lowercased()
        for forbidden in ["token", "secret", "password", "authorization",
                          "developer", "music-user", "key"] {
            XCTAssertFalse(lowered.contains(forbidden),
                           "checkpoint JSON must never contain '\(forbidden)': \(raw)")
        }
    }

    // MARK: - RecoveryFlow: canonical sequencing

    /// A checkpoint whose catalog-ID list fails canonical validation
    /// (duplicates) fails closed at manifest() — BEFORE any network
    /// traffic is issued. Adversarial: a corrupt file must never reach
    /// the engine.
    func testRecoveryFlowRejectsCorruptCheckpointBeforeAnyTraffic() async throws {
        let corrupt = checkpoint(manifestIds: [101, 101], provenPrefix: 1,
                                 libraryIds: [101])
        XCTAssertThrowsError(try RecoveryFlow.manifest(for: corrupt)) { error in
            guard case ManifestError.duplicateCatalogId = error else {
                return XCTFail("expected duplicateCatalogId, got \(error)")
            }
        }

        // And the GUI convenience path surfaces it as a canonical stop,
        // with zero transport calls.
        let t = transportFor(ids: [101, 101], playlistName: "P", libraryHas: [101])
        let outcome = await RecoveryFlow.run(checkpoint: corrupt,
                                             engine: makeEngine(t))
        guard case .stopped(let error) = outcome.kind else {
            return XCTFail("expected a stopped outcome, got \(outcome.kind)")
        }
        guard case .checkpointDiverged = error else {
            return XCTFail("expected checkpointDiverged, got \(error)")
        }
        XCTAssertTrue(t.calls.isEmpty,
                      "a corrupt checkpoint must not issue any traffic; calls: \(t.calls)")
    }

    /// alreadyComplete: fresh reads prove the playlist already matches the
    /// full manifest — recovery writes nothing and reports completion.
    func testRecoveryFlowAlreadyCompleteWritesNothing() async {
        let ids = [101, 102, 103]
        let cp = checkpoint(manifestIds: ids, provenPrefix: 2,
                            libraryIds: ids)
        let t = transportFor(ids: ids, playlistName: "P", libraryHas: ids)
        t.playlistTracks["p.test"] = ids.map { Fixtures.librarySong(libraryId: "i.\($0)", catalogId: $0) }

        let outcome = await RecoveryFlow.run(checkpoint: cp, engine: makeEngine(t))

        guard case .alreadyComplete(let info) = outcome.kind else {
            return XCTFail("expected alreadyComplete, got \(outcome.kind)")
        }
        XCTAssertEqual(info.id, "p.test")
        // Reads only: discovery + playlist track read. No append, no add.
        XCTAssertTrue(t.calls.allSatisfy { $0.name != "append" && $0.name != "libraryAdd" },
                      "alreadyComplete must not write; calls: \(t.calls)")
        XCTAssertEqual(t.storedTracks(playlistId: "p.test").count, ids.count)
    }

    /// The canonical GUI resume: the checkpoint's proven prefix holds
    /// against fresh state, recovery resumes, and the resumed §20
    /// transaction appends ONLY the un-stored suffix — proving the exact
    /// manifest sequence end to end.
    func testRecoveryFlowResumeAppendsOnlyUnstoredSuffix() async {
        let ids = [101, 102, 103, 104]
        let cp = checkpoint(manifestIds: ids, provenPrefix: 1,
                            libraryIds: ids)
        let t = transportFor(ids: ids, playlistName: "P", libraryHas: ids)
        // Reality: exactly the proven prefix is stored.
        t.playlistTracks["p.test"] = [Fixtures.librarySong(libraryId: "i.101", catalogId: 101)]

        var observedPhases: [TransactionPhaseOutcome] = []
        let outcome = await RecoveryFlow.run(checkpoint: cp, engine: makeEngine(t)) { phase in
            observedPhases.append(phase)
        }

        guard case .resumed(let report) = outcome.kind else {
            return XCTFail("expected resumed, got \(outcome.kind)")
        }
        XCTAssertTrue(report.succeeded)
        XCTAssertEqual(report.finalReadback?.verified, true)
        XCTAssertEqual(observedPhases.map(\.kind),
                       report.phases.map(\.kind),
                       "onPhase must mirror the runner's phases in order")
        XCTAssertEqual(t.storedTracks(playlistId: "p.test").map(\.catalogId), ids)
        XCTAssertEqual(t.calls.filter { $0.name == "append" }.map(\.detail),
                       ["p.test:i.102", "p.test:i.103", "p.test:i.104"],
                       "resume appends only the un-stored suffix, in order")
    }

    /// Adversarial: reality lost a track the checkpoint proved stored →
    /// recovery stops, and NO write is issued.
    func testRecoveryFlowStopsWhenRealityContradictsCheckpoint() async {
        let ids = [101, 102, 103]
        let cp = checkpoint(manifestIds: ids, provenPrefix: 2,
                            libraryIds: ids)
        let t = transportFor(ids: ids, playlistName: "P", libraryHas: ids)
        // Reality: fewer tracks than proven.
        t.playlistTracks["p.test"] = [Fixtures.librarySong(libraryId: "i.101", catalogId: 101)]

        let outcome = await RecoveryFlow.run(checkpoint: cp, engine: makeEngine(t))

        guard case .stopped(let error) = outcome.kind else {
            return XCTFail("expected stopped, got \(outcome.kind)")
        }
        guard case .checkpointDiverged = error else {
            return XCTFail("expected checkpointDiverged, got \(error)")
        }
        XCTAssertTrue(t.calls.allSatisfy { $0.name != "append" && $0.name != "libraryAdd" },
                      "a diverged recovery must write nothing; calls: \(t.calls)")
    }

    /// Adversarial: the playlist was deleted/recreated (same name, new id)
    /// → stop; unknown history must never be written.
    func testRecoveryFlowRejectsReplacedPlaylist() async {
        let ids = [101, 102]
        let cp = checkpoint(playlistId: "p.original", playlistName: "P",
                            manifestIds: ids, provenPrefix: 1, libraryIds: ids)
        let t = transportFor(ids: ids, playlistName: "P", libraryHas: ids)
        // Reality: a different playlist id under the same name.
        t.playlistPages = [[Fixtures.playlist(id: "p.replacement", name: "P")]]
        t.playlistTracks["p.replacement"] = [Fixtures.librarySong(libraryId: "i.101", catalogId: 101)]

        let outcome = await RecoveryFlow.run(checkpoint: cp, engine: makeEngine(t))

        guard case .stopped(let error) = outcome.kind else {
            return XCTFail("expected stopped, got \(outcome.kind)")
        }
        guard case .checkpointDiverged = error else {
            return XCTFail("expected checkpointDiverged, got \(error)")
        }
        XCTAssertTrue(t.calls.allSatisfy { $0.name != "append" && $0.name != "libraryAdd" })
    }

    /// The resumed transaction IS the canonical §20 sequence — identical
    /// phase kinds and the identical final verdict to a first run over
    /// the same fresh state.
    func testRecoveryFlowResumeIsCanonicalTransaction() async {
        let ids = [101, 102, 103]
        let cp = checkpoint(manifestIds: ids, provenPrefix: 1, libraryIds: ids)

        // Recovery over state with the proven prefix.
        let t = transportFor(ids: ids, playlistName: "P", libraryHas: ids)
        t.playlistTracks["p.test"] = [Fixtures.librarySong(libraryId: "i.101", catalogId: 101)]
        let recovered = await RecoveryFlow.run(checkpoint: cp, engine: makeEngine(t))

        // A first canonical run over the SAME fresh state.
        let t2 = transportFor(ids: ids, playlistName: "P", libraryHas: ids)
        t2.playlistTracks["p.test"] = [Fixtures.librarySong(libraryId: "i.101", catalogId: 101)]
        let firstRun = await makeRunner(t2).run(manifest: Fixtures.manifest(ids: ids),
                                                playlistName: "P")

        guard case .resumed(let resumedReport) = recovered.kind else {
            return XCTFail("expected resumed, got \(recovered.kind)")
        }
        XCTAssertEqual(resumedReport.phases.map(\.kind), firstRun.phases.map(\.kind),
                       "resume must be the canonical §20 sequence")
        XCTAssertEqual(resumedReport.succeeded, firstRun.succeeded)
        XCTAssertEqual(t.calls.filter { $0.name == "append" }.map(\.detail),
                       t2.calls.filter { $0.name == "append" }.map(\.detail),
                       "resume must issue the identical append sequence as a first run")
    }

    // MARK: - EvidencePresentation: §10 divergence notes

    func testDivergenceNotesDeriveFromCanonicalGateReport() {
        let report = CatalogValidationReport(entries: [
            // Diverged and ok: must surface as a note.
            .init(pos: 1, catalogId: 101, expectedName: "Foo Bar",
                  ok: true, nameDiverged: true,
                  actualTitle: "Totally Different", actualArtist: "Someone",
                  httpStatus: 200, reason: nil),
            // Matching: no note.
            .init(pos: 2, catalogId: 102, expectedName: "Mercy",
                  ok: true, nameDiverged: false,
                  actualTitle: "Mercy", actualArtist: "Hilary Hahn",
                  httpStatus: 200, reason: nil),
            // Diverged but FAILED the gate (not ok): no note — it is a
            // stop condition, not review information.
            .init(pos: 3, catalogId: 999, expectedName: "Gone",
                  ok: false, nameDiverged: true,
                  actualTitle: nil, actualArtist: nil,
                  httpStatus: 404, reason: "no data payload"),
        ])
        let notes = EvidencePresentation.catalogDivergenceNotes(from: report)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].pos, 1)
        XCTAssertEqual(notes[0].catalogId, 101)
        XCTAssertEqual(notes[0].requestedName, "Foo Bar")
        XCTAssertEqual(notes[0].actualTitle, "Totally Different")

        let text = EvidencePresentation.divergenceText(for: notes[0])
        XCTAssertTrue(text.contains("Totally Different"),
                      "divergence text must state the actual catalog title")
    }

    func testDivergenceNotesEmptyWhenNoDivergence() {
        let report = CatalogValidationReport(entries: [
            .init(pos: 1, catalogId: 101, expectedName: "Mercy",
                  ok: true, nameDiverged: false,
                  actualTitle: "Mercy", actualArtist: "Hilary Hahn",
                  httpStatus: 200, reason: nil),
        ])
        XCTAssertTrue(EvidencePresentation.catalogDivergenceNotes(from: report).isEmpty)
    }
}
