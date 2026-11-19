import CryptoKit
import Darwin
import DarwinMetadata
import Foundation

public enum SnapshotError: Error, Equatable {
    case invalid, unsupportedVersion, limitExceeded, filesystem(Int32)
}

extension SearchIndex {
    static let snapshotMagic = Array("M1INDEX1".utf8)
    static let headerSize = 64
    static let maximumSnapshotRecords = 20_000_000
    static let maximumSnapshotNameBytes = 512_000_000
    static let maximumLegacyMetadataBytes = 1_000_000
    static let maximumPreparedMetadataBytes = 64_000_000

    static func checkSnapshotCapacity(records: Int, names: Int, metadata: Int, metadataLimit: Int) throws {
        guard records <= maximumSnapshotRecords, names <= maximumSnapshotNameBytes, metadata <= metadataLimit else {
            throw SnapshotError.limitExceeded
        }
    }

    /// The records and volume checkpoint table belong to the same immutable value.
    public func save(to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let checkpointData = try encoder.encode(volumes)
        try Self.checkSnapshotCapacity(records: recordCount, names: names.count,
                                       metadata: checkpointData.count, metadataLimit: Self.maximumLegacyMetadataBytes)
        var header = Data(Self.snapshotMagic)
        func field<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { header.append(contentsOf: $0) }
        }
        field(UInt32(1))
        field(UInt32(records.count))
        field(UInt64(names.count))
        field(UInt64(checkpointData.count))

        let temporary = path + ".temporary." + UUID().uuidString
        let fd = Darwin.open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SnapshotError.filesystem(errno) }
        var open = true
        var published = false
        defer {
            if open { _ = Darwin.close(fd) }
            if !published { _ = Darwin.unlink(temporary) }
        }
        func write(_ bytes: UnsafeRawBufferPointer) throws {
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count == -1 && errno == EINTR { continue }
                guard count > 0 else { throw SnapshotError.filesystem(count == 0 ? EIO : errno) }
                offset += count
            }
        }
        var hash = SHA256()
        hash.update(data: header)
        func body(_ bytes: UnsafeRawBufferPointer) throws {
            hash.update(bufferPointer: bytes)
            try write(bytes)
        }
        try header.withUnsafeBytes { try write($0) }
        let blank = [UInt8](repeating: 0, count: SHA256.byteCount)
        try blank.withUnsafeBytes { try write($0) }
        try records.withUnsafeBytes { try body($0) }
        try attributes.withUnsafeBytes { try body($0) }
        try names.withUnsafeBytes { try body($0) }
        try checkpointData.withUnsafeBytes { try body($0) }
        guard lseek(fd, off_t(header.count), SEEK_SET) >= 0 else { throw SnapshotError.filesystem(errno) }
        try Array(hash.finalize()).withUnsafeBytes { try write($0) }
        guard fsync(fd) == 0 else { throw SnapshotError.filesystem(errno) }
        let closeResult = Darwin.close(fd)
        open = false
        guard closeResult == 0 else { throw SnapshotError.filesystem(errno) }
        guard Darwin.rename(temporary, path) == 0 else { throw SnapshotError.filesystem(errno) }
        published = true
    }

    public static func load(from path: String) throws -> SearchIndex {
        if let hot = try loadPrepared(from: path) { return hot }
        let input = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        guard input.count >= headerSize, input.prefix(8).elementsEqual(snapshotMagic) else {
            throw SnapshotError.invalid
        }
        return try input.withUnsafeBytes { bytes -> SearchIndex in
            func read<T: FixedWidthInteger>(_ offset: Int, _: T.Type) -> T {
                T(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: T.self))
            }
            guard read(8, UInt32.self) == 1 else { throw SnapshotError.unsupportedVersion }
            let count = Int(read(12, UInt32.self))
            let poolCount = read(16, UInt64.self)
            let volumeCount = read(24, UInt64.self)
            guard count <= maximumSnapshotRecords, poolCount <= maximumSnapshotNameBytes,
                  volumeCount <= maximumLegacyMetadataBytes else {
                throw SnapshotError.invalid
            }
            let flagStart = headerSize + count * MemoryLayout<DMRecord>.stride
            let poolStart = flagStart + count
            let volumeStart = poolStart + Int(poolCount)
            guard volumeStart + Int(volumeCount) == bytes.count else { throw SnapshotError.invalid }
            var hash = SHA256()
            hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes[..<32]))
            hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes[headerSize...]))
            guard hash.finalize().elementsEqual(bytes[32..<headerSize]) else { throw SnapshotError.invalid }
            var result = SearchIndex()
            result.records = Array(unsafeUninitializedCapacity: count) { destination, initialized in
                if count > 0 {
                    memcpy(destination.baseAddress!, bytes.baseAddress!.advanced(by: headerSize),
                           flagStart - headerSize)
                }
                initialized = count
            }
            result.attributes = Array(bytes[flagStart..<poolStart])
            result.names = Array(bytes[poolStart..<volumeStart])
            result.volumes = try JSONDecoder().decode([VolumeCheckpoint].self, from: Data(bytes[volumeStart...]))
            guard result.structureIsValid() else { throw SnapshotError.invalid }
            return result
        }
    }

    func structureIsValid() -> Bool {
        if records.isEmpty { return names.isEmpty }
        return names.withUnsafeBufferPointer { pool in
            var expected = 0
            for (i, record) in records.enumerated() {
                let next = i + 1 == records.count ? pool.count : Int(records[i + 1].offset)
                if Int(record.offset) != expected || next <= expected || next > pool.count ||
                    pool[next - 1] != 0 || memchr(pool.baseAddress!.advanced(by: expected), 0, next - expected - 1) != nil {
                    return false
                }
                if record.parent != .max {
                    let parent = Int(record.parent)
                    if parent >= i || attributes[parent] & Kind.mask == Kind.file ||
                        attributes[parent] & Kind.mask == Kind.other { return false }
                }
                expected = next
            }
            return expected == pool.count
        }
    }

    /// Corrupt, unsupported or missing snapshots take the same controlled rebuild route.
    public static func loadOrRebuild(from path: String, rebuild: () throws -> SearchIndex) throws -> SearchIndex {
        do {
            return try load(from: path)
        } catch SnapshotError.invalid {
        } catch SnapshotError.unsupportedVersion {
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        }
        let index = try rebuild()
        try index.save(to: path)
        return index
    }

    /// Adapter for the project benchmark corpus, whose old format is not a product snapshot.
    public static func importResearchCorpus(from path: String) throws -> SearchIndex {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        return try data.withUnsafeBytes { raw in
            guard raw.count >= 16 else { throw SnapshotError.invalid }
            let number = raw.loadUnaligned(as: UInt64.self)
            let poolSize = raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
            guard number <= 20_000_000, poolSize <= 512_000_000,
                  UInt64(raw.count) == 16 + number * 32 + poolSize else { throw SnapshotError.invalid }
            let poolStart = 16 + Int(number) * 32
            let pool = raw.bindMemory(to: UInt8.self)
            var index = SearchIndex()
            index.reserve(Int(number), nameBytes: Int(poolSize))
            for i in 0..<Int(number) {
                let pos = 16 + i * 32
                let offset = Int(raw.loadUnaligned(fromByteOffset: pos, as: UInt32.self))
                let parent = raw.loadUnaligned(fromByteOffset: pos + 4, as: UInt32.self)
                let size = raw.loadUnaligned(fromByteOffset: pos + 8, as: Int64.self)
                let seconds = raw.loadUnaligned(fromByteOffset: pos + 16, as: Int64.self)
                let flags = raw.loadUnaligned(fromByteOffset: pos + 24, as: UInt32.self)
                let type = raw.loadUnaligned(fromByteOffset: pos + 28, as: UInt32.self)
                guard offset < Int(poolSize), parent == .max || Int(parent) < i,
                      let end = memchr(pool.baseAddress!.advanced(by: poolStart + offset), 0, Int(poolSize) - offset)
                else { throw SnapshotError.invalid }
                let length = UnsafeRawPointer(pool.baseAddress!.advanced(by: poolStart + offset)).distance(to: end)
                let name = UnsafeBufferPointer(start: pool.baseAddress!.advanced(by: poolStart + offset), count: length)
                var attr = type == 0 ? Kind.anchor : type == 2 ? Kind.directory : type == 1 ? Kind.file : Kind.other
                if parent != .max { attr |= index.attributes[Int(parent)] & (Kind.hidden | Kind.excluded) }
                if name.first == 46 || flags & 0x8000 != 0 { attr |= Kind.hidden }
                if flags & Kind.datalessFlag != 0 { attr |= Kind.placeholderBits(for: attr) }
                let (time, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
                index.append(bytes: name, parent: parent, size: size,
                             modified: overflow ? (seconds < 0 ? .min : .max) : time, attribute: attr)
            }
            guard index.structureIsValid() else { throw SnapshotError.invalid }
            return index
        }
    }

    public static func millionHitCorpus(count: Int) -> SearchIndex {
        var index = SearchIndex()
        index.reserve(count + 1, nameBytes: count * 15)
        let root = index.append("/fixture", attribute: Kind.anchor)
        for i in 0..<count {
            index.append("a\(count - i).txt", parent: root,
                         size: Int64(i % 97), modified: Int64(i % 193))
        }
        return index
    }
}
