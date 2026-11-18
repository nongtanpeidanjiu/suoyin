import CoreServices
import Darwin
import DarwinMetadata
import Foundation

public enum ScanError: Error, CustomStringConvertible {
    case invalidWorkerCount
    case metadata(path: String, error: Int32)
    case listener(root: String)

    public var description: String {
        switch self {
        case .invalidWorkerCount: return "Expected 1 to 4 scan workers"
        case let .metadata(path, error): return "Metadata error \(error) at \(path)"
        case let .listener(root): return "Unable to start FSEvents at \(root)"
        }
    }
}

public struct ScanMark: Codable, Sendable {
    public let phase: String
    public let seconds: Double
    public let entries: Int
    public let listenerCount: Int
    public let readOnlyVolumes: Int
    public let denied: Int
    public let disappeared: Int
    public let skippedMounts: Int
    public let pending: Int
    public let fallback: Int
}

struct ScanJob {
    let path: String
    let parent: UInt32
}

private struct Item {
    let start: Int
    let length: Int
    let size: Int64
    let modified: Int64
    let flags: UInt32
    let type: UInt32
}

private final class DirectoryBatch {
    var names: [UInt8] = []
    var items: [Item] = []
}

private let collectEntry: DMEntryCallback = { context, name, length, size, modified, flags, type in
    let batch = Unmanaged<DirectoryBatch>.fromOpaque(context!).takeUnretainedValue()
    let start = batch.names.count
    batch.names.append(contentsOf: UnsafeBufferPointer(start: name, count: length))
    batch.items.append(Item(start: start, length: length, size: size,
                            modified: modified, flags: flags, type: type))
}

private final class ListenerSet {
    private let queue = DispatchQueue(label: "search.fs-events")
    private var streams: [FSEventStreamRef] = []
    var checkpoints: [VolumeCheckpoint] = []
    var count: Int { streams.count }
    var readOnlyCount = 0

    func add(root: String) throws {
        var mount = statfs()
        guard statfs(root, &mount) == 0 else { throw ScanError.metadata(path: root, error: errno) }
        let device = mount.f_fsid.val.0
        let url = URL(fileURLWithPath: root, isDirectory: true)
        let values = try url.resourceValues(forKeys: [.volumeUUIDStringKey])
        let uuid = FSEventsCopyUUIDForDevice(device)
        let readOnly = mount.f_flags & UInt32(MNT_RDONLY) != 0
        checkpoints.append(VolumeCheckpoint(root: root, volumeUUID: values.volumeUUIDString,
                                            eventLogUUID: uuid.map(CFUUIDCreateString).map { $0 as String },
                                            mountedDevice: device, readOnly: readOnly,
                                            appliedEvent: nil))
        // The sealed system volume is static. Writable roots must have an actual stream.
        if readOnly { readOnlyCount += 1; return }
        guard let stream = FSEventStreamCreateRelativeToDevice(
            nil, { _, _, _, _, _, _ in }, nil, device,
            [""] as CFArray, UInt64.max, 0.5, UInt32(kFSEventStreamCreateFlagWatchRoot)
        ) else { throw ScanError.listener(root: root) }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw ScanError.listener(root: root)
        }
        streams.append(stream)
    }

    deinit {
        for stream in streams {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

private let dataRoot = "/System/Volumes/Data"

private struct WalkScope {
    let primaryDevice: dev_t
    let dataDevice: dev_t
    let mirrors: Set<String>
    let cloudRoots: Set<String>
    let privateScratch: String
    let homeCaches: String
    let wholeDisk: Bool

    init(root: String) throws {
        wholeDisk = root == "/"
        primaryDevice = try Self.device(root)
        dataDevice = wholeDisk ? try Self.device(dataRoot) : primaryDevice
        if wholeDisk {
            let table = try String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8)
            mirrors = Set(table.split(separator: "\n").compactMap { line in
                let columns = line.split(separator: "\t")
                return columns.count == 2 ? dataRoot + "/" + columns[1] : nil
            })
        } else { mirrors = [] }
        let home = NSHomeDirectory()
        cloudRoots = wholeDisk ? [home + "/Library/CloudStorage", home + "/Library/Mobile Documents"] : []
        homeCaches = home + "/Library/Caches"
        privateScratch = FileManager.default.currentDirectoryPath + "/.m1-tmp"
    }

    static func device(_ path: String) throws -> dev_t {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw ScanError.metadata(path: path, error: errno) }
        return info.st_dev
    }

    func defaultHiddenDirectory(_ path: String) -> Bool {
        if cloudRoots.contains(path) { return false }
        if path == homeCaches { return true }
        switch path {
        case "/System", "/bin", "/sbin", "/usr", "/private/etc", "/private/var", "/private/tmp",
             "/Library/Apple", "/Library/Updates", "/Library/Developer/CommandLineTools", "/Library/Caches":
            return true
        default: break
        }
        return false
    }
}

private final class ScanSession {
    let scope: WalkScope
    let ordinary: Bool
    let condition = NSCondition()
    let start = DispatchTime.now().uptimeNanoseconds
    let listeners: ListenerSet
    var index = SearchIndex()
    var jobs: [ScanJob] = []
    var cloudJobs: [ScanJob] = []
    var workersActive = 0
    var error: Error?
    var counts = DMCounts()
    var pending = 0
    var entries = 0
    var local = true
    var nextPublication = 2_048
    let publish: (ScanMark, SearchIndex) throws -> Void

    init(scope: WalkScope, ordinary: Bool, listeners: ListenerSet,
         publish: @escaping (ScanMark, SearchIndex) throws -> Void) {
        self.scope = scope
        self.ordinary = ordinary
        self.listeners = listeners
        self.publish = publish
        index.volumes = listeners.checkpoints
        if scope.wholeDisk { index.reserve(2_250_000, nameBytes: 52_000_000) }
    }

    func mark(_ phase: String) -> ScanMark {
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        return ScanMark(phase: phase, seconds: seconds, entries: entries,
                        listenerCount: listeners.count, readOnlyVolumes: listeners.readOnlyCount,
                        denied: Int(counts.denied), disappeared: Int(counts.disappeared),
                        skippedMounts: Int(counts.other_mount), pending: pending + Int(counts.pending),
                        fallback: Int(counts.fallback))
    }

    func addRoot(_ path: String) {
        let id = index.append(path, attribute: Kind.anchor)
        jobs.append(ScanJob(path: path, parent: id))
    }

    func walk() {
        while true {
            condition.lock()
            while jobs.isEmpty && workersActive > 0 && error == nil { condition.wait() }
            guard error == nil, let job = jobs.popLast() else { condition.unlock(); return }
            workersActive += 1
            condition.unlock()

            let batch = DirectoryBatch()
            var delta = DMCounts()
            let code = dm_list(job.path, scope.primaryDevice, scope.dataDevice, ordinary,
                               collectEntry, Unmanaged.passUnretained(batch).toOpaque(), &delta)
            condition.lock()
            counts.denied += delta.denied
            counts.disappeared += delta.disappeared
            counts.other_mount += delta.other_mount
            counts.pending += delta.pending
            counts.fallback += delta.fallback
            if code != 0 {
                if error == nil { error = ScanError.metadata(path: job.path, error: code) }
            } else if error == nil {
                add(batch, job)
                if local && entries >= nextPublication {
                    let phase = nextPublication == 2_048 ? "partial" : "batch"
                    nextPublication = entries + 20_000
                    do { try publish(mark(phase), index) } catch { self.error = error }
                }
            }
            workersActive -= 1
            condition.broadcast()
            condition.unlock()
        }
    }

    private func add(_ batch: DirectoryBatch, _ job: ScanJob) {
        let parentHidden = index.attributes[Int(job.parent)] & Kind.hidden
        let platformParent = job.path.hasPrefix(dataRoot + "/")
            ? String(job.path.dropFirst(dataRoot.count)) : job.path
        let parentIsTrashRoot = !local && isProviderTrash(platformParent)
        let parentIsPackage = Self.packageSuffixes.contains { job.path.hasSuffix($0) }
        let parentPrefix = job.path == "/" ? "/" : job.path + "/"
        batch.names.withUnsafeBufferPointer { pool in
            for item in batch.items {
                let name = UnsafeBufferPointer(start: pool.baseAddress!.advanced(by: item.start), count: item.length)
                let isDirectory = item.type == 2
                if parentIsTrashRoot && name.elementsEqual(".Trash".utf8) { continue }
                var attribute: UInt8 = isDirectory ? Kind.directory : item.type == 1 ? Kind.file : Kind.other
                attribute |= parentHidden
                if name.first == 46 || item.flags & 0x8000 != 0 || parentIsPackage { attribute |= Kind.hidden }
                let dataless = item.flags & 0x40000000 != 0
                if dataless { attribute |= Kind.pending }
                if !isDirectory {
                    index.append(bytes: name, parent: job.parent, size: item.size,
                                 modified: item.modified, attribute: attribute)
                    entries += 1
                    continue
                }

                let component = String(decoding: name, as: UTF8.self)
                let path = parentPrefix + component
                if scope.wholeDisk && (path == dataRoot || scope.mirrors.contains(path) || path == scope.privateScratch) {
                    continue
                }
                let logical = platformParent == "/" ? "/" + component : platformParent + "/" + component
                if scope.defaultHiddenDirectory(logical) { attribute |= Kind.hidden }
                let cloudRoot = scope.cloudRoots.contains(path)
                if cloudRoot || logical == "/usr/local" { attribute &= ~Kind.hidden }
                let id = index.append(bytes: name, parent: job.parent, size: item.size,
                                      modified: item.modified, attribute: attribute)
                entries += 1
                if dataless {
                    pending += 1
                } else if name.elementsEqual(component.utf8) {
                    let child = ScanJob(path: path, parent: id)
                    if local && cloudRoot { cloudJobs.append(child) } else { jobs.append(child) }
                }
            }
        }
    }

    private static let packageSuffixes = [".app", ".appex", ".bundle", ".framework", ".plugin", ".kext", ".xpc"]

    func run(_ workers: Int) throws {
        let group = DispatchGroup()
        for _ in 1..<workers {
            DispatchQueue.global(qos: .userInitiated).async(group: group) { self.walk() }
        }
        walk()
        group.wait()
        if let error { throw error }
    }
}

extension SearchIndex {
    /// A subsequence of the same scan is available to callers before the local pass finishes.
    public static func scan(root: String, workers: Int = 4, ordinary: Bool = false,
                            onProgress: @escaping (ScanMark, SearchIndex) throws -> Void = { _, _ in }) throws -> SearchIndex {
        guard (1...4).contains(workers) else { throw ScanError.invalidWorkerCount }
        let root = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.path
        let scope = try WalkScope(root: root)
        let listeners = ListenerSet()
        try listeners.add(root: root)
        if scope.wholeDisk { try listeners.add(root: dataRoot) }
        let session = ScanSession(scope: scope, ordinary: ordinary, listeners: listeners, publish: onProgress)
        try onProgress(session.mark("listener_ready"), session.index)
        session.addRoot(root)
        if scope.wholeDisk { session.addRoot(dataRoot) }
        try onProgress(session.mark("scan_start"), session.index)
        try session.run(workers)
        try onProgress(session.mark("local_complete"), session.index)
        session.local = false
        session.jobs = session.cloudJobs
        session.cloudJobs = []
        if !session.jobs.isEmpty { try session.run(workers) }
        try onProgress(session.mark("cloud_complete"), session.index)
        return session.index
    }
}

private func CFUUIDCreateString(_ value: CFUUID) -> CFString {
    CoreFoundation.CFUUIDCreateString(nil, value)
}
