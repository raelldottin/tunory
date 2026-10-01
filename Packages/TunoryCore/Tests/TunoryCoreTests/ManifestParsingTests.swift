import XCTest
@testable import TunoryCore

final class ManifestParsingTests: XCTestCase {

    private func fixtureData(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).json")
        return try Data(contentsOf: url)
    }

    func testParseValidManifestWithAll17Entries() throws {
        let data = try fixtureData("valid-manifest")
        let result = try ManifestParser.parse(data: data)
        XCTAssertEqual(result.entries.count, 17)
        XCTAssertEqual(result.entries.first?.pos, 1)
        XCTAssertEqual(result.entries.first?.catalogId, 1436241421)
        XCTAssertEqual(result.entries.first?.name, "The Lark Ascending")
        XCTAssertEqual(result.entries.first?.artist, "Hilary Hahn, London Symphony Orchestra & Sir Colin Davis")
        XCTAssertEqual(result.entries.first?.durationSeconds, 1008)
        XCTAssertEqual(result.entries.first?.url, "https://music.apple.com/us/album/the-lark-ascending/1436241413?i=1436241421&uo=4")
        XCTAssertEqual(result.entries.last?.pos, 17)
        XCTAssertEqual(result.entries.last?.catalogId, 1561852731)
    }

    func testParseRejectsEmptyArray() {
        XCTAssertThrowsError(try ManifestParser.parse(data: Data("[]".utf8))) { error in
            guard case ManifestError.emptyManifest = error else {
                return XCTFail("expected emptyManifest, got \(error)")
            }
        }
    }

    func testParseRejectsDuplicateCatalogIds() {
        let json = """
        [
          {"pos": 1, "catalogId": 100, "name": "A", "artist": "X"},
          {"pos": 2, "catalogId": 100, "name": "B", "artist": "Y"}
        ]
        """
        XCTAssertThrowsError(try ManifestParser.parse(data: Data(json.utf8))) { error in
            guard case ManifestError.duplicateCatalogId(let id, let positions) = error else {
                return XCTFail("expected duplicateCatalogId, got \(error)")
            }
            XCTAssertEqual(id, 100)
            XCTAssertEqual(positions, [1, 2])
        }
    }

    func testParseRejectsNonPositiveCatalogId() {
        let json = """
        [{"pos": 1, "catalogId": 0, "name": "A", "artist": "X"}]
        """
        XCTAssertThrowsError(try ManifestParser.parse(data: Data(json.utf8))) { error in
            guard case ManifestError.invalidCatalogId(let pos) = error else {
                return XCTFail("expected invalidCatalogId, got \(error)")
            }
            XCTAssertEqual(pos, 1)
        }
    }

    func testParseRejectsBlankNameOrArtist() {
        let good = """
        [{"pos": 1, "catalogId": 10, "name": "A", "artist": "X", "album": "Z"}]
        """
        XCTAssertNoThrow(try ManifestParser.parse(data: Data(good.utf8)))

        let blankName = """
        [{"pos": 1, "catalogId": 10, "name": "  ", "artist": "X"}]
        """
        XCTAssertThrowsError(try ManifestParser.parse(data: Data(blankName.utf8)))

        let blankArtist = """
        [{"pos": 1, "catalogId": 10, "name": "A", "artist": ""}]
        """
        XCTAssertThrowsError(try ManifestParser.parse(data: Data(blankArtist.utf8)))
    }

    func testParseRejectsNonSequentialPositions() {
        let json = """
        [
          {"pos": 1, "catalogId": 100, "name": "A", "artist": "X"},
          {"pos": 3, "catalogId": 101, "name": "B", "artist": "Y"}
        ]
        """
        XCTAssertThrowsError(try ManifestParser.parse(data: Data(json.utf8))) { error in
            guard case ManifestError.nonSequentialPositions(let found, let expected) = error else {
                return XCTFail("expected nonSequentialPositions, got \(error)")
            }
            XCTAssertEqual(found, [1, 3])
            XCTAssertEqual(expected, [1, 2])
        }
    }

    func testParseRejectsNonPositiveDuration() {
        let json = """
        [{"pos": 1, "catalogId": 10, "name": "A", "artist": "X", "dur_s": -5}]
        """
        XCTAssertThrowsError(try ManifestParser.parse(data: Data(json.utf8))) { error in
            guard case ManifestError.invalidDuration = error else {
                return XCTFail("expected invalidDuration, got \(error)")
            }
        }
    }

    func testParseRejectsMalformedJSON() {
        XCTAssertThrowsError(try ManifestParser.parse(data: Data("not json".utf8)))
        XCTAssertThrowsError(try ManifestParser.parse(data: Data("{\"a\":1}".utf8)))
    }

    func testParsedEntriesAreSortedByPosRegardlessOfInputOrder() throws {
        let json = """
        [
          {"pos": 3, "catalogId": 103, "name": "C", "artist": "Z"},
          {"pos": 1, "catalogId": 101, "name": "A", "artist": "X"},
          {"pos": 2, "catalogId": 102, "name": "B", "artist": "Y"}
        ]
        """
        let result = try ManifestParser.parse(data: Data(json.utf8))
        XCTAssertEqual(result.entries.map(\.pos), [1, 2, 3])
        XCTAssertEqual(result.entries.map(\.catalogId), [101, 102, 103])
    }

    func testParseAcceptsMissingOptionalFields() throws {
        let json = """
        [{"pos": 1, "catalogId": 100, "name": "A", "artist": "X"}]
        """
        let result = try ManifestParser.parse(data: Data(json.utf8))
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertNil(result.entries.first?.album)
        XCTAssertNil(result.entries.first?.url)
        XCTAssertNil(result.entries.first?.durationSeconds)
    }

    func testParseRejectsURLThatIsNotAnAppleMusicSongLink() {
        let json = """
        [{"pos": 1, "catalogId": 100, "name": "A", "artist": "X", "url": "https://open.spotify.com/x"}]
        """
        XCTAssertThrowsError(try ManifestParser.parse(data: Data(json.utf8))) { error in
            guard case ManifestError.invalidURL = error else {
                return XCTFail("expected invalidURL, got \(error)")
            }
        }
    }

    func testParsedEntryIsImmutable() {
        let json = """
        [{"pos": 1, "catalogId": 100, "name": "A", "artist": "X"}]
        """
        let result = try? ManifestParser.parse(data: Data(json.utf8))
        XCTAssertNotNil(result)
    }
}
