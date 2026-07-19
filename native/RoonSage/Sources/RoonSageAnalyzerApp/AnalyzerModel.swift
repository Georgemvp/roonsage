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
    /// Trickle MusicBrainz genre enrichment in the background (rate-limited, resumable).
    var autoEnrich: Bool { didSet { UserDefaults.standard.set(autoEnrich, forKey: "auto_enrich") } }
    /// Trickle Deezer popularity enrichment in the background (rate-limited, resumable).
    var autoPopularity: Bool { didSet { UserDefaults.standard.set(autoPopularity, forKey: "auto_popularity") } }
    /// Trickle the F3 loudness backfill in the background (decodes pre-F3 tracks,
    /// disk-gentle, resumable).
    var autoLoudness: Bool { didSet { UserDefaults.standard.set(autoLoudness, forKey: "auto_loudness") } }
    /// Trickle preview-embeddings for file-less (Qobuz-only) library tracks via
    /// Deezer 30s previews (network-gentle, resumable) — makes them radio
    /// candidates like any analyzed track.
    var autoPreview: Bool { didSet { UserDefaults.standard.set(autoPreview, forKey: "auto_preview") } }
    /// Trickle Deezer genre backfill in the background (rate-limited, resumable)
    /// — a second genre signal alongside MusicBrainz, whose per-release coverage
    /// is sparse. Feeds the library's genre vocabulary discovery scores against.
    var autoDeezerGenre: Bool { didSet { UserDefaults.standard.set(autoDeezerGenre, forKey: "auto_deezer_genre") } }

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

    /// Path to the distilled MusicMoveArr sidecar (`metadata.db`) DatasetProducer
    /// reads for offline discovery candidates. UserDefaults-backed (RoonClient),
    /// same key the discovery-context builder reads — set either by fetching a
    /// published dataset release or by pointing at a locally distilled one.
    var datasetSidecarPath: String {
        get { RoonClient.shared.datasetSidecarPath }
        set { RoonClient.shared.datasetSidecarPath = newValue }
    }
    private(set) var isrcCount = 0
    private(set) var isFetchingDataset = false
    private(set) var datasetFetchStatus: String?

    private(set) var trackCount = 0
    private(set) var taggedCount = 0
    private(set) var analyze: AnalyzeProgress?
    private(set) var isAnalyzing = false
    private(set) var tag: ClapTagProgress?
    private(set) var isTagging = false
    private(set) var enrich: EnrichProgress?
    private(set) var isEnriching = false
    private(set) var mbEnrichedCount = 0
    private(set) var popularity: PopularityProgress?
    private(set) var isPopularityEnriching = false
    private(set) var popularityCount = 0
    private(set) var loudness: LoudnessProgress?
    private(set) var isLoudnessBackfilling = false
    private(set) var loudnessCount = 0
    private(set) var preview: PreviewProgress?
    private(set) var isPreviewBackfilling = false
    private(set) var previewCount = 0
    private(set) var deezerGenre: DeezerGenreProgress?
    private(set) var isDeezerGenreEnriching = false
    private(set) var deezerGenreCount = 0
    private(set) var isServing = false
    var status = ""

    private let store: FeatureStore?
    private var walker: LibraryWalker?
    private var tagger: ClapTagger?
    private var enricher: GenreEnricher?
    private var popularityEnricher: PopularityEnricher?
    private var loudnessBackfill: LoudnessBackfill?
    private var previewBackfill: PreviewEmbeddingBackfill?
    private var deezerGenreEnricher: DeezerGenreEnricher?
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
        autoEnrich = UserDefaults.standard.object(forKey: "auto_enrich") as? Bool ?? true
        autoPopularity = UserDefaults.standard.object(forKey: "auto_popularity") as? Bool ?? true
        autoLoudness = UserDefaults.standard.object(forKey: "auto_loudness") as? Bool ?? true
        autoPreview = UserDefaults.standard.object(forKey: "auto_preview") as? Bool ?? true
        autoDeezerGenre = UserDefaults.standard.object(forKey: "auto_deezer_genre") as? Bool ?? true
        walkerConcurrency = UserDefaults.standard.object(forKey: "walker_concurrency") as? Int ?? 3
        // One-shot migratie (2026-07, AudioMuse-pariteit): analyse dekt voortaan
        // standaard de VOLLEDIGE track. Flipt een bestaand opgeslagen 120 s-default
        // één keer; wie daarna bewust een fragment kiest, behoudt die keuze.
        if !UserDefaults.standard.bool(forKey: "full_track_analysis_migrated") {
            UserDefaults.standard.set(0.0, forKey: "excerpt_seconds")
            UserDefaults.standard.set(true, forKey: "full_track_analysis_migrated")
        }
        excerptSeconds = UserDefaults.standard.object(forKey: "excerpt_seconds") as? Double ?? 0
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
        mbEnrichedCount = store?.mbEnrichedCount() ?? 0
        popularityCount = store?.popularityCount() ?? 0
        loudnessCount = store?.loudnessCount() ?? 0
        previewCount = store?.previewRowCount() ?? 0
        isrcCount = store?.isrcCount() ?? 0
        deezerGenreCount = store?.deezerGenreEnrichedCount() ?? 0
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
        let path = musicPath
        Task {
            // Embeddings horen bij de hoofd-walk: wacht op het CLAP-model vóór
            // de walker start. Een .full-pass met clap=nil zou bestaande
            // embeddings wissen (upsert schrijft embedding=NULL) én alles
            // scalar-only analyseren — de race die de eerste heranalyse-run
            // op 2026-07-13 166 embeddings kostte.
            let clap = await awaitCLAP()
            if clap == nil { Log.info("Analyse start zonder CLAP-model (niet geïnstalleerd?) — scalar-only.", category: .audio) }
            let w = LibraryWalker(store: store, concurrency: walkerConcurrency, clap: clap,
                                  excerptSeconds: excerptSeconds, sampleRate: analysisSampleRate,
                                  minBpm: bpmMin, maxBpm: bpmMax, priorBpm: bpmPrior)
            walker = w
            let (ok, failed) = await w.run(musicDir: path) { p in
                Task { @MainActor in self.analyze = p }
            }
            isAnalyzing = false
            refresh()
            status = "Analyzed \(ok), \(failed) failed. \(trackCount) tracks total."
            // Newly analyzed tracks have no MusicBrainz genres / popularity yet —
            // let the background enrichers pick them up (resumable, rate-limited).
            autoEnrichIfEnabled()
            autoPopularityIfEnabled()
            // Analysis done → the disk is free; fill loudness on the pre-F3 backlog.
            autoLoudnessIfEnabled()
            // File-less (Qobuz-only) tracks: embed from Deezer previews.
            autoPreviewIfEnabled()
            // Deezer genre backfill — second signal alongside MB enrichment.
            autoDeezerGenreIfEnabled()
            // Zero-shot CLAP tags for new/legacy rows (local, no network).
            autoTagIfNeeded()
        }
    }

    func cancelAnalyze() { walker?.cancel() }

    /// Volledige heranalyse (AudioMuse-pariteit): markeer alle rows en start de
    /// walker — scalars én embedding worden opnieuw uit de volledige track
    /// berekend; tags/MB-genres/populariteit blijven staan (upsert raakt ze niet).
    func reanalyzeAll() {
        guard let store, !musicPath.isEmpty, !isAnalyzing else { return }
        _ = try? store.markAllForReanalysis()
        startAnalyze()
    }

    /// Zero-shot CLAP tagging: scores every embedded track against the fixed
    /// vocabulary (audio-grounded). Replaces the Ollama tagger, which guessed
    /// tags from metadata it never heard and collapsed the vocabulary onto its
    /// own prompt examples ("driving" on 62% of the library).
    func startTag() {
        guard let store, !isTagging, trackCount > 0 else { return }
        isTagging = true
        tag = nil
        status = "Tags scoren op audio (CLAP)…"
        Task {
            guard let clap = await awaitCLAP() else {
                isTagging = false
                status = "Taggen vereist het CLAP-model (niet geladen)."
                return
            }
            let t = ClapTagger(store: store, clap: clap)
            tagger = t
            await t.run { p in Task { @MainActor in self.tag = p } }
            isTagging = false
            refresh()
            status = "Tags: \(store.clapTaggedCount(version: ClapTagVocabulary.version))/\(trackCount) audio-gegrond."
        }
    }

    func cancelTag() { tagger?.cancel() }

    /// Retag automatically after an analysis pass: new tracks have no tags yet,
    /// and legacy (Ollama) rows lag the current vocabulary version. Exits
    /// instantly when everything is stamped, so it's cheap to call every time.
    func autoTagIfNeeded() {
        guard let store, !isTagging,
              !store.rowsNeedingClapTags(version: ClapTagVocabulary.version, limit: 1).isEmpty
        else { return }
        startTag()
    }

    // MARK: - MusicBrainz genre enrichment

    /// Enrich the library with hierarchical MusicBrainz genres + taxonomy. Runs
    /// in-process against the same analyzer.db, so the serving app advertises the
    /// new genres via the feature-revision signature (no separate CLI needed).
    /// Album-level (one MB lookup per album), rate-limited ~1 req/s, resumable —
    /// safe to cancel and re-run; only un-enriched rows are queried.
    func startEnrich() {
        guard let store, !isEnriching, trackCount > 0 else { return }
        isEnriching = true
        enrich = nil
        status = "MusicBrainz-genres ophalen…"
        let e = GenreEnricher(store: store, client: .shared)
        enricher = e
        Task {
            await e.run { p in Task { @MainActor in self.enrich = p } }
            isEnriching = false
            refresh()
            status = "Genre-verrijking: \(mbEnrichedCount)/\(trackCount) tracks verrijkt."
        }
    }

    func cancelEnrich() { enricher?.cancel() }

    /// Called on launch and after analysis: trickle genre enrichment in the
    /// background when enabled. The worker exits fast when there's nothing left to
    /// do, so this is cheap to call even on a fully enriched library.
    func autoEnrichIfEnabled() {
        guard autoEnrich, !isEnriching, store != nil, trackCount > 0 else { return }
        startEnrich()
    }

    // MARK: - Deezer popularity enrichment

    /// Attach Deezer's global popularity (`rank`) to each analyzed track. Runs
    /// in-process against the same analyzer.db and bumps the feature-revision
    /// signature so serving clients re-pull. Rate-limited (~6 req/s), resumable —
    /// safe to cancel and re-run; only un-checked rows are queried. No auth needed
    /// (Deezer's public API is keyless — unlike Last.fm/Spotify).
    func startPopularity() {
        guard let store, !isPopularityEnriching, trackCount > 0 else { return }
        isPopularityEnriching = true
        popularity = nil
        status = "Populariteit ophalen (Deezer)…"
        let e = PopularityEnricher(store: store, client: .shared)
        popularityEnricher = e
        Task {
            await e.run { p in Task { @MainActor in self.popularity = p } }
            isPopularityEnriching = false
            refresh()
            status = "Populariteit: \(popularityCount)/\(trackCount) tracks."
        }
    }

    func cancelPopularity() { popularityEnricher?.cancel() }

    /// Trickle popularity enrichment in the background when enabled. Exits fast
    /// when there's nothing left to do, so it's cheap to call on every launch.
    func autoPopularityIfEnabled() {
        guard autoPopularity, !isPopularityEnriching, store != nil, trackCount > 0 else { return }
        startPopularity()
    }

    /// Backfill perceptual loudness (F3) onto tracks analyzed before it existed.
    /// Disk-gentle (single file at a time), resumable, and idempotent — safe to
    /// cancel and re-run. Uses the current excerpt/sample-rate so backfilled values
    /// match a live analysis.
    func startLoudness() {
        guard let store, !isLoudnessBackfilling, trackCount > 0 else { return }
        isLoudnessBackfilling = true
        loudness = nil
        status = "Loudness berekenen (voor DJ-sets)…"
        let b = LoudnessBackfill(store: store, excerptSeconds: excerptSeconds, sampleRate: analysisSampleRate)
        loudnessBackfill = b
        Task {
            await b.run { p in Task { @MainActor in self.loudness = p } }
            isLoudnessBackfilling = false
            refresh()
            status = "Loudness: \(loudnessCount)/\(trackCount) tracks."
        }
    }

    func cancelLoudness() { loudnessBackfill?.cancel() }

    /// Trickle the loudness backfill in the background when enabled. Exits fast when
    /// coverage is complete, so it's cheap to call on every launch.
    ///
    /// It runs ALONGSIDE the analysis walk rather than waiting for it: the walk
    /// re-enumerates the whole (large, USB-resident) tree on every launch, which
    /// would otherwise keep the backfill permanently starved. The backfill is
    /// single-threaded with a per-file pause, so the extra disk load stays modest
    /// even during a walk. `refresh()` first so a launch call before the initial
    /// count is populated still proceeds.
    func autoLoudnessIfEnabled() {
        guard autoLoudness, !isLoudnessBackfilling, store != nil else { return }
        if trackCount == 0 { refresh() }
        guard trackCount > 0 else { return }
        startLoudness()
    }

    // MARK: - Preview embeddings (Qobuz-only tracks)

    /// Embed the file-less part of the library (Qobuz-added tracks) from Deezer
    /// 30s previews so they join the radios/similarity like any analyzed track.
    /// Network-only (no disk contention with the walk), rate-limited, resumable;
    /// negative lookups are memoised so it converges and then exits instantly.
    func startPreview() {
        guard let store, let clap, !isPreviewBackfilling else {
            if clap == nil { Log.info("Preview-embeddings wachten op het CLAP-model…", category: .audio) }
            return
        }
        isPreviewBackfilling = true
        preview = nil
        status = "Preview-embeddings ophalen (Qobuz-tracks)…"
        let b = PreviewEmbeddingBackfill(store: store, clap: clap)
        previewBackfill = b
        Task {
            let embedded = await b.run(
                backlog: { await RoonClient.shared.unanalyzedTrackCount() },
                wants: { limit, offset in
                    await RoonClient.shared.unanalyzedTracks(limit: limit, offset: offset).map {
                        (matchKey: $0.matchKey, title: $0.title, artist: $0.artist, album: $0.album)
                    }
                },
                onProgress: { p in Task { @MainActor in self.preview = p } })
            isPreviewBackfilling = false
            refresh()
            publishFeatureRevision()
            status = "Preview-embeddings: \(previewCount) tracks zonder bestand geëmbed (+\(embedded) deze run)."
        }
    }

    func cancelPreview() { previewBackfill?.cancel() }

    /// Trickle the preview backfill when enabled. Waits for the CLAP model; exits
    /// fast when the backlog is fully attempted, so it's cheap to call on launch.
    func autoPreviewIfEnabled() {
        guard autoPreview, !isPreviewBackfilling, store != nil else { return }
        guard clap != nil else {
            // CLAP loads asynchronously right after launch — retry once it lands.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                await MainActor.run { self?.autoPreviewIfEnabled() }
            }
            return
        }
        startPreview()
    }

    // MARK: - Deezer genre backfill (second signal alongside MusicBrainz)

    /// Backfill owned tracks' genres from Deezer's album-detail endpoint — MB's
    /// per-release genre coverage is sparse, and this feeds the library's genre
    /// vocabulary that discovery scoring compares candidates against (a
    /// genre-less library side silently zeroes out genreOverlap for otherwise
    /// good candidates). One track-search + one album-lookup per album,
    /// resumable, rate-limited by DeezerClient (~6.6 req/s).
    func startDeezerGenre() {
        guard let store, !isDeezerGenreEnriching, trackCount > 0 else { return }
        isDeezerGenreEnriching = true
        deezerGenre = nil
        status = "Deezer-genres ophalen…"
        let e = DeezerGenreEnricher(store: store)
        deezerGenreEnricher = e
        Task {
            await e.run { p in Task { @MainActor in self.deezerGenre = p } }
            isDeezerGenreEnriching = false
            refresh()
            status = "Deezer-genres: \(deezerGenreCount)/\(trackCount) tracks."
        }
    }

    func cancelDeezerGenre() { deezerGenreEnricher?.cancel() }

    /// Trickle Deezer genre enrichment in the background when enabled. Exits
    /// fast when there's nothing left to do, so it's cheap to call on launch.
    func autoDeezerGenreIfEnabled() {
        guard autoDeezerGenre, !isDeezerGenreEnriching, store != nil, trackCount > 0 else { return }
        startDeezerGenre()
    }

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

    // MARK: - Dataset (MusicMoveArr) — one-click fetch of a published sidecar

    /// Download the newest published `dataset-vN` GitHub Release asset, gunzip it,
    /// run the same offline identity import `import-dataset` does, and — on
    /// success — point DatasetProducer at it. Lets a new install skip the
    /// multi-hour torrent + DuckDB distillation entirely.
    func downloadCuratedDataset() {
        guard let store, !isFetchingDataset else { return }
        isFetchingDataset = true
        datasetFetchStatus = "Zoeken naar gepubliceerde dataset…"
        Task.detached {
            do {
                guard let release = await DatasetFetcher.fetchLatestRelease() else {
                    await MainActor.run {
                        self.isFetchingDataset = false
                        self.datasetFetchStatus = "Geen gepubliceerde dataset gevonden."
                    }
                    return
                }
                await MainActor.run { self.datasetFetchStatus = "Downloaden (dataset-v\(release.version))…" }
                let path = DatasetFetcher.defaultSidecarPath()
                try await DatasetFetcher.download(release, to: path)
                await MainActor.run { self.datasetFetchStatus = "Identiteit koppelen (ISRC/MBID)…" }
                let importer = try DatasetImporter(store: store, sidecarPath: path)
                try await importer.run { p in
                    Task { @MainActor in
                        self.datasetFetchStatus = "Koppelen: \(p.matched)/\(p.checked) tracks (\(p.total) totaal)…"
                    }
                }
                await MainActor.run {
                    self.datasetSidecarPath = path
                    self.refresh()
                    self.isFetchingDataset = false
                    self.datasetFetchStatus = "Dataset-v\(release.version) actief — \(self.isrcCount)/\(self.trackCount) tracks met ISRC."
                }
            } catch {
                await MainActor.run {
                    self.isFetchingDataset = false
                    self.datasetFetchStatus = "Mislukt: \(error)"
                }
            }
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

    /// Wacht tot de CLAP-load afgerond is (start hem zo nodig) en geef het
    /// model terug — nil wanneer laden faalde (model niet geïnstalleerd); de
    /// aanroeper degradeert dan expliciet naar scalar-only.
    private func awaitCLAP() async -> CLAPModel? {
        loadCLAPIfNeeded()
        while case .loading = clapLoadState {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return clap
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
    /// Also re-derives the `arousal` axis for older 4-axis rows (perceptual energy,
    /// the fix for linear-RMS `energy` mis-ordering) — same embedding-only path.
    func startAttributeBackfill() {
        guard let store, let clap, !isBackfilling, !isAnalyzing else { return }
        isBackfilling = true
        status = "Attributen berekenen uit embeddings…"
        let w = LibraryWalker(store: store, clap: clap)
        Task {
            let n = await w.backfillAttributes { done in
                Task { @MainActor in self.status = "Attributen berekend: \(done)…" }
            }
            let r = await w.refreshAttributes(missingKey: "arousal") { done in
                Task { @MainActor in self.status = "Arousal (perceptuele energie) berekend: \(done)…" }
            }
            isBackfilling = false
            refresh()
            publishFeatureRevision()
            status = "Attributen berekend voor \(n) tracks (+\(r) arousal-herberekend)."
        }
    }

    /// Trickle the arousal re-derivation when older rows lack it — the one-time
    /// migration to perceptual energy. Embedding-only (no disk/audio), so it
    /// coexists with the analysis walk (NOT gated on `isAnalyzing`, unlike the
    /// disk-bound loudness backfill — else the re-walk would starve it). Retries
    /// once the CLAP model lands; exits instantly once every row carries the axis.
    func autoArousalRefreshIfNeeded() {
        guard let store, !isBackfilling else { return }
        let missing = store.attributesMissingKeyCount("arousal")
        guard missing > 0 else { return }
        guard let clap else {
            // CLAP loads asynchronously right after launch — retry once it lands.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                await MainActor.run { self?.autoArousalRefreshIfNeeded() }
            }
            return
        }
        isBackfilling = true
        Log.info("Arousal (perceptuele energie) herberekenen uit embeddings — \(missing) rijen te gaan", category: .audio)
        status = "Perceptuele energie (arousal) berekenen uit embeddings…"
        let w = LibraryWalker(store: store, clap: clap)
        Task {
            let r = await w.refreshAttributes(missingKey: "arousal") { done in
                Task { @MainActor in self.status = "Arousal berekend: \(done)…" }
            }
            isBackfilling = false
            refresh()
            publishFeatureRevision()
            Log.info("Arousal-herberekening klaar: \(r) tracks", category: .audio)
            status = "Arousal (perceptuele energie) berekend voor \(r) tracks."
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
        // Accept the master token OR any device the user approved under
        // "Apparaten" — mirrors the share server (5767). Without this a
        // zero-config-paired phone (which holds its own device token, not the
        // master) gets 401 on /audio + /features while the rest of the app works.
        let s = HTTPServer(port: p, store: store, clap: clap,
                           token: LibraryShareServer.currentToken(),
                           isApprovedToken: { LibraryShareServer.isApprovedDevice($0) })
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
