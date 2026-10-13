import XCTest
import MusicKit
import TunoryCore
@testable import Tunory

@MainActor
final class WorkflowSafetyTests: XCTestCase {
    private func store() throws -> CheckpointStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tunory-ui-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return CheckpointStore(directory: directory)
    }

    private func checkpoint() -> TransactionCheckpoint {
        TransactionCheckpoint(playlistId: "test-owned-playlist", playlistName: "Test", manifestCatalogIds: [101], provenStoredPrefixCount: 0, provenLibraryCatalogIds: [101], capturedAtMillisSinceEpoch: 1)
    }

    private func recording(status: ResolutionStatus = .resolved) -> LineResolution {
        LineResolution(pos: 1, status: status, rawTitle: "One",
                       resolvedSong: ResolvedSong(catalogId: 101, title: "One", artistName: "Test Artist", albumTitle: nil, durationMilliseconds: nil),
                       candidates: nil, resolutionPath: nil)
    }

    func testTransactionCannotResetOrStartAgainWhileRunning() async throws {
        let gate = CatalogGate()
        let transport = StoppedReadTransport(gate: gate)
        let model = TransactionViewModel(checkpointStore: try store(), authorizationStatus: { .authorized },
                                         makeEngine: { RESTEngine(transport: transport) })
        model.playlistName = "Test"
        let first = Task { await model.start(resolutions: [recording()]) }
        await gate.waitForRequest()
        model.reset()
        XCTAssertTrue(model.isRunning)
        await model.start(resolutions: [recording()])
        let calls = await gate.callCount
        XCTAssertEqual(calls, 1)
        await gate.release()
        await first.value
        XCTAssertEqual(model.stage, .finished)
        XCTAssertEqual(model.phaseLog, model.report?.phases.sorted { $0.ordinal < $1.ordinal })
        await Task.yield()
        XCTAssertEqual(model.phaseLog, model.report?.phases.sorted { $0.ordinal < $1.ordinal }, "Late callback hops cannot change terminal evidence.")
        await model.start(resolutions: [recording()])
        let afterReplay = await gate.callCount
        XCTAssertEqual(afterReplay, 1, "A completed attempt requires an explicit reset before another run.")
        let writes = await transport.writeCount
        XCTAssertEqual(writes, 0)
    }

    func testTentativeIdentityCannotStartTransaction() async throws {
        var engines = 0
        let model = TransactionViewModel(checkpointStore: try store(), authorizationStatus: { .authorized }, makeEngine: {
            engines += 1
            return RESTEngine(transport: StoppedReadTransport())
        })
        model.playlistName = "Test"
        await model.start(resolutions: [recording(status: .needsReview)])
        XCTAssertEqual(engines, 0)
        XCTAssertEqual(model.failurePosition, 1)
        XCTAssertEqual(model.stage, .finished)
        XCTAssertNil(model.report)
    }

    func testDeniedTransactionDoesNotCreateEngine() async throws {
        var engines = 0
        let model = TransactionViewModel(checkpointStore: try store(), authorizationStatus: { .denied }, makeEngine: {
            engines += 1
            return RESTEngine(transport: StoppedReadTransport())
        })
        model.playlistName = "Test"
        await model.start(resolutions: [recording()])
        XCTAssertEqual(engines, 0)
        XCTAssertNotNil(model.failureMessage)
        XCTAssertNil(model.report)
    }

    func testRecoveryKeepsCheckpointAndStageWhileRunning() async throws {
        let store = try store()
        let saved = checkpoint()
        try store.save(saved)
        let gate = CatalogGate()
        let transport = StoppedReadTransport(gate: gate)
        let model = RecoveryViewModel(store: store, authorizationStatus: { .authorized }, makeEngine: { RESTEngine(transport: transport) })
        model.loadPersisted()
        let first = Task { await model.resume() }
        await gate.waitForRequest()
        model.loadPersisted()
        model.dismiss()
        model.reset()
        XCTAssertTrue(model.isRunning)
        XCTAssertEqual(store.load(), .checkpoint(saved))
        await model.resume()
        let calls = await gate.callCount
        XCTAssertEqual(calls, 1)
        await gate.release()
        await first.value
        XCTAssertEqual(model.stage, .finished)
        XCTAssertNotNil(model.recoveryFailure)
        XCTAssertFalse(model.alreadyComplete)
        XCTAssertEqual(store.load(), .checkpoint(saved))
        let writes = await transport.writeCount
        XCTAssertEqual(writes, 0)
        model.loadPersisted()
        XCTAssertEqual(model.stage, .available(checkpoint: saved))
        XCTAssertNil(model.recoveryFailure)
    }

    func testDeniedRecoveryRetainsSavedProgress() async throws {
        let store = try store()
        let saved = checkpoint()
        try store.save(saved)
        var engines = 0
        let model = RecoveryViewModel(store: store, authorizationStatus: { .denied }, makeEngine: {
            engines += 1
            return RESTEngine(transport: StoppedReadTransport())
        })
        model.loadPersisted()
        await model.resume()
        XCTAssertEqual(engines, 0)
        XCTAssertEqual(store.load(), .checkpoint(saved))
        XCTAssertNotNil(model.recoveryFailure)
        XCTAssertFalse(model.alreadyComplete)
    }

    func testDismissFailureRetainsCheckpointAndExplainsIt() throws {
        let store = try store()
        let saved = checkpoint()
        try store.save(saved)
        let model = RecoveryViewModel(store: store)
        model.loadPersisted()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: store.directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.directory.path) }
        model.dismiss()
        XCTAssertEqual(model.stage, .available(checkpoint: saved))
        XCTAssertEqual(store.load(), .checkpoint(saved))
        XCTAssertNotNil(model.persistenceWarning)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.directory.path)
        model.dismiss()
        XCTAssertEqual(model.stage, .idle)
        XCTAssertEqual(store.load(), .none)
        XCTAssertNil(model.persistenceWarning)
    }

    // MARK: - Stopped execute seeds recovery (run-71 follow-up)

    /// A transaction that STOPs mid-execute (partial append outcomes) must
    /// save a credential-free checkpoint, AND the Recovery surface must
    /// show it after loadPersisted() — the run-71 "STOP did not seed
    /// Recovery" report. When the save itself fails, the warning banner
    /// is the only signal: it must be visible.
    func testStoppedExecuteSeedsCheckpointAndRecoverySurfacesIt() async throws {
        // Scripted server: catalog exists, playlist found and editable and
        // empty, library add verified by fresh read, first append accepted
        // (204) but never stored — the canonical engine stops with
        // playlistVerificationFailed after 1 recorded append outcome.
        actor LaggingWriteTransport: AMTransport {
            func getCatalogSong(catalogId: Int, storefront: String) async throws
                -> (song: AMCatalogSong?, httpStatus: Int) {
                (AMCatalogSong(id: String(catalogId),
                               attributes: .init(name: "One", artistName: "Test Artist",
                                                 albumName: nil, durationInMillis: nil)), 200)
            }
            func getLibrarySongsPage(cursor: String?) async throws
                -> (items: [AMLibrarySong], next: String?) {
                ([AMLibrarySong(id: "l.101",
                               attributes: .init(name: nil, artistName: nil,
                                                 playParams: .init(catalogId: 101)),
                               relationships: nil)], nil)
            }
            func getLibraryPlaylistsPage(cursor: String?) async throws
                -> (items: [AMLibraryPlaylist], next: String?) {
                ([AMLibraryPlaylist(id: "p.test",
                                   attributes: .init(name: "Test", canEdit: true, shareUrl: nil))], nil)
            }
            func getPlaylistTracks(playlistId: String) async throws -> [AMLibrarySong] { [] }
            func addCatalogSongToLibrary(catalogId: Int) async throws -> Int { 202 }
            func appendLibrarySong(toPlaylist playlistId: String, librarySongId: String) async throws -> Int { 204 }
            func createPlaylist(named name: String) async throws
                -> (playlist: AMLibraryPlaylist?, httpStatus: Int) { (nil, 500) }
        }
        let transport = LaggingWriteTransport()
        let store = try self.store()
        // Pin the engine's patience budgets so the scripted failure is
        // observed immediately (the production default is 45 × 2s, which
        // is exactly what the core property test covers instead).
        let fastConfig = RESTEngine.Config(propagateDelayMilliseconds: 0,
                                           verificationRetries: 1, verificationBackoffMilliseconds: 0,
                                           appendVerificationRetries: 1, appendVerificationBackoffMilliseconds: 0,
                                           createRediscoveryRetries: 1, createRediscoveryBackoffMilliseconds: 0)
        let model = TransactionViewModel(checkpointStore: store,
                                         authorizationStatus: { .authorized },
                                         makeEngine: { RESTEngine(transport: transport, config: fastConfig) })
        model.playlistName = "Test"
        await model.start(resolutions: [recording()])
        XCTAssertEqual(model.stage, .finished)
        XCTAssertFalse(model.report?.succeeded ?? true, "the scripted lag must stop the run")

        // The stopped execute saved a checkpoint...
        guard case .checkpoint(let saved) = store.load() else {
            return XCTFail("stopped execute must seed a checkpoint, got \(store.load())")
        }
        XCTAssertEqual(saved.playlistName, "Test")
        // ...and Recovery surfaces it after an explicit loadPersisted().
        let recovery = RecoveryViewModel(store: store)
        recovery.loadPersisted()
        XCTAssertEqual(recovery.stage, .available(checkpoint: saved))

        // Adversarial: when the save itself fails (read-only directory),
        // persistenceWarning must carry the signal.
        let blockedStore = try self.store()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: blockedStore.directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blockedStore.directory.path) }
        let blockedModel = TransactionViewModel(checkpointStore: blockedStore,
                                                authorizationStatus: { .authorized },
                                                makeEngine: { RESTEngine(transport: transport, config: fastConfig) })
        blockedModel.playlistName = "Test"
        await blockedModel.start(resolutions: [recording()])
        XCTAssertEqual(blockedModel.stage, .finished)
        XCTAssertNotNil(blockedModel.persistenceWarning,
                        "a failed checkpoint save must surface the warning banner")
    }
}

/// Every network operation is a fake. Read failure stops the canonical workflow;
/// write counters prove that these UI safety tests never reach a mutation.
actor StoppedReadTransport: AMTransport {
    let gate: CatalogGate?
    private(set) var writeCount = 0
    init(gate: CatalogGate? = nil) { self.gate = gate }
    func getCatalogSong(catalogId: Int, storefront: String) async throws -> (song: AMCatalogSong?, httpStatus: Int) {
        if let gate { _ = await gate.check() }
        return (nil, 404)
    }
    func getLibrarySongsPage(cursor: String?) async throws -> (items: [AMLibrarySong], next: String?) { ([], nil) }
    func getLibraryPlaylistsPage(cursor: String?) async throws -> (items: [AMLibraryPlaylist], next: String?) {
        if let gate { _ = await gate.check() }
        return ([], nil)
    }
    func getPlaylistTracks(playlistId: String) async throws -> [AMLibrarySong] { [] }
    func addCatalogSongToLibrary(catalogId: Int) async throws -> Int { writeCount += 1; return 500 }
    func appendLibrarySong(toPlaylist playlistId: String, librarySongId: String) async throws -> Int { writeCount += 1; return 500 }
    func createPlaylist(named name: String) async throws -> (playlist: AMLibraryPlaylist?, httpStatus: Int) { writeCount += 1; return (nil, 500) }
}
