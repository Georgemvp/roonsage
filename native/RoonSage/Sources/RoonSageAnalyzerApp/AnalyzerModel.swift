import AnalyzerCore
import Foundation
import Observation

@MainActor
@Observable
final class AnalyzerModel {
    var musicPath: String { didSet { UserDefaults.standard.set(musicPath, forKey: "music_path") } }
    var ollamaURL: String { didSet { UserDefaults.standard.set(ollamaURL, forKey: "ollama_url") } }
    var model: String { didSet { UserDefaults.standard.set(model, forKey: "ollama_model") } }
    var port: String { didSet { UserDefaults.standard.set(port, forKey: "serve_port") } }
    var autoStart: Bool { didSet { UserDefaults.standard.set(autoStart, forKey: "auto_start") } }

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

    init() {
        store = try? FeatureStore(path: FeatureStore.defaultPath())
        musicPath = UserDefaults.standard.string(forKey: "music_path") ?? ""
        ollamaURL = UserDefaults.standard.string(forKey: "ollama_url") ?? "http://127.0.0.1:11434"
        model = UserDefaults.standard.string(forKey: "ollama_model") ?? "qwen3.5:4b-mlx"
        port = UserDefaults.standard.string(forKey: "serve_port") ?? "5766"
        autoStart = UserDefaults.standard.object(forKey: "auto_start") as? Bool ?? true
        refresh()
    }

    func refresh() {
        trackCount = store?.count() ?? 0
        taggedCount = store?.taggedCount() ?? 0
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
        let w = LibraryWalker(store: store)
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
        let t = Tagger(store: store, ollamaURL: ollamaURL, model: model)
        tagger = t
        Task {
            await t.run { p in Task { @MainActor in self.tag = p } }
            isTagging = false
            refresh()
            status = "Tagged \(taggedCount)/\(trackCount)."
        }
    }

    func cancelTag() { tagger?.cancel() }

    /// Start the feature server on launch if it isn't already running — this app
    /// is the always-on server, so /features (5766) should be up without a click.
    func startServingIfNeeded() {
        if !isServing { toggleServe() }
    }

    func toggleServe() {
        if isServing {
            server?.stop(); server = nil; isServing = false; status = "Stopped serving."
            return
        }
        guard let store, let p = UInt16(port) else { status = "Invalid port."; return }
        let s = HTTPServer(port: p, store: store)
        do {
            try s.start()
            server = s
            isServing = true
            status = "Serving on port \(p)."
        } catch {
            status = "Serve failed: \(error.localizedDescription)"
        }
    }
}
