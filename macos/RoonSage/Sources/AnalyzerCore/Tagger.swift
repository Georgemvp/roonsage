import Foundation

public struct TagProgress: Sendable {
    public var tagged: Int
    public var failed: Int
    public var total: Int
}

private var taggerErrLogged = false

/// Generates descriptive LLM tags per track via the local Ollama, from the
/// track's metadata + analyzed features. Resumable (only untagged rows).
public final class Tagger {
    private let store: FeatureStore
    private let ollamaURL: String
    private let model: String
    private var cancelled = false

    public init(store: FeatureStore, ollamaURL: String, model: String) {
        self.store = store
        self.ollamaURL = ollamaURL
        self.model = model
    }

    public func cancel() { cancelled = true }

    public func run(onProgress: @escaping @Sendable (TagProgress) -> Void) async {
        let total = store.count()
        guard total > 0 else { return }
        var ok = 0, failed = 0
        while !cancelled {
            let batch = store.untagged(limit: 200)
            if batch.isEmpty { break }
            let before = ok
            for row in batch {
                if cancelled { break }
                if let tags = await tag(row) {
                    try? store.setTags(matchKey: row.matchKey, tags: tags); ok += 1
                } else { failed += 1 }
                onProgress(TagProgress(tagged: store.taggedCount(), failed: failed, total: total))
            }
            if ok == before { break }   // no progress — stop instead of looping
        }
    }

    private func tag(_ r: TrackFeatureRow) async -> String? {
        let prompt = """
        Track: \(r.artist ?? "?") — \(r.title ?? "?")
        Album: \(r.album ?? "?")\(r.year.map { " (\($0))" } ?? "")
        Audio: ~\(Int(r.bpm.rounded())) BPM, key \(r.keyRoot) \(r.keyMode) (Camelot \(r.camelot)), energy \(String(format: "%.2f", r.energy)).
        Give 5-8 short lowercase tags describing mood, vibe, sub-genre and DJ-set role \
        (e.g. "warmup", "peak-time", "driving", "melancholic", "deep house", "summer").
        Respond with ONLY a JSON array of strings.
        """
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "stream": false,
            "think": false,
            "options": ["temperature": 0.4],
        ]
        guard let url = URL(string: "\(ollamaURL)/api/chat"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data

        let respData: Data
        do { (respData, _) = try await URLSession.shared.data(for: req) }
        catch {
            if !taggerErrLogged { taggerErrLogged = true; FileHandle.standardError.write(Data("[ollama] \(error)\n".utf8)) }
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let content = (json["message"] as? [String: Any])?["content"] as? String else { return nil }
        let cleaned = content.replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression)
        guard let start = cleaned.firstIndex(of: "["), let end = cleaned.lastIndex(of: "]"), start < end,
              let parsed = try? JSONSerialization.jsonObject(with: Data(cleaned[start...end].utf8)) as? [Any] else { return nil }
        let tags = parsed.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        guard !tags.isEmpty, let out = try? JSONSerialization.data(withJSONObject: tags),
              let s = String(data: out, encoding: .utf8) else { return nil }
        return s
    }
}
