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
    public let external: ExternalScanStatistics?
}

public struct ExternalScanStatistics: Codable, Sendable, Equatable {
    public internal(set) var workers = 1
    public internal(set) var restoring = false
    public internal(set) var observedDirectories = 0
    public internal(set) var restoredDirectories = 0
    public internal(set) var observedEntries = 0
    public internal(set) var restoredEntries = 0
    public internal(set) var slotWaitNanoseconds: UInt64 = 0
    public internal(set) var listingNanoseconds: UInt64 = 0
    public internal(set) var openNanoseconds: UInt64 = 0
    public internal(set) var bulkNanoseconds: UInt64 = 0
    public internal(set) var readdirNanoseconds: UInt64 = 0
    public internal(set) var statNanoseconds: UInt64 = 0
    public internal(set) var restoreNanoseconds: UInt64 = 0
    public internal(set) var mergeNanoseconds: UInt64 = 0
    public internal(set) var prepareNanoseconds: UInt64 = 0
    public internal(set) var checkpointNanoseconds: UInt64 = 0
    public internal(set) var bulkCalls: UInt64 = 0
    public internal(set) var statCalls: UInt64 = 0
    public internal(set) var directoryLengthRows: UInt64 = 0
    public internal(set) var checkpointBytes = 0
}

struct ScanJob {
    let path: String
    let parent: UInt32
}

struct Item {
    let start: Int
    let length: Int
    let size: Int64
    let modified: Int64
    let flags: UInt32
    let type: UInt32
}

final class DirectoryBatch {
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
private let scanWorkerSlots = DispatchSemaphore(value: 4)

func readDirectory<T>(_ read: () throws -> T) rethrows -> T {
    directoryReadSlots.wait()
    defer { directoryReadSlots.signal() }
    return try read()
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
    var cachedJobs: [ScanJob] = []
    var cloudJobs: [ScanJob] = []
    var workersActive = 0
    var cachedWorkers = 0
    var previewCurrent = false
    var error: Error?
    var counts = DMCounts()
    var pending = 0
    var restrictions = [String: Int32]()
    var entries = 0
    var local = true
    var nextPublication = 2_048
    var publishedEntries = 0
    var lastPublication: UInt64 = 0
    var externalMetrics: ExternalScanStatistics?
    let profileExternal: Bool
    let directoryLengths: Bool
    let scanLog: ExternalScanLog?
    let publish: (ScanMark, SearchIndex) throws -> Void
    let cancelled: () -> Bool

    init(scope: WalkScope, ordinary: Bool, listeners: ListenerSet, excludedPaths: Set<String>, dataOnly: Bool,
         keeping retained: consuming SearchIndex, scanLog: ExternalScanLog?, profileExternal: Bool, directoryLengths: Bool,
         cancelled: @escaping () -> Bool, publish: @escaping (ScanMark, SearchIndex) throws -> Void) {
        self.scope = scope
        self.ordinary = ordinary
        self.excludedPaths = excludedPaths
        self.dataTargets = dataOnly ? scope.dataVolumeRoots : []
        self.listeners = listeners
        self.publish = publish
        self.cancelled = cancelled
        self.scanLog = scanLog
        self.profileExternal = profileExternal
        self.directoryLengths = directoryLengths
        externalMetrics = profileExternal ? ExternalScanStatistics() : nil
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
        if let coverage = index.tracking {
            for path in coverage.restricted { restrictions[path] = coverage.denialErrors?[path] ?? 0 }
        }
        index.volumes = listeners.checkpoints
        if scope.wholeDisk { index.reserve(2_250_000, nameBytes: 52_000_000) }
    }

    func mark(_ phase: String) -> ScanMark {
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        return ScanMark(phase: phase, seconds: seconds, entries: entries,
                        listenerCount: listeners.count, readOnlyVolumes: listeners.readOnlyCount,
                        denied: Int(counts.denied), disappeared: Int(counts.disappeared),
                        skippedMounts: Int(counts.other_mount), pending: pending + Int(counts.pending),
                        fallback: Int(counts.fallback), external: externalMetrics)
    }

    func addRoot(_ path: String) {
        let id = retainedDirectories[path] ?? index.append(path, attribute: Kind.anchor)
        enqueue(ScanJob(path: path, parent: id))
    }

    private func relativePath(_ path: String) -> String {
        path == scope.root ? "" : String(path.dropFirst(scope.root.count + 1))
    }

    private func enqueue(_ job: ScanJob) {
        if scanLog?.contains(relativePath(job.path)) == true { cachedJobs.append(job) }
        else { jobs.append(job) }
    }

    func beginRestoration() {
        externalMetrics?.restoring = !cachedJobs.isEmpty
    }

    /// Materialize a provisional view from the durable tree after the live
    /// root itself was accessible and still matched its saved fingerprint.
    /// Child fingerprints are rechecked by the normal scan before declaring
    /// the volume ready.
    func restorePreview(using scanLog: ExternalScanLog) throws {
        while let job = cachedJobs.popLast() {
            if cancelled() { throw CancellationError() }
            if let batch = scanLog.cached(relativePath(job.path)) { add(batch, job) }
        }
    }

    func walk() {
        scanWorkerSlots.wait()
        defer { scanWorkerSlots.signal() }
        while true {
            condition.lock()
            while cachedJobs.isEmpty && workersActive > 0 && error == nil &&
                    (jobs.isEmpty || externalMetrics?.restoring == true && cachedWorkers > 0) { condition.wait() }
            if cancelled(), error == nil { error = CancellationError(); condition.broadcast() }
            let cached = cachedJobs.popLast()
            guard error == nil, let job = cached ?? jobs.popLast() else { condition.unlock(); return }
            if cached != nil { cachedWorkers += 1 }
            workersActive += 1
            condition.unlock()

            let attempt = Result { try read(job) }
            condition.lock()
            switch attempt {
            case .success(let observation):
                do {
                    try apply(observation, to: job)
                    if previewCurrent, cached != nil, !observation.restored {
                        previewCurrent = false
                        try publish(mark("restore-invalidated"), withCoverage())
                    }
                } catch { self.error = self.error ?? error }
            case .failure(let failure):
                if !(failure is CancellationError) || error == nil { error = failure }
            }
            workersActive -= 1
            if cached != nil { cachedWorkers -= 1 }
            if error == nil && cachedWorkers == 0 && cachedJobs.isEmpty && externalMetrics?.restoring == true {
                externalMetrics?.restoring = false
                previewCurrent = false
                publishedEntries = entries
                nextPublication = entries + 20_000
                lastPublication = DispatchTime.now().uptimeNanoseconds
                do { try publish(mark("restore-complete"), withCoverage()) }
                catch { self.error = error }
            }
            condition.broadcast()
            condition.unlock()
        }
    }

    private struct Observation {
        let batch: DirectoryBatch
        let delta: DMCounts
        let code: Int32
        let relative: String
        let restored: Bool
        let slotWait: UInt64
        let listing: UInt64
        let restoreTime: UInt64
    }

    private func read(_ job: ScanJob) throws -> Observation {
        if cancelled() { throw CancellationError() }
        let relative = scanLog == nil ? "" : relativePath(job.path)
        let restoreStart = scanLog == nil ? 0 : DispatchTime.now().uptimeNanoseconds
        if let restored = try scanLog?.restored(job.path, relative: relative, device: scope.primaryDevice,
                                               cancelled: cancelled) {
            return Observation(batch: restored, delta: DMCounts(), code: 0, relative: relative, restored: true,
                               slotWait: 0, listing: 0,
                               restoreTime: DispatchTime.now().uptimeNanoseconds - restoreStart)
        }
        let profiled = profileExternal
        let queued = profiled ? DispatchTime.now().uptimeNanoseconds : 0
        let batch = DirectoryBatch()
        var delta = DMCounts()
        delta.profile = profiled
        delta.capture_stamp = scanLog != nil
        delta.directory_lengths = directoryLengths
        var entered: UInt64 = 0
        let code = try readDirectory {
            if cancelled() { throw CancellationError() }
            entered = profiled ? DispatchTime.now().uptimeNanoseconds : 0
            scope.onAccess?(job.path)
            return dm_list(job.path, scope.primaryDevice, scope.dataDevice, ordinary,
                           collectEntry, collectDenied, Unmanaged.passUnretained(batch).toOpaque(), &delta)
        }
        if code != 0 && scope.clouds.provider(containing: job.path) == nil {
            throw ScanError.metadata(path: job.path, error: code)
        }
        return Observation(batch: batch, delta: delta, code: code, relative: relative, restored: false,
                           slotWait: entered - queued,
                           listing: profiled ? DispatchTime.now().uptimeNanoseconds - entered : 0,
                           restoreTime: restoreStart == 0 || !profiled ? 0 : queued - restoreStart)
    }

    private func apply(_ observation: Observation, to job: ScanJob) throws {
        guard error == nil else { return }
        let batch = observation.batch
        let delta = observation.delta
        if externalMetrics != nil {
            externalMetrics!.slotWaitNanoseconds += observation.slotWait
            externalMetrics!.listingNanoseconds += observation.listing
            externalMetrics!.restoreNanoseconds += observation.restoreTime
            externalMetrics!.openNanoseconds += delta.open_ns
            externalMetrics!.bulkNanoseconds += delta.bulk_ns
            externalMetrics!.readdirNanoseconds += delta.readdir_ns
            externalMetrics!.statNanoseconds += delta.stat_ns
            externalMetrics!.bulkCalls += delta.bulk_calls
            externalMetrics!.statCalls += delta.stat_calls
            externalMetrics!.directoryLengthRows += delta.directory_length_rows
        }
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
        if (observation.code != 0 || delta.pending != 0), scope.clouds.provider(containing: job.path) != nil {
            index.attributes[Int(job.parent)] |= Kind.pending
            if delta.pending != 0 { index.attributes[Int(job.parent)] |= Kind.dataless }
            else { pending += 1 }
            return
        }
        let previous = entries
        let start = externalMetrics == nil ? 0 : DispatchTime.now().uptimeNanoseconds
        add(batch, job)
        if var metrics = externalMetrics {
            metrics.mergeNanoseconds += DispatchTime.now().uptimeNanoseconds - start
            if observation.restored {
                metrics.restoredDirectories += 1
                metrics.restoredEntries += entries - previous
            } else {
                metrics.observedDirectories += 1
                metrics.observedEntries += entries - previous
                if let scanLog, delta.stamp_valid {
                    let checkpointStart = DispatchTime.now().uptimeNanoseconds
                    try scanLog.append(batch, relative: observation.relative, stamp: delta.stamp)
                    metrics.checkpointNanoseconds += DispatchTime.now().uptimeNanoseconds - checkpointStart
                    metrics.checkpointBytes = scanLog.written
                }
            }
            externalMetrics = metrics
        }
        let now = externalMetrics == nil ? 0 : DispatchTime.now().uptimeNanoseconds
        let restoring = externalMetrics?.restoring == true
        let timedPublication = externalMetrics != nil && entries >= publishedEntries + 1_024 &&
            now - lastPublication >= (restoring ? 1_000_000_000 : 5_000_000_000)
        if local && (entries >= nextPublication || timedPublication) {
            let phase = publishedEntries == 0 ? "partial" : "batch"
            publishedEntries = entries
            nextPublication = entries + (restoring ? 8_192 : max(20_000, externalMetrics == nil ? 0 : entries / 20))
            lastPublication = now
            try publish(mark(phase), withCoverage())
            if externalMetrics != nil {
                externalMetrics!.prepareNanoseconds += DispatchTime.now().uptimeNanoseconds - now
            }
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
                    if local && scope.clouds.isScanBoundary(logical) { cloudJobs.append(child) } else { enqueue(child) }
                }
            }
        }
    }


    func run(_ workers: Int) throws {
        if externalMetrics != nil { externalMetrics!.workers = workers; lastPublication = start }
        let group = DispatchGroup()
        for _ in 1..<workers {
            DispatchQueue.global(qos: .userInitiated).async(group: group) { self.walk() }
        }
        walk()
        group.wait()
        if error == nil || error is CancellationError {
            try scanLog?.flush()
            if let scanLog { externalMetrics?.checkpointBytes = scanLog.written }
        }
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
                                cancelled: @escaping () -> Bool, scanLog: ExternalScanLog? = nil,
                                profileExternal: Bool = false, directoryLengths: Bool = false,
                                onProgress: @escaping (ScanMark, SearchIndex) throws -> Void) throws -> SearchIndex {
        try scan(root: scope.root, workers: workers, ordinary: false, establishListener: false,
                 excludedPaths: paths, dataOnly: false, keeping: SearchIndex(), scope: scope,
                 cancelled: cancelled, scanLog: scanLog, profileExternal: profileExternal,
                 directoryLengths: directoryLengths, onProgress: onProgress)
    }

    static func scanDataVolume(scope: WalkScope, keeping sealed: consuming SearchIndex,
                               excluding paths: Set<String>) throws -> SearchIndex {
        try scan(root: scope.root, workers: 4, ordinary: false, establishListener: false,
                 excludedPaths: paths, dataOnly: true, keeping: consume sealed, scope: scope, onProgress: { _, _ in })
    }

    private static func scan(root: String, workers: Int, ordinary: Bool, establishListener: Bool,
                             excludedPaths: Set<String>, dataOnly: Bool, keeping retained: consuming SearchIndex,
                             scope supplied: WalkScope? = nil, cancelled: @escaping () -> Bool = { false },
                             scanLog: ExternalScanLog? = nil, profileExternal: Bool = false, directoryLengths: Bool = false,
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
                                  scanLog: scanLog, profileExternal: profileExternal, directoryLengths: directoryLengths,
                                  cancelled: cancelled, publish: onProgress)
        try onProgress(session.mark("listener_ready"), session.index)
        session.addRoot(root)
        if scope.wholeDisk { session.addRoot(dataRoot) }
        session.beginRestoration()
        try onProgress(session.mark("scan_start"), session.index)
        if let scanLog, profileExternal, (2_048...1_000_000).contains(scanLog.retainedCount) {
            let preview: SearchIndex? = try {
                scanWorkerSlots.wait()
                defer { scanWorkerSlots.signal() }
                guard try scanLog.restored(root, relative: "", device: scope.primaryDevice, cancelled: cancelled) != nil
                else { return nil }
                let cached = ScanSession(scope: scope, ordinary: ordinary, listeners: listeners,
                                         excludedPaths: excludedPaths, dataOnly: dataOnly, keeping: SearchIndex(),
                                         scanLog: scanLog, profileExternal: false, directoryLengths: directoryLengths,
                                         cancelled: cancelled, publish: { _, _ in })
                cached.addRoot(root)
                try cached.restorePreview(using: scanLog)
                return cached.entries > 0 ? cached.withCoverage() : nil
            }()
            if let preview {
                session.previewCurrent = true
                try onProgress(session.mark("restore-preview"), preview)
            }
        }
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

    func protectedAccessRoots(home: String) -> [String] {
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
