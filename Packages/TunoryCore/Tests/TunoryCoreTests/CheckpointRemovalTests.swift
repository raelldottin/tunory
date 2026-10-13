import XCTest
@testable import TunoryCore

final class CheckpointRemovalTests: XCTestCase {
    func testSupersededCheckpointDoesNotClaimRemovalWhenDeletionFails() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tunory-removal-\(UUID().uuidString)", isDirectory: true)
        let store = CheckpointStore(directory: directory)
        let checkpoint = TransactionCheckpoint(playlistId: "test-owned-playlist", playlistName: "Test", manifestCatalogIds: [101], provenStoredPrefixCount: 1, provenLibraryCatalogIds: [101], capturedAtMillisSinceEpoch: 1)
        try store.save(checkpoint)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        XCTAssertFalse(store.clearIfSuperseded(bySuccessWith: checkpoint.playlistId, manifestCatalogIds: [101]), "Successful verification cannot turn a failed disk deletion into a claimed removal.")
        XCTAssertEqual(store.load(), .checkpoint(checkpoint))
    }
}
