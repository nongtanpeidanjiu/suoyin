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
    var denied: [String: Int32] = [:]
    var unidentifiedDenial = false
}

private let collectEntry: DMEntryCallback = { context, name, length, size, modified, flags, type in
    let batch = Unmanaged<DirectoryBatch>.fromOpaque(context!).takeUnretainedValue()
    let start = batch.names.count
    batch.names.append(contentsOf: UnsafeBufferPointer(start: name, count: length))
    batch.items.append(Item(start: start, length: length, size: size,
                            modified: modified, flags: flags, type: type))
}

private let collectDenied: DMDeniedEntryCallback = { context, name, length, error in
    let batch = Unmanaged<DirectoryBatch>.fromOpaque(context!).takeUnretainedValue()
    guard let name, let component = String(bytes: UnsafeBufferPointer(start: name, count: length), encoding: .utf8),
          !component.isEmpty, component != ".", component != "..", !component.contains("/") else {
        batch.unidentifiedDenial = true
        return
    }
    batch.denied[component] = error
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

enum EntryObservation {
    case entry(TrackedEntry)
    case missing
    case unverified
}

struct WalkScope {
    static let packageSuffixes = [".app", ".appex", ".bundle", ".framework", ".plugin", ".kext", ".xpc"]
    let root: String
    let primaryDevice: dev_t
    let dataDevice: dev_t
    let mirrors: Set<String>
    let clouds: CloudRoots
    let privateScratch: Set<String>
    let homeLibrary: String
    let homeCaches: String
    let wholeDisk: Bool
    let onAccess: ((String) -> Void)?

    init(root: String, clouds: CloudRoots? = nil, onAccess: ((String) -> Void)? = nil) throws {
        self.root = root
        self.onAccess = onAccess
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
        self.clouds = clouds ?? CloudRoots(home: wholeDisk ? home : nil)
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
        if clouds.isVisibleRoot(path) { return false }
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
        if inside(logical, homeLibrary) && clouds.provider(containing: logical) == nil && logical != clouds.storage { return true }
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

    func providerTrashParent(_ path: String) -> Bool {
        clouds.provider(containing: path) == path || wholeDisk && CloudRoots.matchesProviderRoot(path)
    }

    func insideProviderTrash(_ path: String) -> Bool {
        var suffix = path[...]
        while let range = suffix.range(of: "/.Trash") {
            let end = range.upperBound
            if (end == path.endIndex || path[end] == "/"),
               providerTrashParent(String(path[..<range.lowerBound])) { return true }
            suffix = path[end...]
        }
        return false
    }
}

private let directoryReadSlots = DispatchSemaphore(value: 4)

private func readDirectory<T>(_ read: () -> T) -> T {
    directoryReadSlots.wait()
    defer { directoryReadSlots.signal() }
    return read()
}

private final class ScanSession {
    let scope: WalkScope
    let ordinary: Bool
    let excludedPaths: Set<String>
    let dataTargets: [String]
    let condition = NSCondition()
    let start = DispatchTime.now().uptimeNanoseconds
    let listeners: ListenerSet
    var index: SearchIndex
    let retainedDirectories: [String: UInt32]
    var jobs: [ScanJob] = []
    var cloudJobs: [ScanJob] = []
    var workersActive = 0
    var error: Error?
    var counts = DMCounts()
    var pending = 0
    var restrictions = [String: Int32]()
    var entries = 0
    var local = true
    var nextPublication = 2_048
    let publish: (ScanMark, SearchIndex) throws -> Void
    let cancelled: () -> Bool

    init(scope: WalkScope, ordinary: Bool, listeners: ListenerSet, excludedPaths: Set<String>, dataOnly: Bool,
         keeping retained: consuming SearchIndex, cancelled: @escaping () -> Bool, publish: @escaping (ScanMark, SearchIndex) throws -> Void) {
        self.scope = scope
        self.ordinary = ordinary
        self.excludedPaths = excludedPaths
        self.dataTargets = dataOnly ? scope.dataVolumeRoots : []
        self.listeners = listeners
        self.publish = publish
        self.cancelled = cancelled
        var bridgePaths: Set<String> = []
        if retained.recordCount > 0 {
            for target in dataTargets {
                var parent = parentPath(target)
                while bridgePaths.insert(parent).inserted && parent != "/" { parent = parentPath(parent) }
            }
        }
        do {
            var navigator = LiveIndex(base: copy retained, root: scope.root, linkChildren: false)
            retainedDirectories = Dictionary(uniqueKeysWithValues: bridgePaths.compactMap { path in
                navigator.directoryID(path).map { (path, $0) }
            })
        }
        index = consume retained
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
        let id = retainedDirectories[path] ?? index.append(path, attribute: Kind.anchor)
        jobs.append(ScanJob(path: path, parent: id))
    }

    func walk() {
        while true {
            condition.lock()
            while jobs.isEmpty && workersActive > 0 && error == nil { condition.wait() }
            if cancelled(), error == nil { error = CancellationError(); condition.broadcast() }
            guard error == nil, let job = jobs.popLast() else { condition.unlock(); return }
            workersActive += 1
            condition.unlock()

            let batch = DirectoryBatch()
            var delta = DMCounts()
            let code = readDirectory {
                scope.onAccess?(job.path)
                return dm_list(job.path, scope.primaryDevice, scope.dataDevice, ordinary,
                               collectEntry, collectDenied, Unmanaged.passUnretained(batch).toOpaque(), &delta)
            }
            condition.lock()
            counts.denied += delta.denied
            counts.disappeared += delta.disappeared
            counts.other_mount += delta.other_mount
            counts.pending += delta.pending
            counts.fallback += delta.fallback
            if delta.directory_error != 0 || batch.unidentifiedDenial { restrictions[job.path] = delta.directory_error }
            if !batch.denied.isEmpty {
                let isProvider = scope.providerTrashParent(job.path)
                for (name, error) in batch.denied {
                    let child = joinedPath(job.path, name)
                    if !excludedPaths.contains(child), !scope.mirrors.contains(child), !(isProvider && name == ".Trash") {
                        restrictions[child] = error
                    }
                }
            }
            if (code != 0 || delta.pending != 0), scope.clouds.provider(containing: job.path) != nil {
                index.attributes[Int(job.parent)] |= Kind.pending
                if delta.pending != 0 { index.attributes[Int(job.parent)] |= Kind.dataless }
                if delta.pending == 0 { pending += 1 }
            } else if code != 0 {
                if error == nil { error = ScanError.metadata(path: job.path, error: code) }
            } else if error == nil {
                add(batch, job)
                if local && entries >= nextPublication {
                    let phase = nextPublication == 2_048 ? "partial" : "batch"
                    nextPublication = entries + 20_000
                    do { try publish(mark(phase), withCoverage()) } catch { self.error = error }
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
        let parentIsTrashRoot = scope.providerTrashParent(platformParent)
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
                let dataless = item.flags & Kind.datalessFlag != 0
                if dataless { attribute |= Kind.placeholderBits(for: attribute) }
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
                let cloudRoot = scope.clouds.isVisibleRoot(logical)
                if cloudRoot || logical == "/usr/local" { attribute &= ~Kind.hidden }
                let id = retainedDirectories[path] ?? index.append(bytes: name, parent: job.parent, size: item.size,
                                                                   modified: item.modified, attribute: attribute)
                entries += 1
                if dataless {
                    pending += 1
                } else if name.elementsEqual(component.utf8) {
                    let child = ScanJob(path: path, parent: id)
                    if local && scope.clouds.isScanBoundary(logical) { cloudJobs.append(child) } else { jobs.append(child) }
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

    func withCoverage() -> SearchIndex {
        var result = index
        if !restrictions.isEmpty {
            result.tracking = TrackingState(root: scope.root, changes: [:], restricted: Set(restrictions.keys),
                                            denialErrors: restrictions)
        }
        return result
    }
}

extension SearchIndex {
    /// A subsequence of the same scan is available to callers before the local pass finishes.
    public static func scan(root: String, workers: Int = 4, ordinary: Bool = false,
                            establishListener: Bool = true,
                            excludedPaths: Set<String> = [], dataOnly: Bool = false,
                            onProgress: @escaping (ScanMark, SearchIndex) throws -> Void = { _, _ in }) throws -> SearchIndex {
        try scan(root: root, workers: workers, ordinary: ordinary, establishListener: establishListener,
                 excludedPaths: excludedPaths, dataOnly: dataOnly, keeping: SearchIndex(), onProgress: onProgress)
    }

    static func scanForTracking(scope: WalkScope, workers: Int, excluding paths: Set<String>,
                                cancelled: @escaping () -> Bool,
                                onProgress: @escaping (ScanMark, SearchIndex) throws -> Void) throws -> SearchIndex {
        try scan(root: scope.root, workers: workers, ordinary: false, establishListener: false,
                 excludedPaths: paths, dataOnly: false, keeping: SearchIndex(), scope: scope,
                 cancelled: cancelled, onProgress: onProgress)
    }

    static func scanDataVolume(scope: WalkScope, keeping sealed: consuming SearchIndex,
                               excluding paths: Set<String>) throws -> SearchIndex {
        try scan(root: scope.root, workers: 4, ordinary: false, establishListener: false,
                 excludedPaths: paths, dataOnly: true, keeping: consume sealed, scope: scope, onProgress: { _, _ in })
    }

    private static func scan(root: String, workers: Int, ordinary: Bool, establishListener: Bool,
                             excludedPaths: Set<String>, dataOnly: Bool, keeping retained: consuming SearchIndex,
                             scope supplied: WalkScope? = nil, cancelled: @escaping () -> Bool = { false },
                             onProgress: @escaping (ScanMark, SearchIndex) throws -> Void) throws -> SearchIndex {
        guard (1...4).contains(workers) else { throw ScanError.invalidWorkerCount }
        let root = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.path
        let scope = try supplied ?? WalkScope(root: root)
        let listeners = ListenerSet()
        if establishListener {
            try listeners.add(root: root)
            if scope.wholeDisk { try listeners.add(root: dataRoot) }
        }
        let session = ScanSession(scope: scope, ordinary: ordinary, listeners: listeners,
                                  excludedPaths: excludedPaths, dataOnly: dataOnly, keeping: consume retained,
                                  cancelled: cancelled, publish: onProgress)
        try onProgress(session.mark("listener_ready"), session.index)
        session.addRoot(root)
        if scope.wholeDisk { session.addRoot(dataRoot) }
        try onProgress(session.mark("scan_start"), session.index)
        try session.run(workers)
        try onProgress(session.mark("local_complete"), session.withCoverage())
        session.local = false
        session.jobs = session.cloudJobs
        session.cloudJobs = []
        if !session.jobs.isEmpty { try session.run(workers) }
        let result = session.withCoverage()
        try onProgress(session.mark("cloud_complete"), result)
        return result
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
            "/Library/Mobile Documents", "/Library/Application Support/AddressBook"
        ].map { home + $0 }
    }

    func cloudDataless(at path: String) -> Bool? {
        guard let provider = clouds.provider(containing: path) else { return nil }
        var ancestors = [path]
        while ancestors.last! != provider { ancestors.append(parentPath(ancestors.last!)) }
        for ancestor in ancestors.reversed() {
            var info = stat()
            guard Self.metadata(ancestor, &info) == 0 else { return nil }
            let dataless = info.st_flags & Kind.datalessFlag != 0
            if ancestor == path { return dataless }
            if dataless { return nil }
        }
        return nil
    }

    /// Observe one directory. A denied read is distinct from an empty directory.
    func observe(_ path: String, inherited: UInt8, excluding excluded: [String],
                 loadCloud: Bool = false) throws -> DirectoryObservation {
        guard !insideProviderTrash(path), !excluded.contains(where: { inside(path, $0) }) else { return .absent }
        onAccess?(path)
        if let provider = clouds.provider(containing: path) {
            // Avoid walking through an unloaded ancestor to inspect its child.
            var ancestors: [String] = [path]
            while ancestors.last! != provider {
                ancestors.append(parentPath(ancestors.last!))
            }
            for ancestor in ancestors.reversed() {
                var checked = stat()
                if Self.metadata(ancestor, &checked) != 0 {
                    if errno == EACCES || errno == EPERM { return .denied(errno) }
                    if errno == ENOTDIR || errno == ENOENT { return .absent }
                    throw ScanError.metadata(path: ancestor, error: errno)
                }
                if checked.st_flags & Kind.datalessFlag != 0 {
                    if !loadCloud { return ancestor == path ? .pending(dataless: true) : .deferred }
                    if ancestor != path { return .deferred }
                }
            }
        }
        var own = stat()
        if Self.metadata(path, &own) != 0 {
            if errno == EACCES || errno == EPERM { return .denied(errno) }
            if errno == ENOENT || errno == ENOTDIR || errno == ELOOP { return .absent }
            throw ScanError.metadata(path: path, error: errno)
        }
        guard own.st_mode & S_IFMT == S_IFDIR else { return .absent }
        let batch = DirectoryBatch()
        var counts = DMCounts()
        let context = Unmanaged.passUnretained(batch).toOpaque()
        guard own.st_dev == primaryDevice || own.st_dev == dataDevice else { return .absent }
        let error = readDirectory {
            loadCloud
                ? dm_list_cloud(path, own.st_dev, collectEntry, collectDenied, context, &counts)
                : dm_list(path, primaryDevice, dataDevice, false, collectEntry, collectDenied, context, &counts)
        }
        if error != 0 { throw ScanError.metadata(path: path, error: error) }
        if counts.pending != 0, clouds.provider(containing: path) != nil { return .pending(dataless: true) }
        if counts.directory_error != 0 { return .denied(counts.directory_error) }
        if batch.unidentifiedDenial { return .restricted }
        if counts.pending != 0 || counts.other_mount != 0 { return .deferred }
        if loadCloud && counts.disappeared != 0 { return .deferred }
        if counts.disappeared != 0 && Self.metadata(path, &own) != 0 {
            if errno == ENOENT || errno == ENOTDIR { return .absent }
            if errno == EACCES || errno == EPERM { return .denied(errno) }
            throw ScanError.metadata(path: path, error: errno)
        }
        var children: [String: TrackedEntry] = [:]
        children.reserveCapacity(batch.items.count)
        let package = Self.packageSuffixes.contains { path.hasSuffix($0) }
        let logical = path.hasPrefix(dataRoot + "/") ? String(path.dropFirst(dataRoot.count)) : path
        let excludedChildren = Set(excluded.filter { parentPath($0) == path }.map(leafName))
        let mirroredChildren = Set(mirrors.filter { parentPath($0) == path }.map(leafName))
        let providerTrash = providerTrashParent(logical)
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
                if flags & Kind.mask == Kind.directory && clouds.isVisibleRoot(joinedPath(logical, name)) ||
                    path == "/usr" && name == "local" { flags &= ~Kind.hidden }
                if item.flags & Kind.datalessFlag != 0 { flags |= Kind.placeholderBits(for: flags) }
                children[name] = TrackedEntry(size: item.size, modified: item.modified, attribute: flags)
            }
        }
        if loadCloud, Self.metadata(path, &own) != 0 { return .deferred }
        let ownFlags = Kind.directory | (own.st_flags & Kind.datalessFlag != 0 ? Kind.dataless : 0)
        let (seconds, overflow) = Int64(own.st_mtimespec.tv_sec).multipliedReportingOverflow(by: 1_000_000_000)
        let (total, addOverflow) = seconds.addingReportingOverflow(Int64(own.st_mtimespec.tv_nsec))
        let time = overflow || addOverflow ? (own.st_mtimespec.tv_sec < 0 ? Int64.min : Int64.max) : total
        return .readable(own: TrackedEntry(size: own.st_size, modified: time, attribute: ownFlags),
                         children: children, denied: batch.denied.filter {
            !excludedChildren.contains($0.key) && !mirroredChildren.contains($0.key) &&
                !(containsDataRoot && $0.key == dataName) && !(providerTrash && $0.key == ".Trash")
        })
    }

    // Cloud observation must check unavailable ancestors before accessing a leaf.
    // Reconcile those paths using the guarded directory reader.
    func observeEntry(_ path: String, inherited: UInt8, verifyAccess: Bool = false) -> EntryObservation {
        guard clouds.provider(containing: path) == nil else { return .unverified }
        onAccess?(path)
        var info = stat()
        if Self.metadata(path, &info) != 0 {
            return errno == ENOENT ? .missing : .unverified
        }
        guard info.st_dev == primaryDevice || info.st_dev == dataDevice else { return .unverified }
        let type = info.st_mode & S_IFMT
        if verifyAccess, type == S_IFDIR {
            // An explicit directory event can report an ACL or mode change
            // even though lstat still succeeds. Check coverage without listing it.
            guard info.st_flags & Kind.datalessFlag == 0, access(path, R_OK | X_OK) == 0 else { return .unverified }
            let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return .unverified }
            _ = Darwin.close(fd)
        }
        let kind = type == S_IFDIR ? Kind.directory : type == S_IFREG ? Kind.file : Kind.other
        var attribute = kind | (inherited & Kind.hidden)
        let parent = parentPath(path)
        if leafName(path).hasPrefix(".") || info.st_flags & 0x8000 != 0 ||
            Self.packageSuffixes.contains(where: { parent.hasSuffix($0) }) || defaultHiddenDirectory(path) {
            attribute |= Kind.hidden
        }
        if path == "/usr/local" { attribute &= ~Kind.hidden }
        if info.st_flags & Kind.datalessFlag != 0 { attribute |= Kind.placeholderBits(for: attribute) }
        guard let entry = Self.fileEntry(info, attribute: attribute) else { return .unverified }
        return .entry(entry)
    }

    private static func fileEntry(_ info: stat, attribute: UInt8) -> TrackedEntry? {
        let (seconds, overflow) = Int64(info.st_mtimespec.tv_sec).multipliedReportingOverflow(by: 1_000_000_000)
        let (modified, sumOverflow) = seconds.addingReportingOverflow(Int64(info.st_mtimespec.tv_nsec))
        guard !overflow, !sumOverflow else { return nil }
        return TrackedEntry(size: info.st_size, modified: modified, attribute: attribute)
    }
}
