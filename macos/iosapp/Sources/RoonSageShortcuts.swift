import AppIntents

/// Siri / Shortcuts-frases ("Hé Siri, pauzeer RoonSage"). Alleen in het
/// app-target — de provider hoort niet in de widget-extensie.
struct RoonSageShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayPauseIntent(),
            phrases: [
                "Speel of pauzeer \(.applicationName)",
                "Pauzeer \(.applicationName)",
                "Speel \(.applicationName)",
            ],
            shortTitle: "Speel / pauzeer",
            systemImageName: "playpause.fill"
        )
        AppShortcut(
            intent: NextTrackIntent(),
            phrases: [
                "Volgende track in \(.applicationName)",
                "Sla over in \(.applicationName)",
            ],
            shortTitle: "Volgende track",
            systemImageName: "forward.fill"
        )
        AppShortcut(
            intent: PreviousTrackIntent(),
            phrases: [
                "Vorige track in \(.applicationName)",
            ],
            shortTitle: "Vorige track",
            systemImageName: "backward.fill"
        )
    }
}
