import SwiftUI
import RoonSageCore

@MainActor
public struct SettingsView: View {
    @Environment(RoonClient.self) private var client
    @Environment(\.openURL) private var openURL
    @State private var lastSync: String = "—"

    public init() {}

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

    // Qobuz
    @State private var qbEmail: String = ""
    @State private var qbPassword: String = ""
    @State private var qbBusy = false
    @State private var qbStatus: String = ""

    // Audio analyzer
    @State private var analyzerURL: String = ""
    @State private var afBusy = false
    @State private var afStatus: String = ""

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
            // Connection
            Section("Roon Connection") {
                LabeledContent("Status", value: client.connectionState.label)
                if let host = client.coreHost {
                    LabeledContent("Host", value: "\(host):\(client.corePort)")
                }
                HStack {
                    Button("Disconnect") {
                        Task { await client.disconnect() }
                    }
                    .disabled(!client.connectionState.isConnected)

                    Button("Re-authorize", role: .destructive) {
                        Task { await client.clearAndReauthorize() }
                    }
                    .disabled(!client.connectionState.isConnected)
                }
            }

            // Library
            Section("Library") {
                LabeledContent("Tracks in database", value: "\(client.trackCount)")
                LabeledContent("Last sync", value: lastSync)
                HStack {
                    Button("Sync Now") { client.startSync() }
                        .disabled(!client.connectionState.isConnected || client.isSyncing)
                    if client.isSyncing {
                        ProgressView()
                            .controlSize(.small)
                        Text(client.syncProgress.phase)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

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
                                Button(isFetchingModels ? "…" : "Fetch models") {
                                    Task { await fetchOllamaModels() }
                                }
                                .disabled(isFetchingModels)
                            }
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
                    LabeledContent("API Key") {
                        SecureField("Paste key here", text: $llmApiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Button(llmSaved ? "Saved!" : "Save LLM settings") { saveLLMConfig() }
            }

            // External Services
            Section("External Services") {
                LabeledContent("ListenBrainz token") {
                    HStack(spacing: 8) {
                        SecureField("Paste token here", text: $lbToken)
                            .textFieldStyle(.roundedBorder)
                        Button(lbSaved ? "Saved!" : "Save") {
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
                Text("Scrobbles each track to ListenBrainz as it starts playing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Last.fm
            Section("Last.fm") {
                if lfConnected {
                    LabeledContent("Connected as", value: lfUsername.isEmpty ? "✓" : lfUsername)
                    Button("Disconnect Last.fm", role: .destructive) {
                        KeychainStore.delete(key: "lastfm_session_key")
                        KeychainStore.delete(key: "lastfm_username")
                        lfConnected = false; lfUsername = ""; lfStatus = ""
                    }
                } else {
                    LabeledContent("API Key") {
                        SecureField("Last.fm API key", text: $lfApiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("API Secret") {
                        SecureField("Last.fm API secret", text: $lfApiSecret)
                            .textFieldStyle(.roundedBorder)
                    }
                    if lfPendingToken == nil {
                        Button(lfBusy ? "…" : "Connect Last.fm") { Task { await lfStartAuth() } }
                            .disabled(lfBusy || lfApiKey.isEmpty || lfApiSecret.isEmpty)
                    } else {
                        Button(lfBusy ? "…" : "Continue (after authorizing)") { Task { await lfCompleteAuth() } }
                            .disabled(lfBusy)
                    }
                }
                if !lfStatus.isEmpty {
                    Text(lfStatus).font(.caption).foregroundStyle(.secondary)
                }
                Text("Scrobbles each track to Last.fm as it plays. Create API credentials at last.fm/api/account/create.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Qobuz
            Section("Qobuz") {
                LabeledContent("Email") {
                    TextField("you@example.com", text: $qbEmail)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.username)
                }
                LabeledContent("Password") {
                    SecureField("Qobuz password", text: $qbPassword)
                        .textFieldStyle(.roundedBorder)
                }
                Button(qbBusy ? "Verifying…" : "Save & verify") { Task { await saveQobuz() } }
                    .disabled(qbBusy || qbEmail.isEmpty || qbPassword.isEmpty)
                if !qbStatus.isEmpty {
                    Text(qbStatus).font(.caption).foregroundStyle(.secondary)
                }
                Text("Lets you save generated and saved playlists to your Qobuz account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Audio analyzer
            Section("Audio Analyzer (BPM / key / tags)") {
                LabeledContent("Analyzer URL") {
                    TextField("http://10.94.184.22:5766", text: $analyzerURL)
                        .textFieldStyle(.roundedBorder)
                }
                let stats = client.audioFeaturesStats()
                LabeledContent("Synced features", value: "\(stats.matched) matched / \(stats.total) total")
                Button(afBusy ? "Syncing…" : "Save & sync features") { Task { await syncAnalyzer() } }
                    .disabled(afBusy || analyzerURL.isEmpty)
                if !afStatus.isEmpty {
                    Text(afStatus).font(.caption).foregroundStyle(.secondary)
                }
                Text("Pulls BPM, Camelot key, energy and LLM tags from the analyzer running on your music host. Used for DJ sets and tag-based curation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // About
            Section("About") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Protocol", value: "MOO/1 · SOOD · GRDB 6")
                #if os(macOS)
                LabeledContent("Platform", value: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
                #else
                LabeledContent("Platform", value: "iOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
                #endif
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        #if os(macOS)
        .frame(width: 440)
        #endif
        .onAppear {
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
        .onChange(of: client.isSyncing) { _, _ in refreshLastSync() }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (build \(b))"
    }

    private func refreshLastSync() {
        lastSync = (try? client.database?.syncStateValue(forKey: "last_sync")) ?? "Never"
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
        afStatus = "Fetching features…"
        if let r = await client.syncAudioFeatures(from: url) {
            afStatus = "Synced \(r.received) features — \(r.matched) matched to your library."
        } else {
            afStatus = "Could not reach the analyzer at \(url). Is `roonsage-analyzer serve` running?"
        }
    }

    // MARK: - Qobuz

    private func saveQobuz() async {
        qbBusy = true; defer { qbBusy = false }
        let email = qbEmail.trimmingCharacters(in: .whitespaces)
        let pw = qbPassword
        KeychainStore.save(key: "qobuz_email", value: email)
        KeychainStore.save(key: "qobuz_password", value: pw)
        if let name = await QobuzClient.shared.verify(email: email, password: pw) {
            qbStatus = "Connected as \(name)."
        } else {
            qbStatus = "Login failed — check your email and password."
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
            lfStatus = "Could not get a Last.fm token — check your API key and secret."
            return
        }
        lfPendingToken = token
        if let url = LastfmClient.shared.authURL(apiKey: key, token: token) {
            openURL(url)
        }
        lfStatus = "Authorize RoonSage in the browser, then click Continue."
    }

    private func lfCompleteAuth() async {
        guard let token = lfPendingToken else { return }
        lfBusy = true; defer { lfBusy = false }
        let key = lfApiKey.trimmingCharacters(in: .whitespaces)
        let secret = lfApiSecret.trimmingCharacters(in: .whitespaces)
        guard let session = await LastfmClient.shared.getSession(apiKey: key, apiSecret: secret, token: token) else {
            lfStatus = "Authorization not complete yet — approve in the browser, then click Continue."
            return
        }
        KeychainStore.save(key: "lastfm_session_key", value: session.key)
        KeychainStore.save(key: "lastfm_username", value: session.name)
        lfUsername = session.name
        lfConnected = true
        lfPendingToken = nil
        lfStatus = "Connected as \(session.name)."
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
