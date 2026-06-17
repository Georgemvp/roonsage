import AudioAnalysis
import Foundation

// MARK: - Track feedback (like / dislike)
//
// A thumb on Now Playing records a verdict on the *content* track (by
// TrackIdentity.matchKey, not the volatile Roon item_key) so it survives
// resyncs and joins the analyzed library. The verdict lives on the
// server-of-record: the always-on server build (`.direct`) writes it straight
// to its DB; the Mac/iOS client apps (`.server`) POST it to `/track-feedback`
// and read the whole set back from `/feedback`. Either way it's mirrored into
// the in-memory `feedbackByMatchKey` so the UI reacts immediately and the
// radio / fingerprint / recommendation builders can consult it locally.

/// The wire DTO a client POSTs to `/track-feedback`. `kind` nil = clear.
public struct TrackFeedback: Codable, Sendable {
    public var matchKey: String
    public var title: String?
    public var artist: String?
    public var kind: String?     // "like" | "dislike" | nil (clear)
    public init(matchKey: String, title: String?, artist: String?, kind: String?) {
        self.matchKey = matchKey; self.title = title; self.artist = artist; self.kind = kind
    }
}

public enum TrackFeedbackKind: String, Codable, Sendable {
    case like, dislike
}

@MainActor
extension RoonClient {

    /// The verdict on a now-playing track, if any (drives the thumb highlight).
    public func feedbackFor(title: String, artist: String?, album: String?) -> TrackFeedbackKind? {
        feedbackByMatchKey[TrackIdentity.matchKey(artist: artist, album: album, title: title)]
    }

    /// Record a verdict for a track (toggles off when the same thumb is re-tapped).
    /// A thumb is a *soft* taste signal — it doesn't change what's playing now;
    /// it only nudges future radios / fingerprint / recommendations. Persists to
    /// the server-of-record and updates the in-memory mirror so the UI reacts now.
    public func setFeedback(_ kind: TrackFeedbackKind, title: String, artist: String?, album: String?) async {
        let matchKey = TrackIdentity.matchKey(artist: artist, album: album, title: title)
        guard !matchKey.isEmpty else { return }
        // Re-tapping the active thumb clears it.
        let newKind: TrackFeedbackKind? = feedbackByMatchKey[matchKey] == kind ? nil : kind

        if let newKind { feedbackByMatchKey[matchKey] = newKind }
        else { feedbackByMatchKey[matchKey] = nil }

        await persistFeedback(matchKey: matchKey, title: title, artist: artist, kind: newKind)
    }

    /// Write the verdict to the server-of-record (direct = local DB, server =
    /// HTTP POST). nil `kind` clears it.
    private func persistFeedback(matchKey: String, title: String, artist: String?, kind: TrackFeedbackKind?) async {
        if isRemote {
            await postFeedback(TrackFeedback(matchKey: matchKey, title: title, artist: artist, kind: kind?.rawValue))
            return
        }
        do {
            if let kind {
                try await database?.setFeedback(matchKey: matchKey, title: title, artist: artist, kind: kind.rawValue)
            } else {
                try await database?.clearFeedback(matchKey: matchKey)
            }
        } catch {
            Log.warning("Feedback opslaan mislukt: \(error)", category: .roon)
            reportError("Feedback opslaan mislukt — probeer het opnieuw.")
        }
    }

    private func postFeedback(_ fb: TrackFeedback) async {
        guard let base = remoteBaseURL, let url = URL(string: "\(base)/track-feedback") else {
            reportError("Geen verbinding met de RoonSage-server.")
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(fb)
        authorizeShareRequest(&req)
        req.timeoutInterval = 8
        if let (_, resp) = try? await URLSession.shared.data(for: req),
           (resp as? HTTPURLResponse)?.statusCode == 200 {
            return
        }
        reportError("Feedback mislukt — is de RoonSage-server bereikbaar?")
    }

    // MARK: - Loading the verdict set

    /// Populate `feedbackByMatchKey` once per session (direct: local DB; server:
    /// pull `/feedback`). Safe to call repeatedly; only the first load hits I/O.
    public func ensureFeedbackLoaded() async {
        guard !feedbackLoaded else { return }
        feedbackLoaded = true
        await reloadFeedback()
    }

    /// Force a refresh of the in-memory verdict mirror.
    public func reloadFeedback() async {
        let entries: [DatabaseManager.FeedbackEntry]
        if isRemote {
            entries = await fetchRemoteFeedback()
        } else {
            entries = (try? await database?.allFeedback()) ?? []
        }
        var map: [String: TrackFeedbackKind] = [:]
        for e in entries {
            guard !e.matchKey.isEmpty, let k = TrackFeedbackKind(rawValue: e.kind) else { continue }
            map[e.matchKey] = k
        }
        feedbackByMatchKey = map
    }

    private func fetchRemoteFeedback() async -> [DatabaseManager.FeedbackEntry] {
        guard let base = remoteBaseURL, let url = URL(string: "\(base)/feedback") else { return [] }
        var req = URLRequest(url: url); req.timeoutInterval = 8
        authorizeShareRequest(&req)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let entries = try? JSONDecoder().decode([DatabaseManager.FeedbackEntry].self, from: data) else { return [] }
        return entries
    }

    // MARK: - Learning signal (read by radios / fingerprint / recommendations)

    /// Match keys the user has thumbed down — excluded from radio / fingerprint
    /// candidate pools so they're never suggested again.
    public var dislikedMatchKeys: Set<String> {
        Set(feedbackByMatchKey.filter { $0.value == .dislike }.keys)
    }

    /// Match keys the user has thumbed up — boosted as radio seeds.
    public var likedMatchKeys: Set<String> {
        Set(feedbackByMatchKey.filter { $0.value == .like }.keys)
    }

    /// Distinct liked / disliked artist names (lowercased), for the recommendation
    /// prompt and seed weighting. Derived from the analyzed library's match_key →
    /// artist mapping so it covers both library and streamed tracks we've judged.
    public func feedbackArtistHints() async -> (liked: [String], disliked: [String]) {
        guard let db = database, !feedbackByMatchKey.isEmpty else { return ([], []) }
        let lib = await sonicCache.tracks(from: db)
        var artistByKey: [String: String] = [:]
        for t in lib where !t.matchKey.isEmpty {
            if let a = t.artist, !a.isEmpty { artistByKey[t.matchKey] = a }
        }
        var liked = Set<String>(), disliked = Set<String>()
        for (mk, kind) in feedbackByMatchKey {
            guard let a = artistByKey[mk] else { continue }
            if kind == .like { liked.insert(a) } else { disliked.insert(a) }
        }
        return (Array(liked).sorted(), Array(disliked).sorted())
    }

    /// Per-(lowercased)-artist like / dislike tallies, derived from the analyzed
    /// library's match_key → artist mapping. Feeds the radio affinity score so a
    /// thumb *nudges* an artist's ranking rather than forcing a station.
    func feedbackArtistTallies(lib: [DatabaseManager.SonicTrack]) -> (liked: [String: Int], disliked: [String: Int]) {
        guard !feedbackByMatchKey.isEmpty else { return ([:], [:]) }
        var artistByKey: [String: String] = [:]
        for t in lib where !t.matchKey.isEmpty {
            if let a = t.artist, !a.isEmpty { artistByKey[t.matchKey] = a.lowercased() }
        }
        var liked: [String: Int] = [:], disliked: [String: Int] = [:]
        for (mk, kind) in feedbackByMatchKey {
            guard let a = artistByKey[mk] else { continue }
            if kind == .like { liked[a, default: 0] += 1 } else { disliked[a, default: 0] += 1 }
        }
        return (liked, disliked)
    }

    /// The analyzed library, after ensuring the feedback mirror is loaded. Does
    /// NOT remove disliked tracks — feedback is applied as a *soft* weight by the
    /// candidate builders (disliked are down-sampled, not banned), so the library
    /// itself stays whole.
    func radioLibrary() async -> [DatabaseManager.SonicTrack] {
        guard let db = database else { return [] }
        await ensureFeedbackLoaded()
        return await sonicCache.tracks(from: db)
    }

    // MARK: - Soft feedback weighting (pure, used by the off-main builders)

    /// Deterministic gate for whether a thumbed-down track survives this round.
    /// `salt` rotates the surviving subset (e.g. per day) so a disliked track is
    /// heard roughly `1/keepEvery` as often — much less, but never banned.
    nonisolated static func keepDisliked(_ matchKey: String, salt: String, keepEvery: Int) -> Bool {
        guard keepEvery > 1 else { return true }
        return seed64("\(salt)\u{1f}\(matchKey)") % UInt64(keepEvery) == 0
    }

    /// Down-sample disliked tracks in a candidate list (preserving order/identity
    /// of the survivors). Liked and neutral tracks always pass.
    nonisolated static func applyFeedbackWeighting<T>(
        _ items: [T], disliked: Set<String>, salt: String, keepEvery: Int = 4,
        matchKey: (T) -> String
    ) -> [T] {
        guard !disliked.isEmpty else { return items }
        return items.filter {
            let mk = matchKey($0)
            return !disliked.contains(mk) || keepDisliked(mk, salt: salt, keepEvery: keepEvery)
        }
    }
}
