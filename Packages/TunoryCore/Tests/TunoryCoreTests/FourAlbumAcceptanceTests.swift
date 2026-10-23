import XCTest
@testable import TunoryCore

// Four-album acceptance fixtures for the Music.app import contract
// (Req 6; task t_6adaba95; parent spec t_6069340a comment 141).
//
// Fixture: FOUR deterministic album directories holding FORTY real FLAC
// bitstreams (ffmpeg lavfi + genuine vorbis comments), of which THIRTEEN
// recordings are represented in a simulated Music.app library and
// TWENTY-SEVEN are provably missing. Everything is generated INTO
// TEST-OWNED TEMP DIRS at test time — disposable, never the real library,
// never committed binaries. ffmpeg is fixture tooling only; when absent
// the fixture tests skip VISIBLY (XCTSkip), never silently pass.
//
// The 13 existing recordings mix both provable identities:
//   * 4 byte-identical library copies (SHA-256 equal -> exactDuplicate);
//   * 9 cross-format AAC twins (six metadata axes equal + duration
//     within the +-2 s tolerance -> verifiedExisting), the "same song,
//     different encoding" case.
//
// Honest run-1 expectation (27-13-0-0-0): 27 imported, 13 skipped,
// 0 review, 0 failed, 0 unintended duplicates, 0 original files
// modified, 0 pre-existing library tracks modified. No metadata was
// tuned to force these numbers: each of the 40 is provably in its
// bucket (search proves presence/absence; hash/axes prove identity).
// Ambiguous members are covered separately (adversarial review bucket)
// and MUST stop for review — never misclassified to force a count.
//
// Run-2 idempotency: with the journal's verified records supplied as
// priorRecords, every prior import short-circuits to skippedDuplicate
// BEFORE any survey or add (the no-blind-re-add invariant); the 13
// pre-existing recordings re-verify via fresh surveys. 0 newly imported,
// 0 duplicates, no unrelated library changes.
//
// Invariants under test (parent card + board proof ladder):
//   * album selection + recursive discovery (4 album dirs, one album
//     nested as CD1/CD2 — recursion is required to find all 40);
//   * metadata preservation (vorbis comments flow through the GAP B
//     mapping into AudioMetadataTags, six axes, for all 40);
//   * duplicate detection: skip existing (byte proof + six-axis proof),
//     import missing, flag conflicts for explicit review;
//   * non-destructive Music.app import: reads + add only; originals
//     byte-unchanged; existing library entries element-wise unchanged;
//   * durable evidence: journal records .attempted BEFORE each add and
//     .verified after read-back, in deterministic append order.
//
// Live Music.app is never driven (owner rule): all library state is the
// deterministic in-memory fake below, which mirrors FakeMusicScripting's
// shape (MusicImportEngineTests.swift) without touching that board
// hotspot file. Conversion and sandbox-write mechanics are exercised by
// LocalImportEngineTests; this suite pins the import funnel on top of
// the same real-FLAC fixtures.

private extension NSLocking {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }; return body()
    }
}

final class FourAlbumAcceptanceTests: XCTestCase {

    var work: URL!
    var ffmpegURL: URL?

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunory-four-album-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        ffmpegURL = FourAlbumAcceptanceTests.locateFFmpeg()
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

    /// REAL FLAC bitstream with a full six-axis vorbis comment block,
    /// written into `directory`. Exactly the fixture keys that provably
    /// parse through GAP B loadTags: title/artist/album/ALBUMARTIST/
    /// DISCNUMBER/TRACKNUMBER (the "n/total" form self-loads as n).
    @discardableResult
    func makeRealFLAC(in directory: URL,
                       name: String,
                       title: String,
                       artist: String,
                       album: String,
                       albumArtist: String,
                       disc: Int,
                       track: Int,
                       trackTotal: Int,
                       duration: Double,
                       sampleRate: Int = 44100,
                       channels: Int = 1) throws -> URL {
        guard let ffmpeg = ffmpegURL else {
            throw XCTSkip("ffmpeg not installed (fixture generation only)")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let out = directory.appendingPathComponent(name)
        var args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-f", "lavfi",
                    "-i", "sine=frequency=440:duration=\(duration):sample_rate=\(sampleRate)",
                    "-ac", "\(channels)",
                    "-f", "flac", "-c:a", "flac",
                    "-metadata", "title=\(title)",
                    "-metadata", "artist=\(artist)",
                    "-metadata", "album=\(album)",
                    "-metadata", "ALBUMARTIST=\(albumArtist)",
                    "-metadata", "DISCNUMBER=\(disc)",
                    "-metadata", "TRACKNUMBER=\(track)/\(trackTotal)"]
        args.append(out.path)
        try runProcess(ffmpeg, args)
        return out
    }

    /// REAL AAC (.m4a) library twin: a genuinely different encoding of
    /// the same-length recording (different codec, different hash), so
    /// only the six-axes + duration rule can prove the identity.
    @discardableResult
    func makeRealAAC(in directory: URL,
                     name: String,
                     duration: Double) throws -> URL {
        guard let ffmpeg = ffmpegURL else {
            throw XCTSkip("ffmpeg not installed (fixture generation only)")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let out = directory.appendingPathComponent(name)
        let args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-f", "lavfi",
                    "-i", "sine=frequency=515:duration=\(duration):sample_rate=44100",
                    "-ac", "1", "-f", "ipod", "-c:a", "aac", out.path]
        try runProcess(ffmpeg, args)
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

    // MARK: - Four-album fixture spec (deterministic, 40 tracks)

    struct TrackSpec {
        let albumDir: String          // e.g. "01 Midnight Signals"
        let subDir: String?           // e.g. "CD1" (nested -> recursion)
        let file: String               // e.g. "01.flac"
        let title: String
        let artist: String
        let album: String
        let albumArtist: String
        let disc: Int
        let track: Int
        let trackTotal: Int
        let duration: Double
        /// nil = provably missing; .hashTwin / .aacTwin = existing.
        let existing: ExistingKind?
    }

    enum ExistingKind { case hashTwin, aacTwin }

    /// The settled Req 6 census: 4 albums, 40 FLAC, 13 existing
    /// (4 byte-identical + 9 cross-format AAC), 27 missing.
    static let albumCensus = [
        ("01 Midnight Signals", 12), ("02 Paper Lanterns", 10),
        ("03 Harbor Lights", 10), ("04 Static Bloom", 8),
    ]

    static func trackSpecs() -> [TrackSpec] {
        var specs: [TrackSpec] = []
        func ms(_ n: Int, _ total: Int, existing: ExistingKind? = nil) -> TrackSpec {
            TrackSpec(albumDir: "01 Midnight Signals", subDir: nil,
                      file: String(format: "%02d", n) + ".flac",
                      title: "Midnight Signals Track \(String(format: "%02d", n))",
                      artist: "The Night Council", album: "Midnight Signals",
                      albumArtist: "The Night Council",
                      disc: 1, track: n, trackTotal: total,
                      duration: 3 + Double(n % 3), existing: existing)
        }
        for n in 1...4 { specs.append(ms(n, 12, existing: .hashTwin)) }   // 4 byte-identical
        for n in 5...12 { specs.append(ms(n, 12)) }                      // 8 missing

        func pl(cd: Int, n: Int, existing: ExistingKind? = nil) -> TrackSpec {
            TrackSpec(albumDir: "02 Paper Lanterns", subDir: "CD\(cd)",
                      file: String(format: "%02d", n) + ".flac",
                      title: "Paper Lanterns Track \(cd)-\(String(format: "%02d", n))",
                      artist: "Mio Sato", album: "Paper Lanterns",
                      albumArtist: "Mio Sato",
                      disc: cd, track: n, trackTotal: 5,
                      duration: 3 + Double((cd * n) % 3), existing: existing)
        }
        for n in 1...3 { specs.append(pl(cd: 1, n: n, existing: .aacTwin)) } // 3 cross-format
        for n in 4...5 { specs.append(pl(cd: 1, n: n)) }
        for n in 1...5 { specs.append(pl(cd: 2, n: n)) }                    // 7 missing

        func hl(_ n: Int, existing: ExistingKind? = nil) -> TrackSpec {
            TrackSpec(albumDir: "03 Harbor Lights", subDir: nil,
                      file: String(format: "%02d", n) + ".flac",
                      title: "Harbor Lights Track \(String(format: "%02d", n))",
                      artist: "The Ferries", album: "Harbor Lights",
                      albumArtist: "The Ferries",
                      disc: 1, track: n, trackTotal: 10,
                      duration: 3 + Double(n % 3), existing: existing)
        }
        for n in 1...4 { specs.append(hl(n, existing: .aacTwin)) }        // 4 cross-format
        for n in 5...10 { specs.append(hl(n)) }                           // 6 missing

        func sb(_ n: Int, existing: ExistingKind? = nil) -> TrackSpec {
            TrackSpec(albumDir: "04 Static Bloom", subDir: nil,
                      file: String(format: "%02d", n) + ".flac",
                      title: "Static Bloom Track \(String(format: "%02d", n))",
                      artist: "Nadia Wave", album: "Static Bloom",
                      albumArtist: "Nadia Wave",
                      disc: 1, track: n, trackTotal: 8,
                      duration: 3 + Double(n % 3), existing: existing)
        }
        for n in 1...2 { specs.append(sb(n, existing: .aacTwin)) }        // 2 cross-format
        for n in 3...8 { specs.append(sb(n)) }                           // 6 missing

        return specs
    }

    /// The fixture root, canonicalized AFTER creation: temporaryDirectory
    /// hands out /var/folders/... URLs, while FileManager.enumerator walks
    /// report /private/var/folders/... — resolving symlinks on the EXISTING
    /// root makes both sides byte-identical. (Resolving pre-creation is a
    /// documented no-op, so canonicalize only after the fixture exists.)
    static func fixtureRoot(work: URL) -> URL {
        work.appendingPathComponent("four-albums", isDirectory: true)
            .resolvingSymlinksInPath()
    }

    /// The fixture-relative key for a spec: "album dir/[subdir/]file",
    /// lowercased — the same key the discovery walk derives from paths.
    static func relativeKey(_ s: TrackSpec) -> String {
        let sub = s.subDir.map { subdir in "\(subdir)/" } ?? ""
        return "\(s.albumDir)/\(sub)\(s.file)".lowercased()
    }

    /// Deterministic recursive FLAC enumeration (sorted by path): the
    /// acceptance stand-in for recursive discovery — the nested CD1/CD2
    /// album is only findable through a recursive walk.
    static func enumerateFLACs(in root: URL) throws -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil)
        while let next = enumerator?.nextObject() as? URL {
            if next.pathExtension.lowercased() == "flac" { found.append(next) }
        }
        // Canonicalize (paths exist): enumerator yields /private/var/...
        return found.map { $0.resolvingSymlinksInPath() }.sorted { $0.path < $1.path }
    }

    /// Build the four-album FLAC fixture plus the simulated Music.app
    /// library files for the 13 existing recordings. Returns the FLAC
    /// URLs (sorted, run order) and the initial library refs.
    func buildFourAlbumFixture() throws -> (files: [URL], library: [MusicTrackRef]) {
        let root = work.appendingPathComponent("four-albums", isDirectory: true)
        let libraryFiles = work.appendingPathComponent("library-files", isDirectory: true)
        var library: [MusicTrackRef] = []
        var files: [URL] = []
        var twinIndex = 0
        for spec in FourAlbumAcceptanceTests.trackSpecs() {
            let dir = spec.subDir.map { root.appendingPathComponent(spec.albumDir).appendingPathComponent($0) }
                ?? root.appendingPathComponent(spec.albumDir)
            let flac = try makeRealFLAC(in: dir, name: spec.file, title: spec.title,
                                        artist: spec.artist, album: spec.album,
                                        albumArtist: spec.albumArtist, disc: spec.disc,
                                        track: spec.track, trackTotal: spec.trackTotal,
                                        duration: spec.duration)
            files.append(flac)
            twinIndex += 1
            let id = "LIB-\(String(format: "%02d", twinIndex))"
            switch spec.existing {
            case .hashTwin?:
                // Byte-identical copy in the simulated library: SHA-256
                // proof, the strongest duplicate evidence.
                let copy = libraryFiles.appendingPathComponent("hash-\(twinIndex).flac")
                try FileManager.default.createDirectory(at: libraryFiles, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: flac, to: copy)
                library.append(MusicTrackRef(
                    persistentID: id, name: spec.title, artist: spec.artist,
                    album: spec.album, albumArtist: spec.albumArtist,
                    discNumber: spec.disc, trackNumber: spec.track,
                    locationPath: copy.path, durationSeconds: spec.duration))
            case .aacTwin?:
                // Cross-format twin: a real AAC encoding (different hash)
                // whose ref carries the same six axes and duration, so
                // only the metadata rule can prove "same recording".
                let aac = try makeRealAAC(in: libraryFiles, name: "twin-\(twinIndex).m4a",
                                         duration: spec.duration)
                library.append(MusicTrackRef(
                    persistentID: id, name: spec.title, artist: spec.artist,
                    album: spec.album, albumArtist: spec.albumArtist,
                    discNumber: spec.disc, trackNumber: spec.track,
                    locationPath: aac.path, durationSeconds: spec.duration))
            case nil:
                break
            }
        }
        // Canonicalize (files exist) so builder output and the recursive
        // walk's output are byte-identical paths.
        return (files.map { $0.resolvingSymlinksInPath() }.sorted { $0.path < $1.path },
                library)
    }

    // MARK: - Mocked Music.app scripting surface (own copy, board-hotspot safe)

    /// Deterministic in-memory Music.app for the four-album run: same
    /// shape and knob semantics as FakeMusicScripting
    /// (MusicImportEngineTests.swift:48-128) — nextAddResult (nil = add
    /// failure), addActuallyImports, failReadBack, failSearch,
    /// failSearchAfterCalls, readBackFinds — plus a library snapshot
    /// for the non-modification proof. The parent file is untouched.
    final class FourAlbumScriptingFake: MusicScripting, @unchecked Sendable {
        struct AddCall { let file: URL }

        var library: [MusicTrackRef]
        private var addedLocations: Set<String> = []
        private(set) var addCalls: [AddCall] = []
        private(set) var searchQueries: [String] = []
        var nextAddResult: String? = "ADDED123"
        var addActuallyImports = true
        var failReadBack = false
        var readBackFinds = true
        var failSearch = false
        var failSearchAfterCalls = 0
        private var searchCallCount = 0
        private let lock = NSLock()

        init(library: [MusicTrackRef] = []) {
            self.library = library
        }

        func musicVersion() async -> String? { "1.7.0" }
        func libraryTrackCount() async -> Int? {
            lock.withLock { library.count }
        }

        func searchLibrary(query: String) async -> [MusicTrackRef]? {
            lock.withLock {
                searchQueries.append(query)
                searchCallCount += 1
                if failSearch {
                    let threshold = failSearchAfterCalls
                    if threshold == 0 || searchCallCount > threshold {
                        return nil
                    }
                }
                var matches = library.filter { $0.name == query }
                if !readBackFinds {
                    matches = matches.filter { !(addedLocations.contains($0.locationPath ?? "")) }
                }
                return matches
            }
        }

        func track(withPersistentID id: String) async -> MusicTrackRef? {
            lock.withLock {
                if failReadBack { return nil }
                return library.first { $0.persistentID == id }
            }
        }

        func add(file: URL) async -> String? {
            lock.withLock {
                addCalls.append(AddCall(file: file))
                guard let id = nextAddResult else { return nil }
                if addActuallyImports {
                    addedLocations.insert(file.path)
                    library.append(MusicTrackRef(
                        persistentID: id,
                        name: file.deletingPathExtension().lastPathComponent,
                        locationPath: file.path,
                        durationSeconds: 3.0))
                }
                return id
            }
        }

        var searchCallTotal: Int {
            lock.withLock { searchCallCount }
        }
    }

    // MARK: - 1. Fixture shape, recursive discovery, metadata preservation

    func test_fixtureShape_recursiveDiscovery_andMetadataPreservation() async throws {
        // Album selection + recursive discovery: exactly 4 album dirs
        // with the settled census (12/10/10/8); the nested CD1/CD2 of
        // Paper Lanterns is only reachable through a recursive walk.
        let (files, _) = try buildFourAlbumFixture()
        let root = FourAlbumAcceptanceTests.fixtureRoot(work: work)

        let albums = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.hasDirectoryPath }
            .map { $0.lastPathComponent }
            .sorted()
        XCTAssertEqual(albums, FourAlbumAcceptanceTests.albumCensus.map { $0.0 },
                       "the four album directories must be selectable and complete")

        let discovered = try FourAlbumAcceptanceTests.enumerateFLACs(in: root)
        XCTAssertEqual(discovered.count, 40, "recursive discovery must find all 40 FLACs")
        XCTAssertEqual(Set(discovered.map { $0.path }), Set(files.map { $0.path }))
        for (dir, count) in FourAlbumAcceptanceTests.albumCensus {
            let inAlbum = discovered.filter { $0.path.contains("/\(dir)/") }
            XCTAssertEqual(inAlbum.count, count, "album \(dir) must hold exactly \(count) tracks")
        }
        let nested = discovered.filter { $0.path.contains("/02 Paper Lanterns/CD2/") }
        XCTAssertEqual(nested.count, 5,
                       "the nested disc subdir proves the walk is recursive")

        // Fixture validity: 40 distinct real FLAC bitstreams.
        var hashes: Set<String> = []
        for url in discovered {
            let hash = LocalImportEngine.sha256Hex(fileURL: url)
            XCTAssertNotNil(hash, "every fixture file must be hashable: \(url.path)")
            hashes.insert(hash!)
        }
        XCTAssertEqual(hashes.count, 40, "all 40 recordings must be distinct bitstreams")

        // Metadata preservation: all six vorbis axes load exactly as
        // authored, for every one of the 40 (the GAP B mapping).
        let specsByPath = Dictionary(uniqueKeysWithValues:
            FourAlbumAcceptanceTests.trackSpecs().map {
                (FourAlbumAcceptanceTests.relativeKey($0), $0)
            })
        for url in discovered {
            let rel = url.path.lowercased()
                .replacingOccurrences(of: root.path.lowercased() + "/", with: "")
            let spec = specsByPath[rel]
            XCTAssertNotNil(spec, "unexpected fixture file: \(rel)")
            let loaded = await MusicImportEngine.loadCandidateTags(file: url)
            XCTAssertEqual(loaded?.tags?.title, spec?.title, "title axis must survive: \(rel)")
            XCTAssertEqual(loaded?.tags?.artist, spec?.artist, "artist axis must survive: \(rel)")
            XCTAssertEqual(loaded?.tags?.album, spec?.album, "album axis must survive: \(rel)")
            XCTAssertEqual(loaded?.tags?.albumArtist, spec?.albumArtist,
                          "albumArtist axis must survive: \(rel)")
            XCTAssertEqual(loaded?.tags?.discNumber, spec?.disc,
                          "disc axis must survive: \(rel)")
            XCTAssertEqual(loaded?.tags?.trackNumber, spec?.track,
                          "vorbis 'n/total' TRACKNUMBER must self-load as the bare number: \(rel)")
        }
        // The six-axes census of the fixture itself.
        let specs = FourAlbumAcceptanceTests.trackSpecs()
        XCTAssertEqual(specs.count, 40)
        XCTAssertEqual(specs.filter { $0.existing != nil }.count, 13,
                       "the fixture must represent exactly 13 existing recordings")
        XCTAssertEqual(specs.filter { $0.existing == nil }.count, 27,
                       "the fixture must hold exactly 27 missing recordings")
        XCTAssertEqual(specs.filter { $0.existing == .hashTwin }.count, 4)
        XCTAssertEqual(specs.filter { $0.existing == .aacTwin }.count, 9)
    }

    // MARK: - 2. Run 1 honest counts + run 2 idempotency (the centerpiece)

    func test_run1_honestCounts_thenRun2Idempotency_noBlindReAdd() async throws {
        let (files, library) = try buildFourAlbumFixture()
        let fake = FourAlbumScriptingFake(library: library)
        let engine = MusicImportEngine(scripting: fake)
        let journal = MusicImportJournal(directory: work)

        let specs = FourAlbumAcceptanceTests.trackSpecs()
        func spec(for url: URL) -> TrackSpec {
            let rel = url.path.lowercased()
                .replacingOccurrences(
                    of: FourAlbumAcceptanceTests.fixtureRoot(work: work).path.lowercased() + "/",
                    with: "")
            return Dictionary(uniqueKeysWithValues: specs.map {
                (FourAlbumAcceptanceTests.relativeKey($0), $0)
            })[rel]!
        }
        let existingFiles = files.filter { spec(for: $0).existing != nil }
        let hashTwinFiles = files.filter { spec(for: $0).existing == .hashTwin }
        let aacTwinFiles = files.filter { spec(for: $0).existing == .aacTwin }
        let missingFiles = files.filter { spec(for: $0).existing == nil }
        XCTAssertEqual(existingFiles.count, 13)
        XCTAssertEqual(hashTwinFiles.count, 4)
        XCTAssertEqual(aacTwinFiles.count, 9)
        XCTAssertEqual(missingFiles.count, 27)

        // Originals snapshot (non-modification proof).
        let beforeHashes = files.map { LocalImportEngine.sha256Hex(fileURL: $0)! }
        let libraryPrefixBefore = Array(fake.library.prefix(13))

        // ---- Preflight survey: read-only duplicate detection evidence.
        var surveyKinds: [MusicLibraryCandidate.MatchKind: Int] = [:]
        for url in files {
            let survey = await engine.surveyFile(file: url)
            XCTAssertNotNil(survey, "a surveyable FLAC must never survey nil: \(url.path)")
            surveyKinds[survey?.matchKind ?? .undecodableCandidate, default: 0] += 1
        }
        XCTAssertEqual(surveyKinds[.noCandidate, default: 0], 27, "27 recordings are provably missing")
        XCTAssertEqual(surveyKinds[.exactDuplicate, default: 0], 4, "4 byte-identical library copies")
        XCTAssertEqual(surveyKinds[.verifiedExisting, default: 0], 9, "9 cross-format AAC twins verify")
        XCTAssertEqual(surveyKinds[.needsReview, default: 0], 0, "nothing ambiguous in the clean census")
        XCTAssertEqual(fake.addCalls.count, 0, "surveyFile is read-only")

        // ---- Run 1: the import itself.
        var outcomes: [MusicImportOutcome] = []
        for url in files {
            let outcome = await engine.importFile(file: url,
                                                  titleQuery: url.deletingPathExtension().lastPathComponent,
                                                  journal: journal,
                                                  priorRecords: [])
            outcomes.append(outcome)
        }

        // Honest 27-13-0-0-0 counts.
        func count(_ status: MusicImportOutcome.Status) -> Int {
            outcomes.filter { $0.status == status }.count
        }
        XCTAssertEqual(count(.imported), 27, "exactly the 27 missing recordings import")
        XCTAssertEqual(count(.skippedDuplicate), 13, "exactly the 13 existing recordings skip")
        XCTAssertEqual(count(.review), 0, "no ambiguous member in the clean census")
        XCTAssertEqual(count(.failed), 0, "every import/skip must resolve honestly")
        // The 13-skip split by proof kind.
        for outcome in outcomes where outcome.status == .skippedDuplicate {
            let isHashTwin = hashTwinFiles.map { $0.path }.contains(outcome.filePath)
            XCTAssertEqual(outcome.decision,
                           isHashTwin ? .skipExactDuplicate : .skipVerifiedExisting,
                           "skip evidence must carry its proof kind: \(outcome.filePath)")
            XCTAssertFalse(outcome.decision == .reviewRequired)
        }
        XCTAssertEqual(outcomes.filter { $0.decision == .skipExactDuplicate }.count, 4)
        XCTAssertEqual(outcomes.filter { $0.decision == .skipVerifiedExisting }.count, 9)
        // Evidence of successful import of missing tracks.
        let importedOutcomes = outcomes.filter { $0.status == .imported }
        XCTAssertEqual(Set(importedOutcomes.map { $0.filePath }),
                       Set(missingFiles.map { $0.path }),
                       "imported set must be exactly the provably-missing set")
        for outcome in importedOutcomes {
            XCTAssertEqual(outcome.persistentID, "ADDED123",
                           "every successful import carries the read-back persistent ID")
        }

        // 0 unintended duplicates: one add per missing file, no more.
        XCTAssertEqual(fake.addCalls.count, 27)
        XCTAssertEqual(Set(fake.addCalls.map { $0.file.path }),
                       Set(missingFiles.map { $0.path }),
                       "adds must target exactly the missing recordings")
        XCTAssertEqual(fake.addCalls.map { $0.file.path }.count,
                       Set(fake.addCalls.map { $0.file.path }).count,
                       "no file may be added twice")
        XCTAssertEqual(fake.library.count, 40, "library grew by exactly the 27 imports")

        // 0 existing library tracks modified: prefix element-wise intact.
        XCTAssertEqual(Array(fake.library.prefix(13)), libraryPrefixBefore,
                       "the 13 pre-existing library entries must be element-wise unchanged")

        // 0 original files modified.
        for (url, before) in zip(files, beforeHashes) {
            XCTAssertEqual(LocalImportEngine.sha256Hex(fileURL: url)!, before,
                           "the engine must never write to an import file: \(url.path)")
        }

        // Journal evidence: intent before write, verification after, in
        // deterministic append order; skips fabricate no records.
        let (records, _) = try journal.load()
        XCTAssertEqual(records.count, 54, "27 attempted + 27 verified, nothing for skips")
        XCTAssertEqual(records.filter { $0.state == .verified }.count, 27)
        XCTAssertEqual(records.filter { $0.state == .attempted }.count, 27)
        for (index, record) in records.enumerated() {
            XCTAssertEqual(record.sequence, index + 1,
                           "sequence is monotonic append order — intent before write")
            XCTAssertEqual(record.state, index % 2 == 0 ? .attempted : .verified,
                          "attempted/verified must alternate per import")
        }

        // ---- Run 2: same operation again (same simulated Music.app,
        // journal supplied as priorRecords, fresh engine instance).
        let addCallsBefore = fake.addCalls.count
        let searchesBefore = fake.searchQueries.count
        let recordsAfterRun1 = (try journal.load()).records
        let engine2 = MusicImportEngine(scripting: fake)

        var outcomes2: [MusicImportOutcome] = []
        for url in files {
            let outcome = await engine2.importFile(file: url,
                                                  titleQuery: url.deletingPathExtension().lastPathComponent,
                                                  journal: journal,
                                                  priorRecords: recordsAfterRun1)
            outcomes2.append(outcome)
        }
        func count2(_ status: MusicImportOutcome.Status) -> Int {
            outcomes2.filter { $0.status == status }.count
        }
        XCTAssertEqual(count2(.imported), 0, "0 newly imported on the second run")
        XCTAssertEqual(count2(.skippedDuplicate), 40, "every recording resolves to a skip")
        XCTAssertEqual(count2(.review), 0)
        XCTAssertEqual(count2(.failed), 0)
        XCTAssertEqual(fake.addCalls.count - addCallsBefore, 0,
                       "no blind re-add: the second run issues no adds")
        XCTAssertEqual(fake.searchQueries.count - searchesBefore, 13,
                       "only the 13 never-imported twins re-survey; the 27 prior-verified imports short-circuit BEFORE any survey")
        XCTAssertEqual(Set(fake.searchQueries.suffix(13)),
                       Set(existingFiles.map { spec(for: $0).title }),
                       "the re-surveys are exactly the 13 existing titles")
        // Prior-verified evidence: the 27 carry the journal's verified
        // persistent ID (no new survey, no add, decision skipExactDuplicate).
        let run2ByPath = Dictionary(uniqueKeysWithValues: outcomes2.map { ($0.filePath, $0) })
        for url in missingFiles {
            let outcome = run2ByPath[url.path]!
            XCTAssertEqual(outcome.status, .skippedDuplicate)
            XCTAssertEqual(outcome.decision, .skipExactDuplicate,
                           "prior verified imports skip as already-present")
            XCTAssertEqual(outcome.persistentID, "ADDED123",
                           "the skip carries the journaled verified persistent ID")
        }
        let (recordsAfterRun2, _) = try journal.load()
        XCTAssertEqual(recordsAfterRun2.count, 54,
                       "second-run skips fabricate no journal evidence")
        XCTAssertEqual(fake.library.count, 40, "no unrelated library changes")
    }

    // MARK: - 3. Adversarial review bucket: ambiguous stops for review

    func test_adversarialReviewBucket_ambiguousNeverImported_explicitResolutionImports() async throws {
        // Ambiguous members — same titles as library twins so the survey
        // FINDS them, but identity unprovable on some axis. They MUST
        // land in review (never auto-imported, never force-fit), and
        // only an explicit resolution may import one.
        let durTol = MusicImportEngine.metadataDurationToleranceSeconds
        XCTAssertEqual(durTol, 2.0, "tolerance is a named public contract")

        struct Adversarial {
            let file: String
            let album: String
            let albumArtist: String
            let duration: Double
            let twinAlbum: String
            let twinAlbumArtist: String
            let twinDuration: Double
            let twinHasLocation: Bool
        }
        let twins: [Adversarial] = [
            // Live version: different album AND duration far beyond tolerance.
            Adversarial(file: "live.flac", album: "Harbor Lights Live",
                        albumArtist: "The Ferries", duration: 8,
                        twinAlbum: "Harbor Lights", twinAlbumArtist: "The Ferries",
                        twinDuration: 3.0, twinHasLocation: true),
            // Remaster: same everything except the release (album axis).
            Adversarial(file: "remaster.flac", album: "Harbor Lights (2024 Remaster)",
                        albumArtist: "The Ferries", duration: 3,
                        twinAlbum: "Harbor Lights", twinAlbumArtist: "The Ferries",
                        twinDuration: 3.0, twinHasLocation: true),
            // Metadata collision: albumArtist axis differs.
            Adversarial(file: "guest.flac", album: "Harbor Lights",
                        albumArtist: "Various Guests", duration: 3,
                        twinAlbum: "Harbor Lights", twinAlbumArtist: "The Ferries",
                        twinDuration: 3.0, twinHasLocation: true),
            // Duration just beyond the tolerance band.
            Adversarial(file: "beyond.flac", album: "Harbor Lights",
                        albumArtist: "The Ferries", duration: 3,
                        twinAlbum: "Harbor Lights", twinAlbumArtist: "The Ferries",
                        twinDuration: 3.0 + 2.05, twinHasLocation: true),
            // Streaming twin: no file location, byte comparison impossible.
            Adversarial(file: "cloud.flac", album: "Harbor Lights",
                        albumArtist: "The Ferries", duration: 3,
                        twinAlbum: "Harbor Lights", twinAlbumArtist: "The Ferries",
                        twinDuration: 3.0, twinHasLocation: false),
            // Control at the inclusive boundary: |delta| == tolerance
            // verifies (documented inclusive band) — proving the review
            // bucket above is honest, not a blanket stop.
            Adversarial(file: "at-band.flac", album: "Harbor Lights",
                        albumArtist: "The Ferries", duration: 3,
                        twinAlbum: "Harbor Lights", twinAlbumArtist: "The Ferries",
                        twinDuration: 3.0 + durTol, twinHasLocation: true),
        ]

        let libraryFiles = work.appendingPathComponent("library-files", isDirectory: true)
        var library: [MusicTrackRef] = []
        var candidates: [URL] = []
        for (index, a) in twins.enumerated() {
            let title = "Harbor Lights Track \(String(format: "%02d", index + 1))"
            let flac = try makeRealFLAC(in: work, name: a.file, title: title,
                                        artist: "The Ferries", album: a.album,
                                        albumArtist: a.albumArtist, disc: 1,
                                        track: index + 1, trackTotal: 10,
                                        duration: a.duration)
            candidates.append(flac)
            let location: String?
            if a.twinHasLocation {
                let aac = try makeRealAAC(in: libraryFiles, name: "adv-\(index).m4a",
                                          duration: a.twinDuration)
                location = aac.path
            } else {
                location = nil
            }
            library.append(MusicTrackRef(
                persistentID: "ADV-\(index)", name: title, artist: "The Ferries",
                album: a.twinAlbum, albumArtist: a.twinAlbumArtist,
                discNumber: 1, trackNumber: index + 1,
                locationPath: location, durationSeconds: a.twinDuration))
        }

        let fake = FourAlbumScriptingFake(library: library)
        let engine = MusicImportEngine(scripting: fake)
        let journal = MusicImportJournal(directory: work)

        // Unresolved pass: the review bucket is exact and honest.
        var outcomes: [MusicImportOutcome] = []
        for url in candidates {
            let outcome = await engine.importFile(file: url,
                                                  titleQuery: url.deletingPathExtension().lastPathComponent,
                                                  journal: journal,
                                                  priorRecords: [])
            outcomes.append(outcome)
        }
        XCTAssertEqual(outcomes.filter { $0.status == .review }.count, 5,
                       "live/remaster/collision/beyond-tolerance/streaming must all stop for review")
        XCTAssertEqual(outcomes.filter { $0.status == .skippedDuplicate }.count, 1,
                       "the at-tolerance control verifies (inclusive band)")
        XCTAssertEqual(outcomes.filter { $0.status == .imported }.count, 0,
                       "ambiguous members are never auto-imported")
        XCTAssertEqual(outcomes.filter { $0.status == .failed }.count, 0)
        XCTAssertEqual(fake.addCalls.count, 0, "no write may issue for an unresolved review")
        let (midRecords, _) = try journal.load()
        XCTAssertTrue(midRecords.isEmpty,
                      "an unresolved review fabricates no journal evidence")
        for (index, outcome) in outcomes.enumerated() where outcome.status == .review {
            XCTAssertEqual(outcome.decision, .reviewRequired)
            XCTAssertEqual(outcome.reviewCandidates.first?.persistentID, "ADV-\(index)",
                           "review carries the conflicting library twin as evidence")
        }

        // Explicit resolution imports exactly the resolved file as its
        // own recording — the human-in-the-loop write gate.
        let live = candidates[0]
        let resolved = await engine.importFile(file: live,
                                               titleQuery: live.deletingPathExtension().lastPathComponent,
                                               journal: journal,
                                               priorRecords: [],
                                               reviewResolved: true)
        XCTAssertEqual(resolved.status, .imported,
                       "after explicit resolution the ambiguous member imports as its own recording")
        XCTAssertEqual(fake.addCalls.count, 1)
        let (records, _) = try journal.load()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].state, .attempted, "intent recorded BEFORE the write")
        XCTAssertEqual(records[1].state, .verified)
        XCTAssertEqual(fake.library.count, library.count + 1)
    }
}
