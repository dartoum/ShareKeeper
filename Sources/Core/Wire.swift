import Foundation

// What goes over the encrypted channel between two Macs: a JSON header, then raw bytes for file data.

struct Attr: Codable, Equatable {
    var kind: UInt8          // 1 file, 2 directory
    var size: UInt64
    var mode: UInt32
    var atime: Double
    var mtime: Double
    var ctime: Double
    var ino: UInt64
    var nlink: UInt32
}

struct Entry: Codable {
    var name: String
    var attr: Attr
}

struct FsStat: Codable {
    var total: UInt64
    var free: UInt64
    var files: UInt64
    var ffree: UInt64
}

struct Request: Codable {
    var id: UInt32 = 0
    var op: String
    var path: String = ""
    var to: String = ""
    var off: UInt64 = 0
    var len: UInt32 = 0
    var mode: UInt32? = nil
    var size: UInt64? = nil
    var atime: Double? = nil
    var mtime: Double? = nil
    var flag: Bool = false
}

struct Response: Codable {
    var id: UInt32
    var err: Int32 = 0
    var attr: Attr? = nil
    var entries: [Entry]? = nil
    var stat: FsStat? = nil
    var n: UInt32 = 0
    var eof: Bool = false
    /// Answer to "ping": is the other Mac sharing a folder with us right now.
    var sharing: Bool? = nil
}

enum Frame {
    static func pack<T: Encodable>(_ header: T, body: Data = Data()) throws -> Data {
        let json = try JSONEncoder().encode(header)
        var out = be32(UInt32(json.count))
        out.append(json)
        out.append(body)
        return out
    }

    static func unpack<T: Decodable>(_ type: T.Type, _ d: Data) throws -> (T, Data) {
        let base = d.startIndex
        guard d.count >= 4 else { throw FSError(EPROTO) }
        let n = Int(readBE32(d[base..<base + 4]))
        guard d.count >= 4 + n else { throw FSError(EPROTO) }
        let header = try JSONDecoder().decode(T.self, from: d.subdata(in: base + 4..<base + 4 + n))
        return (header, d.subdata(in: base + 4 + n..<d.endIndex))
    }
}

/// What the NFS side needs from "a folder somewhere": the local folder on the sharing Mac (FileServer),
/// or the other Mac over the wire (RemoteClient). Paths are virtual, "/" is the root of the share.
protocol FileBackend: AnyObject {
    func getattr(_ path: String) async throws -> Attr
    func readdir(_ path: String) async throws -> [Entry]
    func read(_ path: String, offset: UInt64, count: UInt32) async throws -> (Data, Bool)
    func write(_ path: String, offset: UInt64, data: Data) async throws -> UInt32
    func create(_ path: String, mode: UInt32, exclusive: Bool) async throws -> Attr
    func mkdir(_ path: String, mode: UInt32) async throws -> Attr
    func remove(_ path: String) async throws
    func rmdir(_ path: String) async throws
    func rename(_ from: String, _ to: String) async throws
    func setattr(_ path: String, mode: UInt32?, size: UInt64?, atime: Double?, mtime: Double?) async throws -> Attr
    func statfs() async throws -> FsStat
}
