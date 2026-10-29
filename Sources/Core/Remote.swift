import Foundation
import Network

/// The folder of one paired Mac, over the encrypted channel. Reconnects on its own: a request made while
/// the link is down waits a few seconds for it to come back before it fails, so a wake from sleep is
/// a short pause and not an error.
final class RemoteClient: FileBackend, @unchecked Sendable {
    private let me: Identity
    private let peerPub: Data
    private let endpoint: () -> NWEndpoint?

    private let lock = NSLock()
    private var channel: Channel?
    private var connected = false
    private var pending: [UInt32: Pending] = [:]
    private var nextId: UInt32 = 1
    private var loop: Task<Void, Never>?
    private var stopped = false
    private var failures = 0
    private var nextAttempt = Date.distantPast
    private var sharing = false
    private var lastError: String?

    /// How often a quiet link is checked (and the other Mac's sharing state refreshed).
    var pingInterval: Double = 10

    var onConnect: (@Sendable () -> Void)?
    var onDisconnect: (@Sendable () -> Void)?

    private struct Pending {
        let k: CheckedContinuation<(Response, Data), Error>
        let timer: Task<Void, Never>
    }

    init(me: Identity, peerPub: Data, endpoint: @escaping () -> NWEndpoint?) {
        self.me = me
        self.peerPub = peerPub
        self.endpoint = endpoint
    }

    var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return connected }

    /// Connected, and the other Mac has a folder shared with us right now.
    var peerSharing: Bool { lock.lock(); defer { lock.unlock() }; return connected && sharing }

    /// Why the last attempt to connect failed; nil while connected.
    var lastConnectError: String? { lock.lock(); defer { lock.unlock() }; return lastError }

    /// True when sharing just turned on.
    private func setSharing(_ now: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let turnedOn = now && !sharing
        sharing = now
        return turnedOn
    }

    func start() {
        loop = Task { await self.run() }
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        loop?.cancel()
        dropChannel(nil)
    }

    /// Try again now (the Mac woke up, the network changed, the peer showed up on Bonjour).
    func kick() {
        lock.lock(); failures = 0; nextAttempt = .distantPast; lock.unlock()
    }

    func waitConnected(_ seconds: Double) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if isConnected { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return isConnected
    }

    // MARK: Connection loop

    private func run() async {
        var lastPing = Date()
        while !Task.isCancelled {
            lock.lock(); let down = !connected; let due = Date() >= nextAttempt; lock.unlock()
            if down {
                if due { await connectOnce() }
                lastPing = Date()
            } else if Date().timeIntervalSince(lastPing) > pingInterval {
                lastPing = Date()
                // A link that died quietly (sleep, wifi change) shows up here instead of at the first read.
                // The answer also says whether the other Mac is sharing a folder right now.
                do {
                    let (resp, _) = try await rpc(Request(op: "ping"), wait: 0, timeout: 8)
                    if setSharing(resp.sharing ?? false) { onConnect?() }
                } catch {
                    log.error("ping failed: \(String(describing: error), privacy: .public)")
                    dropChannel(nil)
                }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func connectOnce() async {
        guard let ep = endpoint() else { return }
        let conn = Conn(to: ep)
        do {
            try await conn.start(timeout: 8)
            let me = self.me, peerPub = self.peerPub
            let ch = try await withTimeout(8, onTimeout: { conn.close() }) {
                try await Handshake.initiate(conn, me: me, peerPub: peerPub)
            }
            lock.lock(); channel = ch; lock.unlock()
            Task { await self.readLoop(ch) }
            // The first answer proves the other side holds the key it paired with.
            let (pong, _) = try await callRaw(ch, Request(op: "ping"), Data(), timeout: 8)
            lock.lock(); connected = true; failures = 0; sharing = pong.sharing ?? false; lastError = nil; lock.unlock()
            log.notice("connected to peer, sharing: \(pong.sharing ?? false)")
            onConnect?()
        } catch {
            log.error("connect failed: \(String(describing: error), privacy: .public)")
            lock.lock()
            failures += 1
            lastError = String(describing: error)
            nextAttempt = Date().addingTimeInterval(Double(min(2 + failures * 2, 20)))
            lock.unlock()
            conn.close()
            dropChannel(nil)
        }
    }

    private func readLoop(_ ch: Channel) async {
        do {
            while true {
                let frame = try await ch.recv()
                let (resp, body) = try Frame.unpack(Response.self, frame)
                complete(resp.id, .success((resp, body)))
            }
        } catch { log.notice("read loop ended: \(String(describing: error), privacy: .public)") }
        dropChannel(ch)
    }

    /// `ch` nil = whatever channel is current.
    private func dropChannel(_ ch: Channel?) {
        lock.lock()
        if let ch, channel !== ch { lock.unlock(); return }
        let old = channel
        let was = connected
        channel = nil
        connected = false
        let all = pending
        pending = [:]
        lock.unlock()
        old?.conn.close()
        for (_, p) in all { p.timer.cancel(); p.k.resume(throwing: FSError(EIO)) }
        if was { log.notice("peer connection lost"); onDisconnect?() }
    }

    // MARK: Requests

    @discardableResult
    private func complete(_ id: UInt32, _ result: Result<(Response, Data), Error>) -> Bool {
        lock.lock(); let p = pending.removeValue(forKey: id); lock.unlock()
        guard let p else { return false }
        p.timer.cancel()
        p.k.resume(with: result)
        return true
    }

    private func callRaw(_ ch: Channel, _ req: Request, _ body: Data, timeout: Double) async throws -> (Response, Data) {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<(Response, Data), Error>) in
            lock.lock()
            var r = req
            r.id = nextId
            nextId &+= 1
            let sent = r
            let timer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                if self.complete(sent.id, .failure(FSError(ETIMEDOUT))) { log.error("request \(sent.op, privacy: .public) timed out"); self.dropChannel(ch) }
            }
            pending[sent.id] = Pending(k: k, timer: timer)
            lock.unlock()
            Task {
                do { try await ch.send(try Frame.pack(sent, body: body)) }
                catch { if self.complete(sent.id, .failure(error)) { log.error("send failed: \(String(describing: error), privacy: .public)"); self.dropChannel(ch) } }
            }
        }
    }

    private func rpc(_ req: Request, body: Data = Data(), wait: Double = 6, timeout: Double = 20) async throws -> (Response, Data) {
        if !isConnected, wait > 0 { _ = await waitConnected(wait) }
        lock.lock(); let ch = connected ? channel : nil; lock.unlock()
        guard let ch else { throw FSError(EIO) }
        let (resp, data) = try await callRaw(ch, req, body, timeout: timeout)
        if resp.err != 0 { throw FSError(resp.err) }
        return (resp, data)
    }

    // MARK: FileBackend

    func getattr(_ path: String) async throws -> Attr {
        guard let a = try await rpc(Request(op: "getattr", path: path)).0.attr else { throw FSError(EPROTO) }
        return a
    }

    func readdir(_ path: String) async throws -> [Entry] {
        guard let e = try await rpc(Request(op: "readdir", path: path)).0.entries else { throw FSError(EPROTO) }
        return e
    }

    func read(_ path: String, offset: UInt64, count: UInt32) async throws -> (Data, Bool) {
        let (resp, data) = try await rpc(Request(op: "read", path: path, off: offset, len: count))
        return (data, resp.eof)
    }

    func write(_ path: String, offset: UInt64, data: Data) async throws -> UInt32 {
        try await rpc(Request(op: "write", path: path, off: offset), body: data).0.n
    }

    func create(_ path: String, mode: UInt32, exclusive: Bool) async throws -> Attr {
        guard let a = try await rpc(Request(op: "create", path: path, mode: mode, flag: exclusive)).0.attr else { throw FSError(EPROTO) }
        return a
    }

    func mkdir(_ path: String, mode: UInt32) async throws -> Attr {
        guard let a = try await rpc(Request(op: "mkdir", path: path, mode: mode)).0.attr else { throw FSError(EPROTO) }
        return a
    }

    func remove(_ path: String) async throws { _ = try await rpc(Request(op: "remove", path: path)) }
    func rmdir(_ path: String) async throws { _ = try await rpc(Request(op: "rmdir", path: path)) }
    func rename(_ from: String, _ to: String) async throws { _ = try await rpc(Request(op: "rename", path: from, to: to)) }

    func setattr(_ path: String, mode: UInt32?, size: UInt64?, atime: Double?, mtime: Double?) async throws -> Attr {
        guard let a = try await rpc(Request(op: "setattr", path: path, mode: mode, size: size, atime: atime, mtime: mtime)).0.attr
        else { throw FSError(EPROTO) }
        return a
    }

    func statfs() async throws -> FsStat {
        guard let s = try await rpc(Request(op: "statfs")).0.stat else { throw FSError(EPROTO) }
        return s
    }
}

/// A couple of seconds of attribute and listing cache in front of a slow backend. The NFS client asks
/// for attributes constantly; without this every `ls -l` would be a round trip per file.
final class CachingBackend: FileBackend, @unchecked Sendable {
    private let inner: FileBackend
    private let ttl: TimeInterval
    private let lock = NSLock()
    private var attrs: [String: (Attr, Date)] = [:]
    private var dirs: [String: ([Entry], Date)] = [:]

    init(_ inner: FileBackend, ttl: TimeInterval = 2) {
        self.inner = inner
        self.ttl = ttl
    }

    private func forget(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        let parent = parentPath(path)
        attrs[path] = nil; dirs[path] = nil
        attrs[parent] = nil; dirs[parent] = nil
    }

    private func forgetAll() {
        lock.lock(); attrs = [:]; dirs = [:]; lock.unlock()
    }

    func getattr(_ path: String) async throws -> Attr {
        lock.lock()
        if let (a, t) = attrs[path], Date().timeIntervalSince(t) < ttl { lock.unlock(); return a }
        lock.unlock()
        let a = try await inner.getattr(path)
        lock.lock(); attrs[path] = (a, Date()); lock.unlock()
        return a
    }

    func readdir(_ path: String) async throws -> [Entry] {
        lock.lock()
        if let (e, t) = dirs[path], Date().timeIntervalSince(t) < ttl { lock.unlock(); return e }
        lock.unlock()
        let e = try await inner.readdir(path)
        let now = Date()
        lock.lock()
        dirs[path] = (e, now)
        for x in e { attrs[joinPath(path, x.name)] = (x.attr, now) }
        lock.unlock()
        return e
    }

    func read(_ path: String, offset: UInt64, count: UInt32) async throws -> (Data, Bool) {
        try await inner.read(path, offset: offset, count: count)
    }

    func write(_ path: String, offset: UInt64, data: Data) async throws -> UInt32 {
        defer { forget(path) }
        return try await inner.write(path, offset: offset, data: data)
    }

    func create(_ path: String, mode: UInt32, exclusive: Bool) async throws -> Attr {
        defer { forget(path) }
        return try await inner.create(path, mode: mode, exclusive: exclusive)
    }

    func mkdir(_ path: String, mode: UInt32) async throws -> Attr {
        defer { forget(path) }
        return try await inner.mkdir(path, mode: mode)
    }

    func remove(_ path: String) async throws {
        defer { forget(path) }
        try await inner.remove(path)
    }

    func rmdir(_ path: String) async throws {
        defer { forgetAll() }
        try await inner.rmdir(path)
    }

    func rename(_ from: String, _ to: String) async throws {
        defer { forgetAll() }
        try await inner.rename(from, to)
    }

    func setattr(_ path: String, mode: UInt32?, size: UInt64?, atime: Double?, mtime: Double?) async throws -> Attr {
        defer { forget(path) }
        return try await inner.setattr(path, mode: mode, size: size, atime: atime, mtime: mtime)
    }

    func statfs() async throws -> FsStat { try await inner.statfs() }
}
