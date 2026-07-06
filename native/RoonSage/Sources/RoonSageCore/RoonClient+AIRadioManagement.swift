import Foundation

// MARK: - AI radio management (server-of-record over HTTP)
//
// The auto-generated AI radios (artist/genre/mood/activity/decade) are mirrored to
// Qobuz by the always-on server, driven by two SERVER-side settings:
// `radioSyncEnabled` (master) + `radioSyncSelection` (per-radio allow-list). To let
// the unified "Mijn radio's" view manage them from ANY client (Mac/iOS thin
// clients), those settings are exposed over the share server here — mirroring the
// playlists/radio-configs pattern. `.sonic` is intentionally omitted (cluster-based,
// not forkable to a facet, and expensive to enumerate).

/// One AI radio offered for management: its stable id, display label, cached AI
/// title, size and current on/off (mirrored-to-Qobuz) state.
public struct AIRadioItem: Codable, Sendable, Identifiable {
    public let id: String          // "<category>:<key>"
    public let category: String    // RadioCategory.rawValue
    public let label: String       // artist / genre / mood / … display name
    public let title: String       // cached AI title, or the label as fallback
    public let trackCount: Int
    public let imageKey: String?
    public var selected: Bool       // currently mirrored to Qobuz
    public init(id: String, category: String, label: String, title: String,
                trackCount: Int, imageKey: String?, selected: Bool) {
        self.id = id; self.category = category; self.label = label; self.title = title
        self.trackCount = trackCount; self.imageKey = imageKey; self.selected = selected
    }
}

/// The management payload the server serves for the AI-radio section.
public struct AIRadioManagement: Codable, Sendable {
    public var syncEnabled: Bool        // master radioSyncEnabled
    public var qobuzConfigured: Bool
    public var radios: [AIRadioItem]
    public init(syncEnabled: Bool, qobuzConfigured: Bool, radios: [AIRadioItem]) {
        self.syncEnabled = syncEnabled; self.qobuzConfigured = qobuzConfigured; self.radios = radios
    }
}

/// A change a client POSTs: toggle one radio's selection and/or the master switch.
public struct AIRadioSelectionRequest: Codable, Sendable {
    public var id: String?
    public var selected: Bool?
    public var syncEnabled: Bool?
    public init(id: String? = nil, selected: Bool? = nil, syncEnabled: Bool? = nil) {
        self.id = id; self.selected = selected; self.syncEnabled = syncEnabled
    }
}

@MainActor
extension RoonClient {

    /// Categories offered for management (sonic omitted — see file header).
    public static let manageableRadioCategories: [RadioCategory] = [.artist, .genre, .mood, .activity, .decade]

    /// The AI-radio management payload. Server builds it from `availableRadios`
    /// across the manageable categories + the current selection; clients fetch it.
    public func aiRadioManagement() async -> AIRadioManagement {
        if isRemote { return await fetchRemoteAIRadioManagement() }
        var items: [AIRadioItem] = []
        for cat in Self.manageableRadioCategories {
            for d in await availableRadios(category: cat) {
                items.append(AIRadioItem(
                    id: d.id, category: d.category, label: d.label,
                    title: Self.cachedRadioTitle(d.id) ?? d.label,
                    trackCount: d.trackCount, imageKey: d.imageKey,
                    selected: isRadioSelected(d.id)))
            }
        }
        return AIRadioManagement(syncEnabled: radioSyncEnabled,
                                 qobuzConfigured: qobuzConfigured, radios: items)
    }

    /// Toggle one AI radio's Qobuz mirror (server-of-record).
    public func setAIRadioSelected(_ id: String, _ on: Bool) async {
        if isRemote { await postAIRadioChange(.init(id: id, selected: on)); return }
        setRadioSelected(id, on)
    }

    /// Toggle the master AI-radio Qobuz sync.
    public func setAIRadioSyncEnabled(_ on: Bool) async {
        if isRemote { await postAIRadioChange(.init(syncEnabled: on)); return }
        radioSyncEnabled = on
    }

    // MARK: Fork an AI radio into an editable custom config ("overnemen")

    /// Build a fresh, editable `RadioConfig` seeded from an AI radio's defining
    /// facet (artist → artist facet, genre → genre facet, …). The user then edits +
    /// saves it as a custom radio; its AI title is regenerated on first sync. Sonic
    /// (cluster) radios have no facet mapping and fall back to a bare, named config.
    public nonisolated static func radioConfigFromAIRadio(_ item: AIRadioItem) -> RadioConfig {
        var cfg = RadioConfig(name: item.label)
        guard let cat = RadioCategory(radioID: item.id) else { return cfg }
        let key = String(item.id.dropFirst(cat.idPrefix.count))
        switch cat {
        case .artist:   cfg.artists = [item.label]
        case .genre:    cfg.genres = [key]
        case .mood:     cfg.moods = [key]
        case .activity: cfg.activities = [key]
        case .decade:   if let y = Int(key) { cfg.decades = [y] }
        case .sonic:    break
        }
        return cfg
    }

    // MARK: Server-side JSON (for the share server routes)

    public func aiRadioManagementData() async -> Data {
        (try? JSONEncoder().encode(await aiRadioManagement())) ?? Data("{}".utf8)
    }

    /// Apply a change server-side. Returns true on a recognised request.
    @discardableResult
    public func applyAIRadioChange(_ req: AIRadioSelectionRequest) -> Bool {
        var handled = false
        if let enabled = req.syncEnabled { radioSyncEnabled = enabled; handled = true }
        if let id = req.id, let sel = req.selected, !id.isEmpty { setRadioSelected(id, sel); handled = true }
        return handled
    }

    // MARK: Remote HTTP helpers

    private func fetchRemoteAIRadioManagement() async -> AIRadioManagement {
        let empty = AIRadioManagement(syncEnabled: false, qobuzConfigured: false, radios: [])
        guard let base = remoteBaseURL, let url = URL(string: "\(base)/ai-radios") else { return empty }
        var req = URLRequest(url: url); req.timeoutInterval = 20   // server builds buckets on demand
        authorizeShareRequest(&req)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let payload = try? JSONDecoder().decode(AIRadioManagement.self, from: data) else { return empty }
        return payload
    }

    private func postAIRadioChange(_ change: AIRadioSelectionRequest) async {
        guard let base = remoteBaseURL, let url = URL(string: "\(base)/ai-radio-selection") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(change)
        authorizeShareRequest(&req); req.timeoutInterval = 10
        if let (_, resp) = try? await URLSession.shared.data(for: req),
           (resp as? HTTPURLResponse)?.statusCode == 200 { return }
        reportError("Wijziging opslaan mislukt — is de RoonSage-server bereikbaar?")
    }
}
