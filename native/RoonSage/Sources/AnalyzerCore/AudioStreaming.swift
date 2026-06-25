import Foundation

/// Pure helpers for the `/audio` streaming endpoint (local playback on the
/// phone). Kept free of `Network`/IO so they unit-test in isolation: HTTP Range
/// parsing, content-type mapping, and path-safety checks.
public enum AudioStreaming {
    /// Audio container extensions the analyser walks (mirrors
    /// `LibraryWalker.audioExtensions` / `AudioDecoder`). Only these are served.
    public static let allowedExtensions: Set<String> =
        ["flac", "m4a", "mp3", "wav", "aiff", "aif", "alac", "aac"]

    /// MIME type for a file path, by extension. Falls back to a generic audio
    /// type so an unknown-but-allowed container still plays.
    public static func contentType(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "flac": return "audio/flac"
        case "mp3": return "audio/mpeg"
        case "m4a", "alac", "aac": return "audio/mp4"
        case "wav": return "audio/wav"
        case "aiff", "aif": return "audio/aiff"
        default: return "application/octet-stream"
        }
    }

    /// True when `ext` (no dot, any case) is a servable audio container.
    public static func isAllowedExtension(_ ext: String) -> Bool {
        allowedExtensions.contains(ext.lowercased())
    }

    /// Outcome of parsing a `Range` header against a known file size.
    public enum RangeResult: Equatable {
        /// No range (or an unparseable one) — serve the whole file as `200`.
        case full
        /// A satisfiable byte range, inclusive on both ends — serve as `206`.
        case partial(start: Int, end: Int)
        /// A syntactically valid but unsatisfiable range — answer `416`.
        case unsatisfiable
    }

    /// Parse a single HTTP `Range` header value (e.g. `bytes=0-1023`,
    /// `bytes=500-`, `bytes=-2048`) against `fileSize`. Only the first range of
    /// a multi-range request is honoured (more than enough for `AVPlayer`).
    /// Anything malformed degrades to `.full` rather than erroring.
    public static func parseRange(_ headerValue: String?, fileSize: Int) -> RangeResult {
        guard let raw = headerValue?.trimmingCharacters(in: .whitespaces),
              raw.lowercased().hasPrefix("bytes=") else { return .full }
        let specPart = raw.dropFirst("bytes=".count)
        // Honour only the first range in a comma list.
        let spec = specPart.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard let dash = spec.firstIndex(of: "-") else { return .full }
        let leftStr = spec[spec.startIndex..<dash]
        let rightStr = spec[spec.index(after: dash)...]

        guard fileSize > 0 else { return .unsatisfiable }
        let lastIndex = fileSize - 1

        if leftStr.isEmpty {
            // Suffix range: last N bytes.
            guard let n = Int(rightStr), n > 0 else { return .full }
            let start = Swift.max(0, fileSize - n)
            return .partial(start: start, end: lastIndex)
        }

        guard let start = Int(leftStr), start >= 0 else { return .full }
        if start > lastIndex { return .unsatisfiable }
        let end: Int
        if rightStr.isEmpty {
            end = lastIndex
        } else {
            guard let e = Int(rightStr), e >= start else { return .full }
            end = Swift.min(e, lastIndex)
        }
        return .partial(start: start, end: end)
    }

    /// Read a byte slice `[start, end]` (inclusive) from a file without loading
    /// the whole thing — keeps memory bounded when `AVPlayer` requests ranges of
    /// a large FLAC. Returns nil on any IO error.
    public static func readSlice(path: String, start: Int, end: Int) -> Data? {
        guard end >= start, start >= 0,
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(start))
            let length = end - start + 1
            return try handle.read(upToCount: length)
        } catch {
            return nil
        }
    }

    /// File size in bytes, or nil if the path is missing/unreadable.
    public static func fileSize(path: String) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int else { return nil }
        return size
    }
}
