import Foundation

/// Formats a DJ set / playlist into a shareable setlist — a readable text
/// tracklist (with BPM + Camelot key) and an M3U variant. Used by the Share
/// button so a set can leave the app (notes, Rekordbox import, etc.).
public enum SetlistExport {
    public struct Track {
        public let n: Int
        public let title: String
        public let artist: String?
        public let bpm: Double?
        public let camelot: String?
        public init(n: Int, title: String, artist: String?, bpm: Double?, camelot: String?) {
            self.n = n; self.title = title; self.artist = artist; self.bpm = bpm; self.camelot = camelot
        }
    }

    /// Human-readable setlist, e.g. "1. Artist — Title  [124 BPM · 8A]".
    public static func text(name: String, tracks: [Track]) -> String {
        var lines = ["🎧 \(name)", ""]
        for t in tracks {
            var meta: [String] = []
            if let b = t.bpm, b > 0 { meta.append("\(Int(b)) BPM") }
            if let c = t.camelot, !c.isEmpty { meta.append(c) }
            let suffix = meta.isEmpty ? "" : "  [\(meta.joined(separator: " · "))]"
            let who = t.artist.map { "\($0) — " } ?? ""
            lines.append("\(t.n). \(who)\(t.title)\(suffix)")
        }
        return lines.joined(separator: "\n")
    }

    /// Extended-M3U variant with per-track BPM comments.
    public static func m3u(name: String, tracks: [Track]) -> String {
        var lines = ["#EXTM3U", "#PLAYLIST:\(name)"]
        for t in tracks {
            if let b = t.bpm, b > 0 { lines.append("#EXTBPM:\(Int(b))") }
            let who = t.artist.map { "\($0) - " } ?? ""
            lines.append("#EXTINF:-1,\(who)\(t.title)")
        }
        return lines.joined(separator: "\n")
    }
}
