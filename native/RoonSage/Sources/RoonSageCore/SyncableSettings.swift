import Foundation

/// The configuration the Mac can hand to the iPhone so the phone works like a
/// remote without re-entering everything by hand. Exported by the Mac's
/// `LibraryShareServer` (`GET /settings`) and applied on the phone via
/// `RoonClient.importSettings(fromMac:)`. Mirrors the one-tap library import.
///
/// Every field is optional: a service the Mac hasn't configured stays `nil` and
/// `apply()` leaves whatever the phone already has untouched — importing never
/// wipes a credential the phone set up itself.
///
/// Note: this carries secrets (API keys, Last.fm session, Qobuz password) and is
/// served plaintext over HTTP on the LAN/ZeroTier — the same trust model as the
/// existing `/library` share, which is only reachable while the Mac's
/// "Deel bibliotheek" toggle is on.
public struct SyncableSettings: Codable, Sendable {
    public var roonHost: String?
    public var roonPort: Int?

    public var llmProvider: String?
    public var llmBaseURL: String?
    public var llmModel: String?
    public var llmApiKey: String?

    public var analyzerURL: String?

    public var listenbrainzToken: String?

    public var lastfmApiKey: String?
    public var lastfmApiSecret: String?
    public var lastfmSessionKey: String?
    public var lastfmUsername: String?
    public var lastfmScrobbleEnabled: Bool?

    public var qobuzEmail: String?
    public var qobuzPassword: String?

    public init() {}

    /// Snapshot the current device's settings from UserDefaults + Keychain.
    /// Reads only thread-safe stores (no main-actor isolation), so the share
    /// server can call this straight from its connection queue.
    public static func exportCurrent() -> SyncableSettings {
        let d = UserDefaults.standard
        var s = SyncableSettings()

        s.roonHost = d.string(forKey: "lastRoonHost")
        let port = d.integer(forKey: "lastRoonPort")
        s.roonPort = port > 0 ? port : nil

        let llm = LLMConfigStore.load()
        s.llmProvider = llm.provider.rawValue
        s.llmBaseURL = llm.baseURL
        s.llmModel = llm.model
        s.llmApiKey = llm.apiKey.isEmpty ? nil : llm.apiKey

        s.analyzerURL = d.string(forKey: "analyzer_url").flatMap { $0.isEmpty ? nil : $0 }

        s.listenbrainzToken = KeychainStore.load(key: "listenbrainz_token")

        s.lastfmApiKey = KeychainStore.load(key: "lastfm_api_key")
        s.lastfmApiSecret = KeychainStore.load(key: "lastfm_api_secret")
        s.lastfmSessionKey = KeychainStore.load(key: "lastfm_session_key")
        s.lastfmUsername = KeychainStore.load(key: "lastfm_username")
        s.lastfmScrobbleEnabled = d.object(forKey: "lastfm_scrobble_enabled") as? Bool

        s.qobuzEmail = KeychainStore.load(key: "qobuz_email")
        s.qobuzPassword = KeychainStore.load(key: "qobuz_password")

        return s
    }

    /// Write the synced settings into this device's stores. `nil`/empty fields
    /// are skipped so an unconfigured service on the Mac never clears one the
    /// phone already has. Roon host/port is persisted here but connecting is the
    /// caller's job (see `RoonClient.importSettings`).
    public func apply() {
        let d = UserDefaults.standard

        if let host = roonHost, !host.isEmpty {
            d.set(host, forKey: "lastRoonHost")
            if let port = roonPort, port > 0 { d.set(port, forKey: "lastRoonPort") }
        }

        if let providerRaw = llmProvider,
           let provider = LLMConfig.Provider(rawValue: providerRaw) {
            var cfg = LLMConfigStore.load()
            cfg.provider = provider
            if let v = llmBaseURL, !v.isEmpty { cfg.baseURL = v }
            if let v = llmModel, !v.isEmpty { cfg.model = v }
            if let v = llmApiKey, !v.isEmpty { cfg.apiKey = v }
            LLMConfigStore.save(cfg)
        }

        if let v = analyzerURL, !v.isEmpty { d.set(v, forKey: "analyzer_url") }

        applyKeychain("listenbrainz_token", listenbrainzToken)
        applyKeychain("lastfm_api_key", lastfmApiKey)
        applyKeychain("lastfm_api_secret", lastfmApiSecret)
        applyKeychain("lastfm_session_key", lastfmSessionKey)
        applyKeychain("lastfm_username", lastfmUsername)
        if let enabled = lastfmScrobbleEnabled { d.set(enabled, forKey: "lastfm_scrobble_enabled") }

        applyKeychain("qobuz_email", qobuzEmail)
        applyKeychain("qobuz_password", qobuzPassword)
    }

    private func applyKeychain(_ key: String, _ value: String?) {
        guard let value, !value.isEmpty else { return }
        KeychainStore.save(key: key, value: value)
    }
}
