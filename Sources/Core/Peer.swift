import Foundation
import Network

/// The listening side: announces this Mac on Bonjour, accepts pairing while the user allows it, and serves
/// the shared folder to paired Macs. Everything else is dropped before it gets to read a byte of a file.
final class PeerListener: @unchecked Sendable {
    let me: Identity
    var name: String

    /// Peer id -> the public key it paired with, or nil for a Mac we do not know.
    var lookupPeer: @Sendable (Data) -> Data? = { _ in nil }
    /// The folder to serve right now; nil while sharing is off.
    var sharedServer: @Sendable () -> FileServer? = { nil }
    /// Called when another Mac asks to pair: (code, peer name) -> does the code match on the other screen.
    /// Nothing is stored unless the user says yes here and the other side says yes too.
    var confirmPairing: @Sendable (String, String) async -> Bool = { _, _ in false }
    var onPaired: @Sendable (Data, String) -> Void = { _, _ in }
    /// A paired Mac dialed us and passed the key check: (its peer id, the link). Return true when the link
    /// was taken over (it then also serves our folder to that Mac); false and the listener serves it itself.
    var adopt: @Sendable (Data, Channel) -> Bool = { _, _ in false }

    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private let lock = NSLock()
    private var active: [ObjectIdentifier: Conn] = [:]

    init(me: Identity, name: String) {
        self.me = me
        self.name = name
    }

    func start(advertise: Bool = true, port fixed: UInt16? = nil) async throws {
        let params = Conn.tcpParams()
        let l: NWListener
        if let fixed, let p = NWEndpoint.Port(rawValue: fixed) {
            l = try NWListener(using: params, on: p)
        } else {
            l = try NWListener(using: params)
        }
        if advertise {
            l.service = NWListener.Service(name: name, type: "_sharekeeper._tcp", domain: nil,
                                           txtRecord: NWTXTRecord(["id": me.id.hex]))
        }
        let q = DispatchQueue(label: "sk.listener")
        l.newConnectionHandler = { [weak self] c in
            let conn = Conn(c)
            Task { await self?.handle(conn) }
        }
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            var done = false
            l.stateUpdateHandler = { st in
                guard !done else { return }
                switch st {
                case .ready: done = true; k.resume()
                case .failed(let e): done = true; k.resume(throwing: e)
                default: break
                }
            }
            l.start(queue: q)
        }
        listener = l
        port = l.port?.rawValue ?? 0
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ conn: Conn) async {
        do {
            try await conn.start(timeout: 10)
            let magic = try await withTimeout(10, onTimeout: { conn.close() }) { try await conn.recv(4) }
            switch String(decoding: magic, as: UTF8.self) {
            case "SKH1":
                let (ch, peerPub) = try await withTimeout(10, onTimeout: { conn.close() }) {
                    try await Handshake.accept(conn, me: self.me, lookup: self.lookupPeer)
                }
                lock.lock(); active[ObjectIdentifier(ch)] = ch.conn; lock.unlock()
                if adopt(Identity.id(of: peerPub), ch) { return }
                await serve(ch)
            case "SKP1":
                let (pub, peerName) = try await withTimeout(180, onTimeout: { conn.close() }) {
                    try await Pairing.respond(conn, me: self.me, name: self.name, confirm: self.confirmPairing)
                }
                onPaired(pub, peerName)
                conn.close()
            default:
                conn.close()
            }
        } catch {
            log.notice("handle ended: \(String(describing: error), privacy: .public)")
            conn.close()
        }
    }

    /// Drops every open link to paired Macs (they reconnect by themselves). For tests, and for a clean cut.
    func disconnectAll() {
        lock.lock(); let all = active; active = [:]; lock.unlock()
        for c in all.values { c.close() }
    }

    private func serve(_ ch: Channel) async {
        let key = ObjectIdentifier(ch)
        defer { lock.lock(); active[key] = nil; lock.unlock() }
        do {
            while true {
                let frame = try await ch.recv()
                guard frame.first == Tag.request else { continue }
                let (req, body) = try Frame.unpack(Request.self, Data(frame.dropFirst()))
                Task {
                    // Asked again per request, so switching sharing off or to read-only takes effect at once.
                    let (resp, out) = await dispatch(sharedServer(), req, body)
                    if let reply = try? Frame.pack(resp, body: out) { try? await ch.send(Data([Tag.response]) + reply) }
                }
            }
        } catch {
            log.notice("serve ended: \(String(describing: error), privacy: .public)")
            ch.conn.close()
        }
    }
}
