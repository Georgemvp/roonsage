import AnalyzerCore
import AudioAnalysis
import Foundation
import Observation
import RoonSageCore
import ServiceManagement

@MainActor
@Observable
final class AnalyzerModel {
    var musicPath: String { didSet { UserDefaults.standard.set(musicPath, forKey: "music_path") } }
    var ollamaURL: String { didSet { UserDefaults.standard.set(ollamaURL, forKey: "ollama_url") } }
    var model: String { didSet { UserDefaults.standard.set(model, forKey: "ollama_model") } }
    var port: String { didSet { UserDefaults.standard.set(port, forKey: "serve_port") } }
    var autoStart: Bool { didSet { UserDefaults.standard.set(autoStart, forKey: "auto_start") } }

    // Analyse-tuning — neemt effect bij de VOLGENDE (re-)analyse, niet met terugwerkende kracht.
    var walkerConcurrency: Int { didSet { UserDefaults.standard.set(walkerConcurrency, forKey: "walker_concurrency") } }
    var excerptSeconds: Double { didSet { UserDefaults.standard.set(excerptSeconds, forKey: "excerpt_seconds") } }
    var analysisSampleRate: Double { didSet { UserDefaults.standard.set(analysisSampleRate, forKey: "analysis_sample_rate") } }
    var bpmMin: Double { didSet { UserDefaults.standard.set(bpmMin, forKey: "bpm_min") } }
    var bpmMax: Double { didSet { UserDefaults.standard.set(bpmMax, forKey: "bpm_max") } }
    var bpmPrior: Double { didSet { UserDefaults.standard.set(bpmPrior, forKey: "bpm_prior") } }
    // Tagging-tuning (Ollama).
    var tagConcurrency: Int { didSet { UserDefaults.standard.set(tagConcurrency, forKey: "tag_concurrency") } }
    var tagContextTokens: Int { didSet { UserDefaults.standard.set(tagContextTokens, forKey: "tag_context_tokens") } }
    var tagTemperature: Double { didSet { UserDefaults.standard.set(tagTemperature, forKey: "tag_temperature") } }
    var tagBatchSize: Int { didSet { UserDefaults.standard.set(tagBatchSize, forKey: "tag_batch_size") } }

    // Onderhoud & beveiliging.
    var launchAtLogin: Bool { didSet { applyLaunchAtLogin(launchAtLogin) } }
    var logLevelRaw: Int {
        didSet {
            UserDefaults.standard.set(logLevelRaw, forKey: "log_level")
            Log.minimumLevel = LogLevel(rawValue: logLevelRaw) ?? .info
        }
    }
    /// Force the share token even for not-yet-paired clients (vs the default grace
    /// window). Mirrors LibraryShareServer.enforceToken (UserDefaults-backed).
    var enforceToken: Bool {
        get { LibraryShareServer.enforceToken }
        set { LibraryShareServer.enforceToken = newValue }
    }
    private(set) var maintenanceStatus: String?

    private(set) var trackCount = 0
    private(set) var taggedCount = 0
    private(set) var analyze: AnalyzeProgress?
    private(set) var isAnalyzing = false
    private(set) var tag: TagProgress?
    private(set) var isTagging = false
    private(set) var isServing = false
    var status = ""

    private let store: FeatureStore?
    private var walker: LibraryWalker?
    private var tagger: Tagger?
    private var server: HTTPServer?
    private var clap: CLAPModel?   // loaded off-main once; enables /text-embed
    /// While serving, periodically re-publishes the feature revision so changes
    /// made by a SEPARATE process (e.g. `roonsage-analyzer enrich`) writing to the
    /// shared analyzer.db are picked up — not just in-app analysis/backfill.
    private var revisionRefreshTask: Task<Void, Never>?

    init() {
        store = try? FeatureStore(path: FeatureStore.defaultPath())
        musicPath = UserDefaults.standard.string(forKey: "music_path") ?? ""
        ollamaURL = UserDefaults.standard.string(forKey: "ollama_url") ?? "http://127.0.0.1:11434"
        model = UserDefaults.standard.string(forKey: "ollama_model") ?? "qwen3.5:4b-mlx"
        port = UserDefaults.standard.string(forKey: "serve_port") ?? "5766"
        autoStart = UserDefaults.standard.object(forKey: "auto_start") as? Bool ?? true
        walkerConcurrency = UserDefaults.standard.object(forKey: "walker_concurrency") as? Int ?? 3
        excerptSeconds = UserDefaults.standard.object(forKey: "excerpt_seconds") as? Double ?? 120
        analysisSampleRate = UserDefaults.standard.object(forKey: "analysis_sample_rate") as? Double ?? 22050
        bpmMin = UserDefaults.standard.object(forKey: "bpm_min") as? Double ?? 60
        bpmMax = UserDefaults.standard.object(forKey: "bpm_max") as? Double ?? 200
        bpmPrior = UserDefaults.standard.object(forKey: "bpm_prior") as? Double ?? 120
        tagConcurrency = UserDefaults.standard.object(forKey: "tag_concurrency") as? Int ?? 6
        tagContextTokens = UserDefaults.standard.object(forKey: "tag_context_tokens") as? Int ?? 8192
        tagTemperature = UserDefaults.standard.object(forKey: "tag_temperature") as? Double ?? 0.4
        tagBatchSize = UserDefaults.standard.object(forKey: "tag_batch_size") as? Int ?? 200
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled   // reflect, don't register (didSet skipped in init)
        } else {
            launchAtLogin = false
        }
        logLevelRaw = UserDefaults.standard.object(forKey: "log_level") as? Int ?? LogLevel.info.rawValue
        Log.minimumLevel = LogLevel(rawValue: logLevelRaw) ?? .info
        refresh()
    }

    func refresh() {
        trackCount = store?.count() ?? 0
        taggedCount = store?.taggedCount() ?? 0
        // Keep the advertised feature revision in step with the store so remotes
        // re-pull after in-app analysis/backfill completes — not only after a
        // re-serve. Cheap: refresh() runs at completion, never on the poll path.
        publishFeatureRevision()
    }

    /// Called on launch: start analyzing if auto-start is on and a folder is set.
    func autoStartIfEnabled() {
        if autoStart, !musicPath.isEmpty, !isAnalyzing { startAnalyze() }
    }

    func startAnalyze() {
        guard let store, !musicPath.isEmpty, !isAnalyzing else { return }
        isAnalyzing = true
        analyze = nil
        status = "Scanning…"
        let w = LibraryWalker(store: store, concurrency: walkerConcurrency,
                              excerptSeconds: excerptSeconds, sampleRate: analysisSampleRate,
                              minBpm: bpmMin, maxBpm: bpmMax, priorBpm: bpmPrior)
        walker = w
        let path = musicPath
        Task {
            let (ok, failed) = await w.run(musicDir: path) { p in
                Task { @MainActor in self.analyze = p }
            }
            isAnalyzing = false
            refresh()
            status = "Analyzed \(ok), \(failed) failed. \(trackCount) tracks total."
        }
    }

    func cancelAnalyze() { walker?.cancel() }

    func startTag() {
        guard let store, !isTagging, trackCount > 0 else { return }
        isTagging = true
        tag = nil
        status = "Tagging via Ollama…"
        let t = Tagger(store: store, ollamaURL: ollamaURL, model: model, concurrency: tagConcurrency,
                       contextTokens: tagContextTokens, temperature: tagTemperature, batchSize: tagBatchSize)
        tagger = t
        Task {
            await t.run { p in Task { @MainActor in self.tag = p } }
            isTagging = false
            refresh()
            status = "Tagged \(taggedCount)/\(trackCount)."
        }
    }

    func cancelTag() { tagger?.cancel() }

    // MARK: - Maintenance & login item

    private func applyLaunchAtLogin(_ on: Bool) {
        guard #available(macOS 13.0, *) else { status = "Start-bij-inloggen vereist macOS 13 of nieuwer."; return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            status = "Login-item kon niet worden ingesteld: \(error.localizedDescription)"
        }
    }

    /// Write a timestamped snapshot of analyzer.db next to the original. The
    /// VACUUM INTO runs off the main actor so a large DB doesn't freeze the UI.
    func backupDatabase() {
        guard let store else { return }
        maintenanceStatus = "Back-up maken…"
        let src = store.databasePath
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dst = (src as NSString).deletingLastPathComponent + "/analyzer-backup-\(stamp).db"
        Task.detached {
            let msg: String
            do { try store.backup(toPath: dst); msg = "Back-up gemaakt: \(dst)" }
            catch { msg = "Back-up mislukt: \(error.localizedDescription)" }
            await MainActor.run { self.maintenanceStatus = msg }
        }
    }

    func vacuumDatabase() {
        guard let store else { return }
        maintenanceStatus = "Database opschonen…"
        Task.detached {
            let msg: String
            do { try store.vacuum(); msg = "Database opgeschoond." }
            catch { msg = "Opschonen mislukt: \(error.localizedDescription)" }
            await MainActor.run { self.maintenanceStatus = msg }
        }
    }

    // MARK: - Ollama connection test (for tagging)

    private(set) var ollamaTestStatus: String?

    /// Probe the configured Ollama (`/api/tags`) and report reachability + whether
    /// the chosen model is installed — validates the tagging setup before a run.
    func testOllama() {
        ollamaTestStatus = "Testen…"
        let urlStr = ollamaURL, want = model
        Task {   // @MainActor inherited; the await suspends without blocking the UI
            guard let url = URL(string: "\(urlStr)/api/tags") else { ollamaTestStatus = "Ongeldige Ollama-URL"; return }
            do {
                var req = URLRequest(url: url, timeoutInterval: 6)
                req.httpMethod = "GET"
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    ollamaTestStatus = "Ollama antwoordde met een fout"; return
                }
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let names = (obj?["models"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
                let has = names.contains { $0 == want || $0 == "\(want):latest" || $0.hasPrefix("\(want):") }
                ollamaTestStatus = has
                    ? "✓ Verbonden — model '\(want)' beschikbaar (\(names.count) modellen)"
                    : "⚠︎ Verbonden, maar '\(want)' niet gevonden. Beschikbaar: \(names.prefix(4).joined(separator: ", "))"
            } catch {
                ollamaTestStatus = "Niet bereikbaar: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - CLAP model lifecycle

    enum CLAPLoadState { case idle, loading, ready, failed }
    private(set) var clapLoadState: CLAPLoadState = .idle

    /// Whether the CLAP text model is loaded (needed to compute attribute probes).
    var clapReady: Bool {
        if case .ready = clapLoadState { return true }
        return false
    }

    /// Load the CLAP model if not already loaded or loading.
    /// Safe to call multiple times; only the first call does work.
    /// Loading happens on the main actor (CoreML requirement) but the method
    /// returns immediately — watch `clapLoadState` / `clapReady` for completion.
    func loadCLAPIfNeeded() {
        guard case .idle = clapLoadState else { return }
        clapLoadState = .loading
        Task { @MainActor in
            let loaded = CLAPModel.load()
            let note = "loaded=\(loaded != nil) canEmbedText=\(loaded?.canEmbedText ?? false) at=\(Date())"
            if let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                try? note.write(to: dir.appendingPathComponent("RoonSageAnalyzer/clap_status.txt"),
                                atomically: true, encoding: .utf8)
            }
            self.clap = loaded
            self.server?.attachCLAP(loaded)
            self.clapLoadState = loaded != nil ? .ready : .failed
            if self.isServing, let p = UInt16(self.port) {
                self.status = "Serving on \(p)" + (loaded?.canEmbedText == true ? " — text search ready." : " (text model unavailable).")
            }
        }
    }

    // MARK: - Attribute backfill (derive valence/danceability/… from stored embeddings)

    private(set) var isBackfilling = false
    /// Embedded rows still missing the CLAP attribute axes.
    var missingAttributes: Int { store?.missingAttributesCount() ?? 0 }

    /// Derive attributes for already-embedded rows — no audio re-read, no re-scan.
    func startAttributeBackfill() {
        guard let store, let clap, !isBackfilling, !isAnalyzing else { return }
        isBackfilling = true
        status = "Attributen berekenen uit embeddings…"
        let w = LibraryWalker(store: store, clap: clap)
        Task {
            let n = await w.backfillAttributes { done in
                Task { @MainActor in self.status = "Attributen berekend: \(done)…" }
            }
            isBackfilling = false
            refresh()
            status = "Attributen berekend voor \(n) tracks."
        }
    }

    /// Start the feature server on launch if it isn't already running — this app
    /// is the always-on server, so /features (5766) should be up without a click.
    func startServingIfNeeded() {
        if !isServing { toggleServe() }
    }

    func toggleServe() {
        if isServing {
            revisionRefreshTask?.cancel(); revisionRefreshTask = nil
            server?.stop(); server = nil; isServing = false; status = "Stopped serving."
            return
        }
        guard let store, let p = UInt16(port) else { status = "Invalid port."; return }
        // Start the server IMMEDIATELY (clap nil) so /features + /embeddings are
        // up without waiting on the slow CoreML load. The CLAP model loads
        // off-main and is attached to the running server (no rebind) to enable
        // /text-embed. A status file records the load outcome for diagnostics.
        // Gate the server with the same shared token clients pair with, so the
        // feature/embedding corpus isn't open over ZeroTier/LAN. Loopback is
        // exempt; /health stays public.
        let s = HTTPServer(port: p, store: store, clap: clap, token: LibraryShareServer.currentToken())
        do {
            try s.start()
            server = s
            isServing = true
            status = clapReady ? "Serving on \(p)." : "Serving on \(p) — loading text model…"
            // Publish a cached feature signature (computed here, not per-poll) so
            // remotes auto-re-pull when analyses change. Use the FULL signature
            // (adds/embeds/tags/attrs + MB genres), not just count/embedded —
            // otherwise genre-only enrichment never bumps the revision and remotes
            // never re-pull the new genres/taxonomy. A slow timer keeps it fresh
            // against out-of-process writes (the `enrich` CLI on the same DB).
            publishFeatureRevision()
            startRevisionRefresh()
            // Advertise our own analyzer endpoint so remotes import the correct
            // features URL (loopback is rewritten to the share host on import) —
            // they no longer have to *guess* the port (:5766 vs the share :5767).
            RoonClient.shared.analyzerURL = "http://127.0.0.1:\(p)"
        } catch {
            status = "Serve failed: \(error.localizedDescription)"
            return
        }
        // Kick off CLAP loading (no-op if already loading/loaded).
        // loadCLAPIfNeeded() updates status + attaches the model to the server
        // once it finishes; the server starts immediately so /features is up fast.
        loadCLAPIfNeeded()
    }

    /// Recompute and advertise the full feature signature (adds/embeds/tags/attrs
    /// + MB genres). Cheap single read; only assigns on change. Called at serve
    /// start, after in-app analysis/backfill, and on the slow refresh timer —
    /// never on the per-poll path that the cached revision exists to protect.
    private func publishFeatureRevision() {
        guard isServing, let store else { return }
        let sig = store.contentSignature()
        if RoonClient.shared.featuresRevision != sig { RoonClient.shared.featuresRevision = sig }
    }

    /// While serving, re-publish the feature revision on a slow cadence so writes
    /// from a SEPARATE process (`roonsage-analyzer enrich` against the shared
    /// analyzer.db) are eventually advertised and remotes re-pull — in-app work
    /// already republishes synchronously via refresh(). 30s is far off the hot
    /// path; the signature is a handful of COUNTs.
    private func startRevisionRefresh() {
        revisionRefreshTask?.cancel()
        revisionRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.publishFeatureRevision()
            }
        }
    }
}
