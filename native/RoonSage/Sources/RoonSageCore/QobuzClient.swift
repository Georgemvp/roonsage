import AudioAnalysis
import Foundation
import CryptoKit

/// Minimal Qobuz JSON-API client for saving playlists. Ports the Python
/// qobuz_api flow: log in with one of the known app_ids (no app_secret /
/// request signing needed), search the catalog to resolve our tracks to Qobuz
/// track IDs, then create a playlist and add them.
public actor QobuzClient {

    public static let shared = QobuzClient()

    private let base = "https://www.qobuz.com/api.json/0.2"
    private let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)"
    // Known working app_ids from established third-party Qobuz tools.
    private let knownAppIds = ["950096963", "579939560", "942852567"]

    public struct SaveResult: Sendable { public let matched: Int; public let total: Int; public let playlistID: String }

    private struct Session { let appId: String; let token: String }

    public init() {}

    // MARK: - Public entry point

    /// Log in, create a playlist, resolve each (title, artist, album) to a Qobuz
    /// track, and add the matches. Returns nil only on login/create failure.
    /// Resolved ids are deduped (preserving order) so two of our tracks that map
    /// to the same Qobuz catalog id don't appear twice.
    public func savePlaylist(
        name: String,
        tracks: [(title: String, artist: String?, album: String?)],
        email: String,
        password: String
    ) async -> SaveResult? {
        guard let session = await login(email: email, password: password) else { return nil }
        guard let playlistID = await createPlaylist(name: name, session: session) else { return nil }

        var ids: [Int] = []
        for t in tracks {
            if let id = await resolveTrackID(wantTitle: t.title, wantArtist: t.artist, wantAlbum: t.album, session: session) {
                ids.append(id)
            }
        }
        ids = Self.dedupePreservingOrder(ids)
        if !ids.isEmpty { await addTracks(playlistID: playlistID, trackIDs: ids, session: session) }
        return SaveResult(matched: ids.count, total: tracks.count, playlistID: playlistID)
    }

    /// Find-or-create a playlist by exact name, replace its contents with
    /// `tracks`, and (re)set its description. Used by the always-on AI
    /// artist-radio sync so a refresh updates the SAME Qobuz playlist instead of
    /// piling up duplicates. The exact `name` is the stable identity key — keep it
    /// stable across refreshes (callers cache the AI title for this reason).
    public func syncPlaylist(
        name: String,
        description: String,
        tracks: [(title: String, artist: String?, album: String?)],
        email: String,
        password: String,
        knownPlaylistID: String? = nil
    ) async -> SaveResult? {
        guard let session = await login(email: email, password: password) else { return nil }

        // 1. Resolve the fresh set FIRST — before touching the existing playlist —
        //    so a transient Qobuz search failure can never gut a good playlist.
        //    Dedup the resolved ids (two of our tracks can map to one catalog id).
        var ids: [Int] = []
        for t in tracks {
            if let id = await resolveTrackID(wantTitle: t.title, wantArtist: t.artist, wantAlbum: t.album, session: session) {
                ids.append(id)
            }
        }
        ids = Self.dedupePreservingOrder(ids)
        guard !ids.isEmpty else {
            // Never clear/create an empty playlist — leave whatever exists intact.
            return nil
        }

        // 2. Resolve the target playlist. A caller-supplied `knownPlaylistID` (the
        //    one we created on a previous sync) lets us update it IN PLACE even
        //    when the title changed — renaming it instead of orphaning the old
        //    name and creating a duplicate. Otherwise find by exact name.
        var existingID: String?
        if let known = knownPlaylistID, !known.isEmpty {
            existingID = known
        } else {
            existingID = await findPlaylist(named: name, session: session)
        }

        // 3. Catastrophic-shrink guard: if we'd replace a populated playlist with
        //    fewer than HALF its current tracks, that's the signature of a transient
        //    matching failure (Qobuz search hiccup), not a real change — skip the
        //    destructive replace and keep the good playlist. Persistent low-match
        //    libraries still update (new ≈ current is not a cliff). Refresh only the
        //    NAME (the stable identity) — NOT the description, which now describes a
        //    tracklist we deliberately didn't install — then bail.
        if let pid = existingID {
            let current = await playlistTrackCount(playlistID: pid, session: session)
            if current > 4, ids.count * 2 < current {
                await updatePlaylist(playlistID: pid, name: name, description: nil, session: session)
                return nil
            }
        }

        // 4. Ensure the playlist exists (find/known → update meta; else create).
        let playlistID: String
        if let pid = existingID {
            playlistID = pid
            await updatePlaylist(playlistID: pid, name: name, description: description, session: session)
        } else if let created = await createPlaylist(name: name, description: description, session: session) {
            playlistID = created
        } else {
            return nil
        }

        // 5. Replace contents. Qobuz `deleteTracks` takes positional IDs and may
        //    shift positions per pass, so loop until empty (bounded), then add the
        //    fresh set in our flow-sequenced order.
        for _ in 0..<4 {
            let count = await playlistTrackCount(playlistID: playlistID, session: session)
            if count == 0 { break }
            await deletePlaylistTracks(playlistID: playlistID, count: count, session: session)
        }
        await addTracks(playlistID: playlistID, trackIDs: ids, session: session)
        return SaveResult(matched: ids.count, total: tracks.count, playlistID: playlistID)
    }

    /// Delete every "RoonSage · …" playlist whose exact name is NOT in `keep`.
    ///
    /// The AI artist-radio set is meant to be a STABLE 6 playlists that refreshes
    /// in place. Earlier builds let the seed set drift (so a refresh created a new
    /// playlist under a new name and orphaned the old one), piling up duplicates.
    /// This reconciles Qobuz back to the current set: list the user's playlists,
    /// and delete any in our `namePrefix` namespace that the caller no longer
    /// recognises. Returns the number deleted.
    public func deleteRadioOrphans(
        keep: Set<String>,
        namePrefix: String,
        email: String,
        password: String
    ) async -> Int {
        guard let session = await login(email: email, password: password) else { return 0 }
        let keepLower = Set(keep.map { $0.lowercased() })
        let mine = await listUserPlaylists(session: session)
        var deleted = 0
        for p in mine where p.name.hasPrefix(namePrefix) && !keepLower.contains(p.name.lowercased()) {
            await deletePlaylist(playlistID: p.id, session: session)
            deleted += 1
        }
        return deleted
    }

    /// Verify credentials and return the account display name, or nil.
    public func verify(email: String, password: String) async -> String? {
        guard await login(email: email, password: password) != nil else { return nil }
        return loginDisplay ?? email
    }
    private var loginDisplay: String?

    // MARK: - Login

    private func login(email: String, password: String) async -> Session? {
        let pwMd5 = Insecure.MD5.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
        for appId in knownAppIds {
            for pw in [password, pwMd5] {
                if let s = await tryLogin(email: email, password: pw, appId: appId) { return s }
            }
        }
        return nil
    }

    private func tryLogin(email: String, password: String, appId: String) async -> Session? {
        // app_id is not a secret and stays in the query; the credentials go in
        // the POST body so the email/password never land in a URL query string
        // (which leaks into server access logs and any TLS-terminating proxy).
        var comps = URLComponents(string: "\(base)/user/login")!
        comps.queryItems = [.init(name: "app_id", value: appId)]
        guard let url = comps.url else { return nil }
        var bodyComps = URLComponents()
        bodyComps.queryItems = [
            .init(name: "email", value: email),
            .init(name: "password", value: password),
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyComps.percentEncodedQuery.map { Data($0.utf8) }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["user_auth_token"] as? String, !token.isEmpty else { return nil }
        loginDisplay = (json["user"] as? [String: Any])?["display_name"] as? String
        return Session(appId: appId, token: token)
    }

    // MARK: - API

    private func authedRequest(_ url: URL, session: Session) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue(session.appId, forHTTPHeaderField: "X-App-Id")
        req.setValue(session.token, forHTTPHeaderField: "X-User-Auth-Token")
        return req
    }

    /// Resolve one of our library tracks to a Qobuz catalog id.
    ///
    /// A curated playlist is only as good as this lookup: the old version accepted a
    /// title-only substring match with NO artist confirmation, so covers / karaoke /
    /// same-title-different-artist tracks silently replaced the real ones, and a
    /// single narrow query dropped anything it didn't surface. This version:
    ///   • normalises both sides (diacritics, "&", "The ", feat/remaster) via
    ///     `TrackIdentity` so Qobuz's catalog spelling lines up with Roon's,
    ///   • tries a tier of widening queries (full → cleaned → title-only),
    ///   • REQUIRES the artist to be confirmed when we know it (no wrong-artist
    ///     matches), falling back to an exact-title rule only when artist is unknown,
    ///   • prefers the canonical recording (penalises live/karaoke/remix/… unless we
    ///     actually asked for that version), with album as a soft tiebreak.
    private func resolveTrackID(wantTitle: String, wantArtist: String?, wantAlbum: String? = nil, session: Session) async -> Int? {
        let queries = Self.candidateQueries(title: wantTitle, artist: wantArtist)
        // We "know" the artist when it survives as non-empty in EITHER the ASCII
        // form or the raw (non-latin) form — so the confirmation gate still applies
        // to CJK/Cyrillic/… artists, not just latin ones.
        let hasArtist = !Self.rawCollapsed(TrackIdentity.primaryArtist(wantArtist)).isEmpty

        var bestID: Int?
        var bestScore = Int.min
        var bestExact = false
        var foundCanonical = false
        // Recovery pool: a known-artist track whose Qobuz performer can't confirm
        // the artist (classical = composer vs orchestra/conductor; compilations =
        // "Various Artists"; remix = remixer credit). Accept the best EXACT-title +
        // matching-album candidate ONLY as a last resort — a wrong-artist cover
        // almost never shares both an exact title AND the album.
        var recoveryID: Int?
        var recoveryScore = Int.min

        for q in queries {
            guard let items = await searchTracks(query: q, session: session) else { continue }
            for item in items {
                let qTitle = item["title"] as? String ?? ""
                // Qobuz puts the credited artist under "performer", but some catalog
                // rows only carry it under "album.artist"/"artist" — fall back so the
                // artist-confirmation gate isn't starved (matches the legacy client),
                // and so the classical composer (album.artist) can confirm.
                let qPerformer = (item["performer"] as? [String: Any])?["name"] as? String
                    ?? (item["artist"] as? [String: Any])?["name"] as? String
                    ?? ((item["album"] as? [String: Any])?["artist"] as? [String: Any])?["name"] as? String
                let qAlbum = (item["album"] as? [String: Any])?["title"] as? String
                let m = Self.scoreCandidate(
                    qobuzTitle: qTitle, qobuzPerformer: qPerformer, qobuzAlbum: qAlbum,
                    wantTitle: wantTitle, wantArtist: wantArtist, wantAlbum: wantAlbum)
                guard m.titleScore >= 1, let id = Self.itemID(item) else { continue }

                if hasArtist {
                    if m.artistConfirmed {
                        // Prefer higher total; on a tie prefer the EXACT-artist hit.
                        if m.total > bestScore || (m.total == bestScore && m.artistExact && !bestExact) {
                            bestScore = m.total; bestID = id; bestExact = m.artistExact
                        }
                        if m.titleScore == 4, m.artistExact, m.total >= 7 { foundCanonical = true }
                    } else if m.titleScore == 4, m.albumConfirmed, m.total > recoveryScore {
                        recoveryScore = m.total; recoveryID = id
                    }
                } else if m.titleScore >= 4, m.total > bestScore {
                    // Unknown artist: only an exact title is safe.
                    bestScore = m.total; bestID = id
                }
            }
            // A confident canonical hit (exact title + EXACT artist, no net penalty)
            // can't be beaten — stop widening.
            if foundCanonical { break }
        }
        return bestID ?? recoveryID
    }

    /// Run one Qobuz `track/search` and return the raw item dictionaries (limit 10
    /// — wider than before so the right edition isn't pushed off a 5-row window).
    private func searchTracks(query: String, session: Session) async -> [[String: Any]]? {
        var comps = URLComponents(string: "\(base)/track/search")!
        comps.queryItems = [.init(name: "query", value: query), .init(name: "limit", value: "10")]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(for: authedRequest(url, session: session)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = (json["tracks"] as? [String: Any])?["items"] as? [[String: Any]],
              !items.isEmpty else { return nil }
        return items
    }

    private static func itemID(_ item: [String: Any]) -> Int? {
        if let id = item["id"] as? Int { return id }
        if let idStr = item["id"] as? String { return Int(idStr) }
        return nil
    }

    // MARK: - Matching (pure, unit-tested in QobuzClientTests)

    /// Tiered search queries, most specific → broadest, deduped. Tier 1 keeps the
    /// original strings (catches exact catalog spellings); tier 2 cleans feat/
    /// remaster noise and reduces to the primary artist; tier 3 is title-only (the
    /// safety net for catalog artist-name divergence — acceptance still confirms
    /// the artist when we know it).
    nonisolated static func candidateQueries(title: String, artist: String?) -> [String] {
        var qs: [String] = []
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, !qs.contains(t) { qs.append(t) }
        }
        let cleanTitle = TrackIdentity.cleanTitle(title)
        let primary = TrackIdentity.primaryArtist(artist)
        add([artist, title].compactMap { $0 }.joined(separator: " "))
        add([primary, cleanTitle].filter { !$0.isEmpty }.joined(separator: " "))
        add(cleanTitle)
        return qs
    }

    /// Lowercase + width-fold + collapse whitespace, but PRESERVE letters of every
    /// script. `TrackIdentity.normalise` keeps only ASCII [a-z0-9], which wipes a
    /// CJK/Cyrillic/Greek title to "" — so we fall back to this for non-latin text
    /// (both sides run the same fold, so an exact non-latin match still resolves).
    nonisolated static func rawCollapsed(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "" }
        let folded = s.folding(options: [.widthInsensitive], locale: Locale(identifier: "en_US")).lowercased()
        return folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Comparable (full, clean) title forms — ASCII-normalised, or raw-collapsed
    /// when normalisation empties a non-latin title.
    private nonisolated static func titleForms(_ s: String) -> (full: String, clean: String) {
        let n = TrackIdentity.normalise(s)
        let nc = TrackIdentity.normalise(TrackIdentity.cleanTitle(s))
        if n.isEmpty, nc.isEmpty { return (rawCollapsed(s), rawCollapsed(TrackIdentity.cleanTitle(s))) }
        return (n, nc)
    }

    /// Comparable primary-artist form — ASCII-normalised, raw-collapsed for
    /// non-latin names.
    private nonisolated static func artistForm(_ s: String?) -> String {
        let n = TrackIdentity.normalise(TrackIdentity.primaryArtist(s))
        return n.isEmpty ? rawCollapsed(TrackIdentity.primaryArtist(s)) : n
    }

    /// Substring confirmation needs a substantial shared string so a single shared
    /// leading token can't false-confirm ("Simon" ← "Simon & Garfunkel" must NOT
    /// match "Simon Says"); short names must match exactly.
    private nonisolated static let minSubstringArtist = 6
    private nonisolated static let minSubstringText = 3

    /// Score a Qobuz candidate against the track we want. Returns the total (album
    /// bonus & version penalties applied), the raw `titleScore` (4 = exact, 1 =
    /// substantial substring, 0 = none), whether the artist was confirmed (exactly
    /// or by a substantial substring), and whether the album matched. The caller
    /// gates acceptance on these.
    nonisolated static func scoreCandidate(
        qobuzTitle: String, qobuzPerformer: String?, qobuzAlbum: String?,
        wantTitle: String, wantArtist: String?, wantAlbum: String?
    ) -> (total: Int, titleScore: Int, artistConfirmed: Bool, artistExact: Bool, albumConfirmed: Bool) {
        let want = titleForms(wantTitle)
        let cand = titleForms(qobuzTitle)
        var titleScore = 0
        if !cand.full.isEmpty, cand.full == want.full || cand.clean == want.clean {
            titleScore = 4
        } else if !want.clean.isEmpty, !cand.clean.isEmpty,
                  min(want.clean.count, cand.clean.count) >= minSubstringText,
                  cand.clean.contains(want.clean) || want.clean.contains(cand.clean) {
            titleScore = 1
        }

        var artistScore = 0
        var artistConfirmed = false
        var artistExact = false
        let wantA = artistForm(wantArtist)
        let candA = artistForm(qobuzPerformer)
        if !wantA.isEmpty, !candA.isEmpty {
            if candA == wantA {
                artistScore = 3; artistConfirmed = true; artistExact = true
            } else if min(candA.count, wantA.count) >= minSubstringArtist,
                      candA.contains(wantA) || wantA.contains(candA) {
                artistScore = 2; artistConfirmed = true
            }
        }

        var albumConfirmed = false
        let wantAlb = TrackIdentity.normalise(wantAlbum)
        if !wantAlb.isEmpty {
            let candAlb = TrackIdentity.normalise(qobuzAlbum)
            if !candAlb.isEmpty,
               candAlb == wantAlb ||
               (min(candAlb.count, wantAlb.count) >= minSubstringText &&
                (candAlb.contains(wantAlb) || wantAlb.contains(candAlb))) {
                albumConfirmed = true
            }
        }
        let albumBonus = albumConfirmed ? 1 : 0

        // Penalise a different-recording marker in EITHER the title or the performer
        // (so "… (Karaoke)" and a "… Tribute Band" performer both fall below the
        // canonical), unless the user actually asked for that edition/credit.
        let penalty = versionPenalty(candidateTitle: qobuzTitle, wantTitle: wantTitle)
            + versionPenalty(candidateTitle: qobuzPerformer ?? "", wantTitle: wantArtist ?? "")
        return (titleScore + artistScore + albumBonus - penalty, titleScore, artistConfirmed, artistExact, albumConfirmed)
    }

    /// Words that mark a DIFFERENT recording (live, karaoke, …). Each one present in
    /// the Qobuz title but NOT in what we asked for costs `versionPenaltyWeight`, so
    /// the canonical studio take outranks a live/karaoke/remix edition — unless the
    /// user's own track is that edition (then it's not penalised).
    nonisolated static let versionMarkers: [String] = [
        "live", "karaoke", "acoustic", "unplugged", "instrumental", "cover",
        "remix", "nightcore", "demo", "rehearsal", "reprise", "acapella",
        "a cappella", "sped up", "slowed", "8d audio", "made famous by", "tribute",
    ]
    nonisolated static let versionPenaltyWeight = 3

    nonisolated static func versionPenalty(candidateTitle: String, wantTitle: String) -> Int {
        let cand = TrackIdentity.normalise(candidateTitle)
        let want = TrackIdentity.normalise(wantTitle)
        guard !cand.isEmpty else { return 0 }
        let candTokens = Set(cand.split(separator: " ").map(String.init))
        let wantTokens = Set(want.split(separator: " ").map(String.init))
        var penalty = 0
        for marker in versionMarkers {
            let present: Bool
            let wanted: Bool
            if marker.contains(" ") {
                present = cand.contains(marker); wanted = want.contains(marker)
            } else {
                present = candTokens.contains(marker); wanted = wantTokens.contains(marker)
            }
            if present && !wanted { penalty += versionPenaltyWeight }
        }
        return penalty
    }

    /// Dedup ids while preserving first-seen order (so flow-sequencing survives).
    nonisolated static func dedupePreservingOrder(_ ids: [Int]) -> [Int] {
        var seen = Set<Int>()
        var out: [Int] = []
        out.reserveCapacity(ids.count)
        for id in ids where seen.insert(id).inserted { out.append(id) }
        return out
    }

    private func createPlaylist(name: String, description: String = "Created by RoonSage", session: Session) async -> String? {
        guard let url = URL(string: "\(base)/playlist/create") else { return nil }
        var req = authedRequest(url, session: session)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form(["name": name, "description": description, "is_public": "false"])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let id = json["id"] as? Int { return String(id) }
        if let id = json["id"] as? String { return id }
        return nil
    }

    // MARK: - Playlist sync helpers (find / update / clear)

    /// Look up one of the user's playlists by exact (case-insensitive) name.
    /// `limit` is generous so an existing radio playlist isn't missed behind a
    /// large library of other playlists (which would create a duplicate).
    private func findPlaylist(named name: String, session: Session) async -> String? {
        var comps = URLComponents(string: "\(base)/playlist/getUserPlaylists")!
        comps.queryItems = [.init(name: "limit", value: "500"), .init(name: "offset", value: "0")]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(for: authedRequest(url, session: session)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = (json["playlists"] as? [String: Any])?["items"] as? [[String: Any]] else { return nil }
        let target = name.lowercased()
        for p in items where (p["name"] as? String ?? "").lowercased() == target {
            if let id = p["id"] as? Int { return String(id) }
            if let id = p["id"] as? String { return id }
        }
        return nil
    }

    /// All of the user's playlists as `(id, name)`. Used by orphan reconciliation.
    private func listUserPlaylists(session: Session) async -> [(id: String, name: String)] {
        var comps = URLComponents(string: "\(base)/playlist/getUserPlaylists")!
        comps.queryItems = [.init(name: "limit", value: "500"), .init(name: "offset", value: "0")]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(for: authedRequest(url, session: session)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = (json["playlists"] as? [String: Any])?["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { p in
            let name = p["name"] as? String ?? ""
            let id: String? = (p["id"] as? Int).map(String.init) ?? (p["id"] as? String)
            guard let id, !name.isEmpty else { return nil }
            return (id, name)
        }
    }

    /// Delete an entire playlist (not just its tracks).
    private func deletePlaylist(playlistID: String, session: Session) async {
        guard let url = URL(string: "\(base)/playlist/delete") else { return }
        var req = authedRequest(url, session: session)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form(["playlist_id": playlistID])
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Update a playlist's name and, when `description` is non-nil, its description.
    /// Passing nil leaves the existing Qobuz description untouched (the shrink-guard
    /// path uses this so it never writes a description for tracks it didn't install).
    private func updatePlaylist(playlistID: String, name: String, description: String?, session: Session) async {
        guard let url = URL(string: "\(base)/playlist/update") else { return }
        var req = authedRequest(url, session: session)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var params = ["playlist_id": playlistID, "name": name]
        if let description { params["description"] = description }
        req.httpBody = form(params)
        _ = try? await URLSession.shared.data(for: req)
    }

    private func playlistTrackCount(playlistID: String, session: Session) async -> Int {
        var comps = URLComponents(string: "\(base)/playlist/get")!
        comps.queryItems = [.init(name: "playlist_id", value: playlistID), .init(name: "extra", value: "tracks")]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(for: authedRequest(url, session: session)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        if let tracks = json["tracks"] as? [String: Any] {
            if let total = tracks["total"] as? Int { return total }
            if let items = tracks["items"] as? [[String: Any]] { return items.count }
        }
        if let total = json["tracks_count"] as? Int { return total }
        return 0
    }

    /// Clear `count` tracks. Qobuz `deleteTracks` takes positional IDs within the
    /// playlist (0-based slots), NOT catalog track IDs — pass every slot to empty
    /// it. The caller loops in case positions shift between passes.
    private func deletePlaylistTracks(playlistID: String, count: Int, session: Session) async {
        guard count > 0, let url = URL(string: "\(base)/playlist/deleteTracks") else { return }
        let positions = (0..<count).map(String.init).joined(separator: ",")
        var req = authedRequest(url, session: session)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form(["playlist_id": playlistID, "playlist_track_ids": positions])
        _ = try? await URLSession.shared.data(for: req)
    }

    private func addTracks(playlistID: String, trackIDs: [Int], session: Session) async {
        guard let url = URL(string: "\(base)/playlist/addTracks") else { return }
        var req = authedRequest(url, session: session)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form([
            "playlist_id": playlistID,
            "track_ids": trackIDs.map(String.init).joined(separator: ","),
        ])
        _ = try? await URLSession.shared.data(for: req)
    }

    private func form(_ params: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs: [String] = params.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return k + "=" + v
        }
        let body: String = pairs.joined(separator: "&")
        return Data(body.utf8)
    }
}
