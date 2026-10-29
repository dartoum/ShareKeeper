import Foundation
import Network

/// async/await around NWConnection: exact-length reads, and sends that keep their order.
final class Conn: @unchecked Sendable {
    let c: NWConnection

    init(_ c: NWConnection) { self.c = c }

    convenience init(to endpoint: NWEndpoint) {
        self.init(NWConnection(to: endpoint, using: Conn.tcpParams()))
    }

    static func tcpParams() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 20
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        return NWParameters(tls: nil, tcp: tcp)
    }

    func start(timeout: Double = 8) async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            var finished = false
            let q = DispatchQueue(label: "sk.conn")
            c.stateUpdateHandler = { st in
                guard !finished else { return }
                switch st {
                case .ready: finished = true; k.resume()
                case .failed(let e): finished = true; k.resume(throwing: e)
                case .cancelled: finished = true; k.resume(throwing: FSError(ECANCELED))
                default: break   // .waiting: keep trying until the timeout below
                }
            }
            c.start(queue: q)
            q.asyncAfter(deadline: .now() + timeout) { [c] in
                if !finished { finished = true; c.cancel(); k.resume(throwing: FSError(ETIMEDOUT)) }
            }
        }
    }

    /// Hands the bytes to the connection right away, so calls made in a given order are sent in that order.
    func enqueue(_ d: Data, completion: @escaping (Error?) -> Void) {
        c.send(content: d, completion: .contentProcessed { completion($0) })
    }

    func send(_ d: Data) async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            enqueue(d) { e in if let e { k.resume(throwing: e) } else { k.resume() } }
        }
    }

    func recv(_ n: Int) async throws -> Data {
        if n == 0 { return Data() }
        return try await withCheckedThrowingContinuation { (k: CheckedContinuation<Data, Error>) in
            c.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, _, error in
                if let error { k.resume(throwing: error) }
                else if let data, data.count == n { k.resume(returning: data) }
                else { k.resume(throwing: FSError(ECONNRESET)) }   // the other side closed
            }
        }
    }

    func close() { c.cancel() }
}
