import Foundation

// MARK: - AI-Picks producer
//
// An LLM-proposed extra source: given the taste profile (top/liked/disliked
// artists), asks for artists/albums the listener doesn't already know. Every
// candidate still passes MusicBrainz validation in the pipeline's Resolve stage
// like any other producer — a hallucinated name that doesn't resolve is simply
// dropped, so a bad LLM answer degrades to "one fewer candidate", never a wrong
// recommendation. `confidence` becomes the candidate's `aiConfidence` (weight
// 0.15 in the composite score — see DiscoveryScoring).

public struct AIPicksProducer: DiscoveryProducer {
    public let id = "ai-picks"
    private let requestCount = 15

    public init() {}

    public func isEnabled(_ context: ProducerContext) -> Bool { true }

    public func discover(seeds: DiscoverySeeds, context: ProducerContext) async -> [Candidate] {
        // Needs SOME taste signal to ground the prompt — an empty-history run
        // would just invite generic hallucinated picks.
        guard !seeds.topArtists.isEmpty || !seeds.likedArtists.isEmpty else { return [] }

        var known = Set<String>()
        var knownList: [String] = []
        for a in seeds.topArtists + seeds.likedArtists {
            let k = a.lowercased()
            if known.insert(k).inserted { knownList.append(a) }
        }
        let liked = Array(seeds.likedArtists.prefix(20))
        let disliked = Array(seeds.dislikedArtists.prefix(15))

        let system = """
        You are a music-discovery assistant. Given a listener's taste profile, propose \(requestCount) \
        artists or albums they likely DON'T already know, that fit their taste. Respond with ONLY a strict \
        JSON array, no prose, no markdown fences, exactly in this shape: \
        [{"artist":"name","album":"title or null","confidence":0.0}] \
        Rules: "album" is a specific release title when you're recommending one particular album, or null when \
        recommending the artist generally. "confidence" is your certainty this fits their taste, 0.0-1.0. \
        NEVER repeat an artist already listed as known. Prefer real, existing artists/albums only.
        """
        // F12a mood-seeded run: nudge the picks toward the requested vibe without
        // abandoning taste-fit — "still sounds like them, just moodier", not "any
        // artist that is generically \(mood)".
        let moodLine = context.mood.map {
            "\nLean the picks toward a \($0) mood/vibe, while still fitting the taste profile above."
        } ?? ""
        let user = """
        Artists already known (do not repeat): \(knownList.prefix(40).joined(separator: ", "))
        Artists they particularly like: \(liked.isEmpty ? "n/a" : liked.joined(separator: ", "))
        Artists they dislike (avoid similar): \(disliked.isEmpty ? "n/a" : disliked.joined(separator: ", "))\(moodLine)
        """

        guard let raw = try? await LLMClient.shared.complete(
            system: system, user: user, config: context.llmConfig,
            jsonMode: true, temperature: 0.6, maxTokens: 1200) else { return [] }

        let picks = Self.parsePicks(raw)
        var out: [Candidate] = []
        for p in picks {
            let name = p.artist.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !known.contains(name.lowercased()) else { continue }
            let album = p.album?.trimmingCharacters(in: .whitespaces)
            out.append(Candidate(
                kind: (album?.isEmpty == false) ? .album : .artist,
                artist: name, album: (album?.isEmpty == false) ? album : nil,
                aiConfidence: min(max(p.confidence, 0), 1), producer: id))
        }
        return Array(out.prefix(context.perProducerLimit))
    }

    // MARK: - Parsing (pure, unit-tested)

    struct Pick { let artist: String; let album: String?; let confidence: Double }

    /// Defensively extract a JSON array of picks from a (possibly fenced/chatty)
    /// LLM reply — mirrors the brace-matching safety net used elsewhere
    /// (`RoonClient.firstJSONObject`), just for an array instead of an object.
    static func parsePicks(_ raw: String) -> [Pick] {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = s.firstIndex(of: "["), let end = s.lastIndex(of: "]"), start < end,
              let data = String(s[start...end]).data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return arr.compactMap { obj -> Pick? in
            guard let artist = obj["artist"] as? String, !artist.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let album = obj["album"] as? String
            let confidence: Double
            if let d = obj["confidence"] as? Double { confidence = d }
            else if let n = obj["confidence"] as? NSNumber { confidence = n.doubleValue }
            else if let str = obj["confidence"] as? String, let d = Double(str) { confidence = d }
            else { confidence = 0.5 }
            return Pick(artist: artist, album: album, confidence: confidence)
        }
    }
}
