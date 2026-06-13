import AudioAnalysis
import Foundation
import Observation
import RoonProtocol

@MainActor
extension RoonClient {
    // MARK: - Qobuz / global search

    /// Search Qobuz (via Roon global search). Returns tracks whose `id` is a
    /// synthetic `qobuz_search::` key; `curateTracks`/`playByBrowse` re-resolve
    /// it with a fresh search at play time.
    public func searchQobuz(query: String, limit: Int = 20) async -> [TrackRecord] {
        guard let bs = browseService else { return [] }
        let results = (try? await bs.searchGlobal(query: query, limit: limit)) ?? []
        return results.map {
            TrackRecord(id: $0.syntheticKey, title: $0.title, artist: $0.artist, album: $0.album)
        }
    }

    // MARK: - Save to Qobuz

    public var qobuzConfigured: Bool {
        !(KeychainStore.load(key: "qobuz_email") ?? "").isEmpty
            && !(KeychainStore.load(key: "qobuz_password") ?? "").isEmpty
    }

    /// Save a track list as a Qobuz playlist using the stored credentials.
    /// Returns match counts, or nil if not configured / login failed.
    public func saveToQobuz(name: String, tracks: [TrackRecord]) async -> QobuzClient.SaveResult? {
        guard let email = KeychainStore.load(key: "qobuz_email"), !email.isEmpty,
              let pw = KeychainStore.load(key: "qobuz_password"), !pw.isEmpty else { return nil }
        let pairs = tracks.map { (title: $0.title, artist: $0.artist) }
        return await QobuzClient.shared.savePlaylist(name: name, tracks: pairs, email: email, password: pw)
    }

}
