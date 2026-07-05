import SwiftUI
import RoonSageCore

/// Where this Settings screen runs.
/// - `.server`: the always-on analyzer/server app — everything editable; this is
///   the single place to configure LLM, Last.fm, Qobuz, analyzer, etc.
/// - `.client`: the Mac/iOS remote apps — almost everything is gone. They only
///   pick a server address, pull config + library + features from it, and keep
///   the per-device Roon authorization + local appearance.
public enum SettingsRole: Sendable {
    case server
    case client
}

@MainActor
public struct SettingsView: View {
    private let role: SettingsRole
    @Environment(RoonClient.self) private var client
    @Environment(\.openURL) private var openURL
    @AppStorage("themePreset") private var themePreset: ThemePreset = .custom
    @AppStorage("themeMode") private var themeMode: ThemeMode = .system
    @AppStorage("accentChoice") private var accent: AccentChoice = .gold
    @AppStorage("ambientIntensity") private var ambientIntensity: Double = 1.0
    @AppStorage("ambientWallpaper") private var ambientWallpaper: Bool = false
    @AppStorage("appLanguage") private var appLanguage: LocalePreference = .system
    @AppStorage("showVisualizer") private var showVisualizer = true
    @State private var lastSync: String = "—"

    // Server sync (client role: pull settings + library + features from the server)
    @State private var serverURL: String = UserDefaults.standard.string(forKey: "library_import_url") ?? ""
    @State private var serverToken: String = LibraryShareServer.configuredToken ?? ""
    @State private var savedServerToken: String = LibraryShareServer.configuredToken ?? ""
    @State private var tokenSaved = false
    @State private var settingsSyncBusy = false
    @State private var settingsSyncStatus: String?

    public init(role: SettingsRole = .client) {
        self.role = role
    }

    /// "21 + 452 via MusicBrainz" — the coarse Roon buckets plus the fine-grained MB
    /// vocabulary, so the depth added by analyzer enrichment is visible rather than
    /// hidden behind Roon's ~21 top-level genres.
    private var genreCountLabel: String {
        if client.genreCount == 0 && client.mbGenreCount == 0 { return "Niet gesynchroniseerd" }
        if client.mbGenreCount > 0 {
            return "\(client.genreCount) + \(client.mbGenreCount) via MusicBrainz"
        }
        return "\(client.genreCount)"
    }

    // ListenBrainz
    @State private var lbToken: String = ""
    @State private var lbSaved = false
    @State private var lbLovesBusy = false
    @State private var lbLovesResult = ""

    // Discogs (F7 — Discogs Labels discovery producer)
    @State private var discogsToken: String = ""
    @State private var discogsSaved = false

    // Last.fm
    @State private var lfApiKey: String = ""
    @State private var lfApiSecret: String = ""
    @State private var lfUsername: String = ""
    @State private var lfConnected = false
    @State private var lfPendingToken: String? = nil
    @State private var lfBusy = false
    @State private var lfStatus: String = ""
    @AppStorage("lastfm_scrobble_enabled") private var lfScrobbleFromApp = false

    // Qobuz
    @State private var qbEmail: String = ""
    @State private var qbPassword: String = ""
    @State private var qbBusy = false
    @State private var qbStatus: String = ""
    @State private var qbStreamLocal = false
    @State private var qbAppSecret: String = ""

    // Audio analyzer
    @State private var analyzerURL: String = ""
    @State private var afBusy = false
    @State private var afStatus: String = ""
    // Loaded in .task — a DB read in `body` blocked main on every render.
    @State private var afStats: (total: Int, matched: Int) = (0, 0)

    // LLM
    @State private var llmProvider: LLMConfig.Provider = .ollama
    @State private var llmBaseURL:  String = "http://localhost:11434"
    @State private var llmModel:    String = "qwen3:8b"
    @State private var llmApiKey:   String = ""
    @State private var llmSaved     = false
    @State private var ollamaModels: [String] = []
    @State private var isFetchingModels = false
    @State private var isTestingLLM = false
    @State private var llmTestStatus: String? = nil
    @State private var llmTestOK = false

    public var body: some View {
        Form {
            // Appearance
            Section("Verschijning") {
                Picker("Thema", selection: $themePreset) {
                    ForEach(ThemePreset.allCases) { preset in
                        Label {
                            Text(preset.label)
                        } icon: {
                            Circle()
                                .fill(LinearGradient(colors: preset.swatch,
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 14, height: 14)
                                .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
                        }
                        .tag(preset)
                    }
                }
                // The custom accent + light/dark pickers only apply to "Aangepast";
                // a named preset pins its own accent and scheme.
                if themePreset == .custom {
                    Picker("Lichtmodus", selection: $themeMode) {
                        ForEach(ThemeMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    Picker("Accentkleur", selection: $accent) {
                        ForEach(AccentChoice.allCases) { choice in
                            Label {
                                Text(choice.label)
                            } icon: {
                                Circle().fill(choice.color).frame(width: 12, height: 12)
                            }
                            .tag(choice)
                        }
                    }
                }
                Toggle("Visualizer bij 'Nu speelt'", isOn: $showVisualizer)
                Picker(LS("settings.language"), selection: $appLanguage) {
                    ForEach(LocalePreference.allCases) { Text($0.label).tag($0) }
                }
            }

            // Ambient backdrop (C6): dial the album-art wash + optional wallpaper.
            Section("Achtergrond") {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Sfeer-intensiteit")
                        Spacer()
                        Text("\(Int(ambientIntensity * 100))%")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Slider(value: $ambientIntensity, in: 0...1, step: 0.05)
                        .tint(Color.roonGold)
                    Text("Hoeveel de album-art de app kleurt. 0% = vlakke achtergrond.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Album-hoes als achtergrond", isOn: $ambientWallpaper)
            }

            // Connection
            Section("Roon-verbinding") {
                LabeledContent("Status", value: client.connectionState.label)
                if let host = client.coreHost {
                    LabeledContent("Host", value: "\(host):\(client.corePort)")
                }
                HStack {
                    Button("Verbreek verbinding") {
                        Task { await client.disconnect() }
                    }
                    .disabled(!client.connectionState.isConnected)

                    Button("Opnieuw autoriseren", role: .destructive) {
                        Task { await client.clearAndReauthorize() }
                    }
                    .disabled(!client.connectionState.isConnected)
                }
            }

            if role == .client {
                // The remote apps work like a remote: pick the server (the
                // always-on analyzer/server) and pull settings + library +
                // analyses from it in one tap. No credentials are entered here.
                Section("Server") {
                    Button {
                        Task { await syncFromServer() }
                    } label: {
                        Label(settingsSyncBusy ? "Synchroniseren…" : "Synchroniseer met server",
                              systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(settingsSyncBusy || client.isSyncing)

                    // Manual fallback for a server the app can't auto-discover.
                    HStack {
                        TextField("http://10.94.184.22:5767", text: $serverURL)
                            .textFieldStyle(.roundedBorder)
                        Button("Synchroniseer") {
                            Task { await syncFromServer(explicit: serverURL) }
                        }
                        .disabled(settingsSyncBusy || client.isSyncing
                                  || serverURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let s = settingsSyncStatus {
                        Text(s).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: Spacing.sm) {
                        // Save on commit (Enter / Bewaar), not on every keystroke —
                        // a half-typed token used to overwrite the working one.
                        SecureField("Servertoken", text: $serverToken)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { saveServerToken() }
                        if tokenSaved {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.roonSuccess)
                                .accessibilityLabel("Token bewaard")
                                .transition(.opacity)
                        }
                        Button("Bewaar") { saveServerToken() }
                            .disabled(serverToken.trimmingCharacters(in: .whitespaces) == savedServerToken)
                    }
                    .animation(Motion.quick, value: tokenSaved)
                    Text("Haalt instellingen, de muziekbibliotheek en de analyses op van de RoonSage-server (de analyzer op je always-on Mac). Je hoeft hier niets in te vullen: dit apparaat meldt zich automatisch aan en verschijnt op de server onder ‘Apparaten’, waar je het met één tik goedkeurt. (Het veld is alleen nodig als je liever de master-token handmatig plakt.) De app onthoudt álle adressen van de server (thuisnetwerk én ZeroTier) en kiest onderweg op 4G/5G automatisch het adres dat bereikbaar is.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            // Library — counts always; sync/share controls only on the server.
            Section("Bibliotheek") {
                LabeledContent("Tracks in database", value: "\(client.trackCount)")
                LabeledContent("Genres in database", value: genreCountLabel)
                LabeledContent("Laatste sync", value: lastSync)

                if role == .server {
                    HStack {
                        Button("Synchroniseer nu") { client.startSync() }
                            .disabled(!client.connectionState.isConnected || client.isSyncing || client.isGenreSyncing)
                        if client.isSyncing {
                            ProgressView()
                                .controlSize(.small)
                            Text(client.syncProgress.phase)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button("Synchroniseer genres") { client.startGenreSync() }
                            .disabled(!client.connectionState.isConnected || client.isSyncing || client.isGenreSyncing)
                        if client.isGenreSyncing {
                            ProgressView()
                                .controlSize(.small)
                            Text(client.syncProgress.phase)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle("Deel bibliotheek voor import (poort 5767)", isOn: Binding(
                        get: { client.isLibrarySharing },
                        set: { client.setLibrarySharing(enabled: $0) }
                    ))
                    Text("Client-apps (Mac/iPhone) halen de bibliotheek hiervandaan op in plaats van zelf urenlang te syncen.")
                        .font(.caption).foregroundStyle(.secondary)

                    if client.isLibrarySharing {
                        LabeledContent("Toegangstoken") {
                            Text(LibraryShareServer.currentToken())
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Toggle("Forceer token (weiger niet-gekoppelde clients)", isOn: Binding(
                            get: { LibraryShareServer.enforceToken },
                            set: { LibraryShareServer.enforceToken = $0 }
                        ))
                        Text("De server deelt ook je instellingen — inclusief API-sleutels en wachtwoorden. Nieuwe clients koppel je zonder token: ze verschijnen onder ‘Apparaten’, waar je ze goedkeurt. Dit token is de handmatige fallback. Met ‘Forceer’ aan krijgen alleen goedgekeurde clients toegang.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if role == .server {
            // LLM
            Section("LLM / Playlist AI") {
                Picker("Provider", selection: $llmProvider) {
                    ForEach(LLMConfig.Provider.allCases, id: \.self) { p in
                        Text(p.rawValue).tag(p)
                    }
                }

                if llmProvider.usesBaseURL {
                    LabeledContent("Base URL") {
                        HStack(spacing: Spacing.sm) {
                            TextField("http://localhost:11434", text: $llmBaseURL)
                                .textFieldStyle(.roundedBorder)
                            if llmProvider == .ollama {
                                Button(isFetchingModels ? "…" : "Haal modellen op") {
                                    Task { await fetchOllamaModels() }
                                }
                                .disabled(isFetchingModels)
                            }
                        }
                    }
                    if llmProvider == .ollama, let host = client.coreHost {
                        Button {
                            llmBaseURL = "http://\(host):11434"
                            Task { await fetchOllamaModels() }
                        } label: {
                            Label("Vind automatisch", systemImage: "magnifyingglass")
                        }
                    }
                }

                LabeledContent("Model") {
                    if ollamaModels.isEmpty {
                        TextField(llmProvider.defaultModel.isEmpty ? "model-naam" : llmProvider.defaultModel,
                                  text: $llmModel)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        Picker("Model", selection: $llmModel) {
                            ForEach(ollamaModels, id: \.self) { m in Text(m).tag(m) }
                        }
                        .labelsHidden()
                    }
                }

                if llmProvider.needsAPIKey {
                    LabeledContent("API-sleutel") {
                        SecureField("Plak hier je sleutel", text: $llmApiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                HStack(spacing: Spacing.md) {
                    Button(llmSaved ? "Bewaard!" : "Bewaar LLM-instellingen") { saveLLMConfig() }
                    Button {
                        Task { await testLLM() }
                    } label: {
                        if isTestingLLM { ProgressView().controlSize(.small) }
                        else { Label("Test verbinding", systemImage: "bolt.horizontal.circle") }
                    }
                    .disabled(isTestingLLM)
                }

                if let llmTestStatus {
                    Label(llmTestStatus, systemImage: llmTestOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(llmTestOK ? Color.roonSuccess : Color.roonDanger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if llmProvider == .gemini {
                    Text("Gebruik je Google AI Studio-sleutel (generativelanguage.googleapis.com). Groot contextvenster — ideaal voor curatie uit een grote bibliotheek.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            // External Services
            Section("Externe diensten") {
                LabeledContent("ListenBrainz-token") {
                    HStack(spacing: Spacing.sm) {
                        SecureField("Plak hier je token", text: $lbToken)
                            .textFieldStyle(.roundedBorder)
                        Button(lbSaved ? "Bewaard!" : "Bewaar") {
                            if lbToken.trimmingCharacters(in: .whitespaces).isEmpty {
                                KeychainStore.delete(key: "listenbrainz_token")
                            } else {
                                KeychainStore.save(key: "listenbrainz_token", value: lbToken.trimmingCharacters(in: .whitespaces))
                            }
                            lbSaved = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { lbSaved = false }
                        }
                    }
                }
                Text("Scrobblet elke track naar ListenBrainz zodra hij echt geluisterd is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(lbLovesBusy ? "Loves importeren…" : (lbLovesResult.isEmpty ? "Importeer loves als likes" : lbLovesResult)) {
                    lbLovesBusy = true
                    Task {
                        let n = await client.importListenBrainzLoves()
                        lbLovesResult = n > 0 ? "\(n) loves geïmporteerd" : "Geen nieuwe loves gevonden"
                        lbLovesBusy = false
                    }
                }
                .disabled(lbLovesBusy)
                Text("Haalt je ListenBrainz-‘loved’ tracks op en zet ze als duim-omhoog op de server; bestaande oordelen blijven staan.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Importeer ListenBrainz-playlists dagelijks", isOn: Binding(
                    get: { client.lbPlaylistSyncEnabled },
                    set: { client.setListenBrainzPlaylistSync(enabled: $0) }
                ))
                Text("Haalt elke dag je ListenBrainz-playlists (eigen + ‘voor jou samengesteld’) op en zet ze in de playlist-bibliotheek van de server, zodat ze in de Playlists-tab verschijnen.")
                    .font(.caption).foregroundStyle(.secondary)
                if client.lbPlaylistSyncEnabled {
                    Toggle("Sync ze ook naar Qobuz", isOn: Binding(
                        get: { client.lbQobuzSyncEnabled },
                        set: { client.setListenBrainzQobuzSync(enabled: $0) }
                    ))
                    .disabled(!client.qobuzConfigured)
                    Text(client.qobuzConfigured
                         ? "Maakt voor elke ListenBrainz-playlist een Qobuz-playlist “ListenBrainz · …” aan en werkt die dagelijks bij."
                         : "Stel eerst je Qobuz-account in (sectie Qobuz) om dit te kunnen gebruiken.")
                        .font(.caption).foregroundStyle(.secondary)

                    Button("Synchroniseer playlists nu") { client.syncListenBrainzPlaylistsNow() }
                    if !client.lbPlaylistSyncStatus.isEmpty {
                        Text(client.lbPlaylistSyncStatus)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            // Discogs (F7 — Discogs Labels discovery producer)
            Section("Discogs") {
                LabeledContent("Persoonlijke access token") {
                    HStack(spacing: Spacing.sm) {
                        SecureField("Plak hier je token", text: $discogsToken)
                            .textFieldStyle(.roundedBorder)
                        Button(discogsSaved ? "Bewaard!" : "Bewaar") {
                            if discogsToken.trimmingCharacters(in: .whitespaces).isEmpty {
                                KeychainStore.delete(key: "discogs_token")
                            } else {
                                KeychainStore.save(key: "discogs_token", value: discogsToken.trimmingCharacters(in: .whitespaces))
                            }
                            discogsSaved = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { discogsSaved = false }
                        }
                    }
                }
                Text("Schakelt de \"Discogs\"-bron in Ontdekkingen in: artiesten op hetzelfde platenlabel als artiesten die je veel speelt. Token aanmaken via discogs.com → instellingen → Developers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Last.fm
            Section("Last.fm") {
                if lfConnected {
                    LabeledContent("Verbonden als", value: lfUsername.isEmpty ? "✓" : lfUsername)
                    Toggle("Scrobble vanuit de app", isOn: $lfScrobbleFromApp)
                    Text("Laat uit als Roon zelf al naar Last.fm scrobbelt — anders krijg je dubbele scrobbles. Het importeren en de top-lijsten hieronder werken los hiervan.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button {
                        Task { await client.importLastfmHistory() }
                    } label: {
                        Label(client.lastfmImportInProgress ? "Bezig met importeren…" : "Importeer volledige Last.fm-historie",
                              systemImage: "square.and.arrow.down")
                    }
                    .disabled(client.lastfmImportInProgress)
                    if client.lastfmImportInProgress {
                        ProgressView()
                    }
                    if !client.lastfmImportStatus.isEmpty {
                        Text(client.lastfmImportStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Eenmalig je hele scrobble-historie binnenhalen — vult jaaroverzicht, smaakprofiel en aanbevelingen. Kan bij een grote historie even duren.")
                        .font(.caption).foregroundStyle(.secondary)

                    Divider()
                    Toggle("Importeer top-tracks als playlists", isOn: Binding(
                        get: { client.lastfmPlaylistSyncEnabled },
                        set: { client.setLastfmPlaylistSync(enabled: $0) }
                    ))
                    Text("Last.fm heeft geen eigen playlists; dit maakt dagelijks playlists van je top-tracks (laatste 7 dagen, maand, jaar, aller tijden). Ze verschijnen met een Last.fm-label in de Playlists-tab.")
                        .font(.caption).foregroundStyle(.secondary)
                    if client.lastfmPlaylistSyncEnabled {
                        Toggle("Sync ze ook naar Qobuz", isOn: Binding(
                            get: { client.lastfmQobuzSyncEnabled },
                            set: { client.setLastfmQobuzSync(enabled: $0) }
                        ))
                        .disabled(!client.qobuzConfigured)
                        Text(client.qobuzConfigured
                             ? "Maakt voor elke lijst een Qobuz-playlist “Last.fm · …” aan en werkt die dagelijks bij."
                             : "Stel eerst je Qobuz-account in (sectie Qobuz) om dit te kunnen gebruiken.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Synchroniseer playlists nu") { client.syncLastfmPlaylistsNow() }
                        if !client.lastfmPlaylistSyncStatus.isEmpty {
                            Text(client.lastfmPlaylistSyncStatus)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    Button("Ontkoppel Last.fm", role: .destructive) {
                        KeychainStore.delete(key: "lastfm_session_key")
                        KeychainStore.delete(key: "lastfm_username")
                        lfConnected = false; lfUsername = ""; lfStatus = ""
                    }
                } else {
                    LabeledContent("API-sleutel") {
                        SecureField("Last.fm API-sleutel", text: $lfApiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("API-secret") {
                        SecureField("Last.fm API-secret", text: $lfApiSecret)
                            .textFieldStyle(.roundedBorder)
                    }
                    if lfPendingToken == nil {
                        Button(lfBusy ? "…" : "Koppel Last.fm") { Task { await lfStartAuth() } }
                            .disabled(lfBusy || lfApiKey.isEmpty || lfApiSecret.isEmpty)
                    } else {
                        Button(lfBusy ? "…" : "Ga verder (na goedkeuren)") { Task { await lfCompleteAuth() } }
                            .disabled(lfBusy)
                    }
                }
                if !lfStatus.isEmpty {
                    Text(lfStatus).font(.caption).foregroundStyle(.secondary)
                }
                Text("Scrobblet elke track naar Last.fm. Maak API-gegevens aan op last.fm/api/account/create.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Qobuz
            Section("Qobuz") {
                LabeledContent("E-mail") {
                    TextField("jij@voorbeeld.nl", text: $qbEmail)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.username)
                }
                LabeledContent("Wachtwoord") {
                    SecureField("Qobuz-wachtwoord", text: $qbPassword)
                        .textFieldStyle(.roundedBorder)
                }
                Button(qbBusy ? "Verifiëren…" : "Bewaar & verifieer") { Task { await saveQobuz() } }
                    .disabled(qbBusy || qbEmail.isEmpty || qbPassword.isEmpty)
                if !qbStatus.isEmpty {
                    Text(qbStatus).font(.caption).foregroundStyle(.secondary)
                }
                Text("Hiermee kun je gegenereerde en bewaarde playlists in je Qobuz-account opslaan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Qobuz local streaming (experimental)
            Section("Qobuz lokaal streamen (experimenteel)") {
                Toggle("Qobuz-tracks op deze iPhone afspelen", isOn: $qbStreamLocal)
                    .onChange(of: qbStreamLocal) { _, v in client.qobuzLocalStreamEnabled = v }
                    .disabled(!client.qobuzConfigured)
                if qbStreamLocal {
                    LabeledContent("app_secret") {
                        SecureField("Qobuz web-player app_secret", text: $qbAppSecret)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button("Bewaar app_secret") { client.qobuzAppSecret = qbAppSecret }
                        .disabled(qbAppSecret.isEmpty)
                }
                Text("Speelt Qobuz-nummers uit je bibliotheek lokaal op je telefoon via Qobuz' onofficiële API (vereist een actief abonnement en de huidige web-player app_secret). Niet door Qobuz ondersteund; werkt mogelijk niet en kan wijzigen. Zonder dit blijven Qobuz-tracks overgeslagen bij lokaal afspelen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LoudnessSettingsSection()

            TranscodeSettingsSection()

            // Audio analyzer
            Section("Audio-analyzer (BPM / toonsoort / tags)") {
                LabeledContent("Analyzer-URL") {
                    TextField("http://10.94.184.22:5766", text: $analyzerURL)
                        .textFieldStyle(.roundedBorder)
                }
                if let host = client.coreHost {
                    Button {
                        analyzerURL = "http://\(host):5766"
                    } label: {
                        Label("Vind automatisch", systemImage: "magnifyingglass")
                    }
                }
                LabeledContent("Gesyncte kenmerken", value: "\(afStats.matched) gematcht / \(afStats.total) totaal")
                Button(afBusy ? "Synchroniseren…" : "Bewaar & sync kenmerken") { Task { await syncAnalyzer() } }
                    .disabled(afBusy || analyzerURL.isEmpty)
                Button("Diagnose match-percentage") { Task { await diagnoseAnalyzer() } }
                    .disabled(afBusy || analyzerURL.isEmpty)
                if !afStatus.isEmpty {
                    Text(afStatus).font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Sonische embeddings (CLAP)", isOn: Binding(
                    get: { client.useSonicEmbeddings },
                    set: { client.useSonicEmbeddings = $0 }))
                Text("Aan: Vergelijkbaar / Sonic DNA / Song Paths / Alchemy / Music Map draaien op de geleerde CLAP-vectoren. Uit: terug naar de BPM/toonsoort/tag-regels (om te vergelijken).")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Haalt BPM, Camelot-toonsoort, energie en LLM-tags op van de analyzer op je muziek-host. Gebruikt voor DJ-sets en tag-curatie.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            } // end role == .server

            // About
            Section("Over") {
                LabeledContent("Versie", value: appVersion)
                LabeledContent("Protocol", value: "MOO/1 · SOOD · GRDB 6")
                #if os(macOS)
                LabeledContent("Platform", value: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
                #else
                LabeledContent("Platform", value: "iOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
                #endif
                NavigationLink {
                    LogConsoleView()
                } label: {
                    Label("Logboek bekijken / delen", systemImage: "doc.text.magnifyingglass")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Instellingen")
        #if os(macOS)
        .frame(width: 440)
        #endif
        .task { afStats = await client.audioFeaturesStats() }
        .onAppear { loadSettingsState() }
        .onChange(of: client.isSyncing) { _, _ in refreshLastSync() }
    }

    /// Loads every field from UserDefaults + Keychain into local @State. Called
    /// on first render and again after a settings sync from the Mac, so the UI
    /// immediately reflects the imported values.
    private func saveServerToken() {
        let t = serverToken.trimmingCharacters(in: .whitespaces)
        serverToken = t
        LibraryShareServer.setConfiguredToken(t)
        savedServerToken = t
        tokenSaved = true
        Haptics.success()
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            tokenSaved = false
        }
    }

    private func loadSettingsState() {
        refreshLastSync()
        lbToken = KeychainStore.load(key: "listenbrainz_token") ?? ""
        discogsToken = KeychainStore.load(key: "discogs_token") ?? ""
        lfApiKey    = KeychainStore.load(key: "lastfm_api_key") ?? ""
        lfApiSecret = KeychainStore.load(key: "lastfm_api_secret") ?? ""
        lfUsername  = KeychainStore.load(key: "lastfm_username") ?? ""
        lfConnected = !(KeychainStore.load(key: "lastfm_session_key") ?? "").isEmpty
        qbEmail    = KeychainStore.load(key: "qobuz_email") ?? ""
        qbPassword = KeychainStore.load(key: "qobuz_password") ?? ""
        qbStreamLocal = client.qobuzLocalStreamEnabled
        qbAppSecret = client.qobuzAppSecret ?? ""
        analyzerURL = client.analyzerURL
        let cfg = LLMConfigStore.load()
        llmProvider = cfg.provider
        llmBaseURL  = cfg.baseURL
        llmModel    = cfg.model
        llmApiKey   = cfg.apiKey
        if cfg.provider == .ollama {
            Task { await fetchOllamaModels() }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (build \(b))"
    }

    private func refreshLastSync() {
        lastSync = (try? client.database?.syncStateValue(forKey: "last_sync")) ?? "Nooit"
    }

    /// Client role: pull settings + library + analyses from the server. With an
    /// explicit URL, sync that host; otherwise auto-discover the server.
    private func syncFromServer(explicit: String? = nil) async {
        settingsSyncBusy = true; defer { settingsSyncBusy = false }
        let trimmed = explicit?.trimmingCharacters(in: .whitespaces)
        if let trimmed, !trimmed.isEmpty {
            settingsSyncStatus = "Synchroniseren met \(trimmed)…"
            if let r = await client.syncEverythingFromServer(baseURL: trimmed) {
                loadSettingsState()
                settingsSyncStatus = "Klaar — \(r.tracks) tracks, \(r.features) kenmerken ✓"
            } else {
                settingsSyncStatus = "Mislukt — draait de RoonSage-server (analyzer) op \(trimmed)?"
            }
        } else {
            settingsSyncStatus = "Server zoeken op poort 5767…"
            if let r = await client.autoSyncEverythingFromServer() {
                serverURL = r.source
                loadSettingsState()
                settingsSyncStatus = "Klaar — \(r.tracks) tracks, \(r.features) kenmerken van \(r.source) ✓"
            } else {
                settingsSyncStatus = "Geen server gevonden — start de RoonSage-server (analyzer) op je always-on Mac."
            }
        }
    }

    private func saveLLMConfig() {
        LLMConfigStore.save(LLMConfig(provider: llmProvider, baseURL: llmBaseURL, model: llmModel, apiKey: llmApiKey))
        llmSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { llmSaved = false }
    }

    /// Fire a tiny completion against the *current* (unsaved) settings so the user
    /// can confirm provider/key/model before relying on it. Uses the same
    /// loopback-retargeting as real generation so a thin client tests the right host.
    private func testLLM() async {
        isTestingLLM = true; llmTestStatus = nil
        defer { isTestingLLM = false }
        var cfg = LLMConfig(provider: llmProvider, baseURL: llmBaseURL, model: llmModel, apiKey: llmApiKey)
        // Apply the same loopback → core-host retargeting as real generation so a
        // thin client tests the host where Ollama actually runs.
        cfg = client.effectiveLLMConfig(cfg)
        if let err = await LLMClient.shared.test(config: cfg) {
            llmTestStatus = err
            llmTestOK = false
        } else {
            llmTestStatus = "Verbinding OK — \(cfg.provider.rawValue) (\(cfg.effectiveModel)) antwoordt."
            llmTestOK = true
        }
    }

    // MARK: - Audio analyzer

    private func syncAnalyzer() async {
        afBusy = true; defer { afBusy = false }
        let url = analyzerURL.trimmingCharacters(in: .whitespaces)
        client.analyzerURL = url
        afStatus = "Kenmerken ophalen…"
        if let r = await client.syncAudioFeatures(from: url) {
            let pct = Int((r.matchRate * 100).rounded())
            afStatus = "\(r.featureRows) kenmerken gesynct — \(r.exactMatched) exact + \(r.fuzzyMatched) fuzzy = \(pct)% van \(r.libraryTracks) tracks gematcht."
            afStats = await client.audioFeaturesStats()
        } else {
            afStatus = "Kon de analyzer niet bereiken op \(url). Draait `roonsage-analyzer serve`?"
        }
    }

    private func diagnoseAnalyzer() async {
        afBusy = true; defer { afBusy = false }
        let url = analyzerURL.trimmingCharacters(in: .whitespaces)
        afStatus = "Diagnosticeren…"
        guard let r = await client.diagnoseAudioFeatures(from: url) else {
            afStatus = "Kon de analyzer niet bereiken op \(url)."
            return
        }
        let pct = Int((r.matchRate * 100).rounded())
        var msg = "Match-percentage \(pct)%: \(r.exactMatched) exact + \(r.fuzzyMatched) fuzzy / \(r.libraryTracks) tracks (\(r.unmatched) niet gematcht, \(r.featureRows) kenmerken). Alleen-lezen — niets gewijzigd."
        if !r.sampleUnmatched.isEmpty {
            msg += "\n\nVoorbeelden zonder match:\n• " + r.sampleUnmatched.prefix(12).joined(separator: "\n• ")
        }
        afStatus = msg
    }

    // MARK: - Qobuz

    private func saveQobuz() async {
        qbBusy = true; defer { qbBusy = false }
        let email = qbEmail.trimmingCharacters(in: .whitespaces)
        let pw = qbPassword
        KeychainStore.save(key: "qobuz_email", value: email)
        KeychainStore.save(key: "qobuz_password", value: pw)
        if let name = await QobuzClient.shared.verify(email: email, password: pw) {
            qbStatus = "Verbonden als \(name)."
        } else {
            qbStatus = "Inloggen mislukt — controleer je e-mail en wachtwoord."
        }
    }

    // MARK: - Last.fm auth flow

    private func lfStartAuth() async {
        lfBusy = true; defer { lfBusy = false }
        let key = lfApiKey.trimmingCharacters(in: .whitespaces)
        let secret = lfApiSecret.trimmingCharacters(in: .whitespaces)
        KeychainStore.save(key: "lastfm_api_key", value: key)
        KeychainStore.save(key: "lastfm_api_secret", value: secret)
        guard let token = await LastfmClient.shared.getToken(apiKey: key, apiSecret: secret) else {
            lfStatus = "Kon geen Last.fm-token krijgen — controleer je API-sleutel en -secret."
            return
        }
        lfPendingToken = token
        if let url = LastfmClient.shared.authURL(apiKey: key, token: token) {
            openURL(url)
        }
        lfStatus = "Keur RoonSage goed in de browser en klik daarna op Ga verder."
    }

    private func lfCompleteAuth() async {
        guard let token = lfPendingToken else { return }
        lfBusy = true; defer { lfBusy = false }
        let key = lfApiKey.trimmingCharacters(in: .whitespaces)
        let secret = lfApiSecret.trimmingCharacters(in: .whitespaces)
        guard let session = await LastfmClient.shared.getSession(apiKey: key, apiSecret: secret, token: token) else {
            lfStatus = "Goedkeuring nog niet afgerond — keur goed in de browser en klik daarna op Ga verder."
            return
        }
        KeychainStore.save(key: "lastfm_session_key", value: session.key)
        KeychainStore.save(key: "lastfm_username", value: session.name)
        lfUsername = session.name
        lfConnected = true
        lfPendingToken = nil
        lfStatus = "Verbonden als \(session.name)."
    }

    private func fetchOllamaModels() async {
        isFetchingModels = true
        defer { isFetchingModels = false }
        let models = await LLMConfigStore.fetchOllamaModels(baseURL: llmBaseURL)
        ollamaModels = models
        if !models.isEmpty, !models.contains(llmModel) {
            llmModel = models.first ?? llmModel
        }
    }
}

/// Loudness normalization for on-device playback (LMS-style ReplayGain UX).
/// Self-contained: binds straight to the `LocalLoudness` UserDefaults keys and
/// pokes the live player so a change is audible without a track skip.
struct LoudnessSettingsSection: View {
    @AppStorage("local_loudness_mode") private var modeRaw = LocalLoudness.Mode.off.rawValue
    @AppStorage("local_loudness_preamp_db") private var preampDB = 0.0

    var body: some View {
        Section("Loudness-normalisatie (lokaal afspelen)") {
            Picker("Modus", selection: $modeRaw) {
                Text("Uit").tag(LocalLoudness.Mode.off.rawValue)
                Text("Per track").tag(LocalLoudness.Mode.track.rawValue)
                Text("Per album").tag(LocalLoudness.Mode.album.rawValue)
            }
            .onChange(of: modeRaw) { _, _ in LocalPlaybackController.shared.reapplyLoudness() }
            if modeRaw != LocalLoudness.Mode.off.rawValue {
                LabeledContent("Pre-amp") {
                    HStack {
                        Slider(value: $preampDB, in: -12...12, step: 1)
                            .onChange(of: preampDB) { _, _ in
                                LocalPlaybackController.shared.reapplyLoudness()
                            }
                        Text(String(format: "%+.0f dB", preampDB))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }
            Text("Egaliseert het volume tussen tracks op dit apparaat op basis van de gemeten LUFS-loudness (doel −14 LUFS). \u{201C}Per album\u{201D} behoudt de dynamiek binnen een album. Werkt alleen bij lokaal afspelen; Roon-zones regelen dit zelf.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// AAC-transcoding for on-device playback over the network (LMS-style
/// bandwidth setting): stream the original at home, a lean AAC on the road.
struct TranscodeSettingsSection: View {
    @AppStorage("local_transcode_mode") private var modeRaw = LocalTranscode.Mode.off.rawValue
    @AppStorage("local_transcode_kbps") private var kbps = 256

    var body: some View {
        Section("Onderweg streamen (lokaal afspelen)") {
            Picker("Transcodeer naar AAC", selection: $modeRaw) {
                Text("Nooit").tag(LocalTranscode.Mode.off.rawValue)
                Text("Alleen mobiele data").tag(LocalTranscode.Mode.cellular.rawValue)
                Text("Altijd").tag(LocalTranscode.Mode.always.rawValue)
            }
            if modeRaw != LocalTranscode.Mode.off.rawValue {
                Picker("Bitrate", selection: $kbps) {
                    Text("128 kbps").tag(128)
                    Text("192 kbps").tag(192)
                    Text("256 kbps").tag(256)
                }
            }
            Text("Laat de server FLAC/lossless omzetten naar AAC vóór het streamen — veel lichter over ZeroTier op mobiele data. Bronnen die al zuiniger zijn dan de gekozen bitrate worden ongemoeid gelaten. Geldt vanaf de volgende track.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
