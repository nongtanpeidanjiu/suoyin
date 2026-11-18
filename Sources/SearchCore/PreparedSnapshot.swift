import CryptoKit
import Darwin
import DarwinMetadata
import Foundation

struct TrackedEntry: Codable, Equatable {
    let size: Int64
    let modified: Int64
    let attribute: UInt8

    var directory: Bool { attribute & Kind.mask == Kind.directory }
}

struct TrackingState: Codable {
    let root: String
    var changes: [String: TrackedEntry]
    var restricted: Set<String>
}

private struct SnapshotMetadata: Codable {
    let volumes: [VolumeCheckpoint]
    let tracking: TrackingState?
}

extension SearchIndex {
    private static let hotMagic = Array("M2INDEX2".utf8)

    /// Persist search-ready tables and committed tracking state in one atomic file.
    public func savePrepared(to path: String, beforeReplace: (() throws -> Void)? = nil) throws {
        guard let tables = prepared else {
            if records.isEmpty {
                var empty = self
                empty.prepared = PreparedSearch(keyOffsets: [])
                try empty.savePrepared(to: path, beforeReplace: beforeReplace)
                return
            }
            throw SnapshotError.invalid
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let metadata = try encoder.encode(SnapshotMetadata(volumes: volumes, tracking: tracking))
        let fields = [records.count, names.count, tables.keyBytes.count, tables.changedRows.count, metadata.count]
        guard fields.allSatisfy({ $0 <= Int(UInt32.max) }) else { throw SnapshotError.invalid }
        var header = Data(Self.hotMagic)
        for value in fields + [1] {
            var little = UInt32(value).littleEndian
            withUnsafeBytes(of: &little) { header.append(contentsOf: $0) }
        }

        let temporary = path + ".temporary." + UUID().uuidString
        let fd = Darwin.open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SnapshotError.filesystem(errno) }
        var open = true
        var committed = false
        defer {
            if open { _ = Darwin.close(fd) }
            if !committed { _ = Darwin.unlink(temporary) }
        }

        func write(_ section: UnsafeRawBufferPointer) throws {
            var cursor = 0
            while cursor < section.count {
                let n = Darwin.write(fd, section.baseAddress!.advanced(by: cursor), section.count - cursor)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw SnapshotError.filesystem(n == 0 ? EIO : errno) }
                cursor += n
            }
        }

        var hash = SHA256()
        hash.update(data: header)
        func put<T>(_ array: [T]) throws {
            try array.withUnsafeBytes { bytes in
                hash.update(bufferPointer: bytes)
                try write(bytes)
            }
        }
        try header.withUnsafeBytes { try write($0) }
        try [UInt8](repeating: 0, count: 32).withUnsafeBytes { try write($0) }
        try put(records)
        try put(attributes)
        try put(names)
        try put(tables.keyOffsets)
        try put(tables.changedRows)
        try put(tables.keyBytes)
        try put(tables.nameOrder)
        try put(tables.pathOrder)
        try put(tables.sizeOrder)
        try put(tables.modifiedOrder)
        try metadata.withUnsafeBytes { bytes in
            hash.update(bufferPointer: bytes)
            try write(bytes)
        }
        guard lseek(fd, 32, SEEK_SET) == 32 else { throw SnapshotError.filesystem(errno) }
        try Array(hash.finalize()).withUnsafeBytes { try write($0) }
        guard fsync(fd) == 0 else { throw SnapshotError.filesystem(errno) }
        let closed = Darwin.close(fd)
        open = false
        guard closed == 0 else { throw SnapshotError.filesystem(errno) }
        try beforeReplace?()
        guard rename(temporary, path) == 0 else { throw SnapshotError.filesystem(errno) }
        committed = true
    }

    // Read into final arrays directly. Avoid a second full resident mmap on warm startup.
    static func loadPrepared(from path: String) throws -> SearchIndex? {
        let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw SnapshotError.filesystem(errno) }
        defer { _ = Darwin.close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw SnapshotError.filesystem(errno) }
        guard st.st_size >= 8 else { return nil }

        func read(_ bytes: UnsafeMutableRawBufferPointer) throws {
            var cursor = 0
            while cursor < bytes.count {
                let n = Darwin.read(fd, bytes.baseAddress!.advanced(by: cursor), bytes.count - cursor)
                if n < 0 && errno == EINTR { continue }
                if n < 0 { throw SnapshotError.filesystem(errno) }
                guard n > 0 else { throw SnapshotError.invalid }
                cursor += n
            }
        }
        var magic = [UInt8](repeating: 0, count: 8)
        try magic.withUnsafeMutableBytes { try read($0) }
        guard magic == hotMagic else { return nil }
        var header = magic + [UInt8](repeating: 0, count: 56)
        try header.withUnsafeMutableBytes { try read(UnsafeMutableRawBufferPointer(rebasing: $0[8...])) }
        let fields: [Int] = header.withUnsafeBytes { bytes in
            (0..<6).map { Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 8 + 4 * $0, as: UInt32.self))) }
        }
        let n = fields[0], nameCount = fields[1], foldedCount = fields[2], changedCount = fields[3], metaCount = fields[4]
        guard fields[5] == 1 else { throw SnapshotError.unsupportedVersion }
        guard n <= 20_000_000, changedCount <= n, nameCount <= 512_000_000,
              foldedCount <= 512_000_000, metaCount <= 64_000_000,
              st.st_size == Int64(64 + n * 45 + changedCount * 4 + nameCount + foldedCount + metaCount)
        else { throw SnapshotError.invalid }

        var hash = SHA256()
        hash.update(data: Data(header.prefix(32)))
        func load<T>(_ count: Int) throws -> [T] {
            try Array(unsafeUninitializedCapacity: count) { buffer, initialized in
                let bytes = UnsafeMutableRawBufferPointer(buffer)
                try read(bytes)
                hash.update(bufferPointer: UnsafeRawBufferPointer(bytes))
                initialized = count
            }
        }
        var index = SearchIndex()
        index.records = try load(n)
        index.attributes = try load(n)
        index.names = try load(nameCount)
        var tables = PreparedSearch(keyOffsets: try load(n))
        tables.changedRows = try load(changedCount)
        tables.keyBytes = try load(foldedCount)
        tables.nameOrder = try load(n)
        tables.pathOrder = try load(n)
        tables.sizeOrder = try load(n)
        tables.modifiedOrder = try load(n)
        let metadataBytes: [UInt8] = try load(metaCount)
        guard hash.finalize().elementsEqual(header.dropFirst(32)), index.structureIsValid(),
              tables.validForPersistence(rows: n) else { throw SnapshotError.invalid }
        let metadata: SnapshotMetadata
        do {
            metadata = try JSONDecoder().decode(SnapshotMetadata.self, from: Data(metadataBytes))
        } catch { throw SnapshotError.invalid }
        index.volumes = metadata.volumes
        index.tracking = metadata.tracking
        index.prepared = tables
        index.loadedPrepared = true
        return index
    }
}

extension SearchIndex {
    public func saveAsLoaded(to path: String) throws {
        if loadedPrepared { try savePrepared(to: path) }
        else { try save(to: path) }
    }
}

private extension PreparedSearch {
    func validForPersistence(rows: Int) -> Bool {
        for order in [nameOrder, pathOrder, sizeOrder, modifiedOrder] {
            var seen = [UInt8](repeating: 0, count: rows)
            for id in order {
                guard id < rows, seen[Int(id)] == 0 else { return false }
                seen[Int(id)] = 1
            }
        }
        var count = 0
        var former: UInt32?
        for row in changedRows {
            guard row < rows, former.map({ $0 < row }) ?? true,
                  keyOffsets[Int(row)] == count, count < keyBytes.count else { return false }
            former = row
            while count < keyBytes.count && keyBytes[count] != 0 { count += 1 }
            guard count < keyBytes.count else { return false }
            count += 1
        }
        return count == keyBytes.count && keyOffsets.lazy.filter { $0 != .max }.count == changedRows.count
    }
}
