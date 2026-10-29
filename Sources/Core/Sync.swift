import Foundation

/// What a file or folder looks like for the purpose of "did it change": folders are just folders,
/// files are size + modification time (to the millisecond; copies get the source's time).
struct Sig: Codable, Equatable {
    var dir: Bool
    var size: UInt64
    var mtime: Int64

    init(_ a: Attr) {
        dir = a.kind == 2
        size = dir ? 0 : a.size
        mtime = dir ? 0 : Int64((a.mtime * 1000).rounded())
    }
}

/// What one sync run did, as seen from this Mac's side ("local"). Mirrored when it is told to the other Mac.
struct SyncReport: Codable {
    var receivedHere: [String] = []      // new or changed files that arrived on this Mac
    var sentAway: [String] = []          // ... that were copied to the other Mac
    var trashedHere: [String] = []       // deleted here because the other Mac deleted them
    var trashedAway: [String] = []
    var conflicts: [String] = []         // files changed on both; both versions were kept

    var isEmpty: Bool { receivedHere.isEmpty && sentAway.isEmpty && trashedHere.isEmpty && trashedAway.isEmpty && conflicts.isEmpty }

    /// The same run from the other Mac's point of view.
    var mirrored: SyncReport {
        SyncReport(receivedHere: sentAway, sentAway: receivedHere, trashedHere: trashedAway, trashedAway: trashedHere, conflicts: conflicts)
    }
}

/// Keeps one folder the same on this Mac and one paired Mac. A three-way comparison: what each side has
/// now, and what both had after the last run ("base"). That is what tells a new file from a deleted one.
///
/// - New or changed on one side only: copied to the other.
/// - Deleted on one side and untouched on the other: moved to the Trash on the other side, never erased.
/// - Changed on both sides since the last run: both kept; the other Mac's version gets its name added.
///
/// Only one Mac of a pair runs this (the one with the smaller id); the other just answers requests.
/// Copies are written to a temporary name and renamed into place, so nobody sees half a file.
final class SyncEngine: @unchecked Sendable {
    let local: FileBackend
    let remote: FileBackend
    let peerName: String
    private let statePath: String?

    private let lock = NSLock()
    private var base: [String: Sig]
    private var running = false
    private var again = false
    private var _lastRun: Date?
    private var _lastError: String?

    var onChange: (@Sendable () -> Void)?
    /// Called after a run that changed something.
    var onReport: (@Sendable (SyncReport) -> Void)?

    init(local: FileBackend, remote: FileBackend, peerName: String, statePath: String?) {
        self.local = local
        self.remote = remote
        self.peerName = peerName
        self.statePath = statePath
        if let statePath, let d = FileManager.default.contents(atPath: statePath),
           let b = try? JSONDecoder().decode([String: Sig].self, from: d) {
            base = b
        } else {
            base = [:]
        }
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    var lastRun: Date? { lock.lock(); defer { lock.unlock() }; return _lastRun }
    var lastError: String? { lock.lock(); defer { lock.unlock() }; return _lastError }

    /// Run soon. A request while a run is busy makes it go round once more afterwards.
    func trigger() {
        lock.lock()
        if running { again = true; lock.unlock(); return }
        running = true
        lock.unlock()
        onChange?()
        Task {
            while true {
                var problem: String?
                do { try await runOnce() } catch { problem = String(describing: error) }
                lock.lock()
                _lastError = problem
                if problem == nil { _lastRun = Date() }
                let more = again
                again = false
                if !more { running = false }
                lock.unlock()
                onChange?()
                if !more { break }
            }
        }
    }

    /// One full comparison and the copies it calls for. Throws when anything could not be done; what could
    /// be done is done, and what failed is tried again next time.
    func runOnce() async throws {
        let l = try await sigs(local)
        let r = try await sigs(remote)
        lock.lock(); let base = self.base; lock.unlock()

        var next: [String: Sig] = [:]
        var gone: [String] = []       // trashed folders: everything below them is gone too
        var failed = 0
        var report = SyncReport()

        func below(_ p: String, _ roots: [String]) -> Bool { roots.contains { p == $0 || p.hasPrefix($0 + "/") } }
        func untouched(_ side: [String: Sig], under p: String) -> Bool {
            side.allSatisfy { k, v in !k.hasPrefix(p + "/") || base[k] == v }
        }

        // Sorted, so a folder is always handled before what is in it.
        for p in Set(l.keys).union(r.keys).union(base.keys).sorted() {
            if below(p, gone) { continue }
            let b = base[p]
            do {
                switch (l[p], r[p]) {
                case let (x?, y?) where x == y:
                    next[p] = x
                case let (x?, y?):
                    if x.dir != y.dir {
                        log.error("sync: \(p, privacy: .public) is a file on one Mac and a folder on the other; left alone")
                        continue
                    }
                    if b == x {
                        try await copy(p, from: remote, to: local); next[p] = y
                        if !y.dir { report.receivedHere.append(p) }
                    } else if b == y {
                        try await copy(p, from: local, to: remote); next[p] = x
                        if !x.dir { report.sentAway.append(p) }
                    } else {
                        // Changed on both: keep ours under the name, theirs next to it with their name on it.
                        let alt = try await conflictPath(p)
                        try await copy(p, from: remote, to: local, as: alt)
                        try await copy(alt, from: local, to: remote)
                        try await copy(p, from: local, to: remote)
                        next[p] = x
                        next[alt] = Sig(try await local.getattr(alt))
                        report.conflicts.append(p)
                    }
                case let (x?, nil):
                    if let b, b == x, !x.dir || untouched(l, under: p) {
                        try await local.trash(p); gone.append(p)        // they deleted it, we did not touch it
                        report.trashedHere.append(p)
                    } else {
                        try await copy(p, from: local, to: remote); next[p] = x
                        if !x.dir { report.sentAway.append(p) }
                    }
                case let (nil, y?):
                    if let b, b == y, !y.dir || untouched(r, under: p) {
                        try await remote.trash(p); gone.append(p)
                        report.trashedAway.append(p)
                    } else {
                        try await copy(p, from: remote, to: local); next[p] = y
                        if !y.dir { report.receivedHere.append(p) }
                    }
                case (nil, nil):
                    break
                }
            } catch {
                failed += 1
                if let b { next[p] = b }     // as if this round never happened for this path
                log.error("sync: \(p, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        lock.lock(); self.base = next; lock.unlock()
        save(next)
        if !report.isEmpty { onReport?(report) }
        if failed > 0 { throw FSError(EIO) }
    }

    private func sigs(_ side: FileBackend) async throws -> [String: Sig] {
        var out: [String: Sig] = [:]
        for e in try await side.scan() { out[e.name] = Sig(e.attr) }
        return out
    }

    private func save(_ b: [String: Sig]) {
        guard let statePath, let d = try? JSONEncoder().encode(b) else { return }
        try? d.write(to: URL(fileURLWithPath: statePath), options: .atomic)
    }

    /// "report.pdf" -> "report (Other Mac).pdf", numbered when that is taken as well.
    private func conflictPath(_ p: String) async throws -> String {
        let dir = parentPath(p)
        let name = (p as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        for n in 1...100 {
            let tag = n == 1 ? peerName : "\(peerName) \(n)"
            let candidate = joinPath(dir, ext.isEmpty ? "\(stem) (\(tag))" : "\(stem) (\(tag)).\(ext)")
            if (try? await local.getattr(candidate)) == nil, (try? await remote.getattr(candidate)) == nil { return candidate }
        }
        throw FSError(EEXIST)
    }

    private func copy(_ p: String, from src: FileBackend, to dst: FileBackend, as q: String? = nil) async throws {
        let q = q ?? p
        let a = try await src.getattr(p)
        if a.kind == 2 {
            if (try? await dst.getattr(q))?.kind != 2 { _ = try await dst.mkdir(q, mode: a.mode & 0o777) }
            return
        }
        let tmp = joinPath(parentPath(q), ".sk-tmp-" + UUID().uuidString.prefix(8))
        _ = try await dst.create(tmp, mode: (a.mode & 0o777) | 0o600, exclusive: true)
        do {
            var off: UInt64 = 0
            while true {
                let (d, eof) = try await src.read(p, offset: off, count: 1 << 20)
                if !d.isEmpty {
                    _ = try await dst.write(tmp, offset: off, data: d)
                    off += UInt64(d.count)
                }
                if eof || d.isEmpty { break }
            }
            _ = try await dst.setattr(tmp, mode: nil, size: nil, atime: nil, mtime: a.mtime)
            try await dst.rename(tmp, q)
        } catch {
            try? await dst.remove(tmp)
            throw error
        }
    }
}
