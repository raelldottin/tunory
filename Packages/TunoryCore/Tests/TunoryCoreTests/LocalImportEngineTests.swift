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
