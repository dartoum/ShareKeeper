import Foundation
import os

let log = Logger(subsystem: "nl.david.ShareKeeper", category: "core")

/// An errno on its way over the wire or into an NFS status.
struct FSError: Error, CustomStringConvertible {
    let code: Int32
    init(_ code: Int32) { self.code = code }
    var description: String { "errno \(code): " + String(cString: strerror(code)) }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var d = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            d.append(b)
            i = j
        }
        self = d
    }
}

func be32(_ v: UInt32) -> Data {
    Data([UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)])
}

/// Exactly four bytes, big endian.
func readBE32(_ d: Data) -> UInt32 { d.reduce(0) { ($0 << 8) | UInt32($1) } }

// Paths in the share are virtual: "/" is the shared folder, always with "/" as separator.
func joinPath(_ dir: String, _ name: String) -> String { dir == "/" ? "/" + name : dir + "/" + name }

func parentPath(_ p: String) -> String {
    guard let i = p.lastIndex(of: "/"), i != p.startIndex else { return "/" }
    return String(p[..<i])
}

/// Runs `op`, and calls `onTimeout` (which must make `op` fail, e.g. by closing its socket) when it takes too long.
func withTimeout<T: Sendable>(_ seconds: Double,
                              onTimeout: @escaping @Sendable () -> Void = {},
                              _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            onTimeout()
            throw FSError(ETIMEDOUT)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

func realPath(_ p: String) -> String? {
    guard let c = realpath(p, nil) else { return nil }
    defer { free(c) }
    return String(cString: c)
}
