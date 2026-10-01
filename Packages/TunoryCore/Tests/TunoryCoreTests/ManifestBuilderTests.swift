import XCTest
@testable import TunoryCore

/// ManifestBuilder tests: the canonical review-state → manifest path.
/// Every ManifestParser invariant must hold identically for GUI-built
/// manifests; adversarial cases prove the stops.
final class ManifestBuilderTests: XCTestCase {

    func testBuildsSequentialManifestFromReviewedLines() throws {
        let manifest = try ManifestParser.build(
            lineCount: 3,
            catalogIdForLine: { [10, 20, 30][$0 - 1] },
            nameForLine: { "Song \($0)" },
            artistForLine: { "Artist \($0)" })
        XCTAssertEqual(manifest.entries.map(\.catalogId), [10, 20, 30])
        XCTAssertEqual(manifest.entries.map(\.pos), [1, 2, 3])
    }

    func testUnresolvedLineStops() {
        XCTAssertThrowsError(try ManifestParser.build(
            lineCount: 2,
            catalogIdForLine: { $0 == 2 ? nil : 10 },
            nameForLine: { _ in "X" },
            artistForLine: { _ in "Y" })) { error in
            XCTAssertEqual(error as? ManifestError, .unresolvedLine(pos: 2))
        }
    }

    func testDuplicateIdentityStops() {
        XCTAssertThrowsError(try ManifestParser.build(
            lineCount: 2,
            catalogIdForLine: { _ in 10 },
            nameForLine: { _ in "X" },
            artistForLine: { _ in "Y" })) { error in
            XCTAssertEqual(error as? ManifestError,
                           .duplicateCatalogId(catalogId: 10, positions: [1, 2]))
        }
    }

    func testBlankNameStops() {
        XCTAssertThrowsError(try ManifestParser.build(
            lineCount: 1,
            catalogIdForLine: { _ in 10 },
            nameForLine: { $0 == 1 ? "  " : "X" },
            artistForLine: { _ in "Y" })) { error in
            XCTAssertEqual(error as? ManifestError, .blankName(pos: 1))
        }
    }

    func testBlankArtistStops() {
        XCTAssertThrowsError(try ManifestParser.build(
            lineCount: 1,
            catalogIdForLine: { _ in 10 },
            nameForLine: { _ in "X" },
            artistForLine: { _ in "" })) { error in
            XCTAssertEqual(error as? ManifestError, .blankArtist(pos: 1))
        }
    }

    func testEmptyStops() {
        XCTAssertThrowsError(try ManifestParser.build(
            lineCount: 0,
            catalogIdForLine: { _ in nil },
            nameForLine: { _ in "" },
            artistForLine: { _ in "" })) { error in
            XCTAssertEqual(error as? ManifestError, .emptyManifest)
        }
    }

    func testInvalidCatalogIdStops() {
        XCTAssertThrowsError(try ManifestParser.build(
            lineCount: 1,
            catalogIdForLine: { _ in 0 },
            nameForLine: { _ in "X" },
            artistForLine: { _ in "Y" })) { error in
            XCTAssertEqual(error as? ManifestError, .invalidCatalogId(pos: 1))
        }
    }

    /// Property: a GUI-built manifest is always parse-equivalent to a file
    /// manifest with the same identities — one canonical validation.
    func testBuiltManifestPassesFileValidationRoundTrip() throws {
        let built = try ManifestParser.build(
            lineCount: 4,
            catalogIdForLine: { [501, 502, 503, 504][$0 - 1] },
            nameForLine: { "N\($0)" },
            artistForLine: { "A\($0)" })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Re-encode in the manifest file DTO shape and parse as a file:
        struct DTO: Encodable { let pos, catalogId: Int; let name, artist: String }
        let dtos = built.entries.map { DTO(pos: $0.pos, catalogId: $0.catalogId,
                                           name: $0.name, artist: $0.artist) }
        let data = try encoder.encode(dtos)
        let parsed = try ManifestParser.parse(data: data)
        XCTAssertEqual(parsed.entries.map(\.catalogId), built.entries.map(\.catalogId))
        XCTAssertEqual(parsed.entries.map(\.name), built.entries.map(\.name))
    }
}
