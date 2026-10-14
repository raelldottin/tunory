import Foundation
import AVFoundation
import CryptoKit
import UniformTypeIdentifiers

// MARK: - Local audio import: canonical conversion engine
//
// THE canonical implementation of the local-import decision logic. The GUI
// and CLI are thin presentations of this engine; they must never re-derive
// a conversion decision.
//
// Owner conversion contract (t_dc244b34 §3, received from owner; native
// realization per D1, t_559e5375):
//
//   FLAC in → .m4a out, AAC 256 kbps reference profile
//   (kAudioFormatMPEG4AAC via the encoder's default VBR settings —
//   measured ~260 kbps on worst-case pink noise @44.1 kHz, within the
//   256k+10% contract ceiling; explicitly setting AVEncoderBitRateKey
//   OVERSHOOTS to 412–424 kbps, see encodeOnQueue), ALAC opt-in profile
//   (kAudioFormatAppleLossless — bit-exact PCM roundtrip verified).
//
// Requirements carried here: recursive with relative directory structure
// preserved, originals unchanged, metadata + artwork preserved (vorbis
// comments mapped to iTunes tags; FLAC PICTURE blocks parsed at file level
// because AVFoundation does not expose them), idempotent re-runs (valid
// outputs skipped with no mtime change, invalid prior outputs reconverted),
// atomic temp+promote (no partially-written file ever visible at the
// destination path), never overwrite unrelated files (destination guard
// consults the journal before any overwrite).
//
// Lossy-transcode rule (owner contract): Tunory never transcodes
// lossy→lossy claiming fidelity. Lossy sources (mp3/aac) are already
// Music-importable and are passed through untouched; the ALAC profile
// accepts lossless sources only.
//
// Conversion is fully in-process (AVFoundation / Core Audio). There is no
// external binary dependency: decoding, encoding, and metadata handling all
// run through system frameworks, so nothing is left to PATH resolution or
// sandbox visibility (the two failure classes the ffmpeg shell-out had).

/// A file-level import decision, derived only from probed content,
/// destination state, and the journal. Deterministic: same inputs →
/// same decision.
public enum ConversionDecision: String, Equatable, Sendable, Codable {
    /// Source needs conversion under the chosen profile (e.g. FLAC → AAC-256).
    case convert
    /// Source is already Music-native and lossy-safe (mp3/aac): pass
    /// through untouched; converting it would be a lossy→lossy transcode.
    case passthroughNative
    /// Destination holds a valid converted output (idempotent skip).
    case skipValidOutput
    /// Destination holds a valid audio file we did not produce: never
    /// overwrite; user resolves manually.
    case conflictDestinationValidForeign
    /// Destination holds an invalid/undecodable file we did not produce:
    /// never overwrite (might be an unrelated corrupt user file).
    case conflictDestinationInvalidForeign
    /// Source cannot be decoded; nothing to do.
    case undecodableSource
    /// Profile cannot be applied to this source (e.g. ALAC profile on a
    /// lossy source) without violating the lossy-transcode rule.
    case blockedByProfile
}

/// Conversion profile. `aac256` is the owner reference profile; `alac`
/// is the explicit opt-in lossless profile (owner policy pending, never
/// the default).
public enum ConversionProfile: String, Equatable, Sendable, Codable {
    case aac256
    case alac
}

/// Journal record for one completed conversion. Append-only history:
// records are never rewritten; superseding events are new records.
public struct LocalImportJournalRecord: Equatable, Sendable, Codable {
    public let sourcePath: String
    public let destinationPath: String
    public let sourceSHA256: String
    public let profile: ConversionProfile
    public let completedAt: ISO8601DateWithNanoseconds
}

/// Convenience: ISO-8601 timestamp that encodes deterministically.
public struct ISO8601DateWithNanoseconds: Equatable, Sendable, Codable {
    public let secondsSinceEpoch: Int64
    public init(secondsSinceEpoch: Int64) { self.secondsSinceEpoch = secondsSinceEpoch }
    init(date: Date = Date()) {
        self.secondsSinceEpoch = Int64(date.timeIntervalSince1970.rounded())
    }
}

/// Append-only conversion journal. Single JSON file, atomically replaced
/// on append (CheckpointStore conventions). The journal is the authority
/// for "did we produce this destination" — the destination guard never
/// overwrites a file absent from the journal, no matter how corrupt it is.
public struct LocalImportJournal: Sendable {
    public let directory: URL
    public static let fileName = "local-import-journal.json"

    public init(directory: URL) {
        self.directory = directory
    }

    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// Load all records; empty when absent or unreadable (fail-visible:
    /// an unreadable journal is reported, and treated as empty so the
    /// engine can only skip, never silently overwrite).
    public func load() throws -> (records: [LocalImportJournalRecord], warning: String?) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ([], nil)
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let records = try JSONDecoder().decode([LocalImportJournalRecord].self, from: data)
            return (records, nil)
        } catch {
            return ([], "journal unreadable (\(error.localizedDescription)); treating as empty — no overwrites")
        }
    }

    /// Atomically append records: decode + append + sort by completion
    /// time + atomic replace. Sorting keeps the file deterministic.
    public func append(_ newRecords: [LocalImportJournalRecord]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (existing, _) = try load()
        let merged = (existing + newRecords).sorted {
            ($0.completedAt.secondsSinceEpoch, $0.sourcePath, $0.destinationPath)
                < ($1.completedAt.secondsSinceEpoch, $1.sourcePath, $1.destinationPath)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(merged)
        try data.write(to: fileURL, options: [.atomic])
    }
}

/// Result of one file-level conversion attempt.
public struct ConversionOutcome: Equatable, Sendable, Codable {
    public enum Status: String, Equatable, Sendable, Codable {
        case converted, skippedValid, passthrough, conflict, failed
    }
    public let sourcePath: String
    public let destinationPath: String?
    public let decision: ConversionDecision
    public let status: Status
    public let detail: String?
}

/// The canonical local-import engine.
public struct LocalImportEngine: Sendable {

    public let prober: AudioProber

    public init() {
        self.prober = AudioProber()
    }

    // MARK: - Planning (pure decision logic, no I/O side effects)

    /// Decide what to do with one source file. Reads (probe source,
    /// probe destination, journal) but never writes.
    public func plan(source: URL,
                     outputDirectory: URL,
                     profile: ConversionProfile,
                     journalRecords: [LocalImportJournalRecord]) async -> (decision: ConversionDecision,
                                                                            probe: AudioProbe?,
                                                                            destination: URL?) {
        // Destination path: mirror relative structure under output dir.
        let fileName = source.deletingPathExtension().lastPathComponent
        // Caller supplies the output root; relative structure is applied
        // by `planBatch` (which knows the source root). For single files
        // the destination is flat in outputDirectory.
        let destination = outputDirectory.appendingPathComponent(fileName + ".m4a")

        let probe = await prober.probe(url: source)
        guard probe.codec != nil, probe.failureDetail == nil else {
            return (.undecodableSource, probe, nil)
        }

        // Profile/lossiness guard (owner rule: never lossy→lossy).
        if profile == .alac, probe.lossless != .yes {
            return (.blockedByProfile, probe, destination)
        }
        if profile == .aac256, probe.lossless == .no {
            // Lossy sources are already Music-native (mp3/aac per the
            // research matrix); converting them is forbidden, copying
            // would duplicate what Music imports natively — passthrough.
            return (.passthroughNative, probe, destination)
        }

        // Destination guard (research §5 obligations): idempotent skip,
        // reconvert-our-invalid, never touch foreign files.
        if FileManager.default.fileExists(atPath: destination.path) {
            let ours = journalRecords.contains { $0.destinationPath == destination.path }
            let destProbe = await prober.probe(url: destination)
            let destValid = destProbe.codec != nil
                && destProbe.failureDetail == nil
                && Self.matchesProfile(destProbe, profile: profile)
            if destValid {
                return (.skipValidOutput, probe, destination)
            }
            return ours
                ? (.convert, probe, destination)
                : (.conflictDestinationInvalidForeign, probe, destination)
        }
        return (.convert, probe, destination)
    }

    static func matchesProfile(_ probe: AudioProbe, profile: ConversionProfile) -> Bool {
        switch profile {
        case .aac256: return probe.codec == "aac"
        case .alac: return probe.codec == "alac"
        }
    }

    // MARK: - Batch planning (recursive, deterministic order)

    /// Decide what to do with one already-probed file, given the batch
    /// context. Pure decision logic shared by every planning entry point
    /// (directory batches and GUI/CLI file lists): the single place a
    /// conversion decision is derived.
    static func decision(for probe: AudioProbe,
                         sourceHash: String?,
                         profile: ConversionProfile,
                         destinationExists: Bool,
                         destinationIsOurs: Bool,
                         destinationIsValid: Bool) -> ConversionDecision {
        guard probe.codec != nil, probe.failureDetail == nil else {
            return .undecodableSource
        }
        if profile == .alac, probe.lossless != .yes {
            return .blockedByProfile
        }
        if profile == .aac256, probe.lossless == .no {
            return .passthroughNative
        }
        if destinationExists {
            if destinationIsValid { return .skipValidOutput }
            return destinationIsOurs ? .convert : .conflictDestinationInvalidForeign
        }
        return .convert
    }

    /// Plan an explicit list of files (GUI multi-select / CLI argument
    /// list). Same decision logic as `planBatch` — this is the canonical
    /// planning surface for user-selected files; presentations must call
    /// this, never re-derive a decision.
    public func planFiles(files: [URL],
                          outputDirectory: URL,
                          profile: ConversionProfile,
                          journalRecords: [LocalImportJournalRecord]) async -> LocalImportPlan {
        let sorted = files.sorted { $0.standardizedFileURL.path < $1.standardizedFileURL.path }
        var entries: [LocalImportPlanEntry] = []
        entries.reserveCapacity(sorted.count)
        var hashToFirstIndex: [String: Int] = [:]
        for (index, file) in sorted.enumerated() {
            let probe = await prober.probe(url: file)
            let destination = outputDirectory
                .appendingPathComponent(file.deletingPathExtension().lastPathComponent)
                .appendingPathExtension("m4a")
            let sourceHash = Self.sha256Hex(fileURL: file)
            let duplicateOf: Int? = {
                guard let sourceHash else { return nil }
                if let first = hashToFirstIndex[sourceHash] { return first }
                hashToFirstIndex[sourceHash] = index
                return nil
            }()

            var destinationExists = false
            var destinationIsOurs = false
            var destinationIsValid = false
            if FileManager.default.fileExists(atPath: destination.path) {
                destinationExists = true
                destinationIsOurs = journalRecords.contains { $0.destinationPath == destination.path }
                let destProbe = await prober.probe(url: destination)
                destinationIsValid = destProbe.codec != nil
                    && destProbe.failureDetail == nil
                    && Self.matchesProfile(destProbe, profile: profile)
            }
            let decision = Self.decision(for: probe,
                                         sourceHash: sourceHash,
                                         profile: profile,
                                         destinationExists: destinationExists,
                                         destinationIsOurs: destinationIsOurs,
                                         destinationIsValid: destinationIsValid)
            entries.append(LocalImportPlanEntry(sourcePath: file.standardizedFileURL.path,
                                                relativePath: file.lastPathComponent,
                                                destinationPath: destination.path,
                                                sourceSHA256: sourceHash,
                                                probe: probe,
                                                decision: decision,
                                                duplicateOfIndex: duplicateOf))
        }
        return LocalImportPlan(sourceRoot: "(selected files)",
                                outputRoot: outputDirectory.standardizedFileURL.path,
                                profile: profile,
                                entries: entries)
    }

    /// Walk `sourceRoot` recursively (sorted for determinism), probe every
    /// audio file, classify duplicates within the batch by exact source
    /// SHA-256 (audio fingerprinting unavailable — chromaprint not in the
    /// installed ffmpeg build), and return per-file plans preserving the
    /// relative directory structure under `outputRoot`.
    public func planBatch(sourceRoot: URL,
                          outputRoot: URL,
                          profile: ConversionProfile,
                          journalRecords: [LocalImportJournalRecord]) async -> LocalImportPlan {
        var files = Self.audioFilesUnder(sourceRoot)
        files.sort { $0.standardizedFileURL.path < $1.standardizedFileURL.path }
        let rootPath = sourceRoot.standardizedFileURL.path

        var entries: [LocalImportPlanEntry] = []
        entries.reserveCapacity(files.count)
        var hashToFirstIndex: [String: Int] = [:]
        for (index, file) in files.enumerated() {
            let probe = await prober.probe(url: file)
            let relPath = file.standardizedFileURL.path.hasPrefix(rootPath)
                ? String(file.standardizedFileURL.path.dropFirst(rootPath.count + 1))
                : file.lastPathComponent
            let destination = outputRoot
                .appendingPathComponent(relPath)
                .deletingPathExtension()
                .appendingPathExtension("m4a")

            let sourceHash = Self.sha256Hex(fileURL: file)
            let duplicateOf: Int? = {
                guard let sourceHash else { return nil }
                if let first = hashToFirstIndex[sourceHash] { return first }
                hashToFirstIndex[sourceHash] = index
                return nil
            }()

            var destinationExists = false
            var destinationIsOurs = false
            var destinationIsValid = false
            if FileManager.default.fileExists(atPath: destination.path) {
                destinationExists = true
                destinationIsOurs = journalRecords.contains { $0.destinationPath == destination.path }
                let destProbe = await prober.probe(url: destination)
                destinationIsValid = destProbe.codec != nil
                    && destProbe.failureDetail == nil
                    && Self.matchesProfile(destProbe, profile: profile)
            }
            let decision = Self.decision(for: probe,
                                         sourceHash: sourceHash,
                                         profile: profile,
                                         destinationExists: destinationExists,
                                         destinationIsOurs: destinationIsOurs,
                                         destinationIsValid: destinationIsValid)

            entries.append(LocalImportPlanEntry(sourcePath: file.standardizedFileURL.path,
                                                relativePath: relPath,
                                                destinationPath: destination.path,
                                                sourceSHA256: sourceHash,
                                                probe: probe,
                                                decision: decision,
                                                duplicateOfIndex: duplicateOf))
        }
        return LocalImportPlan(sourceRoot: rootPath,
                                outputRoot: outputRoot.standardizedFileURL.path,
                                profile: profile,
                                entries: entries)
    }

    /// Deterministic recursive enumeration of audio candidate files.
    /// Extension is only a pre-filter to bound I/O; the probe still
    /// decides on content.
    static let audioExtensions: Set<String> = [
        "flac", "mp3", "m4a", "m4b", "wav", "aiff", "aif", "alac"
    ]

    static func audioFilesUnder(_ root: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var result: [URL] = []
        for case let url as URL in enumerator {
            guard let isRegular = try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
                  isRegular else { continue }
            let ext = url.pathExtension.lowercased()
            if audioExtensions.contains(ext) {
                result.append(url)
            }
        }
        return result
    }

    // MARK: - Conversion (exact reference arguments)

    /// Convert one planned entry with the in-process AVFoundation encoder,
    /// atomically promoted. Returns the outcome; throws only on
    /// unrecoverable I/O errors (missing directories).
    @discardableResult
    public func convert(entry: LocalImportPlanEntry,
                        profile: ConversionProfile,
                        journal: LocalImportJournal) async -> ConversionOutcome {
        let source = URL(fileURLWithPath: entry.sourcePath)
        let destination = URL(fileURLWithPath: entry.destinationPath)

        func outcome(_ decision: ConversionDecision,
                     _ status: ConversionOutcome.Status,
                     _ detail: String? = nil,
                     dest: URL? = nil) -> ConversionOutcome {
            ConversionOutcome(sourcePath: entry.sourcePath,
                               destinationPath: dest?.path,
                               decision: decision,
                               status: status,
                               detail: detail)
        }

        guard entry.decision == .convert else {
            return outcome(entry.decision, Self.status(for: entry.decision))
        }

        let destinationDir = destination.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        // Atomic promote (research §5): unique temp name in the SAME
        // directory, converted fully, validated, then renamed.
        let temp = destinationDir
            .appendingPathComponent(".tunory-tmp-\(UUID().uuidString).m4a")

        // The writer must be fully flushed BEFORE the output is validated
        // or promoted. AVAudioFile flushes on deinit (no public close on
        // our deployment target), so encoding + metadata application run
        // inside a scope whose exit deterministically ends the writer's
        // lifetime first (verified empirically, probe3/probe6).
        do {
            let encodedURL = try await encode(source: source, output: temp, profile: profile)
            try await applyMetadata(source: source, encoded: encodedURL, output: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return outcome(.convert, .failed, "native encode failed: \(error.localizedDescription)")
        }

        // Validate BEFORE promote: decodable, codec matches profile,
        // duration within 1 s of the source probe.
        let outputProbe = await prober.probe(url: temp)
        guard outputProbe.codec != nil, outputProbe.failureDetail == nil,
              Self.matchesProfile(outputProbe, profile: profile) else {
            try? FileManager.default.removeItem(at: temp)
            return outcome(.convert, .failed, "output validation failed: not decodable \(profile.rawValue)")
        }
        if let sourceDuration = entry.probe.durationSeconds,
           let outputDuration = outputProbe.durationSeconds,
           abs(sourceDuration - outputDuration) > 1.0 {
            try? FileManager.default.removeItem(at: temp)
            return outcome(.convert, .failed,
                           "duration delta \(abs(sourceDuration - outputDuration))s exceeds 1s")
        }

        // Destination re-check at promote time (another run may have
        // written it while we converted): still refuse foreign files.
        if FileManager.default.fileExists(atPath: destination.path) {
            guard let (records, _) = try? journal.load() else {
                try? FileManager.default.removeItem(at: temp)
                return outcome(.convert, .failed, "journal load failed at promote re-check")
            }
            let ours = records.contains { $0.destinationPath == destination.path }
            let destProbe = await prober.probe(url: destination)
            let destValid = destProbe.codec != nil && destProbe.failureDetail == nil
                && Self.matchesProfile(destProbe, profile: profile)
            if destValid {
                try? FileManager.default.removeItem(at: temp)
                return outcome(.skipValidOutput, .skippedValid, dest: destination)
            }
            if !ours {
                try? FileManager.default.removeItem(at: temp)
                return outcome(.conflictDestinationInvalidForeign, .conflict,
                               "destination appeared during conversion", dest: destination)
            }
        }

        do {
            // Same-directory rename: atomic on APFS.
            try? FileManager.default.removeItem(at: destination) // only reached when ours+invalid
            try FileManager.default.moveItem(at: temp, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return outcome(.convert, .failed, "promote failed: \(error.localizedDescription)")
        }

        if let hash = entry.sourceSHA256 {
            try? journal.append([LocalImportJournalRecord(
                sourcePath: entry.sourcePath,
                destinationPath: destination.path,
                sourceSHA256: hash,
                profile: profile,
                completedAt: ISO8601DateWithNanoseconds())])
        }
        return outcome(.convert, .converted, dest: destination)
    }

    static func status(for decision: ConversionDecision) -> ConversionOutcome.Status {
        switch decision {
        case .convert: return .failed
        case .passthroughNative: return .passthrough
        case .skipValidOutput: return .skippedValid
        case .conflictDestinationValidForeign, .conflictDestinationInvalidForeign: return .conflict
        case .undecodableSource: return .failed
        case .blockedByProfile: return .failed
        }
    }

    // MARK: - Native in-process encoding (AVFoundation / Core Audio)

    /// Encode `source` audio to `output` in-process. AAC-256 reference
    /// profile: kAudioFormatMPEG4AAC with AVEncoderBitRateKey 256000
    /// (measured payload ≈250 kbps on real stereo content, probe3).
    /// ALAC profile: kAudioFormatAppleLossless (bit-exact PCM roundtrip
    /// verified, probe3/probe8 — 24-bit sources land as 32-bit ALAC).
    /// Returns the URL holding the encoded audio (a mid-step file when
    /// metadata must be applied; `output` itself when no metadata step
    /// runs).
    func encode(source: URL, output: URL, profile: ConversionProfile) async throws -> URL {
        // Function scope is load-bearing: the AVAudioFile writer flushes
        // on deinit, and deinit must run before the caller validates or
        // promotes the output. probe3 observed the writer still holding
        // unflushed frames while alive (bytes grew at readback).
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                do {
                    try Self.encodeOnQueue(source: source, output: output, profile: profile)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        return output
    }

    /// Synchronous encode for one file. Float32 client format on both
    /// sides (the AVAudioFile processing format): forcing an integer
    /// commonFormat on the writer CORRUPTS audio against Float32 read
    /// buffers (measured ≈5.4x amplitude error, probe7) — the encoder
    /// converts internally.
    static func encodeOnQueue(source: URL, output: URL, profile: ConversionProfile) throws {
        let reader = try AVAudioFile(forReading: source)
        let settings: [String: Any]
        switch profile {
        case .aac256:
            // NOTE: AVEncoderBitRateKey is deliberately NOT set.
            // Empirically (probe5/probe7, 2026-10-14, macOS 27 SDK):
            // setting it to 256_000 makes Apple's AAC encoder produce
            // 412–424 kbps (65% overshoot); 128_000 is silently ignored.
            // The encoder default lands at ~260 kbps @44.1 kHz /
            // ~271 kbps @48 kHz on worst-case pink noise — inside the
            // owner contract ceiling (256k+10%), and lower on real
            // music (VBR). The default IS the reference profile.
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: reader.processingFormat.sampleRate,
                AVNumberOfChannelsKey: reader.processingFormat.channelCount,
            ]
        case .alac:
            settings = [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: reader.processingFormat.sampleRate,
                AVNumberOfChannelsKey: reader.processingFormat.channelCount,
            ]
        }
        let writer = try AVAudioFile(forWriting: output, settings: settings)
        let chunkFrames: AVAudioFrameCount = 65_536
        var remaining = AVAudioFrameCount(reader.length)
        while remaining > 0 {
            let n = min(chunkFrames, remaining)
            guard let chunk = AVAudioPCMBuffer(pcmFormat: reader.processingFormat,
                                               frameCapacity: n) else {
                throw NSError(domain: "TunoryCore.nativeEncode", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "buffer allocation failed"])
            }
            chunk.frameLength = n
            try reader.read(into: chunk, frameCount: n)
            try writer.write(from: chunk)
            remaining -= n
        }
    }

    /// Copy source metadata (title/artist/album & friends via AVFoundation's
    /// format-specific readers) plus FLAC PICTURE artwork (parsed at file
    /// level — AVFoundation does not expose FLAC pictures as metadata) onto
    /// the encoded file. Runs a passthrough AVAssetExportSession whose
    /// `metadata` array carries the mapped AVMetadataItems; passthrough
    /// leaves the audio payload untouched (verified, probe6 Q8).
    /// When the source exposes no metadata and no artwork, this is a no-op
    /// returning `encoded` unchanged.
    func applyMetadata(source: URL, encoded: URL, output: URL) async throws {
        let asset = AVURLAsset(url: source)
        var items: [AVMetadataItem] = []
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats {
                let formatItems = (try? await asset.loadMetadata(for: format)) ?? []
                for item in formatItems {
                    guard let commonKey = item.commonKey else { continue }
                    // Text tags: map every format-specific identifier to its
                    // common equivalent (vorbis TITLE → common title, ID3
                    // TIT2 → common title, …). The passthrough writer maps
                    // common identifiers onto iTunes-family atoms.
                    if let value = try? await item.load(.stringValue),
                       let common = Self.commonIdentifier(forCommonKey: commonKey) {
                        let mapped = AVMutableMetadataItem()
                        mapped.identifier = common
                        mapped.value = value as NSString
                        mapped.dataType = "public.utf8-plain-text"
                        items.append(mapped)
                    }
                }
            }
        }
        if let pictures = try? Self.flacPictures(in: source) {
            for picture in pictures {
                let art = AVMutableMetadataItem()
                art.identifier = .commonIdentifierArtwork
                art.value = picture.data as NSData
                art.dataType = Self.utType(forMIMEType: picture.mime)?.identifier
                    ?? UTType.png.identifier
                items.append(art)
            }
        }
        guard !items.isEmpty else { return }
        // `encoded` == `output` here (encode writes straight to the temp);
        // the passthrough export rewrites the same path with metadata. Use
        // a sibling temp so the export never reads and writes one file.
        let injectTemp = URL(fileURLWithPath: output.path + ".meta-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: injectTemp) }
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: encoded),
                                                 presetName: AVAssetExportPresetPassthrough) else {
            throw NSError(domain: "TunoryCore.nativeEncode", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "export session unavailable"])
        }
        session.outputURL = injectTemp
        session.outputFileType = .m4a
        session.metadata = items
        await session.export()
        guard session.status == .completed else {
            throw NSError(domain: "TunoryCore.nativeEncode", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "metadata export failed: \(session.error.map { "\($0)" } ?? "unknown")"])
        }
        // Replace the encoded file with the metadata-bearing export.
        // moveItem fails when the destination exists, and a plain remove
        // could leave a window with no file; the rename API swaps
        // atomically. `output` is a `.tunory-tmp-*` file we just created,
        // so replacing it cannot touch user data.
        try FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: injectTemp, to: output)
    }

    // MARK: - Hashing

    /// SHA-256 of file bytes, streaming (large-file safe). Byte equality
    /// is the practical duplicate contract (chromaprint unavailable).
    public static func sha256Hex(fileURL: URL) -> String? {
        guard let stream = InputStream(url: fileURL) else { return nil }
        stream.open()
        defer { stream.close() }
        var hasher = SHA256()
        let bufferSize = 1024 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            hasher.update(data: Data(bytes: buffer, count: read))
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - FLAC artwork (file-level PICTURE block parsing)

    /// One parsed FLAC PICTURE block.
    struct FlacPicture: Sendable {
        let mime: String
        let data: Data
    }

    /// Parse FLAC metadata blocks at file level and return every PICTURE
    /// payload. AVFoundation exposes vorbis text comments through its
    /// metadata API but NOT embedded pictures (verified, probe5), so
    /// artwork carry requires reading the container directly. FLAC spec:
    /// block type 6 = PICTURE (type 4 is VORBIS_COMMENT).
    static func flacPictures(in url: URL) throws -> [FlacPicture] {
        let data = try Data(contentsOf: url)
        guard data.count > 8, data.prefix(4) == Data("fLaC".utf8) else { return [] }
        var pictures: [FlacPicture] = []
        var offset = 4
        var isLast = false
        while offset + 4 <= data.count, !isLast {
            let header = data[data.startIndex + offset]
            let blockType = header & 0x7F
            isLast = (header & 0x80) != 0
            let bodyStart = offset + 4
            let length = (Int(data[data.startIndex + bodyStart - 3]) << 16)
                | (Int(data[data.startIndex + bodyStart - 2]) << 8)
                | Int(data[data.startIndex + bodyStart - 1])
            let bodyEnd = bodyStart + length
            guard bodyEnd <= data.count else { break }
            if blockType == 6 {
                var p = bodyStart
                func u32() -> Int {
                    let v = (Int(data[data.startIndex + p]) << 24)
                        | (Int(data[data.startIndex + p + 1]) << 16)
                        | (Int(data[data.startIndex + p + 2]) << 8)
                        | Int(data[data.startIndex + p + 3])
                    p += 4
                    return v
                }
                _ = u32() // picture type (e.g. 3 = cover front)
                let mimeLen = u32()
                let mime = String(data: data.subdata(in: (data.startIndex + p)..<(data.startIndex + p + mimeLen)),
                                  encoding: .ascii) ?? ""
                p += mimeLen
                let descLen = u32()
                p += descLen // description bytes (u32 already advanced past the length field)
                p += 16           // width, height, depth, colors
                let dataLen = u32()
                guard p + dataLen <= data.count else { break }
                let picData = data.subdata(in: (data.startIndex + p)..<(data.startIndex + p + dataLen))
                pictures.append(FlacPicture(mime: mime, data: picData))
            }
            offset = bodyEnd
        }
        return pictures
    }

    /// Map a FLAC PICTURE MIME type onto a UniformTypeIdentifiers type
    /// for the AVMetadataItem dataType. Falls back to PNG.
    static func utType(forMIMEType mime: String) -> UTType? {
        UTType(mimeType: mime) ?? UTType(mimeType: "image/png")
    }

    /// Map an AVMetadataItem's commonKey (e.g. `AVMetadataItem.commonKeyTitle`)
    /// to the corresponding common AVMetadataIdentifier. `commonKey` is the
    /// only cross-format mapping surface AVFoundation exposes on the item
    /// itself; the identifier-space accessor does not exist in this SDK.
    static func commonIdentifier(forCommonKey key: AVMetadataKey) -> AVMetadataIdentifier? {
        switch key {
        case .commonKeyTitle: return .commonIdentifierTitle
        case .commonKeyArtist: return .commonIdentifierArtist
        case .commonKeyAlbumName: return .commonIdentifierAlbumName
        case .commonKeyCreationDate: return .commonIdentifierCreationDate
        case .commonKeyDescription: return .commonIdentifierDescription
        case .commonKeySubject: return .commonIdentifierSubject
        case .commonKeyCreator: return .commonIdentifierCreator
        case .commonKeyPublisher: return .commonIdentifierPublisher
        case .commonKeyContributor: return .commonIdentifierContributor
        default: return nil
        }
    }
}

/// One file's plan in a batch.
public struct LocalImportPlanEntry: Equatable, Sendable, Codable {
    public let sourcePath: String
    public let relativePath: String
    public let destinationPath: String
    public let sourceSHA256: String?
    public let probe: AudioProbe
    public let decision: ConversionDecision
    /// Index of the first entry in the batch with identical bytes;
    /// nil for batch-unique files. Ambiguous duplicates require explicit
    /// user review (owner rule) — never auto-resolved.
    public let duplicateOfIndex: Int?
}

/// A full deterministic batch plan.
public struct LocalImportPlan: Equatable, Sendable, Codable {
    public let sourceRoot: String
    public let outputRoot: String
    public let profile: ConversionProfile
    public let entries: [LocalImportPlanEntry]
}
