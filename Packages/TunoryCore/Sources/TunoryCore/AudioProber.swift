import Foundation
import AVFoundation
import CoreMedia

// MARK: - Local audio import: format detection (requirement 2)
//
// Inspects ACTUAL file content, never filename extensions. Codec identity
// comes from the container's own format description (CoreMedia media
// sub-type four-char code), which AVFoundation decodes from the bytes; a
// mislabeled extension cannot pass. The probe is deterministic and
// side-effect-free: read-only open, stream properties, canonical
// description. All decidability lives here (TunoryCore) — the UI presents.
//
// The four-char-code map below was established empirically against real
// fixtures on this host (probe evidence in task t_5ed9e8d3):
//   flac 0x666c6163, alac 0x616c6163, aac 0x61616320 ('aac '),
//   mp3  0x2e6d7033 ('.mp3'),  lpcm 0x6c70636d (WAV and AIFF alike).
//
// Music.app importability comes from the verified research matrix
// (t_dc244b34 §4, live-probed on this Music 1.7 / macOS 27.0.1 host):
// MP3, AAC, ALAC, FLAC, WAV, AIFF, M4B are all native Music imports
// (sdef `add` + declared openable UTIs).
//
// Lossy-transcode rule (owner contract): Tunory never transcodes
// lossy→lossy claiming fidelity. FLAC (lossless) → AAC-256 is the
// reference profile; ALAC is an optional explicit opt-in lossless profile.

/// Canonical description of one probed audio file.
public struct AudioProbe: Equatable, Sendable, Codable {
    public enum Lossless: String, Sendable, Codable {
        case yes, no, unknown
    }

    /// The file's absolute path at probe time.
    public let path: String
    /// File size in bytes.
    public let byteCount: Int64
    /// Decoded audio duration in seconds (nil when undecodable).
    public let durationSeconds: Double?
    /// Canonical codec name derived from the container's format
    /// description (never from the filename).
    public let codec: String?
    /// Source sample rate in Hz (from the stream description, not the
    /// processing format).
    public let sampleRate: Double?
    /// Source channel count.
    public let channels: Int?
    /// Source bits per channel when the codec reports it.
    public let bitDepth: Int?
    /// Whether the decoded stream is a known-lossless codec.
    public let lossless: Lossless
    /// Whether the installed Music.app can import this file natively
    /// (per the live-probed research matrix).
    public let musicImportable: Bool
    /// Failure detail when the file cannot be decoded at all.
    public let failureDetail: String?

    public init(path: String,
                byteCount: Int64,
                durationSeconds: Double?,
                codec: String?,
                sampleRate: Double?,
                channels: Int?,
                bitDepth: Int?,
                lossless: Lossless,
                musicImportable: Bool,
                failureDetail: String? = nil) {
        self.path = path
        self.byteCount = byteCount
        self.durationSeconds = durationSeconds
        self.codec = codec
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitDepth = bitDepth
        self.lossless = lossless
        self.musicImportable = musicImportable
        self.failureDetail = failureDetail
    }
}

/// Probes files with AVFoundation (content-based, not extension-based).
/// Async by contract: modern AVFoundation track loading is async-only, and
/// callers own the scheduling (view-models use Task, CLI awaits).
public struct AudioProber: Sendable {

    public init() {}

    /// Codecs Music.app imports natively (research matrix t_dc244b34 §4).
    /// 'lpcm' covers WAV and AIFF; 'aac' covers m4a and m4b containers.
    public static let musicNativeCodecs: Set<String> = [
        "mp3", "aac", "alac", "flac", "lpcm"
    ]

    /// Four-char-code → canonical codec name. Values are empirical
    /// (see header); the trailing-space 'aac ' is Apple's actual sub-type.
    static let fourCCMap: [UInt32: String] = [
        0x666c6163: "flac",   // 'flac'
        0x616c6163: "alac",   // 'alac'
        0x61616320: "aac",    // 'aac '
        0x2e6d7033: "mp3",    // '.mp3'
        0x6c70636d: "lpcm",   // 'lpcm' (WAV, AIFF)
    ]

    /// Probe one file. Read-only; never throws — undecodable files return
    /// a probe with `codec == nil`, `failureDetail` set, and
    /// `musicImportable == false` (fail-visible, never guessed).
    public func probe(url: URL) async -> AudioProbe {
        let byteCount = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0

        // Content over extension: AVAudioFile must actually open and decode
        // the container; a mislabeled .flac holding MP3 data fails here.
        guard let file = try? AVAudioFile(forReading: url) else {
            return AudioProbe(path: url.path, byteCount: byteCount, durationSeconds: nil,
                              codec: nil, sampleRate: nil, channels: nil, bitDepth: nil,
                              lossless: .unknown, musicImportable: false,
                              failureDetail: "undecodable by AVFoundation")
        }
        let streamFormat = file.processingFormat
        let decodedDuration = streamFormat.sampleRate > 0
            ? Double(file.length) / streamFormat.sampleRate
            : nil

        // The container's own track + format description is the authority
        // for codec identity and source stream shape.
        let trackInfo = await Self.loadTrackInfo(url: url)
        let assetDuration = await Self.loadAssetDuration(url: url)

        let codec = trackInfo?.codec
        let lossless = Self.losslessness(forCodec: codec)
        let importable = codec.map { Self.musicNativeCodecs.contains($0) } ?? false
        let duration = decodedDuration ?? assetDuration
        let sampleRate = trackInfo?.sampleRate ?? streamFormat.sampleRate
        let channels = trackInfo?.channels ?? Int(streamFormat.channelCount)
        return AudioProbe(path: url.path, byteCount: byteCount,
                          durationSeconds: duration,
                          codec: codec,
                          sampleRate: sampleRate,
                          channels: channels,
                          bitDepth: trackInfo?.bitDepth,
                          lossless: lossless,
                          musicImportable: importable,
                          failureDetail: trackInfo == nil ? "no audio track in container" : nil)
    }

    /// Probe a directory of files, preserving input order (deterministic).
    public func probe(urls: [URL]) async -> [AudioProbe] {
        var results: [AudioProbe] = []
        results.reserveCapacity(urls.count)
        for url in urls {
            results.append(await probe(url: url))
        }
        return results
    }

    // MARK: - Track introspection

    /// Source stream facts from the container's first audio track.
    static func loadTrackInfo(url: URL) async -> (codec: String,
                                                  sampleRate: Double?,
                                                  channels: Int?,
                                                  bitDepth: Int?)? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
              let track = tracks.first else { return nil }
        let descriptions = (try? await track.load(.formatDescriptions)) ?? []
        guard let description = descriptions.first else { return nil }
        let fourcc = CMFormatDescriptionGetMediaSubType(description)

        let codec = Self.fourCCMap[fourcc]
            ?? String(fourCC: fourcc).trimmingCharacters(in: .whitespaces).lowercased()

        var sampleRate: Double?
        var channels: Int?
        var bitDepth: Int?
        if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
            sampleRate = Double(asbd.mSampleRate)
            channels = Int(asbd.mChannelsPerFrame)
            bitDepth = asbd.mBitsPerChannel > 0 ? Int(asbd.mBitsPerChannel) : nil
        }
        return (codec, sampleRate, channels, bitDepth)
    }

    /// Decoded duration per the asset's own clock (fallback when
    /// AVAudioFile's frame count is unavailable).
    static func loadAssetDuration(url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite ? seconds : nil
    }

    /// Losslessness classification for the canonical codec names.
    static func losslessness(forCodec codec: String?) -> AudioProbe.Lossless {
        switch codec {
        case "flac", "alac", "lpcm": return .yes
        case "mp3", "aac": return .no
        default: return .unknown
        }
    }
}

/// Four-char-code to String (diagnostics and unmapped codecs).
extension String {
    init(fourCC value: UInt32) {
        let b0 = UInt8((value >> 24) & 0xFF)
        let b1 = UInt8((value >> 16) & 0xFF)
        let b2 = UInt8((value >> 8) & 0xFF)
        let b3 = UInt8(value & 0xFF)
        self = String(bytes: [b0, b1, b2, b3], encoding: .ascii) ?? String(value)
    }
}
