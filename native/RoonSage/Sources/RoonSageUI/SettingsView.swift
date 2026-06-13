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
    @AppStorage("themeMode") private var themeMode: ThemeMode = .system
    @AppStorage("accentChoice") private var accent: AccentChoice = .gold
    @State private var lastSync: String = "—"

    // Server sync (client role: pull settings + library + features from the server)
    @State private var serverURL: String = UserDefaults.standard.string(forKey: "library_import_url") ?? ""
    @State private var settingsSyncBusy = false
    @State private var settingsSyncStatus: String?

    public init(role: SettingsRole = .client) {
        self.role = role
    }

    // ListenBrainz
    @State private var lbToken: String = ""
    @State private var lbSaved = false

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

    // Audio analyzer
    @State private var analyzerURL: String = ""
    @State private var afBusy = false
    @State private var afStatus: String = ""
    // Loaded in .task — a DB read in `body` blocked main on every render.
    @State private var afStats: (total: Int, matched: Int) = (0, 0)

    // LLM
    @State private var llmProvider: LLMConfig.Provider = .ollama
    @State private var llmBaseURL:  String = "http://localhost:11434"
    @State private var llmModel:    String = "qwen3.5:4b-mlx"
    @State private var llmApiKey:   String = ""
    @State private var llmSaved     = false
    @State private var ollamaModels: [String] = []
    @State private var isFetchingModels = false

    public var body: some View {
        Form {
            // Appearance
            Section("Verschijning") {
                Picker("Thema", selection: $themeMode) {
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
                    Text("Haalt instellingen, de muziekbibliotheek en de analyses op van de RoonSage-server (de analyzer op je always-on Mac). De eerste keer moet je dit apparaat nog wel goedkeuren in Roon.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            // Library — counts always; sync/share controls only on the server.
            Section("Bibliotheek") {
                LabeledContent("Tracks in database", value: "\(client.trackCount)")
                LabeledContent("Genres in database", value: client.genreCount == 0 ? "Niet gesynchroniseerd" : "\(client.genreCount)")
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

                if llmProvider == .ollama || llmProvider == .custom {
                    LabeledContent("Base URL") {
                        HStack(spacing: 8) {
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
                        TextField("qwen3.5:4b-mlx", text: $llmModel)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        Picker("Model", selection: $llmModel) {
                            ForEach(ollamaModels, id: \.self) { m in Text(m).tag(m) }
                        }
                        .labelsHidden()
                    }
                }

                if llmProvider != .ollama {
                    LabeledContent("API-sleutel") {
                        SecureField("Plak hier je sleutel", text: $llmApiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Button(llmSaved ? "Bewaard!" : "Bewaar LLM-instellingen") { saveLLMConfig() }
            }

            // External Services
            Section("Externe diensten") {
                LabeledContent("ListenBrainz-token") {
                    HStack(spacing: 8) {
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
    private func loadSettingsState() {
        refreshLastSync()
        lbToken = KeychainStore.load(key: "listenbrainz_token") ?? ""
        lfApiKey    = KeychainStore.load(key: "lastfm_api_key") ?? ""
        lfApiSecret = KeychainStore.load(key: "lastfm_api_secret") ?? ""
        lfUsername  = KeychainStore.load(key: "lastfm_username") ?? ""
        lfConnected = !(KeychainStore.load(key: "lastfm_session_key") ?? "").isEmpty
        qbEmail    = KeychainStore.load(key: "qobuz_email") ?? ""
        qbPassword = KeychainStore.load(key: "qobuz_password") ?? ""
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
