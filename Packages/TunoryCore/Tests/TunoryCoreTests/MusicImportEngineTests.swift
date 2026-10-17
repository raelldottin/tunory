import XCTest
@testable import TunoryCore

final class MusicImportEngineTests: XCTestCase {

    // MARK: - Test Helpers

    private func makeEngine(for tests: [String: [(key: String, value: String)]]? = nil,
                            matchThreshold: Int = 80,
                            fuzzyMatchThreshold: Int = 60) -> MusicImportEngine {
        return MusicImportEngine(musicCatalog: MockMusicCatalog(tests: tests),
                                 matchThreshold: matchThreshold,
                                 fuzzyMatchThreshold: fuzzyMatchThreshold)
    }

    private func makeFLAC(
        _ name: String,
        duration: Double = 10.0,
        album: String = "Test Album",
        album_artist: String = "Test Artist",
        artist: String = "Test Artist",
        genre: String = "Electronic",
        year: Int = 2023,
        track: Int = 1,
        disc: Int = 1,
        metadata: Bool = true // This is the important flag for GAP B tests
    ) -> AudioProbe {
        return AudioProbe(
            path: URL(fileURLWithPath: "/tmp/test_audio/\(name).flac"),
            duration: duration,
            tags: metadata ? [
                .title: name,
                .artist: artist,
                .album: album,
                .albumArtist: album_artist,
                .genre: genre,
                .year: String(year),
                .trackNumber: String(track),
                .discNumber: String(disc)
            ] : [:]
        )
    }

    // MARK: - GAP C: Backend Tests (Items 1-5, 7)

    // Item 1: `probe.tags` is non-optional with a default empty dict.
    // This is a structural change, and will be reflected by the compiler if it's incorrect.
    // Runtime tests will focus on correct tag usage.

    // Item 2: MusicTrackRef for import decision
    func testImportDecision_musicTrackRef_existsAndValidates() async throws {
        let engine = makeEngine()
        let trackRef = MusicTrackRef(id: "12345", title: "Test Song", artist: "Test Artist")
        let probe = makeFLAC("Test Song")

        let decision = try await engine.plan(file: probe, titleQuery: "Test Song", priorRecords: [])
        XCTAssertNotNil(decision.musicTrackRef, "MusicTrackRef should be present for a valid match")
        XCTAssertEqual(decision.musicTrackRef?.id, trackRef.id)
    }

    // Item 3: MatchKind.verifiedExisting
    func testClassify_matchKind_verifiedExisting() async throws {
        let engine = makeEngine()
        let probe = makeFLAC("Existing Song")
        let priorRecord = PriorRecord(probe: probe, matchKind: .exactMatch, matchedID: "existingID")
        let decision = try await engine.classify(file: probe, titleQuery: "Existing Song", priorRecords: [priorRecord])
        XCTAssertEqual(decision.matchKind, .verifiedExisting)
    }

    func testClassify_matchKind_verifiedExisting_withDifferentMetadata() async throws {
        let engine = makeEngine()
        let probe = makeFLAC("Existing Song", album: "New Album") // Different album metadata
        let priorRecord = PriorRecord(probe: makeFLAC("Existing Song"), matchKind: .exactMatch, matchedID: "existingID")
        let decision = try await engine.classify(file: probe, titleQuery: "Existing Song", priorRecords: [priorRecord])
        XCTAssertEqual(decision.matchKind, .verifiedExisting, "Should still be verifiedExisting despite metadata differences if other criteria match")
    }

    // Item 4: MusicImportDecision.skipVerifiedExisting
    func testImportDecision_skipVerifiedExisting() async throws {
        let engine = makeEngine()
        let probe = makeFLAC("Verified Existing Song")
        let priorRecord = PriorRecord(probe: probe, matchKind: .verifiedExisting, matchedID: "verifiedID")
        let decision = try await engine.plan(file: probe, titleQuery: "Verified Existing Song", priorRecords: [priorRecord])
        XCTAssertEqual(decision.status, .skippedDuplicate, "Should skip verified existing tracks")
        XCTAssertEqual(decision.matchKind, .verifiedExisting)
    }

    // Item 5: Title query uses probe.tags when available
    func testTitleQuery_usesProbeTags() {
        let probeWithTags = makeFLAC("Tagged Title", artist: "Tagged Artist")
        let titleQuery = MusicImportEngine.titleQuery(forFileAt: probeWithTags.path)
        XCTAssertTrue(titleQuery.contains("Tagged Title"), "Title query should use probe tags")
        XCTAssertTrue(titleQuery.contains("Tagged Artist"), "Title query should include artist from probe tags")
    }

    func testTitleQuery_usesFileName_whenNoProbeTags() {
        let probeWithoutTags = makeFLAC("Untagged Title", metadata: false)
        let titleQuery = MusicImportEngine.titleQuery(forFileAt: probeWithoutTags.path)
        XCTAssertTrue(titleQuery.contains("Untagged Title"), "Title query should use file name when no probe tags")
    }

    // Item 7: MusicAppScripting (Swift adapter) parse logic moves to TunoryCore

    // New tests for the MusicAppScripting.swift parse logic, now residing in TunoryCore.
    // These tests simulate the input `MusicAppScripting` would provide.

    func testMusicTrackParse_basicProperties() throws {
        let rawTrackData: [String: Any] = [
            "persistentID": "P12345",
            "name": "Test Song",
            "artist": "Test Artist",
            "album": "Test Album",
            "albumArtist": "Album Artist",
            "genre": "Pop",
            "year": 2023,
            "trackNumber": 1,
            "discNumber": 1,
            "duration": 200.0
        ]
        let musicTrack = try MusicTrack(from: rawTrackData)
        XCTAssertEqual(musicTrack.persistentID, "P12345")
        XCTAssertEqual(musicTrack.name, "Test Song")
        XCTAssertEqual(musicTrack.artist, "Test Artist")
        XCTAssertEqual(musicTrack.album, "Test Album")
        XCTAssertEqual(musicTrack.albumArtist, "Album Artist")
        XCTAssertEqual(musicTrack.genre, "Pop")
        XCTAssertEqual(musicTrack.year, 2023)
        XCTAssertEqual(musicTrack.trackNumber, 1)
        XCTAssertEqual(musicTrack.discNumber, 1)
        XCTAssertEqual(musicTrack.duration, 200.0)
    }

    func testMusicTrackParse_missingOptionalProperties() throws {
        let rawTrackData: [String: Any] = [
            "persistentID": "P67890",
            "name": "Another Song",
            "artist": "Another Artist"
            // Missing optional properties
        ]
        let musicTrack = try MusicTrack(from: rawTrackData)
        XCTAssertEqual(musicTrack.persistentID, "P67890")
        XCTAssertEqual(musicTrack.name, "Another Song")
        XCTAssertEqual(musicTrack.artist, "Another Artist")
        XCTAssertNil(musicTrack.album)
        XCTAssertNil(musicTrack.albumArtist)
        XCTAssertNil(musicTrack.genre)
        XCTAssertNil(musicTrack.year)
        XCTAssertNil(musicTrack.trackNumber)
        XCTAssertNil(musicTrack.discNumber)
        XCTAssertNil(musicTrack.duration)
    }

    func testMusicTrackParse_invalidProperties_typeMismatch() {
        let rawTrackData: [String: Any] = [
            "persistentID": "PInvalid",
            "name": "Invalid Song",
            "artist": "Invalid Artist",
            "year": "not a number" // Invalid type
        ]
        XCTAssertThrowsError(try MusicTrack(from: rawTrackData)) { error in
            XCTAssertTrue(error is MusicTrackParseError)
        }
    }

    func testMusicTrackParse_missingRequiredProperties() {
        let rawTrackData: [String: Any] = [
            "name": "Missing ID Song",
            "artist": "Missing ID Artist"
            // Missing persistentID
        ]
        XCTAssertThrowsError(try MusicTrack(from: rawTrackData)) { error in
            XCTAssertTrue(error is MusicTrackParseError)
        }
    }

    func testMusicTrackParse_emptyData() {
        let rawTrackData: [String: Any] = [:]
        XCTAssertThrowsError(try MusicTrack(from: rawTrackData)) { error in
            XCTAssertTrue(error is MusicTrackParseError)
        }
    }
}