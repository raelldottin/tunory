import XCTest
@testable import TunoryCore

final class AppleMusicLinkParsingTests: XCTestCase {

    func testParsesStandardSongLink() throws {
        let link = AppleMusicLink.parse("https://music.apple.com/us/album/the-lark-ascending/1436241413?i=1436241421&uo=4")
        XCTAssertEqual(link?.kind, .song)
        XCTAssertEqual(link?.catalogId, 1436241421)
        XCTAssertEqual(link?.storefront, "us")
        XCTAssertEqual(link?.albumId, 1436241413)
    }

    func testParsesLinkWithoutUo() throws {
        let link = AppleMusicLink.parse("https://music.apple.com/us/album/mercy/1440767384?i=1440767734")
        XCTAssertEqual(link?.kind, .song)
        XCTAssertEqual(link?.catalogId, 1440767734)
    }

    func testParsesHTMLAmpersandEscapedURL() throws {
        let link = AppleMusicLink.parse("https://music.apple.com/us/album/x/1440767384?i=1440767734&uo=4")
        XCTAssertEqual(link?.catalogId, 1440767734)
    }

    func testAlbumOnlyLinkHasNoSongId() throws {
        let link = AppleMusicLink.parse("https://music.apple.com/us/album/mercy/1440767384")
        XCTAssertEqual(link?.kind, .album)
        XCTAssertNil(link?.catalogId)
        XCTAssertEqual(link?.albumId, 1440767384)
    }

    func testRejectsNonAppleMusicHost() {
        XCTAssertNil(AppleMusicLink.parse("https://open.spotify.com/track/1436241421"))
        XCTAssertNil(AppleMusicLink.parse("https://example.com/us/album/x/1?i=2"))
        XCTAssertNil(AppleMusicLink.parse("https://music.apple.com.evil.com/us/album/x/1?i=2"))
        XCTAssertNil(AppleMusicLink.parse("https://musicapplecom/us/album/x/1?i=2"))
    }

    func testRejectsNonNumericIds() {
        XCTAssertNil(AppleMusicLink.parse("https://music.apple.com/us/album/x/abc?i=1436241421"))
        XCTAssertNil(AppleMusicLink.parse("https://music.apple.com/us/album/x/1436241413?i=abc"))
        XCTAssertNil(AppleMusicLink.parse("https://music.apple.com/us/album/x/0?i=0"))
    }

    func testRejectsEmptyAndGarbage() {
        XCTAssertNil(AppleMusicLink.parse(""))
        XCTAssertNil(AppleMusicLink.parse("random text"))
        XCTAssertNil(AppleMusicLink.parse("music.apple.com/us/album/x/1?i=2"))  // no scheme
    }

    func testParsesPlaylistLink() throws {
        let link = AppleMusicLink.parse("https://music.apple.com/us/playlist/after-hours/pl.u-9N9LxM4GqKX")
        XCTAssertEqual(link?.kind, .playlist)
        XCTAssertNil(link?.catalogId)
    }

    func testSongURLWithoutAlbumPathStillParses() throws {
        // Legacy song URLs: music.apple.com/us/song/id
        let link = AppleMusicLink.parse("https://music.apple.com/us/song/the-lark-ascending/1436241421")
        XCTAssertEqual(link?.kind, .song)
        XCTAssertEqual(link?.catalogId, 1436241421)
    }
}
