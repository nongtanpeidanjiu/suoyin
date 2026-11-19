import CryptoKit
import Darwin
import Foundation

/// Mutations address base rows by ID and overlay rows by logical path.
/// Row IDs are valid only for the snapshot digest stored in the journal header.
struct JournalFrame {
    struct RowEdit {
        let path: String
        let value: TrackedEntry?
    }

    let rows: [RowEdit]
    let masks: [(UInt32, Bool)]
    let coverage: [(String, Bool)]
    let positions: [String: UInt64]

    func apply(to index: inout SearchIndex, root: String) {
        if index.tracking == nil {
            index.tracking = TrackingState(root: root, changes: [:], restricted: [])
        }
        for row in rows { index.tracking!.changes[row.path] = row.value }
        for (path, restricted) in coverage {
            if restricted { index.tracking!.recordDenial(path, error: nil) }
            else { index.tracking!.clearDenial(path) }
        }
        for (id, hidden) in masks {
            let offset = Int(id)
            if hidden { index.attributes[offset] |= Kind.suppressed }
            else { index.attributes[offset] &= ~Kind.suppressed }
        }
        index.volumes = index.volumes.map { volume in
            VolumeCheckpoint(root: volume.root, volumeUUID: volume.volumeUUID,
                             eventLogUUID: volume.eventLogUUID, mountedDevice: volume.mountedDevice,
                             readOnly: volume.readOnly, appliedEvent: positions[volume.root])
        }
    }
}

struct JournalImage {
    let rows: [String: TrackedEntry]
    let masks: [UInt8]
    let coverage: Set<String>
    let positions: [String: UInt64]

    func delta(after old: JournalImage) -> JournalFrame? {
        var edits: [JournalFrame.RowEdit] = []
        for (path, row) in rows where old.rows[path] != row {
            edits.append(.init(path: path, value: row))
        }
        for path in old.rows.keys where rows[path] == nil {
            edits.append(.init(path: path, value: nil))
        }
        var bits: [(UInt32, Bool)] = []
        if masks != old.masks {
            for byte in 0..<max(masks.count, old.masks.count) {
                let current = byte < masks.count ? masks[byte] : 0
                let previous = byte < old.masks.count ? old.masks[byte] : 0
                var changed = current ^ previous
                while changed != 0 {
                    let bit = changed.trailingZeroBitCount
                    bits.append((UInt32(byte * 8 + bit), current & (1 << bit) != 0))
                    changed &= changed - 1
                }
            }
        }
        let scopes = coverage.symmetricDifference(old.coverage)
        guard !edits.isEmpty || !bits.isEmpty || !scopes.isEmpty || positions != old.positions else {
            return nil
        }
        return JournalFrame(rows: edits.sorted { $0.path < $1.path }, masks: bits,
                            coverage: scopes.sorted().map { ($0, coverage.contains($0)) },
                            positions: positions)
    }
}

/// Version 1. Header: eight-byte magic, little-endian UInt32 version,
/// 32-byte base digest. Frame: little-endian UInt32 length, 32-byte SHA-256
/// over the length and payload, then the payload. Integers have fixed widths.
struct ChangeJournal {
    private static let magic = Data("M2DELTA1".utf8)
    private static let version: UInt32 = 1
    private static let maxFrame = 32 * 1024 * 1024
    private static let maxFile = 128 * 1024 * 1024
    static let headerBytes = 44

    let path: String
    let identity: Data
    private(set) var length = 0
    private(set) var repair = "missing"
    private(set) var restoredFrames = 0

    private var header: Data {
        var result = Self.magic
        result.put(Self.version)
        result.append(identity)
        return result
    }

    init(snapshot: String, identity: Data) {
        path = snapshot + ".changes"
        self.identity = identity
    }

    mutating func restore(into index: inout SearchIndex, root: String, repairSuffix: Bool = true) throws {
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return }
        guard fd >= 0 else { throw SnapshotError.filesystem(errno) }
        defer { _ = Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw SnapshotError.filesystem(errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw SnapshotError.invalid }
        // Bound allocations even when an externally damaged journal advertises a huge size.
        guard info.st_size <= Self.maxFile else { repair = "invalid-size"; return }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let bytes = try file.readToEnd() ?? Data()
        guard bytes.starts(with: header) else { repair = "identity-or-version"; return }
        length = Self.headerBytes
        repair = "valid"
        let volumeRoots = Set(index.volumes.map(\.root))
        while length < bytes.count {
            var reader = JournalReader(bytes: bytes, cursor: length)
            guard let size = reader.read(UInt32.self), size <= Self.maxFrame,
                  let digest = reader.take(32), let payload = reader.take(Int(size)),
                  digest == Self.digest(size, payload),
                  let frame = Self.decode(payload, rows: index.recordCount, root: root, volumes: volumeRoots)
            else {
                repair = "discarded-suffix"
                guard repairSuffix else { return }
                let writer = Darwin.open(path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
                guard writer >= 0 else { throw SnapshotError.filesystem(errno) }
                defer { _ = Darwin.close(writer) }
                guard ftruncate(writer, off_t(length)) == 0 else { throw SnapshotError.filesystem(errno) }
                return
            }
            frame.apply(to: &index, root: root)
            restoredFrames += 1
            length = reader.cursor
        }
    }

    /// Replay only the durable visibility mask and overlay metadata for the
    /// volume catalogue. The base row and name pools are unnecessary.
    func applyRetainedMetadata(attributes: inout Data, tracking: inout TrackingState?,
                               volumes: [VolumeCheckpoint]) throws {
        guard let root = tracking?.root ?? volumes.first?.root else { return }
        let file: FileHandle
        do { file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return }
        defer { try? file.close() }
        guard try file.seekToEnd() <= UInt64(Self.maxFile) else { return }
        try file.seek(toOffset: 0)
        guard try file.read(upToCount: Self.headerBytes) == header else { return }
        let roots = Set(volumes.map(\.root))
        while let fields = try file.read(upToCount: 36), fields.count == 36 {
            let size = fields.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
            guard size <= Self.maxFrame, let payload = try file.read(upToCount: Int(size)),
                  payload.count == Int(size), fields.dropFirst(4) == Self.digest(size, payload),
                  let frame = Self.decode(payload, rows: attributes.count, root: root, volumes: roots) else { break }
            for (id, hidden) in frame.masks {
                if hidden { attributes[Int(id)] |= Kind.suppressed }
                else { attributes[Int(id)] &= ~Kind.suppressed }
            }
            if tracking == nil { tracking = TrackingState(root: root, changes: [:], restricted: []) }
            for row in frame.rows { tracking?.changes[row.path] = row.value }
        }
    }

    /// A new identity replaces any old journal atomically. A crash between
    /// the two renames leaves a journal the new snapshot cannot accept.
    mutating func reset() throws -> Int {
        let temporary = path + ".new-" + UUID().uuidString
        let fd = Darwin.open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SnapshotError.filesystem(errno) }
        defer {
            _ = Darwin.close(fd)
            _ = Darwin.unlink(temporary)
        }
        try Self.write(header, to: fd)
        guard rename(temporary, path) == 0 else { throw SnapshotError.filesystem(errno) }
        length = Self.headerBytes
        return length
    }

    mutating func append(_ frame: JournalFrame, sync: Bool = true) throws -> Int {
        let payload = Self.encode(frame)
        guard payload.count <= Self.maxFrame else { throw SnapshotError.invalid }
        let size = UInt32(payload.count)
        var bytes = Data()
        bytes.put(size)
        bytes.append(Self.digest(size, payload))
        bytes.append(payload)
        let initialization = length == 0 ? try reset() : 0
        let fd = Darwin.open(path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SnapshotError.filesystem(errno) }
        defer { _ = Darwin.close(fd) }
        try Self.write(bytes, to: fd)
        if sync {
            while fsync(fd) != 0 {
                guard errno == EINTR else { throw SnapshotError.filesystem(errno) }
            }
        }
        length += bytes.count
        return initialization + bytes.count
    }

    private static func write(_ bytes: Data, to fd: Int32) throws {
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let sent = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if sent < 0 && errno == EINTR { continue }
                guard sent > 0 else { throw SnapshotError.filesystem(sent == 0 ? EIO : errno) }
                offset += sent
            }
        }
    }

    private static func digest(_ length: UInt32, _ payload: Data) -> Data {
        var prefix = Data()
        prefix.put(length)
        var hash = SHA256()
        hash.update(data: prefix)
        hash.update(data: payload)
        return Data(hash.finalize())
    }

    private static func encode(_ frame: JournalFrame) -> Data {
        var data = Data()
        data.put(UInt32(frame.rows.count))
        for row in frame.rows {
            data.put(row.path)
            data.put(UInt8(row.value == nil ? 0 : 1))
            if let entry = row.value {
                data.put(entry.attribute)
                data.put(entry.size)
                data.put(entry.modified)
            }
        }
        data.put(UInt32(frame.masks.count))
        for (id, value) in frame.masks { data.put(id); data.put(UInt8(value ? 1 : 0)) }
        data.put(UInt32(frame.coverage.count))
        for (path, value) in frame.coverage { data.put(path); data.put(UInt8(value ? 1 : 0)) }
        data.put(UInt32(frame.positions.count))
        for (root, id) in frame.positions.sorted(by: { $0.key < $1.key }) {
            data.put(root)
            data.put(id)
        }
        return data
    }

    private static func decode(_ payload: Data, rows: Int, root: String, volumes: Set<String>) -> JournalFrame? {
        var reader = JournalReader(bytes: payload, cursor: payload.startIndex)
        var edits: [JournalFrame.RowEdit] = []
        var masks: [(UInt32, Bool)] = []
        var coverage: [(String, Bool)] = []
        var positions: [String: UInt64] = [:]
        guard let editCount = reader.count(minWidth: 5) else { return nil }
        for _ in 0..<editCount {
            guard let path = reader.path(), inside(path, root), let present = reader.bool() else { return nil }
            if present {
                guard let attr = reader.read(UInt8.self), attr & Kind.mask != Kind.anchor,
                      let size = reader.read(Int64.self), let modified = reader.read(Int64.self)
                else { return nil }
                edits.append(.init(path: path, value: .init(size: size, modified: modified, attribute: attr)))
            } else { edits.append(.init(path: path, value: nil)) }
        }
        guard let maskCount = reader.count(minWidth: 5) else { return nil }
        for _ in 0..<maskCount {
            guard let id = reader.read(UInt32.self), id < rows, let value = reader.bool() else { return nil }
            masks.append((id, value))
        }
        guard let coverageCount = reader.count(minWidth: 5) else { return nil }
        for _ in 0..<coverageCount {
            guard let path = reader.path(), inside(path, root), let value = reader.bool() else { return nil }
            coverage.append((path, value))
        }
        guard let positionCount = reader.count(minWidth: 12) else { return nil }
        for _ in 0..<positionCount {
            guard let path = reader.path(), volumes.contains(path), let id = reader.read(UInt64.self),
                  id != 0, id != .max, positions.updateValue(id, forKey: path) == nil
            else { return nil }
        }
        guard reader.cursor == payload.endIndex else { return nil }
        return JournalFrame(rows: edits, masks: masks, coverage: coverage, positions: positions)
    }
}

extension Data {
    mutating func put<T: FixedWidthInteger>(_ integer: T) {
        var value = integer.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    mutating func put(_ value: String) {
        put(UInt32(value.utf8.count))
        append(contentsOf: value.utf8)
    }
}

struct JournalReader {
    let bytes: Data
    var cursor: Int

    mutating func take(_ length: Int) -> Data? {
        guard length <= bytes.endIndex - cursor else { return nil }
        defer { cursor += length }
        return bytes[cursor..<(cursor + length)]
    }

    mutating func read<T: FixedWidthInteger>(_ type: T.Type) -> T? {
        take(MemoryLayout<T>.size)?.withUnsafeBytes {
            T(littleEndian: $0.loadUnaligned(as: T.self))
        }
    }

    mutating func count(minWidth: Int) -> Int? {
        guard let count = read(UInt32.self), Int(count) <= (bytes.endIndex - cursor) / minWidth else { return nil }
        return Int(count)
    }

    mutating func bool() -> Bool? {
        guard let raw = read(UInt8.self), raw <= 1 else { return nil }
        return raw == 1
    }

    mutating func path() -> String? {
        guard let count = read(UInt32.self), count > 0, let data = take(Int(count)),
              data.first == 47, !data.contains(0)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
