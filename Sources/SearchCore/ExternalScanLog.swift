import CryptoKit
import Darwin
import DarwinMetadata
import Foundation

/// Completed directory listings addressed relative to a single known volume.
/// Only the valid prefix is reusable after termination during a write.
final class ExternalScanLog {
    private static let magic = Data("M2WALK01".utf8)
    private static let maximumBytes = 256 * 1024 * 1024
    private static let maximumFrame = 16 * 1024 * 1024
    private static let flushBytes = 1024 * 1024
    private static let flushDelay: UInt64 = 20_000_000_000
    private let file: FileHandle
    private let bytes: Data
    private let offsets: [String: Range<Int>]
    private var length: Int
    private var pending = Data()
    private var lastFlush = DispatchTime.now().uptimeNanoseconds
    private(set) var written = 0

    init(path: String) throws {
        let fd = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SnapshotError.filesystem(errno) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw SnapshotError.filesystem(errno) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size <= Self.maximumBytes else {
            throw SnapshotError.invalid
        }
        let bytes = try handle.readToEnd() ?? Data()
        var offsets: [String: Range<Int>] = [:]
        var valid = 0
        if bytes.starts(with: Self.magic) {
            valid = Self.magic.count
            while valid < bytes.count {
                var frame = JournalReader(bytes: bytes, cursor: valid)
                guard let count = frame.read(UInt32.self), count <= Self.maximumFrame,
                      let digest = frame.take(32), let payload = frame.take(Int(count)),
                      digest.elementsEqual(SHA256.hash(data: payload)) else { break }
                var directory = JournalReader(bytes: payload, cursor: payload.startIndex)
                guard let path = Self.readRelativePath(&directory), let stamp = directory.take(40),
                      !stamp.isEmpty else { break }
                offsets[path] = directory.cursor - 40 ..< frame.cursor
                valid = frame.cursor
            }
        }
        if valid != bytes.count { try handle.truncate(atOffset: UInt64(valid)) }
        try handle.seek(toOffset: UInt64(valid))
        file = handle
        self.bytes = bytes
        self.offsets = offsets
        length = valid
        if valid == 0 { pending = Self.magic }
    }

    private static func readRelativePath(_ reader: inout JournalReader) -> String? {
        guard let count = reader.read(UInt32.self), let raw = reader.take(Int(count)),
              !raw.contains(0), let path = String(data: raw, encoding: .utf8), !path.hasPrefix("/"),
              path.isEmpty || path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }) else { return nil }
        return path
    }

    func contains(_ relative: String) -> Bool { offsets[relative] != nil }

    /// Lookup data is immutable throughout a scan. A read slot is held only
    /// for the directory open and fstat, not while decoding saved entries.
    func restored(_ path: String, relative: String, device: Int32,
                  cancelled: () -> Bool = { false }) throws -> DirectoryBatch? {
        guard let range = offsets[relative] else { return nil }
        var reader = JournalReader(bytes: bytes[range], cursor: range.lowerBound)
        guard let inode = reader.read(UInt64.self), let modified = reader.read(Int64.self),
              let changed = reader.read(Int64.self), let created = reader.read(Int64.self),
              let size = reader.read(Int64.self) else { return nil }
        var stamp = DMDirectoryStamp()
        let error = try readDirectory {
            if cancelled() { throw CancellationError() }
            return dm_directory_stamp(path, device, &stamp)
        }
        switch error {
        case 0: break
        case EACCES, EPERM, ENOENT, ENOTDIR, ELOOP, ESTALE: return nil
        default: throw ScanError.metadata(path: path, error: error)
        }
        guard stamp.inode == inode, stamp.modified == modified, stamp.changed == changed,
              stamp.created == created, stamp.size == size,
              let count = reader.count(minWidth: 28) else { return nil }
        let batch = DirectoryBatch()
        batch.items.reserveCapacity(count)
        for _ in 0..<count {
            guard let length = reader.read(UInt32.self), length > 0,
                  let size = reader.read(Int64.self), let modified = reader.read(Int64.self),
                  let flags = reader.read(UInt32.self), let type = reader.read(UInt32.self),
                  let name = reader.take(Int(length)), !name.contains(0), !name.contains(47),
                  !name.elementsEqual([46]), !name.elementsEqual([46, 46]) else { return nil }
            batch.items.append(Item(start: batch.names.count, length: Int(length), size: size,
                                    modified: modified, flags: flags, type: type))
            batch.names.append(contentsOf: name)
        }
        return reader.cursor == range.upperBound ? batch : nil
    }

    // The scan coordinator serializes append and flush. Each entry's metadata
    // is written once for its newly observed directory; no full-index rewrite.
    func append(_ batch: DirectoryBatch, relative: String, stamp: DMDirectoryStamp) throws {
        let payloadSize = 48 + relative.utf8.count + batch.items.count * 28 + batch.names.count
        guard payloadSize <= Self.maximumFrame,
              length + pending.count + payloadSize + 36 <= Self.maximumBytes else { return }
        var payload = Data(capacity: payloadSize)
        payload.put(relative)
        payload.put(stamp.inode)
        payload.put(stamp.modified)
        payload.put(stamp.changed)
        payload.put(stamp.created)
        payload.put(stamp.size)
        payload.put(UInt32(batch.items.count))
        for item in batch.items {
            payload.put(UInt32(item.length))
            payload.put(item.size)
            payload.put(item.modified)
            payload.put(item.flags)
            payload.put(item.type)
            payload.append(contentsOf: batch.names[item.start..<(item.start + item.length)])
        }
        pending.put(UInt32(payload.count))
        pending.append(contentsOf: SHA256.hash(data: payload))
        pending.append(payload)
        if pending.count >= Self.flushBytes || DispatchTime.now().uptimeNanoseconds - lastFlush >= Self.flushDelay {
            try flush()
        }
    }

    func flush() throws {
        guard !pending.isEmpty else { return }
        try file.write(contentsOf: pending)
        try file.synchronize()
        length += pending.count
        written += pending.count
        pending.removeAll(keepingCapacity: true)
        lastFlush = DispatchTime.now().uptimeNanoseconds
    }
}
