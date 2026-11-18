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

let dataRoot = "/System/Volumes/Data"

struct WalkScope {
    static let packageSuffixes = [".app", ".appex", ".bundle", ".framework", ".plugin", ".kext", ".xpc"]
    let root: String
    let primaryDevice: dev_t
    let dataDevice: dev_t
    let mirrors: Set<String>
    let cloudRoots: Set<String>
    let privateScratch: Set<String>
    let homeLibrary: String
    let homeCaches: String
    let wholeDisk: Bool

    init(root: String) throws {
        self.root = root
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
        homeLibrary = home + "/Library"
        homeCaches = homeLibrary + "/Caches"
        let cwd = FileManager.default.currentDirectoryPath
        privateScratch = [cwd + "/.m1-tmp"]
    }

    static func device(_ path: String) throws -> dev_t {
        var info = stat()
        guard metadata(path, &info) == 0 else { throw ScanError.metadata(path: path, error: errno) }
        return info.st_dev
    }

    private static func metadata(_ path: String, _ storage: inout stat) -> Int32 {
        var result: Int32
        repeat { result = lstat(path, &storage) } while result < 0 && errno == EINTR
        return result
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

    func backgroundDirectory(_ path: String) -> Bool {
        let logical = path.hasPrefix(dataRoot + "/") ? String(path.dropFirst(dataRoot.count)) : path
        if inside(logical, homeLibrary) && !cloudRoots.contains(where: { inside(logical, $0) }) { return true }
        // An explicitly indexed fixture or external root is the reference point
        // for visibility. Only directories inside it affect that view.
        let visiblePrefix = wholeDisk && inside(logical, "/usr/local") ? "/usr/local" : ""
        let relative = wholeDisk ? logical.dropFirst(visiblePrefix.count) : path.dropFirst(root.count)
        var prefix = visiblePrefix
        let components = relative.split(separator: "/")
        for (index, component) in components.enumerated() {
            prefix += "/" + component
            let insidePackage = index < components.count - 1 && Self.packageSuffixes.contains { component.hasSuffix($0) }
            if component.hasPrefix(".") || insidePackage ||
                wholeDisk && defaultHiddenDirectory(prefix) { return true }
        }
        return false
    }

    func insideProviderTrash(_ path: String) -> Bool {
        let logical = path.hasPrefix(dataRoot + "/") ? String(path.dropFirst(dataRoot.count)) : path
        let components = logical.split(separator: "/")
        guard let trash = components.firstIndex(of: ".Trash"), trash >= 2 else { return false }
        return isProviderTrash("/" + components[..<trash].joined(separator: "/"))
    }
}

private final class ScanSession {
    let scope: WalkScope
    let ordinary: Bool
    let excludedPaths: Set<String>
    let dataTargets: [String]
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

    init(scope: WalkScope, ordinary: Bool, listeners: ListenerSet, excludedPaths: Set<String>, dataOnly: Bool,
         publish: @escaping (ScanMark, SearchIndex) throws -> Void) {
        self.scope = scope
        self.ordinary = ordinary
        self.excludedPaths = excludedPaths
        self.dataTargets = dataOnly ? scope.dataVolumeRoots : []
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
        let parentIsPackage = WalkScope.packageSuffixes.contains { job.path.hasSuffix($0) }
        let parentPrefix = job.path == "/" ? "/" : job.path + "/"
        let includeFiles = dataTargets.isEmpty || dataTargets.contains { inside(job.path, $0) }
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
                    if !includeFiles { continue }
                    index.append(bytes: name, parent: job.parent, size: item.size,
                                 modified: item.modified, attribute: attribute)
                    entries += 1
                    continue
                }

                let component = String(decoding: name, as: UTF8.self)
                let path = parentPrefix + component
                if excludedPaths.contains(path) || scope.wholeDisk &&
                    (path == dataRoot || scope.mirrors.contains(path) || scope.privateScratch.contains(path)) {
                    continue
                }
                if !dataTargets.isEmpty && !includeFiles &&
                    !dataTargets.contains(where: { inside(path, $0) || inside($0, path) }) { continue }
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
                            establishListener: Bool = true,
                            excludedPaths: Set<String> = [], dataOnly: Bool = false,
                            onProgress: @escaping (ScanMark, SearchIndex) throws -> Void = { _, _ in }) throws -> SearchIndex {
        guard (1...4).contains(workers) else { throw ScanError.invalidWorkerCount }
        let root = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.path
        let scope = try WalkScope(root: root)
        let listeners = ListenerSet()
        if establishListener {
            try listeners.add(root: root)
            if scope.wholeDisk { try listeners.add(root: dataRoot) }
        }
        let session = ScanSession(scope: scope, ordinary: ordinary, listeners: listeners,
                                  excludedPaths: excludedPaths, dataOnly: dataOnly, publish: onProgress)
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

extension WalkScope {
    var dataVolumeRoots: [String] { [dataRoot] + mirrors.map { String($0.dropFirst(dataRoot.count)) } }

    var protectedStartupRoots: [String] {
        let home = NSHomeDirectory()
        return [
            "/Desktop", "/Documents", "/Downloads", "/Library/Mail", "/Library/Messages",
            "/Library/Calendars", "/Library/Safari", "/Library/CloudStorage",
            "/Library/Mobile Documents", "/Library/Application Support/AddressBook",
            "/Library/Containers/com.apple.Home"
        ].map { home + $0 }
    }

    /// Observe one directory. A denied read is distinct from an empty directory.
    func observe(_ path: String, inherited: UInt8, excluding excluded: [String]) throws -> DirectoryObservation {
        guard !insideProviderTrash(path), !excluded.contains(where: { inside(path, $0) }) else { return .absent }
        if cloudRoots.contains(where: { inside(path, $0) }) {
            // Avoid walking through an unloaded ancestor to inspect its child.
            var ancestors: [String] = [path]
            while !cloudRoots.contains(ancestors.last!) {
                ancestors.append(parentPath(ancestors.last!))
            }
            for ancestor in ancestors.reversed() {
                var checked = stat()
                if Self.metadata(ancestor, &checked) != 0 {
                    if errno == EACCES || errno == EPERM { return .restricted }
                    if errno == ENOTDIR || errno == ENOENT { return .absent }
                    throw ScanError.metadata(path: ancestor, error: errno)
                }
                if checked.st_flags & 0x40000000 != 0 { return .restricted }
            }
        }
        var own = stat()
        if Self.metadata(path, &own) != 0 {
            if errno == EACCES || errno == EPERM { return .restricted }
            if errno == ENOENT || errno == ENOTDIR || errno == ELOOP { return .absent }
            throw ScanError.metadata(path: path, error: errno)
        }
        guard own.st_mode & S_IFMT == S_IFDIR else { return .absent }
        let batch = DirectoryBatch()
        var counts = DMCounts()
        let error = dm_list(path, primaryDevice, dataDevice, false,
                            collectEntry, Unmanaged.passUnretained(batch).toOpaque(), &counts)
        if error != 0 { throw ScanError.metadata(path: path, error: error) }
        if counts.denied != 0 || counts.pending != 0 || counts.other_mount != 0 { return .restricted }
        if counts.disappeared != 0 && Self.metadata(path, &own) != 0 {
            if errno == ENOENT || errno == ENOTDIR { return .absent }
            if errno == EACCES || errno == EPERM { return .restricted }
            throw ScanError.metadata(path: path, error: errno)
        }
        var children: [String: TrackedEntry] = [:]
        children.reserveCapacity(batch.items.count)
        let package = Self.packageSuffixes.contains { path.hasSuffix($0) }
        let logical = path.hasPrefix(dataRoot + "/") ? String(path.dropFirst(dataRoot.count)) : path
        let excludedChildren = Set(excluded.filter { parentPath($0) == path }.map(leafName))
        let mirroredChildren = Set(mirrors.filter { parentPath($0) == path }.map(leafName))
        let cloudChildren = Set(cloudRoots.filter { parentPath($0) == path }.map(leafName))
        let providerTrash = isProviderTrash(logical)
        let containsDataRoot = wholeDisk && path == parentPath(dataRoot)
        let dataName = leafName(dataRoot)
        let mayHideSystemChild = logical == "/" || logical == "/Library" || logical == "/private" ||
                                 logical == "/Library/Developer" || logical == parentPath(homeCaches)
        batch.names.withUnsafeBufferPointer { pool in
            for item in batch.items {
                let bytes = UnsafeBufferPointer(start: pool.baseAddress!.advanced(by: item.start), count: item.length)
                let name = String(decoding: bytes, as: UTF8.self)
                if excludedChildren.contains(name) || mirroredChildren.contains(name) ||
                    containsDataRoot && name == dataName ||
                    providerTrash && name == ".Trash" { continue }
                var flags: UInt8 = item.type == 2 ? Kind.directory : item.type == 1 ? Kind.file : Kind.other
                if inherited & Kind.hidden != 0 || name.hasPrefix(".") || item.flags & 0x8000 != 0 ||
                    package || mayHideSystemChild && defaultHiddenDirectory(joinedPath(logical, name)) { flags |= Kind.hidden }
                if cloudChildren.contains(name) || path == "/usr" && name == "local" { flags &= ~Kind.hidden }
                if item.flags & 0x40000000 != 0 { flags |= Kind.pending }
                children[name] = TrackedEntry(size: item.size, modified: item.modified, attribute: flags)
            }
        }
        let (seconds, overflow) = Int64(own.st_mtimespec.tv_sec).multipliedReportingOverflow(by: 1_000_000_000)
        let (total, addOverflow) = seconds.addingReportingOverflow(Int64(own.st_mtimespec.tv_nsec))
        let time = overflow || addOverflow ? (own.st_mtimespec.tv_sec < 0 ? Int64.min : Int64.max) : total
        return .readable(own: TrackedEntry(size: own.st_size, modified: time, attribute: Kind.directory),
                         children: children)
    }

    /// An explicit regular-file event never traverses a substituted leaf or
    /// a cloud scope. Renames and ambiguous results use directory reconciliation.
    func observeFile(_ path: String, inherited: UInt8) -> (file: TrackedEntry?, parent: TrackedEntry)? {
        guard !cloudRoots.contains(where: { inside(path, $0) }) else { return nil }
        let parent = parentPath(path)
        let fd = Darwin.open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { _ = Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_flags & 0x40000000 == 0,
              info.st_dev == primaryDevice || info.st_dev == dataDevice,
              let folder = Self.fileEntry(info, attribute: inherited)
        else { return nil }
        var result: Int32
        let name = leafName(path)
        repeat { result = fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) } while result < 0 && errno == EINTR
        if result < 0 && errno == ENOENT { return (nil, folder) }
        guard result == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_dev == primaryDevice || info.st_dev == dataDevice
        else { return nil }
        var attribute = Kind.file | (inherited & Kind.hidden)
        let package = [".app", ".appex", ".bundle", ".framework", ".plugin", ".kext", ".xpc"]
            .contains { parent.hasSuffix($0) }
        if name.hasPrefix(".") || info.st_flags & 0x8000 != 0 || package || defaultHiddenDirectory(path) {
            attribute |= Kind.hidden
        }
        if info.st_flags & 0x40000000 != 0 { attribute |= Kind.pending }
        guard let entry = Self.fileEntry(info, attribute: attribute) else { return nil }
        return (entry, folder)
    }

    private static func fileEntry(_ info: stat, attribute: UInt8) -> TrackedEntry? {
        let (seconds, overflow) = Int64(info.st_mtimespec.tv_sec).multipliedReportingOverflow(by: 1_000_000_000)
        let (modified, sumOverflow) = seconds.addingReportingOverflow(Int64(info.st_mtimespec.tv_nsec))
        guard !overflow, !sumOverflow else { return nil }
        return TrackedEntry(size: info.st_size, modified: modified, attribute: attribute)
    }
}
