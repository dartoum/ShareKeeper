import Foundation

/// Why a volume cannot be mounted, in words that tell the user what to do.
enum MountError: LocalizedError {
    case unreachable(String, String?)
    case notSharing(String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let name, let why):
            return "Cannot reach \(name). Is ShareKeeper running on \(name), and are both Macs on the same network?"
                + (why.map { "\n\n(\($0))" } ?? "")
        case .notSharing(let name):
            return "\(name) is not sharing a folder yet. On \(name), open the ShareKeeper menu and choose “Share a Folder from This Mac”."
        }
    }
}

/// One paired Mac as a volume on this Mac: the link to it, the local NFS server in front of that link,
/// and the mount. The mount outlives a lost link (requests wait briefly, then fail with an I/O error),
/// so after sleep it simply starts working again when the link is back.
final class PeerVolume: @unchecked Sendable {
    let peerName: String
    let mountPath: String
    let client: RemoteClient
    private var nfs: NFSServer?

    init(peerName: String, mountPath: String, client: RemoteClient) {
        self.peerName = peerName
        self.mountPath = mountPath
        self.client = client
    }

    var isMounted: Bool { NFSMount.isMounted(mountPath) }

    func mount() async throws {
        if isMounted { return }
        guard await client.waitConnected(10) else { throw MountError.unreachable(peerName, client.lastConnectError) }
        guard client.peerSharing else { throw MountError.notSharing(peerName) }
        let server = try nfs ?? NFSServer(backend: CachingBackend(client))
        nfs = server
        let port = try await server.start()
        try await NFSMount.mount(port: port, at: mountPath)
        log.notice("mounted \(self.peerName, privacy: .public) at \(self.mountPath, privacy: .public)")
    }

    func unmount() async {
        await NFSMount.unmount(at: mountPath)
        nfs?.stop()
        nfs = nil
    }
}
