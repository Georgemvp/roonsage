import Foundation

/// Now-playing snapshot gedeeld tussen de app en de widget-extensie via de
/// App Group. De app schrijft hem bij elke track-/state-wissel; de widget
/// leest hem in zijn TimelineProvider. Gecompileerd in beide targets.
struct SharedNowPlaying: Codable {
    var title: String
    var artist: String?
    var zoneName: String
    var isPlaying: Bool
    var updatedAt: Date

    static let appGroup = "group.com.roonsage.ios"
    private static let key = "shared_now_playing"

    /// Ouder dan een uur = niet meer tonen (de app is dan al lang
    /// gesuspendeerd en de data is vrijwel zeker achterhaald).
    var isFresh: Bool { Date().timeIntervalSince(updatedAt) < 3600 }

    static func load() -> SharedNowPlaying? {
        guard let defaults = UserDefaults(suiteName: appGroup),
              let data = defaults.data(forKey: key),
              let snap = try? JSONDecoder().decode(SharedNowPlaying.self, from: data)
        else { return nil }
        return snap
    }

    static func save(_ snapshot: SharedNowPlaying?) {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return }
        if let snapshot, let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
