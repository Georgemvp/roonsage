/// RoonSage MCP Server — stdio JSON-RPC bridge for Claude Desktop.
///
/// Implements the Model Context Protocol (MCP) over stdin/stdout.
/// Claude Desktop launches this binary and communicates via newline-delimited JSON.
///
/// Tools exposed:
///   roon_zones          — list all zones + now-playing
///   roon_play_pause     — toggle playback on a zone
///   roon_next / roon_previous — skip tracks
///   roon_set_volume     — set volume on an output
///   roon_search_library — search local GRDB track database
///
/// Configuration (claude_desktop_config.json):
/// {
///   "mcpServers": {
///     "roonsage": {
///       "command": "/Applications/RoonSage.app/Contents/MacOS/roonsage-mcp",
///       "args": []
///     }
///   }
/// }

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

// Flexible JSON value type for MCP protocol
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
}

// MARK: - MCP Server

@MainActor
final class MCPServer {

    private let client = RoonClient()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func run() async {
        // Discover and connect to Roon on startup
        await client.discoverAndConnect()
        // Brief wait for zone subscription to populate
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        // Main stdio read loop
        while let line = readLine(strippingNewline: true), !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let req = try? decoder.decode(MCPRequest.self, from: data) else {
                continue
            }
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
                "serverInfo": .object([
                    "name": .string("roonsage"),
                    "version": .string("1.0.0")
                ])
            ]))

        case "tools/list":
            return success(req.id, result: .object(["tools": .array(toolDefinitions)]))

        case "tools/call":
            return await callTool(req)

        default:
            return error(req.id, code: -32601, message: "Method not found: \(req.method)")
        }
    }

    // MARK: - Tool dispatch

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
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string(text)
                ])])
            ]))
        } catch {
            return self.error(req.id, code: -32603, message: error.localizedDescription)
        }
    }

    private func executeTool(name: String, args: [String: JSONValue]) async throws -> String {
        switch name {

        case "roon_zones":
            if client.zones.isEmpty { return "No active zones." }
            return client.zones.map { z in
                var s = "Zone: \(z.displayName) [\(z.state.rawValue)]"
                if let np = z.nowPlaying {
                    s += "\n  Now playing: \(np.title)"
                    if let a = np.artist { s += " — \(a)" }
                    if let al = np.album  { s += " (\(al))" }
                }
                if let out = z.outputs.first, let vol = out.volume {
                    s += "\n  Volume: \(vol.value)\(vol.isMuted ? " (muted)" : "")"
                    s += "  output_id: \(out.id)"
                }
                s += "\n  zone_id: \(z.id)"
                return s
            }.joined(separator: "\n\n")

        case "roon_play_pause":
            let zoneID = try requireString(args, key: "zone_id")
            await client.playPause(zoneID: zoneID)
            return "Toggled playback on zone \(zoneID)."

        case "roon_next":
            let zoneID = try requireString(args, key: "zone_id")
            await client.next(zoneID: zoneID)
            return "Skipped to next track on zone \(zoneID)."

        case "roon_previous":
            let zoneID = try requireString(args, key: "zone_id")
            await client.previous(zoneID: zoneID)
            return "Went to previous track on zone \(zoneID)."

        case "roon_set_volume":
            let outputID = try requireString(args, key: "output_id")
            guard let value = args["value"]?.intValue else {
                throw ToolError.missingArg("value")
            }
            await client.setVolume(outputID: outputID, value: value)
            return "Volume set to \(value) on output \(outputID)."

        case "roon_search_library":
            let query = args["query"]?.stringValue ?? ""
            let tracks = client.searchTracks(query: query)
            if tracks.isEmpty { return "No tracks found for query: \(query)" }
            let lines = tracks.prefix(50).map { t in
                var s = "• \(t.title)"
                if let a = t.artist { s += " — \(a)" }
                if let al = t.album { s += " [\(al)]" }
                if let y = t.year   { s += " (\(y))" }
                return s
            }
            return "Found \(tracks.count) track(s):\n" + lines.joined(separator: "\n")

        default:
            throw ToolError.unknown(name)
        }
    }

    // MARK: - Tool definitions (returned in tools/list)

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
        func strProp(_ desc: String) -> JSONValue {
            .object(["type": .string("string"), "description": .string(desc)])
        }
        func intProp(_ desc: String) -> JSONValue {
            .object(["type": .string("integer"), "description": .string(desc)])
        }

        return [
            tool("roon_zones",   "List all Roon zones and their current now-playing status."),
            tool("roon_play_pause", "Toggle play/pause on a zone.",
                 props: ["zone_id": strProp("Zone ID from roon_zones")], required: ["zone_id"]),
            tool("roon_next", "Skip to next track.",
                 props: ["zone_id": strProp("Zone ID")], required: ["zone_id"]),
            tool("roon_previous", "Go to previous track.",
                 props: ["zone_id": strProp("Zone ID")], required: ["zone_id"]),
            tool("roon_set_volume", "Set absolute volume on an output.",
                 props: ["output_id": strProp("Output ID from roon_zones"),
                         "value":     intProp("Volume value (0–100)")],
                 required: ["output_id", "value"]),
            tool("roon_search_library", "Search the local track database.",
                 props: ["query": strProp("Search query (title, artist, or album)")]),
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
