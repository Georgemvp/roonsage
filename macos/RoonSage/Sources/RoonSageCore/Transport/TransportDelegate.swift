import Foundation

/// URLSession delegate that surfaces WebSocket lifecycle events to RoonTransport.
/// Marked @unchecked Sendable because the closures are set once before the
/// WebSocket task starts and never mutated thereafter.
final class TransportDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    var onOpen: (() -> Void)?
    var onClose: ((URLSessionWebSocketTask.CloseCode, Data?) -> Void)?

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        onOpen?()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        onClose?(closeCode, reason)
    }
}
