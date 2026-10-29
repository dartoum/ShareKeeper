import Cocoa
import Network
import ServiceManagement
import UserNotifications
import os

// ShareKeeper: one folder, ~/ShareKeeper, with the same contents on every Mac you pair. Put something in
// it on one Mac and it appears on the other. Nothing else is shared, nothing to set up after pairing.
// See AGENTS.md.

// MARK: - Settings

struct PeerRecord: Codable {
    var id: String        // hex of the 8 byte peer id
    var name: String
    var pub: String       // hex of the X25519 public key it paired with
    var auto: Bool        // kept for settings written by 0.2; unused
}

enum Store {
    static var peers: [PeerRecord] {
        get { UserDefaults.standard.data(forKey: "peers").flatMap { try? JSONDecoder().decode([PeerRecord].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "peers") }
    }
    /// In the Dock and Cmd-Tab like any app (default), or only in the menu bar.
    static var showDock: Bool {
        get { UserDefaults.standard.object(forKey: "showDock") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showDock") }
    }
}

enum Notifier {
    static func setup(_ delegate: UNUserNotificationCenterDelegate) {
        let c = UNUserNotificationCenter.current()
        c.delegate = delegate
        c.requestAuthorization(options: [.alert]) { granted, error in
            log.notice("notifications allowed: \(granted), error: \(String(describing: error), privacy: .public)")
        }
    }

    static func post(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    /// "3 files from MacBook: a.txt, b.txt, c.txt", or nil when this Mac has nothing to be told.
    static func describe(_ r: SyncReport) -> String? {
        func names(_ l: [String]) -> String {
            let n = l.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            return l.count > 3 ? n + " …" : n
        }
        var lines: [String] = []
        if !r.receivedHere.isEmpty { lines.append("\(r.receivedHere.count) new or changed: \(names(r.receivedHere))") }
        if !r.trashedHere.isEmpty { lines.append("\(r.trashedHere.count) removed (in your Trash): \(names(r.trashedHere))") }
        if !r.conflicts.isEmpty { lines.append("Changed on both Macs, both versions kept: \(names(r.conflicts))") }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

let supportDir = NSHomeDirectory() + "/Library/Application Support/ShareKeeper"
let syncFolder = NSHomeDirectory() + "/ShareKeeper"

/// Bonjour endpoints by peer id, readable from the connection loops' threads.
final class EndpointBook: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: NWEndpoint] = [:]
    func set(_ m: [String: NWEndpoint]) { lock.lock(); map = m; lock.unlock() }
    func get(_ id: String) -> NWEndpoint? { lock.lock(); defer { lock.unlock() }; return map[id] }
}

/// Links by peer id, for the listener thread that hands over a connection a paired Mac dialed.
final class ClientBook: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: RemoteClient] = [:]
    func set(_ id: String, _ c: RemoteClient?) { lock.lock(); map[id] = c; lock.unlock() }
    func get(_ id: String) -> RemoteClient? { lock.lock(); defer { lock.unlock() }; return map[id] }
}

/// One paired Mac: the link to it, and the sync with it when this Mac is the one that drives it.
struct Peer {
    let client: RemoteClient
    let engine: SyncEngine?     // nil: the other Mac drives, we only answer and say when something changed
}

// MARK: - Moving off 0.2

/// 0.2 mounted the other Mac at ~/ShareKeeper/<name> and shared ~/ShareKeeper Drop. Undo the mounts (and
/// their empty folders) and move whatever was put in the Drop folder into ~/ShareKeeper.
func migrateFromMounts() {
    var buf: UnsafeMutablePointer<statfs>?
    let n = getmntinfo(&buf, MNT_NOWAIT)
    if n > 0, let mounts = buf {
        for i in 0..<Int(n) {
            var m = mounts[i]
            let from = withUnsafePointer(to: &m.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let on = withUnsafePointer(to: &m.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            guard from.hasPrefix("127.0.0.1:"), on.hasPrefix(syncFolder + "/") else { continue }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/sbin/umount")
            p.arguments = ["-f", on]
            try? p.run()
            p.waitUntilExit()
            rmdir(on)                       // only succeeds when empty, which a mount point is
            log.notice("removed old mount \(on, privacy: .public)")
        }
    }

    let fm = FileManager.default
    let drop = NSHomeDirectory() + "/ShareKeeper Drop"
    guard let items = try? fm.contentsOfDirectory(atPath: drop) else { return }
    try? fm.createDirectory(atPath: syncFolder, withIntermediateDirectories: true)
    for name in items {
        let src = drop + "/" + name
        if FileServer.ignored(name) { try? fm.removeItem(atPath: src); continue }
        if !fm.fileExists(atPath: syncFolder + "/" + name) { try? fm.moveItem(atPath: src, toPath: syncFolder + "/" + name) }
    }
    rmdir(drop)                             // left in place if anything could not be moved
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    var item: NSStatusItem!
    var identity: Identity!
    var local: FileServer!
    var listener: PeerListener!
    let discovery = Discovery()
    let endpoints = EndpointBook()
    let clients = ClientBook()
    let pathMonitor = NWPathMonitor()
    var peers: [String: Peer] = [:]
    var askingCode = false      // one pairing question at a time; anything else that knocks is refused
    var lastPath: NWPath.Status?
    var lastFingerprint: Int?
    let deviceName = Host.current().localizedName ?? "Mac"

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let img = NSImage(systemSymbolName: "folder.badge.person.crop", accessibilityDescription: "ShareKeeper")
        img?.isTemplate = true
        item.button?.image = img
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        do { identity = try Identity.loadOrCreate(in: supportDir) }
        catch { fatal("Cannot create this Mac's key: \(error.localizedDescription)"); return }

        Notifier.setup(self)
        migrateFromMounts()
        try? FileManager.default.createDirectory(atPath: syncFolder, withIntermediateDirectories: true)
        guard let fs = FileServer(root: syncFolder) else { fatal("Cannot use the folder \(syncFolder)."); return }
        local = fs

        listener = PeerListener(me: identity, name: deviceName)
        listener.lookupPeer = { id in
            Store.peers.first { Data(hex: $0.id) == id }.flatMap { Data(hex: $0.pub) }
        }
        listener.sharedServer = { [local] in local }
        listener.confirmPairing = { [weak self] code, name in await self?.askCode(code, name) ?? false }
        listener.onPaired = { [weak self] pub, name in
            DispatchQueue.main.async { self?.addPeer(pub: pub, name: name) }
        }
        // A Mac that can see us dials us; its connection is then our link to it as well.
        listener.adopt = { [clients] id, ch in
            guard let c = clients.get(id.hex) else { return false }
            c.adopt(ch)
            return true
        }
        Task {
            do { try await listener.start() }
            catch { log.error("listener: \(error.localizedDescription, privacy: .public)") }
        }

        discovery.onChange = { [weak self] in self?.peersChanged() }
        discovery.start()

        for rec in Store.peers { makePeer(rec) }

        pathMonitor.pathUpdateHandler = { [weak self] p in
            DispatchQueue.main.async {
                defer { self?.lastPath = p.status }
                if p.status == .satisfied, self?.lastPath != nil { self?.kickAll() }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "sk.path"))
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.kickAll()
        }

        // Something changed in ~/ShareKeeper: sync now. And every 20 s anyway, in case a nudge got lost.
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.checkLocalChanges() }
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.peers.values.forEach { $0.engine?.trigger() }
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        for p in peers.values { p.client.stop() }
    }

    // Notifications also show while the app is in front (the menu bar app often is).
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner])
    }

    /// Clicking the Dock icon opens the folder, which is what the app is about.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openFolder()
        return false
    }

    func fatal(_ text: String) {
        let a = NSAlert()
        a.messageText = "ShareKeeper"
        a.informativeText = text
        a.runModal()
        NSApp.terminate(nil)
    }

    // MARK: Peers

    func makePeer(_ rec: PeerRecord) {
        guard peers[rec.id] == nil, let pub = Data(hex: rec.pub) else { return }
        let id = rec.id
        let client = RemoteClient(me: identity, peerPub: pub, endpoint: { [endpoints] in endpoints.get(id) })
        // One Mac of the pair drives the sync, the same one on both sides: the one with the smaller id.
        let drives = identity.id.hex < id
        let engine = drives ? SyncEngine(local: local, remote: client, peerName: rec.name,
                                         statePath: supportDir + "/sync-\(id).json") : nil
        let local = self.local!
        let name = rec.name
        // This Mac drives: say what arrived here, and tell the other Mac what arrived there.
        engine?.onReport = { r in
            if let text = Notifier.describe(r) { Notifier.post("From \(name)", text) }
            Task { await client.notifyReport(r.mirrored) }
        }
        client.incoming = { req, body in
            if req.op == "changed" { engine?.trigger(); return (Response(id: req.id), Data()) }
            if req.op == "report" {      // the other Mac drove a sync and tells us what it did to our folder
                if let r = try? JSONDecoder().decode(SyncReport.self, from: body), let text = Notifier.describe(r) {
                    Notifier.post("From \(name)", text)
                }
                return (Response(id: req.id), Data())
            }
            return await dispatch(local, req, body)
        }
        client.onConnect = {
            if let engine { engine.trigger() } else { Task { await client.notifyChanged() } }
        }
        clients.set(id, client)
        peers[id] = Peer(client: client, engine: engine)
        client.start()
    }

    func addPeer(pub: Data, name: String) {
        let rec = PeerRecord(id: Identity.id(of: pub).hex, name: name, pub: pub.hex, auto: true)
        var all = Store.peers.filter { $0.id != rec.id }
        all.append(rec)
        Store.peers = all
        makePeer(rec)
        Notifier.post("Paired with \(name)", "The folder “ShareKeeper” in your home folder now has the same contents on both Macs.")
        // Show where things go, once.
        if !UserDefaults.standard.bool(forKey: "shownFolder") {
            UserDefaults.standard.set(true, forKey: "shownFolder")
            NSWorkspace.shared.open(URL(fileURLWithPath: syncFolder))
        }
    }

    func peersChanged() {
        endpoints.set(discovery.peers.mapValues(\.endpoint))
        kickAll()
    }

    func kickAll() {
        for p in peers.values where !p.client.isConnected { p.client.kick() }
    }

    func checkLocalChanges() {
        let local = self.local!
        Task.detached { [weak self] in
            guard let entries = try? await local.scan() else { return }
            var h = Hasher()
            for e in entries { h.combine(e.name); h.combine(e.attr.size); h.combine(e.attr.mtime); h.combine(e.attr.kind) }
            let f = h.finalize()
            await MainActor.run {
                guard let self else { return }
                defer { self.lastFingerprint = f }
                guard let last = self.lastFingerprint, last != f else { return }
                for p in self.peers.values {
                    if let e = p.engine { e.trigger() } else { Task { await p.client.notifyChanged() } }
                }
            }
        }
    }

    func askCode(_ code: String, _ name: String) async -> Bool {
        await MainActor.run {
            if askingCode { return false }
            askingCode = true
            defer { askingCode = false }
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Pair with \(name)?"
            a.informativeText = "\(name) should show this same code:\n\n\(code)\n\nAfter pairing, the folder “ShareKeeper” in your home folder has the same contents on both Macs."
            a.addButton(withTitle: "Codes match")
            a.addButton(withTitle: "Cancel")
            return a.runModal() == .alertFirstButtonReturn
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        kickAll()   // opening the menu is a good moment to look again
        let records = Store.peers

        if records.isEmpty { hint(menu, "Not paired with another Mac yet") }
        for (i, rec) in records.enumerated() {
            guard let p = peers[rec.id] else { continue }
            let status: String
            var why: String?
            if p.client.isConnected {
                if let e = p.engine {
                    if e.isRunning { status = "syncing…" }
                    else if e.lastError != nil { status = "some files could not be synced"; why = "ShareKeeper tries again by itself." }
                    else if let t = e.lastRun { status = "in sync (\(t.formatted(date: .omitted, time: .shortened)))" }
                    else { status = "connected" }
                } else {
                    status = "connected"
                }
            } else if endpoints.get(rec.id) == nil {
                status = "not found on the network"
                why = "Is ShareKeeper running on \(rec.name)? Syncing continues by itself when it shows up."
            } else {
                status = "cannot connect"
                why = "ShareKeeper keeps trying."
            }
            let row = NSMenuItem(title: "\(rec.name) — \(status)", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            if let why { hint(sub, why); sub.addItem(.separator()) }
            let forget = NSMenuItem(title: "Forget This Mac", action: #selector(forgetPeer(_:)), keyEquivalent: "")
            forget.target = self; forget.tag = i; sub.addItem(forget)
            row.submenu = sub
            menu.addItem(row)
        }

        let open = NSMenuItem(title: "Open ShareKeeper Folder", action: #selector(openFolder), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        let others = discovery.peers.values
            .filter { p in p.id != identity.id.hex && !records.contains(where: { r in r.id == p.id }) }
            .sorted { $0.name < $1.name }
        let pair = NSMenuItem(title: "Pair a New Mac", action: nil, keyEquivalent: "")
        let pairMenu = NSMenu()
        if others.isEmpty { hint(pairMenu, "No other Macs with ShareKeeper found nearby") }
        for p in others {
            let i = NSMenuItem(title: p.name, action: #selector(pairWith(_:)), keyEquivalent: "")
            i.representedObject = p.id; i.target = self; pairMenu.addItem(i)
        }
        pair.submenu = pairMenu
        menu.addItem(pair)
        menu.addItem(.separator())

        let dock = NSMenuItem(title: "Show in Dock", action: #selector(toggleDock), keyEquivalent: "")
        dock.target = self; dock.state = Store.showDock ? .on : .off
        menu.addItem(dock)
        let login = NSMenuItem(title: "Launch on login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self; login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(withTitle: "Quit ShareKeeper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    func hint(_ menu: NSMenu, _ text: String) {
        let i = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        i.isEnabled = false
        menu.addItem(i)
    }

    @objc func openFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: syncFolder))
    }

    @objc func forgetPeer(_ s: NSMenuItem) {
        let records = Store.peers
        guard records.indices.contains(s.tag) else { return }
        let rec = records[s.tag]
        Store.peers = records.filter { $0.id != rec.id }
        clients.set(rec.id, nil)
        peers.removeValue(forKey: rec.id)?.client.stop()
        try? FileManager.default.removeItem(atPath: supportDir + "/sync-\(rec.id).json")
    }

    @objc func pairWith(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String, let peer = discovery.peers[id] else { return }
        let me = identity!, name = deviceName
        Task {
            do {
                let conn = Conn(to: peer.endpoint)
                try await conn.start(timeout: 10)
                let (pub, peerName) = try await withTimeout(180, onTimeout: { conn.close() }) {
                    try await Pairing.initiate(conn, me: me, name: name, confirm: { code, n in await self.askCode(code, n) })
                }
                conn.close()
                await MainActor.run { self.addPeer(pub: pub, name: peerName) }
            } catch let e as FSError where e.code == ECANCELED {
                log.notice("pairing cancelled")
            } catch {
                log.error("pairing failed: \(String(describing: error), privacy: .public)")
                await MainActor.run {
                    NSApp.activate(ignoringOtherApps: true)
                    let a = NSAlert()
                    a.messageText = "Pairing with \(peer.name) failed"
                    a.informativeText = "Is ShareKeeper running on \(peer.name), and are both Macs on the same network?"
                    a.runModal()
                }
            }
        }
    }

    @objc func toggleDock() {
        Store.showDock.toggle()
        NSApp.setActivationPolicy(Store.showDock ? .regular : .accessory)
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { log.error("login item: \(error.localizedDescription, privacy: .public)") }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(Store.showDock ? .regular : .accessory)
app.run()
