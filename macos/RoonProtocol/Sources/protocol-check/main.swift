import Foundation
import RoonProtocol

// Minimal assertion harness so the protocol codec can be verified with only
// the CommandLineTools toolchain (XCTest/swift-testing need full Xcode).

var failures = 0
var checks = 0

func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if condition {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message)")
    }
}

func section(_ name: String) { print("\n# \(name)") }

// MARK: - MOO frame round-trip

section("MOO REQUEST round-trip")
do {
    let frame = try MOOFrame.request(
        RoonService.registry + "/register",
        requestID: 10,
        json: ["display_name": "RoonSage", "token": "abc123"]
    )
    let decoded = try MOOFrame.decode(frame.encode())
    expect(decoded.verb == .request, "verb == REQUEST")
    expect(decoded.name == "com.roonlabs.registry:1/register", "endpoint preserved")
    expect(decoded.requestID == 10, "request id == 10")
    let json = try decoded.jsonBody() as? [String: Any]
    expect(json?["display_name"] as? String == "RoonSage", "body display_name")
    expect(json?["token"] as? String == "abc123", "body token")
}

section("Content-Length is UTF-8 byte count")
do {
    let frame = try MOOFrame.request("svc/x", requestID: 1, json: ["v": "café"])
    let text = String(data: frame.encode(), encoding: .utf8) ?? ""
    // {"v":"café"} -> 13 bytes (é is 2 bytes) vs 12 characters.
    expect(text.contains("Content-Length: 13"), "byte-count Content-Length (13)")
}

section("Decode COMPLETE Registered reply")
do {
    let body = #"{"token":"tok-9","core_id":"core-xyz","display_name":"Living Room"}"#
    let raw = "MOO/1 COMPLETE Registered\nRequest-Id: 10\n"
        + "Content-Length: \(body.utf8.count)\nContent-Type: application/json\n\n" + body
    let frame = try MOOFrame.decode(Data(raw.utf8))
    expect(frame.verb == .complete, "verb == COMPLETE")
    expect(frame.name == "Registered", "name == Registered")
    let json = try frame.jsonBody() as? [String: Any]
    expect(json?["token"] as? String == "tok-9", "token parsed")
    expect(json?["core_id"] as? String == "core-xyz", "core_id parsed")
}

section("Decode server PING")
do {
    let raw = "MOO/1 REQUEST com.roonlabs.ping:1/ping\nRequest-Id: 3\n\n"
    let frame = try MOOFrame.decode(Data(raw.utf8))
    expect(frame.isPing, "recognized as ping")
    expect(frame.requestID == 3, "ping request id == 3")
    expect(frame.body == nil, "ping has no body")
}

section("Decode CONTINUE Changed (zones)")
do {
    let body = #"{"zones_changed":[{"zone_id":"z1","display_name":"Office"}]}"#
    let raw = "MOO/1 CONTINUE Changed\nRequest-Id: 42\n"
        + "Content-Length: \(body.utf8.count)\nContent-Type: application/json\n\n" + body
    let frame = try MOOFrame.decode(Data(raw.utf8))
    expect(frame.verb == .continuation, "verb == CONTINUE")
    let zonesJSON = try frame.jsonBody() as? [String: Any]
    expect(zonesJSON?["zones_changed"] != nil, "zones_changed present")
}

section("Encode no-body COMPLETE Success")
do {
    let frame = MOOFrame(verb: .complete, name: "Success", requestID: 5)
    let wire = String(data: frame.encode(), encoding: .utf8)
    expect(wire == "MOO/1 COMPLETE Success\nRequest-Id: 5\n\n", "exact wire bytes")
}

section("Decode rejects garbage")
do {
    var threw = false
    do { _ = try MOOFrame.decode(Data("HELLO world\n\n".utf8)) } catch { threw = true }
    expect(threw, "non-MOO start line throws")
}

// MARK: - SOOD discovery

section("SOOD query canonical layout")
do {
    let query = SOODMessage.makeQuery()
    expect(query.count == 104, "query length == 104 bytes (matches .soodmsg)")
    expect(Array(query.prefix(6)) == [0x53, 0x4F, 0x4F, 0x44, 0x02, 0x51], "SOOD\\x02Q header")
}

section("SOOD query round-trips")
do {
    let parsed = try SOODMessage(parsing: SOODMessage.makeQuery())
    expect(parsed.type == .query, "type == query")
    expect(parsed.properties["query_service_id"] == RoonProtocolConstants.soodServiceID,
           "service id property")
    expect(parsed.properties["_tid"] == RoonProtocolConstants.soodDefaultTID, "_tid property")
}

section("SOOD response parsing")
do {
    var data = Data([0x53, 0x4F, 0x4F, 0x44, 0x02, 0x52]) // SOOD\x02R
    func add(_ key: String, _ value: String) {
        let k = Data(key.utf8), v = Data(value.utf8)
        data.append(UInt8(k.count)); data.append(k)
        let len = UInt16(v.count)
        data.append(UInt8(len >> 8)); data.append(UInt8(len & 0xFF)); data.append(v)
    }
    add("name", "Living Room")
    add("unique_id", "core-abc-123")
    add("http_port", "9330")
    add("display_version", "2.0 (build 1488)")

    let parsed = try SOODMessage(parsing: data)
    expect(parsed.type == .response, "type == response")
    let core = DiscoveredRoonCore(host: "192.168.1.50", soodResponse: parsed)
    expect(core?.httpPort == 9330, "http_port == 9330")
    expect(core?.uniqueID == "core-abc-123", "unique_id parsed")
    expect(core?.name == "Living Room", "name parsed")
}

section("SOOD rejects bad input")
do {
    var badPrefix = false
    do { _ = try SOODMessage(parsing: Data("NOPE".utf8)) }
    catch { badPrefix = (error as? SOODMessage.ParseError) == .badPrefix }
    expect(badPrefix, "bad prefix throws .badPrefix")

    var truncated = false
    let t = Data([0x53, 0x4F, 0x4F, 0x44, 0x02, 0x52, 0x04, 0x6E, 0x61, 0x6D, 0x65, 0x00, 0x10])
    do { _ = try SOODMessage(parsing: t) }
    catch { truncated = (error as? SOODMessage.ParseError) == .truncated }
    expect(truncated, "truncated value throws .truncated")
}

// MARK: - Summary

print("\n----------------------------------------")
print("\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("FAILED (\(failures) failures)")
    exit(1)
} else {
    print("ALL PASSED")
}
