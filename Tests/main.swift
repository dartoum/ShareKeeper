import Foundation
import Network

// Integration test for the Core, run by Tests/run.sh. Both Macs run in this one process: two folders,
// two identities, real TCP on loopback, and the sync engine between them.

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "PASS  \(name)" : "FAIL  \(name) \(detail)")
    if !ok { failures += 1 }
}

func errno(of op: () async throws -> Void) async -> Int32 {
    do { try await op(); return 0 } catch let e as FSError { return e.code } catch { return -1 }
}

let fm = FileManager.default
func write(_ path: String, _ text: String) { try! text.write(toFile: path, atomically: true, encoding: .utf8) }
func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
func listing(_ dir: String) -> [String] {
    ((try? fm.subpathsOfDirectory(atPath: dir)) ?? []).filter { !$0.hasSuffix(".DS_Store") }.sorted()
}
/// Gives the next write a different modification time even on a fast machine.
func later() async { try? await Task.sleep(nanoseconds: 20_000_000) }

func run() async {
    let base = NSTemporaryDirectory() + "sk-test-\(UUID().uuidString.prefix(8))"
    let share = base + "/share", outside = base + "/outside"
    for d in [share + "/sub", base + "/shareB", outside, base + "/idA", base + "/idB", base + "/idC"] {
        try! fm.createDirectory(atPath: d, withIntermediateDirectories: true)
    }
    write(share + "/hello.txt", "hello")
    write(share + "/sub/a.txt", "in sub")
    write(outside + "/secret.txt", "TOP SECRET")
    write(base + "/shareB/from-b.txt", "from B")
    try! fm.createSymbolicLink(atPath: share + "/escape", withDestinationPath: outside)
    try! fm.createSymbolicLink(atPath: share + "/inner", withDestinationPath: share + "/sub")

    // MARK: confinement (the sharing side's own defence)
    let fs = FileServer(root: share)!
    check("root lists", (try? await fs.readdir("/").map(\.name).sorted()) == ["hello.txt", "inner", "sub"],
          "\((try? await fs.readdir("/").map(\.name).sorted()) ?? [])")
    check(".. is refused", await errno { _ = try await fs.getattr("/../outside/secret.txt") } == EACCES)
    check("embedded .. is refused", await errno { _ = try await fs.getattr("/sub/../../outside/secret.txt") } == EACCES)
    check("symlink out is refused", await errno { _ = try await fs.read("/escape/secret.txt", offset: 0, count: 100) } == EACCES)
    check("create through symlink out is refused", await errno { _ = try await fs.create("/escape/new.txt", mode: 0o644, exclusive: true) } == EACCES)
    check("rename out is refused", await errno { try await fs.rename("/hello.txt", "/../outside/hello.txt") } == EACCES)
    check("trash out is refused", await errno { try await fs.trash("/../outside/secret.txt") } == EACCES)
    check("outside untouched", read(outside + "/secret.txt") == "TOP SECRET" && listing(outside) == ["secret.txt"])
    check("scan leaves symlinks out", (try? await fs.scan().map(\.name)) == ["/hello.txt", "/sub", "/sub/a.txt"],
          "\((try? await fs.scan().map(\.name)) ?? [])")
    try! fm.removeItem(atPath: share + "/escape")
    try! fm.removeItem(atPath: share + "/inner")

    // MARK: pairing and handshake
    let idA = try! Identity.loadOrCreate(in: base + "/idA")
    let idB = try! Identity.loadOrCreate(in: base + "/idB")
    let idC = try! Identity.loadOrCreate(in: base + "/idC")
    let known = NSLock()
    var knownPeers: [Data: Data] = [:]
    var codeA = "", codeB = ""
    var answerA = true

    let listener = PeerListener(me: idA, name: "A")
    listener.lookupPeer = { id in known.lock(); defer { known.unlock() }; return knownPeers[id] }
    listener.sharedServer = { FileServer(root: share) }
    listener.confirmPairing = { code, _ in codeA = code; return answerA }
    listener.onPaired = { pub, _ in known.lock(); knownPeers[Identity.id(of: pub)] = pub; known.unlock() }
    try! await listener.start(advertise: false)
    let ep = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: listener.port)!)

    let stranger = RemoteClient(me: idB, peerPub: idA.pub, endpoint: { ep })
    stranger.start()
    check("unpaired Mac does not connect", !(await stranger.waitConnected(3)))
    stranger.stop()

    answerA = false
    var c = Conn(to: ep)
    try? await c.start()
    let refused = await errno { _ = try await Pairing.initiate(c, me: idB, name: "B", confirm: { _, _ in true }) }
    check("pairing fails when one side says no", refused != 0 && knownPeers.isEmpty)

    answerA = true
    c = Conn(to: ep)
    try? await c.start()
    let paired = try? await Pairing.initiate(c, me: idB, name: "B", confirm: { code, _ in codeB = code; return true })
    check("pairing succeeds", paired?.0 == idA.pub)
    check("both sides show the same six digits", codeA == codeB && codeA.count == 6, "\(codeA) \(codeB)")
    try? await Task.sleep(nanoseconds: 300_000_000)
    check("host stored the key", knownPeers[idB.id] == idB.pub)

    let impostor = RemoteClient(me: idC, peerPub: idA.pub, endpoint: { ep })
    impostor.start()
    check("unknown key does not connect", !(await impostor.waitConnected(3)))
    impostor.stop()

    // MARK: one link, both directions
    // B dials A. A cannot find B, so it uses that same link to reach B's folder.
    let client = RemoteClient(me: idB, peerPub: idA.pub, endpoint: { ep })
    client.incoming = { req, body in await dispatch(FileServer(root: base + "/shareB"), req, body) }
    let clientA = RemoteClient(me: idA, peerPub: idB.pub, endpoint: { nil })
    clientA.incoming = { req, body in await dispatch(FileServer(root: share), req, body) }
    listener.adopt = { id, ch in
        guard id == idB.id else { return false }
        clientA.adopt(ch)
        return true
    }
    client.start()
    check("paired Mac connects", await client.waitConnected(10))
    check("the Mac that was dialed uses the same link", await clientA.waitConnected(5))
    check("dialer reads the other folder", (try? await client.read("/hello.txt", offset: 1, count: 3).0) == Data("ell".utf8))
    check("dialed side reads the dialer's folder", (try? await clientA.read("/from-b.txt", offset: 0, count: 100).0) == Data("from B".utf8))
    check("remote path escape refused", await errno { _ = try await client.getattr("/../outside/secret.txt") } == EACCES)
    check("remote scan", (try? await client.scan().map(\.name)) == ["/hello.txt", "/sub", "/sub/a.txt"])

    listener.disconnectAll()
    try? await Task.sleep(nanoseconds: 500_000_000)   // let both ends notice the drop
    let back = await client.waitConnected(8)
    let readable = (try? await client.getattr("/hello.txt")) != nil
    check("link comes back after a drop", back && readable)
    check("both directions work after the drop", (try? await clientA.read("/from-b.txt", offset: 0, count: 100).0) == Data("from B".utf8))

    // MARK: sync, between two local folders (the algorithm on its own)
    let left = base + "/left", right = base + "/right"
    for d in [left, right] { try! fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
    let lfs = FileServer(root: left)!, rfs = FileServer(root: right)!
    lfs.trashDir = base + "/trash-left"
    rfs.trashDir = base + "/trash-right"
    let engine = SyncEngine(local: lfs, remote: rfs, peerName: "Right Mac", statePath: base + "/sync.json")
    func sync() async -> Bool { (try? await engine.runOnce()) != nil }

    write(left + "/a.txt", "from left")
    try! fm.createDirectory(atPath: right + "/untitled folder/deep", withIntermediateDirectories: true)
    write(right + "/untitled folder/deep/b.txt", "from right")
    write(left + "/.DS_Store", "finder junk")
    check("first sync", await sync())
    check("both sides have everything", listing(left) == listing(right) && listing(left) == ["a.txt", "untitled folder", "untitled folder/deep", "untitled folder/deep/b.txt"],
          "\(listing(left)) | \(listing(right))")
    check("contents arrived", read(right + "/a.txt") == "from left" && read(left + "/untitled folder/deep/b.txt") == "from right")
    check("Finder's .DS_Store is not synced", !fm.fileExists(atPath: right + "/.DS_Store"))
    check("a second sync changes nothing", await sync() && listing(left) == listing(right))

    await later(); write(left + "/a.txt", "edited on left")
    check("edit on one side", await sync() && read(right + "/a.txt") == "edited on left")
    await later(); write(right + "/a.txt", "edited on right")
    check("edit on the other side", await sync() && read(left + "/a.txt") == "edited on right")

    try! fm.removeItem(atPath: right + "/a.txt")
    check("delete on one side", await sync() && !fm.fileExists(atPath: left + "/a.txt"))
    check("deleted file is in the Trash, not gone", listing(base + "/trash-left").contains { $0.hasSuffix("a.txt") })

    await later(); write(left + "/c.txt", "c"); _ = await sync()
    await later(); write(left + "/c.txt", "left version"); write(right + "/c.txt", "right version")
    check("conflict sync", await sync())
    check("conflict keeps both versions on both sides",
          read(left + "/c.txt") == "left version" && read(right + "/c.txt") == "left version"
            && read(left + "/c (Right Mac).txt") == "right version" && read(right + "/c (Right Mac).txt") == "right version",
          "\(listing(left)) | \(listing(right))")

    // A folder deleted on one side while a file in it was changed on the other: the changed file survives.
    await later(); write(left + "/untitled folder/deep/b.txt", "changed while the folder was deleted")
    try! fm.removeItem(atPath: right + "/untitled folder")
    check("folder delete vs edit", await sync())
    check("the edited file is kept on both sides",
          read(left + "/untitled folder/deep/b.txt") == "changed while the folder was deleted"
            && read(right + "/untitled folder/deep/b.txt") == "changed while the folder was deleted")

    try! fm.removeItem(atPath: left + "/untitled folder")
    check("folder delete", await sync() && !fm.fileExists(atPath: right + "/untitled folder"))

    let big = Data((0..<3_000_000).map { _ in UInt8.random(in: 0...255) })
    try! big.write(to: URL(fileURLWithPath: right + "/big.bin"))
    check("3 MB file copies identical", await sync() && fm.contents(atPath: left + "/big.bin") == big)
    check("no half-written temp files left", !listing(left).contains { $0.contains(".sk-tmp-") } && !listing(right).contains { $0.contains(".sk-tmp-") })

    let reloaded = SyncEngine(local: lfs, remote: rfs, peerName: "Right Mac", statePath: base + "/sync.json")
    try! fm.removeItem(atPath: left + "/big.bin")
    check("remembered state survives a restart (a delete is a delete)",
          (try? await reloaded.runOnce()) != nil && !fm.fileExists(atPath: right + "/big.bin"))

    // MARK: sync over the network link
    let netA = base + "/netA"
    try! fm.createDirectory(atPath: netA, withIntermediateDirectories: true)
    let afs = FileServer(root: netA)!
    afs.trashDir = base + "/trash-netA"
    write(netA + "/from A.txt", "A")
    let bfs = FileServer(root: base + "/shareB")!
    bfs.trashDir = base + "/trash-shareB"
    clientA.incoming = { req, body in await dispatch(afs, req, body) }
    client.incoming = { req, body in await dispatch(bfs, req, body) }
    let netEngine = SyncEngine(local: afs, remote: clientA, peerName: "B", statePath: nil)
    check("sync over the link", (try? await netEngine.runOnce()) != nil)
    check("over the link both folders match", listing(netA) == listing(base + "/shareB") && listing(netA) == ["from A.txt", "from-b.txt"],
          "\(listing(netA)) | \(listing(base + "/shareB"))")
    try! fm.removeItem(atPath: base + "/shareB/from-b.txt")
    check("delete over the link", (try? await netEngine.runOnce()) != nil && !fm.fileExists(atPath: netA + "/from-b.txt"))

    client.stop()
    clientA.stop()
    listener.stop()
    try? fm.removeItem(atPath: base)
}

Task {
    await run()
    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
dispatchMain()
