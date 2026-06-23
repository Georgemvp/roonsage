import Foundation

/// URLSession delegate that surfaces WebSocket lifecycle events to RoonTransport.
/// Marked @unchecked Sendable because the closures are set once before the
/// WebSocket task starts and never mutated thereafter.
///
/// A fresh delegate is created per connection attempt, so the one-shot `closed`
/// guard below resets naturally for each new socket.
final class TransportDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    var onOpen: (() -> Void)?
    var onClose: ((URLSessionWebSocketTask.CloseCode, Data?) -> Void)?

    // `didCloseWith` (a clean WS close handshake) and `didCompleteWithError` (a
    // connect failure / abrupt drop / timeout — NO close frame) can BOTH fire for
    // one task, so onClose is fired at most once. Delegate callbacks arrive on the
    // session's serial delegate queue, but guard with a lock anyway.
    private let lock = NSLock()
    private var closed = false

    private func fireClose(_ code: URLSessionWebSocketTask.CloseCode, _ reason: Data?) {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        lock.unlock()
        onClose?(code, reason)
    }

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
        fireClose(closeCode, reason)
    }

    /// Connection-level completion. Critically this fires for failures that occur
    /// BEFORE the WebSocket handshake completes — connection refused, host
    /// unreachable, request timeout — and for abrupt drops with no close frame.
    /// `didCloseWith` does NOT cover these. Without handling this, a failed
    /// connect leaves RoonClient stuck in `.connecting` forever (the root cause of
    /// the analyzer hanging on "Verbinden met …"). `error == nil` means a normal
    /// completion after a clean close, already reported via `didCloseWith` and
    /// deduped here.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        fireClose(.abnormalClosure, nil)
    }
}
