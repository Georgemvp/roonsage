/// RoonSage MCP Server — stdio JSON-RPC bridge for Claude Desktop.
///
/// Tools exposed:
///   roon_zones          — list all zones + now-playing
///   roon_play_pause     — toggle playback on a zone
///   roon_next / roon_previous — skip tracks
///   roon_set_volume     — set absolute volume on an output
///   roon_set_shuffle    — enable/disable shuffle
///   roon_set_repeat     — set repeat mode (disabled/loop/loop_one)
///   roon_search_library — search local track database by title/artist/album
///   get_library_stats   — genre breakdown, decade distribution, artist/album counts
///   filter_tracks       — filter library by genre/decade/artist/keywords → numbered list + session_id
///   curate_and_play     — play tracks from a filter session in a Roon zone

import Foundation
@preconcurrency import RoonSageCore

// MARK: - MCP wire types

struct MCPRequest: Decodable {
    let jsonrpc: String
    let id: JSONValue?
    let method: String
    let params: [String: JSONValue]?
}

struct MCPResponse: Encodable {
    let jsonrpc = "2.0"
    let id: JSONValue?
    let result: JSONValue?
    let error: MCPError?
}

struct MCPError: Encodable {
    let code: Int
    let message: String
}

enum JSONValue: Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil()              { self = .null; return }
        if let v = try? c.decode(Bool.self)   { self = .bool(v); return }
        if let v = try? c.decode(Int.self)    { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self)         { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.typeMismatch(JSONValue.self, .init(codingPath: decoder.codingPath, debugDescription: "Unknown type"))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:           try c.encodeNil()
        case .bool(let v):   try c.encode(v)
        case .int(let v):    try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v):  try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var intValue: Int?       { if case .int(let i) = self { return i }; return nil }
    var boolValue: Bool?     { if case .bool(let b) = self { return b }; return nil }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }; return nil
    }
}

// MARK: - Filter session store (in-process, keyed by UUID)

actor FilterSessionStore {
    private var sessions: [String: [Int: TrackRecord]] = [:]

    func store(_ tracks: [TrackRecord]) -> String {
        let id = UUID().uuidString
        var map: [Int: TrackRecord] = [:]
        for (i, t) in tracks.enumerated() { map[i + 1] = t }
        sessions[id] = map
        return id
    }

    func resolve(sessionID: String, numbers: [Int]) -> [TrackRecord] {
        guard let map = sessions[sessionID] else { return [] }
        return numbers.compactMap { map[$0] }
    }

    func all(sessionID: String) -> [TrackRecord] {
        guard let map = sessions[sessionID] else { return [] }
        return map.sorted { $0.key < $1.key }.map { $0.value }
    }
}

// MARK: - MCP Server

@MainActor
final class MCPServer {

    private let client = RoonClient()
    private let sessions = FilterSessionStore()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func run() async {
        await client.discoverAndConnect()
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        while let line = readLine(strippingNewline: true), !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let req = try? decoder.decode(MCPRequest.self, from: data) else { continue }
            let response = await handle(req)
            if let json = try? encoder.encode(response),
               let str = String(data: json, encoding: .utf8) {
                print(str)
                fflush(stdout)
            }
        }
    }

    // MARK: - Dispatch

    private func handle(_ req: MCPRequest) async -> MCPResponse {
        switch req.method {
        case "initialize":
            return success(req.id, result: .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string("roonsage"), "version": .string("2.0.0")])
            ]))
        case "tools/list":
            return success(req.id, result: .object(["tools": .array(toolDefinitions)]))
        case "tools/call":
            return await callTool(req)
        default:
            return error(req.id, code: -32601, message: "Method not found: \(req.method)")
        }
    }

    private func callTool(_ req: MCPRequest) async -> MCPResponse {
        guard let name = req.params?["name"]?.stringValue else {
            return error(req.id, code: -32602, message: "Missing tool name")
        }
        let args = req.params?["arguments"]
        let argObj: [String: JSONValue]
        if case .object(let o) = args { argObj = o } else { argObj = [:] }

        do {
            let text = try await executeTool(name: name, args: argObj)
            return success(req.id, result: .object([
                "content": .array([.object(["type": .string("text"), "text": .string(text)])])
            ]))
        } catch {
            return self.error(req.id, code: -32603, message: error.localizedDescription)
        }
    }

    // MARK: - Tool implementations

    private func executeTool(name: String, args: [String: JSONValue]) async throws -> String {
        switch name {

        // ── Zones ───────────────────────────────────────────────────────────

        case "roon_zones":
            if client.zones.isEmpty { return "No active zones." }
            return client.zones.map { z in
                var s = "Zone: \(z.displayName) [\(z.state.rawValue)]  zone_id: \(z.id)"
                if let np = z.nowPlaying {
                    s += "\n  Now playing: \(np.title)"
                    if let a = np.artist  { s += " — \(a)" }
                    if let al = np.album  { s += " (\(al))" }
                }
                if let out = z.outputs.first, let vol = out.volume {
                    s += "\n  Volume: \(vol.value)\(vol.isMuted ? " (muted)" : "")  output_id: \(out.id)"
                }
                return s
            }.joined(separator: "\n\n")

        // ── Transport ────────────────────────────────────────────────────────

        case "roon_play_pause":
            let z = try requireString(args, key: "zone_id")
            await client.playPause(zoneID: z)
            return "Toggled playback on zone \(z)."

        case "roon_next":
            let z = try requireString(args, key: "zone_id")
            await client.next(zoneID: z)
            return "Skipped to next track."

        case "roon_previous":
            let z = try requireString(args, key: "zone_id")
            await client.previous(zoneID: z)
            return "Went to previous track."

        case "roon_set_volume":
            let outputID = try requireString(args, key: "output_id")
            guard let value = args["value"]?.intValue else { throw ToolError.missingArg("value") }
            await client.setVolume(outputID: outputID, value: value)
            return "Volume set to \(value)."

        case "roon_set_shuffle":
            let z = try requireString(args, key: "zone_id")
            let enabled = args["enabled"]?.boolValue ?? true
            await client.setShuffle(zoneID: z, enabled: enabled)
            return "Shuffle \(enabled ? "on" : "off")."

        case "roon_set_repeat":
            let z = try requireString(args, key: "zone_id")
            let mode = args["mode"]?.stringValue ?? "disabled"
            await client.setRepeat(zoneID: z, mode: mode)
            return "Repeat set to \(mode)."

        // ── Library search ───────────────────────────────────────────────────

        case "roon_search_library":
            let query = args["query"]?.stringValue ?? ""
            let tracks = client.searchTracks(query: query)
            if tracks.isEmpty { return "No tracks found for '\(query)'." }
            let lines = tracks.prefix(50).map { t in
                var s = "• \(t.title)"
                if let a = t.artist { s += " — \(a)" }
                if let al = t.album { s += " [\(al)]" }
                if let y = t.year   { s += " (\(y))" }
                return s
            }
            return "Found \(tracks.count) track(s):\n" + lines.joined(separator: "\n")

        // ── Library stats ────────────────────────────────────────────────────

        case "get_library_stats":
            guard let stats = client.libraryStats() else {
                return "Library not synced yet. Use Sync Library first."
            }
            var lines = [
                "Library overview:",
                "  Tracks:  \(stats.totalTracks)",
                "  Artists: \(stats.totalArtists)",
                "  Albums:  \(stats.totalAlbums)",
                "",
                "Top genres:"
            ]
            for g in stats.topGenres.prefix(15) {
                lines.append("  \(g.genre): \(g.count) tracks")
            }
            if !stats.tracksByDecade.isEmpty {
                lines.append("")
                lines.append("Tracks by decade:")
                for d in stats.tracksByDecade {
                    lines.append("  \(d.decade): \(d.count) tracks")
                }
            }
            return lines.joined(separator: "\n")

        // ── Filter tracks ────────────────────────────────────────────────────

        case "filter_tracks":
            var options = DatabaseManager.FilterOptions()

            if let genreArr = args["genres"]?.arrayValue {
                options.genres = genreArr.compactMap { $0.stringValue }
            }
            if let decadeArr = args["decades"]?.arrayValue {
                options.decades = decadeArr.compactMap { $0.intValue }
            }
            if let artistArr = args["artists"]?.arrayValue {
                options.artists = artistArr.compactMap { $0.stringValue }
            }
            if let kw = args["keywords"]?.stringValue { options.keywords = kw }
            if let lim = args["limit"]?.intValue       { options.limit   = min(lim, 1000) }
            if let excl = args["exclude_live"]?.boolValue { options.excludeLive = excl }

            let tracks = client.filterTracks(options: options)
            if tracks.isEmpty { return "No tracks matched the filter criteria." }

            let sessionID = await sessions.store(tracks)

            var lines = ["Found \(tracks.count) tracks (session_id: \(sessionID)):", ""]
            for (i, t) in tracks.enumerated() {
                var s = "\(i + 1). \(t.title)"
                if let a = t.artist { s += " — \(a)" }
                if let al = t.album { s += " [\(al)]" }
                if let y = t.year   { s += " (\(y))" }
                lines.append(s)
            }
            return lines.joined(separator: "\n")

        // ── Curate and play ──────────────────────────────────────────────────

        case "curate_and_play":
            let sessionID = try requireString(args, key: "session_id")
            let zoneID    = try requireString(args, key: "zone_id")

            let numbers: [Int]
            if let arr = args["track_numbers"]?.arrayValue {
                numbers = arr.compactMap { $0.intValue }
            } else {
                // Play all tracks in session if no numbers given
                numbers = []
            }

            let tracks: [TrackRecord]
            if numbers.isEmpty {
                tracks = await sessions.all(sessionID: sessionID)
            } else {
                tracks = await sessions.resolve(sessionID: sessionID, numbers: numbers)
            }

            if tracks.isEmpty { return "No tracks resolved from session \(sessionID). Run filter_tracks first." }

            await client.curateTracks(tracks, zoneID: zoneID)

            var lines = ["Playing \(tracks.count) tracks in zone \(zoneID):", ""]
            for (i, t) in tracks.enumerated() {
                var s = "\(i + 1). \(t.title)"
                if let a = t.artist { s += " — \(a)" }
                lines.append(s)
            }
            return lines.joined(separator: "\n")

        default:
            throw ToolError.unknown(name)
        }
    }

    // MARK: - Tool definitions

    private var toolDefinitions: [JSONValue] {
        func tool(_ name: String, _ desc: String, props: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
            .object([
                "name": .string(name),
                "description": .string(desc),
                "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object(props),
                    "required": .array(required.map { .string($0) })
                ])
            ])
        }
        func str(_ d: String) -> JSONValue { .object(["type": .string("string"),  "description": .string(d)]) }
        func int_(_ d: String) -> JSONValue { .object(["type": .string("integer"), "description": .string(d)]) }
        func bool_(_ d: String) -> JSONValue { .object(["type": .string("boolean"), "description": .string(d)]) }
        func arrStr(_ d: String) -> JSONValue { .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string(d)]) }
        func arrInt(_ d: String) -> JSONValue { .object(["type": .string("array"), "items": .object(["type": .string("integer")]), "description": .string(d)]) }

        return [
            tool("roon_zones", "List all Roon zones and their current now-playing status. Call this first to get zone_id and output_id values."),

            tool("roon_play_pause", "Toggle play/pause on a zone.",
                 props: ["zone_id": str("Zone ID from roon_zones")], required: ["zone_id"]),

            tool("roon_next", "Skip to the next track.",
                 props: ["zone_id": str("Zone ID")], required: ["zone_id"]),

            tool("roon_previous", "Go back to the previous track.",
                 props: ["zone_id": str("Zone ID")], required: ["zone_id"]),

            tool("roon_set_volume", "Set absolute volume on an output.",
                 props: ["output_id": str("Output ID from roon_zones"), "value": int_("Volume 0–100")],
                 required: ["output_id", "value"]),

            tool("roon_set_shuffle", "Enable or disable shuffle on a zone.",
                 props: ["zone_id": str("Zone ID"), "enabled": bool_("true to shuffle, false to disable")],
                 required: ["zone_id"]),

            tool("roon_set_repeat", "Set repeat mode on a zone.",
                 props: ["zone_id": str("Zone ID"), "mode": str("disabled | loop | loop_one")],
                 required: ["zone_id"]),

            tool("roon_search_library", "Quick search the local track database by title, artist, or album.",
                 props: ["query": str("Search query")]),

            tool("get_library_stats",
                 "Get an overview of the synced library: total tracks/artists/albums, top genres, and tracks by decade. Call this to understand what music is available before filtering."),

            tool("filter_tracks",
                 "Filter the local library and get a numbered track list + session_id for curation. Combine multiple filters: genres AND decades AND artists AND keywords. Returns up to `limit` tracks (default 500).",
                 props: [
                    "genres":       arrStr("Genre names, e.g. [\"Jazz\", \"Soul\"]. Case-insensitive substring match."),
                    "decades":      arrInt("Decade start years, e.g. [1970, 1980] for 70s and 80s."),
                    "artists":      arrStr("Artist name substrings, e.g. [\"Miles Davis\"]."),
                    "keywords":     str("Keyword matched against title, artist, and album."),
                    "exclude_live": bool_("Exclude live recordings (default true)."),
                    "limit":        int_("Maximum tracks to return (default 500, max 1000).")
                 ]),

            tool("curate_and_play",
                 "Play a curated selection from a filter_tracks session. Pass the session_id and the track numbers you want to play. First track starts immediately; the rest are queued. Omit track_numbers to play the entire session.",
                 props: [
                    "session_id":    str("session_id returned by filter_tracks."),
                    "zone_id":       str("Zone ID from roon_zones where music should play."),
                    "track_numbers": arrInt("Track numbers from the filter_tracks list. Omit to play all.")
                 ],
                 required: ["session_id", "zone_id"]),
        ]
    }

    // MARK: - Helpers

    private func requireString(_ args: [String: JSONValue], key: String) throws -> String {
        guard let v = args[key]?.stringValue else { throw ToolError.missingArg(key) }
        return v
    }

    private func success(_ id: JSONValue?, result: JSONValue) -> MCPResponse {
        MCPResponse(id: id, result: result, error: nil)
    }

    private func error(_ id: JSONValue?, code: Int, message: String) -> MCPResponse {
        MCPResponse(id: id, result: nil, error: MCPError(code: code, message: message))
    }
}

enum ToolError: LocalizedError {
    case missingArg(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .missingArg(let k): "Missing required argument: \(k)"
        case .unknown(let n):    "Unknown tool: \(n)"
        }
    }
}

// MARK: - Entry point

let server = MCPServer()
await server.run()
