import Foundation

// MARK: - Explanation cards ("waarom past dit")
//
// One BATCHED LLM call per run generates a short Dutch "why" sentence for every
// recommendation that doesn't already have one cached under its current
// signature (source producers + genres) — so a recommendation that keeps
// reappearing across daily runs only ever costs one LLM call, not one per day.
// Never blocks storing a batch: an LLM failure leaves the templated fallback,
// which the feed UI already treats as optional.

public enum DiscoveryExplanations {

    /// Input to the explanation prompt: `index` is the 1-based position shown to
    /// the LLM (and echoed back), so parsing survives a skipped/reordered item.
    public struct Item: Sendable {
        public let index: Int
        public let artist: String
        public let album: String?
        public let sourceLabels: [String]
        public let genres: [String]
        public init(index: Int, artist: String, album: String?, sourceLabels: [String], genres: [String]) {
            self.index = index; self.artist = artist; self.album = album
            self.sourceLabels = sourceLabels; self.genres = genres
        }
    }

    /// Stable signature over the inputs that could change an explanation's
    /// wording — NOT the score (which shifts run to run without changing the
    /// underlying "why"). Reuses `RoonClient.seed64` (FNV-1a), the same
    /// process-independent hash the AI-radio title cache uses.
    public static func signature(artist: String, album: String?, sourceLabels: [String], genres: [String]) -> String {
        let parts = [
            artist.lowercased(),
            (album ?? "").lowercased(),
            sourceLabels.map { $0.lowercased() }.sorted().joined(separator: ","),
            genres.map { $0.lowercased() }.sorted().joined(separator: ","),
        ]
        return String(RoonClient.seed64(parts.joined(separator: "|")))
    }

    /// A templated Dutch fallback used when the LLM is unreachable or skips an
    /// item — always non-empty, so the feed never shows a blank explanation.
    public static func fallback(sourceCount: Int, genres: [String]) -> String {
        let genrePart = genres.first.map { " en sluit aan op je smaak voor \($0.lowercased())" } ?? ""
        if sourceCount > 1 {
            return "Aanbevolen omdat \(sourceCount) bronnen dit noemden\(genrePart)."
        }
        return "Aanbevolen op basis van je luistergeschiedenis\(genrePart)."
    }

    public static func buildPrompt(_ items: [Item]) -> (system: String, user: String) {
        let system = """
        Je schrijft korte Nederlandse uitlegzinnen voor muziekaanbevelingen: waarom past dit bij de luisteraar? \
        Antwoord UITSLUITEND met een strikt geldige JSON-array, geen andere tekst, exact in de vorm \
        [{"i":1,"text":"..."}]. Één zin per item, max 20 woorden, vlot Nederlands, geen aanhalingstekens erin. \
        Noem waar zinvol de bron (bv. "vergelijkbaar met artiesten die je al leuk vindt") of het genre.
        """
        let lines = items.map { it -> String in
            var s = "\(it.index). \(it.artist)"
            if let a = it.album, !a.isEmpty { s += " — album \"\(a)\"" }
            if !it.sourceLabels.isEmpty { s += " [bron: \(it.sourceLabels.joined(separator: ", "))]" }
            if !it.genres.isEmpty { s += " [genres: \(it.genres.prefix(3).joined(separator: ", "))]" }
            return s
        }.joined(separator: "\n")
        return (system, "Aanbevelingen:\n\(lines)")
    }

    /// Defensively parse `[{"i":N,"text":"..."}]` into `index → text`. Tolerates
    /// a fenced/chatty reply (brace-matching safety net, like `firstJSONObject`)
    /// and drops any entry with an empty/whitespace-only text.
    public static func parseResponse(_ raw: String) -> [Int: String] {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = s.firstIndex(of: "["), let end = s.lastIndex(of: "]"), start < end,
              let data = String(s[start...end]).data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [:] }
        var out: [Int: String] = [:]
        for obj in arr {
            let idx: Int? = (obj["i"] as? Int) ?? (obj["i"] as? NSNumber)?.intValue
                ?? (obj["i"] as? String).flatMap(Int.init)
            guard let idx, let text = (obj["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }
            out[idx] = text
        }
        return out
    }
}
