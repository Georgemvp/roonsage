import Foundation

/// A single MOO/1 protocol message. Roon's WebSocket transport carries these as
/// binary frames (opcode 0x2). The textual layout is:
///
///     MOO/1 <VERB> <name>\n
///     <Header-Key>: <value>\n
///     ...
///     \n
///     <body bytes>
///
/// `name` is the verb argument: a service endpoint for outgoing REQUESTs
/// (e.g. `com.roonlabs.registry:1/register`) or a status word on replies
/// (`Registered`, `Success`, `Changed`, ...).
public struct MOOFrame: Equatable {
    public enum Verb: String, Equatable {
        case request = "REQUEST"
        case complete = "COMPLETE"
        case continuation = "CONTINUE"
    }

    public var verb: Verb
    public var name: String
    public var requestID: Int?
    public var headers: [String: String]
    public var body: Data?

    public init(
        verb: Verb,
        name: String,
        requestID: Int? = nil,
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.verb = verb
        self.name = name
        self.requestID = requestID
        self.headers = headers
        self.body = body
    }

    /// Decoded JSON body, if the frame carried an application/json payload.
    public func jsonBody() throws -> Any? {
        guard let body, !body.isEmpty else { return nil }
        return try JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
    }
}

// MARK: - Encoding

public extension MOOFrame {
    /// Convenience builder for an outgoing REQUEST with an optional JSON body.
    static func request(
        _ endpoint: String,
        requestID: Int,
        json: [String: Any]? = nil
    ) throws -> MOOFrame {
        var body: Data?
        if let json {
            body = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        }
        return MOOFrame(verb: .request, name: endpoint, requestID: requestID, body: body)
    }

    /// Serialize to wire bytes. Content-Length is the body's UTF-8 byte count.
    ///
    /// Note: pyroon emits `len(str)` (character count) here, which diverges
    /// from the HTTP-style byte length for multi-byte JSON. We follow the
    /// node-roon-api reference (`Buffer.byteLength`) and use byte count.
    func encode() -> Data {
        var header = "MOO/1 \(verb.rawValue) \(name)\n"
        if let requestID {
            header += "Request-Id: \(requestID)\n"
        }
        for key in headers.keys.sorted() where key != "Request-Id" {
            header += "\(key): \(headers[key]!)\n"
        }

        if let body, !body.isEmpty {
            let contentType = headers["Content-Type"] ?? "application/json"
            if headers["Content-Type"] == nil {
                header += "Content-Type: \(contentType)\n"
            }
            header += "Content-Length: \(body.count)\n\n"
            var data = Data(header.utf8)
            data.append(body)
            return data
        } else {
            header += "\n"
            return Data(header.utf8)
        }
    }
}

// MARK: - Decoding

public extension MOOFrame {
    enum DecodeError: Error, Equatable {
        case emptyMessage
        case missingHeaderLine
        case malformedStartLine(String)
        case unknownVerb(String)
    }

    /// Parse an inbound MOO frame from raw WebSocket bytes.
    ///
    /// The header section ends at the first blank line (`\n\n`); everything
    /// after is the raw body. Operating on bytes (not a decoded String) keeps
    /// the body intact regardless of its content.
    static func decode(_ data: Data) throws -> MOOFrame {
        guard !data.isEmpty else { throw DecodeError.emptyMessage }

        let separator = Data([0x0A, 0x0A]) // "\n\n"
        let headerData: Data
        var body: Data?
        if let range = data.firstRange(of: separator) {
            headerData = data.subdata(in: data.startIndex..<range.lowerBound)
            let bodyStart = range.upperBound
            if bodyStart < data.endIndex {
                let slice = data.subdata(in: bodyStart..<data.endIndex)
                body = slice.isEmpty ? nil : slice
            }
        } else {
            headerData = data
        }

        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw DecodeError.missingHeaderLine
        }
        let lines = headerString.split(separator: "\n", omittingEmptySubsequences: false)
        guard let startLine = lines.first, !startLine.isEmpty else {
            throw DecodeError.missingHeaderLine
        }

        // Start line: "MOO/1 <VERB> <name...>"
        let startComponents = startLine.split(separator: " ", maxSplits: 2,
                                              omittingEmptySubsequences: true)
        guard startComponents.count >= 2, startComponents[0] == "MOO/1" else {
            throw DecodeError.malformedStartLine(String(startLine))
        }
        guard let verb = Verb(rawValue: String(startComponents[1])) else {
            throw DecodeError.unknownVerb(String(startComponents[1]))
        }
        let name = startComponents.count >= 3 ? String(startComponents[2]) : ""

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where line.contains(":") {
            let kv = line.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            headers[kv[0].trimmingCharacters(in: .whitespaces)] =
                kv[1].trimmingCharacters(in: .whitespaces)
        }

        let requestID = headers["Request-Id"].flatMap { Int($0) }

        return MOOFrame(verb: verb, name: name, requestID: requestID,
                        headers: headers, body: body)
    }

    /// True when this frame is a server-initiated ping that must be answered
    /// with `COMPLETE Success`.
    var isPing: Bool {
        verb == .request && name.hasPrefix(RoonService.ping)
    }
}
