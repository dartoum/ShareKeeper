import Cocoa
import Network
import NetFS
import ServiceManagement
import os

let log = Logger(subsystem: "nl.david.ShareKeeper", category: "main")

// ShareKeeper: keeps SMB shares of other Macs mounted.
// macOS File Sharing already serves and announces the folder (Bonjour _smb._tcp);
// this app only remounts it after sleep, a network change, or the host coming back.

// MARK: - Settings

struct Share: Codable, Equatable {
    var host: String        // Bonjour service name, i.e. the other Mac's computer name
    var name: String        // shared folder name as set in File Sharing
    var auto: Bool = true   // false = user unmounted it here; leave it alone until mounted again

    var title: String { "\(name) on \(host)" }

    // Bonjour form, the same one Finder uses: resolved at mount time, so a new IP address is no problem.
    var url: URL? {
        var c = URLComponents()
        c.scheme = "smb"
        c.host = "\(host)._smb._tcp.local"
        c.path = "/" + name
        return c.url
    }
}

enum Prefs {
    static var shares: [Share] {
        get {
            guard let d = UserDefaults.standard.data(forKey: "shares") else { return [] }
            return (try? JSONDecoder().decode([Share].self, from: d)) ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "shares") }
    }
}

// MARK: - Mounting

// Mounted smbfs volumes, keyed by "host/share" in lowercase.
// f_mntfromname looks like "//user@Host._smb._tcp.local/Share" (host percent-encoded when it has spaces).
func mountedShares() -> [String: URL] {
    var out: [String: URL] = [:]
    var buf: UnsafeMutablePointer<statfs>?
    let n = getmntinfo(&buf, MNT_NOWAIT)
    guard n > 0, let mounts = buf else { return out }
    for i in 0..<Int(n) {
        var m = mounts[i]
        let type = withUnsafePointer(to: &m.f_fstypename) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
        guard type == "smbfs" else { continue }
        let from = withUnsafePointer(to: &m.f_mntfromname) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
        let onPath = withUnsafePointer(to: &m.f_mntonname) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
        var rest = from.drop(while: { $0 == "/" })
        if let at = rest.firstIndex(of: "@") { rest = rest[rest.index(after: at)...] }
        guard let slash = rest.firstIndex(of: "/") else { continue }
        var host = String(rest[..<slash]).removingPercentEncoding ?? String(rest[..<slash])
        if let dot = host.range(of: "._smb._tcp.local") { host = String(host[..<dot.lowerBound]) }
        else if host.hasSuffix(".local") { host = String(host.dropLast(6)) }
        let share = String(rest[rest.index(after: slash)...]).removingPercentEncoding ?? ""
        out["\(host)/\(share)".lowercased()] = URL(fileURLWithPath: onPath)
    }
    return out
}

func key(_ s: Share) -> String { "\(s.host)/\(s.name)".lowercased() }

var inFlight = Set<String>()

// interactive = may show the system login dialog (with "Remember in keychain").
// Automatic remounts never do: a password dialog popping up after every wake is worse than no mount.
func mount(_ s: Share, interactive: Bool, done: (() -> Void)? = nil) {
    let k = key(s)
    guard let url = s.url, !inFlight.contains(k), mountedShares()[k] == nil else { done?(); return }
    inFlight.insert(k)
    let open = NSMutableDictionary()
    open["UIOption"] = interactive ? "AllowUI" : "NoUI"   // kNAUIOptionKey; CFSTR macros don't import into Swift
    var req: AsyncRequestID?
    let rc = NetFSMountURLAsync(url as CFURL, nil, nil, nil, open, nil, &req, .main) { status, _, _ in
        inFlight.remove(k)
        if status == 0 || status == EEXIST { log.notice("mounted \(s.title, privacy: .public)") }
        else { log.error("mount \(s.title, privacy: .public) failed: \(status)") }
        done?()
    }
    if rc != 0 { inFlight.remove(k); log.error("mount \(s.title, privacy: .public) not started: \(rc)"); done?() }
}

func mountAll(reason: String) {
    log.notice("remount check: \(reason, privacy: .public)")
    for s in Prefs.shares where s.auto { mount(s, interactive: false) }
}

// MARK: - Discovery

final class Discovery {
    private(set) var hosts: [String] = []
    var onAppear: ((String) -> Void)?
    private let browser = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: nil), using: .tcp)
    private let me = Host.current().localizedName ?? ""

    func start() {
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let names = results.compactMap { r -> String? in
                if case let .service(name, _, _, _) = r.endpoint { return name }
                return nil
            }
            let now = Array(Set(names)).filter { $0 != self.me }.sorted()
            let added = now.filter { !self.hosts.contains($0) }
            self.hosts = now
            added.forEach { self.onAppear?($0) }
        }
        browser.stateUpdateHandler = { log.notice("browser: \(String(describing: $0), privacy: .public)") }
        browser.start(queue: .main)
    }
}

// MARK: - Menu bar

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    let discovery = Discovery()
    let path = NWPathMonitor()
    var lastPath: NWPath.Status?

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let img = NSImage(systemSymbolName: "externaldrive.connected.to.line.below", accessibilityDescription: "ShareKeeper")
        img?.isTemplate = true
        item.button?.image = img
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        discovery.onAppear = { host in
            if Prefs.shares.contains(where: { $0.host == host && $0.auto }) { mountAll(reason: "\(host) appeared") }
        }
        discovery.start()

        // Network up again (other wifi, cable, VPN off): try the shares. The first update is the current state.
        path.pathUpdateHandler = { [weak self] p in
            defer { self?.lastPath = p.status }
            if p.status == .satisfied && self?.lastPath != nil { self?.retrySoon(reason: "network changed") }
        }
        path.start(queue: .main)

        // After sleep the network often needs a few seconds; retry a couple of times.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.retrySoon(reason: "wake")
        }

        mountAll(reason: "launch")
    }

    func retrySoon(reason: String) {
        for delay in [3.0, 15.0, 45.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { mountAll(reason: reason) }
        }
    }

    // Rebuild the menu on every open so state is correct.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let mounted = mountedShares()
        let shares = Prefs.shares
        if shares.isEmpty {
            let hint = NSMenuItem(title: "No shares yet", action: nil, keyEquivalent: ""); hint.isEnabled = false; menu.addItem(hint)
        }
        for (i, s) in shares.enumerated() {
            let on = mounted[key(s)] != nil
            let row = NSMenuItem(title: s.title, action: nil, keyEquivalent: "")
            row.state = on ? .on : .off
            if !s.auto && !on { row.title += " (paused)" }
            let sub = NSMenu()
            if on {
                addItem(sub, "Open in Finder", #selector(openShare(_:)), tag: i)
                addItem(sub, "Unmount", #selector(unmountShare(_:)), tag: i)
            } else {
                addItem(sub, "Mount", #selector(mountShare(_:)), tag: i)
            }
            sub.addItem(.separator())
            addItem(sub, "Remove", #selector(removeShare(_:)), tag: i)
            row.submenu = sub
            menu.addItem(row)
        }
        menu.addItem(.separator())

        let add = NSMenuItem(title: "Add Share", action: nil, keyEquivalent: "")
        let addMenu = NSMenu()
        if discovery.hosts.isEmpty {
            let hint = NSMenuItem(title: "No Macs with File Sharing found", action: nil, keyEquivalent: ""); hint.isEnabled = false; addMenu.addItem(hint)
        }
        for h in discovery.hosts {
            let i = NSMenuItem(title: h, action: #selector(addShare(_:)), keyEquivalent: "")
            i.representedObject = h; i.target = self; addMenu.addItem(i)
        }
        add.submenu = addMenu
        menu.addItem(add)
        let all = NSMenuItem(title: "Mount All Now", action: #selector(mountAllNow), keyEquivalent: "")
        all.target = self; all.isEnabled = !shares.isEmpty; menu.addItem(all)
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch on login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self; login.state = SMAppService.mainApp.status == .enabled ? .on : .off; menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ShareKeeper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    func addItem(_ menu: NSMenu, _ title: String, _ sel: Selector, tag: Int) {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self; i.tag = tag; menu.addItem(i)
    }

    func share(_ s: NSMenuItem) -> Share? { Prefs.shares.indices.contains(s.tag) ? Prefs.shares[s.tag] : nil }

    func setAuto(_ tag: Int, _ on: Bool) {
        var all = Prefs.shares
        guard all.indices.contains(tag) else { return }
        all[tag].auto = on
        Prefs.shares = all
    }

    @objc func addShare(_ s: NSMenuItem) {
        guard let host = s.representedObject as? String else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Add a share from \(host)"
        alert.informativeText = "Name of the shared folder, as listed under File Sharing on \(host)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Shared folder"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add and Mount")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else { return }
        let new = Share(host: host, name: name)
        guard !Prefs.shares.contains(where: { key($0) == key(new) }) else { return }
        Prefs.shares.append(new)
        mount(new, interactive: true)
    }

    @objc func mountShare(_ s: NSMenuItem) {
        guard let sh = share(s) else { return }
        setAuto(s.tag, true)
        mount(sh, interactive: true)
    }

    @objc func unmountShare(_ s: NSMenuItem) {
        guard let sh = share(s), let url = mountedShares()[key(sh)] else { return }
        setAuto(s.tag, false)
        do { try NSWorkspace.shared.unmountAndEjectDevice(at: url) }
        catch { log.error("unmount \(sh.title, privacy: .public) failed: \(error.localizedDescription, privacy: .public)") }
    }

    @objc func openShare(_ s: NSMenuItem) {
        guard let sh = share(s), let url = mountedShares()[key(sh)] else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func removeShare(_ s: NSMenuItem) {
        var all = Prefs.shares
        guard all.indices.contains(s.tag) else { return }
        all.remove(at: s.tag)
        Prefs.shares = all
    }

    @objc func mountAllNow() {
        for (i, s) in Prefs.shares.enumerated() { setAuto(i, true); mount(s, interactive: true) }
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
app.setActivationPolicy(.accessory)
app.run()
