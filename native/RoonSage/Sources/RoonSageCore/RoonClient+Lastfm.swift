import Foundation

@MainActor
extension RoonClient {
    // MARK: - Last.fm credentials (uit Keychain)

    /// (username, apiKey) als beide aanwezig zijn. Lees-methodes vereisen geen
    /// secret of sessiesleutel — alleen de publieke api_key en de gebruikersnaam.
    private func lastfmReadCreds() -> (user: String, apiKey: String)? {
        guard let user = KeychainStore.load(key: "lastfm_username"), !user.isEmpty,
              let apiKey = KeychainStore.load(key: "lastfm_api_key"), !apiKey.isEmpty
        else { return nil }
        return (user, apiKey)
    }

    public var lastfmConfigured: Bool { lastfmReadCreds() != nil }

    // MARK: - Live top-lijsten

    public func lastfmTopArtists(period: LastfmClient.Period, limit: Int = 50) async -> [LastfmClient.TopItem] {
        guard let c = lastfmReadCreds() else { return [] }
        return await LastfmClient.shared.getTopArtists(user: c.user, apiKey: c.apiKey, period: period, limit: limit)
    }

    public func lastfmTopTracks(period: LastfmClient.Period, limit: Int = 50) async -> [LastfmClient.TopItem] {
        guard let c = lastfmReadCreds() else { return [] }
        return await LastfmClient.shared.getTopTracks(user: c.user, apiKey: c.apiKey, period: period, limit: limit)
    }

    public func lastfmTopAlbums(period: LastfmClient.Period, limit: Int = 50) async -> [LastfmClient.TopItem] {
        guard let c = lastfmReadCreds() else { return [] }
        return await LastfmClient.shared.getTopAlbums(user: c.user, apiKey: c.apiKey, period: period, limit: limit)
    }

    // MARK: - Incrementele Last.fm-sync (recente scrobbles)

    /// Haalt scrobbles op die Last.fm heeft ontvangen sinds de laatste geslaagde
    /// sync en voegt ze toe aan `listening_history` (duplicaten worden overgeslagen).
    /// Bedoeld om periodiek op de server te draaien zodat ARC-plays automatisch
    /// binnenkomen. Geeft het aantal nieuw toegevoegde scrobbles terug.
    @discardableResult
    public func syncRecentLastfmScrobbles() async -> Int {
        guard !lastfmImportInProgress else { return 0 }
        guard let c = lastfmReadCreds() else { return 0 }
        guard let db = database else { return 0 }

        // Ondergrens: meest recente Last.fm-row in de DB, minus 60 seconden overlap.
        let fromTs: Int? = await Task.detached {
            guard let iso = (try? await db.latestImportedListen(source: "lastfm")) ?? nil,
                  let date = ISO8601DateFormatter().date(from: iso)
            else { return nil }
            return max(0, Int(date.timeIntervalSince1970) - 60)
        }.value

        Log.info("Last.fm incrementele sync (from=\(fromTs.map(String.init) ?? "begin"))", category: .scrobble)

        var collected: [LastfmClient.Scrobble] = []
        var page = 1
        var totalPages = 1

        while page <= totalPages && page <= 50 {   // max 50 pagina's = 10 000 scrobbles
            guard let result = await LastfmClient.shared.getRecentTracks(
                user: c.user, apiKey: c.apiKey, page: page, limit: 200, from: fromTs) else {
                Log.warning("Last.fm sync netwerkfout op pagina \(page)", category: .scrobble)
                break
            }
            totalPages = max(result.totalPages, 1)
            collected.append(contentsOf: result.scrobbles)
            page += 1
        }

        guard !collected.isEmpty else { return 0 }

        let scrobbles = collected
        let added = await Task.detached { () -> Int in
            let iso = ISO8601DateFormatter()
            let entries = scrobbles.map { s in
                DatabaseManager.ImportedListen(
                    title: s.track, artist: s.artist, album: s.album,
                    playedAt: iso.string(from: Date(timeIntervalSince1970: Double(s.uts))))
            }
            // Dedupe against our own local Roon listens — Roon scrobbles its plays
            // to Last.fm, so importing them straight would double-count.
            try? await db.appendDedupedScrobbles(entries, source: "lastfm", zoneName: "Last.fm")
            return (try? await db.importedListenCount(source: "lastfm")) ?? 0
        }.value

        if added > 0 {
            Log.info("Last.fm sync: \(collected.count) opgehaald, totaal \(added) in DB", category: .scrobble)
        }
        return collected.count
    }

    // MARK: - Historie-import (volledige backfill in listening_history)

    /// Haalt de volledige Last.fm-scrobblehistorie op en schrijft die als
    /// `source='lastfm'` in `listening_history`. Idempotent: een her-import
    /// bouwt de Last.fm-rijen opnieuw op. Alleen scrobbles vóór de vroegste
    /// lokale Roon-listen worden geïmporteerd, zodat er geen dubbele tellingen
    /// ontstaan. Geeft het aantal geïmporteerde scrobbles terug.
    @discardableResult
    public func importLastfmHistory(maxPages: Int = 3000) async -> Int {
        guard !lastfmImportInProgress else { return 0 }
        guard let c = lastfmReadCreds() else {
            lastfmImportStatus = "Koppel eerst Last.fm (gebruikersnaam + API-sleutel)."
            Log.warning("Last.fm-import afgebroken: geen credentials", category: .scrobble)
            return 0
        }
        guard let db = database else { return 0 }

        lastfmImportInProgress = true
        lastfmImportStatus = "Voorbereiden…"
        defer { lastfmImportInProgress = false }

        // Bovengrens: alleen historie vóór onze eerste eigen Roon-listen.
        let cutoff: Int? = await Task.detached {
            guard let iso = (try? await db.earliestListen(excludingSource: "lastfm")) ?? nil else { return nil }
            return ISO8601DateFormatter().date(from: iso).map { Int($0.timeIntervalSince1970) - 1 }
        }.value

        Log.info("Last.fm-import gestart (cutoff=\(cutoff.map(String.init) ?? "geen"))", category: .scrobble)

        var collected: [LastfmClient.Scrobble] = []
        var page = 1
        var totalPages = 1
        var total = 0

        while page <= totalPages && page <= maxPages {
            guard let result = await LastfmClient.shared.getRecentTracks(
                user: c.user, apiKey: c.apiKey, page: page, limit: 200, to: cutoff) else {
                lastfmImportStatus = "Netwerkfout bij pagina \(page) — gestopt."
                Log.error("Last.fm-import netwerkfout op pagina \(page)", category: .scrobble)
                break
            }
            totalPages = max(result.totalPages, 1)
            total = result.total
            collected.append(contentsOf: result.scrobbles)
            lastfmImportStatus = "Ophalen… \(collected.count.formatted()) / \(total.formatted())"
            page += 1
        }

        guard !collected.isEmpty else {
            lastfmImportStatus = total == 0 ? "Geen historie gevonden." : "Niets geïmporteerd."
            return 0
        }

        lastfmImportStatus = "Opslaan in database…"
        let scrobbles = collected
        let written = await Task.detached { () -> Int in
            let iso = ISO8601DateFormatter()
            let entries = scrobbles.map { s in
                DatabaseManager.ImportedListen(
                    title: s.track, artist: s.artist, album: s.album,
                    playedAt: iso.string(from: Date(timeIntervalSince1970: Double(s.uts))))
            }
            try? await db.replaceImportedListens(entries, source: "lastfm", zoneName: "Last.fm")
            return (try? await db.importedListenCount(source: "lastfm")) ?? entries.count
        }.value

        lastfmImportStatus = "\(written.formatted()) scrobbles geïmporteerd ✓"
        Log.info("Last.fm-import klaar: \(written) scrobbles", category: .scrobble)
        return written
    }
}
