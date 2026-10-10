import XCTest
import TunoryCore
@testable import Tunory

@MainActor
final class ResultEvidenceTests: XCTestCase {
    private func recording(_ id: Int = 101, pos: Int = 1) -> LineResolution {
        LineResolution(pos: pos, status: .resolved, rawTitle: "Recording \(pos)",
                       resolvedSong: ResolvedSong(catalogId: id, title: "Recording \(pos)", artistName: "Test Artist", albumTitle: nil, durationMilliseconds: nil),
                       candidates: nil, resolutionPath: nil)
    }

    func testFailedMutationAcknowledgmentsAreNotPresentedAsAdded() {
        let phases = [
            TransactionPhaseOutcome(kind: .libraryAdd, report: "Test-owned failure", ordinal: 1,
                                    libraryAddOutcomes: [LibraryAddOutcome(pos: 1, catalogId: 101, httpStatus: 500)]),
            TransactionPhaseOutcome(kind: .execute, report: "Test-owned failure", ordinal: 2,
                                    appendOutcomes: [AppendOutcome(pos: 1, catalogId: 101, librarySongId: "test-owned-song", httpStatus: 500)])
        ]
        let report = TransactionReport(playlistName: "Test", phases: phases, plan: nil, libraryVerification: nil, finalReadback: nil, succeeded: false)
        let rows = TransactionViewModel.deriveRows(resolutions: [recording()], report: report)
        XCTAssertFalse(rows[0].libraryAdded)
        XCTAssertFalse(rows[0].appended)
        XCTAssertNil(rows[0].verified)
        XCTAssertNotNil(rows[0].problem)
    }

    func testShortFinalReadbackReportsMissingPositionsWithoutCrashing() {
        let readback = PlaylistVerification(playlistId: "test-owned-playlist", expectedCatalogIds: [101, 202], actualCatalogIds: [101],
                                            verified: false, orderingPass: false, duplicates: [], unexpectedCatalogIds: [], unidentifiableTrackCount: 0, shareUrl: nil)
        let report = TransactionReport(playlistName: "Test", phases: [], plan: nil, libraryVerification: nil, finalReadback: readback, succeeded: false)
        let rows = TransactionViewModel.deriveRows(resolutions: [recording(), recording(202, pos: 2)], report: report)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].verified, false, "A matching position cannot claim complete verification when the final readback failed.")
        XCTAssertEqual(rows[1].verified, false)
        XCTAssertNotNil(rows[1].problem)
        XCTAssertTrue(rows[1].problem?.contains("2") == true)
    }

    func testRecoveryDoesNotPresentFailedAcknowledgmentsAsAccepted() throws {
        let manifest = try ManifestParser.build(lineCount: 1,
            catalogIdForLine: { _ in 101 }, nameForLine: { _ in "Recording" },
            artistForLine: { _ in "Test Artist" })
        let phases = [
            TransactionPhaseOutcome(kind: .libraryAdd, report: "Failure", ordinal: 1,
                libraryAddOutcomes: [LibraryAddOutcome(pos: 1, catalogId: 101, httpStatus: 500)]),
            TransactionPhaseOutcome(kind: .execute, report: "Failure", ordinal: 2,
                appendOutcomes: [AppendOutcome(pos: 1, catalogId: 101,
                    librarySongId: "test-owned-song", httpStatus: 500)])
        ]
        let report = TransactionReport(playlistName: "Test", phases: phases,
            plan: nil, libraryVerification: nil, finalReadback: nil, succeeded: false)
        let rows = RecoveryViewModel.deriveRows(manifest: manifest, report: report)
        XCTAssertFalse(rows[0].libraryAdded)
        XCTAssertFalse(rows[0].appended)
        XCTAssertNotNil(rows[0].problem)
    }
}
