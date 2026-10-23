import XCTest
@testable import TunoryCore

// Comprehensive duplicate-preflight test suite (task t_73c7491b).
//
// Scope relative to the parent suite (MusicImportEngineTests, 17 GAP C
// tests on hand-built byte fixtures and in-memory tags): this suite adds
// (a) the four classification scenarios named by the task card —
// 'verified existing', 'verified missing', 'conflict', 'unreadable' —
// (b) classification driven by REAL/synthetic FLAC bitstreams (ffmpeg
// lavfi fixtures with genuine vorbis comments flowing through the GAP B
// mapping into AudioMetadataTags), and (c) an expanded adversarial /
// property suite pinning ordering, boundary, Unicode, and empty-value
// behavior of the conservative classifier.
//
// Fixture contract (t_dc244b34 §8): fixtures are generated INTO
// TEST-OWNED TEMP DIRS at test time — never the real library, never
// committed binaries. ffmpeg is fixture tooling ONLY. When absent,
// fixture-dependent tests skip VISIBLY (XCTSkip), never silently pass;
// every pure decision-theory test runs without ffmpeg.
//
// Library data is MOCKED (PreflightScriptingFake): no live Music.app,
// no library writes. This is read-only + fake-write proof, per the
// board's proof ladder.

final class MusicDuplicatePreflightTests: XCTestCase {

    var work: URL!
    var ffmpegURL: URL?

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunory-preflight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        ffmpegURL = MusicDuplicatePreflightTests.locateFFmpeg()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: work)
    }

    static func locateFFmpeg() -> URL? {
        var candidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/local/bin/ffmpeg"),
        ]
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            candidates.append(URL(fileURLWithPath: String(dir)).appendingPathComponent("ffmpeg"))
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: - Fixture generation (synthetic, test-owned)

    /// REAL FLAC bitstream with a full six-axis vorbis comment block.
    /// `tags: false` produces a genuinely tagless FLAC; individual axes
    /// are omitted when nil (partial-tag fixtures).
    @discardableResult
    func makeRealFLAC(name: String,
                      title: String? = "Golden Hour",
                      artist: String? = "Artist",
                      album: String? = "Album",
                      albumArtist: String? = "Album Artist",
                      disc: Int? = 1,
                      track: Int? = 7,
                      trackTotal: Int? = 12,
                      duration: Double = 3,
                      sampleRate: Int = 44100,
                      channels: Int = 1) throws -> URL {
        guard let ffmpeg = ffmpegURL else { throw XCTSkip("ffmpeg not installed (fixture generation only)") }
        let out = work.appendingPathComponent(name)
        var args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-f", "lavfi",
                    "-i", "sine=frequency=440:duration=\(duration):sample_rate=\(sampleRate)",
                    "-ac", "\(channels)",
                    "-f", "flac", "-c:a", "flac"]
        if let title { args += ["-metadata", "title=\(title)"] }
        if let artist { args += ["-metadata", "artist=\(artist)"] }
        if let album { args += ["-metadata", "album=\(album)"] }
        if let albumArtist { args += ["-metadata", "ALBUMARTIST=\(albumArtist)"] }
        if let disc { args += ["-metadata", "DISCNUMBER=\(disc)"] }
        if let track {
            // "n/total" positional form when a total is given (the GAP B
            // parser keeps the leading number); bare "n" otherwise.
            let value = trackTotal.map { "\(track)/\($0)" } ?? "\(track)"
            args += ["-metadata", "TRACKNUMBER=\(value)"]
        }
        args.append(out.path)
        try runProcess(ffmpeg, args)
        return out
    }

    /// Garbage bytes: a corrupt candidate that IS hashable (so the
    /// undecodable path does not apply) but never decodes.
    func makeCorruptFLAC(name: String) throws -> URL {
        let out = work.appendingPathComponent(name)
        try Data("fLaC but the stream is garbage beyond this point".utf8).write(to: out)
        return out
    }

    func makeBytes(name: String, _ bytes: [UInt8]) throws -> URL {
        let out = work.appendingPathComponent(name)
        try Data(bytes).write(to: out)
        return out
    }

    @discardableResult
    func runProcess(_ url: URL, _ arguments: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = url
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    // MARK: - Value builders

    func tags(title: String? = "Golden Hour",
              artist: String? = "Artist",
              album: String? = "Album",
              albumArtist: String? = "Album Artist",
              disc: Int? = 1,
              track: Int? = 7) -> AudioMetadataTags {
        AudioMetadataTags(title: title, artist: artist, album: album,
                          albumArtist: albumArtist, discNumber: disc, trackNumber: track)
    }

    func twin(id: String = "PF01",
              title: String? = "Golden Hour",
              artist: String? = "Artist",
              album: String? = "Album",
              albumArtist: String? = "Album Artist",
              disc: Int? = 1,
              track: Int? = 7,
              location: String,
              duration: Double? = 200.0) -> MusicTrackRef {
        MusicTrackRef(persistentID: id, name: title, artist: artist, album: album,
                      albumArtist: albumArtist, discNumber: disc, trackNumber: track,
                      locationPath: location, durationSeconds: duration)
    }

    // MARK: - A. The four classification scenarios (card vocabulary)

    func test_scenarios_verifiedExisting_realFLACTwin() throws {
        // 'verified existing': a genuinely tagged FLAC candidate whose
        // six axes all match the library twin within duration tolerance.
        let candidate = try makeRealFLAC(name: "studio.flac")
        let libraryFile = try makeBytes(name: "library.m4a", [9, 9, 9, 9])
        let hash = LocalImportEngine.sha256Hex(fileURL: candidate)!
        let survey = MusicImportEngine.classify(filePath: candidate.path,
                                                candidateHash: hash,
                                                candidateTags: tags(),
                                                candidateDurationSeconds: 200.0,
                                                libraryTracks: [twin(location: libraryFile.path,
                                                                     duration: 201.5)])
        XCTAssertEqual(survey.matchKind, .verifiedExisting)
        XCTAssertEqual(survey.duplicate?.persistentID, "PF01",
                       "the proven twin is carried as skip evidence")
        XCTAssertEqual(MusicImportEngine.decision(for: survey), .skipVerifiedExisting)
    }

    func test_scenarios_verifiedMissing_emptyLibrary_importCandidate() throws {
        // 'verified missing': no library candidate at all -> import may
        // proceed. Proven with a real FLAC candidate hash.
        let candidate = try makeRealFLAC(name: "new.flac")
        let hash = LocalImportEngine.sha256Hex(fileURL: candidate)!
        let engine = MusicImportEngine(scripting: PreflightScriptingFake())
        let survey = engine.plan(filePath: candidate.path,
                                 candidateHash: hash,
                                 candidateTags: tags(),
                                 candidateDurationSeconds: 200.0,
                                 libraryTracks: [])
        XCTAssertEqual(survey.matchKind, .noCandidate)
        XCTAssertEqual(MusicImportEngine.decision(for: survey), .importCandidate)
    }

    func test_scenarios_conflict_metadataTwin_requiresReview() async throws {
        // 'conflict': candidate metadata exists but identity is NOT
        // provable -> explicit review, never auto-import, never skip.
        let candidate = try makeRealFLAC(name: "conflict.flac", album: "Deluxe Edition")
        let libraryFile = try makeBytes(name: "library.m4a", [8, 8, 8])
        let loaded = try await classifyLoaded(candidate: candidate, library: libraryFile,
                                              twinDuration: 200.0)
        XCTAssertEqual(loaded.matchKind, .needsReview)
        XCTAssertEqual(loaded.candidates.count, 1, "review carries the conflicting candidate as evidence")
        XCTAssertEqual(MusicImportEngine.decision(for: loaded), .reviewRequired)
    }

    func test_scenarios_unreadable_missingFile_andNilHash() throws {
        // 'unreadable': the candidate itself is missing or unhashable —
        // no honest import decision can be derived from it.
        let engine = MusicImportEngine(scripting: PreflightScriptingFake())
        let missing = work.appendingPathComponent("missing.flac")
        let surveyA = engine.plan(filePath: missing.path,
                                  candidateHash: nil,
                                  libraryTracks: [])
        XCTAssertEqual(surveyA.matchKind, .undecodableCandidate)
        XCTAssertEqual(MusicImportEngine.decision(for: surveyA), .undecodableFile)

        let unreadable = try makeBytes(name: "nohash.bin", [1, 2, 3])
        // A directory-as-file trick is not needed: nil hash is the other
        // undecodable trigger, exercised directly.
        let surveyB = engine.plan(filePath: unreadable.path,
                                  candidateHash: nil,
                                  libraryTracks: [])
        XCTAssertEqual(surveyB.matchKind, .undecodableCandidate)
        XCTAssertEqual(MusicImportEngine.decision(for: surveyB), .undecodableFile)
    }

    /// classify() with tags/duration loaded from the REAL candidate file
    /// (the same self-load path surveyFile/importFile use).
    func classifyLoaded(candidate: URL, library: URL, twinDuration: Double) async throws -> MusicLibraryCandidate {
        let loaded = await MusicImportEngine.loadCandidateTags(file: candidate)
        return MusicImportEngine.classify(filePath: candidate.path,
                                          candidateHash: LocalImportEngine.sha256Hex(fileURL: candidate)!,
                                          candidateTags: loaded?.tags,
                                          candidateDurationSeconds: loaded?.duration,
                                          libraryTracks: [twin(location: library.path,
                                                               duration: twinDuration)])
    }

    // MARK: - B. Real / synthetic FLAC diversity

    func test_realFLACFixtureSet_isDiverseAndValid() async throws {
        // The fixture set itself must be diverse: distinct bitstreams,
        // valid FLAC probes, differing sample rates and channel counts.
        let a = try makeRealFLAC(name: "a44.flac", duration: 3, sampleRate: 44100, channels: 1)
        let b = try makeRealFLAC(name: "b48.flac", title: "Other Title", track: 3,
                                 duration: 4, sampleRate: 48000, channels: 2)
        let hashA = LocalImportEngine.sha256Hex(fileURL: a)!
        let hashB = LocalImportEngine.sha256Hex(fileURL: b)!
        XCTAssertNotEqual(hashA, hashB, "distinct fixtures must not be byte-identical")

        let probeA = await AudioProber().probe(url: a)
        XCTAssertEqual(probeA.codec, "flac")
        XCTAssertEqual(probeA.sampleRate, 44100)
        let probeB = await AudioProber().probe(url: b)
        XCTAssertEqual(probeB.codec, "flac")
        XCTAssertEqual(probeB.sampleRate, 48000)
        XCTAssertEqual(probeB.channels, 2, "stereo fixture must really be stereo")
    }

    func test_realFLAC_verifiedExisting_viaSelfLoadedTags() async throws {
        // End-to-end identity proof on a REAL FLAC: the vorbis comment
        // block flows through the GAP B mapping into AudioMetadataTags,
        // and those self-loaded axes verify against the twin. The twin's
        // duration (3.0) sits within ±2 s of the candidate's real
        // decoded duration (~3 s), so this exercises the true tolerance
        // band rather than fabricated numbers.
        let candidate = try makeRealFLAC(name: "selfload.flac")
        let libraryFile = try makeBytes(name: "library.m4a", [9, 9, 9])
        let loaded = await MusicImportEngine.loadCandidateTags(file: candidate)
        XCTAssertEqual(loaded?.tags?.title, "Golden Hour")
        XCTAssertEqual(loaded?.tags?.trackNumber, 7, "vorbis 'n/total' TRACKNUMBER must self-load as 7")

        let survey = try await classifyLoaded(candidate: candidate, library: libraryFile,
                                              twinDuration: 3.0)
        XCTAssertEqual(survey.matchKind, .verifiedExisting,
                       "real vorbis axes + decoded duration within ±2 s must verify")
        XCTAssertEqual(survey.duplicate?.persistentID, "PF01")
    }

    func test_realFLAC_tagless_staysReview_missingAxes() async throws {
        // A genuinely tagless FLAC: self-load yields nil axes on every
        // field, identity is unprovable, and the funnel stays review —
        // never a verified skip, never a silent import.
        let candidate = try makeRealFLAC(name: "bare.flac", title: nil, artist: nil,
                                         album: nil, albumArtist: nil,
                                         disc: nil, track: nil)
        let libraryFile = try makeBytes(name: "library.m4a", [9, 9, 9])
        let loaded = await MusicImportEngine.loadCandidateTags(file: candidate)
        XCTAssertNotNil(loaded?.tags)
        XCTAssertNil(loaded?.tags?.title)

        let survey = try await classifyLoaded(candidate: candidate, library: libraryFile,
                                              twinDuration: 3.0)
        XCTAssertEqual(survey.matchKind, .needsReview,
                       "a tagless candidate cannot prove identity — review")
        XCTAssertEqual(MusicImportEngine.decision(for: survey), .reviewRequired)
    }

    func test_realFLAC_partialTags_staysReview() async throws {
        // Only title/artist present (album, album artist, disc, track
        // missing): each missing axis is unprovable, not a wildcard.
        let candidate = try makeRealFLAC(name: "partial.flac", album: nil,
                                         albumArtist: nil, disc: nil, track: nil)
        let libraryFile = try makeBytes(name: "library.m4a", [7, 7, 7])
        let survey = try await classifyLoaded(candidate: candidate, library: libraryFile,
                                              twinDuration: 3.0)
        XCTAssertEqual(survey.matchKind, .needsReview,
                       "partial tags cannot prove identity — review")
    }

    func test_realFLAC_garbagePositionalTags_stayNilAndReview() async throws {
        // Unparseable DISCNUMBER/TRACKNUMBER must load as nil (skipped,
        // never guessed) and therefore never verify.
        guard let ffmpeg = ffmpegURL else { throw XCTSkip("ffmpeg not installed (fixture generation only)") }
        let candidate = work.appendingPathComponent("garbage.flac")
        try runProcess(ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error",
                                "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                                "-f", "flac", "-c:a", "flac",
                                "-metadata", "title=Golden Hour",
                                "-metadata", "artist=Artist", "-metadata", "album=Album",
                                "-metadata", "ALBUMARTIST=Album Artist",
                                "-metadata", "DISCNUMBER=not-a-number",
                                "-metadata", "TRACKNUMBER=also-not-a-number",
                                candidate.path])
        let loadedTags = await AudioProber().loadTags(url: candidate)
        XCTAssertNil(loadedTags?.discNumber, "garbage positional tags must stay nil")
        XCTAssertNil(loadedTags?.trackNumber)

        let libraryFile = try makeBytes(name: "library.m4a", [5, 5])
        let survey = try await classifyLoaded(candidate: candidate, library: libraryFile,
                                              twinDuration: 3.0)
        XCTAssertEqual(survey.matchKind, .needsReview,
                       "nil disc/track axes are unprovable — review, never verify")
    }

    func test_corruptFLAC_hashableButNeverVerified() async throws {
        // Adversarial: a corrupt candidate is still hashable bytes, so it
        // is NOT 'unreadable' to the funnel — but its tags never load,
        // so it can neither verify nor silently import. With a metadata
        // twin present it must land in review.
        let candidate = try makeCorruptFLAC(name: "corrupt.flac")
        let libraryFile = try makeBytes(name: "library.m4a", [3, 3, 3])
        let survey = try await classifyLoaded(candidate: candidate, library: libraryFile,
                                              twinDuration: 3.0)
        XCTAssertEqual(survey.matchKind, .needsReview,
                       "corrupt bytes must never produce a verified skip")
    }

    // MARK: - C. Non-conflation: live versions, alternate mixes, remasters

    func test_liveVersion_differentAlbumAndDuration_neverVerified() throws {
        // A live version: same song title family, live album, longer
        // duration. Both differences independently prevent conflation.
        let candidate = try makeRealFLAC(name: "live.flac",
                                         title: "Golden Hour (Live)",
                                         album: "Live in Paris",
                                         duration: 6)
        let libraryFile = try makeBytes(name: "library.m4a", [9, 9])
        let hash = LocalImportEngine.sha256Hex(fileURL: candidate)!

        // Same title + album axes as the live candidate, studio duration:
        // ONLY the duration separates them.
        let durationOnly = MusicImportEngine.classify(
            filePath: candidate.path, candidateHash: hash,
            candidateTags: tags(title: "Golden Hour (Live)", album: "Live in Paris"),
            candidateDurationSeconds: 251.0,
            libraryTracks: [twin(title: "Golden Hour (Live)", album: "Live in Paris",
                                location: libraryFile.path, duration: 200.0)])
        XCTAssertEqual(durationOnly.matchKind, .needsReview,
                       "a live take 51 s longer than the studio twin is a different recording — review")

        // Studio twin with matching duration but different album/title:
        let metadataOnly = MusicImportEngine.classify(
            filePath: candidate.path, candidateHash: hash,
            candidateTags: tags(title: "Golden Hour (Live)", album: "Live in Paris"),
            candidateDurationSeconds: 200.0,
            libraryTracks: [twin(title: "Golden Hour", album: "Album",
                                 location: libraryFile.path, duration: 200.0)])
        XCTAssertEqual(metadataOnly.matchKind, .needsReview,
                       "same-length live version on a different album is not the studio recording")
    }

    func test_alternateMix_differentTitle_requiresReview() throws {
        // Alternate mix: same artist/album/duration, different title.
        // The classifier must not conflate "Song" with "Song (Alternate
        // Mix)". (A metadata-IDENTICAL alternate mix is indistinguish-
        // able by ANY metadata classifier — the strategy doc records
        // fingerprinting cannot adjudicate those either; that resolution
        // boundary is accepted at the parent's design level.)
        let candidate = try makeRealFLAC(name: "mix.flac", title: "Golden Hour (Alternate Mix)")
        let libraryFile = try makeBytes(name: "library.m4a", [9, 9])
        let hash = LocalImportEngine.sha256Hex(fileURL: candidate)!
        let survey = MusicImportEngine.classify(
            filePath: candidate.path, candidateHash: hash,
            candidateTags: tags(title: "Golden Hour (Alternate Mix)"),
            candidateDurationSeconds: 200.0,
            libraryTracks: [twin(title: "Golden Hour", location: libraryFile.path,
                                 duration: 200.0)])
        XCTAssertEqual(survey.matchKind, .needsReview,
                       "an alternate mix is a different recording from the original — review")
    }

    func test_remaster_sameDurationDifferentDisc_requiresReview() throws {
        // A remaster sitting on the bonus disc of a deluxe edition:
        // identical core axes but disc 2 — a different release.
        let candidate = try makeRealFLAC(name: "remaster.flac")
        let libraryFile = try makeBytes(name: "library.m4a", [9, 9])
        let hash = LocalImportEngine.sha256Hex(fileURL: candidate)!
        let survey = MusicImportEngine.classify(
            filePath: candidate.path, candidateHash: hash,
            candidateTags: tags(),
            candidateDurationSeconds: 200.0,
            libraryTracks: [twin(disc: 2, location: libraryFile.path, duration: 200.0)])
        XCTAssertEqual(survey.matchKind, .needsReview,
                       "same recording on a bonus disc is a different release — review")
    }

    // MARK: - D. Adversarial / property suite

    func test_property_determinism_sameInputsSameResult() throws {
        // Determinism: the classifier is a pure function — 50 repeated
        // classifications with identical inputs must be identical.
        let candidate = try makeRealFLAC(name: "det.flac")
        let libraryFile = try makeBytes(name: "library.m4a", [9, 9])
        let hash = LocalImportEngine.sha256Hex(fileURL: candidate)!
        let first = MusicImportEngine.classify(filePath: candidate.path, candidateHash: hash,
                                                candidateTags: tags(),
                                                candidateDurationSeconds: 200.0,
                                                libraryTracks: [twin(location: libraryFile.path,
                                                                    duration: 200.5)])
        for _ in 0..<50 {
            let again = MusicImportEngine.classify(filePath: candidate.path, candidateHash: hash,
                                                   candidateTags: tags(),
                                                   candidateDurationSeconds: 200.0,
                                                   libraryTracks: [twin(location: libraryFile.path,
                                                                        duration: 200.5)])
            XCTAssertEqual(again, first)
        }
    }

    func test_property_singleAxisSweep_everyDifferenceOrAbsenceStaysReview() throws {
        // Property: for EACH of the six axes, a differing value OR a
        // missing value ON EITHER SIDE must break verification. Base
        // case verifies; every single-axis mutation must review.
        let candidate = try makeRealFLAC(name: "sweep.flac")
        let libraryFile = try makeBytes(name: "library.m4a", [9, 9])
        let hash = LocalImportEngine.sha256Hex(fileURL: candidate)!

        let base = MusicImportEngine.classify(filePath: candidate.path, candidateHash: hash,
                                              candidateTags: tags(),
                                              candidateDurationSeconds: 200.0,
                                              libraryTracks: [twin(location: libraryFile.path,
                                                                   duration: 200.0)])
        XCTAssertEqual(base.matchKind, .verifiedExisting, "base case must verify first")

        // One side mutated per pass; the OTHER side stays at defaults.
        // (candidateTags mutation, twin mutation)
        let mutations: [(String, (String?) -> AudioMetadataTags, (String?) -> MusicTrackRef)] = [
            ("title", { self.tags(title: $0) }, { self.twin(title: $0, location: libraryFile.path, duration: 200.0) }),
            ("artist", { self.tags(artist: $0) }, { self.twin(artist: $0, location: libraryFile.path, duration: 200.0) }),
            ("album", { self.tags(album: $0) }, { self.twin(album: $0, location: libraryFile.path, duration: 200.0) }),
            ("albumArtist", { self.tags(albumArtist: $0) }, { self.twin(albumArtist: $0, location: libraryFile.path, duration: 200.0) }),
            ("disc", { self.tags(disc: $0.flatMap { Int($0) }) }, { self.twin(disc: $0.flatMap { Int($0) }, location: libraryFile.path, duration: 200.0) }),
            ("track", { self.tags(track: $0.flatMap { Int($0) }) }, { self.twin(track: $0.flatMap { Int($0) }, location: libraryFile.path, duration: 200.0) }),
        ]
        let defaultTwin = twin(location: libraryFile.path, duration: 200.0)
        for (axis, candMut, twinMut) in mutations {
            for altered in [nil, "Different Value"] {
                // Candidate side mutated, library side at defaults:
                let survey = MusicImportEngine.classify(filePath: candidate.path, candidateHash: hash,
                                                        candidateTags: candMut(altered),
                                                        candidateDurationSeconds: 200.0,
                                                        libraryTracks: [defaultTwin])
                XCTAssertEqual(survey.matchKind, .needsReview,
                               "candidate-side axis \(axis) altered to '\(altered ?? "nil")' must break verification")
                // Library side mutated, candidate side at defaults:
                let surveyLib = MusicImportEngine.classify(filePath: candidate.path, candidateHash: hash,
                                                           candidateTags: tags(),
                                                           candidateDurationSeconds: 200.0,
                                                           libraryTracks: [twinMut(altered)])
                XCTAssertEqual(surveyLib.matchKind, .needsReview,
                               "library-side axis \(axis) altered to '\(altered ?? "nil")' must break verification")
            }
        }
    }

    func test_property_durationBoundary_inclusiveAtTolerance_rejectsJustBeyond() throws {
        let candidate = try makeRealFLAC(name: "edge.flac")
        let libraryFile = try makeBytes(name: "library.m4a", [9, 9])
        let hash = LocalImportEngine.sha256Hex(fileURL: candidate)!
        let tol = MusicImportEngine.metadataDurationToleranceSeconds
        XCTAssertEqual(tol, 2.0, "tolerance is a named public contract")

        func classify(candidateDuration: Double?, twinDuration: Double?) -> MusicLibraryCandidate {
            MusicImportEngine.classify(filePath: candidate.path, candidateHash: hash,
                                       candidateTags: tags(),
                                       candidateDurationSeconds: candidateDuration,
                                       libraryTracks: [twin(location: libraryFile.path,
                                                            duration: twinDuration)])
        }
        XCTAssertEqual(classify(candidateDuration: 200.0, twinDuration: 202.0).matchKind,
                       .verifiedExisting, "|Δ| == tolerance is inclusive (documented)")
        XCTAssertEqual(classify(candidateDuration: 200.0, twinDuration: 198.0).matchKind,
                       .verifiedExisting, "symmetric below")
        XCTAssertEqual(classify(candidateDuration: 200.0, twinDuration: 202.0001).matchKind,
                       .needsReview, "just beyond the band is a different recording")
        XCTAssertEqual(classify(candidateDuration: 200.0, twinDuration: 197.9999).matchKind,
                       .needsReview, "just below the band is a different recording")
        XCTAssertEqual(classify(candidateDuration: nil, twinDuration: 200.0).matchKind,
                       .needsReview, "missing candidate duration is unprovable")
        XCTAssertEqual(classify(candidateDuration: 200.0, twinDuration: nil).matchKind,
                       .needsReview, "missing library duration is unprovable")
    }

    func test_property_byteIdenticalOutranksMetadata_twinFirst() throws {
        // Byte equality is the strongest proof: the SAME FLAC bitstream
        // in the library must classify exactDuplicate even though every
        // metadata axis also matches (which would otherwise verify).
        let candidate = try makeRealFLAC(name: "original.flac")
        let libraryCopy = try makeBytes(name: "copy.flac",
                                        Array(try Data(contentsOf: candidate)))
        let hash = LocalImportEngine.sha256Hex(fileURL: candidate)!
        let survey = MusicImportEngine.classify(filePath: candidate.path, candidateHash: hash,
                                                candidateTags: tags(),
                                                candidateDurationSeconds: 200.0,
                                                libraryTracks: [twin(location: libraryCopy.path,
                                                                     duration: 200.0)])
        XCTAssertEqual(survey.matchKind, .exactDuplicate,
                       "byte-identical must outrank metadata verification")
        XCTAssertEqual(MusicImportEngine.decision(for: survey), .skipExactDuplicate)
    }

    func test_adversarial_ordering_metadataTwinBeforeByteTwin_verifiedExisting() throws {
        // Adversarial ordering: the funnel is per-track in deterministic
        // loop order, so a VERIFIED twin listed BEFORE the byte twin
        // returns early as verifiedExisting. Both outcomes are skip
        // decisions (no duplicate import either way); the difference is
        // only which evidence the skip carries. Pin the actual behavior.
        let candidate = try makeRealFLAC(name: "order.flac")
        let libraryCopy = try makeBytes(name: "copy.flac",
                                        Array(try Data(contentsOf: candidate)))
        let otherFile = try makeBytes(name: "other.m4a", [4, 4])
        let hash = LocalImportEngine.sha256Hex(fileURL: candidate)!
        let survey = MusicImportEngine.classify(
            filePath: candidate.path, candidateHash: hash,
            candidateTags: tags(), candidateDurationSeconds: 200.0,
            libraryTracks: [twin(id: "META1", location: otherFile.path, duration: 200.0),
                            twin(id: "BYTE1", location: libraryCopy.path, duration: 200.0)])
        XCTAssertEqual(survey.matchKind, .verifiedExisting,
                       "deterministic loop order: the earlier verified twin returns first")
        XCTAssertEqual(survey.duplicate?.persistentID, "META1")
        // Both orderings skip — never a duplicate import:
        let flipped = MusicImportEngine.classify(
            filePath: candidate.path, candidateHash: hash,
            candidateTags: tags(), candidateDurationSeconds: 200.0,
            libraryTracks: [twin(id: "BYTE1", location: libraryCopy.path, duration: 200.0),
                            twin(id: "META1", location: otherFile.path, duration: 200.0)])
        XCTAssertEqual(flipped.matchKind, .exactDuplicate)
        XCTAssertNotEqual(MusicImportEngine.decision(for: survey),
                          MusicImportEngine.decision(for: flipped))
    }

    func test_adversarial_unicodeCanonicalEquivalence_verifies() throws {
        // Swift String equality is Unicode-canonicalizing: a precomposed
        // "Café" (NFC) and a decomposed "Cafe\u{0301}" (NFD) are ==.
        // The classifier therefore treats canonically-equivalent titles
        // as equal even though their UTF-8 bytes differ. That is the
        // correct identity semantics (same text), and it is pinned here
        // because it is NOT byte equality — a subtle adversarial case.
        let candidate = try makeRealFLAC(name: "unicode.flac",
                                         title: "Caf\u{00E9} au Jazz",
                                         albumArtist: "Cafe\u{0301} au Jazz")
        let libraryFile = try makeBytes(name: "library.m4a", [9, 9])
        let hash = LocalImportEngine.sha256Hex(fileURL: candidate)!
        let survey = MusicImportEngine.classify(
            filePath: candidate.path, candidateHash: hash,
            candidateTags: tags(title: "Caf\u{00E9} au Jazz"),
            candidateDurationSeconds: 200.0,
            libraryTracks: [twin(title: "Cafe\u{0301} au Jazz",
                                 location: libraryFile.path, duration: 200.0)])
        XCTAssertEqual(survey.matchKind, .verifiedExisting,
                       "NFC and NFD renderings of the same text are the same title")
    }

    func test_adversarial_caseAndWhitespaceDifferences_requireReview() throws {
        // Exact equality means exact: no case folding, no trimming.
        let candidate = try makeRealFLAC(name: "case.flac")
        let libraryFile = try makeBytes(name: "library.m4a", [9, 9])
        let hash = LocalImportEngine.sha256Hex(fileURL: candidate)!
        for variant in ["golden hour", " Golden Hour", "Golden Hour "] {
            let survey = MusicImportEngine.classify(
                filePath: candidate.path, candidateHash: hash,
                candidateTags: tags(title: "Golden Hour"),
                candidateDurationSeconds: 200.0,
                libraryTracks: [twin(title: variant, location: libraryFile.path,
                                     duration: 200.0)])
            XCTAssertEqual(survey.matchKind, .needsReview,
                           "title variant '\(variant.debugDescription)' must not verify")
        }
    }

    func test_adversarial_emptyStringAxes_presentAndEqual_verify() throws {
        // Boundary pin: an axis that is present-but-empty ("") satisfies
        // the present-AND-equal rule when both sides are empty strings.
        // loadTags drops empty albumArtist values but the commonKey path
        // keeps empty title/artist/album, so an explicitly-empty tag on
        // a real file can reach this boundary. Documented behavior; if
        // empty should count as absent, that is a classifier change with
        // its own RED test on this pin.
        let candidate = try makeBytes(name: "empty.m4a", [1, 1])
        let libraryFile = try makeBytes(name: "library.m4a", [9, 9])
        let hash = LocalImportEngine.sha256Hex(fileURL: candidate)!
        let survey = MusicImportEngine.classify(
            filePath: candidate.path, candidateHash: hash,
            candidateTags: tags(title: "", artist: "", album: "",
                                albumArtist: "", disc: 1, track: 7),
            candidateDurationSeconds: 200.0,
            libraryTracks: [twin(title: "", artist: "", album: "", albumArtist: "",
                                 location: libraryFile.path, duration: 200.0)])
        XCTAssertEqual(survey.matchKind, .verifiedExisting,
                       "empty-but-present axes are equal by the current rule")
    }

    func test_adversarial_duplicateTwinEntries_firstWinsDeterministically() throws {
        // The same twin listed twice: the first is returned, always.
        let candidate = try makeRealFLAC(name: "dupe.flac")
        let libraryFile = try makeBytes(name: "library.m4a", [9, 9])
        let hash = LocalImportEngine.sha256Hex(fileURL: candidate)!
        for _ in 0..<10 {
            let survey = MusicImportEngine.classify(
                filePath: candidate.path, candidateHash: hash,
                candidateTags: tags(), candidateDurationSeconds: 200.0,
                libraryTracks: [twin(id: "FIRST", location: libraryFile.path),
                               twin(id: "SECOND", location: libraryFile.path)])
            XCTAssertEqual(survey.matchKind, .verifiedExisting)
            XCTAssertEqual(survey.duplicate?.persistentID, "FIRST")
        }
    }

    func test_adversarial_streamingTrackAlongsideVerifiedTwin_skipsWithEmptyCandidates() throws {
        // A streaming (no-file) track cannot be byte-compared and would
        // go to review — but an early verifiedExisting return drops it
        // from the candidates list. The skip is still safe (never a
        // duplicate import); the evidence narrowing is pinned.
        let candidate = try makeRealFLAC(name: "stream.flac")
        let libraryFile = try makeBytes(name: "library.m4a", [9, 9])
        let hash = LocalImportEngine.sha256Hex(fileURL: candidate)!
        let streaming = MusicTrackRef(persistentID: "STREAM", name: "Golden Hour",
                                      durationSeconds: 200.0)
        let survey = MusicImportEngine.classify(
            filePath: candidate.path, candidateHash: hash,
            candidateTags: tags(), candidateDurationSeconds: 200.0,
            libraryTracks: [streaming,
                            twin(id: "TWIN", location: libraryFile.path, duration: 200.0)])
        XCTAssertEqual(survey.matchKind, .verifiedExisting)
        XCTAssertTrue(survey.candidates.isEmpty,
                      "early verified return narrows evidence to the proven twin")
    }

    func test_adversarial_reviewCandidates_preserveLibraryOrder() throws {
        // Multiple unprovable candidates: review keeps them all, in
        // deterministic library order.
        let candidate = try makeRealFLAC(name: "multi.flac", album: "Different Album")
        let fileA = try makeBytes(name: "a.m4a", [1])
        let fileB = try makeBytes(name: "b.m4a", [2])
        let hash = LocalImportEngine.sha256Hex(fileURL: candidate)!
        let survey = MusicImportEngine.classify(
            filePath: candidate.path, candidateHash: hash,
            candidateTags: tags(album: "Different Album"),
            candidateDurationSeconds: 200.0,
            libraryTracks: [twin(id: "A", location: fileA.path),
                            twin(id: "B", location: fileB.path)])
        XCTAssertEqual(survey.matchKind, .needsReview)
        XCTAssertEqual(survey.candidates.map(\.persistentID), ["A", "B"])
    }

    func test_sameRecording_directUnit_guards() throws {
        // The six-axis rule's own guards: absent tags, absent candidate
        // duration, absent library duration — all unprovable.
        let libraryFile = try makeBytes(name: "library.m4a", [9, 9])
        let track = twin(location: libraryFile.path, duration: 200.0)
        XCTAssertFalse(MusicImportEngine.sameRecording(candidateTags: nil,
                                                       candidateDurationSeconds: 200.0,
                                                       libraryTrack: track))
        XCTAssertFalse(MusicImportEngine.sameRecording(candidateTags: tags(),
                                                      candidateDurationSeconds: nil,
                                                      libraryTrack: track))
        XCTAssertFalse(MusicImportEngine.sameRecording(candidateTags: tags(),
                                                       candidateDurationSeconds: 200.0,
                                                       libraryTrack: twin(location: libraryFile.path,
                                                                          duration: nil)))
    }

    // MARK: - E. Integration: surveyFile / importFile with mocked Music.app

    func test_integration_surveyFile_realFLAC_verifiedExistingEndToEnd() async throws {
        // Full read-only pipeline on a REAL FLAC: self-load tags, derive
        // the query from the TAG TITLE (not the filename), search the
        // mocked library, verify the twin, and report the skip.
        let candidate = try makeRealFLAC(name: "survey.flac")
        let libraryFile = try makeBytes(name: "library.m4a", [9, 9, 9])
        let fake = PreflightScriptingFake(library: [
            twin(id: "SURV1", location: libraryFile.path, duration: 3.0)
        ])
        let engine = MusicImportEngine(scripting: fake)
        let survey = await engine.surveyFile(file: candidate)

        XCTAssertNotNil(survey)
        XCTAssertEqual(survey?.matchKind, .verifiedExisting)
        XCTAssertEqual(fake.searchQueries.first, "Golden Hour",
                       "the query must come from the tag title, not the filename")
        XCTAssertEqual(survey?.duplicate?.persistentID, "SURV1")
        XCTAssertEqual(fake.addCalls.count, 0, "surveyFile is read-only")
    }

    func test_integration_importFile_realFLAC_verifiedSkip_noWriteNoJournal() async throws {
        // The verified-existing skip through the write path: Music is
        // never written AND the append-only journal records nothing
        // (skips are pure reads; only attempts and their resolutions
        // are journal evidence).
        let candidate = try makeRealFLAC(name: "import.flac")
        let libraryFile = try makeBytes(name: "library.m4a", [9, 9])
        let fake = PreflightScriptingFake(library: [
            twin(id: "IMP1", location: libraryFile.path, duration: 3.0)
        ])
        let engine = MusicImportEngine(scripting: fake)
        let journal = MusicImportJournal(directory: work)

        let outcome = await engine.importFile(file: candidate,
                                              titleQuery: "import",
                                              journal: journal,
                                              priorRecords: [])
        XCTAssertEqual(outcome.status, .skippedDuplicate)
        XCTAssertEqual(outcome.decision, .skipVerifiedExisting)
        XCTAssertEqual(outcome.persistentID, "IMP1")
        XCTAssertEqual(fake.addCalls.count, 0, "verified skip must never write to Music")
        let (records, _) = try journal.load()
        XCTAssertTrue(records.isEmpty, "a skip must not fabricate journal evidence")
    }

    func test_integration_importFile_liveVersion_reviewThenExplicitResolutionImports() async throws {
        // Non-conflation end-to-end: a live version (identical tags to a
        // studio-length twin) is NOT auto-skipped — it reviews; only an
        // EXPLICIT user resolution imports it as its own recording.
        let candidate = try makeRealFLAC(name: "live.flac",
                                         title: "Golden Hour (Live)",
                                         album: "Live in Paris",
                                         duration: 6)
        let studioFile = try makeBytes(name: "studio.m4a", [9, 9])
        let fake = PreflightScriptingFake(library: [
            twin(id: "LIVE1", title: "Golden Hour (Live)", album: "Live in Paris",
                 location: studioFile.path, duration: 3.0)
        ])
        let engine = MusicImportEngine(scripting: fake)
        let journal = MusicImportJournal(directory: work)

        let review = await engine.importFile(file: candidate,
                                             titleQuery: "live",
                                             journal: journal,
                                             priorRecords: [])
        XCTAssertEqual(review.status, .review, "a live version must never be auto-skipped or auto-imported")
        XCTAssertEqual(review.decision, .reviewRequired)
        XCTAssertEqual(review.reviewCandidates.first?.persistentID, "LIVE1",
                       "review carries the conflicting studio twin as evidence")
        XCTAssertEqual(fake.addCalls.count, 0)
        let (midRecords, _) = try journal.load()
        XCTAssertTrue(midRecords.isEmpty, "an unresolved review writes nothing")

        // Explicit resolution imports the live version as its own track.
        let resolved = await engine.importFile(file: candidate,
                                              titleQuery: "live",
                                              journal: journal,
                                              priorRecords: [],
                                              reviewResolved: true)
        XCTAssertEqual(resolved.status, .imported,
                       "after explicit resolution the live version imports as its own recording")
        XCTAssertEqual(fake.addCalls.count, 1)
        let (records, _) = try journal.load()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].state, .attempted)
        XCTAssertEqual(records[1].state, .verified)
    }

    func test_integration_importFile_cleanLibrary_importsAndJournals() async throws {
        // 'Verified missing' end-to-end on a REAL FLAC: empty mocked
        // library -> import proceeds, journal records intent before the
        // write, then verification.
        let candidate = try makeRealFLAC(name: "fresh.flac")
        let fake = PreflightScriptingFake()
        let engine = MusicImportEngine(scripting: fake)
        let journal = MusicImportJournal(directory: work)

        let outcome = await engine.importFile(file: candidate,
                                              titleQuery: "fresh",
                                              journal: journal,
                                              priorRecords: [])
        XCTAssertEqual(outcome.status, .imported)
        XCTAssertEqual(outcome.persistentID, "ADDED-PF")
        XCTAssertEqual(fake.addCalls.count, 1)
        let (records, _) = try journal.load()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].state, .attempted, "intent recorded BEFORE the write")
        XCTAssertEqual(records[1].state, .verified)
    }

    func test_integration_surveyFile_taglessFallsBackToFilenameQuery() async throws {
        // A tagless candidate derives its query from the FILENAME — and
        // even when a same-named track exists, nil tags keep the
        // classification in review (never verified, never auto-import).
        let candidate = try makeRealFLAC(name: "unified.flac",
                                         title: nil, artist: nil, album: nil,
                                         albumArtist: nil, disc: nil, track: nil)
        let libraryFile = try makeBytes(name: "library.m4a", [9, 9])
        let fake = PreflightScriptingFake(library: [
            twin(id: "NAME1", title: "unified", location: libraryFile.path, duration: 3.0)
        ])
        let engine = MusicImportEngine(scripting: fake)
        let survey = await engine.surveyFile(file: candidate)

        XCTAssertEqual(fake.searchQueries.first, "unified",
                       "tagless candidates fall back to the filename-derived query")
        XCTAssertEqual(survey?.matchKind, .needsReview,
                       "a found same-named track with unprovable tags reviews")
        XCTAssertEqual(MusicImportEngine.decision(for: survey!), .reviewRequired)
    }
}

// MARK: - Mocked Music.app scripting surface

/// Minimal deterministic Music.app fake for the preflight suite. Own
/// copy (private to this file) so this suite never collides with the
/// parent's test file — a board hotspot. Search is exact-name match,
/// mirroring the sdef `search` contains-behavior conservatively; `add`
/// records the call and simulates a successful import.
private final class PreflightScriptingFake: MusicScripting, @unchecked Sendable {
    struct AddCall { let file: URL }

    private var library: [MusicTrackRef]
    private var addedLocations: Set<String> = []
    private(set) var addCalls: [AddCall] = []
    private(set) var searchQueries: [String] = []
    private let lock = NSLock()

    init(library: [MusicTrackRef] = []) {
        self.library = library
    }

    func musicVersion() async -> String? { "1.7.0" }
    func libraryTrackCount() async -> Int? { lock.withLock { library.count } }

    func searchLibrary(query: String) async -> [MusicTrackRef]? {
        lock.withLock {
            searchQueries.append(query)
            var matches = library.filter { $0.name == query }
            matches = matches.filter { !(addedLocations.contains($0.locationPath ?? "")) }
            return matches
        }
    }

    func track(withPersistentID id: String) async -> MusicTrackRef? {
        lock.withLock { library.first { $0.persistentID == id } }
    }

    func add(file: URL) async -> String? {
        lock.withLock {
            addCalls.append(AddCall(file: file))
            addedLocations.insert(file.path)
            library.append(MusicTrackRef(persistentID: "ADDED-PF",
                                         name: file.deletingPathExtension().lastPathComponent,
                                         locationPath: file.path,
                                         durationSeconds: 3.0))
            return "ADDED-PF"
        }
    }
}
