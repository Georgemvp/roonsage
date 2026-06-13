import Foundation

@MainActor
extension RoonClient {
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
              let settings = try? JSONDecoder().decode(SyncableSettings.self, from: data)
        else { return false }

        settings.apply()

        // Auto-connect to the Mac's Core when it differs from the live session.
        if let host = settings.roonHost, !host.isEmpty, host != coreHost {
            let port = UInt16(settings.roonPort ?? Int(savedPort))
            await connect(host: host, port: port)
        }
        return true
    }
}
