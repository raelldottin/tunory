import XCTest
@testable import TunoryCore

final class PastedListParsingTests: XCTestCase {

    func testParsesNewlineSeparatedTitles() {
        let text = """
        The Lark Ascending
        Mercy
        Sonata for Violin Solo No. 1 in G Minor, BWV 1001: III. Siciliana
        """
        let lines = PastedListParser.parse(text)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].rawTitle, "The Lark Ascending")
    }

    func testStripsLeadingTrackNumbersAndDots() {
        let text = """
        1. The Lark Ascending
        2) Mercy
        3 - Sonata for Violin Solo No. 1: III. Siciliana
        12.\tOblivion
        """
        let lines = PastedListParser.parse(text)
        XCTAssertEqual(lines.map(\.rawTitle),
                       ["The Lark Ascending", "Mercy",
                        "Sonata for Violin Solo No. 1: III. Siciliana", "Oblivion"])
    }

    func testDoesNotStripNumbersInsideTitles() {
        let text = """
        3 Gymnopédies: III. Lent et grave
        Sonata for Violin Solo No. 1 in G Minor, BWV 1001: III. Siciliana
        """
        let lines = PastedListParser.parse(text)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].rawTitle, "3 Gymnopédies: III. Lent et grave")
        XCTAssertEqual(lines[1].rawTitle, "Sonata for Violin Solo No. 1 in G Minor, BWV 1001: III. Siciliana")
    }

    func testStripsLeadingQuotationMarks() {
        let text = """
        "The Lark Ascending"
        'Mercy'
        “Sofðu unga ástin mín”
        """
        let lines = PastedListParser.parse(text)
        XCTAssertEqual(lines.map(\.rawTitle),
                       ["The Lark Ascending", "Mercy", "Sofðu unga ástin mín"])
    }

    func testEmptyAndBlankLinesProduceNothing() {
        XCTAssertEqual(PastedListParser.parse(""), [])
        XCTAssertEqual(PastedListParser.parse("\n\n   \n\t\n"), [])
        XCTAssertFalse(PastedListParser.isActionable("\n\n   \n"))
        XCTAssertTrue(PastedListParser.isActionable("A"))
    }

    func testRecognizesLinksInsidePastedText() {
        let text = """
        The Lark Ascending
        https://music.apple.com/us/album/the-lark-ascending/1436241413?i=1436241421&uo=4
        Mercy
        """
        let lines = PastedListParser.parse(text)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].kind, .name)
        XCTAssertEqual(lines[1].kind, .link)
        XCTAssertEqual(lines[1].catalogId, 1436241421)
        XCTAssertEqual(lines[2].kind, .name)
    }

    func testParsesTitleDashArtistLines() {
        let text = """
        The Lark Ascending - Hilary Hahn
        Mercy — Hilary Hahn & Cory Smythe
        """
        let lines = PastedListParser.parse(text)
        XCTAssertEqual(lines[0].title, "The Lark Ascending")
        XCTAssertEqual(lines[0].artistHint, "Hilary Hahn")
        XCTAssertEqual(lines[1].title, "Mercy")
        XCTAssertEqual(lines[1].artistHint, "Hilary Hahn & Cory Smythe")
    }

    func testDashSplitOnlyWhenSeparatorIsClear() {
        // "Partita No. 2 in D Minor, BWV 1004: III. Sarabande" has no dash
        let lines = PastedListParser.parse("Violin Partita No. 2 in D Minor, BWV 1004: III. Sarabande")
        XCTAssertEqual(lines[0].title, "Violin Partita No. 2 in D Minor, BWV 1004: III. Sarabande")
        XCTAssertNil(lines[0].artistHint)
        // En-dash and em-dash both split
        XCTAssertEqual(PastedListParser.parse("X – Y").first?.artistHint, "Y")
        XCTAssertEqual(PastedListParser.parse("X — Y").first?.artistHint, "Y")
    }

    func testPositionsAssignedInOrder() {
        let text = "A\nB\nC"
        let lines = PastedListParser.parse(text)
        XCTAssertEqual(lines.map(\.pos), [1, 2, 3])
    }

    func testTrimsTrailingDurationMarkers() {
        // Common paste artifacts: "(4:12)" or "[4:12]" at end
        let lines = PastedListParser.parse("Mercy (3:32)")
        XCTAssertEqual(lines[0].title, "Mercy")
    }
}
