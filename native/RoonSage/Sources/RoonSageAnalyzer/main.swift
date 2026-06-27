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
    let clap = args.contains("--no-clap") ? nil : CLAPModel.load()
    print("Analyzing \(args[2]) with \(workers) workers (resumable)…")
    print(clap == nil ? "  CLAP embeddings: off (scalar-only)" : "  CLAP embeddings: on (\(clap!.modelVersion))")
    let (ok, failed) = await LibraryWalker(store: store, concurrency: workers, clap: clap).run(musicDir: args[2]) { p in
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

case "enrich":
    // Album-level MusicBrainz genre enrichment + genre hierarchy. Rate-limited
    // (~1 req/s) and resumable, so it's safe to re-run / interrupt.
    let store = try FeatureStore(path: option("--db") ?? FeatureStore.defaultPath())
    let client = option("--user-agent").map { MusicBrainzClient(userAgent: $0) } ?? MusicBrainzClient.shared
    print("Enriching \(store.count()) tracks with MusicBrainz genres (resumable)…")
    await GenreEnricher(store: store, client: client).run { p in
        if (p.albums % 25 == 0) || (p.checked % 100 == 0) {
            print("  \(p.albums) albums, \(p.enriched)/\(p.checked) tracks with genres (\(p.total) total)")
        }
    }
    print("Enrichment done: \(store.mbEnrichedCount())/\(store.count()) tracks, \(store.taxonomyCount()) genres in taxonomy.")

case "serve":
    let store = try FeatureStore(path: option("--db") ?? FeatureStore.defaultPath())
    let port = UInt16(option("--port") ?? "5766") ?? 5766
    let clap = args.contains("--no-clap") ? nil : CLAPModel.load()
    // No Keychain access in the CLI — read the shared token from the environment.
    // Unset → server runs open (it warns at start); set it to gate the corpus.
    let shareToken = ProcessInfo.processInfo.environment["ROONSAGE_SHARE_TOKEN"]
    let server = HTTPServer(port: port, store: store, clap: clap, token: shareToken)
    try server.start()
    print("Serving \(store.count()) tracks on http://0.0.0.0:\(port)/features  (Ctrl-C to stop)")
    print(clap?.canEmbedText == true ? "  text search: /text-embed enabled" : "  text search: disabled (no CLAP)")
    while true { try await Task.sleep(nanoseconds: 3_600_000_000_000) }

case "stats":
    let store = try FeatureStore(path: option("--db") ?? FeatureStore.defaultPath())
    print("tracks: \(store.count())  tagged: \(store.taggedCount())")

case "matchcheck":
    // Measure analyzer↔library match rate on the real DBs (E1 proof).
    guard let lib = option("--library") else {
        print("usage: roonsage-analyzer matchcheck --library <library.db> [--db <analyzer.db>]"); exit(1)
    }
    let featureDB = option("--db") ?? FeatureStore.defaultPath()
    print(try MatchChecker.run(libraryDB: lib, featureDB: featureDB))

case "validate":
    // Measure analyzer accuracy against a reference CSV (artist,title,bpm,camelot).
    guard args.count >= 3, let ref = option("--reference") else {
        print("usage: roonsage-analyzer validate <musicdir> --reference <csv> [--limit N]"); exit(1)
    }
    guard let csv = try? String(contentsOfFile: ref, encoding: .utf8) else {
        print("Could not read reference CSV at \(ref)"); exit(1)
    }
    let reference = AccuracyValidator.parseReferenceCSV(csv)
    print("Reference: \(reference.count) labelled tracks. Scanning \(args[2])…")
    let limit = option("--limit").flatMap { Int($0) }
    let exts: Set<String> = ["flac", "mp3", "m4a", "mp4", "aac", "ogg", "opus", "wav", "aiff", "aif"]
    var report = AccuracyValidator.Report()
    let en = FileManager.default.enumerator(at: URL(fileURLWithPath: args[2]),
                                            includingPropertiesForKeys: nil)
    while let any = en?.nextObject() {
        guard let url = any as? URL, exts.contains(url.pathExtension.lowercased()) else { continue }
        let meta = MetadataReader.read(url: url)
        let key = TrackIdentity.matchKey(artist: meta.artist, album: nil, title: meta.title)
        guard let refRow = reference[key] else { continue }
        guard let f = try? AudioAnalyzer.analyze(url: url) else { continue }
        report.add(analyzedBPM: f.bpm, refBPM: refRow.bpm,
                   analyzedCamelot: f.camelot, refCamelot: refRow.camelot)
        if report.compared % 25 == 0 { print("  compared \(report.compared)…") }
        if let limit, report.compared >= limit { break }
    }
    print("\n" + report.formatted())

case "":
    print("""
    usage: roonsage-analyzer <command>
      analyze <musicdir> [--db path] [--workers N] [--no-clap]   walk + analyze + store
      tag [--db path] [--ollama url] [--model name]    LLM-tag stored tracks
      enrich [--db path] [--user-agent ua]             MusicBrainz genre enrichment + hierarchy
      serve [--db path] [--port 5766]                  serve features over HTTP
      stats [--db path]                                show counts
      matchcheck --library <library.db> [--db path]    measure analyzer↔library match rate
      validate <musicdir> --reference <csv> [--limit N]  measure BPM/key accuracy
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
