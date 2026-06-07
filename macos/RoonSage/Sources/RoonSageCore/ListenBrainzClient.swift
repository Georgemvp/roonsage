import Foundation

/// Submits listens to ListenBrainz. Token is stored in Keychain.
public actor ListenBrainzClient {

    public static let shared = ListenBrainzClient()

    private let endpoint = URL(string: "https://api.listenbrainz.org/1/submit-listens")!

    public func submit(title: String, artist: String?, album: String?, token: String) async {
        guard !token.isEmpty else { return }

        var trackMeta: [String: Any] = ["track_name": title]
        if let a = artist { trackMeta["artist_name"] = a }
        if let al = album { trackMeta["additional_info"] = ["release_name": al] }

        let body: [String: Any] = [
            "listen_type": "single",
            "payload": [[
                "listened_at": Int(Date().timeIntervalSince1970),
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
