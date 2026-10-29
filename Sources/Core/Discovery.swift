import Foundation
import Network

/// Other ShareKeeper Macs on the network, from Bonjour. Delivers on the main queue.
final class Discovery {
    struct Peer {
        let id: String        // hex of the 8 byte peer id
        let name: String
        let endpoint: NWEndpoint
    }

    private(set) var peers: [String: Peer] = [:]
    var onChange: (() -> Void)?
    private var browser: NWBrowser?

    func start() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_sharekeeper._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            var found: [String: Peer] = [:]
            for r in results {
                guard case let .service(name, _, _, _) = r.endpoint,
                      case let .bonjour(txt) = r.metadata, let id = txt["id"] else { continue }
                found[id] = Peer(id: id, name: name, endpoint: r.endpoint)
            }
            DispatchQueue.main.async {
                self?.peers = found
                self?.onChange?()
            }
        }
        b.stateUpdateHandler = { log.notice("bonjour browser: \(String(describing: $0), privacy: .public)") }
        b.start(queue: DispatchQueue(label: "sk.browser"))
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
