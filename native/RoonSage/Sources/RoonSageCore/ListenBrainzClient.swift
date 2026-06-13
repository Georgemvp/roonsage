import Foundation

/// Submits listens to ListenBrainz. Token is stored in Keychain.
public actor ListenBrainzClient {

    public static let shared = ListenBrainzClient()

    private let endpoint = URL(string: "https://api.listenbrainz.org/1/submit-listens")!

    /// `listenedAt` is the play START time (Unix seconds). The gated commit
    /// fires minutes into the track, so without it ListenBrainz would record
    /// the submit time instead — drifting every listen by up to the gate
    /// length and disagreeing with the Last.fm scrobble (which uses the start).
    public func submit(title: String, artist: String?, album: String?,
                       listenedAt: Int? = nil, token: String) async {
        guard !token.isEmpty else { return }

        var trackMeta: [String: Any] = ["track_name": title]
        if let a = artist { trackMeta["artist_name"] = a }
        if let al = album { trackMeta["additional_info"] = ["release_name": al] }

        let body: [String: Any] = [
            "listen_type": "single",
            "payload": [[
                "listened_at": listenedAt ?? Int(Date().timeIntervalSince1970),
                "track_metadata": trackMeta
            ]]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data

        _ = try? await URLSession.shared.data(for: req)
    }
}
