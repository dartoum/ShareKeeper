import Foundation

/// The folder this Mac shares. Every path that comes in from the network is virtual ("/" is the shared
/// folder) and is checked here, on the Mac that owns the files: no "..", and symlinks are followed only
/// when they stay inside the shared folder. Entries that point outside are hidden, not served.
final class FileServer: FileBackend {
    let root: String
    var readOnly: Bool

    init?(root: String, readOnly: Bool = false) {
        guard let r = realPath(root) else { return nil }
        var st = stat()
        guard stat(r, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
        self.root = r
        self.readOnly = readOnly
    }

    // MARK: Path confinement

    private func components(_ vpath: String) throws -> [String] {
        var out: [String] = []
        for c in vpath.split(separator: "/", omittingEmptySubsequences: true) {
            let s = String(c)
            if s == "." { continue }
            if s == ".." || s.contains("\0") { throw FSError(EACCES) }
            out.append(s)
        }
        return out
    }

    private func inside(_ p: String) -> Bool { p == root || p.hasPrefix(root + "/") }

    /// An existing entry, symlinks followed, as a real path that is inside the share.
    private func resolveExisting(_ vpath: String) throws -> String {
        let comps = try components(vpath)
        let joined = comps.isEmpty ? root : root + "/" + comps.joined(separator: "/")
        guard let real = realPath(joined) else { throw FSError(errno == 0 ? ENOENT : errno) }
        guard inside(real) else { throw FSError(EACCES) }
        return real
    }

    /// A name inside a directory that may not exist yet (create, remove, rename target): the directory
    /// is resolved and checked, the last component is not followed.
    private func resolveEntry(_ vpath: String) throws -> String {
        let comps = try components(vpath)
        guard let last = comps.last else { throw FSError(EINVAL) }
        let parent = try resolveExisting("/" + comps.dropLast().joined(separator: "/"))
        return parent + "/" + last
    }

    private func writable() throws {
        if readOnly { throw FSError(EROFS) }
    }

    private func attr(from st: stat) throws -> Attr {
        let kind: UInt8
        switch st.st_mode & S_IFMT {
        case S_IFDIR: kind = 2
        case S_IFREG: kind = 1
        default: throw FSError(EINVAL)   // sockets, devices, fifos are not shared
        }
        func t(_ ts: timespec) -> Double { Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9 }
        return Attr(kind: kind, size: UInt64(max(st.st_size, 0)), mode: UInt32(st.st_mode & 0o7777),
                    atime: t(st.st_atimespec), mtime: t(st.st_mtimespec), ctime: t(st.st_ctimespec),
                    ino: st.st_ino, nlink: UInt32(st.st_nlink))
    }

    private func attrOf(real: String) throws -> Attr {
        var st = stat()
        guard stat(real, &st) == 0 else { throw FSError(errno) }
        return try attr(from: st)
    }

    // MARK: FileBackend

    func getattr(_ path: String) async throws -> Attr {
        try attrOf(real: try resolveExisting(path))
    }

    func readdir(_ path: String) async throws -> [Entry] {
        let real = try resolveExisting(path)
        guard let d = opendir(real) else { throw FSError(errno) }
        defer { closedir(d) }
        var out: [Entry] = []
        while let e = Darwin.readdir(d) {
            let name = withUnsafePointer(to: &e.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard let r = realPath(real + "/" + name), inside(r), let a = try? attrOf(real: r) else { continue }
            out.append(Entry(name: name, attr: a))
        }
        return out
    }

    func read(_ path: String, offset: UInt64, count: UInt32) async throws -> (Data, Bool) {
        let real = try resolveExisting(path)
        let fd = open(real, O_RDONLY)
        guard fd >= 0 else { throw FSError(errno) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw FSError(errno) }
        if (st.st_mode & S_IFMT) == S_IFDIR { throw FSError(EISDIR) }
        let want = Int(min(count, 1 << 20))
        var buf = Data(count: want)
        let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, want, off_t(offset)) }
        guard n >= 0 else { throw FSError(errno) }
        return (buf.prefix(n), offset + UInt64(n) >= UInt64(st.st_size))
    }

    func write(_ path: String, offset: UInt64, data: Data) async throws -> UInt32 {
        try writable()
        let real = try resolveExisting(path)
        let fd = open(real, O_WRONLY)
        guard fd >= 0 else { throw FSError(errno) }
        defer { close(fd) }
        var done = 0
        while done < data.count {
            let n = data.withUnsafeBytes { raw in
                pwrite(fd, raw.baseAddress! + done, data.count - done, off_t(offset) + off_t(done))
            }
            guard n > 0 else { throw FSError(errno == 0 ? EIO : errno) }
            done += n
        }
        return UInt32(done)
    }

    func create(_ path: String, mode: UInt32, exclusive: Bool) async throws -> Attr {
        try writable()
        let real = try resolveEntry(path)
        var st = stat()
        if lstat(real, &st) == 0 {
            if exclusive { throw FSError(EEXIST) }
            return try await getattr(path)   // already there; resolves (and confines) a symlink
        }
        let fd = open(real, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(mode & 0o777))
        guard fd >= 0 else { throw FSError(errno) }
        close(fd)
        return try attrOf(real: real)
    }

    func mkdir(_ path: String, mode: UInt32) async throws -> Attr {
        try writable()
        let real = try resolveEntry(path)
        guard Darwin.mkdir(real, mode_t(mode & 0o777)) == 0 else { throw FSError(errno) }
        return try attrOf(real: real)
    }

    func remove(_ path: String) async throws {
        try writable()
        guard unlink(try resolveEntry(path)) == 0 else { throw FSError(errno) }
    }

    func rmdir(_ path: String) async throws {
        try writable()
        guard Darwin.rmdir(try resolveEntry(path)) == 0 else { throw FSError(errno) }
    }

    func rename(_ from: String, _ to: String) async throws {
        try writable()
        guard Darwin.rename(try resolveEntry(from), try resolveEntry(to)) == 0 else { throw FSError(errno) }
    }

    func setattr(_ path: String, mode: UInt32?, size: UInt64?, atime: Double?, mtime: Double?) async throws -> Attr {
        try writable()
        let real = try resolveExisting(path)
        if let mode, chmod(real, mode_t(mode & 0o7777)) != 0 { throw FSError(errno) }
        if let size, truncate(real, off_t(size)) != 0 { throw FSError(errno) }
        if atime != nil || mtime != nil {
            let omit = Int((1 << 30) - 2)   // UTIME_OMIT
            func ts(_ t: Double?) -> timespec {
                guard let t else { return timespec(tv_sec: 0, tv_nsec: omit) }
                let s = floor(t)
                return timespec(tv_sec: Int(s), tv_nsec: Int((t - s) * 1e9))
            }
            var times = [ts(atime), ts(mtime)]
            guard utimensat(AT_FDCWD, real, &times, 0) == 0 else { throw FSError(errno) }
        }
        return try attrOf(real: real)
    }

    func statfs() async throws -> FsStat {
        var s = statvfs()
        guard statvfs(root, &s) == 0 else { throw FSError(errno) }
        let fr = UInt64(s.f_frsize)
        return FsStat(total: UInt64(s.f_blocks) * fr, free: UInt64(s.f_bavail) * fr,
                      files: UInt64(s.f_files), ffree: UInt64(s.f_ffree))
    }
}

/// Answers one request from a paired Mac out of the shared folder.
/// `fs` is nil while sharing is off: the link stays up (the other Mac can see that, and say so), but
/// nothing is served.
func dispatch(_ fs: FileServer?, _ req: Request, _ body: Data) async -> (Response, Data) {
    var resp = Response(id: req.id)
    var out = Data()
    if req.op == "ping" { resp.sharing = fs != nil; return (resp, out) }
    guard let fs else { resp.err = EACCES; return (resp, out) }
    do {
        switch req.op {
        case "getattr": resp.attr = try await fs.getattr(req.path)
        case "readdir": resp.entries = try await fs.readdir(req.path)
        case "read":
            let (d, eof) = try await fs.read(req.path, offset: req.off, count: req.len)
            out = d
            resp.eof = eof
        case "write": resp.n = try await fs.write(req.path, offset: req.off, data: body)
        case "create": resp.attr = try await fs.create(req.path, mode: req.mode ?? 0o644, exclusive: req.flag)
        case "mkdir": resp.attr = try await fs.mkdir(req.path, mode: req.mode ?? 0o755)
        case "remove": try await fs.remove(req.path)
        case "rmdir": try await fs.rmdir(req.path)
        case "rename": try await fs.rename(req.path, req.to)
        case "setattr":
            resp.attr = try await fs.setattr(req.path, mode: req.mode, size: req.size, atime: req.atime, mtime: req.mtime)
        case "statfs": resp.stat = try await fs.statfs()
        default: resp.err = ENOSYS
        }
    } catch let e as FSError {
        resp.err = e.code
    } catch {
        resp.err = EIO
    }
    return (resp, out)
}
