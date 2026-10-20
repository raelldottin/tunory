import XCTest
import AVFoundation
@testable import TunoryCore

// Local-import engine tests. Fixtures are generated INTO TEST-OWNED TEMP
// DIRS at test time (research acceptance contract t_dc244b34 §8): never
// the real library, never committed binaries.
//
// ffmpeg's ONLY role is fixture generation (making synthetic FLAC/WAV/
// MP3 inputs). The engine under test is fully in-process AVFoundation /
// Core Audio (owner decision D1); no test exercises an external
// converter. When ffmpeg is absent, fixture-dependent tests skip
// VISIBLY (XCTSkip appears in the report, not a silent pass); every
// decision-theory test runs on hand-built inputs without ffmpeg.
//
// Per D1 acceptance, conversion tests must pass with ffmpeg completely
// absent from the engine — which is now structural (the engine has no
// code path that could exec it).

final class LocalImportEngineTests: XCTestCase {

    var work: URL!
    var ffmpegURL: URL?

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunory-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        ffmpegURL = LocalImportEngineTests.locateFFmpeg()
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

    /// Generate a FLAC fixture via ffmpeg lavfi (sine tone). ffmpeg is
    /// fixture tooling only; the engine never invokes it.
    func makeFLAC(name: String = "tone.flac", metadata: Bool = true) throws -> URL {
        guard let ffmpeg = ffmpegURL else { throw XCTSkip("ffmpeg not installed (fixture generation only)") }
        let out = work.appendingPathComponent(name)
        var args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-f", "lavfi",
                    "-i", "sine=frequency=440:duration=3"]
        if metadata {
            args += ["-metadata", "title=Test Tone", "-metadata", "artist=Tunory Tests"]
        }
        // Force the FLAC container explicitly. Without -f, ffmpeg selects its
        // output muxer from the file extension; a fixture deliberately named
        // *.mp3 (the mislabeled-extension test) then picks the MP3 muxer and
        // fails with "Exactly one MP3 audio stream is required" (captured,
        // ffmpeg 6.x), leaving a 0-byte file. The point of the fixture is a
        // FLAC payload in a mislabeled container, so the format must be
        // forced, not inferred.
        args += ["-f", "flac", "-c:a", "flac", out.path]
        try runProcess(ffmpeg, args)
        return out
    }

    func makeCorruptFile(_ url: URL) throws {
        try Data("this is not audio at all".utf8).write(to: url)
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

    // MARK: - Prober (requirement 2: content over extension)

    func testProbeIdentifiesCodecFromContent() async throws {
        // A FLAC file mislabeled as .mp3 must probe as flac: the probe
        // reads content, never the extension.
        let flac = try makeFLAC(name: "mislabeled.mp3")
        let probe = await AudioProber().probe(url: flac)
        XCTAssertEqual(probe.codec, "flac", "mislabeled extension must not fool the probe")
        XCTAssertEqual(probe.lossless, .yes)
        XCTAssertTrue(probe.musicImportable)
        XCTAssertEqual(probe.sampleRate, 44100)
    }

    func testProbeRejectsUndecodableContent() async throws {
        let corrupt = work.appendingPathComponent("corrupt.flac")
        try makeCorruptFile(corrupt)
        let probe = await AudioProber().probe(url: corrupt)
        XCTAssertNil(probe.codec)
        XCTAssertFalse(probe.musicImportable)
        XCTAssertNotNil(probe.failureDetail)
    }

    func testProbeWAVAndMP3Classification() async throws {
        guard let ffmpeg = ffmpegURL else { throw XCTSkip("ffmpeg not installed (fixture generation only)") }
        let wav = work.appendingPathComponent("tone.wav")
        try runProcess(ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error",
                                "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                                "-c:a", "pcm_s16le", wav.path])
        let probe = await AudioProber().probe(url: wav)
        XCTAssertEqual(probe.codec, "lpcm")
        XCTAssertEqual(probe.bitDepth, 16)
        XCTAssertEqual(probe.lossless, .yes)
        XCTAssertTrue(probe.musicImportable)
    }

    // MARK: - GAP C item 3: standalone tags loader (six axes)

    func testLoadTagsSixAxesFromVorbisComments() async throws {
        // Full vorbis axis set the classifier compares, incl. the three
        // GAP B extended fields (ALBUMARTIST/DISCNUMBER/TRACKNUMBER).
        guard let ffmpeg = ffmpegURL else { throw XCTSkip("ffmpeg not installed (fixture generation only)") }
        let flac = work.appendingPathComponent("tagged.flac")
        try runProcess(ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error",
                                "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                                "-f", "flac", "-c:a", "flac",
                                "-metadata", "title=Golden Hour",
                                "-metadata", "artist=Artist",
                                "-metadata", "album=Album",
                                "-metadata", "ALBUMARTIST=Album Artist",
                                "-metadata", "DISCNUMBER=2",
                                "-metadata", "TRACKNUMBER=7/12",
                                flac.path])
        let tags = await AudioProber().loadTags(url: flac)
        XCTAssertNotNil(tags)
        XCTAssertEqual(tags?.title, "Golden Hour")
        XCTAssertEqual(tags?.artist, "Artist")
        XCTAssertEqual(tags?.album, "Album")
        XCTAssertEqual(tags?.albumArtist, "Album Artist")
        XCTAssertEqual(tags?.discNumber, 2, "vorbis DISCNUMBER must parse via the GAP B mapping")
        XCTAssertEqual(tags?.trackNumber, 7, "vorbis 'n/total' TRACKNUMBER must yield the number")
    }

    func testLoadTagsReusesID3Mapping() async throws {
        // The GAP B source-identifier table is the single mapping: id3
        // TPE2/TPOS/TRCK must reach the loader exactly like vorbis.
        guard let ffmpeg = ffmpegURL else { throw XCTSkip("ffmpeg not installed (fixture generation only)") }
        let mp3 = work.appendingPathComponent("id3tagged.mp3")
        try runProcess(ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error",
                                "-f", "lavfi", "-i", "sine=frequency=550:duration=3",
                                "-c:a", "libmp3lame", "-b:a", "128k", "-id3v2_version", "3",
                                "-metadata", "title=ID3 Tone",
                                "-metadata", "TPE2=ID3 Album Artist",
                                "-metadata", "TPOS=2/2", "-metadata", "TRCK=7/12",
                                mp3.path])
        let tags = await AudioProber().loadTags(url: mp3)
        XCTAssertNotNil(tags)
        XCTAssertEqual(tags?.title, "ID3 Tone")
        XCTAssertEqual(tags?.albumArtist, "ID3 Album Artist")
        XCTAssertEqual(tags?.discNumber, 2)
        XCTAssertEqual(tags?.trackNumber, 7)
    }

    func testLoadTagsTaglessFileYieldsAllNilAxes() async throws {
        let bare = try makeFLAC(name: "bare.flac", metadata: false)
        let tags = await AudioProber().loadTags(url: bare)
        XCTAssertEqual(tags, AudioMetadataTags(title: nil, artist: nil, album: nil,
                                               albumArtist: nil, discNumber: nil,
                                               trackNumber: nil),
                       "a tagless file must load all-nil axes, never guessed values")
    }

    func testLoadTagsCorruptFileIsFailVisible() async throws {
        let corrupt = work.appendingPathComponent("corrupt-tags.flac")
        try makeCorruptFile(corrupt)
        let tags = await AudioProber().loadTags(url: corrupt)
        // Fail-visible: either the survey fails outright (nil) or every
        // axis is nil. Never invented values.
        if let tags {
            XCTAssertEqual(tags, AudioMetadataTags(title: nil, artist: nil, album: nil,
                                                  albumArtist: nil, discNumber: nil,
                                                  trackNumber: nil))
        }
    }

    func testLoadTagsGarbagePositionalTagsStayNil() async throws {
        // "handle various FLAC tag formats gracefully": unparseable
        // positional values must be skipped, never guessed.
        guard let ffmpeg = ffmpegURL else { throw XCTSkip("ffmpeg not installed (fixture generation only)") }
        let flac = work.appendingPathComponent("garbage.flac")
        try runProcess(ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error",
                                "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                                "-f", "flac", "-c:a", "flac",
                                "-metadata", "title=Garbage",
                                "-metadata", "TRACKNUMBER=not-a-number",
                                "-metadata", "DISCNUMBER=-1",
                                flac.path])
        let tags = await AudioProber().loadTags(url: flac)
        XCTAssertEqual(tags?.title, "Garbage")
        XCTAssertNil(tags?.trackNumber, "unparseable TRACKNUMBER must stay nil")
        XCTAssertNil(tags?.discNumber, "negative DISCNUMBER must stay nil")
    }

    // MARK: - Planning (deterministic decisions)

    func testPlanPassthroughForLossySources() async throws {
        let engine = LocalImportEngine()
        let flac = try makeFLAC()
        // Lossy source: create an mp3 by converting the flac.
        guard let ffmpeg = ffmpegURL else { throw XCTSkip("ffmpeg not installed (fixture generation only)") }
        let mp3 = work.appendingPathComponent("tone.mp3")
        try runProcess(ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error",
                                "-i", flac.path, "-c:a", "libmp3lame", "-b:a", "128k", mp3.path])
        let plan = await engine.planBatch(sourceRoot: work, outputRoot: work.appendingPathComponent("out"),
                                            profile: .aac256, journalRecords: [])
        let mp3Entry = plan.entries.first { $0.sourcePath.hasSuffix("tone.mp3") }
        XCTAssertEqual(mp3Entry?.decision, .passthroughNative,
                       "lossy→lossy transcode is forbidden by the owner contract")
        let flacEntry = plan.entries.first { $0.sourcePath.hasSuffix("tone.flac") }
        XCTAssertEqual(flacEntry?.decision, .convert)
    }

    func testPlanBlocksALACProfileOnLossySource() async throws {
        guard let ffmpeg = ffmpegURL else { throw XCTSkip("ffmpeg not installed (fixture generation only)") }
        let mp3 = work.appendingPathComponent("tone.mp3")
        try runProcess(ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error",
                                "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                                "-c:a", "libmp3lame", "-b:a", "128k", mp3.path])
        let engine = LocalImportEngine()
        let plan = await engine.planBatch(sourceRoot: work, outputRoot: work.appendingPathComponent("out"),
                                            profile: .alac, journalRecords: [])
        XCTAssertEqual(plan.entries.first?.decision, .blockedByProfile)
    }

    func testPlanPreservesRelativeStructure() async throws {
        let nested = work.appendingPathComponent("Artist/Album1", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try makeFLAC(name: "Artist/Album1/reftrack.flac")
        let engine = LocalImportEngine()
        let out = work.appendingPathComponent("out")
        let plan = await engine.planBatch(sourceRoot: work, outputRoot: out,
                                            profile: .aac256, journalRecords: [])
        XCTAssertEqual(plan.entries.count, 1)
        XCTAssertTrue(plan.entries[0].destinationPath.hasSuffix("out/Artist/Album1/reftrack.m4a"),
                      "relative directory structure must be preserved")
    }

    func testPlanClassifiesExactByteDuplicates() async throws {
        let a = try makeFLAC(name: "dup-a.flac")
        let b = work.appendingPathComponent("dup-b.flac")
        try FileManager.default.copyItem(at: a, to: b)
        let engine = LocalImportEngine()
        let plan = await engine.planBatch(sourceRoot: work, outputRoot: work.appendingPathComponent("out"),
                                            profile: .aac256, journalRecords: [])
        // Files are walked sorted: dup-a before dup-b.
        let dupB = plan.entries.first { $0.sourcePath.hasSuffix("dup-b.flac") }
        XCTAssertNotNil(dupB?.duplicateOfIndex, "identical bytes must be classified duplicate")
        let dupA = plan.entries.first { $0.sourcePath.hasSuffix("dup-a.flac") }
        XCTAssertNil(dupA?.duplicateOfIndex)
    }

    /// Regression (observed live, 2026-10-14 e2e): a read-denied file must
    /// NOT hash to the empty-data digest. Before the fix, two distinct
    /// unreadable files (a FLAC and an MP3, both sandbox read-denied)
    /// hashed identically to e3b0c442… (SHA-256 of empty input) and the
    /// second was wrongly classified as a byte-duplicate of the first.
    func testUnreadableFileHasNoSHA256AndIsNotDuplicate() async throws {
        // A "file" the stream layer cannot read bytes from: a directory
        // at an audio-extension path.
        let dir = work.appendingPathComponent("not-a-file.flac")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dir2 = work.appendingPathComponent("also-not-a-file.mp3")
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)

        XCTAssertNil(LocalImportEngine.sha256Hex(fileURL: dir),
                      "unreadable input must yield nil, never the empty-data digest e3b0c442…")
        XCTAssertNil(LocalImportEngine.sha256Hex(fileURL: dir2))

        // Two different unreadable inputs must not be classified as
        // byte-duplicates of each other. (planFiles, not planBatch: the
        // batch walk pre-filters non-regular files, but the CLI's
        // explicit-file path does not — that's where the live defect
        // occurred.)
        let engine = LocalImportEngine()
        let plan = await engine.planFiles(files: [dir, dir2],
                                          outputDirectory: work.appendingPathComponent("out"),
                                          profile: .aac256,
                                          journalRecords: [])
        guard plan.entries.count == 2 else { return XCTFail("expected 2 entries, got \(plan.entries.count)") }
        XCTAssertNil(plan.entries[0].duplicateOfIndex)
        XCTAssertNil(plan.entries[1].duplicateOfIndex,
                     "two read-denied files must never be byte-duplicates of each other")
        XCTAssertNil(plan.entries[0].sourceSHA256)
        XCTAssertNil(plan.entries[1].sourceSHA256)
    }

    // MARK: - Multi-root folder planning (GAP A, phase 11)

    /// Minimal valid mono 16-bit PCM WAV (~1 s), hand-built so folder
    /// planning tests never depend on ffmpeg. WAV is lossless (lpcm),
    /// so it plans as `.convert` under the AAC-256 reference profile.
    static func makeWAVFixture(at url: URL, frequency: Double = 440) throws {
        let sampleRate = 44_100.0
        let frames = Int(sampleRate)
        var samples = [Int16](repeating: 0, count: frames)
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            samples[i] = Int16((sin(2 * .pi * frequency * t) * 0.4) * Double(Int16.max))
        }
        var data = Data()
        func append(_ s: String) { data.append(s.data(using: .ascii)!) }
        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        append("RIFF"); append32(UInt32(36 + frames * 2)); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)
        append32(UInt32(sampleRate)); append32(UInt32(sampleRate * 2)); append16(2); append16(16)
        append("data"); append32(UInt32(frames * 2))
        for s in samples { append16(UInt16(bitPattern: s)) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// A single selected folder must plan exactly like the CLI batch
    /// walk — the GUI folder picker is a new presentation of the SAME
    /// canonical plan, never a second decision path.
    func testPlanBatchesSingleRootEqualsPlanBatch() async throws {
        let album = work.appendingPathComponent("AlbumA", isDirectory: true)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        try Self.makeWAVFixture(at: album.appendingPathComponent("01 Track.wav"))
        let engine = LocalImportEngine()
        let out = work.appendingPathComponent("out")
        let batch = await engine.planBatch(sourceRoot: album, outputRoot: out,
                                           profile: .aac256, journalRecords: [])
        let batches = await engine.planBatches(sourceRoots: [album], outputRoot: out,
                                               profile: .aac256, journalRecords: [])
        XCTAssertEqual(batch.entries, batches.entries,
                       "single-root planBatches must equal planBatch entry for entry")
    }

    /// Multiple selected album folders: each root's entries carry the
    /// album folder name as prefix, so same-named tracks in different
    /// albums plan to distinct per-album destinations (no collision).
    func testPlanBatchesMultipleRootsPreservePerAlbumStructure() async throws {
        for album in ["AlbumA", "AlbumB"] {
            let dir = work.appendingPathComponent(album, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Self.makeWAVFixture(at: dir.appendingPathComponent("01 Track.wav"))
        }
        let engine = LocalImportEngine()
        let out = work.appendingPathComponent("out")
        let plan = await engine.planBatches(
            sourceRoots: [work.appendingPathComponent("AlbumA"),
                          work.appendingPathComponent("AlbumB")],
            outputRoot: out, profile: .aac256, journalRecords: [])
        XCTAssertEqual(plan.entries.count, 2)
        XCTAssertEqual(plan.entries.map(\.relativePath).sorted(),
                       ["AlbumA/01 Track.wav", "AlbumB/01 Track.wav"],
                       "each root's entries must be prefixed with the album folder name")
        XCTAssertEqual(plan.entries.map(\.destinationPath).sorted(),
                       [out.appendingPathComponent("AlbumA/01 Track.m4a").path,
                        out.appendingPathComponent("AlbumB/01 Track.m4a").path].sorted(),
                       "same-named tracks in different albums must not collide at the destination")
        for entry in plan.entries {
            XCTAssertEqual(entry.decision, .convert,
                           "valid lossless WAVs must plan as convert under AAC-256")
        }
    }

    /// Requirement 1's two selection modes must be equivalent: selecting
    /// the parent folder or selecting the album folders directly
    /// produces the same plan for the same collection.
    func testPlanBatchesParentSelectionMatchesAlbumsSelection() async throws {
        for album in ["AlbumA", "AlbumB"] {
            let dir = work.appendingPathComponent(album, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Self.makeWAVFixture(at: dir.appendingPathComponent("01 Track.wav"))
        }
        let engine = LocalImportEngine()
        let out = work.appendingPathComponent("out")
        let parentPlan = await engine.planBatches(sourceRoots: [work], outputRoot: out,
                                                  profile: .aac256, journalRecords: [])
        let albumsPlan = await engine.planBatches(
            sourceRoots: [work.appendingPathComponent("AlbumA"),
                          work.appendingPathComponent("AlbumB")],
            outputRoot: out, profile: .aac256, journalRecords: [])
        XCTAssertEqual(parentPlan.entries, albumsPlan.entries,
                       "parent-folder and album-folder selection must produce identical plans")
    }

    /// Byte-identical recordings in two different selected folders must
    /// still be flagged as batch duplicates for explicit review.
    func testPlanBatchesFlagsByteDuplicatesAcrossFolders() async throws {
        let a = work.appendingPathComponent("AlbumA", isDirectory: true)
        let b = work.appendingPathComponent("AlbumB", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try Self.makeWAVFixture(at: a.appendingPathComponent("shared.wav"))
        try FileManager.default.copyItem(at: a.appendingPathComponent("shared.wav"),
                                         to: b.appendingPathComponent("same-bytes.wav"))
        let engine = LocalImportEngine()
        let plan = await engine.planBatches(sourceRoots: [a, b],
                                            outputRoot: work.appendingPathComponent("out"),
                                            profile: .aac256, journalRecords: [])
        XCTAssertEqual(plan.entries.count, 2)
        let first = plan.entries.first { $0.sourcePath.hasSuffix("shared.wav") }!
        let second = plan.entries.first { $0.sourcePath.hasSuffix("same-bytes.wav") }!
        XCTAssertNil(first.duplicateOfIndex)
        XCTAssertNotNil(second.duplicateOfIndex,
                        "byte-identical recordings across two selected folders must be flagged for review")
    }

    /// The same folder handed twice (panel quirk) must plan once —
    /// deterministic, no double walk.
    func testPlanBatchesPlansIdenticalRootOnce() async throws {
        let album = work.appendingPathComponent("AlbumA", isDirectory: true)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        try Self.makeWAVFixture(at: album.appendingPathComponent("01 Track.wav"))
        let engine = LocalImportEngine()
        let plan = await engine.planBatches(sourceRoots: [album, album],
                                            outputRoot: work.appendingPathComponent("out"),
                                            profile: .aac256, journalRecords: [])
        XCTAssertEqual(plan.entries.count, 1,
                       "an identical root handed twice must plan exactly once")
    }

    /// Adversarial edge: two DIFFERENT roots that share a folder name
    /// ("Greatest Hits" from two parents) prefix to the same relative
    /// paths, so their destinations collide. Planning must stay
    /// deterministic and honest: both entries present, both `.convert`
    /// (a plan never writes); the promote-time destination guard owns
    /// the actual collision — a foreign file is never overwritten.
    func testPlanBatchesSameNamedRootsCollideDeterministically() async throws {
        let parent1 = work.appendingPathComponent("col1", isDirectory: true)
        let parent2 = work.appendingPathComponent("col2", isDirectory: true)
        let r1 = parent1.appendingPathComponent("Greatest", isDirectory: true)
        let r2 = parent2.appendingPathComponent("Greatest", isDirectory: true)
        try FileManager.default.createDirectory(at: r1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: r2, withIntermediateDirectories: true)
        try Self.makeWAVFixture(at: r1.appendingPathComponent("01.wav"), frequency: 440)
        try Self.makeWAVFixture(at: r2.appendingPathComponent("01.wav"), frequency: 660)
        let engine = LocalImportEngine()
        let plan = await engine.planBatches(sourceRoots: [r1, r2],
                                            outputRoot: work.appendingPathComponent("out"),
                                            profile: .aac256, journalRecords: [])
        XCTAssertEqual(plan.entries.count, 2)
        XCTAssertEqual(Set(plan.entries.map(\.destinationPath)).count, 1,
                       "same-named roots document a real destination edge: identical planned paths")
        XCTAssertEqual(plan.entries.map(\.sourcePath),
                       plan.entries.map(\.sourcePath).sorted(),
                       "entries stay deterministically ordered")
        for entry in plan.entries {
            XCTAssertEqual(entry.decision, .convert,
                           "planning never writes; the promote-time guard owns the collision")
        }
    }

    // MARK: - Phase 11 t_72d1c24a: multi-root nested FLAC selection

    /// The four-album selection shape in one canonical proof (card
    /// t_72d1c24a): MULTIPLE selected album folders — exactly what the
    /// GUI folder picker hands `select(folders:)` → `planBatches` — each
    /// containing NESTED disc subfolders (CD1/CD2), holding real FLAC
    /// with the full metadata set (album title, album artist, track
    /// artist, song title, disc number, track number) plus embedded
    /// PICTURE artwork. Recursive discovery must find every file
    /// through both roots, relative paths must preserve album + disc
    /// structure, conversion must create the nested destination
    /// layout and carry ALL six axes + artwork onto the outputs, and
    /// the original FLAC files must stay byte-identical.
    func testMultiRootNestedFLACDiscoveryPreservesAllMetadata() async throws {
        guard let ffmpeg = ffmpegURL else { throw XCTSkip("ffmpeg not installed (fixture generation only)") }

        // Fixture descriptor: one row per FLAC track under a selected root.
        struct NestedTrack {
            let rootName: String
            let dir: URL
            let name: String
            let title: String
            let track: Int
            let disc: Int
            let album: String
            let band: String
            var relativePath: String { rootName + "/" + dir.lastPathComponent + "/" + name }
        }

        // Two selected album folders, each with nested disc subfolders:
        // a flat walk would find none of these files.
        let alpha = work.appendingPathComponent("AlbumAlpha", isDirectory: true)
        let beta = work.appendingPathComponent("AlbumBeta", isDirectory: true)
        let alphaCD1 = alpha.appendingPathComponent("CD1", isDirectory: true)
        let alphaCD2 = alpha.appendingPathComponent("CD2", isDirectory: true)
        let betaCD1 = beta.appendingPathComponent("CD1", isDirectory: true)
        for dir in [alphaCD1, alphaCD2, betaCD1] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let png = try Self.makeTinyPNG(in: work)
        let tracks: [NestedTrack] = [
            NestedTrack(rootName: "AlbumAlpha", dir: alphaCD1, name: "01 Open Tone.flac",
                        title: "Open Tone", track: 1, disc: 1, album: "Alpha Album", band: "Alpha Band"),
            NestedTrack(rootName: "AlbumAlpha", dir: alphaCD1, name: "02 Second Tone.flac",
                        title: "Second Tone", track: 2, disc: 1, album: "Alpha Album", band: "Alpha Band"),
            NestedTrack(rootName: "AlbumAlpha", dir: alphaCD2, name: "01 Late Tone.flac",
                        title: "Late Tone", track: 1, disc: 2, album: "Alpha Album", band: "Alpha Band"),
            NestedTrack(rootName: "AlbumBeta", dir: betaCD1, name: "01 Beta Tone.flac",
                        title: "Beta Tone", track: 1, disc: 1, album: "Beta Album", band: "Beta Band"),
        ]
        var sourceHashes: [String: String?] = [:]
        for t in tracks {
            let out = t.dir.appendingPathComponent(t.name)
            try runProcess(ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error",
                                    "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                                    "-i", png.path,
                                    "-map", "0:a", "-map", "1:v",
                                    "-c:a", "flac", "-c:v", "png",
                                    "-disposition:v", "attached_pic",
                                    "-metadata", "title=\(t.title)",
                                    "-metadata", "artist=Track Artist \(t.track)",
                                    "-metadata", "album=\(t.album)",
                                    "-metadata", "ALBUMARTIST=\(t.band)",
                                    "-metadata", "DISCNUMBER=\(t.disc)",
                                    "-metadata", "TRACKNUMBER=\(t.track)",
                                    "-f", "flac", out.path])
            sourceHashes[t.name] = LocalImportEngine.sha256Hex(fileURL: out)
        }

        let out = work.appendingPathComponent("out")
        let engine = LocalImportEngine()
        let journal = LocalImportJournal(directory: out.appendingPathComponent(".tunory"))
        let plan = await engine.planBatches(sourceRoots: [alpha, beta],
                                            outputRoot: out,
                                            profile: .aac256, journalRecords: [])

        // Recursive discovery through both selected roots: all four
        // tracks found, every relative path carrying album + disc structure.
        XCTAssertEqual(plan.entries.count, 4,
                       "recursive discovery must find every FLAC under both selected folders")
        XCTAssertEqual(plan.entries.map(\.relativePath).sorted(),
                       tracks.map(\.relativePath).sorted(),
                       "multi-root planning must preserve album + nested disc structure in every path")
        for entry in plan.entries {
            XCTAssertEqual(entry.decision, .convert, "valid FLAC must plan as convert")
        }

        for entry in plan.entries {
            let outcome = await engine.convert(entry: entry, profile: .aac256, journal: journal)
            XCTAssertEqual(outcome.status, .converted, outcome.detail ?? "")
        }

        // Per-file: nested destination created, six metadata axes +
        // artwork carried, original untouched.
        for t in tracks {
            let dest = out.appendingPathComponent(t.relativePath)
                .deletingPathExtension().appendingPathExtension("m4a")
            XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path),
                          "conversion must create the nested destination: \(dest.path)")

            let metadata = try await Self.commonMetadata(of: dest)
            XCTAssertEqual(metadata["title"], t.title, "song title must survive")
            XCTAssertEqual(metadata["artist"], "Track Artist \(t.track)", "track artist must survive")
            XCTAssertEqual(metadata["album"], t.album, "album title must survive")

            let dump = try await Self.identifierDump(of: dest)
            XCTAssertEqual(dump["itsk/aART"], t.band, "album artist must survive")
            let trkn = try await Self.positionalAtom(of: dest, identifier: "itsk/trkn")
            XCTAssertEqual(trkn?.number, t.track, "track number must survive")
            let disk = try await Self.positionalAtom(of: dest, identifier: "itsk/disk")
            XCTAssertEqual(disk?.number, t.disc, "disc number must survive")

            let source = t.dir.appendingPathComponent(t.name)
            let pictures = try LocalImportEngine.flacPictures(in: source)
            XCTAssertEqual(pictures.count, 1, "fixture must embed exactly one PICTURE block")
            let artwork = try await Self.artworkData(of: dest)
            XCTAssertEqual(artwork, pictures.first?.data,
                           "embedded FLAC artwork must survive conversion byte-identical")

            XCTAssertEqual(sourceHashes[t.name], LocalImportEngine.sha256Hex(fileURL: source),
                           "original FLAC must never be modified")
        }
    }

    // MARK: - Native conversion (D1 acceptance: in-process, no external binary)

    func testConvertFLACToM4AReferenceProfile() async throws {
        _ = try makeFLAC()
        let outDir = work.appendingPathComponent("out", isDirectory: true)
        let engine = LocalImportEngine()
        let journal = LocalImportJournal(directory: outDir.appendingPathComponent(".tunory"))
        let plan = await engine.planBatch(sourceRoot: work, outputRoot: outDir,
                                            profile: .aac256, journalRecords: [])
        let entry = plan.entries.first { $0.sourcePath.hasSuffix("tone.flac") }
        XCTAssertNotNil(entry)
        let sourceHashBefore = LocalImportEngine.sha256Hex(fileURL: work.appendingPathComponent("tone.flac"))
        let outcome = await engine.convert(entry: entry!, profile: .aac256, journal: journal)
        XCTAssertEqual(outcome.status, .converted, outcome.detail ?? "")

        // §8.1: exists, decodable, codec=aac, m4a container, duration ≤ 1s.
        let dest = URL(fileURLWithPath: entry!.destinationPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        let outProbe = await AudioProber().probe(url: dest)
        XCTAssertEqual(outProbe.codec, "aac")
        XCTAssertEqual(dest.pathExtension, "m4a")
        if let srcDur = entry!.probe.durationSeconds, let outDur = outProbe.durationSeconds {
            XCTAssertLessThanOrEqual(abs(srcDur - outDur), 1.0)
        }

        // §8.4: source immutable.
        XCTAssertEqual(sourceHashBefore, LocalImportEngine.sha256Hex(fileURL: work.appendingPathComponent("tone.flac")),
                       "originals must never be modified")

        // D1: metadata preserved — verified natively via AVFoundation,
        // not with ffprobe (no external tool dependency in acceptance).
        let metadata = try await Self.commonMetadata(of: dest)
        XCTAssertEqual(metadata["title"], "Test Tone", "title metadata must survive conversion")
        XCTAssertEqual(metadata["artist"], "Tunory Tests", "artist metadata must survive conversion")
    }

    func testConvertFLACToALACLossless() async throws {
        _ = try makeFLAC(name: "lossless.flac")
        let outDir = work.appendingPathComponent("out", isDirectory: true)
        let engine = LocalImportEngine()
        let journal = LocalImportJournal(directory: outDir.appendingPathComponent(".tunory"))
        let plan = await engine.planBatch(sourceRoot: work, outputRoot: outDir,
                                            profile: .alac, journalRecords: [])
        let entry = plan.entries.first { $0.sourcePath.hasSuffix("lossless.flac") }!
        XCTAssertEqual(entry.decision, .convert)
        let outcome = await engine.convert(entry: entry, profile: .alac, journal: journal)
        XCTAssertEqual(outcome.status, .converted, outcome.detail ?? "")

        let dest = URL(fileURLWithPath: entry.destinationPath)
        let outProbe = await AudioProber().probe(url: dest)
        XCTAssertEqual(outProbe.codec, "alac", "ALAC profile must produce an ALAC stream")

        // D1: decoded audio fidelity for lossless conversion must be
        // PCM-equivalent to the source: identical frame counts, and
        // Float32 sample values equal to within 1 LSB of 16-bit.
        try await Self.assertPCMEquivalent(source: URL(fileURLWithPath: entry.sourcePath),
                                            converted: dest,
                                            tolerance: 1.0 / 32768.0)
    }

    func testConversionBitrateWithinContract() async throws {
        guard let ffmpeg = ffmpegURL else { throw XCTSkip("ffmpeg not installed (fixture generation only)") }
        // §8.2: on complex content (stereo pink noise) assert ≤ 256k+10%
        // and ≥ 128k; equality is NOT the contract (research §5).
        let noise = work.appendingPathComponent("noise.flac")
        try runProcess(ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error",
                                "-f", "lavfi", "-i", "anoisesrc=color=pink:duration=3:amplitude=0.5",
                                "-ac", "2", "-c:a", "flac", noise.path])
        let outDir = work.appendingPathComponent("out", isDirectory: true)
        let engine = LocalImportEngine()
        let journal = LocalImportJournal(directory: outDir.appendingPathComponent(".tunory"))
        let plan = await engine.planBatch(sourceRoot: work, outputRoot: outDir,
                                            profile: .aac256, journalRecords: [])
        let entry = plan.entries.first { $0.sourcePath.hasSuffix("noise.flac") }
        let outcome = await engine.convert(entry: entry!, profile: .aac256, journal: journal)
        XCTAssertEqual(outcome.status, .converted, outcome.detail ?? "")

        // Bitrate measured natively: payload bytes × 8 ÷ duration.
        let dest = URL(fileURLWithPath: entry!.destinationPath)
        let attributes = try FileManager.default.attributesOfItem(atPath: dest.path)
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let probe = await AudioProber().probe(url: dest)
        let duration = probe.durationSeconds ?? 0
        XCTAssertGreaterThan(duration, 0)
        let bitrate = Double(bytes * 8) / duration
        XCTAssertLessThanOrEqual(bitrate, 256_000 * 1.10, "bitrate must be within target+10%")
        XCTAssertGreaterThanOrEqual(bitrate, 128_000, "hard floor on complex content")
    }

    func testConvertPreservesArtwork() async throws {
        guard let ffmpeg = ffmpegURL else { throw XCTSkip("ffmpeg not installed (fixture generation only)") }
        // FLAC with an embedded PICTURE block (cover art): run 91 probe5
        // proved AVFoundation does NOT expose FLAC pictures as metadata,
        // so the engine must parse the PICTURE block at file level and
        // the artwork must land in the converted m4a.
        let png = try Self.makeTinyPNG(in: work)
        let flac = work.appendingPathComponent("art.flac")
        try runProcess(ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error",
                                "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                                "-i", png.path,
                                "-map", "0:a", "-map", "1:v",
                                "-c:a", "flac", "-c:v", "png",
                                "-disposition:v", "attached_pic",
                                "-metadata", "title=Art Track",
                                "-f", "flac", flac.path])
        // Sanity: the fixture generator must actually have embedded a
        // PICTURE block the parser can find. ffmpeg re-encodes the PNG
        // when embedding it (89 bytes ≠ the 67-byte source), so the
        // artwork contract is: converted output carries the FLAC's
        // embedded PICTURE bytes.
        let pictures = try LocalImportEngine.flacPictures(in: flac)
        XCTAssertEqual(pictures.count, 1, "fixture must carry one FLAC PICTURE block")
        XCTAssertEqual(pictures.first?.mime, "image/png")
        let embeddedArt = pictures.first?.data
        XCTAssertNotNil(embeddedArt)

        let outDir = work.appendingPathComponent("out", isDirectory: true)
        let engine = LocalImportEngine()
        let journal = LocalImportJournal(directory: outDir.appendingPathComponent(".tunory"))
        let plan = await engine.planBatch(sourceRoot: work, outputRoot: outDir,
                                            profile: .aac256, journalRecords: [])
        let entry = plan.entries.first { $0.sourcePath.hasSuffix("art.flac") }!
        let outcome = await engine.convert(entry: entry, profile: .aac256, journal: journal)
        XCTAssertEqual(outcome.status, .converted, outcome.detail ?? "")

        // Artwork and title must be present on the converted output.
        let dest = URL(fileURLWithPath: entry.destinationPath)
        let metadata = try await Self.commonMetadata(of: dest)
        XCTAssertEqual(metadata["title"], "Art Track")
        let artwork = try await Self.artworkData(of: dest)
        XCTAssertNotNil(artwork, "FLAC PICTURE artwork must survive conversion")
        XCTAssertEqual(artwork, embeddedArt,
                       "converted artwork must equal the FLAC's embedded PICTURE bytes")
        if let data = artwork {
            XCTAssertEqual(data.prefix(8), Self.pngMagic, "embedded artwork must be PNG data")
        }
    }

    // MARK: - Extended metadata carry (GAP B, phase 11)

    /// Full identifier dump of a file via AVFoundation (every format,
    /// identifier-qualified). Used by the GAP B roundtrip tests to prove
    /// the extended fields land as the exact iTunes-family atoms.
    static func identifierDump(of url: URL) async throws -> [String: String] {
        let asset = AVURLAsset(url: url)
        var result: [String: String] = [:]
        let formats = try await asset.load(.availableMetadataFormats)
        for format in formats {
            let items = try await asset.loadMetadata(for: format)
            for item in items {
                guard let identifier = item.identifier else { continue }
                if let value = try? await item.load(.stringValue) {
                    result[identifier.rawValue] = value
                }
            }
        }
        return result
    }

    func testConvertFLACCarriesAlbumArtistDiscTrack() async throws {
        guard let ffmpeg = ffmpegURL else { throw XCTSkip("ffmpeg not installed (fixture generation only)") }
        // FLAC with the three GAP B fields (vorbis comments) + base tags.
        let flac = work.appendingPathComponent("extended.flac")
        try runProcess(ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error",
                                "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                                "-c:a", "flac",
                                "-metadata", "title=Ext Tone", "-metadata", "artist=Ext Artist",
                                "-metadata", "album=Ext Album",
                                "-metadata", "ALBUMARTIST=Ext Album Artist",
                                "-metadata", "DISCNUMBER=2", "-metadata", "TRACKNUMBER=7",
                                flac.path])

        let outDir = work.appendingPathComponent("out", isDirectory: true)
        let engine = LocalImportEngine()
        let journal = LocalImportJournal(directory: outDir.appendingPathComponent(".tunory"))
        let plan = await engine.planBatch(sourceRoot: work, outputRoot: outDir,
                                            profile: .aac256, journalRecords: [])
        let entry = plan.entries.first { $0.sourcePath.hasSuffix("extended.flac") }!
        let outcome = await engine.convert(entry: entry, profile: .aac256, journal: journal)
        XCTAssertEqual(outcome.status, .converted, outcome.detail ?? "")

        let dest = URL(fileURLWithPath: entry.destinationPath)
        let metadata = try await Self.commonMetadata(of: dest)
        XCTAssertEqual(metadata["title"], "Ext Tone")
        XCTAssertEqual(metadata["artist"], "Ext Artist")
        XCTAssertEqual(metadata["album"], "Ext Album")

        // GAP B contract: the three fields that lack common keys must land
        // as iTunes-family atoms on the converted m4a.
        let dump = try await Self.identifierDump(of: dest)
        XCTAssertEqual(dump["itsk/aART"], "Ext Album Artist",
                       "album artist must survive conversion")
        let trkn = try await Self.positionalAtom(of: dest, identifier: "itsk/trkn")
        XCTAssertEqual(trkn?.number, 7, "track number must survive conversion")
        let disk = try await Self.positionalAtom(of: dest, identifier: "itsk/disk")
        XCTAssertEqual(disk?.number, 2, "disc number must survive conversion")
    }

    func testApplyMetadataCarriesID3AlbumArtistDiscTrack() async throws {
        guard let ffmpeg = ffmpegURL else { throw XCTSkip("ffmpeg not installed (fixture generation only)") }
        // MP3 sources are passthroughNative in the convert flow (lossy →
        // no re-encode), so the id3/* mapping is exercised through the
        // metadata stage itself: encode the mp3 once, then apply metadata
        // from the ID3-tagged source onto that encoded file.
        let mp3 = work.appendingPathComponent("tagged.mp3")
        try runProcess(ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error",
                                "-f", "lavfi", "-i", "sine=frequency=550:duration=3",
                                "-c:a", "libmp3lame", "-b:a", "128k", "-id3v2_version", "3",
                                "-metadata", "title=Totalling",
                                "-metadata", "TPE2=Total Album Artist",
                                "-metadata", "TPOS=2/2", "-metadata", "TRCK=7/12",
                                mp3.path])
        let engine = LocalImportEngine()
        let outDir = work.appendingPathComponent("out3", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let encoded = outDir.appendingPathComponent("encoded.m4a")
        _ = try await engine.encode(source: mp3, output: encoded, profile: .aac256)
        try await engine.applyMetadata(source: mp3, encoded: encoded, output: encoded)

        let dump = try await Self.identifierDump(of: encoded)
        XCTAssertEqual(dump["itsk/aART"], "Total Album Artist",
                       "ID3 TPE2 must map onto the aART atom")
        let trkn = try await Self.positionalAtom(of: encoded, identifier: "itsk/trkn")
        XCTAssertEqual(trkn?.number, 7)
        XCTAssertEqual(trkn?.total, 12, "ID3 TRCK 'n/total' totals must survive")
        let disk = try await Self.positionalAtom(of: encoded, identifier: "itsk/disk")
        XCTAssertEqual(disk?.number, 2)
        XCTAssertEqual(disk?.total, 2, "ID3 TPOS 'n/total' totals must survive")
    }

    func testConvertCarriesVorbisTrackAndDiscTotals() async throws {
        guard let ffmpeg = ffmpegURL else { throw XCTSkip("ffmpeg not installed (fixture generation only)") }
        // Vorbis "n/total" shapes must keep BOTH number and total.
        let flac = work.appendingPathComponent("totalling.flac")
        try runProcess(ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error",
                                "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                                "-c:a", "flac",
                                "-metadata", "title=Totalling F",
                                "-metadata", "ALBUMARTIST=Total Album Artist F",
                                "-metadata", "DISCNUMBER=2/2", "-metadata", "TRACKNUMBER=7/12",
                                flac.path])
        let outDir = work.appendingPathComponent("out2", isDirectory: true)
        let engine = LocalImportEngine()
        let journal = LocalImportJournal(directory: outDir.appendingPathComponent(".tunory"))
        let plan = await engine.planBatch(sourceRoot: work, outputRoot: outDir,
                                            profile: .aac256, journalRecords: [])
        let entry = plan.entries.first { $0.sourcePath.hasSuffix("totalling.flac") }!
        let outcome = await engine.convert(entry: entry, profile: .aac256, journal: journal)
        XCTAssertEqual(outcome.status, .converted, outcome.detail ?? "")
        let dest = URL(fileURLWithPath: entry.destinationPath)
        let dump = try await Self.identifierDump(of: dest)
        XCTAssertEqual(dump["itsk/aART"], "Total Album Artist F")
        let trkn = try await Self.positionalAtom(of: dest, identifier: "itsk/trkn")
        XCTAssertEqual(trkn?.number, 7)
        XCTAssertEqual(trkn?.total, 12, "vorbis 'n/total' totals must survive")
        let disk = try await Self.positionalAtom(of: dest, identifier: "itsk/disk")
        XCTAssertEqual(disk?.number, 2)
        XCTAssertEqual(disk?.total, 2)
    }

    func testExtendedMetadataParserEdgeCases() {
        // Deterministic parser contract, hand-built inputs (no ffmpeg).
        // "n" and "n/t" parse; whitespace trims; garbage rejects.
        XCTAssertEqual(LocalImportEngine.parsePositionalTag("7")?.number, 7)
        XCTAssertEqual(LocalImportEngine.parsePositionalTag(" 7 ")?.number, 7)
        XCTAssertEqual(LocalImportEngine.parsePositionalTag("7/12")?.number, 7)
        XCTAssertEqual(LocalImportEngine.parsePositionalTag("7/12")?.total, 12)
        XCTAssertNil(LocalImportEngine.parsePositionalTag("seven"))
        XCTAssertNil(LocalImportEngine.parsePositionalTag("-1"))
        XCTAssertNil(LocalImportEngine.parsePositionalTag(""))
        // Unparseable total: the number still parses, so the tag is kept
        // and only the total is dropped (documented parser contract).
        XCTAssertEqual(LocalImportEngine.parsePositionalTag("7/twelve")?.number, 7)
        XCTAssertNil(LocalImportEngine.parsePositionalTag("7/twelve")?.total,
                     "unparseable total keeps number")
        // A total that exceeds the 16-bit atom field: the tag keeps the
        // number, the total is dropped rather than wrapped or truncated.
        XCTAssertEqual(LocalImportEngine.parsePositionalTag("7/70000")?.number, 7)
        XCTAssertNil(LocalImportEngine.parsePositionalTag("7/70000")?.total)
        XCTAssertNil(LocalImportEngine.parsePositionalTag("70000"), "number beyond 16-bit rejects the tag")
        // Binary atom roundtrip (m4a source path).
        let atom = LocalImportEngine.iTunesPositionalAtom(number: 7, total: 12)
        XCTAssertEqual(atom.count, 8)
        XCTAssertEqual([UInt8](atom), [0, 0, 0, 7, 0, 12, 0, 0])
        XCTAssertEqual(LocalImportEngine.parsePositionalAtom(atom)?.number, 7)
        XCTAssertEqual(LocalImportEngine.parsePositionalAtom(atom)?.total, 12)
        // Short/garbage payloads reject, never guess.
        XCTAssertNil(LocalImportEngine.parsePositionalAtom(Data([0, 0, 0])))
        XCTAssertNil(LocalImportEngine.parsePositionalAtom(Data()))
        // No-total atom: number present, total nil.
        let noTotal = LocalImportEngine.iTunesPositionalAtom(number: 2, total: nil)
        XCTAssertEqual(LocalImportEngine.parsePositionalAtom(noTotal)?.number, 2)
        XCTAssertNil(LocalImportEngine.parsePositionalAtom(noTotal)?.total)
    }

    /// Read one positional iTunes atom (trkn/disk) from a file as
    /// (number, total) via AVFoundation.
    static func positionalAtom(of url: URL, identifier raw: String) async throws -> (number: Int, total: Int?)? {
        let asset = AVURLAsset(url: url)
        let formats = try await asset.load(.availableMetadataFormats)
        for format in formats {
            let items = try await asset.loadMetadata(for: format)
            for item in items {
                guard item.identifier?.rawValue == raw,
                      let data = try? await item.load(.dataValue) else { continue }
                return LocalImportEngine.parsePositionalAtom(data)
            }
        }
        return nil
    }

    // MARK: - Idempotency + adversarial destination states (§8.3)

    func testIdempotentSecondRunSkipsValidOutput() async throws {
        _ = try makeFLAC()
        let outDir = work.appendingPathComponent("out", isDirectory: true)
        let engine = LocalImportEngine()
        let journal = LocalImportJournal(directory: outDir.appendingPathComponent(".tunory"))
        let plan = await engine.planBatch(sourceRoot: work, outputRoot: outDir,
                                            profile: .aac256, journalRecords: [])
        let entry = plan.entries.first { $0.sourcePath.hasSuffix("tone.flac") }!
        let first = await engine.convert(entry: entry, profile: .aac256, journal: journal)
        XCTAssertEqual(first.status, .converted, first.detail ?? "")

        let dest = URL(fileURLWithPath: entry.destinationPath)
        let mtimeFirst = try FileManager.default.attributesOfItem(atPath: dest.path)[.modificationDate] as? Date
        try await Task.sleep(nanoseconds: 50_000_000)

        // Replan WITH the journal (as a second run would) and reconvert.
        let (records, _) = try journal.load()
        let plan2 = await engine.planBatch(sourceRoot: work, outputRoot: outDir,
                                            profile: .aac256, journalRecords: records)
        let entry2 = plan2.entries.first { $0.sourcePath.hasSuffix("tone.flac") }!
        XCTAssertEqual(entry2.decision, .skipValidOutput, "valid output must be skipped on re-run")
        let second = await engine.convert(entry: entry2, profile: .aac256, journal: journal)
        XCTAssertEqual(second.status, .skippedValid)
        let mtimeSecond = try FileManager.default.attributesOfItem(atPath: dest.path)[.modificationDate] as? Date
        XCTAssertEqual(mtimeFirst, mtimeSecond, "skip must not touch the file mtime")
    }

    func testReconvertsOurInvalidPriorOutput() async throws {
        _ = try makeFLAC()
        let outDir = work.appendingPathComponent("out", isDirectory: true)
        let engine = LocalImportEngine()
        let journal = LocalImportJournal(directory: outDir.appendingPathComponent(".tunory"))
        let plan = await engine.planBatch(sourceRoot: work, outputRoot: outDir,
                                            profile: .aac256, journalRecords: [])
        let entry = plan.entries.first { $0.sourcePath.hasSuffix("tone.flac") }!
        _ = await engine.convert(entry: entry, profile: .aac256, journal: journal)
        let dest = URL(fileURLWithPath: entry.destinationPath)
        // Truncate the output to simulate a corrupt prior run.
        let handle = try FileHandle(forWritingTo: dest)
        try handle.truncate(atOffset: 100)
        try handle.close()

        let (records, _) = try journal.load()
        let plan2 = await engine.planBatch(sourceRoot: work, outputRoot: outDir,
                                            profile: .aac256, journalRecords: records)
        let entry2 = plan2.entries.first { $0.sourcePath.hasSuffix("tone.flac") }!
        XCTAssertEqual(entry2.decision, .convert,
                       "our invalid prior output must be reconverted")
        let outcome = await engine.convert(entry: entry2, profile: .aac256, journal: journal)
        XCTAssertEqual(outcome.status, .converted, outcome.detail ?? "")
        let probe = await AudioProber().probe(url: dest)
        XCTAssertEqual(probe.codec, "aac", "fresh conversion must validate")
    }

    func testNeverOverwritesForeignFileAtDestination() async throws {
        _ = try makeFLAC()
        let outDir = work.appendingPathComponent("out", isDirectory: true)
        // A pre-existing foreign file at the exact destination path.
        let sentinelRel = "tone.m4a"
        let sentinel = outDir.appendingPathComponent(sentinelRel)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try Data("sentinel - user's own file".utf8).write(to: sentinel)
        let sentinelHashBefore = LocalImportEngine.sha256Hex(fileURL: sentinel)

        let engine = LocalImportEngine()
        let journal = LocalImportJournal(directory: outDir.appendingPathComponent(".tunory"))
        let plan = await engine.planBatch(sourceRoot: work, outputRoot: outDir,
                                            profile: .aac256, journalRecords: [])
        let entry = plan.entries.first { $0.sourcePath.hasSuffix("tone.flac") }!
        XCTAssertEqual(entry.decision, .conflictDestinationInvalidForeign,
                       "invalid foreign destination must be a conflict, never overwritten")
        let outcome = await engine.convert(entry: entry, profile: .aac256, journal: journal)
        XCTAssertEqual(outcome.status, .conflict)
        XCTAssertEqual(LocalImportEngine.sha256Hex(fileURL: sentinel), sentinelHashBefore,
                       "sentinel must be byte-identical after the refused conversion")

        // No temp file leaked at the destination directory.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: outDir.path)
            .filter { $0.hasPrefix(".tunory-tmp-") }
        XCTAssertTrue(leftovers.isEmpty, "no temp files may leak: \(leftovers)")
    }

    func testAtomicPromoteNoPartialFileVisible() async throws {
        _ = try makeFLAC()
        let outDir = work.appendingPathComponent("out", isDirectory: true)
        let engine = LocalImportEngine()
        let journal = LocalImportJournal(directory: outDir.appendingPathComponent(".tunory"))
        let plan = await engine.planBatch(sourceRoot: work, outputRoot: outDir,
                                            profile: .aac256, journalRecords: [])
        let entry = plan.entries.first { $0.sourcePath.hasSuffix("tone.flac") }!
        let outcome = await engine.convert(entry: entry, profile: .aac256, journal: journal)
        XCTAssertEqual(outcome.status, .converted, outcome.detail ?? "")
        let dest = URL(fileURLWithPath: entry.destinationPath)
        // A fully promoted file must be immediately decodable (it was
        // validated before the rename, so no partial state is possible).
        let probe = await AudioProber().probe(url: dest)
        XCTAssertEqual(probe.codec, "aac")
    }

    // MARK: - FLAC PICTURE block parser (D1: artwork carry)

    func testFlacPictureParserExtractsEmbeddedArtwork() throws {
        guard let ffmpeg = ffmpegURL else { throw XCTSkip("ffmpeg not installed (fixture generation only)") }
        let png = try Self.makeTinyPNG(in: work)
        let flac = work.appendingPathComponent("pic.flac")
        try runProcess(ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error",
                                "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
                                "-i", png.path,
                                "-map", "0:a", "-map", "1:v",
                                "-c:a", "flac", "-c:v", "png",
                                "-disposition:v", "attached_pic",
                                "-f", "flac", flac.path])
        let pictures = try LocalImportEngine.flacPictures(in: flac)
        XCTAssertEqual(pictures.count, 1)
        XCTAssertEqual(pictures.first?.mime, "image/png")
        // ffmpeg re-encodes the PNG when embedding it into the FLAC, so
        // assert against the bytes actually in the file, plus the PNG
        // magic as an independent sanity check.
        let raw = try Data(contentsOf: flac)
        let stored = pictures.first?.data ?? Data()
        XCTAssertTrue(raw.range(of: stored) != nil,
                      "parsed picture bytes must be the bytes physically stored in the FLAC")
        XCTAssertEqual(stored.prefix(8), Self.pngMagic, "embedded picture must be PNG data")
    }

    func testFlacPictureParserRejectsNonFlacAndTruncated() throws {
        // Not FLAC at all: zero pictures, no throw.
        let text = work.appendingPathComponent("notflac.flac")
        try Data("definitely not a flac stream".utf8).write(to: text)
        XCTAssertTrue(try LocalImportEngine.flacPictures(in: text).isEmpty)

        // FLAC magic with a PICTURE block whose length overruns the file
        // must not read out of bounds and must return what it safely can.
        var truncated = Data("fLaC".utf8)
        truncated.append(0x06)                 // block type 6 (PICTURE)
        truncated.append(contentsOf: [0, 0, 0x10]) // claimed body length 16
        truncated.append(contentsOf: Array(repeating: 0xAB, count: 4)) // fewer bytes than claimed
        let truncFile = work.appendingPathComponent("trunc.flac")
        try truncated.write(to: truncFile)
        let pictures = try LocalImportEngine.flacPictures(in: truncFile)
        XCTAssertTrue(pictures.isEmpty, "overrunning PICTURE block must parse to nothing, not crash")
    }

    // MARK: - Journal determinism

    func testJournalAppendIsDeterministicAndAtomicFileExists() throws {
        let journal = LocalImportJournal(directory: work.appendingPathComponent(".tunory"))
        let rec1 = LocalImportJournalRecord(sourcePath: "/b.flac", destinationPath: "/out/b.m4a",
                                             sourceSHA256: "aa", profile: .aac256,
                                             completedAt: ISO8601DateWithNanoseconds(secondsSinceEpoch: 20))
        let rec2 = LocalImportJournalRecord(sourcePath: "/a.flac", destinationPath: "/out/a.m4a",
                                             sourceSHA256: "bb", profile: .aac256,
                                             completedAt: ISO8601DateWithNanoseconds(secondsSinceEpoch: 10))
        try journal.append([rec1])
        try journal.append([rec2])
        let (records, _) = try journal.load()
        XCTAssertEqual(records.map { $0.sourcePath }, ["/a.flac", "/b.flac"],
                       "journal must be deterministically sorted regardless of append order")
    }

    func testJournalUnreadableTreatedAsEmpty() throws {
        let dir = work.appendingPathComponent(".tunory")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent(LocalImportJournal.fileName))
        let journal = LocalImportJournal(directory: dir)
        let (records, warning) = try journal.load()
        XCTAssertTrue(records.isEmpty)
        XCTAssertNotNil(warning, "unreadable journal must be reported")
    }

    // MARK: - Native verification helpers (no external tools)

    /// Common metadata (title/artist/album) of a file via AVFoundation.
    /// Reads `commonKey` (the only cross-format mapping surface the SDK
    /// exposes on the item); format-specific keys are translated for
    /// the switch.
    static func commonMetadata(of url: URL) async throws -> [String: String] {
        let asset = AVURLAsset(url: url)
        var result: [String: String] = [:]
        let formats = try await asset.load(.availableMetadataFormats)
        for format in formats {
            let items = try await asset.loadMetadata(for: format)
            for item in items {
                guard let commonKey = item.commonKey,
                      let value = try? await item.load(.stringValue) else { continue }
                switch commonKey {
                case .commonKeyTitle: result["title"] = value
                case .commonKeyArtist: result["artist"] = value
                case .commonKeyAlbumName: result["album"] = value
                default: break
                }
            }
        }
        return result
    }

    /// Artwork payload of a file via AVFoundation, if present.
    static func artworkData(of url: URL) async throws -> Data? {
        let asset = AVURLAsset(url: url)
        let formats = try await asset.load(.availableMetadataFormats)
        for format in formats {
            let items = try await asset.loadMetadata(for: format)
            for item in items {
                guard let commonKey = item.commonKey,
                      commonKey == AVMetadataKey.commonKeyArtwork else { continue }
                if let data = try? await item.load(.dataValue) {
                    return data
                }
            }
        }
        return nil
    }

    /// D1 fidelity gate: the converted lossless file must decode to the
    /// same PCM as the source. Reopen both files (a streaming read
    /// leaves the reader at EOF) and compare frame count + Float32
    /// samples within tolerance.
    static func assertPCMEquivalent(source: URL, converted: URL, tolerance: Float) async throws {
        let srcFile = try AVAudioFile(forReading: source)
        let srcFormat = srcFile.processingFormat
        let srcFrames = AVAudioFrameCount(srcFile.length)
        let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: srcFrames)!
        try srcFile.read(into: srcBuffer)

        let outFile = try AVAudioFile(forReading: converted)
        let outFormat = outFile.processingFormat
        let outFrames = AVAudioFrameCount(outFile.length)
        XCTAssertEqual(UInt(srcFrames), UInt(outFrames),
                       "lossless conversion must preserve the exact frame count")

        // Both decode to Float32 processing format; channel layouts may
        // differ in description but must match in channel count.
        XCTAssertEqual(srcFormat.channelCount, outFormat.channelCount)
        XCTAssertEqual(srcFormat.sampleRate, outFormat.sampleRate,
                       "lossless conversion must preserve the sample rate")

        let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outFrames)!
        try outFile.read(into: outBuffer)

        for channel in 0..<Int(srcFormat.channelCount) {
            let s = srcBuffer.floatChannelData![channel]
            let o = outBuffer.floatChannelData![channel]
            for frame in 0..<Int(srcFrames) {
                let delta = abs(s[frame] - o[frame])
                if delta > tolerance {
                    XCTFail("PCM mismatch channel \(channel) frame \(frame): |\(s[frame]) - \(o[frame])| = \(delta) > \(tolerance)")
                    return
                }
            }
        }
    }

    // MARK: - Tiny PNG fixture

    static let pngMagic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    /// Minimal valid 1x1 PNG (transparent pixel), hand-assembled so the
    /// fixture does not depend on AppKit imaging in a CLI test context.
    static func makeTinyPNG(in dir: URL) throws -> URL {
        // PNG signature + IHDR + IDAT + IEND, CRCs precomputed for this
        // exact byte sequence (a fixed 67-byte file).
        var png = pngMagic
        png.append(contentsOf: [
            0x00, 0x00, 0x00, 0x0D, // IHDR length
            0x49, 0x48, 0x44, 0x52, // "IHDR"
            0x00, 0x00, 0x00, 0x01, // width 1
            0x00, 0x00, 0x00, 0x01, // height 1
            0x08, 0x06, 0x00, 0x00, 0x00, // 8-bit RGBA
            0x1F, 0x15, 0xC4, 0x89, // IHDR CRC
            0x00, 0x00, 0x00, 0x0A, // IDAT length
            0x49, 0x44, 0x41, 0x54, // "IDAT"
            0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, // zlib stream: 1 filter byte + 4px bytes
            0x0D, 0x0A, 0x2D, 0xB4, // IDAT CRC
            0x00, 0x00, 0x00, 0x00, // IEND length
            0x49, 0x45, 0x4E, 0x44, // "IEND"
            0xAE, 0x42, 0x60, 0x82, // IEND CRC
        ])
        let url = dir.appendingPathComponent("tiny.png")
        try png.write(to: url)
        return url
    }
}

// (No URL extensions needed: all helpers are static funcs above.)
