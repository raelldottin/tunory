import Foundation

/// Parses pasted song lists (newline-separated titles, optionally with
/// "Title - Artist" separators, leading numbering, quotes, or Apple Music
/// links). Ordering of the paste is the intended track order.
public enum PastedListParser {

    public static func isActionable(_ text: String) -> Bool {
        !parse(text).isEmpty
    }

    public static func parse(_ text: String) -> [ParsedLine] {
        var out: [ParsedLine] = []
        var pos = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let cleaned0 = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned0.isEmpty else { continue }
            pos += 1

            var title = cleaned0

            // Leading track numbering: "1. ", "2) ", "3 - ", "12.\t"
            title = stripLeadingNumbering(title)

            // Trailing duration markers: "(3:32)", "[4:12]"
            title = stripTrailingDuration(title)

            // Surrounding quotes: “X”, "X", 'X' (any mix of the usual marks)
            title = stripSurroundingQuotes(title)

            // Apple Music link lines resolve by exact id.
            if let link = AppleMusicLink.parse(title) {
                out.append(ParsedLine(pos: pos, rawTitle: title, kind: .link,
                                      catalogId: link.catalogId, link: link))
                continue
            }

            // "Title - Artist" split (en/em dash with spaces).
            var artistHint: String?
            var matchTitle = title
            if let (t, a) = splitTitleArtist(title) {
                matchTitle = t
                artistHint = a
            }

            out.append(ParsedLine(pos: pos, rawTitle: title, kind: .name,
                                  catalogId: nil, link: nil,
                                  artistHint: artistHint, title: matchTitle))
        }
        return out
    }

    // MARK: - Cleaning steps

    private static func stripLeadingNumbering(_ s: String) -> String {
        // "^3." or "12)" or "3 -" style prefixes ONLY: digits must be followed
        // by explicit numbering punctuation. A title that merely starts with
        // a number ("3 Gymnopédies") is preserved.
        guard let r = s.range(of: #"^\d{1,3}\s*[.):–—-]+\s*"#, options: .regularExpression) else {
            return s
        }
        let rest = String(s[r.upperBound...])
        return rest.isEmpty ? s : rest
    }

    private static func stripTrailingDuration(_ s: String) -> String {
        guard let r = s.range(of: #"\s*[(\[][0-9]{1,2}:[0-9]{2}[)\]]\s*$"#, options: .regularExpression) else {
            return s
        }
        let rest = String(s[..<r.lowerBound])
        return rest.isEmpty ? s : rest
    }

    private static func stripSurroundingQuotes(_ s: String) -> String {
        let openers: Set<Character> = ["“", "\"", "‘", "'"]
        let closers: Set<Character> = ["”", "\"", "’", "'"]
        var t = s
        while t.count >= 2, let f = t.first, let l = t.last,
              openers.contains(f), closers.contains(l) {
            let inner = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if inner.isEmpty { break }  // pure-quotes line: leave as-is
            t = inner
        }
        return t
    }

    private static func splitTitleArtist(_ s: String) -> (String, String)? {
        // Require spaces around the dash so "BWV 1004: III" or hyphenated
        // words never split. Look for the LAST such separator (artist at end).
        let separators = [" - ", " – ", " — "]
        var best: Range<String.Index>? = nil
        for sep in separators {
            var searchStart = s.startIndex
            while let r = s.range(of: sep, range: searchStart..<s.endIndex) {
                best = r
                searchStart = r.upperBound
            }
        }
        guard let r = best else { return nil }
        let title = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        let artist = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        return (title, artist)
    }
}
