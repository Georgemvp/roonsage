import Foundation

// MARK: - Sonic radio → Qobuz sync settings
//
// User control over WHICH sonic radios are mirrored to Qobuz, and whether the
// mirror runs at all. Two persisted settings drive the always-on server's
// auto-sync (`startArtistRadioRefresh`):
//
//   • `radioSyncEnabled`   — master on/off. Off → the server never touches Qobuz.
//   • `radioSyncSelection` — an allow-list of stable radio ids ("genre:house",
//     "mood:calm", "artist:<key>", …). Checked in the UI = present here = synced.
//
// Back-compat: when no selection has ever been saved (`radioSyncSelection == nil`)
// the auto-sync keeps its original daypart rotation, so users who never open the
// new screen see no behaviour change. The moment a selection is saved, the sync
// switches to "mirror exactly the selected radios" (no rotation).

extension RoonClient {

    // MARK: Persisted settings

    private static let radioSyncEnabledKey   = "radiosync.enabled"
    private static let radioSyncSelectionKey = "radiosync.selection.v1"
    private static let radioHiddenKey        = "radiosync.hidden.v1"

    /// Master switch for the Qobuz mirror. Defaults to `true` (the prior always-on
    /// behaviour) when never set.
    public var radioSyncEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.radioSyncEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.radioSyncEnabledKey) }
    }

    /// The allow-list of radio ids to mirror, or `nil` when the user has never made
    /// a selection (→ keep the legacy daypart rotation). An empty set is a valid,
    /// explicit "mirror nothing".
    public var radioSyncSelection: Set<String>? {
        get {
            guard let arr = UserDefaults.standard.array(forKey: Self.radioSyncSelectionKey) as? [String]
            else { return nil }
            return Set(arr)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(Array(newValue), forKey: Self.radioSyncSelectionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.radioSyncSelectionKey)
            }
        }
    }

    /// Radios the user has hidden from the main "Radio's" screen. Server-of-record
    /// like `radioSyncSelection`, but a plain set — empty means "hide nothing", so
    /// there's no first-edit seeding to do. Independent of the Qobuz-mirror
    /// selection: hiding a station only removes its tile, it doesn't stop a sync.
    public var radioHidden: Set<String> {
        get { Set((UserDefaults.standard.array(forKey: Self.radioHiddenKey) as? [String]) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.radioHiddenKey) }
    }

    /// Hide or un-hide one radio id from the main screen.
    public func setRadioHidden(_ id: String, _ hidden: Bool) {
        var set = radioHidden
        if hidden { set.insert(id) } else { set.remove(id) }
        radioHidden = set
    }

    /// Whether a radio id is currently hidden from the main screen.
    public func isRadioHidden(_ id: String) -> Bool { radioHidden.contains(id) }

    /// Toggle one radio id in the selection. Seeds the allow-list from the currently
    /// live radios on first edit, so unticking one radio doesn't silently drop all
    /// the others that were already being mirrored.
    public func setRadioSelected(_ id: String, _ selected: Bool) {
        var sel = radioSyncSelection ?? Self.allLiveRadioIDs()
        if selected { sel.insert(id) } else { sel.remove(id) }
        radioSyncSelection = sel
    }

    /// Whether a radio id is currently selected for syncing. With no explicit
    /// selection yet, a radio counts as selected when it's currently live (so the
    /// checkboxes reflect what Qobuz already mirrors).
    public func isRadioSelected(_ id: String) -> Bool {
        (radioSyncSelection ?? Self.allLiveRadioIDs()).contains(id)
    }

    /// Every radio id considered live across all categories (artist seeds + the
    /// persisted per-category ids). Used as the default selection on first edit.
    static func allLiveRadioIDs() -> Set<String> {
        var ids = Set<String>()
        for cat in RadioCategory.allCases { ids.formUnion(liveRadioIDs(cat)) }
        return ids
    }

    /// The effective selection the UI should reflect: the saved allow-list, or —
    /// when none has been saved yet — everything currently live on Qobuz.
    public func currentRadioSelection() -> Set<String> {
        radioSyncSelection ?? Self.allLiveRadioIDs()
    }

    // MARK: Available radios (lightweight enumeration for the settings UI)

    /// A radio that can be offered for selection — id, display label, size and a
    /// representative cover. Built WITHOUT the expensive per-radio pool/LLM-title
    /// work, so the settings list loads quickly.
    public struct RadioDescriptor: Identifiable, Sendable {
        public let id: String          // stable radio id ("<category>:<key>")
        public let category: String    // RadioCategory.rawValue
        public let label: String       // display name
        public let trackCount: Int
        public let imageKey: String?
    }

    /// List the radios currently available for `category`, cheaply. Returns `[]` on
    /// a client app (the server owns the sync) or when the library isn't analyzed.
    public func availableRadios(category: RadioCategory) async -> [RadioDescriptor] {
        guard !isRemote, let db = database else { return [] }
        if category == .artist {
            let lib = await radioLibrary()
            guard !lib.isEmpty else { return [] }
            let index = await activeIndex(db)
            let disliked = dislikedMatchKeys
            let radios = await artistSeedRadios(db: db, lib: lib, index: index,
                                                disliked: disliked, stamp: Self.dayStamp())
            return radios.map {
                RadioDescriptor(id: $0.id, category: category.rawValue, label: $0.artist,
                                trackCount: $0.trackCount, imageKey: $0.imageKey)
            }
        } else {
            let buckets = await radioBuckets(category)
            return buckets.map {
                RadioDescriptor(id: $0.id, category: category.rawValue, label: $0.label,
                                trackCount: $0.trackCount, imageKey: $0.imageKey)
            }
        }
    }

    // MARK: Selection-driven sync (replaces daypart rotation when a selection exists)

    /// Mirror exactly the selected radios to Qobuz, grouped by category, then run a
    /// single reconciliation that keeps precisely that set (deselected radios are
    /// removed from Qobuz). Returns the number of playlists synced.
    @discardableResult
    public func syncSelectedRadiosToQobuz(_ selection: Set<String>) async -> Int {
        guard let email = KeychainStore.load(key: "qobuz_email"), !email.isEmpty,
              let pw = KeychainStore.load(key: "qobuz_password"), !pw.isEmpty else { return 0 }
        var total = 0
        for cat in RadioCategory.allCases {
            let ids = selection.filter { $0.hasPrefix(cat.idPrefix) }
            guard !ids.isEmpty else { continue }
            // Non-artist categories need the matching bucket KEYS so exactly the
            // selected buckets get built (the default build caps to the largest few).
            // Artist ignores restrictKeys and is narrowed by restrictIDs after build.
            let keys = cat == .artist ? nil : Array(ids).map { String($0.dropFirst(cat.idPrefix.count)) }
            total += await syncRadiosToQobuz(category: cat, restrictKeys: keys,
                                             restrictIDs: ids, reconcile: false)
        }
        await reconcileQobuzRadios(keepIDs: selection, email: email, password: pw)
        return total
    }
}
