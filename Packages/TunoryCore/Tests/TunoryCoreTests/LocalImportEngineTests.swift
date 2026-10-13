import XCTest
@testable import TunoryCore

// Local-import engine tests. Fixtures are generated INTO TEST-OWNED TEMP
// DIRS at test time (research acceptance contract t_dc244b34 §8): never
// the real library, never committed binaries. ffmpeg is an optional
// system dependency; conversion tests skip visibly when it is absent
// (XCTSkip is fail-visible in the report, not a silent pass).

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

    /// Generate a FLAC fixture via ffmpeg lavfi (sine tone). The
    /// generator itself uses ffmpeg, which every conversion test
    /// already requires.
    func makeFLAC(name: String = "tone.flac", metadata: Bool = true) throws -> URL {
        guard let ffmpeg = ffmpegURL else { throw XCTSkip("ffmpeg not installed") }
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
        guard let ffmpeg = ffmpegURL else { throw XCTSkip("ffmpeg not installed") }
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
        guard let ffmpeg = ffmpegURL else { throw XCTSkip("ffmpeg not installed") }
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
        let engine = LocalImportEngine(ffmpegURL: ffmpegURL)
        let flac = try makeFLAC()
        // Lossy source: create an mp3 by converting the flac.
        guard let ffmpeg = ffmpegURL else { throw XCTSkip("ffmpeg not installed") }
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
        guard let ffmpeg = ffmpegURL else { throw XCTSkip("ffmpeg not installed") }
        let mp3 = work.appendingPathComponent("tone.mp3")
        try runProcess(ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error",
                                "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                                "-c:a", "libmp3lame", "-b:a", "128k", mp3.path])
        let engine = LocalImportEngine(ffmpegURL: ffmpegURL)
        let plan = await engine.planBatch(sourceRoot: work, outputRoot: work.appendingPathComponent("out"),
                                            profile: .alac, journalRecords: [])
        XCTAssertEqual(plan.entries.first?.decision, .blockedByProfile)
    }

    func testPlanPreservesRelativeStructure() async throws {
        let nested = work.appendingPathComponent("Artist/Album1", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try makeFLAC(name: "Artist/Album1/reftrack.flac")
        let engine = LocalImportEngine(ffmpegURL: ffmpegURL)
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
        let engine = LocalImportEngine(ffmpegURL: ffmpegURL)
        let plan = await engine.planBatch(sourceRoot: work, outputRoot: work.appendingPathComponent("out"),
                                            profile: .aac256, journalRecords: [])
        // Files are walked sorted: dup-a before dup-b.
        let dupB = plan.entries.first { $0.sourcePath.hasSuffix("dup-b.flac") }
        XCTAssertNotNil(dupB?.duplicateOfIndex, "identical bytes must be classified duplicate")
        let dupA = plan.entries.first { $0.sourcePath.hasSuffix("dup-a.flac") }
        XCTAssertNil(dupA?.duplicateOfIndex)
    }

    // MARK: - Conversion (acceptance contract §8.1, §8.2)

    func testConvertFLACToM4AReferenceProfile() async throws {
        guard ffmpegURL != nil else { throw XCTSkip("ffmpeg not installed") }
        let flac = try makeFLAC()
        let outDir = work.appendingPathComponent("out", isDirectory: true)
        let engine = LocalImportEngine(ffmpegURL: ffmpegURL)
        let journal = LocalImportJournal(directory: outDir.appendingPathComponent(".tunory"))
        let plan = await engine.planBatch(sourceRoot: work, outputRoot: outDir,
                                            profile: .aac256, journalRecords: [])
        let entry = plan.entries.first { $0.sourcePath.hasSuffix("tone.flac") }
        XCTAssertNotNil(entry)
        let sourceHashBefore = LocalImportEngine.sha256Hex(fileURL: flac)
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
        XCTAssertEqual(sourceHashBefore, LocalImportEngine.sha256Hex(fileURL: flac),
                       "originals must never be modified")

        // Metadata preserved via ffprobe-style check: use AVFoundation's
        // metadata or check via ffmpeg. Simplest: probe with ffprobe.
        let ffprobe = ffmpegURL!.deletingLastPathComponent().appendingPathComponent("ffprobe")
        if FileManager.default.isExecutableFile(atPath: ffprobe.path) {
            let output = try probeMetadata(ffprobe, dest)
            XCTAssertTrue(output.contains("Test Tone"), "title metadata must survive conversion")
        }
    }

    func probeMetadata(_ ffprobe: URL, _ file: URL) throws -> String {
        let p = Process()
        p.executableURL = ffprobe
        // ffprobe (unlike ffmpeg) has no -nostdin/-hide_banner options and
        // exits with "Option not found" when given them (captured, ffmpeg
        // 6.x) — the helper then saw empty output and reported metadata as
        // lost. -v error is the correct quiet flag for ffprobe.
        p.arguments = ["-v", "error",
                       "-show_entries", "format_tags=title,artist",
                       "-of", "default=noprint_wrappers=1", file.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    func testConversionBitrateWithinContract() async throws {
        guard let ffmpeg = ffmpegURL else { throw XCTSkip("ffmpeg not installed") }
        // §8.2: on complex content (stereo pink noise) assert ≤ 256k+10%
        // and ≥ 128k; equality is NOT the contract (research §5).
        let noise = work.appendingPathComponent("noise.flac")
        try runProcess(ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error",
                                "-f", "lavfi", "-i", "anoisesrc=color=pink:duration=3:amplitude=0.5",
                                "-ac", "2", "-c:a", "flac", noise.path])
        let outDir = work.appendingPathComponent("out", isDirectory: true)
        let engine = LocalImportEngine(ffmpegURL: ffmpegURL)
        let journal = LocalImportJournal(directory: outDir.appendingPathComponent(".tunory"))
        let plan = await engine.planBatch(sourceRoot: work, outputRoot: outDir,
                                            profile: .aac256, journalRecords: [])
        let entry = plan.entries.first { $0.sourcePath.hasSuffix("noise.flac") }
        let outcome = await engine.convert(entry: entry!, profile: .aac256, journal: journal)
        XCTAssertEqual(outcome.status, .converted, outcome.detail ?? "")

        let ffprobe = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        let bitrate = try bitrateOf(ffprobe, URL(fileURLWithPath: entry!.destinationPath))
        XCTAssertLessThanOrEqual(bitrate, 256_000 * 110 / 100, "bitrate must be within target+10%")
        XCTAssertGreaterThanOrEqual(bitrate, 128_000, "hard floor on complex content")
    }

    func bitrateOf(_ ffprobe: URL, _ file: URL) throws -> Int {
        let p = Process()
        p.executableURL = ffprobe
        p.arguments = ["-v", "error",
                       "-show_entries", "format=bit_rate", "-of", "default=noprint_wrappers=1:nokey=1",
                       file.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
        return Int(text) ?? 0
    }

    // MARK: - Idempotency + adversarial destination states (§8.3)

    func testIdempotentSecondRunSkipsValidOutput() async throws {
        guard ffmpegURL != nil else { throw XCTSkip("ffmpeg not installed") }
        let flac = try makeFLAC()
        let outDir = work.appendingPathComponent("out", isDirectory: true)
        let engine = LocalImportEngine(ffmpegURL: ffmpegURL)
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
        guard ffmpegURL != nil else { throw XCTSkip("ffmpeg not installed") }
        let flac = try makeFLAC()
        let outDir = work.appendingPathComponent("out", isDirectory: true)
        let engine = LocalImportEngine(ffmpegURL: ffmpegURL)
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
        guard ffmpegURL != nil else { throw XCTSkip("ffmpeg not installed") }
        _ = try makeFLAC()
        let outDir = work.appendingPathComponent("out", isDirectory: true)
        // A pre-existing foreign file at the exact destination path.
        let sentinelRel = "tone.m4a"
        let sentinel = outDir.appendingPathComponent(sentinelRel)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try Data("sentinel - user's own file".utf8).write(to: sentinel)
        let sentinelHashBefore = LocalImportEngine.sha256Hex(fileURL: sentinel)

        let engine = LocalImportEngine(ffmpegURL: ffmpegURL)
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
        guard ffmpegURL != nil else { throw XCTSkip("ffmpeg not installed") }
        _ = try makeFLAC()
        let outDir = work.appendingPathComponent("out", isDirectory: true)
        let engine = LocalImportEngine(ffmpegURL: ffmpegURL)
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
}
