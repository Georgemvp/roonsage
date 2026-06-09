import AnalyzerCore
import AudioAnalysis
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

func option(_ name: String) -> String? {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
    return nil
}

let args = CommandLine.arguments
let command = args.count >= 2 ? args[1] : ""

switch command {
case "analyze":
    guard args.count >= 3 else {
        print("usage: roonsage-analyzer analyze <musicdir> [--db <path>] [--workers N]"); exit(1)
    }
    let store = try FeatureStore(path: option("--db") ?? FeatureStore.defaultPath())
    let workers = option("--workers").flatMap { Int($0) } ?? max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
    print("Analyzing \(args[2]) with \(workers) workers (resumable)…")
    let (ok, failed) = await LibraryWalker(store: store, concurrency: workers).run(musicDir: args[2]) { p in
        if (p.done + p.failed) % 50 == 0 {
            print(String(format: "  %d/%d (%.1f/s, ETA %.0fs, %d failed)", p.done + p.failed, p.total, p.rate, p.etaSeconds, p.failed))
        }
    }
    print("Done. \(ok) analyzed, \(failed) failed. Store holds \(store.count()) tracks.")

case "tag":
    let store = try FeatureStore(path: option("--db") ?? FeatureStore.defaultPath())
    let ollama = option("--ollama") ?? "http://127.0.0.1:11434"
    let model = option("--model") ?? "qwen3.5:4b-mlx"
    print("Tagging via \(ollama) (\(model))…")
    await Tagger(store: store, ollamaURL: ollama, model: model).run { p in
        if (p.tagged + p.failed) % 25 == 0 { print("  \(p.tagged) tagged, \(p.failed) failed (\(p.total) total)") }
    }
    print("Tagging done: \(store.taggedCount())/\(store.count()).")

case "serve":
    let store = try FeatureStore(path: option("--db") ?? FeatureStore.defaultPath())
    let port = UInt16(option("--port") ?? "5766") ?? 5766
    let server = HTTPServer(port: port, store: store)
    try server.start()
    print("Serving \(store.count()) tracks on http://0.0.0.0:\(port)/features  (Ctrl-C to stop)")
    while true { try await Task.sleep(nanoseconds: 3_600_000_000_000) }

case "stats":
    let store = try FeatureStore(path: option("--db") ?? FeatureStore.defaultPath())
    print("tracks: \(store.count())  tagged: \(store.taggedCount())")

case "":
    print("""
    usage: roonsage-analyzer <command>
      analyze <musicdir> [--db path] [--workers N]    walk + analyze + store
      tag [--db path] [--ollama url] [--model name]    LLM-tag stored tracks
      serve [--db path] [--port 5766]                  serve features over HTTP
      stats [--db path]                                show counts
      <audiofile> …                                    analyze single file(s)
    """)
    exit(1)

default:
    for path in args.dropFirst() {
        let url = URL(fileURLWithPath: path)
        let meta = MetadataReader.read(url: url)
        if let f = try? AudioAnalyzer.analyze(url: url) {
            print("\(url.lastPathComponent): \(meta.artist ?? "?") — \(meta.title ?? "?")  BPM \(f.bpm) \(f.keyRoot) \(f.keyMode) [\(f.camelot)] energy \(String(format: "%.3f", f.energy))")
        } else {
            print("\(url.lastPathComponent): analysis failed")
        }
    }
}
