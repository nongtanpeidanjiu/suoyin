import DarwinMetadata
import Foundation

public enum QueryMode: String, Codable, Sendable { case name, path }
public enum SearchColumn: String, Codable, CaseIterable, Sendable { case name, path, size, modified }
public enum SearchDirection: String, Codable, CaseIterable, Sendable { case ascending, descending }

public struct SearchRow: Codable, Equatable, Sendable {
    public let id: UInt32
    public let name: String
    public let path: String
    public let size: Int64
    public let modified: Int64
    public let volumeID: String?
    var attribute: UInt8 = 0
    var volumeSlot: UInt32 = 0

    private enum CodingKeys: String, CodingKey { case id, name, path, size, modified, volumeID }

    init(id: UInt32, name: String, path: String, size: Int64, modified: Int64, volumeID: String? = nil,
         attribute: UInt8 = 0) {
        self.id = id
        self.name = name
        self.path = path
        self.size = size
        self.modified = modified
        self.volumeID = volumeID
        self.attribute = attribute
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.path == rhs.path &&
            lhs.size == rhs.size && lhs.modified == rhs.modified && lhs.volumeID == rhs.volumeID
    }
}

enum Kind {
    static let anchor: UInt8 = 0
    static let file: UInt8 = 1
    static let directory: UInt8 = 2
    static let other: UInt8 = 3
    static let mask: UInt8 = 3
    static let hidden: UInt8 = 4
    static let pending: UInt8 = 8
    static let excluded: UInt8 = 16
    static let suppressed: UInt8 = 32
    // Directory listing state and SF_DATALESS can change independently.
    static let dataless: UInt8 = 64
    static let datalessFlag: UInt32 = 0x40000000

    static func placeholderBits(for attribute: UInt8) -> UInt8 {
        attribute & mask == directory ? pending | dataless : pending
    }
}

public struct VolumeCheckpoint: Codable, Sendable, Equatable {
    public let root: String
    public let volumeUUID: String?
    public let eventLogUUID: String?
    public let mountedDevice: Int32?
    public let readOnly: Bool?
    /// Last applied event recorded in this snapshot, when a safe position exists.
    public let appliedEvent: UInt64?
}

public struct SearchIndex {
    var records: [DMRecord] = []
    var attributes: [UInt8] = []
    var names: [UInt8] = []
    var prepared: PreparedSearch?
    var suppressed: [UInt8] = []
    var tracking: TrackingState?
    var loadedPrepared = false
    public internal(set) var volumes: [VolumeCheckpoint] = []

    public init() {}
    public var recordCount: Int { records.count }
    public var visibleEntryCount: Int { attributes.indices.count { visible(attributes[$0], true) && !isSuppressed($0) } }

    mutating func reserve(_ count: Int, nameBytes: Int) {
        records.reserveCapacity(count)
        attributes.reserveCapacity(count)
        names.reserveCapacity(nameBytes)
    }

    @discardableResult
    mutating func append(bytes: UnsafeBufferPointer<UInt8>, parent: UInt32,
                         size: Int64, modified: Int64, attribute: UInt8) -> UInt32 {
        let id = UInt32(records.count)
        records.append(DMRecord(offset: UInt32(names.count), parent: parent, size: size, modified: modified))
        attributes.append(attribute)
        names.append(contentsOf: bytes)
        names.append(0)
        return id
    }

    @discardableResult
    mutating func append(_ name: String, parent: UInt32 = .max, size: Int64 = 0,
                         modified: Int64 = 0, attribute: UInt8 = Kind.file) -> UInt32 {
        let bytes = Array(name.utf8)
        return bytes.withUnsafeBufferPointer {
            append(bytes: $0, parent: parent, size: size, modified: modified, attribute: attribute)
        }
    }

    func name(_ id: UInt32) -> String {
        let offset = Int(records[Int(id)].offset)
        return names.withUnsafeBufferPointer {
            String(cString: $0.baseAddress!.advanced(by: offset))
        }
    }

    func fullPath(_ id: UInt32) -> String {
        var components: [String] = []
        var cursor = id
        while cursor != .max {
            components.append(name(cursor))
            cursor = records[Int(cursor)].parent
        }
        let joined = components.reversed().joined(separator: "/")
        return joined.hasPrefix("//") ? String(joined.dropFirst()) : joined
    }

    func directoryPath(_ id: UInt32) -> String {
        let parent = records[Int(id)].parent
        return parent == .max ? "" : fullPath(parent)
    }

    func row(_ id: UInt32) -> SearchRow {
        let record = records[Int(id)]
        return SearchRow(id: id, name: name(id), path: fullPath(id), size: record.size, modified: record.modified,
                         attribute: attributes[Int(id)])
    }

    func visible(_ attribute: UInt8, _ showAll: Bool) -> Bool {
        attribute & Kind.mask != Kind.anchor && attribute & (Kind.excluded | Kind.suppressed) == 0 &&
            (showAll || attribute & Kind.hidden == 0)
    }

    func isSuppressed(_ index: Int) -> Bool {
        !suppressed.isEmpty && suppressed[index >> 3] & (1 << (index & 7)) != 0
    }

    mutating func setSuppressed(_ index: Int, _ value: Bool) {
        guard isSuppressed(index) != value else { return }
        if suppressed.isEmpty { suppressed = [UInt8](repeating: 0, count: (recordCount + 7) / 8) }
        if value { suppressed[index >> 3] |= 1 << (index & 7) }
        else { suppressed[index >> 3] &= ~(1 << (index & 7)) }
    }

    static func key(_ text: String) -> [UInt8] {
        text.precomposedStringWithCanonicalMapping.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }
    }

    static func queryWords(_ text: String) -> [[UInt8]] {
        text.split(separator: " ").map { key(String($0)) }
    }

    private func byteOrder(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
        if lhs == rhs { return 0 }
        return lhs.lexicographicallyPrecedes(rhs) ? -1 : 1
    }

    private func compare(_ lhs: UInt32, _ rhs: UInt32, _ column: SearchColumn) -> Int {
        let left = records[Int(lhs)], right = records[Int(rhs)]
        let comparison: Int
        switch column {
        case .name: comparison = 0
        case .path: comparison = byteOrder(Self.key(directoryPath(lhs)), Self.key(directoryPath(rhs)))
        case .size: comparison = left.size == right.size ? 0 : left.size < right.size ? -1 : 1
        case .modified: comparison = left.modified == right.modified ? 0 : left.modified < right.modified ? -1 : 1
        }
        if comparison != 0 { return comparison }
        let byKey = byteOrder(Self.key(name(lhs)), Self.key(name(rhs)))
        if byKey != 0 { return byKey }
        let byName = byteOrder(Array(name(lhs).utf8), Array(name(rhs).utf8))
        if byName != 0 { return byName }
        return lhs == rhs ? 0 : lhs < rhs ? -1 : 1
    }

    /// Bounded exact selection formats only the requested rows.
    public func directSearch(_ query: String, mode: QueryMode = .name,
                             column: SearchColumn = .name, direction: SearchDirection = .ascending,
                             showAll: Bool = false, kind: EngineKind = .any,
                             offset: Int = 0, limit: Int = 50) -> [SearchRow] {
        guard let capacity = pageCapacity(offset: offset, limit: limit) else { return [] }
        let words = Self.queryWords(query).map { Data($0) }
        let type = kind.code
        func before(_ a: UInt32, _ b: UInt32) -> Bool {
            let order = compare(a, b, column)
            return direction == .ascending ? order < 0 : order > 0
        }
        var first: [UInt32] = []
        first.reserveCapacity(min(capacity, records.count))
        for i in records.indices where visible(attributes[i], showAll) && !isSuppressed(i) {
            let id = UInt32(i)
            if kind == .folder {
                guard attributes[i] & Kind.mask == Kind.directory else { continue }
            } else if kind != .any {
                guard name(id).withCString({ dm_file_kind($0, attributes[i]) }) == type else { continue }
            }
            if !words.isEmpty {
                let text = mode == .name ? name(id) : fullPath(id)
                let bytes = Data(Self.key(text))
                guard words.allSatisfy({ bytes.range(of: $0) != nil }) else { continue }
            }
            if first.count == capacity, let last = first.last, !before(id, last) { continue }
            var lo = 0, hi = first.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if before(id, first[mid]) { hi = mid } else { lo = mid + 1 }
            }
            first.insert(id, at: lo)
            if first.count > capacity { first.removeLast() }
        }
        return first.dropFirst(offset).map { row($0) }
    }

    func pageCapacity(offset: Int, limit: Int) -> Int? {
        guard offset >= 0, limit > 0, offset < records.count else { return nil }
        return offset + min(limit, records.count - offset)
    }

    public static func residentBytes() -> UInt64 { dm_resident_bytes() }
}
