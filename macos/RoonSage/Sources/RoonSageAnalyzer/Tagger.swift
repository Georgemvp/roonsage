import Foundation

private var taggerErrLogged = false

/// Generates descriptive LLM tags per track via the local Ollama, using the
/// track's metadata + analyzed audio features. Resumable (only untagged rows).
struct Tagger {
    let store: FeatureStore
    let ollamaURL: String
    let model: String

    func run() async {
        let total = store.count()
        guard total > 0 else { print("No analyzed tracks to tag — run `analyze` first."); return }
        print("Tagging via \(ollamaURL) (\(model)). \(store.taggedCount())/\(total) already tagged.")

        var processed = 0, ok = 0, failed = 0
        while true {
            let batch = store.untagged(limit: 200)
            if batch.isEmpty { break }
            let before = ok
            for row in batch {
                if let tags = await tag(row) {
                    try? store.setTags(matchKey: row.matchKey, tags: tags)
                    ok += 1
                    if ok <= 3 { print("  \(row.title ?? "?") → \(tags)") }
                } else {
                    failed += 1
                }
                processed += 1
                if processed % 25 == 0 { print("  \(ok) tagged, \(failed) failed (\(store.taggedCount())/\(total))") }
            }
            if ok == before {   // no progress this batch — stop instead of looping forever
                print("  No successful tags this pass — stopping. (\(failed) failed)")
                break
            }
        }
        print("Tagging done: \(store.taggedCount())/\(total) tagged, \(failed) failed.")
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
            "think": false,   // thinking models (qwen) otherwise stall on this open task
            "options": ["temperature": 0.4],
        ]
        guard let url = URL(string: "\(ollamaURL)/api/chat"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data

        let respData: Data
        do {
            (respData, _) = try await URLSession.shared.data(for: req)
        } catch {
            if !taggerErrLogged { taggerErrLogged = true; print("  [ollama request error] \(error)") }
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let content = (json["message"] as? [String: Any])?["content"] as? String else {
            if !taggerErrLogged { taggerErrLogged = true; print("  [ollama parse error] \(String(data: respData.prefix(200), encoding: .utf8) ?? "?")") }
            return nil
        }

        let cleaned = content.replacingOccurrences(
            of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression
        )
        guard let start = cleaned.firstIndex(of: "["), let end = cleaned.lastIndex(of: "]"), start < end,
              let parsed = try? JSONSerialization.jsonObject(with: Data(cleaned[start...end].utf8)) as? [Any]
        else { return nil }

        let tags = parsed.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        guard !tags.isEmpty,
              let out = try? JSONSerialization.data(withJSONObject: tags),
              let s = String(data: out, encoding: .utf8) else { return nil }
        return s
    }
}
