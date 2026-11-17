import Foundation
import Network

/// One-shot HTTP listener on 127.0.0.1 that captures the OAuth redirect.
/// All mutable state is touched only on `queue`.
public final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "claude-usage-bar.loopback")
    private var ready: CheckedContinuation<UInt16, Error>?
    private var waiter: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?

    public init() throws {
        let params = NWParameters.tcp
        // Loopback only, both v4 and v6: browsers may resolve "localhost" to either.
        params.requiredInterfaceType = .loopback
        listener = try NWListener(using: params)
    }

    /// Starts listening and returns the bound port.
    public func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { c in
            queue.async {
                self.ready = c
                self.listener.stateUpdateHandler = { self.onState($0) }
                self.listener.newConnectionHandler = { self.accept($0) }
                self.listener.start(queue: self.queue)
            }
        }
    }

    /// Query items of the first `/callback` request.
    public func callback() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { c in
            queue.async {
                if let r = self.result { c.resume(with: r) } else { self.waiter = c }
            }
        }
    }

    public func stop() {
        queue.async {
            self.listener.cancel()
            self.finish(.failure(CancellationError()))
        }
    }

    private func onState(_ state: NWListener.State) {
        switch state {
        case .ready:
            ready?.resume(returning: listener.port?.rawValue ?? 0)
            ready = nil
        case .failed(let e):
            ready?.resume(throwing: e)
            ready = nil
            finish(.failure(e))
        default:
            break
        }
    }

    private func finish(_ r: Result<[String: String], Error>) {
        guard result == nil else { return }
        result = r
        waiter?.resume(with: r)
        waiter = nil
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
            let query = data.flatMap(Self.callbackQuery)
            let body = query == nil
                ? "Not found"
                : "<!doctype html><meta charset=utf-8><body style=\"font:16px -apple-system;padding:40px\">已完成登录，可以关闭此页面。</body>"
            let head = query == nil ? "404 Not Found" : "200 OK"
            let resp = "HTTP/1.1 \(head)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
            if let query { self.finish(.success(query)) }
        }
    }

    /// Parses "GET /callback?code=..&state=.. HTTP/1.1".
    static func callbackQuery(_ request: Data) -> [String: String]? {
        guard let line = String(decoding: request, as: UTF8.self).split(separator: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let c = URLComponents(string: String(parts[1])), c.path == "/callback" else { return nil }
        var out: [String: String] = [:]
        for item in c.queryItems ?? [] { out[item.name] = item.value ?? "" }
        return out
    }
}
