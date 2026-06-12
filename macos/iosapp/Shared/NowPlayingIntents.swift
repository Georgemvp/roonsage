import AppIntents
#if !WIDGET_EXTENSION
import RoonSageCore
#endif

// Transport-intents voor de Live Activity-knoppen én Siri/Shortcuts.
//
// Dit bestand wordt in BEIDE targets gecompileerd (app + widget-extensie):
// de widget heeft het intent-TYPE nodig voor `Button(intent:)`, maar een
// `LiveActivityIntent` voert `perform()` altijd in het APP-proces uit. De
// widget-extensie linkt RoonSageCore niet (WIDGET_EXTENSION-conditie), dus daar compileert een lege
// perform — die versie wordt nooit uitgevoerd.

@available(iOS 17.0, *)
struct PlayPauseIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Speel / pauzeer"
    static var description = IntentDescription("Speelt of pauzeert de huidige Roon-zone.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        let client = RoonClient.shared
        guard await client.ensureConnected(), let zone = client.selectedZone else { return .result() }
        await client.playPause(zoneID: zone.id)
        #endif
        return .result()
    }
}

@available(iOS 17.0, *)
struct NextTrackIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Volgende track"
    static var description = IntentDescription("Slaat over naar de volgende track in de huidige Roon-zone.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        let client = RoonClient.shared
        guard await client.ensureConnected(), let zone = client.selectedZone else { return .result() }
        await client.next(zoneID: zone.id)
        #endif
        return .result()
    }
}

@available(iOS 17.0, *)
struct PreviousTrackIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Vorige track"
    static var description = IntentDescription("Gaat terug naar de vorige track in de huidige Roon-zone.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        let client = RoonClient.shared
        guard await client.ensureConnected(), let zone = client.selectedZone else { return .result() }
        await client.previous(zoneID: zone.id)
        #endif
        return .result()
    }
}
