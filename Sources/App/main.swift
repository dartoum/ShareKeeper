import Cocoa
import Network
import ServiceManagement
import os

// ShareKeeper: shares one folder of this Mac with your other Macs and mounts theirs here as volumes,
// over an encrypted link of its own. No File Sharing, no accounts, no FUSE driver. See AGENTS.md.

// MARK: - Settings

struct PeerRecord: Codable {
    var id: String        // hex of the 8 byte peer id
    var name: String
    var pub: String       // hex of the X25519 public key it paired with
    var auto: Bool        // false = unmounted by hand; stays that way until mounted again
}

enum Store {
    private static let d = UserDefaults.standard

    static var peers: [PeerRecord] {
        get { d.data(forKey: "peers").flatMap { try? JSONDecoder().decode([PeerRecord].self, from: $0) } ?? [] }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "peers") }
    }
    static var sharedPath: String? {
        get { d.string(forKey: "sharedPath") }
        set { d.set(newValue, forKey: "sharedPath") }
    }
    static var sharing: Bool {
        get { d.bool(forKey: "sharing") }
        set { d.set(newValue, forKey: "sharing") }
    }
    static var readOnly: Bool {
        get { d.bool(forKey: "readOnly") }
        set { d.set(newValue, forKey: "readOnly") }
    }
}

let supportDir = NSHomeDirectory() + "/Library/Application Support/ShareKeeper"
let mountBase = NSHomeDirectory() + "/ShareKeeper"

/// Bonjour endpoints by peer id, readable from the connection loops' threads.
final class EndpointBook: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: NWEndpoint] = [:]
    func set(_ m: [String: NWEndpoint]) { lock.lock(); map = m; lock.unlock() }
    func get(_ id: String) -> NWEndpoint? { lock.lock(); defer { lock.unlock() }; return map[id] }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    var identity: Identity!
    var listener: PeerListener!
    let discovery = Discovery()
    let endpoints = EndpointBook()
    let pathMonitor = NWPathMonitor()
    var volumes: [String: PeerVolume] = [:]
    var askingCode = false      // one pairing question at a time; anything else that knocks is refused
    var lastPath: NWPath.Status?
    let deviceName = Host.current().localizedName ?? "Mac"

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let img = NSImage(systemSymbolName: "externaldrive.connected.to.line.below", accessibilityDescription: "ShareKeeper")
        img?.isTemplate = true
        item.button?.image = img
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        do { identity = try Identity.loadOrCreate(in: supportDir) }
        catch { fatal("Cannot create this Mac's key: \(error.localizedDescription)"); return }

        // A mount left behind by a crash has no server any more and would hang Finder.
        for stale in NFSMount.staleMounts(under: mountBase) {
            log.notice("unmounting stale \(stale, privacy: .public)")
            Self.umountSync(stale)
        }

        listener = PeerListener(me: identity, name: deviceName)
        listener.lookupPeer = { id in
            Store.peers.first { Data(hex: $0.id) == id }.flatMap { Data(hex: $0.pub) }
        }
        listener.sharedServer = {
            guard Store.sharing, let p = Store.sharedPath else { return nil }
            return FileServer(root: p, readOnly: Store.readOnly)
        }
        listener.confirmPairing = { [weak self] code, name in await self?.askCode(code, name) ?? false }
        listener.onPaired = { [weak self] pub, name in
            DispatchQueue.main.async { self?.addPeer(pub: pub, name: name); self?.offerSharing(with: name) }
        }
        Task {
            do { try await listener.start() }
            catch { log.error("listener: \(error.localizedDescription, privacy: .public)") }
        }

        discovery.onChange = { [weak self] in self?.peersChanged() }
        discovery.start()

        for rec in Store.peers { makeVolume(rec) }

        // A network that came back, or a Mac that woke up: do not wait for the next retry.
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
    }

    func applicationWillTerminate(_ n: Notification) {
        for v in volumes.values { v.client.stop(); if v.isMounted { Self.umountSync(v.mountPath) } }
    }

    static func umountSync(_ path: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/umount")
        p.arguments = ["-f", path]
        try? p.run()
        p.waitUntilExit()
    }

    func fatal(_ text: String) {
        let a = NSAlert()
        a.messageText = "ShareKeeper"
        a.informativeText = text
        a.runModal()
        NSApp.terminate(nil)
    }

    // MARK: Peers and volumes

    func makeVolume(_ rec: PeerRecord) {
        guard volumes[rec.id] == nil, let pub = Data(hex: rec.pub) else { return }
        let id = rec.id
        let client = RemoteClient(me: identity, peerPub: pub, endpoint: { [endpoints] in endpoints.get(id) })
        let safe = rec.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let vol = PeerVolume(peerName: rec.name, mountPath: mountBase + "/" + safe, client: client)
        client.onConnect = { [weak self] in Task { await self?.autoMount(id) } }
        volumes[rec.id] = vol
        client.start()
    }

    func autoMount(_ id: String) async {
        guard let rec = Store.peers.first(where: { $0.id == id }), rec.auto, let vol = volumes[id] else { return }
        do { try await vol.mount() }
        catch { log.error("mount \(rec.name, privacy: .public): \(error.localizedDescription, privacy: .public)") }
    }

    func peersChanged() {
        endpoints.set(discovery.peers.mapValues(\.endpoint))
        kickAll()
    }

    func kickAll() {
        for v in volumes.values where !v.client.isConnected { v.client.kick() }
    }

    func addPeer(pub: Data, name: String) {
        let rec = PeerRecord(id: Identity.id(of: pub).hex, name: name, pub: pub.hex, auto: true)
        var all = Store.peers.filter { $0.id != rec.id }
        all.append(rec)
        Store.peers = all
        makeVolume(rec)
    }

    func askCode(_ code: String, _ name: String) async -> Bool {
        await MainActor.run {
            if askingCode { return false }
            askingCode = true
            defer { askingCode = false }
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Pair with \(name)?"
            a.informativeText = "\(name) should show this same code:\n\n\(code)\n\nOnly continue if the codes are identical. If you did not start this, choose Cancel."
            a.addButton(withTitle: "Codes match")
            a.addButton(withTitle: "Cancel")
            return a.runModal() == .alertFirstButtonReturn
        }
    }

    static let defaultShareFolder = NSHomeDirectory() + "/ShareKeeper Drop"

    /// Right after pairing, for a Mac that never shared anything: share one ready-made folder, and say so.
    /// Whoever turned sharing off or picked a folder on purpose is left alone.
    func offerSharing(with name: String) {
        guard Store.sharedPath == nil else { return }
        try? FileManager.default.createDirectory(atPath: Self.defaultShareFolder, withIntermediateDirectories: true)
        Store.sharedPath = Self.defaultShareFolder
        Store.sharing = true

        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Paired with \(name)"
        a.informativeText = "Files you put in the folder “ShareKeeper Drop” in your home folder can be opened and changed by \(name). It cannot see anything else on this Mac. You can pick another folder, or stop sharing, in the ShareKeeper menu."
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Choose Another Folder…")
        if a.runModal() == .alertSecondButtonReturn { chooseFolder() }
    }

    func showError(_ title: String, _ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = error.localizedDescription
        a.runModal()
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let records = Store.peers

        kickAll()   // opening the menu is a good moment to look again
        if records.isEmpty { hint(menu, "No Macs paired yet — pair with one below") }
        for (i, rec) in records.enumerated() {
            let vol = volumes[rec.id]
            let mounted = vol?.isMounted ?? false
            let client = vol?.client
            let status: String
            if mounted { status = "mounted" }
            else if !rec.auto { status = "paused" }
            else if client?.isConnected == true { status = client?.peerSharing == true ? "connecting…" : "not sharing a folder yet" }
            else if endpoints.get(rec.id) == nil { status = "not found on the network" }
            else { status = "cannot connect" }
            let row = NSMenuItem(title: "\(rec.name) — \(status)", action: nil, keyEquivalent: "")
            row.state = mounted ? .on : .off
            let sub = NSMenu()
            if mounted { act(sub, "Open in Finder", #selector(openPeer(_:)), i) }
            act(sub, mounted ? "Unmount" : "Mount", mounted ? #selector(unmountPeer(_:)) : #selector(mountPeer(_:)), i)
            sub.addItem(.separator())
            act(sub, "Forget This Mac", #selector(forgetPeer(_:)), i)
            row.submenu = sub
            menu.addItem(row)
        }
        menu.addItem(.separator())

        let others = discovery.peers.values
            .filter { p in p.id != identity.id.hex && !records.contains(where: { r in r.id == p.id }) }
            .sorted { $0.name < $1.name }
        let pair = NSMenuItem(title: "Pair with…", action: nil, keyEquivalent: "")
        let pairMenu = NSMenu()
        if others.isEmpty { hint(pairMenu, "No other Macs found") }
        for p in others {
            let i = NSMenuItem(title: p.name, action: #selector(pairWith(_:)), keyEquivalent: "")
            i.representedObject = p.id; i.target = self; pairMenu.addItem(i)
        }
        pair.submenu = pairMenu
        menu.addItem(pair)
        menu.addItem(.separator())

        if !records.isEmpty && !Store.sharing { hint(menu, "Nothing is shared from this Mac yet") }
        let share = NSMenuItem(title: "Share a Folder from This Mac", action: #selector(toggleSharing), keyEquivalent: "")
        share.target = self; share.state = Store.sharing ? .on : .off
        menu.addItem(share)
        if let p = Store.sharedPath {
            let show = NSMenuItem(title: "Show “\((p as NSString).lastPathComponent)” in Finder", action: #selector(showShared), keyEquivalent: "")
            show.target = self; menu.addItem(show)
            let folder = NSMenuItem(title: "Choose Another Folder…", action: #selector(chooseFolder), keyEquivalent: "")
            folder.target = self; menu.addItem(folder)
            let ro = NSMenuItem(title: "Read-only", action: #selector(toggleReadOnly), keyEquivalent: "")
            ro.target = self; ro.state = Store.readOnly ? .on : .off; menu.addItem(ro)
        }
        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch on login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self; login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ShareKeeper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    func hint(_ menu: NSMenu, _ text: String) {
        let i = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        i.isEnabled = false
        menu.addItem(i)
    }

    func act(_ menu: NSMenu, _ title: String, _ sel: Selector, _ tag: Int) {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self; i.tag = tag; menu.addItem(i)
    }

    func record(_ s: NSMenuItem) -> PeerRecord? { Store.peers.indices.contains(s.tag) ? Store.peers[s.tag] : nil }

    @objc func openPeer(_ s: NSMenuItem) {
        guard let rec = record(s), let v = volumes[rec.id] else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: v.mountPath))
    }

    @objc func mountPeer(_ s: NSMenuItem) {
        guard let rec = record(s) else { return }
        var all = Store.peers
        all[s.tag].auto = true
        Store.peers = all
        guard let v = volumes[rec.id] else { return }
        v.client.kick()
        Task {
            do { try await v.mount() }
            catch { await MainActor.run { self.showError("Cannot mount \(rec.name)", error) } }
        }
    }

    @objc func unmountPeer(_ s: NSMenuItem) {
        guard let rec = record(s), let v = volumes[rec.id] else { return }
        var all = Store.peers
        all[s.tag].auto = false
        Store.peers = all
        Task { await v.unmount() }
    }

    @objc func forgetPeer(_ s: NSMenuItem) {
        guard let rec = record(s) else { return }
        Store.peers = Store.peers.filter { $0.id != rec.id }
        if let v = volumes.removeValue(forKey: rec.id) {
            v.client.stop()
            Task { await v.unmount() }
        }
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
                await MainActor.run { self.addPeer(pub: pub, name: peerName); self.offerSharing(with: peerName) }
            } catch let e as FSError where e.code == ECANCELED {
                log.notice("pairing cancelled")
            } catch {
                log.error("pairing failed: \(String(describing: error), privacy: .public)")
                await MainActor.run {
                    self.showError("Pairing with \(peer.name) failed",
                                   MountError.unreachable(peer.name, nil))
                }
            }
        }
    }

    @objc func toggleSharing() {
        if Store.sharedPath == nil { chooseFolder(); return }
        Store.sharing.toggle()
    }

    @objc func chooseFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Share"
        panel.message = "Macs you pair with can see and change everything in this folder, and nothing outside it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Store.sharedPath = url.path
        Store.sharing = true
    }

    @objc func showShared() {
        guard let p = Store.sharedPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: p))
    }

    @objc func toggleReadOnly() { Store.readOnly.toggle() }

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
app.setActivationPolicy(.accessory)
app.run()
