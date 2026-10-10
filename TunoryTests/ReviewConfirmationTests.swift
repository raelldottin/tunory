import XCTest
import MusicKit
import TunoryCore
@testable import Tunory

@MainActor
final class ReviewConfirmationTests: XCTestCase {
    private func model(gate: ResolutionGate) -> ImportViewModel {
        let auth = MusicAuthViewModel(currentStatus: { .authorized }, checkCatalog: { 1 })
        return ImportViewModel(authModel: auth) { _ in
            var sources = ResolutionEngine.Sources()
            sources.search = { _, _ in [
                SongCandidate(catalogId: 101, title: "One", artistName: "First Artist"),
                SongCandidate(catalogId: 202, title: "One", artistName: "Second Artist")
            ] }
            sources.resolveIds = { await gate.resolve($0) }
            return ResolutionEngine(sources: sources)
        }
    }

    func testResetDuringConfirmationCannotApplyAnOldArrayIndex() async {
        let gate = ResolutionGate()
        let model = model(gate: gate)
        model.importPastedList("One")
        await model.resolve()
        XCTAssertEqual(model.resolutions.first?.status, .needsReview)
        let request = Task { await model.confirm(pos: 1, candidateId: 101) }
        await gate.waitForFirstRequest()
        model.reset()
        await gate.release()
        await request.value
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.resolutions.isEmpty)
        XCTAssertTrue(model.confirmingPositions.isEmpty)
    }

    func testRepeatedConfirmationIsOneCatalogReverification() async {
        let gate = ResolutionGate()
        let model = model(gate: gate)
        model.importPastedList("One")
        await model.resolve()
        let request = Task { await model.confirm(pos: 1, candidateId: 101) }
        await gate.waitForFirstRequest()
        await model.confirm(pos: 1, candidateId: 202)
        let calls = await gate.callCount
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(model.isBusy)
        await gate.release()
        await request.value
        XCTAssertEqual(model.resolutions.first?.resolvedSong?.catalogId, 101)
        XCTAssertEqual(model.resolutions.first?.status, .resolved)
        XCTAssertFalse(model.isBusy)
    }

    func testUnlistedCandidateCannotBeConfirmed() async {
        let gate = ResolutionGate()
        let model = model(gate: gate)
        model.importPastedList("One")
        await model.resolve()
        await model.confirm(pos: 1, candidateId: 999)
        let calls = await gate.callCount
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(model.resolutions.first?.status, .needsReview)
    }

    func testCanceledConfirmationRetainsUnconfirmedChoice() async {
        let gate = ResolutionGate()
        let model = model(gate: gate)
        model.importPastedList("One")
        await model.resolve()
        let request = Task { await model.confirm(pos: 1, candidateId: 101) }
        await gate.waitForFirstRequest()
        request.cancel()
        await gate.release()
        await request.value
        XCTAssertEqual(model.resolutions.first?.status, .needsReview)
        XCTAssertFalse(model.isBusy)
    }
}
