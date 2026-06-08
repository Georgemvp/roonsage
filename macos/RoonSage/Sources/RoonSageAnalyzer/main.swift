import AudioAnalysis
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: roonsage-analyzer <audiofile> [<audiofile> …]")
    exit(1)
}

for path in args.dropFirst() {
    let url = URL(fileURLWithPath: path)
    do {
        let t0 = Date()
        let f = try AudioAnalyzer.analyze(url: url)
        let dt = Date().timeIntervalSince(t0)
        print(String(
            format: "%-50@  BPM %6.1f (%.2f)  %@ %-5@ [%@]  energy %.3f  %.1fs  (%.2fs)",
            url.lastPathComponent as NSString,
            f.bpm, f.bpmConfidence,
            f.keyRoot as NSString, f.keyMode as NSString, f.camelot as NSString,
            f.energy, f.durationSec, dt
        ))
    } catch {
        print("\(url.lastPathComponent): error \(error)")
    }
}
