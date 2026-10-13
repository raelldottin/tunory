import Foundation
import AVFoundation
import CryptoKit

// MARK: - Local audio import: canonical conversion engine
//
// THE canonical implementation of the local-import decision logic. The GUI
// and CLI are thin presentations of this engine; they must never re-derive
// a conversion decision.
//
// Owner conversion contract (t_dc244b34 §3, received from owner):
//
//   ffmpeg -nostdin -hide_banner -loglevel error \
//     -i INPUT -map 0:a:0 -map 0:v? -map_metadata 0 \
//     -c:a aac -b:a 256k -c:v copy -disposition:v attached_pic \
//     OUTPUT.m4a
//
// Requirements carried here: FLAC in → .m4a out, AAC 256 kbps reference
// profile, recursive with relative directory structure preserved, originals
// unchanged, metadata + artwork preserved, idempotent re-runs (valid
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
// FFmpeg is an external system dependency (runtime presence check per
// research §5; the Homebrew build is not redistributable and is never
// bundled). afconvert is NOT a viable substitute (drops tags + artwork).

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

    public let ffmpegURL: URL
    public let prober: AudioProber

    /// - Parameter ffmpegURL: explicit ffmpeg location. When nil, the
    /// engine resolves `ffmpeg` via the user PATH; `nil` result means
    /// the dependency is absent and every conversion decision fails
    /// visibly with `ffmpegMissing`.
    public init(ffmpegURL: URL? = nil) {
        if let ffmpegURL {
            self.ffmpegURL = ffmpegURL
        } else {
            self.ffmpegURL = Self.resolveFFmpegInPATH() ?? URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        }
        self.prober = AudioProber()
    }

    public var ffmpegPresent: Bool {
        FileManager.default.isExecutableFile(atPath: ffmpegURL.path)
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
        let containerDir = source.deletingLastPathComponent()
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

            let decision: ConversionDecision
            if probe.codec == nil || probe.failureDetail != nil {
                decision = .undecodableSource
            } else if profile == .alac, probe.lossless != .yes {
                decision = .blockedByProfile
            } else if profile == .aac256, probe.lossless == .no {
                decision = .passthroughNative
            } else if FileManager.default.fileExists(atPath: destination.path) {
                let ours = journalRecords.contains { $0.destinationPath == destination.path }
                let destProbe = await prober.probe(url: destination)
                let destValid = destProbe.codec != nil
                    && destProbe.failureDetail == nil
                    && Self.matchesProfile(destProbe, profile: profile)
                decision = destValid ? .skipValidOutput
                    : (ours ? .convert : .conflictDestinationInvalidForeign)
            } else {
                decision = .convert
            }

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

    /// Convert one planned entry using the owner's exact ffmpeg argument
    /// set, atomically promoted. Returns the outcome; throws only on
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

        guard ffmpegPresent else {
            return outcome(.convert, .failed, "ffmpeg missing at \(ffmpegURL.path)")
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

        do {
            try await runFFmpeg(source: source, output: temp, profile: profile)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return outcome(.convert, .failed, "ffmpeg failed: \(error.localizedDescription)")
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

    /// The owner's exact reference argument set (t_dc244b34 §3) for the
    /// AAC-256 profile; the ALAC opt-in profile swaps the audio codec.
    /// Arguments are IDENTICAL to the reference except `-c:a`.
    func runFFmpeg(source: URL, output: URL, profile: ConversionProfile) async throws {
        let process = Process()
        process.executableURL = ffmpegURL
        var arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error",
            "-i", source.path,
            "-map", "0:a:0", "-map", "0:v?", "-map_metadata", "0",
        ]
        switch profile {
        case .aac256:
            arguments += ["-c:a", "aac", "-b:a", "256k"]
        case .alac:
            arguments += ["-c:a", "alac"]
        }
        arguments += ["-c:v", "copy", "-disposition:v", "attached_pic", output.path]
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = Pipe()
        try process.run()
        // ffmpeg is CPU-bound and synchronous; run it off the caller's
        // actor via the global executor, keeping this function async
        // without blocking a main actor.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
        guard process.terminationStatus == 0 else {
            let stderrData = (process.standardError as? Pipe)?.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: stderrData ?? Data(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown ffmpeg error"
            throw NSError(domain: "TunoryCore.ffmpeg", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
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

    // MARK: - FFmpeg discovery

    static func resolveFFmpegInPATH() -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("ffmpeg")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
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
