import Foundation
import Network

// A small NFS version 3 server on 127.0.0.1, so that macOS can mount "a folder on another Mac" as an
// ordinary volume without File Sharing and without a FUSE driver. It speaks ONC RPC over TCP (RFC 5531),
// MOUNT v3 and NFS v3 (RFC 1813), and turns every call into a FileBackend call. Only the pieces macOS
// needs are here; symlinks, hard links and device nodes answer "not supported".

private let localUid = getuid()
private let localGid = getgid()

struct XDRError: Error {}

struct XDRWriter {
    var b: [UInt8] = []

    mutating func u32(_ v: UInt32) { b += [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    mutating func u64(_ v: UInt64) { u32(UInt32(v >> 32)); u32(UInt32(v & 0xffff_ffff)) }
    mutating func bool(_ v: Bool) { u32(v ? 1 : 0) }
    mutating func fixed(_ d: [UInt8]) { b += d; b += [UInt8](repeating: 0, count: (4 - d.count % 4) % 4) }
    mutating func opaque(_ d: [UInt8]) { u32(UInt32(d.count)); fixed(d) }
    mutating func string(_ s: String) { opaque(Array(s.utf8)) }

    mutating func time(_ t: Double) {
        let s = min(max(t, 0), 4_294_967_295)
        let sec = UInt32(s)
        u32(sec)
        u32(UInt32((s - Double(sec)) * 1e9))
    }

    mutating func fattr(_ a: Attr) {
        u32(a.kind == 2 ? 2 : 1)
        u32(a.mode & 0o7777)
        u32(max(a.nlink, a.kind == 2 ? 2 : 1))
        u32(localUid); u32(localGid)
        u64(a.size)
        u64((a.size + 4095) / 4096 * 4096)
        u32(0); u32(0)                 // rdev
        u64(1)                         // fsid
        u64(a.ino)
        time(a.atime); time(a.mtime); time(a.ctime)
    }

    mutating func postOp(_ a: Attr?) {
        if let a { bool(true); fattr(a) } else { bool(false) }
    }

    mutating func wcc(_ a: Attr?) {
        bool(false)                    // no pre-operation attributes
        postOp(a)
    }
}

struct XDRReader {
    let b: [UInt8]
    var o = 0

    init(_ b: [UInt8]) { self.b = b }

    mutating func u32() throws -> UInt32 {
        guard o + 4 <= b.count else { throw XDRError() }
        defer { o += 4 }
        return UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }

    mutating func u64() throws -> UInt64 {
        let h = try u32(), l = try u32()
        return UInt64(h) << 32 | UInt64(l)
    }

    mutating func bool() throws -> Bool { try u32() != 0 }

    mutating func fixed(_ n: Int) throws -> [UInt8] {
        guard n >= 0, o + n <= b.count else { throw XDRError() }
        let r = Array(b[o..<o + n])
        o = min(o + n + (4 - n % 4) % 4, b.count)
        return r
    }

    mutating func opaque(max: Int = 1 << 21) throws -> [UInt8] {
        let n = Int(try u32())
        guard n <= max else { throw XDRError() }
        return try fixed(n)
    }

    mutating func string() throws -> String { String(decoding: try opaque(max: 4096), as: UTF8.self) }
}

/// File handles: an 8 byte id that the server maps to a virtual path. Handles do not survive a restart
/// of the server, which is the correct answer for a mount of a server that is gone (NFS3ERR_STALE).
private final class Handles {
    private let lock = NSLock()
    private var toPath: [UInt64: String] = [1: "/"]
    private var toId: [String: UInt64] = ["/": 1]
    private var next: UInt64 = 2

    func id(for path: String) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        if let i = toId[path] { return i }
        let i = next
        next += 1
        toPath[i] = path
        toId[path] = i
        return i
    }

    func path(_ id: UInt64) -> String? {
        lock.lock(); defer { lock.unlock() }
        return toPath[id]
    }

    func forget(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        for (p, i) in toId where p == path || p.hasPrefix(path + "/") {
            toId[p] = nil
            toPath[i] = nil
        }
    }

    func rename(_ from: String, _ to: String) {
        lock.lock(); defer { lock.unlock() }
        for (p, i) in toId where p == to || p.hasPrefix(to + "/") {   // whatever the target overwrote
            toId[p] = nil
            toPath[i] = nil
        }
        for (p, i) in toId where p == from || p.hasPrefix(from + "/") {
            let np = to + p.dropFirst(from.count)
            toId[p] = nil
            toId[np] = i
            toPath[i] = np
        }
    }
}

private enum NFS3 {
    static let ok: UInt32 = 0, noent: UInt32 = 2, io: UInt32 = 5, inval: UInt32 = 22, stale: UInt32 = 70
    static let notSupp: UInt32 = 10004, serverFault: UInt32 = 10006, nameTooLong: UInt32 = 63

    static func status(_ errno: Int32) -> UInt32 {
        switch errno {
        case 1, 2, 5, 6, 13, 17, 18, 19, 20, 21, 22, 27, 28, 30, 31, 63, 66, 69: return UInt32(errno)
        case ENOSYS, ENOTSUP: return notSupp
        default: return io
        }
    }
}

final class NFSServer: @unchecked Sendable {
    private let backend: FileBackend
    private let handles = Handles()
    private let listener: NWListener
    private let queue = DispatchQueue(label: "sk.nfs")
    private let verifier: [UInt8] = (0..<8).map { _ in UInt8.random(in: 0...255) }
    private(set) var port: UInt16 = 0

    init(backend: FileBackend) throws {
        self.backend = backend
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
    }

    func start() async throws -> UInt16 {
        if port != 0 { return port }
        listener.newConnectionHandler = { [weak self] c in
            let conn = Conn(c)
            Task {
                do { try await conn.start(); await self?.serve(conn) } catch { conn.close() }
            }
        }
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            var done = false
            listener.stateUpdateHandler = { st in
                guard !done else { return }
                switch st {
                case .ready: done = true; k.resume()
                case .failed(let e): done = true; k.resume(throwing: e)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        port = listener.port?.rawValue ?? 0
        return port
    }

    func stop() { listener.cancel() }

    // MARK: RPC framing

    private func serve(_ conn: Conn) async {
        do {
            while true {
                var msg: [UInt8] = []
                while true {
                    let h = readBE32(try await conn.recv(4))
                    let len = Int(h & 0x7fff_ffff)
                    guard len <= 1 << 21, msg.count + len <= 1 << 21 else { throw FSError(EMSGSIZE) }
                    msg += [UInt8](try await conn.recv(len))
                    if h & 0x8000_0000 != 0 { break }
                }
                Task {
                    guard let reply = await self.handleCall(msg) else { return }
                    try? await conn.send(be32(UInt32(reply.count) | 0x8000_0000) + Data(reply))
                }
            }
        } catch {
            conn.close()
        }
    }

    private func header(_ xid: UInt32, accept stat: UInt32) -> XDRWriter {
        var w = XDRWriter()
        w.u32(xid); w.u32(1); w.u32(0)       // reply, MSG_ACCEPTED
        w.u32(0); w.u32(0)                   // verifier AUTH_NONE
        w.u32(stat)
        return w
    }

    private func denied(_ xid: UInt32) -> [UInt8] {
        var w = XDRWriter()
        w.u32(xid); w.u32(1); w.u32(1)       // reply, MSG_DENIED
        w.u32(1); w.u32(5)                   // AUTH_ERROR, AUTH_TOOWEAK
        return w.b
    }

    private func handleCall(_ msg: [UInt8]) async -> [UInt8]? {
        var r = XDRReader(msg)
        guard let xid = try? r.u32() else { return nil }
        do {
            guard try r.u32() == 0, try r.u32() == 2 else { return nil }
            let prog = try r.u32(), vers = try r.u32(), proc = try r.u32()
            let flavor = try r.u32()
            let cred = try r.opaque(max: 400)
            _ = try r.u32(); _ = try r.opaque(max: 400)           // verifier

            // Any process on this Mac can reach a loopback port. Only our own user (and root) gets in.
            if proc != 0 {
                var c = XDRReader(cred)
                guard flavor == 1, (try? c.u32()) != nil, (try? c.string()) != nil, let uid = try? c.u32(),
                      uid == localUid || uid == 0 else { return denied(xid) }
            }

            switch prog {
            case 100005:
                guard vers == 3 else { return mismatch(xid) }
                var w = header(xid, accept: 0)
                guard try mount(proc, &r, &w) else { return header(xid, accept: 3).b }
                return w.b
            case 100003:
                guard vers == 3 else { return mismatch(xid) }
                guard proc <= 21 else { return header(xid, accept: 3).b }
                var w = header(xid, accept: 0)
                w.b += try await nfs(proc, &r).b
                return w.b
            default:
                return header(xid, accept: 1).b   // PROG_UNAVAIL
            }
        } catch {
            return header(xid, accept: 4).b       // GARBAGE_ARGS
        }
    }

    private func mismatch(_ xid: UInt32) -> [UInt8] {
        var w = header(xid, accept: 2)
        w.u32(3); w.u32(3)
        return w.b
    }

    // MARK: MOUNT v3

    private func mount(_ proc: UInt32, _ r: inout XDRReader, _ w: inout XDRWriter) throws -> Bool {
        switch proc {
        case 0, 3, 4: return true                       // NULL, UMNT, UMNTALL
        case 1:                                         // MNT: every path is the root of the share
            _ = try r.string()
            w.u32(0)
            w.opaque(fh(1))
            w.u32(1); w.u32(1)                          // one auth flavor: AUTH_SYS
            return true
        case 2: w.bool(false); return true              // DUMP
        case 5:                                         // EXPORT
            w.bool(true); w.string("/"); w.bool(false); w.bool(false)
            return true
        default: return false
        }
    }

    // MARK: NFS v3

    private func fh(_ id: UInt64) -> [UInt8] { (0..<8).map { UInt8((id >> UInt64(56 - 8 * $0)) & 0xff) } }

    private func readFH(_ r: inout XDRReader) throws -> String? {
        let b = try r.opaque(max: 64)
        guard b.count == 8 else { return nil }
        return handles.path(b.reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
    }

    private func checkName(_ n: String) throws {
        if n.isEmpty || n.contains("/") || n.contains("\0") { throw FSError(EINVAL) }
        if n.utf8.count > 255 { throw FSError(ENAMETOOLONG) }
    }

    private struct SAttr {
        var mode: UInt32?
        var size: UInt64?
        var atime: Double?
        var mtime: Double?
    }

    private func readSAttr(_ r: inout XDRReader) throws -> SAttr {
        var s = SAttr()
        if try r.bool() { s.mode = try r.u32() }
        if try r.bool() { _ = try r.u32() }             // uid: the other Mac decides ownership
        if try r.bool() { _ = try r.u32() }             // gid
        if try r.bool() { s.size = try r.u64() }
        func time(_ r: inout XDRReader) throws -> Double? {
            switch try r.u32() {
            case 1: return Date().timeIntervalSince1970
            case 2: let sec = try r.u32(), ns = try r.u32(); return Double(sec) + Double(ns) / 1e9
            default: return nil
            }
        }
        s.atime = try time(&r)
        s.mtime = try time(&r)
        return s
    }

    /// The reply body for a failed call, shaped the way each procedure's failure arm is defined.
    private func failure(_ proc: UInt32, _ status: UInt32, _ attr: Attr? = nil) -> XDRWriter {
        var w = XDRWriter()
        w.u32(status)
        switch proc {
        case 1: break
        case 2, 7, 8, 9, 10, 11, 12, 13, 21: w.wcc(attr)
        case 14: w.wcc(attr); w.wcc(nil)
        case 15: w.postOp(attr); w.wcc(nil)
        default: w.postOp(attr)
        }
        return w
    }

    private func nfs(_ proc: UInt32, _ r: inout XDRReader) async throws -> XDRWriter {
        var w = XDRWriter()
        if proc == 0 { return w }

        // Everything but NULL starts with a file handle.
        guard let path = try readFH(&r) else { return failure(proc, NFS3.stale) }
        let dirAttr: () async -> Attr? = { try? await self.backend.getattr(path) }

        do {
            switch proc {
            case 1:                                                       // GETATTR
                w.u32(0)
                w.fattr(try await backend.getattr(path))

            case 2:                                                       // SETATTR
                let s = try readSAttr(&r)
                let a = try await backend.setattr(path, mode: s.mode, size: s.size, atime: s.atime, mtime: s.mtime)
                w.u32(0); w.wcc(a)

            case 3:                                                       // LOOKUP
                let name = try r.string()
                let child: String
                if name == "." { child = path }
                else if name == ".." { child = parentPath(path) }
                else { try checkName(name); child = joinPath(path, name) }
                let a = try await backend.getattr(child)
                w.u32(0)
                w.opaque(fh(handles.id(for: child)))
                w.postOp(a)
                w.postOp(await dirAttr())

            case 4:                                                       // ACCESS
                let want = try r.u32()
                let a = try await backend.getattr(path)
                w.u32(0); w.postOp(a); w.u32(want & 0x3f)                 // the other Mac enforces the rest

            case 5:                                                       // READLINK
                return failure(proc, NFS3.inval)

            case 6:                                                       // READ
                let off = try r.u64(), count = try r.u32()
                let (data, eof) = try await backend.read(path, offset: off, count: min(count, 1 << 17))
                w.u32(0); w.postOp(await dirAttr())
                w.u32(UInt32(data.count)); w.bool(eof); w.opaque([UInt8](data))

            case 7:                                                       // WRITE
                let off = try r.u64()
                _ = try r.u32(); _ = try r.u32()                          // count, stable_how
                let data = try r.opaque(max: 1 << 20)
                let n = try await backend.write(path, offset: off, data: Data(data))
                w.u32(0); w.wcc(await dirAttr())
                w.u32(n); w.u32(2); w.fixed(verifier)                     // FILE_SYNC

            case 8:                                                       // CREATE
                let name = try r.string()
                try checkName(name)
                let how = try r.u32()
                var mode: UInt32 = 0o644
                var truncate = false
                if how == 2 { _ = try r.fixed(8) }
                else { let s = try readSAttr(&r); mode = s.mode ?? 0o644; truncate = (s.size == 0) }
                let child = joinPath(path, name)
                var a: Attr
                do {
                    a = try await backend.create(child, mode: mode, exclusive: how == 1)
                } catch let e as FSError where e.code == EEXIST && how == 2 {
                    a = try await backend.getattr(child)
                }
                if truncate && how == 0 && a.size > 0 {
                    a = try await backend.setattr(child, mode: nil, size: 0, atime: nil, mtime: nil)
                }
                w.u32(0)
                w.bool(true); w.opaque(fh(handles.id(for: child)))
                w.postOp(a)
                w.wcc(await dirAttr())

            case 9:                                                       // MKDIR
                let name = try r.string()
                try checkName(name)
                let s = try readSAttr(&r)
                let child = joinPath(path, name)
                let a = try await backend.mkdir(child, mode: s.mode ?? 0o755)
                w.u32(0)
                w.bool(true); w.opaque(fh(handles.id(for: child)))
                w.postOp(a)
                w.wcc(await dirAttr())

            case 10, 11, 15:                                              // SYMLINK, MKNOD, LINK
                return failure(proc, NFS3.notSupp)

            case 12, 13:                                                  // REMOVE, RMDIR
                let name = try r.string()
                try checkName(name)
                let child = joinPath(path, name)
                if proc == 12 { try await backend.remove(child) } else { try await backend.rmdir(child) }
                handles.forget(child)
                w.u32(0); w.wcc(await dirAttr())

            case 14:                                                      // RENAME
                let from = try r.string()
                guard let toDir = try readFH(&r) else { return failure(proc, NFS3.stale) }
                let to = try r.string()
                try checkName(from); try checkName(to)
                let src = joinPath(path, from), dst = joinPath(toDir, to)
                try await backend.rename(src, dst)
                handles.rename(src, dst)
                w.u32(0); w.wcc(await dirAttr()); w.wcc(try? await backend.getattr(toDir))

            case 16, 17:                                                  // READDIR, READDIRPLUS
                let cookie = Int(try r.u64())
                _ = try r.fixed(8)                                        // cookieverf
                let first = try r.u32()
                let budget = Int(proc == 17 ? try r.u32() : first)
                let dirA = try await backend.getattr(path)
                let entries = try await backend.readdir(path).sorted { $0.name < $1.name }
                // "." and ".." first, then the entries by name; a cookie is the position after that item.
                let all: [(String, Attr)] = [(".", dirA), ("..", dirA)] + entries.map { ($0.name, $0.attr) }
                w.u32(0); w.postOp(dirA); w.fixed([UInt8](repeating: 0, count: 8))
                var used = 160
                var i = max(cookie, 0)
                while i < all.count {
                    let (name, a) = all[i]
                    let size = 8 + 4 + ((name.utf8.count + 3) & ~3) + 8 + (proc == 17 ? 4 + 84 + 4 + 12 : 0)
                    if used + size > budget && i > cookie { break }
                    used += size
                    w.bool(true); w.u64(a.ino); w.string(name); w.u64(UInt64(i + 1))
                    if proc == 17 {
                        w.postOp(a)
                        let child = name == "." ? path : name == ".." ? parentPath(path) : joinPath(path, name)
                        w.bool(true); w.opaque(fh(handles.id(for: child)))
                    }
                    i += 1
                }
                w.bool(false)
                w.bool(i >= all.count)

            case 18:                                                      // FSSTAT
                let s = try await backend.statfs()
                w.u32(0); w.postOp(await dirAttr())
                w.u64(s.total); w.u64(s.free); w.u64(s.free)
                w.u64(s.files); w.u64(s.ffree); w.u64(s.ffree)
                w.u32(0)

            case 19:                                                      // FSINFO
                w.u32(0); w.postOp(await dirAttr())
                w.u32(1 << 17); w.u32(1 << 16); w.u32(512)               // rtmax, rtpref, rtmult
                w.u32(1 << 17); w.u32(1 << 16); w.u32(512)               // wtmax, wtpref, wtmult
                w.u32(1 << 15)                                            // dtpref
                w.u64(0x7fff_ffff_ffff_ffff)
                w.u32(1); w.u32(0)                                        // time_delta
                w.u32(0x18)                                               // homogeneous, can set time

            case 20:                                                      // PATHCONF
                w.u32(0); w.postOp(await dirAttr())
                w.u32(1); w.u32(255)
                w.bool(true); w.bool(true); w.bool(false); w.bool(true)

            case 21:                                                      // COMMIT
                w.u32(0); w.wcc(await dirAttr()); w.fixed(verifier)

            default:
                return failure(proc, NFS3.notSupp)
            }
            return w
        } catch let e as FSError {
            log.notice("nfs proc \(proc) failed: \(e.description, privacy: .public)")
            return failure(proc, NFS3.status(e.code), await dirAttr())
        } catch let e as XDRError {
            throw e
        } catch {
            return failure(proc, NFS3.io)
        }
    }
}

enum NFSMount {
    static func mount(port: UInt16, at path: String) async throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let opts = "vers=3,tcp,port=\(port),mountport=\(port),soft,dumbtimer,timeo=100,retrans=3,locallocks,noresvport,rsize=65536,wsize=65536"
        try await run("/sbin/mount_nfs", ["-o", opts, "127.0.0.1:/", path])
    }

    static func unmount(at path: String) async {
        _ = try? await run("/sbin/umount", ["-f", path])
    }

    /// Mount points of ours that are still mounted: left over after a crash, they would hang Finder.
    static func staleMounts(under base: String) -> [String] {
        var buf: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&buf, MNT_NOWAIT)
        guard n > 0, let mounts = buf else { return [] }
        var out: [String] = []
        for i in 0..<Int(n) {
            var m = mounts[i]
            let from = withUnsafePointer(to: &m.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let on = withUnsafePointer(to: &m.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if from.hasPrefix("127.0.0.1:"), on.hasPrefix(base + "/") { out.append(on) }
        }
        return out
    }

    static func isMounted(_ path: String) -> Bool {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return false }
        let type = withUnsafePointer(to: &s.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
        }
        let on = withUnsafePointer(to: &s.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return type == "nfs" && on == (realPath(path) ?? path)
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) async throws -> String {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            let pipe = Pipe()
            p.standardError = pipe
            p.standardOutput = pipe
            try p.run()
            p.waitUntilExit()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard p.terminationStatus == 0 else {
                throw NSError(domain: "ShareKeeper", code: Int(p.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: "\(tool): \(out.trimmingCharacters(in: .whitespacesAndNewlines))"])
            }
            return out
        }.value
    }
}
