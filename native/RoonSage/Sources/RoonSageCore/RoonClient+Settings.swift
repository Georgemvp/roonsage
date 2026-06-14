import Foundation

@MainActor
extension RoonClient {
    // MARK: - Server identity

    /// Register this process as the always-on "RoonSage Server" extension — a
    /// distinct Roon identity so it doesn't clash with the Mac/iOS client apps
    /// (which keep their default per-platform IDs). Call once at launch, before
    /// `connect()`. Used by the analyzer/server build.
    public static func useServerIdentity() {
        RoonClientAuth.extensionIDOverride = "com.roonsage.server"
        RoonClientAuth.displayNameOverride = "RoonSage Server"
        // Own keychain namespace: never read items created by the client apps
        // (cross-app reads pop a blocking ACL prompt that freezes the main
        // thread during connect). The server owns its own Roon token + creds.
        KeychainStore.serviceOverride = "com.roonsage.server"
    }

    // MARK: - Settings import (from a sharing Mac)

    /// One-tap settings sync: find the sharing Mac (known hosts on port 5767,
    /// same probe as the library import) and pull its configuration. Returns the
    /// source base URL on success, or nil when no server was found / it failed.
    public func autoImportSettings() async -> String? {
        guard let base = await discoverShareServer() else { return nil }
        guard await importSettings(fromMac: base) else { return nil }
        return base
    }

    /// Pull the Mac's settings (`GET {base}/settings`) and apply them to this
    /// device. If the Mac reports a Roon host we aren't already connected to,
    /// connect to it (the phone authorizes separately the first time — its Roon
    /// token can't be shared). Returns whether the import succeeded.
    public func importSettings(fromMac baseURL: String) async -> Bool {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: "\(trimmed)/settings") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              var settings = try? JSONDecoder().decode(SyncableSettings.self, from: data)
        else { return false }

        // The server reports hosts as it sees them. When the Core / analyzer run
        // on the server itself it reports loopback (127.0.0.1) — useless to the
        // client, where that means the client. Substitute the share server's
        // host (we just reached it there; Core + analyzer live on that machine)
        // for both the Roon host and the analyzer URL.
        let shareHost = URL(string: trimmed)?.host
        if let host = settings.roonHost, Self.isLoopback(host), let shareHost {
            settings.roonHost = shareHost   // apply() persists it below
        }
        if let aURL = settings.analyzerURL, let shareHost {
            settings.analyzerURL = Self.rewriteLoopbackHost(in: aURL, to: shareHost)
        }

        settings.apply()

        // Auto-connect to the Mac's Core when it differs from the live session.
        if let host = settings.roonHost, !host.isEmpty, host != coreHost {
            let port = UInt16(settings.roonPort ?? Int(savedPort))
            await connect(host: host, port: port)
        }
        return true
    }

    static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }

    /// Rewrites the host of a URL string to `newHost` when it points at loopback,
    /// preserving scheme + port (e.g. http://127.0.0.1:5766 → http://<mac>:5766).
    private static func rewriteLoopbackHost(in urlString: String, to newHost: String) -> String {
        guard var comps = URLComponents(string: urlString), let host = comps.host,
              isLoopback(host) else { return urlString }
        comps.host = newHost
        return comps.string ?? urlString
    }

    /// The saved LLM config with one fix-up for thin clients: when the provider
    /// is Ollama and the base URL is empty or still points at loopback, retarget
    /// it at the connected core host — where Ollama actually runs. iOS and a
    /// second Mac never run Ollama locally, so the `localhost` default made
    /// playlist generation fail with "could not connect to the server". No-op
    /// (keeps the saved URL) when no non-loopback core host is known yet.
    /// Use this for *running* completions; saving/editing must keep the raw URL.
    public func effectiveLLMConfig() -> LLMConfig {
        var cfg = LLMConfigStore.load()
        guard cfg.provider == .ollama else { return cfg }
        let url = cfg.baseURL.trimmingCharacters(in: .whitespaces)
        let needsRetarget = url.isEmpty || (URL(string: url)?.host.map(Self.isLoopback) ?? true)
        guard needsRetarget, let host = ollamaFallbackHost else { return cfg }
        cfg.baseURL = url.isEmpty ? "http://\(host):11434" : Self.rewriteLoopbackHost(in: url, to: host)
        return cfg
    }

    /// Best known host that runs Ollama: the live core host, else the host of
    /// the configured analyzer URL (same Mac), else nil. Loopback never counts.
    private var ollamaFallbackHost: String? {
        if let h = coreHost, !h.isEmpty, !Self.isLoopback(h) { return h }
        if let h = URL(string: analyzerURL.trimmingCharacters(in: .whitespaces))?.host,
           !Self.isLoopback(h) { return h }
        return nil
    }

    // MARK: - Full server sync (settings + library + analyses)

    public struct ServerSyncResult: Sendable {
        public let source: String
        public let tracks: Int
        public let features: Int
    }

    /// Client-side "pull everything": settings → library → audio features, in one
    /// go from the central server. `importSettings` runs first so the analyzer
    /// URL (with loopback rewritten) is set before we pull features. Returns nil
    /// if settings or library couldn't be fetched.
    public func syncEverythingFromServer(baseURL: String) async -> ServerSyncResult? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(trimmed, forKey: "library_import_url")
        guard await importSettings(fromMac: trimmed) else { return nil }
        guard let tracks = await importLibrary(fromMac: trimmed) else { return nil }

        var features = 0
        let aURL = featuresURL(serverBase: trimmed)
        if !aURL.isEmpty, let diag = await syncAudioFeatures(from: aURL) {
            features = diag.featureRows
        }
        // Baseline the library revision so the auto-refresh poll doesn't
        // immediately re-import what we just pulled.
        if let rev = await fetchLibraryRevision(base: trimmed) {
            UserDefaults.standard.set(rev, forKey: "imported_library_revision")
        }
        UserDefaults.standard.set(Self.appVersion, forKey: "imported_app_version")
        return ServerSyncResult(source: trimmed, tracks: tracks, features: features)
    }

    /// Auto-discover the server (known hosts on port 5767) and pull everything.
    public func autoSyncEverythingFromServer() async -> ServerSyncResult? {
        guard let base = await discoverShareServer() else { return nil }
        return await syncEverythingFromServer(baseURL: base)
    }
}
