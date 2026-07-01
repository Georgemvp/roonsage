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
    /// `forceReplace` skips the catastrophic-shrink guard (step 3) — used for a
    /// deliberate one-time correction when a playlist's Qobuz copy is known to be
    /// stale/bloated (e.g. residue from the pre-fix `deletePlaylistTracks`, which
    /// could leave a playlist not fully cleared before adding the next refresh on
    /// top). Never set this from a routine/automatic sync path.
    public func syncPlaylist(
        name: String,
        description: String,
        tracks: [(title: String, artist: String?, album: String?)],
        email: String,
        password: String,
        knownPlaylistID: String? = nil,
        forceReplace: Bool = false
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
            Log.warning("Qobuz sync '\(name)': 0/\(tracks.count) tracks matched on Qobuz — skipping",
                         category: .network)
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
        if let pid = existingID, !forceReplace {
            let current = await playlistTrackCount(playlistID: pid, session: session)
            if current > 4, ids.count * 2 < current {
                Log.warning("Qobuz sync '\(name)': catastrophic-shrink guard — \(ids.count) resolved from \(tracks.count) candidates vs \(current) existing, keeping existing tracks",
                             category: .network)
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
            Log.warning("Qobuz sync '\(name)': playlist/create failed on Qobuz", category: .network)
            return nil
        }

        // 5. Replace contents. `deleteTracks` requires each track's opaque
        //    `playlist_track_id` (assigned per slot when added) — NOT a raw
        //    0-based position. An earlier version of this code sent synthetic
        //    positions instead, which Qobuz silently rejected: every "replace"
        //    quietly failed to clear anything, so the next sync's `addTracks`
        //    piled on top — the actual cause of playlists bloating unbounded
        //    over time. Loop (re-fetching real ids each pass) until confirmed
        //    empty; bail WITHOUT adding if we still can't after a few tries, so
        //    we never compound the residue further.
        var clearPasses = 0
        while clearPasses < 5 {
            let ptIDs = await playlistTrackIDs(playlistID: playlistID, session: session)
            if ptIDs.isEmpty { break }
            await deletePlaylistTracks(playlistID: playlistID, playlistTrackIDs: ptIDs, session: session)
            clearPasses += 1
        }
        let remaining = await playlistTrackIDs(playlistID: playlistID, session: session)
        guard remaining.isEmpty else {
            Log.warning("Qobuz sync '\(name)': could not fully clear existing tracks (\(remaining.count) left after \(clearPasses) passes) — aborting to avoid piling on top",
                         category: .network)
            return nil
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

    // MARK: - Streaming (experimental / unofficial — see QobuzStream)

    /// Resolve streamable Qobuz URLs for a batch of tracks, logging in ONCE.
    /// Keyed by the caller's `key` (the library match key) so results map back
    /// to the original order. `formatID` 6 = FLAC 16-bit (CD quality). Returns
    /// only the tracks that resolved; the rest stay "not playable" in the UI.
    public func streamURLs(
        for tracks: [(key: String, title: String, artist: String?, album: String?)],
        formatID: Int = 6,
        appSecret: String,
        email: String,
        password: String
    ) async -> [String: URL] {
        guard !appSecret.isEmpty, !tracks.isEmpty,
              let session = await login(email: email, password: password) else { return [:] }
        var out: [String: URL] = [:]
        for t in tracks {
            guard let id = await resolveTrackID(wantTitle: t.title, wantArtist: t.artist, wantAlbum: t.album, session: session),
                  let url = await fileURL(trackID: id, formatID: formatID, appSecret: appSecret, session: session)
            else { continue }
            out[t.key] = url
        }
        return out
    }

    /// One signed `track/getFileUrl` call → a temporary CDN URL (or nil).
    private func fileURL(trackID: Int, formatID: Int, appSecret: String, session: Session) async -> URL? {
        let ts = Int(Date().timeIntervalSince1970)
        let sig = QobuzStream.requestSignature(
            formatID: formatID, intent: "stream", trackID: trackID, timestamp: ts, appSecret: appSecret)
        var comps = URLComponents(string: "\(base)/track/getFileUrl")!
        comps.queryItems = [
            .init(name: "request_ts", value: String(ts)),
            .init(name: "request_sig", value: sig),
            .init(name: "track_id", value: String(trackID)),
            .init(name: "format_id", value: String(formatID)),
            .init(name: "intent", value: "stream"),
        ]
        guard let url = comps.url,
              let (data, resp) = try? await URLSession.shared.data(for: authedRequest(url, session: session)),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlStr = json["url"] as? String, let fileURL = URL(string: urlStr) else { return nil }
        return fileURL
    }

    // MARK: - Login

    private func login(email: String, password: String) async -> Session? {
        let pwMd5 = Insecure.MD5.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
        var lastFailure: String?
        for appId in knownAppIds {
            for pw in [password, pwMd5] {
                switch await tryLogin(email: email, password: pw, appId: appId) {
                case .success(let s): return s
                case .failure(let reason): lastFailure = reason
                }
            }
        }
        // Every (app_id, password-form) combination failed — surface why the LAST
        // one failed so a stale password / dead app_id / Qobuz-side outage is
        // distinguishable from downstream track-matching failures in the log.
        Log.warning("Qobuz login failed for all \(knownAppIds.count) known app_ids: \(lastFailure ?? "unknown reason")",
                     category: .network)
        return nil
    }

    private enum LoginAttempt { case success(Session), failure(String) }

    private func tryLogin(email: String, password: String, appId: String) async -> LoginAttempt {
        // app_id is not a secret and stays in the query; the credentials go in
        // the POST body so the email/password never land in a URL query string
        // (which leaks into server access logs and any TLS-terminating proxy).
        var comps = URLComponents(string: "\(base)/user/login")!
        comps.queryItems = [.init(name: "app_id", value: appId)]
        guard let url = comps.url else { return .failure("could not build login URL") }
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
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
            return .failure("request failed (network error)")
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            let body = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            return .failure("app_id \(appId): HTTP \(status) — \(body)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["user_auth_token"] as? String, !token.isEmpty else {
            return .failure("app_id \(appId): HTTP 200 but no user_auth_token in response")
        }
        loginDisplay = (json["user"] as? [String: Any])?["display_name"] as? String
        return .success(Session(appId: appId, token: token))
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

    /// Every track's opaque `playlist_track_id` — the id Qobuz assigns a track
    /// when it's added to a specific playlist slot. This is what `deleteTracks`
    /// actually requires (confirmed against the legacy Python client, which
    /// reads `t["playlist_track_id"]` from this same `tracks.items` payload) —
    /// NOT a raw 0-based position, which is what an earlier version of this
    /// method sent and which Qobuz silently rejected. Paginated since a large
    /// playlist's `items` page is capped.
    private func playlistTrackIDs(playlistID: String, session: Session) async -> [String] {
        var ids: [String] = []
        var offset = 0
        let pageSize = 500
        while true {
            var comps = URLComponents(string: "\(base)/playlist/get")!
            comps.queryItems = [
                .init(name: "playlist_id", value: playlistID),
                .init(name: "extra", value: "tracks"),
                .init(name: "limit", value: String(pageSize)),
                .init(name: "offset", value: String(offset)),
            ]
            guard let url = comps.url,
                  let (data, _) = try? await URLSession.shared.data(for: authedRequest(url, session: session)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tracks = json["tracks"] as? [String: Any],
                  let items = tracks["items"] as? [[String: Any]], !items.isEmpty else { break }
            for item in items {
                if let pt = item["playlist_track_id"] as? Int { ids.append(String(pt)) }
                else if let pt = item["playlist_track_id"] as? String { ids.append(pt) }
            }
            if items.count < pageSize { break }
            offset += pageSize
        }
        return ids
    }

    /// Max playlist_track_ids per `deleteTracks` call — keeps each request small
    /// and reliable rather than naming every slot of a large playlist at once.
    private let deleteBatchSize = 100

    /// Clear the given `playlist_track_id`s, in batches.
    private func deletePlaylistTracks(playlistID: String, playlistTrackIDs ids: [String], session: Session) async {
        guard !ids.isEmpty, let url = URL(string: "\(base)/playlist/deleteTracks") else { return }
        var start = 0
        while start < ids.count {
            let end = min(start + deleteBatchSize, ids.count)
            let batch = ids[start..<end].joined(separator: ",")
            var req = authedRequest(url, session: session)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = form(["playlist_id": playlistID, "playlist_track_ids": batch])
            _ = try? await URLSession.shared.data(for: req)
            start = end
        }
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

// MARK: - Album resolution (discovery engine)
//
// The discovery pipeline resolves each recommended album to a Qobuz album so it's
// playable/saveable (RoonSage's library-first constitution — it can't download).
// Qobuz album search doubles as the recency signal (`released_at`) and cover art.
// Same-file extension so it can reuse the private track-matching primitives
// (`titleForms`/`artistForm`/`versionPenalty`) and playlist helpers.
extension QobuzClient {

    /// A resolved, playable Qobuz album.
    public struct ResolvedAlbum: Sendable {
        public let id: String
        public let title: String
        public let artist: String
        public let coverURL: URL?
        public let releaseDate: String?   // "YYYY-MM-DD" when known
    }

    /// Resolve a batch of (artist, album) wants to Qobuz albums, logging in ONCE.
    /// Keyed by the caller's `key` (the recommendation dedup key). Only albums that
    /// pass the match gate are returned; the rest stay unresolved (stored but not
    /// actionable in the feed).
    public func resolveAlbums(
        _ wants: [(key: String, artist: String, album: String)],
        email: String, password: String
    ) async -> [String: ResolvedAlbum] {
        guard !wants.isEmpty, let session = await login(email: email, password: password) else { return [:] }
        var out: [String: ResolvedAlbum] = [:]
        for w in wants {
            if let r = await resolveAlbum(wantArtist: w.artist, wantAlbum: w.album, session: session) {
                out[w.key] = r
            }
        }
        return out
    }

    /// Resolve a batch of ARTIST-only wants to a representative Qobuz cover image
    /// — used for `.artist`-kind recommendations, which have no specific album to
    /// resolve/play (unlike `.album`-kind, handled by `resolveAlbums`). Takes the
    /// first search hit whose artist name matches (normalised — no fuzzy title
    /// scoring, since there's no album title to match against). Logs in ONCE.
    public func resolveArtistCovers(
        _ wants: [(key: String, artist: String)],
        email: String, password: String
    ) async -> [String: URL] {
        guard !wants.isEmpty, let session = await login(email: email, password: password) else { return [:] }
        var out: [String: URL] = [:]
        for w in wants {
            guard let items = await searchAlbums(query: w.artist, session: session) else { continue }
            let wantForm = Self.artistForm(w.artist)
            for item in items {
                let candidateArtist = (item["artist"] as? [String: Any])?["name"] as? String
                    ?? (item["performer"] as? [String: Any])?["name"] as? String
                guard Self.artistForm(candidateArtist) == wantForm, let cover = Self.albumCover(item) else { continue }
                out[w.key] = cover
                break
            }
        }
        return out
    }

    /// Append a whole Qobuz album's tracks to a find-or-create playlist (the
    /// "Ontdekkingen" accept action). Additive — never replaces existing contents,
    /// so accepting a second album doesn't wipe the first. Returns false on failure.
    @discardableResult
    public func appendAlbumToPlaylist(
        name: String, description: String, albumID: String,
        email: String, password: String
    ) async -> Bool {
        guard let session = await login(email: email, password: password) else { return false }
        let ids = Self.dedupePreservingOrder(await albumTrackIDs(albumID: albumID, session: session))
        guard !ids.isEmpty else { return false }
        let plID: String
        if let existing = await findPlaylist(named: name, session: session) {
            plID = existing
        } else if let created = await createPlaylist(name: name, description: description, session: session) {
            plID = created
        } else {
            return false
        }
        await addTracks(playlistID: plID, trackIDs: ids, session: session)
        return true
    }

    /// (title, performer) pairs for a Qobuz album — used to build synthetic
    /// `qobuz_search::` play keys so an accepted album can be played/queued in Roon.
    public func albumTrackTitles(albumID: String, email: String, password: String) async -> [(title: String, artist: String?)] {
        guard let session = await login(email: email, password: password) else { return [] }
        var comps = URLComponents(string: "https://www.qobuz.com/api.json/0.2/album/get")!
        comps.queryItems = [.init(name: "album_id", value: albumID), .init(name: "extra", value: "tracks")]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(for: authedRequest(url, session: session)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = (json["tracks"] as? [String: Any])?["items"] as? [[String: Any]] else { return [] }
        let albumArtist = (json["artist"] as? [String: Any])?["name"] as? String
        return items.compactMap { it in
            guard let t = it["title"] as? String, !t.isEmpty else { return nil }
            let performer = (it["performer"] as? [String: Any])?["name"] as? String ?? albumArtist
            return (title: t, artist: performer)
        }
    }

    // MARK: Private

    private func resolveAlbum(wantArtist: String?, wantAlbum: String, session: Session) async -> ResolvedAlbum? {
        let query = [wantArtist, wantAlbum].compactMap { $0 }.joined(separator: " ")
        guard let items = await searchAlbums(query: query, session: session) else { return nil }
        var best: (album: ResolvedAlbum, score: Int)?
        for item in items {
            let title = item["title"] as? String ?? ""
            let artist = (item["artist"] as? [String: Any])?["name"] as? String
                ?? (item["performer"] as? [String: Any])?["name"] as? String
            let m = Self.scoreAlbumCandidate(qobuzTitle: title, qobuzArtist: artist,
                                             wantAlbum: wantAlbum, wantArtist: wantArtist)
            guard m.accept, let id = Self.albumID(item) else { continue }
            if best == nil || m.score > best!.score {
                best = (ResolvedAlbum(id: id, title: title, artist: artist ?? wantArtist ?? "",
                                      coverURL: Self.albumCover(item),
                                      releaseDate: Self.albumReleaseDate(item)), m.score)
            }
        }
        return best?.album
    }

    private func searchAlbums(query: String, session: Session) async -> [[String: Any]]? {
        var comps = URLComponents(string: "https://www.qobuz.com/api.json/0.2/album/search")!
        comps.queryItems = [.init(name: "query", value: query), .init(name: "limit", value: "10")]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(for: authedRequest(url, session: session)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = (json["albums"] as? [String: Any])?["items"] as? [[String: Any]],
              !items.isEmpty else { return nil }
        return items
    }

    /// Track ids of a Qobuz album (for the playlist-append accept action).
    private func albumTrackIDs(albumID: String, session: Session) async -> [Int] {
        var comps = URLComponents(string: "https://www.qobuz.com/api.json/0.2/album/get")!
        comps.queryItems = [.init(name: "album_id", value: albumID), .init(name: "extra", value: "tracks")]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(for: authedRequest(url, session: session)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = (json["tracks"] as? [String: Any])?["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { Self.itemID($0) }
    }

    private static func albumID(_ item: [String: Any]) -> String? {
        if let id = item["id"] as? String, !id.isEmpty { return id }
        if let id = item["id"] as? Int { return String(id) }
        return nil
    }

    private static func albumCover(_ item: [String: Any]) -> URL? {
        if let img = item["image"] as? [String: Any] {
            for k in ["large", "small", "thumbnail"] {
                if let s = img[k] as? String, let u = URL(string: s) { return u }
            }
        }
        if let s = item["image"] as? String, let u = URL(string: s) { return u }
        return nil
    }

    private static func albumReleaseDate(_ item: [String: Any]) -> String? {
        // Prefer the ISO "YYYY-MM-DD" original date; fall back to a unix `released_at`.
        for k in ["release_date_original", "release_date_stream", "release_date_download"] {
            if let s = item[k] as? String, !s.isEmpty { return s }
        }
        if let ts = item["released_at"] as? Int {
            let d = Date(timeIntervalSince1970: TimeInterval(ts))
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
            return f.string(from: d)
        }
        return nil
    }

    /// Pure album match gate — reuses the track scorer's primitives. Requires the
    /// artist to be confirmed and the album title to match (exact or substantial
    /// substring), with no different-recording version penalty. Returns whether to
    /// accept and a rank score to pick the best among candidates.
    nonisolated static func scoreAlbumCandidate(
        qobuzTitle: String, qobuzArtist: String?, wantAlbum: String, wantArtist: String?
    ) -> (accept: Bool, score: Int) {
        let want = titleForms(wantAlbum)
        let cand = titleForms(qobuzTitle)
        var titleScore = 0
        if !cand.full.isEmpty, cand.full == want.full || cand.clean == want.clean {
            titleScore = 4
        } else if !want.clean.isEmpty, !cand.clean.isEmpty,
                  min(want.clean.count, cand.clean.count) >= minSubstringText,
                  cand.clean.contains(want.clean) || want.clean.contains(cand.clean) {
            titleScore = 1
        }

        var artistConfirmed = false, artistExact = false
        let wantA = artistForm(wantArtist), candA = artistForm(qobuzArtist)
        if !wantA.isEmpty, !candA.isEmpty {
            if candA == wantA { artistConfirmed = true; artistExact = true }
            else if min(candA.count, wantA.count) >= minSubstringArtist,
                    candA.contains(wantA) || wantA.contains(candA) { artistConfirmed = true }
        }

        // Penalise a different-recording marker in the album title (live/karaoke/…)
        // unless we asked for it.
        let penalty = versionPenalty(candidateTitle: qobuzTitle, wantTitle: wantAlbum)
        // Accept only a confirmed-artist, title-matching, unpenalised candidate.
        let accept = titleScore >= 1 && artistConfirmed && penalty == 0
        let score = titleScore * 10 + (artistExact ? 3 : 0)
        return (accept, score)
    }
}
