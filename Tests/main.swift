import Foundation
import Network

// Integration test for the Core, run by Tests/run.sh. It starts a sharing side and a client in this
// one process, talks over real TCP on loopback, and mounts the share through the real macOS NFS client.

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
    print("\(f.string(from: Date())) " + (ok ? "PASS  \(name)" : "FAIL  \(name) \(detail)"))
    if !ok { failures += 1 }
}

func shell(_ cmd: String) async -> (Int32, String) {
    await Task.detached {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (p.terminationStatus, out.trimmingCharacters(in: .whitespacesAndNewlines))
    }.value
}

func errno(of op: () async throws -> Void) async -> Int32 {
    do { try await op(); return 0 } catch let e as FSError { return e.code } catch { return -1 }
}

func run() async {
    let base = NSTemporaryDirectory() + "sk-test-\(UUID().uuidString.prefix(8))"
    let share = base + "/share", outside = base + "/outside", mnt = base + "/mnt"
    let fm = FileManager.default
    for d in [share + "/sub", outside, base + "/idA", base + "/idB", base + "/idC"] {
        try! fm.createDirectory(atPath: d, withIntermediateDirectories: true)
    }
    try! "hello".write(toFile: share + "/hello.txt", atomically: true, encoding: .utf8)
    try! "in sub".write(toFile: share + "/sub/a.txt", atomically: true, encoding: .utf8)
    try! "TOP SECRET".write(toFile: outside + "/secret.txt", atomically: true, encoding: .utf8)
    try! fm.createSymbolicLink(atPath: share + "/escape", withDestinationPath: outside)
    try! fm.createSymbolicLink(atPath: share + "/inner", withDestinationPath: share + "/sub")
    try! fm.createSymbolicLink(atPath: share + "/dangling", withDestinationPath: base + "/nothing")
    _ = await shell("head -c 3000000 /dev/urandom > '\(share)/big.bin'")

    // MARK: confinement (the sharing side's own defence)
    let fs = FileServer(root: share)!
    check("root lists", (try? await fs.readdir("/").map(\.name).sorted()) == ["big.bin", "hello.txt", "inner", "sub"],
          "\((try? await fs.readdir("/").map(\.name).sorted()) ?? [])")
    check(".. is refused", await errno { _ = try await fs.getattr("/../outside/secret.txt") } == EACCES)
    check("embedded .. is refused", await errno { _ = try await fs.getattr("/sub/../../outside/secret.txt") } == EACCES)
    check("symlink out is refused", await errno { _ = try await fs.read("/escape/secret.txt", offset: 0, count: 100) } == EACCES)
    check("create through symlink out is refused", await errno { _ = try await fs.create("/escape/new.txt", mode: 0o644, exclusive: true) } == EACCES)
    check("rename out is refused", await errno { try await fs.rename("/hello.txt", "/../outside/hello.txt") } == EACCES)
    check("symlink in works", (try? await fs.read("/inner/a.txt", offset: 0, count: 100).0) == Data("in sub".utf8))
    check("outside untouched", !fm.fileExists(atPath: outside + "/new.txt") && !fm.fileExists(atPath: outside + "/hello.txt"))
    let ro = FileServer(root: share, readOnly: true)!
    check("read-only refuses write", await errno { _ = try await ro.create("/x", mode: 0o644, exclusive: true) } == EROFS)

    // MARK: pairing and handshake
    let idA = try! Identity.loadOrCreate(in: base + "/idA")   // shares
    let idB = try! Identity.loadOrCreate(in: base + "/idB")   // mounts
    let idC = try! Identity.loadOrCreate(in: base + "/idC")   // stranger
    let known = NSLock()
    var knownPeers: [Data: Data] = [:]
    var codeA = "", codeB = ""
    var answerA = true
    var sharingOn = true

    let listener = PeerListener(me: idA, name: "A")
    listener.lookupPeer = { id in known.lock(); defer { known.unlock() }; return knownPeers[id] }
    listener.sharedServer = { sharingOn ? FileServer(root: share) : nil }
    listener.confirmPairing = { code, _ in codeA = code; return answerA }
    listener.onPaired = { pub, _ in known.lock(); knownPeers[Identity.id(of: pub)] = pub; known.unlock() }
    try! await listener.start(advertise: false)
    let ep = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: listener.port)!)

    // Not paired: the handshake must not get anywhere.
    let stranger = RemoteClient(me: idB, peerPub: idA.pub, endpoint: { ep })
    stranger.start()
    check("unpaired Mac does not connect", !(await stranger.waitConnected(3)))
    stranger.stop()

    // Pairing where one side says the codes differ.
    answerA = false
    var c = Conn(to: ep)
    try? await c.start()
    let refused = await errno { _ = try await Pairing.initiate(c, me: idB, name: "B", confirm: { _, _ in true }) }
    check("pairing fails when one side says no", refused != 0 && knownPeers.isEmpty)

    // Pairing that works; both screens must show the same code.
    answerA = true
    c = Conn(to: ep)
    try? await c.start()
    let paired = try? await Pairing.initiate(c, me: idB, name: "B", confirm: { code, _ in codeB = code; return true })
    check("pairing succeeds", paired?.0 == idA.pub, "\(String(describing: paired))")
    check("both sides show the same six digits", codeA == codeB && codeA.count == 6, "\(codeA) \(codeB)")
    try? await Task.sleep(nanoseconds: 300_000_000)
    check("host stored the key", knownPeers[idB.id] == idB.pub)

    // A stranger with a valid-looking id but the wrong private key must not connect either.
    let impostor = RemoteClient(me: idC, peerPub: idA.pub, endpoint: { ep })
    impostor.start()
    check("unknown key does not connect", !(await impostor.waitConnected(3)))
    impostor.stop()

    // MARK: file operations over the network
    // Sharing is off when the link comes up: it connects, says so, serves nothing, and notices when that changes.
    sharingOn = false
    let client = RemoteClient(me: idB, peerPub: idA.pub, endpoint: { ep })
    client.pingInterval = 1
    var sharingTurnedOn = 0
    client.onConnect = { sharingTurnedOn += 1 }
    client.start()
    check("paired Mac connects while not sharing", await client.waitConnected(10))
    check("client knows the other Mac is not sharing", !client.peerSharing)
    check("nothing is served while not sharing", await errno { _ = try await client.getattr("/hello.txt") } == EACCES)
    let early = PeerVolume(peerName: "A", mountPath: mnt, client: client)
    var notSharing = false
    do { try await early.mount() } catch MountError.notSharing { notSharing = true } catch {}
    check("mount explains that the other Mac is not sharing", notSharing)
    sharingOn = true
    try? await Task.sleep(nanoseconds: 2_500_000_000)
    check("client notices sharing turned on", client.peerSharing && sharingTurnedOn >= 2, "\(sharingTurnedOn)")
    client.pingInterval = 15
    check("remote getattr", (try? await client.getattr("/hello.txt").size) == 5)
    check("remote readdir", (try? await client.readdir("/sub").map(\.name)) == ["a.txt"])
    check("remote read", (try? await client.read("/hello.txt", offset: 1, count: 3).0) == Data("ell".utf8))
    check("remote path escape refused", await errno { _ = try await client.getattr("/../outside/secret.txt") } == EACCES)
    check("remote missing file", await errno { _ = try await client.getattr("/nope") } == ENOENT)
    _ = try? await client.create("/new.txt", mode: 0o644, exclusive: true)
    _ = try? await client.write("/new.txt", offset: 0, data: Data("written".utf8))
    check("remote write lands on disk", (try? String(contentsOfFile: share + "/new.txt", encoding: .utf8)) == "written")
    check("remote exclusive create of existing fails", await errno { _ = try await client.create("/new.txt", mode: 0o644, exclusive: true) } == EEXIST)
    try? await client.rename("/new.txt", "/renamed.txt")
    check("remote rename", fm.fileExists(atPath: share + "/renamed.txt") && !fm.fileExists(atPath: share + "/new.txt"))
    try? await client.remove("/renamed.txt")
    check("remote remove", !fm.fileExists(atPath: share + "/renamed.txt"))

    // MARK: mounted through the macOS NFS client
    let volume = PeerVolume(peerName: "A", mountPath: mnt, client: client)
    do { try await volume.mount() } catch { check("mount", false, "\(error)") ; print("cannot continue without a mount"); return }
    check("mount", volume.isMounted)
    let m = "'\(mnt)'", s = "'\(share)'"

    var r = await shell("ls \(m)")
    check("ls shows the share", r.1.split(separator: "\n").map(String.init) == ["big.bin", "hello.txt", "inner", "sub"], r.1)
    r = await shell("cat \(m)/hello.txt \(m)/sub/a.txt")
    check("cat reads files", r.1 == "helloin sub", r.1)
    r = await shell("cat \(m)/inner/a.txt")
    check("symlink inside the share is followed", r.1 == "in sub", r.1)
    r = await shell("ls \(m)/escape 2>&1")
    check("symlink out of the share is not there", r.0 != 0, r.1)
    r = await shell("cmp \(m)/big.bin \(s)/big.bin && echo same")
    check("3 MB file reads identical", r.1 == "same", r.1)
    r = await shell("cp \(s)/big.bin \(m)/copy.bin && cmp \(m)/copy.bin \(s)/big.bin && cmp \(s)/copy.bin \(s)/big.bin && echo same")
    check("3 MB file writes identical", r.1 == "same", r.1)
    r = await shell("mkdir \(m)/dir && echo 'doc' > \(m)/dir/d.txt && cat \(s)/dir/d.txt")
    check("mkdir + create + write", r.1 == "doc", r.1)
    r = await shell("echo more >> \(m)/dir/d.txt && cat \(s)/dir/d.txt")
    check("append", r.1 == "doc\nmore", r.1)
    r = await shell("mv \(m)/dir/d.txt \(m)/dir/e.txt && ls \(s)/dir")
    check("rename", r.1 == "e.txt", r.1)
    r = await shell(": > \(m)/dir/e.txt && wc -c < \(s)/dir/e.txt")
    check("truncate to zero", r.1 == "0", r.1)
    r = await shell("touch -t 202001010000 \(m)/hello.txt && stat -f %Sm -t %Y \(s)/hello.txt")
    check("touch sets mtime", r.1 == "2020", r.1)
    r = await shell("chmod 600 \(m)/hello.txt && stat -f %Lp \(s)/hello.txt")
    check("chmod", r.1 == "600", r.1)
    r = await shell("rm \(m)/copy.bin \(m)/dir/e.txt && rmdir \(m)/dir && ls \(s)")
    check("remove + rmdir", !r.1.contains("dir") && !r.1.contains("copy.bin"), r.1)
    r = await shell("rmdir \(m)/sub 2>&1")
    check("rmdir of non-empty directory fails", r.0 != 0, r.1)
    r = await shell("df -k \(m) | tail -1 | awk '{print ($2 > 0)}'")
    check("df works", r.1 == "1", r.1)
    r = await shell("mkdir \(m)/many && for i in $(seq 1 300); do : > \(m)/many/f$i; done; ls \(m)/many | wc -l")
    check("300 files in one directory (paged readdir)", r.1 == "300", r.1)
    r = await shell("ls -l \(m)/many | wc -l")
    check("ls -l on it", r.1 == "301", r.1)
    r = await shell("rm -r \(m)/many; ls \(s) | grep -c many")
    check("rm -r", r.1 == "0", r.1)

    // MARK: the link drops (sleep, wifi change): the mount must come back by itself
    listener.disconnectAll()
    r = await shell("cat \(m)/hello.txt")
    check("a read right after the link dropped waits for the reconnect", r.1 == "hello", r.1)
    check("client reports connected again", await client.waitConnected(5))

    // MARK: sharing switched off on the host side applies at once, on links already open
    // (A create, not a read: a read of a file the NFS client already cached never reaches us.)
    sharingOn = false
    r = await shell("echo x > \(m)/offtest.txt 2>&1")
    check("sharing off stops an open link", r.0 != 0 && !fm.fileExists(atPath: share + "/offtest.txt"), r.1)
    sharingOn = true
    r = await shell("echo x > \(m)/offtest.txt && cat \(s)/offtest.txt && rm \(m)/offtest.txt")
    check("sharing on again", r.1 == "x", r.1)

    await volume.unmount()
    check("unmount", !volume.isMounted)
    client.stop()
    listener.stop()
    _ = await shell("rm -rf '\(base)'")
}

Task {
    await run()
    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
dispatchMain()
