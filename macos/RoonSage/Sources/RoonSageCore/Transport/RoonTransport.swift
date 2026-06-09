import Foundation
import RoonProtocol

enum RoonTransportError: LocalizedError {
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Roon denied authorization. Open Roon → Settings → Extensions and enable RoonSage."
        }
    }
}

/// Manages the low-level Roon MOO/1 WebSocket connection.
///
/// - Request/response pairs are correlated by Request-Id via CheckedContinuations.
/// - Subscriptions return an AsyncStream of parsed JSON bodies.
/// - The Roon "Registered" handshake is handled via a dedicated continuation.
/// - Application-level pings (com.roonlabs.ping:1) are answered automatically.
///
/// Connection lifecycle:
/// 1. Caller calls `connect(host:port:)`.
/// 2. WebSocket handshake completes → `onOpen` fires.
/// 3. Caller uses `register(payload:)` to perform the Roon extension handshake.
/// 4. On disconnect `onClose` fires; caller decides whether to reconnect.
actor RoonTransport {

    // MARK: - State

    private var wsTask: URLSessionWebSocketTask?
    private var delegate: TransportDelegate?
    private(set) var isConnected = false

    // Request-Id counter — starts at 10 to avoid confusion with server's
    // initial messages (matching the pyroon / node-roon-api convention).
    private var nextID = 10

    // Watchdog: fires handleClose when no frame has been received for >20s.
    // Roon pings every ~10s, so silence beyond 20s means a half-open TCP socket.
    private var watchdogTask: Task<Void, Never>?
    private var lastReceivedAt: Date = .distantPast

    // MARK: - Pending request tracking

    private var pendingRequests: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var subscriptions: [Int: AsyncStream<[String: Any]>.Continuation] = [:]
    // One-shot continuation for the Roon registration response.
    private var registrationContinuation: CheckedContinuation<[String: Any], Error>?

    // MARK: - External callbacks

    var onOpen: (@Sendable () async -> Void)?
    var onClose: (@Sendable () async -> Void)?

    func configure(
        onOpen: @escaping @Sendable () async -> Void,
        onClose: @escaping @Sendable () async -> Void
    ) {
        self.onOpen = onOpen
        self.onClose = onClose
    }

    // MARK: - Connect / Disconnect

    func connect(host: String, port: UInt16) {
        // Defensive: never force-unwrap a URL built from external input. The
        // caller (RoonClient.connect) already validates, but guard here too so
        // a malformed host can never trap the process.
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "ws://\(cleanHost):\(port)/api") else {
            Task { await self.handleClose() }
            return
        }
        let del = TransportDelegate()
        delegate = del

        del.onOpen = { [weak self] in
            guard let self else { return }
            Task { [self] in await self.handleOpen() }
        }
        del.onClose = { [weak self] _, _ in
            guard let self else { return }
            Task { [self] in await self.handleClose() }
        }

        let session = URLSession(
            configuration: .default,
            delegate: del,
            delegateQueue: OperationQueue()
        )
        let task = session.webSocketTask(with: url)
        wsTask = task
        task.resume()
        startReceiving(task)
    }

    func disconnect() {
        watchdogTask?.cancel()
        watchdogTask = nil
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
        delegate = nil
        isConnected = false
        failAllPending(with: URLError(.networkConnectionLost))
    }

    // MARK: - Sending

    func send(_ frame: MOOFrame) async throws {
        guard let wsTask else { throw URLError(.notConnectedToInternet) }
        try await wsTask.send(.data(frame.encode()))
    }

    // MARK: - Registration (special-cased: response matched by name, not by ID)

    func register(payload: [String: Any]) async throws -> [String: Any] {
        let id = nextID; nextID += 1
        let frame = try MOOFrame.request(
            "\(RoonService.registry)/register",
            requestID: id,
            json: payload
        )
        return try await withCheckedThrowingContinuation { cont in
            registrationContinuation = cont
            // Send from an unstructured task so we can await inside the sync closure.
            Task { try? await self.send(frame) }
        }
    }

    // MARK: - Request / Response

    func request(_ endpoint: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        let id = nextID; nextID += 1
        let frame = try MOOFrame.request(endpoint, requestID: id, json: body)
        return try await withCheckedThrowingContinuation { cont in
            pendingRequests[id] = cont
            Task { try? await self.send(frame) }
        }
    }

    // MARK: - Subscriptions

    func subscribe(service: String, endpoint: String, params: [String: Any] = [:]) async throws -> AsyncStream<[String: Any]> {
        let id = nextID; nextID += 1
        var body = params
        body["subscription_key"] = id
        let frame = try MOOFrame.request(
            "\(service)/subscribe_\(endpoint)",
            requestID: id,
            json: body
        )
        var continuation: AsyncStream<[String: Any]>.Continuation!
        let stream = AsyncStream { continuation = $0 }
        subscriptions[id] = continuation
        try await send(frame)
        return stream
    }

    func unsubscribe(service: String, endpoint: String, subscriptionKey: Int) async throws {
        subscriptions[subscriptionKey]?.finish()
        subscriptions.removeValue(forKey: subscriptionKey)
        let frame = try MOOFrame.request(
            "\(service)/unsubscribe_\(endpoint)",
            requestID: nextID,
            json: ["subscription_key": subscriptionKey]
        )
        nextID += 1
        try? await send(frame)
    }

    // MARK: - Receive loop

    private func startReceiving(_ wsTask: URLSessionWebSocketTask) {
        wsTask.receive { result in
            Task { await self.processReceived(result, from: wsTask) }
        }
    }

    private func processReceived(
        _ result: Result<URLSessionWebSocketTask.Message, Error>,
        from wsTask: URLSessionWebSocketTask
    ) async {
        switch result {
        case .success(let message):
            lastReceivedAt = Date()
            let data: Data?
            switch message {
            case .data(let d):   data = d
            case .string(let s): data = Data(s.utf8)
            @unknown default:    data = nil
            }
            if let data, let frame = try? MOOFrame.decode(data) {
                routeFrame(frame)
            }
            startReceiving(wsTask)

        case .failure:
            // Actual disconnect is reported via the delegate; just stop looping.
            break
        }
    }

    private func routeFrame(_ frame: MOOFrame) {
        guard let id = frame.requestID else { return }
        let body = (try? frame.jsonBody() as? [String: Any]) ?? [:]

        // Application-level ping: reply immediately.
        if frame.isPing {
            let pong = MOOFrame(verb: .complete, name: "Success", requestID: id)
            Task { try? await self.send(pong) }
            return
        }

        // Registration response is matched by NAME, not verb. Roon delivers it
        // as CONTINUE (so it can later push state changes — e.g. Unauthorized —
        // over the same request), not COMPLETE. Mirror the reference pyroon
        // client, which routes on "Registered" in the header regardless of verb.
        switch frame.name {
        case "Registered":
            registrationContinuation?.resume(returning: body)
            registrationContinuation = nil
            return
        case "Unauthorized":
            registrationContinuation?.resume(throwing: RoonTransportError.unauthorized)
            registrationContinuation = nil
            return
        default:
            break
        }

        switch frame.verb {
        case .complete:
            pendingRequests[id]?.resume(returning: body)
            pendingRequests.removeValue(forKey: id)

        case .continuation:
            subscriptions[id]?.yield(body)

        default:
            break
        }
    }

    // MARK: - Lifecycle helpers

    private func handleOpen() async {
        isConnected = true
        lastReceivedAt = Date()
        startWatchdog()
        await onOpen?()
    }

    private func handleClose() async {
        watchdogTask?.cancel()
        watchdogTask = nil
        isConnected = false
        failAllPending(with: URLError(.networkConnectionLost))
        await onClose?()
    }

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, isConnected else { return }
                if Date().timeIntervalSince(lastReceivedAt) > 20 {
                    await handleClose()
                    return
                }
            }
        }
    }

    private func failAllPending(with error: Error) {
        for cont in pendingRequests.values { cont.resume(throwing: error) }
        pendingRequests.removeAll()
        registrationContinuation?.resume(throwing: error)
        registrationContinuation = nil
        for cont in subscriptions.values { cont.finish() }
        subscriptions.removeAll()
    }
}
