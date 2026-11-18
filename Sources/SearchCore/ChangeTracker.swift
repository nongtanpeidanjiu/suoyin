import Darwin
import Foundation
import CoreServices
import DarwinMetadata

public struct TrackingStatus: Codable {
    public var phase = "starting"
    public var recovery = "uninitialized"
    public var generation: UInt64 = 0
    public var appliedBatches: UInt64 = 0
    public var receivedEvents: UInt64 = 0
    public var bufferedEvents = 0
    public var appliedEvents: [String: UInt64] = [:]
    public var durableEvents: [String: UInt64] = [:]
    public var durableGeneration: UInt64 = 0
    public var outOfOrderBatches: UInt64 = 0
    public var maximumEventRegression: UInt64 = 0
    public var deferredDirectories = 0
    public var baseWriteDeferred = false
    public var automaticBaseWritesInWindow = 0
    public var exitBaseWrites: UInt64 = 0
    public var exitBaseWrittenBytes: UInt64 = 0
    public var baseWrites: UInt64 = 0
    public var baseWrittenBytes: UInt64 = 0
    public var journalFrames: UInt64 = 0
    public var journalWrittenBytes: UInt64 = 0
    public var journalLength = 0
    public var journalRestoredFrames = 0
    public var journalRecovery = "none"
    public var compactions: UInt64 = 0
    public var compacting = false
    public var lastCompactionNanoseconds: UInt64 = 0
    public var coverageRestricted: [String] = []
    public var overlayRows = 0
    public var baseRecords = 0
    public var applying = false
    public var lastApplyStart: UInt64 = 0
    public var lastApplyEnd: UInt64 = 0
    public var invalidEvidence: String?
    public var registrationPosition: [String: UInt64] = [:]
    public var firstCallbackPosition: [String: UInt64] = [:]
    public var degradedVolumes: [String] = []
    public var rebuilds: UInt64 = 0
    public var directoriesObserved: UInt64 = 0
    public var recursiveDirectoriesObserved: UInt64 = 0
    public var directFilesObserved: UInt64 = 0
    public var error: String?
}

public struct ApplyInterval: Codable {
    public let start: UInt64
    public let end: UInt64
}

private struct EventBatch {
    let volume: Int
    let epoch: UInt64
    let events: [VolumeEvent]
}

/// Work and persistence are serialized on one queue. Queries capture a value
/// of the last published view, then run without holding the publication lock.
public final class ChangeTracker {
    private let root: String
    private let scope: WalkScope
    private let path: String
    private let ownDirectory: String
    private let excluded: [String]
    private let update = DispatchQueue(label: "index.change-writer", autoreleaseFrequency: .workItem)
    private let lock = NSLock()
    private var view: LiveSearchView?
    private var publishedCoverage = Set<String>()
    private var status = TrackingStatus()
    private var current: LiveIndex?
    private var sources: [Int: VolumeEventStream] = [:]
    private var identities: [VolumeIdentity]
    private var cursors = [EventCursor]()
    private var epochs: [UInt64]
    private var batches: [EventBatch] = []
    private var pendingEvents = 0
    private var overflowed: Set<Int> = []
    private var applyScheduled = false
    private var paused = false
    static let journalFlushInterval = DispatchTimeInterval.seconds(45)
    private var saveScheduled = false
    private var needsBaseWrite = false
    private var firstBaseWrite = false
    private var quotaCheck: TimeInterval?
    private var budget: BaseWriteBudget
    private let wallTime: () -> TimeInterval
    private var directories = DirectorySchedule()
    private var deliveredHigh: [Int: UInt64] = [:]
    private var directoryWake: UInt64?
    private var directoryTimer: DispatchSourceTimer?
    private static let pendingLimit = 50_000
    private var journal: ChangeJournal?
    private var durableImage: JournalImage?
    private var saveTicket: UInt64 = 0
    private var closed = false
    private var observer: ((String) -> Void)?
    private var needsReplay: Set<Int> = []
    private var scanBarriers: [Int: ScanBoundary] = [:]
    private var rebuildThrottle = RebuildThrottle()
    private var degraded = Set<Int>()
    private let compactor = DispatchQueue(label: "index.compaction", qos: .utility, autoreleaseFrequency: .workItem)
    private static let compactionRows = 32_768
    private static let compactionBytes = 32 * 1024 * 1024
    private var compactionToken: UInt64 = 0
    private var duringCompaction: [String: Bool]?
    private var applyTrace: [ApplyInterval]?
    private var lastAllocatorRelief: UInt64 = 0

    public convenience init(root: String, snapshot: String, ownData: String) throws {
        try self.init(root: root, snapshot: snapshot, ownData: ownData,
                      wallTime: { Date().timeIntervalSince1970 })
    }

    init(root: String, snapshot: String, ownData: String,
         wallTime: @escaping () -> TimeInterval) throws {
        self.wallTime = wallTime
        budget = BaseWriteBudget(snapshot: snapshot)
        let root = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        self.root = root
        self.path = snapshot
        ownDirectory = URL(fileURLWithPath: ownData).resolvingSymlinksInPath().standardizedFileURL.path
        let walk = try WalkScope(root: root)
        scope = walk
        excluded = Array(walk.privateScratch.filter { !inside(root, $0) }) +
            [ownDirectory].filter { !inside(root, $0) }
        identities = try (root == "/" ? ["/", dataRoot] : [root]).map { try VolumeIdentity(root: $0) }
        epochs = [UInt64](repeating: 0, count: identities.count)
    }

    public func start(onPhase: @escaping (String) -> Void = { _ in }) {
        update.async {
            self.observer = onPhase
            do { try self.bootstrap() } catch { self.fail(error) }
        }
    }

    public func snapshotStatus() -> TrackingStatus {
        lock.withLock { status }
    }

    public func memoryBreakdown() -> [String: Int] {
        update.sync { current?.memoryBreakdown() ?? [:] }
    }

    public static func processMetrics() -> [String: UInt64] {
        let info = dm_process_metrics()
        var result = ["allocatorInUse": info.heap_used, "allocatorAllocated": info.heap_reserved]
        if info.available {
            result["physicalFootprint"] = info.footprint
            result["peakPhysicalFootprint"] = info.footprint_peak
            result["processWrittenBytes"] = info.written_bytes
        }
        return result
    }

    private func note(_ phase: String) {
        lock.withLock { status.phase = phase }
        observer?(phase)
    }

    private func fail(_ error: Error) {
        lock.withLock { status.error = String(describing: error) }
        note("error")
    }

    public func search(_ query: String, mode: QueryMode = .name, column: SearchColumn = .name,
                       direction: SearchDirection = .ascending, showAll: Bool = false,
                       offset: Int = 0, limit: Int = 50) -> [SearchRow] {
        let captured = lock.withLock { view }
        return captured?.search(query, mode: mode, column: column, direction: direction,
                                showAll: showAll, offset: offset, limit: limit) ?? []
    }

    private func publish(_ updated: LiveIndex, changed: Bool) {
        current = updated
        let coverage: [String]?
        if publishedCoverage == updated.state.restricted { coverage = nil }
        else {
            publishedCoverage = updated.state.restricted
            coverage = publishedCoverage.sorted()
        }
        let read = updated.readView()
        lock.withLock {
            view = read
            if changed { status.generation += 1 }
            status.appliedEvents = positions()
            status.overlayRows = updated.state.changes.count
            status.baseRecords = updated.base.recordCount
            if let coverage { status.coverageRestricted = coverage }
        }
    }

    private func positions() -> [String: UInt64] {
        var result: [String: UInt64] = [:]
        for (i, cursor) in cursors.enumerated() { result[identities[i].root] = cursor.applied }
        return result
    }

    private func bootstrap() throws {
        var loaded: SearchIndex?
        var reason = "missing"
        do {
            var value = try SearchIndex.load(from: path)
            let identityMatches = identities.allSatisfy { volume in
                value.volumes.contains { $0.root == volume.root && $0.volumeUUID == volume.uuid }
            }
            if identityMatches && (value.tracking?.root == root || value.tracking == nil && hasRoot(value)) {
                if value.loadedPrepared {
                    var loadedJournal = ChangeJournal(snapshot: path, identity: try SearchIndex.preparedIdentity(at: path))
                    try loadedJournal.restore(into: &value, root: root)
                    journal = loadedJournal
                    lock.withLock {
                        status.journalLength = loadedJournal.length
                        status.journalRecovery = loadedJournal.repair
                        status.journalRestoredFrames = loadedJournal.restoredFrames
                    }
                } else {
                    needsBaseWrite = true
                }
                loaded = value
                reason = "replay"
            } else { reason = "scope-changed" }
        } catch SnapshotError.invalid { reason = "corrupt" }
        catch SnapshotError.unsupportedVersion { reason = "unsupported-version" }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {}
        firstBaseWrite = reason == "missing"
        lock.withLock { status.automaticBaseWritesInWindow = budget.count(at: wallTime()) }
        let previous = loaded?.volumes ?? []
        var reset = Set<Int>()
        cursors = identities.enumerated().map { i, volume in
            let prior = previous.first { $0.root == volume.root }
            if volume.readOnly { return EventCursor(applied: nil) }
            if loaded != nil && volume.permitsReplay(prior) {
                needsReplay.insert(i)
                return EventCursor(applied: prior?.appliedEvent, replaying: true)
            }
            reset.insert(i)
            return EventCursor(applied: nil, scanBaseline: volume.scanReplayBaseline())
        }
        for i in identities.indices where !identities[i].readOnly {
            try watch(i)
        }
        var reopened: [String] = []
        if var loaded {
            loaded.prepare()
            var validated = LiveIndex(base: loaded, root: root)
            let savedPositions = Dictionary(uniqueKeysWithValues: loaded.volumes.compactMap { volume in
                volume.appliedEvent.map { (volume.root, $0) }
            })
            durableImage = validated.journalImage(at: savedPositions)
            lock.withLock { status.durableEvents = savedPositions }
            let scopes = Set(scope.protectedStartupRoots).union(validated.state.restricted).sorted()
            reopened = validated.verifyStartupCoverage(at: scopes) { folder in
                try? scope.observe(folder, inherited: 0, excluding: excluded)
            }
            publish(validated, changed: true)
            scheduleSave()
            lock.withLock { status.recovery = reset.isEmpty ? reason : "invalid-checkpoint" }
            note("ready")
        }
        let needsInitialScan = loaded == nil
        loaded = nil
        if needsInitialScan || !reset.isEmpty {
            if !needsInitialScan {
                for i in reset { _ = rebuildThrottle.allow(volume: i, now: DispatchTime.now().uptimeNanoseconds) }
            }
            try rebuild(reset, initial: needsInitialScan, reason: needsInitialScan ? reason : "invalid-checkpoint")
        } else if !reopened.isEmpty {
            try applyCoverage(at: reopened)
        }
        for stream in sources.values { stream.flush() }
        update.async {
            self.drain()
            self.finishReplayIfReady()
        }
    }

    private func hasRoot(_ value: SearchIndex) -> Bool {
        guard let i = value.records.firstIndex(where: { $0.parent == .max }) else { return false }
        return value.name(UInt32(i)) == root
    }

    private func watch(_ volume: Int) throws {
        sources[volume]?.stop()
        epochs[volume] += 1
        let epoch = epochs[volume]
        let since = needsReplay.contains(volume) ? cursors[volume].applied : nil
        let key = identities[volume].root
        let observed = identities[volume].observedBoundary()
        lock.withLock {
            status.registrationPosition[key] = observed
            status.firstCallbackPosition.removeValue(forKey: key)
        }
        // A scoped tracker whose recovery marker is inside its tree need not
        // receive unrelated events from the rest of the device.
        let relative = root != "/" && inside(ownDirectory, root) ? identities[volume].relativeScope(root) : ""
        sources[volume] = try VolumeEventStream(volume: identities[volume], since: since, scope: relative) {
            [weak self] events in
            guard let self else { return }
            self.update.async { self.enqueue(EventBatch(volume: volume, epoch: epoch, events: events)) }
        }
    }

    private func markScanBoundary(for volumes: Set<Int>) throws {
        guard !volumes.isEmpty else { return }
        let device = try WalkScope.device(ownDirectory)
        for i in volumes where !identities[i].readOnly {
            guard identities[i].device == device, excluded.contains(ownDirectory) else {
                throw ScanError.listener(root: identities[i].root)
            }
            // An event written on the observed device after enumeration bounds
            // the scan. The marker itself is excluded from the index.
            let marker = joinedPath(ownDirectory, ".scan-boundary-" + UUID().uuidString)
            scanBarriers[i] = ScanBoundary(marker: marker, after: FSEventsGetCurrentEventId())
            let fd = Darwin.open(marker, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw ScanError.metadata(path: ownDirectory, error: errno) }
            let closed = Darwin.close(fd)
            let closeError = errno
            let removed = Darwin.unlink(marker)
            if closed != 0 { throw ScanError.metadata(path: ownDirectory, error: closeError) }
            if removed != 0 { throw ScanError.metadata(path: ownDirectory, error: errno) }
        }
    }

    private func enqueue(_ batch: EventBatch) {
        guard !closed, batch.epoch == epochs[batch.volume], !degraded.contains(batch.volume) else { return }
        let key = identities[batch.volume].root
        lock.withLock {
            if status.firstCallbackPosition[key] == nil {
                status.firstCallbackPosition[key] = batch.events.lazy.filter { !$0.historyDone }.map(\.id).max()
            }
        }
        if pendingEvents + batch.events.count > Self.pendingLimit {
            overflowed.insert(batch.volume)
        } else {
            pendingEvents += batch.events.count
            batches.append(batch)
        }
        lock.withLock { status.bufferedEvents = pendingEvents }
        if applyScheduled { return }
        applyScheduled = true
        update.asyncAfter(deadline: .now() + .milliseconds(800)) {
            self.applyScheduled = false
            self.drain()
        }
    }

    private func logicalPath(_ raw: String, volume: Int) -> String? {
        let mount = identities[volume].mount
        let relative = raw == mount ? "" : raw.hasPrefix(mount + "/") && mount != "/"
            ? String(raw.dropFirst(mount.count + 1))
            : String(raw.drop(while: { $0 == "/" }))
        let components = relative.split(separator: "/").filter { $0 != "." }
        guard !components.contains("..") else { return nil }
        let suffix = components.joined(separator: "/")
        if mount == dataRoot {
            let physical = suffix.isEmpty ? dataRoot : joinedPath(dataRoot, suffix)
            if scope.mirrors.contains(where: { inside(physical, $0) }) || !scope.wholeDisk {
                return suffix.isEmpty ? "/" : "/" + suffix
            }
            return physical
        }
        return suffix.isEmpty ? mount : joinedPath(mount, suffix)
    }

    private func dirtyPaths(from events: [EventBatch]) -> ([String: DirectoryUpdate], [Int: UInt64], Set<Int>, Set<Int>) {
        var work: [String: DirectoryUpdate] = [:]
        var high: [Int: UInt64] = [:]
        var reset = overflowed
        var crossed = Set<Int>()
        var late: UInt64 = 0
        var maximum: UInt64 = 0

        func mark(_ path: String, event: VolumeEvent, volume: Int, recursive: Bool? = nil, file: String? = nil) {
            var item = work.removeValue(forKey: path) ?? DirectoryUpdate()
            item.add(event: event.id, volume: volume)
            if let recursive {
                item.recursive = item.recursive == true || recursive
                item.files.removeAll()
            } else if let file, item.recursive == nil { item.files.insert(file) }
            work[path] = item
        }

        for batch in events where batch.epoch == epochs[batch.volume] {
            let volume = batch.volume
            let prior = cursors[volume].lastSeen
            let before = cursors[volume].outOfOrderBatches
            if !cursors[volume].receivedBatch(batch.events) {
                reset.insert(volume)
                let invalid = batch.events.first(where: { $0.invalidatesHistory || !$0.historyDone && ($0.id == 0 || $0.id == .max) })
                let latest = batch.events.filter { !$0.historyDone }.map(\.id).max()
                lock.withLock {
                    status.invalidEvidence = "batch=\(latest ?? 0) flags=\(invalid?.flags ?? 0) prior=\(prior ?? 0)"
                }
                continue
            }
            late += cursors[volume].outOfOrderBatches - before
            maximum = max(maximum, cursors[volume].maximumRegression)
            for event in batch.events {
                if event.historyDone { continue }
                high[volume] = max(high[volume] ?? 0, event.id)
                guard let path = logicalPath(event.path, volume: volume) else {
                    mark(root, event: event, volume: volume, recursive: true)
                    continue
                }
                if scanBarriers[volume]?.covered(by: event, at: path) == true { crossed.insert(volume) }
                if excluded.contains(where: { inside(path, $0) }) || scope.insideProviderTrash(path) { continue }
                guard inside(path, root) else {
                    if event.recursive && inside(root, path) { mark(root, event: event, volume: volume, recursive: true) }
                    continue
                }
                if event.recursive {
                    mark(path, event: event, volume: volume, recursive: true)
                } else if event.leafFileChange, path != root {
                    mark(parentPath(path), event: event, volume: volume, file: path)
                } else {
                    let folder = event.isDirectory && !event.structural ? path : parentPath(path)
                    mark(inside(folder, root) ? folder : root, event: event, volume: volume, recursive: false)
                    if event.isDirectory && event.structural && path != root {
                        mark(path, event: event, volume: volume, recursive: true)
                    }
                }
            }
        }
        if late > 0 {
            lock.withLock {
                status.outOfOrderBatches += late
                status.maximumEventRegression = max(status.maximumEventRegression, maximum)
            }
        }
        return (work, high, reset, crossed)
    }

    private func scheduleDirectoryWake() {
        let next = directories.next
        guard next != directoryWake else { return }
        directoryWake = next
        guard let next else {
            directoryTimer?.schedule(deadline: .distantFuture)
            return
        }
        let timer: DispatchSourceTimer
        if let existing = directoryTimer {
            timer = existing
        } else {
            timer = DispatchSource.makeTimerSource(flags: .strict, queue: update)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.directoryWake = nil
                self.drain()
            }
            directoryTimer = timer
            timer.activate()
        }
        timer.schedule(deadline: DispatchTime(uptimeNanoseconds: next), leeway: .nanoseconds(0))
    }

    private func drain(force: Bool = false) {
        guard !closed, !paused, current != nil, snapshotStatus().error == nil,
              !batches.isEmpty || !overflowed.isEmpty || directories.count > 0 else { return }
        if !force, duringCompaction != nil, (current?.state.changes.count ?? 0) >= 2 * Self.compactionRows,
           overflowed.isEmpty { return }
        let submitted = batches
        batches.removeAll(keepingCapacity: true)
        pendingEvents = 0
        lock.withLock { status.bufferedEvents = 0 }
        let before = cursors
        let (observations, high, invalid, crossed) = dirtyPaths(from: submitted)
        var reset = invalid
        overflowed.removeAll()
        let now = DispatchTime.now().uptimeNanoseconds
        let immediate = force || snapshotStatus().phase != "caught-up"
        if reset.isEmpty {
            for (path, item) in observations {
                let hidden: Bool
                if let known = directories.knownVisibility(at: path, now: now) {
                    hidden = known
                } else if let indexed = current?.entry(at: path) {
                    hidden = indexed.attribute & Kind.hidden != 0
                } else {
                    hidden = scope.backgroundDirectory(path)
                }
                directories.enqueue(item, at: path, hidden: hidden, now: now)
            }
            if directories.pendingItems > Self.pendingLimit, !immediate {
                reset.formUnion(directories.pendingVolumes)
            }
        }
        if !reset.isEmpty {
            directories.discard(volumes: reset)
            for volume in reset { deliveredHigh[volume] = nil }
            lock.withLock { status.deferredDirectories = directories.count }
            scheduleDirectoryWake()
            lock.withLock { status.receivedEvents += UInt64(submitted.reduce(0) { $0 + $1.events.count }) }
            do {
                var rebuildable = Set<Int>()
                let now = DispatchTime.now().uptimeNanoseconds
                for i in reset {
                    if degraded.contains(i) { continue }
                    guard rebuildThrottle.allow(volume: i, now: now) else {
                        degraded.insert(i)
                        sources.removeValue(forKey: i)?.stop()
                        epochs[i] += 1
                        cursors[i] = EventCursor(applied: nil)
                        scanBarriers.removeValue(forKey: i)
                        needsReplay.remove(i)
                        lock.withLock {
                            status.degradedVolumes = degraded.map { identities[$0].root }.sorted()
                            status.appliedEvents = positions()
                        }
                        scheduleSave()
                        note("degraded")
                        continue
                    }
                    rebuildable.insert(i)
                    identities[i] = try VolumeIdentity(root: identities[i].root)
                    cursors[i] = EventCursor(applied: nil, scanBaseline: identities[i].scanReplayBaseline())
                    needsReplay.remove(i)
                    if !identities[i].readOnly { try watch(i) }
                }
                if !rebuildable.isEmpty { try rebuild(rebuildable, initial: false, reason: "history-invalid") }
                // Keep work from other volumes, whose checkpoints remain unchanged.
                let unaffected = submitted.filter { !reset.contains($0.volume) }
                if !unaffected.isEmpty {
                    for i in identities.indices where !reset.contains(i) { cursors[i] = before[i] }
                    batches.insert(contentsOf: unaffected, at: 0)
                    drain()
                }
            } catch { fail(error) }
            return
        }
        lock.withLock { status.receivedEvents += UInt64(submitted.reduce(0) { $0 + $1.events.count }) }
        for (volume, id) in high { deliveredHigh[volume] = max(deliveredHigh[volume] ?? 0, id) }
        let ready = directories.take(at: now, force: immediate)
        lock.withLock { status.deferredDirectories = directories.count }
        scheduleDirectoryWake()
        var work: [String: Bool] = [:]
        var files = Set<String>()
        for (path, item) in ready {
            work[path] = item.recursive
            files.formUnion(item.files)
        }
        if (!work.isEmpty || !files.isEmpty), var updated = current {
            current = nil
            let start = DispatchTime.now().uptimeNanoseconds
            lock.withLock { status.applying = true; status.lastApplyStart = start }
            do {
                var work = work
                var direct: UInt64 = 0
                for path in files {
                    let parent = parentPath(path)
                    if work[parent] != nil { continue }
                    if updated.refreshFile(path, observation: { scope.observeFile(path, inherited: $0) }) {
                        direct += 1
                    } else { work[parent] = false }
                }
                try reconcile(work, in: &updated)
                updated.prepareDelta()
                acknowledgeReadyEvents()
                publish(updated, changed: true)
                recordDuringCompaction(work)
                if duringCompaction != nil {
                    for path in files {
                        let parent = parentPath(path)
                        if duringCompaction?[parent] == nil { duringCompaction?[parent] = false }
                    }
                }
                let end = DispatchTime.now().uptimeNanoseconds
                lock.withLock {
                    status.applying = false
                    status.lastApplyEnd = end
                    status.appliedBatches += 1
                    status.directFilesObserved += direct
                }
                applyTrace?.append(ApplyInterval(start: start, end: end))
                scheduleSave()
                scheduleCompaction()
                releaseTemporaryPages()
            } catch {
                lock.withLock { status.applying = false }
                fail(error)
            }
        }
        if work.isEmpty, files.isEmpty {
            acknowledgeReadyEvents()
            lock.withLock { status.appliedEvents = positions() }
        }
        for i in crossed { scanBarriers.removeValue(forKey: i) }
        if !force { finishReplayIfReady() }
    }

    private func acknowledgeReadyEvents() {
        let floors = directories.floors()
        let time = DispatchTime.now().uptimeNanoseconds
        for i in cursors.indices {
            var applied = deliveredHigh[i]
            if let floor = floors[i] {
                applied = applied.flatMap { floor > 1 ? min($0, floor - 1) : nil }
            } else {
                deliveredHigh[i] = nil
            }
            cursors[i].acknowledge(applied, at: time)
        }
    }

    private func reconcile(_ initial: [String: Bool], in index: inout LiveIndex) throws {
        var work = initial
        var visited: Set<String> = []
        var ordered = work.keys.sorted { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }
        var queued = Set(ordered)
        var position = 0
        var observedDirectories: UInt64 = 0
        var recursive: UInt64 = 0
        while position < ordered.count {
            let folder = ordered[position]
            position += 1
            guard inside(folder, root), !excluded.contains(where: { inside(folder, $0) }),
                  visited.insert(folder).inserted else { continue }
            let inherited = index.entry(at: folder)?.attribute ?? 0
            observedDirectories += 1
            let observed = try scope.observe(folder, inherited: inherited, excluding: excluded)
            var more = index.reconcile(path: folder, observed: observed)
            if work[folder] == true, case let .readable(_, contents) = observed {
                recursive += 1
                for (name, entry) in contents where entry.directory && entry.attribute & Kind.pending == 0 {
                    let child = joinedPath(folder, name)
                    work[child] = true
                    more.append(child)
                }
            }
            for path in more where queued.insert(path).inserted { ordered.append(path) }
        }
        lock.withLock {
            status.directoriesObserved += observedDirectories
            status.recursiveDirectoriesObserved += recursive
        }
    }

    private func releaseTemporaryPages() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastAllocatorRelief >= 10_000_000_000 else { return }
        lastAllocatorRelief = now
        update.async { dm_release_allocator_cache() }
    }

    private func rebuild(_ affected: Set<Int>, initial: Bool, reason: String) throws {
        compactionToken += 1
        duringCompaction = nil
        lock.withLock {
            status.recovery = reason
            if !initial { status.rebuilds += 1 }
            status.compacting = false
        }
        note("scan-start")
        var index: SearchIndex
        if !initial, root == "/", !affected.contains(0), current != nil {
            retainSealedVolume()
            dm_release_allocator_cache()
            index = try rebuildDataVolume(preserving: current!)
        } else {
            var lastPartial: Double = 0
            index = try SearchIndex.scan(root: root, establishListener: false, excludedPaths: Set(excluded)) {
                mark, partial in
                if initial && (mark.phase == "partial" || mark.phase == "local_complete" ||
                               mark.phase == "batch" && mark.seconds >= lastPartial + 0.5) {
                    lastPartial = mark.seconds
                    self.publish(LiveIndex(base: partial, root: self.root, linkChildren: false), changed: true)
                }
                if mark.phase == "partial" { self.note("scan-partial") }
            }
        }
        dm_release_allocator_cache()
        index.tightenScannedStorage()
        dm_release_allocator_cache()
        publish(LiveIndex(base: index, root: root), changed: true)
        try markScanBoundary(for: affected)
        needsBaseWrite = true
        note(initial ? "ready" : "rebuilt")
        update.async { dm_release_allocator_cache() }
    }

    private func retainSealedVolume() {
        guard let original = current else { return }
        var sealed = mergeDataVolume(old: original, new: SearchIndex(), targets: scope.dataVolumeRoots)
        sealed.prepare()
        publish(LiveIndex(base: sealed, root: root), changed: true)
    }

    private func rebuildDataVolume(preserving old: LiveIndex) throws -> SearchIndex {
        let fresh = try SearchIndex.scan(root: "/", establishListener: false,
                                         excludedPaths: Set(excluded), dataOnly: true)
        return mergeDataVolume(old: old, new: fresh, targets: scope.dataVolumeRoots)
    }

    private func finishReplayIfReady() {
        guard snapshotStatus().error == nil, !paused, batches.isEmpty else { return }
        needsReplay = needsReplay.filter { !cursors[$0].historyDelivered }
        guard needsReplay.isEmpty, scanBarriers.isEmpty, degraded.isEmpty else { return }
        if needsBaseWrite, directories.count == 0 {
            do { try persistPendingBase() }
            catch { fail(error); return }
        }
        if snapshotStatus().phase != "caught-up" {
            releaseTemporaryPages()
            note("caught-up")
        }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        let ticket = saveTicket
        update.asyncAfter(deadline: .now() + Self.journalFlushInterval) {
            guard !self.closed, self.saveTicket == ticket, self.snapshotStatus().error == nil else { return }
            do { try self.flushJournal() } catch { self.fail(error) }
        }
    }

    private func checkpoints() -> [VolumeCheckpoint] {
        var pending = directories.floors()
        for batch in batches where batch.epoch == epochs[batch.volume] {
            for event in batch.events where !event.historyDone && event.id != .max {
                pending[batch.volume] = min(pending[batch.volume] ?? .max, event.id)
            }
        }
        let now = DispatchTime.now().uptimeNanoseconds
        return identities.enumerated().map { i, volume in
            let safe = !volume.readOnly && !overflowed.contains(i)
                ? cursors[i].lag.position(at: now, observed: volume.observedBoundary(), pending: pending[i])
                : nil
            return volume.checkpoint(safe)
        }
    }

    private func allowAutomaticWrite() -> Bool {
        let now = wallTime()
        let next = budget.next(at: now)
        lock.withLock { status.automaticBaseWritesInWindow = budget.count(at: now) }
        guard let next, next <= now else {
            lock.withLock { status.baseWriteDeferred = true }
            if let next { scheduleQuotaCheck(at: next) }
            return false
        }
        return true
    }

    private func scheduleQuotaCheck(at time: TimeInterval) {
        guard !closed, quotaCheck != time else { return }
        quotaCheck = time
        let delay = max(0.1, time - wallTime())
        update.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.closed, self.quotaCheck == time else { return }
            self.quotaCheck = nil
            guard !self.paused, self.batches.isEmpty, self.directories.count == 0 else {
                self.scheduleQuotaCheck(at: self.wallTime() + 1)
                return
            }
            self.finishReplayIfReady()
            self.scheduleCompaction()
        }
    }

    private func reserveAutomaticWrite() -> Bool {
        guard allowAutomaticWrite() else { return false }
        do { return try budget.reserve(at: wallTime()) }
        catch {
            budget.preventWrites()
            lock.withLock {
                status.baseWriteDeferred = true
                status.automaticBaseWritesInWindow = BaseWriteBudget.limit
            }
            return false
        }
    }

    private func persistPendingBase(onExit: Bool = false) throws {
        guard needsBaseWrite, needsReplay.isEmpty, scanBarriers.isEmpty, degraded.isEmpty else { return }
        if !firstBaseWrite, !reserveAutomaticWrite() { return }
        try persistBase(onExit: onExit)
        needsBaseWrite = false
        firstBaseWrite = false
    }

    private func durablePositions(_ volumes: [VolumeCheckpoint]) -> [String: UInt64] {
        Dictionary(uniqueKeysWithValues: volumes.compactMap { volume in
            volume.appliedEvent.map { (volume.root, $0) }
        })
    }

    private func didSave(_ image: JournalImage) {
        durableImage = image
        lock.withLock {
            status.durableEvents = image.positions
            status.durableGeneration = status.generation
            status.journalLength = journal?.length ?? 0
        }
        saveScheduled = false
        saveTicket += 1
    }

    private func persistBase(beforeReplace: (() throws -> Void)? = nil,
                             afterReplace: (() throws -> Void)? = nil,
                             replacement: LiveIndex? = nil, onExit: Bool = false) throws {
        guard let index = replacement ?? current else { return }
        var archive = index.archive()
        archive.volumes = checkpoints()
        try archive.savePrepared(to: path, beforeReplace: beforeReplace)
        try afterReplace?()
        let bytes = try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber
        var fresh = ChangeJournal(snapshot: path, identity: try SearchIndex.preparedIdentity(at: path))
        let initialized = try fresh.reset()
        journal = fresh
        if replacement != nil { publish(index, changed: true) }
        didSave(index.journalImage(at: durablePositions(archive.volumes)))
        lock.withLock {
            status.baseWrites += 1
            let size = bytes?.uint64Value ?? 0
            status.baseWrittenBytes += size
            status.automaticBaseWritesInWindow = budget.count(at: wallTime())
            status.baseWriteDeferred = false
            if onExit {
                status.exitBaseWrites += 1
                status.exitBaseWrittenBytes += size
            }
            status.journalWrittenBytes += UInt64(initialized)
        }
    }

    private func flushJournal() throws {
        guard !needsBaseWrite, let current, var openJournal = journal, let durableImage else {
            saveScheduled = false
            return
        }
        let image = current.journalImage(at: durablePositions(checkpoints()))
        if let frame = image.delta(after: durableImage) {
            let written = try openJournal.append(frame)
            journal = openJournal
            lock.withLock {
                status.journalFrames += 1
                status.journalWrittenBytes += UInt64(written)
            }
        }
        didSave(image)
        scheduleCompaction()
    }

    public func save() throws {
        try update.sync { try flushJournal() }
    }

    private func recordDuringCompaction(_ work: [String: Bool]) {
        guard duringCompaction != nil else { return }
        for (path, recursive) in work {
            if recursive || duringCompaction?[path] == nil {
                duringCompaction?[path] = recursive
            }
        }
    }

    private func scheduleCompaction() {
        guard !closed, !needsBaseWrite, degraded.isEmpty, duringCompaction == nil,
              let original = current,
              original.state.changes.count >= Self.compactionRows || (journal?.length ?? 0) >= Self.compactionBytes
        else { return }
        guard allowAutomaticWrite() else { return }
        let token = compactionToken
        let started = DispatchTime.now().uptimeNanoseconds
        duringCompaction = [:]
        lock.withLock { status.compacting = true }
        compactor.async { [weak self] in
            let base = original.compacted()
            guard let self else { return }
            self.update.async {
                guard !self.closed, self.compactionToken == token, let work = self.duringCompaction else { return }
                self.duringCompaction = nil
                if !self.degraded.isEmpty {
                    self.lock.withLock { self.status.compacting = false }
                    return
                }
                do {
                    var replacement = LiveIndex(base: base, root: self.root)
                    try self.reconcile(work, in: &replacement)
                    replacement.prepareDelta()
                    guard self.reserveAutomaticWrite() else {
                        self.lock.withLock { self.status.compacting = false }
                        self.drain()
                        return
                    }
                    try self.persistBase(replacement: replacement)
                    self.lock.withLock {
                        self.status.compacting = false
                        self.status.compactions += 1
                        self.status.lastCompactionNanoseconds = DispatchTime.now().uptimeNanoseconds - started
                    }
                    self.update.async { dm_release_allocator_cache() }
                    self.drain()
                } catch { self.fail(error) }
            }
        }
    }

    /// The CLI only exposes these deterministic kill points in its owned tree.
    public func compactForTesting(beforeReplace: (() throws -> Void)? = nil,
                                  afterReplace: (() throws -> Void)? = nil) throws {
        try update.sync {
            guard let index = current else { return }
            let replacement = LiveIndex(base: index.compacted(), root: root)
            try persistBase(beforeReplace: beforeReplace, afterReplace: afterReplace, replacement: replacement)
        }
    }

    /// Flush delivery before the next queue barrier. A deliberately held batch
    /// stays pending and cannot advance the durable cursor.
    public func synchronize() {
        update.sync { for stream in sources.values { stream.flush() } }
        update.sync { drain(); finishReplayIfReady() }
    }

    /// The application can request a metadata-only reconciliation of a scope
    /// after its existing access changes. Indeterminate access remains restricted.
    public func recheckCoverage(at paths: [String]) {
        update.async {
            do { try self.applyCoverage(at: paths) }
            catch { self.fail(error) }
        }
    }

    private func applyCoverage(at paths: [String]) throws {
        guard !closed, var updated = current else { return }
        let work = paths.reduce(into: [String: Bool]()) { $0[$1] = false }
        try reconcile(work, in: &updated)
        updated.prepareDelta()
        publish(updated, changed: true)
        recordDuringCompaction(work)
        scheduleSave()
        scheduleCompaction()
    }

    public func stop() throws {
        update.sync { for stream in sources.values { stream.flush() } }
        try update.sync {
            drain(force: true)
            for stream in sources.values { stream.stop() }
            sources.removeAll()
            closed = true
            directoryTimer?.cancel()
            directoryTimer = nil
            if snapshotStatus().error == nil {
                if needsBaseWrite { try persistPendingBase(onExit: true) }
                else { try flushJournal() }
            }
        }
    }

    public func beginApplyTrace() {
        update.sync { applyTrace = [] }
    }

    public func endApplyTrace() -> [ApplyInterval] {
        update.sync {
            let captured = applyTrace ?? []
            applyTrace = nil
            return captured
        }
    }

    public func queuedEventID(at path: String) -> UInt64? {
        update.sync {
            batches.lazy.flatMap { batch in
                batch.events.lazy.filter { self.logicalPath($0.path, volume: batch.volume) == path }.map(\.id)
            }.max()
        }
    }

    // These are deterministic injection points for the owned-directory harness.
    public func holdUpdates(_ hold: Bool) {
        update.sync { paused = hold; if !hold { drain() } }
    }

    public func simulateDroppedHistory() {
        update.sync {
            guard let i = identities.firstIndex(where: { !$0.readOnly }) else { return }
            overflowed.insert(i)
            drain()
        }
    }

    func deliverForTesting(_ events: [VolumeEvent], writing: () throws -> Void = {},
                           check: () -> Void = {}) rethrows {
        try update.sync {
            guard let i = identities.firstIndex(where: { !$0.readOnly }) else { return }
            try writing()
            enqueue(EventBatch(volume: i, epoch: epochs[i], events: events))
            drain()
            check()
        }
    }

    func injectPermissionObservation(_ path: String, _ observation: DirectoryObservation) {
        update.sync {
            guard var index = current else { return }
            _ = index.reconcile(path: path, observed: observation)
            index.prepareDelta()
            publish(index, changed: true)
        }
    }
}
