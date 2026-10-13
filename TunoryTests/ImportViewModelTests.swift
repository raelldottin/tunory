import XCTest
import MusicKit
import TunoryCore
@testable import Tunory

@MainActor
final class ImportViewModelTests: XCTestCase {
    private let firstInput = "https://music.apple.com/us/song/one/101"
    private let secondInput = "https://music.apple.com/us/song/two/202"

    private func makeModel(gate: ResolutionGate? = nil) -> ImportViewModel {
        let auth = MusicAuthViewModel(currentStatus: { .authorized }, checkCatalog: { 1 })
        return ImportViewModel(authModel: auth) { _ in
            var sources = ResolutionEngine.Sources()
            sources.resolveIds = { ids in
                if let gate { return await gate.resolve(ids) }
                return ResolutionGate.songs(ids)
            }
            return ResolutionEngine(sources: sources)
        }
    }

    func testRepeatedResolveDoesNotStartAnotherRequest() async {
        let gate = ResolutionGate()
        let model = makeModel(gate: gate)
        model.importPastedList(firstInput)
        let first = Task { await model.resolve() }
        await gate.waitForFirstRequest()
        await model.resolve()
        let calls = await gate.callCount
        XCTAssertEqual(calls, 1, "The model must reject duplicate resolution entry, even without a disabled button.")
        XCTAssertTrue(model.isBusy)
        await gate.release()
        await first.value
    }

    func testResetRejectsLateResolution() async {
        let gate = ResolutionGate()
        let model = makeModel(gate: gate)
        model.importPastedList(firstInput)
        let request = Task { await model.resolve() }
        await gate.waitForFirstRequest()
        model.reset()
        await gate.release()
        await request.value
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.resolutions.isEmpty)
        XCTAssertFalse(model.hasInput)
    }

    func testChangedInputRejectsOldResolution() async {
        let gate = ResolutionGate()
        let model = makeModel(gate: gate)
        model.importPastedList(firstInput)
        let request = Task { await model.resolve() }
        await gate.waitForFirstRequest()
        model.importPastedList(secondInput)
        await gate.release()
        await request.value
        XCTAssertEqual(model.phase, .parsed(lines: 1))
        XCTAssertTrue(model.resolutions.isEmpty)
    }

    func testCanceledResolutionCannotBecomeReviewEvidence() async {
        let gate = ResolutionGate()
        let model = makeModel(gate: gate)
        model.importPastedList(firstInput)
        let request = Task { await model.resolve() }
        await gate.waitForFirstRequest()
        request.cancel()
        await gate.release()
        await request.value
        XCTAssertTrue(model.resolutions.isEmpty)
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.phase, .parsed(lines: 1))
    }

    func testNewInputClearsPreviousReview() async {
        let model = makeModel()
        model.importPastedList(firstInput)
        await model.resolve()
        XCTAssertFalse(model.resolutions.isEmpty)
        model.importPastedList(secondInput)
        XCTAssertTrue(model.resolutions.isEmpty)
        XCTAssertEqual(model.phase, .parsed(lines: 1))
    }

    func testInvalidNewInputCannotReuseOldLines() async {
        let model = makeModel()
        model.importPastedList(firstInput)
        model.importPastedList(" \n ")
        await model.resolve()
        XCTAssertFalse(model.hasInput)
        XCTAssertTrue(model.resolutions.isEmpty)
        guard case .failed = model.phase else { return XCTFail("Invalid new input must remain a parse failure.") }
    }

    func testAuthorizationFailureMakesNoCatalogRequest() async {
        let auth = MusicAuthViewModel(currentStatus: { .denied }, checkCatalog: { 1 })
        let model = ImportViewModel(authModel: auth) { _ in
            XCTFail("Denied access must fail before an engine is constructed.")
            return ResolutionEngine(sources: .init())
        }
        model.importPastedList(firstInput)
        await model.resolve()
        XCTAssertFalse(model.authGranted)
        guard case .failed = model.phase else { return XCTFail("Expected actionable authorization failure.") }
    }

    func testCatalogFailureIsNotPresentedAsProofOfNoMatch() async {
        let auth = MusicAuthViewModel(currentStatus: { .authorized }, checkCatalog: { 1 })
        let model = ImportViewModel(authModel: auth) { onFailure in
            var sources = ResolutionEngine.Sources()
            sources.resolveIds = { _ in await onFailure("Test-owned offline response"); return [:] }
            return ResolutionEngine(sources: sources)
        }
        model.importPastedList(firstInput)
        await model.resolve()
        XCTAssertNotNil(model.sourceWarning)
        XCTAssertFalse(model.canContinueReview)
        XCTAssertEqual(model.resolutions.first?.status, .unresolved)
    }

    func testSuccessfulRetryClearsPriorCatalogRequestFailure() async {
        let auth = MusicAuthViewModel(currentStatus: { .authorized }, checkCatalog: { 1 })
        var attempt = 0
        let model = ImportViewModel(authModel: auth) { onFailure in
            attempt += 1
            let currentAttempt = attempt
            var sources = ResolutionEngine.Sources()
            sources.resolveIds = { ids in
                if currentAttempt == 1 { await onFailure("Test-owned offline response"); return [:] }
                return ResolutionGate.songs(ids)
            }
            return ResolutionEngine(sources: sources)
        }
        model.importPastedList(firstInput)
        await model.resolve()
        XCTAssertNotNil(model.sourceWarning)
        await model.resolve()
        XCTAssertNil(model.sourceWarning)
        XCTAssertEqual(model.resolutions.count, 1)
        guard case .review = model.phase else { return XCTFail("Retry must return to review after a completed catalog request.") }
    }
}

/// The first response is explicitly suspended; later calls return immediately so
/// duplicate-entry regressions fail without hanging or relying on sleep timing.
actor ResolutionGate {
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<[Int: ResolvedSong], Never>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstIds: [Int] = []

    nonisolated static func songs(_ ids: [Int]) -> [Int: ResolvedSong] {
        Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, ResolvedSong(catalogId: id, title: id == 101 ? "one" : "two", artistName: "Test Artist", albumTitle: nil, durationMilliseconds: nil))
        })
    }

    func resolve(_ ids: [Int]) async -> [Int: ResolvedSong] {
        callCount += 1
        guard callCount == 1 else { return Self.songs(ids) }
        firstIds = ids
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            startedWaiters.forEach { $0.resume() }
            startedWaiters.removeAll()
        }
    }

    func waitForFirstRequest() async {
        if continuation != nil { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release() {
        continuation?.resume(returning: Self.songs(firstIds))
        continuation = nil
    }
}
