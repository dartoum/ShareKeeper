import Foundation
import CryptoKit

// Trust model: two Macs are paired once, by comparing a six digit code on both screens (like Bluetooth
// numeric comparison). Pairing leaves each side with the other's long-term X25519 public key. Every later
// connection is a mutually authenticated key exchange over those keys (Noise KK shaped: four
// Diffie-Hellman results, ephemeral + static, mixed through HKDF), then ChaCha20-Poly1305 frames.
// A device that is not paired, or that does not hold the private key it paired with, never gets a key.

typealias PrivKey = Curve25519.KeyAgreement.PrivateKey
typealias PubKey = Curve25519.KeyAgreement.PublicKey

struct Identity {
    let key: PrivKey

    var pub: Data { key.publicKey.rawRepresentation }
    /// First 8 bytes of SHA-256(pub): what a peer announces itself with, and what Bonjour carries.
    var id: Data { Identity.id(of: pub) }

    static func id(of pub: Data) -> Data { Data(SHA256.hash(data: pub).prefix(8)) }

    static func loadOrCreate(in dir: String) throws -> Identity {
        let path = dir + "/identity.key"
        if let d = FileManager.default.contents(atPath: path), let k = try? PrivKey(rawRepresentation: d) {
            return Identity(key: k)
        }
        let k = PrivKey()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(atPath: path, contents: k.rawRepresentation,
                                             attributes: [.posixPermissions: 0o600]) else { throw FSError(EIO) }
        return Identity(key: k)
    }
}

private func secret(_ priv: PrivKey, _ pub: Data) throws -> Data {
    let ss = try priv.sharedSecretFromKeyAgreement(with: PubKey(rawRepresentation: pub))
    return ss.withUnsafeBytes { Data($0) }
}

/// Encrypted, authenticated frames. One reader at a time; any number of writers.
final class Channel: @unchecked Sendable {
    let conn: Conn
    private let sendKey: SymmetricKey
    private let recvKey: SymmetricKey
    private var sendCtr: UInt64 = 0
    private var recvCtr: UInt64 = 0
    private let lock = NSLock()
    static let maxFrame = 4 << 20

    init(conn: Conn, sendKey: SymmetricKey, recvKey: SymmetricKey) {
        self.conn = conn
        self.sendKey = sendKey
        self.recvKey = recvKey
    }

    private static func nonce(_ n: UInt64) throws -> ChaChaPoly.Nonce {
        var d = Data(count: 4)
        for i in (0..<8).reversed() { d.append(UInt8((n >> UInt64(8 * i)) & 0xff)) }
        return try ChaChaPoly.Nonce(data: d)
    }

    func send(_ plain: Data) async throws {
        guard plain.count <= Channel.maxFrame else { throw FSError(EMSGSIZE) }
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            // Sealing and handing to the socket happen under one lock, so counter order is wire order.
            lock.lock()
            defer { lock.unlock() }
            do {
                let box = try ChaChaPoly.seal(plain, using: sendKey, nonce: Channel.nonce(sendCtr))
                sendCtr += 1
                var frame = be32(UInt32(box.ciphertext.count + 16))
                frame.append(box.ciphertext)
                frame.append(box.tag)
                conn.enqueue(frame) { e in if let e { k.resume(throwing: e) } else { k.resume() } }
            } catch {
                k.resume(throwing: error)
            }
        }
    }

    func recv() async throws -> Data {
        let len = Int(readBE32(try await conn.recv(4)))
        guard len >= 16, len <= Channel.maxFrame + 16 else { throw FSError(EPROTO) }
        let blob = try await conn.recv(len)
        let box = try ChaChaPoly.SealedBox(nonce: Channel.nonce(recvCtr),
                                           ciphertext: blob.prefix(len - 16), tag: blob.suffix(16))
        let plain = try ChaChaPoly.open(box, using: recvKey)
        recvCtr += 1
        return plain
    }
}

enum Handshake {
    private static let magic = Data("SKH1".utf8)

    private static func keys(_ dh: [Data], salt: Data) -> (ir: SymmetricKey, ri: SymmetricKey) {
        let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: dh.reduce(Data(), +)),
                                         salt: salt, info: Data("ShareKeeper v1 keys".utf8), outputByteCount: 64)
        let bytes = okm.withUnsafeBytes { Data($0) }
        return (SymmetricKey(data: bytes.prefix(32)), SymmetricKey(data: bytes.suffix(32)))
    }

    static func initiate(_ conn: Conn, me: Identity, peerPub: Data) async throws -> Channel {
        let eI = PrivKey()
        var m1 = magic
        m1.append(me.id)
        m1.append(eI.publicKey.rawRepresentation)
        try await conn.send(m1)
        let eR = try await conn.recv(32)

        let dh = [try secret(eI, eR), try secret(me.key, eR), try secret(eI, peerPub), try secret(me.key, peerPub)]
        let k = keys(dh, salt: Data(SHA256.hash(data: m1 + eR)))
        return Channel(conn: conn, sendKey: k.ir, recvKey: k.ri)
    }

    /// The four magic bytes are already read. `lookup` maps a peer id to the public key it paired with.
    static func accept(_ conn: Conn, me: Identity, lookup: (Data) -> Data?) async throws -> (Channel, Data) {
        let rest = try await conn.recv(8 + 32)
        let peerId = Data(rest.prefix(8))
        let eI = Data(rest.suffix(32))
        guard let sI = lookup(peerId), Identity.id(of: sI) == peerId else { throw FSError(EACCES) }

        let eR = PrivKey()
        try await conn.send(eR.publicKey.rawRepresentation)
        let m1 = magic + rest

        let dh = [try secret(eR, eI), try secret(eR, sI), try secret(me.key, eI), try secret(me.key, sI)]
        let k = keys(dh, salt: Data(SHA256.hash(data: m1 + eR.publicKey.rawRepresentation)))
        return (Channel(conn: conn, sendKey: k.ri, recvKey: k.ir), sI)
    }
}

/// Numeric comparison pairing. The initiator commits to its key before it sees the other's, so a
/// man in the middle cannot pick keys that produce the same code on both sides.
enum Pairing {
    static let magic = Data("SKP1".utf8)

    struct Msg: Codable {
        var t: String
        var h: String? = nil
        var pub: String? = nil
        var nonce: String? = nil
        var name: String? = nil
    }

    static func sas(initiatorPub: Data, nonce: Data, responderPub: Data) -> String {
        let h = Data(SHA256.hash(data: Data("SK-SAS".utf8) + initiatorPub + nonce + responderPub))
        let v = h.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        return String(format: "%06d", v)
    }

    private static func send(_ conn: Conn, _ m: Msg) async throws {
        let j = try JSONEncoder().encode(m)
        try await conn.send(be32(UInt32(j.count)) + j)
    }

    private static func recv(_ conn: Conn) async throws -> Msg {
        let n = Int(readBE32(try await conn.recv(4)))
        guard n > 0, n <= 4096 else { throw FSError(EPROTO) }
        return try JSONDecoder().decode(Msg.self, from: try await conn.recv(n))
    }

    private static func key(_ hex: String?) throws -> Data {
        guard let hex, let d = Data(hex: hex), d.count == 32 else { throw FSError(EPROTO) }
        return d
    }

    /// `confirm(code, peerName)` shows the code to the user; true when it matches the other screen.
    /// Returns the other side's public key and name once both users said yes.
    static func initiate(_ conn: Conn, me: Identity, name: String,
                         confirm: (String, String) async -> Bool) async throws -> (Data, String) {
        let nonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        try await conn.send(magic)
        try await send(conn, Msg(t: "commit", h: Data(SHA256.hash(data: me.pub + nonce)).hex))

        let theirs = try await recv(conn)
        guard theirs.t == "key" else { throw FSError(EPROTO) }
        let rPub = try key(theirs.pub)
        let rName = theirs.name ?? "Mac"

        try await send(conn, Msg(t: "reveal", pub: me.pub.hex, nonce: nonce.hex, name: name))
        let code = sas(initiatorPub: me.pub, nonce: nonce, responderPub: rPub)
        let ok = await confirm(code, rName)
        try await send(conn, Msg(t: ok ? "ok" : "no"))
        let verdict = try await recv(conn)
        guard ok, verdict.t == "ok" else { throw FSError(ECANCELED) }
        return (rPub, rName)
    }

    static func respond(_ conn: Conn, me: Identity, name: String,
                        confirm: (String, String) async -> Bool) async throws -> (Data, String) {
        let commit = try await recv(conn)
        guard commit.t == "commit", let want = commit.h else { throw FSError(EPROTO) }
        try await send(conn, Msg(t: "key", pub: me.pub.hex, name: name))

        let reveal = try await recv(conn)
        guard reveal.t == "reveal" else { throw FSError(EPROTO) }
        let iPub = try key(reveal.pub)
        guard let nonce = reveal.nonce.flatMap({ Data(hex: $0) }), nonce.count == 16,
              Data(SHA256.hash(data: iPub + nonce)).hex == want else { throw FSError(EPROTO) }
        let iName = reveal.name ?? "Mac"

        let code = sas(initiatorPub: iPub, nonce: nonce, responderPub: me.pub)
        let ok = await confirm(code, iName)
        try await send(conn, Msg(t: ok ? "ok" : "no"))
        let verdict = try await recv(conn)
        guard ok, verdict.t == "ok" else { throw FSError(ECANCELED) }
        return (iPub, iName)
    }
}
