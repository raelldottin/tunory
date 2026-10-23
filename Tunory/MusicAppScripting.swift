import Foundation
import TunoryCore

/// Production MusicScripting adapter: sends Apple Events to Music.app
/// via NSAppleScript, in-process, so TCC attributes the automation
/// permission prompt to Tunory itself (owner decision D2, task
/// t_31cf5210). All decision logic lives in TunoryCore's
/// MusicImportEngine; this file only transports commands and never
/// derives an import decision.
///
/// Every script is a read or the single `add` write, phrased against the
/// verified Music.app 1.7 sdef surface (t_dc244b34):
///   * version probe:        `tell application "Music" to get version`
///   * library count:        `count file tracks of library playlist 1`
///   * read-only search:     `search library playlist 1 for "<query>"`,
///                           then per matched track fetch persistent ID,
///                           name, artist, album, album artist, disc
///                           number, track number, POSIX location and
///                           duration (9 tab-separated fields) so the
///                           engine's six-axis sameRecording comparison
///                           has the metadata it needs (t_e6a35c8e)
///   * add (the only write): `add POSIX file "<path>" to library playlist 1`
///
/// Live-verified read-only on this machine (t_31cf5210 platform sweep):
/// zero-match searches return count 0 without error, and fetching names
/// of an empty search result raises -1728 - so this adapter always
/// counts first and only fetches details for a non-empty result. That
/// keeps "no matches" (valid empty survey) distinct from a script
/// failure (nil survey, which the engine fail-stops on).
@MainActor
final class MusicAppScripting: MusicScripting {

    nonisolated init() {}

    // MARK: - Script plumbing

    /// Escape a value for embedding inside an AppleScript string literal.
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Run one AppleScript; returns its descriptor or nil on any script
    /// error (logged, never silently swallowed).
    private func runScript(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            NSLog("MusicAppScripting: AppleScript error: \(errorInfo)")
            return nil
        }
        return result
    }

    // MARK: - MusicScripting

    func musicVersion() async -> String? {
        runScript("tell application \"Music\" to get version")?.stringValue
    }

    func libraryTrackCount() async -> Int? {
        guard let descriptor = runScript(
            "tell application \"Music\" to count file tracks of library playlist 1") else { return nil }
        return Int(descriptor.int32Value)
    }

    func searchLibrary(query: String) async -> [MusicTrackRef]? {
        let escaped = Self.escape(query)

        // Step 1: count. Zero is a valid empty survey; a script error is
        // nil (fail-stop upstream). Fetching details of an empty result
        // would raise -1728 (verified live), so only proceed past 0.
        guard let countDescriptor = runScript(
            "tell application \"Music\" to count (every track of (search library playlist 1 for \"\(escaped)\"))") else {
            return nil
        }
        let count = Int(countDescriptor.int32Value)
        guard count > 0 else { return [] }

        // Step 2: one script collects the nine decision fields per
        // matched track, tab/linefeed delimited: persistent ID, name,
        // artist, album, album artist, disc number, track number, POSIX
        // location, duration. The metadata axes beyond name are what the
        // engine's six-axis sameRecording comparison needs to prove a
        // cross-format verified-existing match (t_e6a35c8e) - without
        // them every metadata match degrades to needsReview and only
        // byte-identical hashes could ever skip. Per-field try guards:
        // streaming tracks have no location, some tracks lack names or
        // tag axes - a missing field is empty text, not a survey failure.
        let source = """
        tell application "Music"
            set out to ""
            repeat with t in (every track of (search library playlist 1 for "\(escaped)"))
                try
                    set out to out & ((persistent ID of t) as text) & tab
                on error
                    set out to out & "" & tab
                end try
                try
                    set out to out & ((name of t) as text) & tab
                on error
                    set out to out & "" & tab
                end try
                try
                    set out to out & ((artist of t) as text) & tab
                on error
                    set out to out & "" & tab
                end try
                try
                    set out to out & ((album of t) as text) & tab
                on error
                    set out to out & "" & tab
                end try
                try
                    set out to out & ((album artist of t) as text) & tab
                on error
                    set out to out & "" & tab
                end try
                try
                    set out to out & ((disc number of t) as text) & tab
                on error
                    set out to out & "" & tab
                end try
                try
                    set out to out & ((track number of t) as text) & tab
                on error
                    set out to out & "" & tab
                end try
                try
                    set out to out & (POSIX path of (location of t)) & tab
                on error
                    set out to out & "" & tab
                end try
                try
                    set out to out & ((duration of t) as text) & linefeed
                on error
                    set out to out & "" & linefeed
                end try
            end repeat
            return out
        end tell
        """
        guard let descriptor = runScript(source),
              let raw = descriptor.stringValue else {
            return nil
        }
        // POSIX path may come back quoted for paths with spaces; strip
        // surrounding double quotes so locationPath compares equal to
        // URL.path downstream.
        func unquote(_ s: String) -> String {
            var value = s
            if value.hasPrefix("\"") { value.removeFirst() }
            if value.hasSuffix("\"") { value.removeLast() }
            return value
        }

        var refs: [MusicTrackRef] = []
        for line in raw.components(separatedBy: "\n") where !line.isEmpty {
            // Wire order mirrors MusicTrackRef: persistent ID, name,
            // artist, album, album artist, disc number, track number,
            // POSIX location, duration. Empty or unparseable disc/track
            // numbers become nil: an unprovable axis stays unprovable
            // (conservative review), never guessed into a match.
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 9 else { continue }
            let pid = fields[0]
            guard !pid.isEmpty else { continue }
            let name = fields[1].isEmpty ? nil : fields[1]
            let artist = fields[2].isEmpty ? nil : fields[2]
            let album = fields[3].isEmpty ? nil : fields[3]
            let albumArtist = fields[4].isEmpty ? nil : fields[4]
            let discNumber = fields[5].isEmpty ? nil : Int(fields[5])
            let trackNumber = fields[6].isEmpty ? nil : Int(fields[6])
            let location = fields[7].isEmpty ? nil : unquote(fields[7])
            let duration = Double(fields[8])
            refs.append(MusicTrackRef(persistentID: pid,
                                      name: name,
                                      artist: artist,
                                      album: album,
                                      albumArtist: albumArtist,
                                      discNumber: discNumber,
                                      trackNumber: trackNumber,
                                      locationPath: location,
                                      durationSeconds: duration))
        }
        return refs
    }

    func track(withPersistentID id: String) async -> MusicTrackRef? {
        let escaped = Self.escape(id)
        let source = """
        tell application "Music"
            try
                set t to (some file track of library playlist 1 whose persistent ID is "\(escaped)")
            on error
                return ""
            end try
            set out to ""
            try
                set out to out & ((persistent ID of t) as text) & tab
            on error
                set out to out & "" & tab
            end try
            try
                set out to out & ((name of t) as text) & tab
            on error
                set out to out & "" & tab
            end try
            try
                set out to out & ((artist of t) as text) & tab
            on error
                set out to out & "" & tab
            end try
            try
                set out to out & ((album of t) as text) & tab
            on error
                set out to out & "" & tab
            end try
            try
                set out to out & ((album artist of t) as text) & tab
            on error
                set out to out & "" & tab
            end try
            try
                set out to out & ((disc number of t) as text) & tab
            on error
                set out to out & "" & tab
            end try
            try
                set out to out & ((track number of t) as text) & tab
            on error
                set out to out & "" & tab
            end try
            try
                set out to out & (POSIX path of (location of t)) & tab
            on error
                set out to out & "" & tab
            end try
            try
                set out to out & ((duration of t) as text)
            on error
                set out to out & ""
            end try
            return out
        end tell
        """
        guard let descriptor = runScript(source),
              let raw = descriptor.stringValue, !raw.isEmpty else {
            return nil
        }
        // Same 9-field wire order as searchLibrary: persistent ID, name,
        // artist, album, album artist, disc number, track number, POSIX
        // location, duration. Empty or unparseable disc/track numbers
        // become nil (unprovable, never guessed into a match).
        let fields = raw.components(separatedBy: "\t")
        guard fields.count == 9, !fields[0].isEmpty else { return nil }
        var location = fields[7]
        if location.hasPrefix("\"") { location.removeFirst() }
        if location.hasSuffix("\"") { location.removeLast() }
        return MusicTrackRef(persistentID: fields[0],
                             name: fields[1].isEmpty ? nil : fields[1],
                             artist: fields[2].isEmpty ? nil : fields[2],
                             album: fields[3].isEmpty ? nil : fields[3],
                             albumArtist: fields[4].isEmpty ? nil : fields[4],
                             discNumber: fields[5].isEmpty ? nil : Int(fields[5]),
                             trackNumber: fields[6].isEmpty ? nil : Int(fields[6]),
                             locationPath: location.isEmpty ? nil : location,
                             durationSeconds: Double(fields[8]))
    }

    func add(file: URL) async -> String? {
        let escaped = Self.escape(file.path)
        let source = """
        tell application "Music"
            set addedTracks to (add POSIX file "\(escaped)" to library playlist 1)
            try
                return ((persistent ID of item 1 of addedTracks) as text)
            on error
                return ""
            end try
        end tell
        """
        guard let descriptor = runScript(source),
              let pid = descriptor.stringValue else {
            return nil
        }
        return pid.isEmpty ? nil : pid
    }
}
