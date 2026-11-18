import Darwin
import Foundation
import CoreServices
import DarwinMetadata

public struct TrackingStatus: Codable {
    public var cloud = CloudCompletionStatus()
    public var slowVolume = false
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
    public var indexReconciling = false
    public var nextRecoveryAt: TimeInterval?
    public var droppedEvents: UInt64 = 0
    public var droppedDuringRecovery: UInt64 = 0
    public var lastDroppedAtUptimeNanoseconds: UInt64?
    public var lastDroppedEventID: UInt64?
    public var lastDroppedFlags: UInt32?
    public var recoveries: UInt64 = 0
    public var lastRecoveryNanoseconds: UInt64?
    public var directoriesObserved: UInt64 = 0
    public var recursiveDirectoriesObserved: UInt64 = 0
    public var directFilesObserved: UInt64 = 0
    public var directDirectoriesObserved: UInt64 = 0
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
    let ownDirectory: String
    let excluded: [String]
    private let update = DispatchQueue(label: "index.change-writer", autoreleaseFrequency: .workItem)
    private let lock = NSLock()
    private var cloud: CloudCompletion?
    private let mounts: ExternalVolumes?
    private let external: ExternalMount?
    private let externalPersistence: Bool
    private var externalCancelled = false
    private var directoryEvents = false
    private var pollTimer: DispatchSourceTimer?
    private var cloudChangedDuringCompaction = false
    private var view: LiveSearchView?
    private var publishedCoverage = Set<String>()
    private var status = TrackingStatus()
    private var current: LiveIndex?
    private var sources: [Int: VolumeEventStream] = [:]
    private var identities: [VolumeIdentity]
    private let injectionVolume: (index: Int, root: String)?
    private var cursors = [EventCursor]()
    private var epochs: [UInt64]
    private var batches: [EventBatch] = []
    // The event callback uses this bounded inbox even when the writer is scanning.
    // Inbox fields, epochs, event activity and receivingRecovery are protected by lock.
    private var invalidations: [Int: UInt64] = [:]
    private var activity: [Int: EventActivity] = [:]
    private var receivingRecovery = false
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
    private var fileContents = FileContentSchedule()
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
    private let recoveryTiming: RecoveryTiming
    private var pendingRecovery: [Int: UInt64] = [:]
    private var recoveryInProgress = false
    private var lastRecoveryStart: UInt64?
    private var recoveryTimer: DispatchSourceTimer?
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
         wallTime: @escaping () -> TimeInterval, recoveryTiming: RecoveryTiming = RecoveryTiming(),
         cloudRoots: CloudRoots? = nil, cloudTiming: CloudCompletion.Timing = .init(),
         cloudReader: CloudCompletion.Reader? = nil, external: ExternalMount? = nil,
         externalPersistence: Bool = true, discoverExternal: Bool = true) throws {
        self.wallTime = wallTime
        self.external = external
        self.externalPersistence = externalPersistence
        directoryEvents = external.map { !$0.fileEvents } ?? false
        status.slowVolume = directoryEvents
        self.recoveryTiming = recoveryTiming
        budget = BaseWriteBudget(snapshot: snapshot)
        let root = try Self.canonicalPath(root)
        self.root = root
        self.path = snapshot
        ownDirectory = try Self.canonicalPath(ownData)
        mounts = root == "/" && discoverExternal ? ExternalVolumes(directory: ownDirectory) : nil
        let walk = try WalkScope(root: root, clouds: cloudRoots)
        scope = walk
        excluded = Array(walk.privateScratch.filter { !inside(root, $0) }) +
            [ownDirectory].filter { !inside(root, $0) }
        identities = try external.map { [$0.identity] } ??
            (root == "/" ? ["/", dataRoot] : [root]).map { try VolumeIdentity(root: $0) }
        injectionVolume = identities.enumerated().first { !$0.element.readOnly }.map { ($0.offset, $0.element.root) }
        epochs = [UInt64](repeating: 0, count: identities.count)
        if walk.clouds.storage != nil {
            let excluded = self.excluded
            let queue = CloudCompletion(writer: update, roots: walk.clouds, timing: cloudTiming,
                                        monitorNetwork: cloudReader == nil, read: cloudReader ?? { path, flags in
                try walk.observe(path, inherited: flags, excluding: excluded, loadCloud: true)
            })
            queue.changed = { [weak self] value in
                guard let self else { return }
                self.lock.withLock { self.status.cloud = value }
            }
            queue.beforeApply = { [weak self] in self?.drain() }
            queue.apply = { [weak self] path, result in self?.applyCloud(path, result) ?? false }
            cloud = queue
        }
    }

    private static func canonicalPath(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else { throw ScanError.metadata(path: path, error: errno) }
        defer { free(resolved) }
        return String(cString: resolved)
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

    public func retryCloudCompletion() {
        update.async { self.cloud?.retry() }
    }

    public func externalVolumeStatuses() -> [ExternalVolumeStatus] { mounts?.statuses() ?? [] }

    public func indexedEntryCount() -> Int {
        let local = lock.withLock { view }
        return (local?.entryCount ?? 0) + (mounts?.searchable().reduce(0) { $0 + $1.tracker.indexedEntryCount() } ?? 0)
    }

    func cancelExternalWork() {
        lock.withLock { externalCancelled = true; view = nil }
    }

    private var detached: Bool { external != nil && lock.withLock { externalCancelled } }


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
        let volumes = mounts?.searchable() ?? []
        if volumes.isEmpty {
            return captured?.search(query, mode: mode, column: column, direction: direction,
                                    showAll: showAll, offset: offset, limit: limit) ?? []
        }
        guard offset >= 0, limit > 0, offset <= Int.max - limit else { return [] }
        let capacity = offset + limit
        var groups: [[SearchRow]] = []
        groups.append(captured?.search(query, mode: mode, column: column, direction: direction,
                                       showAll: showAll, offset: 0, limit: capacity) ?? [])
        for volume in volumes {
            groups.append(volume.tracker.search(query, mode: mode, column: column, direction: direction,
                                                 showAll: showAll, limit: capacity).map {
                SearchRow(id: $0.id, name: $0.name, path: $0.path,
                          size: $0.size, modified: $0.modified, volumeID: volume.key)
            })
        }
        let rows = groups.enumerated().flatMap { group, rows in rows.map { (group, $0) } }.sorted { lhs, rhs in
            let order = compareAcross(lhs.1, rhs.1, column: column)
            return order == 0 ? lhs.0 < rhs.0 : (direction == .ascending ? order < 0 : order > 0)
        }
        return rows.lazy.filter { $0.0 == 0 || self.mounts?.isCurrent(volumes[$0.0 - 1]) == true }
            .dropFirst(offset).prefix(limit).map { $0.1 }
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
            guard !externalCancelled else { return }
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
            guard !detached else { return }
            if !externalPersistence {
                throw CocoaError(.fileReadNoSuchFile)
            }
            var value = try SearchIndex.load(from: path)
            let archivedRoot = external == nil ? root : value.tracking?.root ?? value.volumes.first?.root ?? root
            let identityMatches = identities.allSatisfy { volume in
                value.volumes.contains {
                    if external == nil { return $0.root == volume.root && $0.volumeUUID == volume.uuid }
                    return $0.root == archivedRoot && volume.uuid != nil && $0.volumeUUID == volume.uuid &&
                        volume.log != nil && $0.eventLogUUID == volume.log && $0.readOnly == volume.readOnly
                }
            }
            if identityMatches && (value.tracking?.root == archivedRoot || value.tracking == nil && hasRoot(value, at: archivedRoot)) {
                if value.loadedPrepared {
                    var loadedJournal = ChangeJournal(snapshot: path, identity: try SearchIndex.preparedIdentity(at: path))
                    try loadedJournal.restore(into: &value, root: archivedRoot)
                    journal = loadedJournal
                    lock.withLock {
                        status.journalLength = loadedJournal.length
                        status.journalRecovery = loadedJournal.repair
                        status.journalRestoredFrames = loadedJournal.restoredFrames
                    }
                } else {
                    needsBaseWrite = true
                }
                if external != nil && !identities[0].permitsReplay(value.volumes.first) {
                    reason = "invalid-checkpoint"
                } else {
                    if archivedRoot != root {
                        value = try value.movedVolume(from: archivedRoot, to: root)
                        needsBaseWrite = true
                    }
                    loaded = value
                    reason = "replay"
                }
            } else { reason = "scope-changed" }
        } catch SnapshotError.invalid { reason = "corrupt" }
        catch SnapshotError.unsupportedVersion { reason = "unsupported-version" }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {}
        firstBaseWrite = reason == "missing" || external != nil && needsBaseWrite
        lock.withLock { status.automaticBaseWritesInWindow = budget.count(at: wallTime()) }
        let previous = loaded?.volumes ?? []
        var reset = Set<Int>()
        cursors = identities.enumerated().map { i, volume in
            let prior = external != nil ? previous.first : previous.first { $0.root == volume.root }
            if volume.readOnly && external == nil { return EventCursor(applied: nil) }
            if loaded != nil && volume.permitsReplay(prior) {
                needsReplay.insert(i)
                return EventCursor(applied: prior?.appliedEvent, replaying: true)
            }
            reset.insert(i)
            return newCursor(for: volume)
        }
        for i in identities.indices where external != nil || !identities[i].readOnly {
            try watch(i)
            if external != nil && directoryEvents {
                reset.insert(i)
                if loaded != nil { reason = "directory-events" }
                loaded = nil
            }
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
            if let cloud {
                validated.purgeProviderTrash(in: scope.clouds)
                cloud.replacePending(validated.pendingCloudDirectories(in: scope.clouds))
            }
            publish(validated, changed: true)
            scheduleSave()
            lock.withLock { status.recovery = reset.isEmpty ? reason : "invalid-checkpoint" }
            note("ready")
        }
        let needsInitialScan = loaded == nil
        loaded = nil
        if needsInitialScan || !reset.isEmpty {
            if needsInitialScan {
                try rebuild(reset, initial: true, reason: reason)
            } else {
                try recover(reset, reason: "invalid-checkpoint")
            }
        } else if !reopened.isEmpty {
            try applyCoverage(at: reopened)
        }
        for stream in sources.values { stream.flush() }
        update.async {
            self.drain()
            self.finishReplayIfReady()
        }
    }

    private func newCursor(for volume: VolumeIdentity) -> EventCursor {
        // External media receives no marker file. The observed pre-scan
        // boundary is safe after the scan and may cause overlap on replay.
        if external != nil {
            return EventCursor(applied: directoryEvents ? nil : volume.observedBoundary())
        }
        return EventCursor(applied: nil, scanBaseline: volume.scanReplayBaseline())
    }

    private func hasRoot(_ value: SearchIndex, at root: String) -> Bool {
        guard let i = value.records.firstIndex(where: { $0.parent == .max }) else { return false }
        return value.name(UInt32(i)) == root
    }

    private func watch(_ volume: Int) throws {
        sources[volume]?.stop()
        let epoch = lock.withLock {
            epochs[volume] += 1
            batches.removeAll { $0.volume == volume }
            status.bufferedEvents = batches.reduce(0) { $0 + $1.events.count }
            invalidations.removeValue(forKey: volume)
            activity.removeValue(forKey: volume)
            return epochs[volume]
        }
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
        func open(_ since: UInt64?, fileEvents: Bool) throws -> VolumeEventStream {
            try VolumeEventStream(volume: identities[volume], since: since, scope: relative, fileEvents: fileEvents) {
                [weak self] events in
                self?.receive(EventBatch(volume: volume, epoch: epoch, events: events), root: key)
            }
        }
        do {
            sources[volume] = try open(since, fileEvents: !directoryEvents)
        } catch {
            guard external != nil else { throw error }
            directoryEvents = true
            lock.withLock { status.slowVolume = true }
            needsReplay.remove(volume)
            cursors[volume] = newCursor(for: identities[volume])
            sources[volume] = try? open(nil, fileEvents: false)
        }
        if external != nil, sources[volume] == nil || directoryEvents && identities[volume].log == nil {
            startVolumePolling()
        }
    }

    private func startVolumePolling() {
        guard pollTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: update)
        timer.schedule(deadline: .now() + .seconds(600), repeating: .seconds(600), leeway: .seconds(15))
        timer.setEventHandler { [weak self] in
            guard let self, !self.detached else { return }
            do { try self.applyCoverage(at: [self.root], recursive: true) }
            catch { self.fail(error) }
        }
        pollTimer = timer
        timer.activate()
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

    private func receive(_ batch: EventBatch, root: String) {
        let wake = lock.withLock {
            guard !externalCancelled, batch.epoch == epochs[batch.volume] else { return false }
            let now = DispatchTime.now().uptimeNanoseconds
            activity[batch.volume, default: EventActivity()].received(batch.events.count, at: now)
            status.receivedEvents += UInt64(batch.events.count)
            var lastInvalid: VolumeEvent?
            var high: UInt64?
            for event in batch.events {
                if !event.historyDone { high = max(high ?? 0, event.id) }
                if event.invalidPosition { lastInvalid = event }
                if event.dropped {
                    status.droppedEvents += 1
                    if receivingRecovery { status.droppedDuringRecovery += 1 }
                    status.lastDroppedAtUptimeNanoseconds = now
                    status.lastDroppedEventID = event.id
                    status.lastDroppedFlags = event.flags
                }
            }
            if status.firstCallbackPosition[root] == nil { status.firstCallbackPosition[root] = high }
            if let lastInvalid {
                invalidations[batch.volume] = invalidations[batch.volume] ?? now
                status.invalidEvidence = "batch=\(high ?? 0) flags=\(lastInvalid.flags)"
            }
            if status.bufferedEvents + batch.events.count > Self.pendingLimit {
                invalidations[batch.volume] = invalidations[batch.volume] ?? now
                if lastInvalid == nil { status.invalidEvidence = "event-inbox-overflow" }
            } else {
                batches.append(batch)
                status.bufferedEvents += batch.events.count
            }
            guard !applyScheduled else { return false }
            applyScheduled = true
            return true
        }
        if wake {
            update.asyncAfter(deadline: .now() + .milliseconds(800)) { [weak self] in
                guard let self else { return }
                self.lock.withLock { self.applyScheduled = false }
                self.drain()
            }
        }
    }

    private func takeEvents() -> ([EventBatch], [Int: UInt64]) {
        lock.withLock {
            let available = (batches, invalidations)
            batches.removeAll(keepingCapacity: true)
            invalidations.removeAll(keepingCapacity: true)
            status.bufferedEvents = 0
            return available
        }
    }

    private var inboxEmpty: Bool {
        lock.withLock { batches.isEmpty && invalidations.isEmpty }
    }

    func logicalPath(_ raw: String, volume: Int) -> String? {
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

    private func dirtyPaths(from events: [EventBatch], now: UInt64)
        -> ([String: DirectoryUpdate], [Int: UInt64], Set<Int>) {
        var work: [String: DirectoryUpdate] = [:]
        var high: [Int: UInt64] = [:]
        var crossed = Set<Int>()
        var late: UInt64 = 0
        var maximum: UInt64 = 0

        func mark(_ path: String, event: VolumeEvent, volume: Int, recursive: Bool? = nil,
                  file: String? = nil, metadata: Bool = false) {
            var item = work.removeValue(forKey: path) ?? DirectoryUpdate()
            item.add(event: event.id, volume: volume)
            if let recursive {
                item.recursive = item.recursive == true || recursive
                item.files.removeAll()
            } else if item.recursive == nil {
                if let file { item.files[file] = item.files[file] == true || event.structural }
                item.metadata = item.metadata || metadata
            }
            work[path] = item
        }

        for batch in events {
            let volume = batch.volume
            let valid = batch.events.contains(where: \.invalidPosition)
                ? batch.events.filter { !$0.invalidPosition } : batch.events
            let before = cursors[volume].outOfOrderBatches
            _ = cursors[volume].receivedBatch(valid)
            late += cursors[volume].outOfOrderBatches - before
            maximum = max(maximum, cursors[volume].maximumRegression)
            for event in valid {
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
                    cloud?.invalidate(at: path)
                } else if event.isDirectory {
                    if event.structural {
                        cloud?.invalidate(at: path)
                        cloud?.invalidateListing(at: parentPath(path))
                    }
                } else {
                    cloud?.invalidateListing(at: parentPath(path))
                }
                if event.recursive {
                    mark(path, event: event, volume: volume, recursive: true)
                } else if directoryEvents {
                    mark(path, event: event, volume: volume, recursive: false)
                } else if event.isDirectory || path == root {
                    if event.structural && path != root {
                        mark(parentPath(path), event: event, volume: volume, recursive: false)
                        mark(path, event: event, volume: volume, recursive: true)
                    } else {
                        mark(path, event: event, volume: volume, metadata: true)
                    }
                } else if event.contentOnly {
                    fileContents.enqueue(path, event: event.id, volume: volume, now: now)
                } else {
                    mark(parentPath(path), event: event, volume: volume, file: path)
                }
            }
        }
        if late > 0 {
            lock.withLock {
                status.outOfOrderBatches += late
                status.maximumEventRegression = max(status.maximumEventRegression, maximum)
            }
        }
        return (work, high, crossed)
    }

    private func scheduleDirectoryWake() {
        let next = [directories.next, fileContents.next].compactMap { $0 }.min()
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
        guard !closed, !detached, !paused, current != nil, snapshotStatus().error == nil,
              !inboxEmpty || directories.count > 0 || fileContents.count > 0 else { return }
        if !force, duringCompaction != nil, (current?.state.changes.count ?? 0) >= 2 * Self.compactionRows,
           lock.withLock({ invalidations.isEmpty }) { return }
        let (submitted, invalid) = takeEvents()
        let now = DispatchTime.now().uptimeNanoseconds
        guard requestRecovery(invalid) else { return }
        let (observations, high, crossed) = dirtyPaths(from: submitted, now: now)
        let immediate = force || !needsReplay.isEmpty || !scanBarriers.isEmpty
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
        if !immediate, directories.pendingItems + fileContents.count > Self.pendingLimit {
            let volumes = directories.pendingVolumes.union(fileContents.pendingVolumes)
            guard requestRecovery(Dictionary(uniqueKeysWithValues: volumes.map { ($0, now) })) else { return }
            directories.discard(volumes: volumes)
            fileContents.discard(volumes: volumes)
        }
        for (volume, id) in high { deliveredHigh[volume] = max(deliveredHigh[volume] ?? 0, id) }
        let ready = directories.take(at: now, force: immediate)
        var files = Dictionary(uniqueKeysWithValues: fileContents.take(at: now, force: immediate).map { ($0, false) })
        var work: [String: Bool] = [:]
        var metadata = Set<String>()
        for (path, item) in ready {
            work[path] = item.recursive
            if item.metadata { metadata.insert(path) }
            files.merge(item.files) { $0 || $1 }
        }
        let directoriesToVerify = metadata
        if (!work.isEmpty || !files.isEmpty || !metadata.isEmpty), var updated = current {
            current = nil
            let start = DispatchTime.now().uptimeNanoseconds
            lock.withLock { status.applying = true; status.lastApplyStart = start }
            do {
                var work = work
                var direct: UInt64 = 0
                var directDirectories: UInt64 = 0
                for (path, structural) in files {
                    let parent = parentPath(path)
                    fileContents.observed(path, at: now)
                    if work[parent] != nil { continue }
                    if updated.refreshFile(path, observation: { scope.observeEntry(path, inherited: $0) }) {
                        direct += 1
                        if structural { metadata.insert(parent) }
                    } else {
                        let target = observationAncestor(parent, in: &updated)
                        if work[target] == nil { work[target] = false }
                    }
                }
                for folder in metadata where work[folder] == nil {
                    let verifyAccess = directoriesToVerify.contains(folder)
                    if folder == root && !verifyAccess { continue }
                    if updated.refreshDirectory(folder, observation: { scope.observeEntry(folder, inherited: $0, verifyAccess: verifyAccess) }) {
                        if folder != root { directDirectories += 1 }
                    } else {
                        let target = observationAncestor(folder, in: &updated)
                        if work[target] == nil { work[target] = false }
                    }
                }
                try reconcile(work, in: &updated)
                updated.prepareDelta()
                acknowledgeReadyEvents()
                publish(updated, changed: true)
                recordDuringCompaction(work)
                if duringCompaction != nil {
                    for path in files.keys {
                        let parent = parentPath(path)
                        if duringCompaction?[parent] == nil { duringCompaction?[parent] = false }
                    }
                    recordDuringCompaction(Dictionary(uniqueKeysWithValues: metadata.map { ($0, false) }))
                }
                let end = DispatchTime.now().uptimeNanoseconds
                lock.withLock {
                    status.applying = false
                    status.lastApplyEnd = end
                    status.appliedBatches += 1
                    status.directFilesObserved += direct
                    status.directDirectoriesObserved += directDirectories
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
        lock.withLock { status.deferredDirectories = directories.count }
        scheduleDirectoryWake()
        if work.isEmpty, files.isEmpty, metadata.isEmpty {
            acknowledgeReadyEvents()
            lock.withLock { status.appliedEvents = positions() }
        }
        for i in crossed { scanBarriers.removeValue(forKey: i) }
        if !force {
            finishReplayIfReady()
            scheduleRecovery()
        }
    }

    private func observationAncestor(_ path: String, in index: inout LiveIndex) -> String {
        var directory = path
        while directory != root && index.entry(at: directory)?.directory != true {
            directory = parentPath(directory)
        }
        return directory
    }

    private func pendingFloors() -> [Int: UInt64] {
        directories.floors().merging(fileContents.floors(), uniquingKeysWith: min)
    }

    private func acknowledgeReadyEvents() {
        let floors = pendingFloors()
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
            if detached { throw CancellationError() }
            let folder = ordered[position]
            position += 1
            guard inside(folder, root), !excluded.contains(where: { inside(folder, $0) }),
                  visited.insert(folder).inserted else { continue }
            let inherited = index.entry(at: folder)?.attribute ?? 0
            observedDirectories += 1
            let inCloud = scope.clouds.provider(containing: folder) != nil
            let observed: DirectoryObservation
            do { observed = try scope.observe(folder, inherited: inherited, excluding: excluded) }
            catch where inCloud { observed = .pending }
            var more = index.reconcile(path: folder, observed: observed)
            if inCloud {
                switch observed {
                case .absent, .restricted: cloud?.discard(at: folder)
                case .pending: cloud?.enqueue(folder, inherited: inherited)
                case .deferred: break
                case .readable:
                    cloud?.invalidate(at: folder)
                    if inherited & Kind.pending != 0 { index.clearCloudPending(at: folder); cloud?.discardOnly(folder) }
                }
            }
            if case let .readable(_, contents) = observed {
                enqueueCloudChildren(of: folder, contents: contents, in: &index)
            }
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

    private func enqueueCloudChildren(of folder: String, contents: [String: TrackedEntry],
                                      in index: inout LiveIndex) {
        guard let cloud else { return }
        for (name, entry) in contents where entry.directory {
            let path = joinedPath(folder, name)
            if entry.attribute & Kind.pending != 0 ||
                scope.clouds.provider(containing: folder) != nil && index.entry(at: path).map({
                    $0.attribute & Kind.pending != 0
                }) == true {
                cloud.enqueue(path, inherited: entry.attribute)
            }
        }
    }

    private func applyCloud(_ path: String, _ result: DirectoryObservation) -> Bool {
        guard !closed, !recoveryUnresolved, var revised = current else { return false }
        guard revised.entry(at: path).map({ $0.directory && $0.attribute & Kind.pending != 0 }) == true,
              !revised.state.restricted.contains(where: { $0 != path && inside(path, $0) }) else {
            cloud?.discardOnly(path)
            return false
        }
        switch result {
        case let .readable(_, children):
            _ = revised.reconcile(path: path, observed: result, completingCloud: true)
            enqueueCloudChildren(of: path, contents: children, in: &revised)
        case .absent:
            _ = revised.reconcile(path: path, observed: .absent)
            cloud?.discard(at: path)
        case .pending, .deferred, .restricted:
            return false
        }
        revised.prepareDelta()
        publish(revised, changed: true)
        if duringCompaction != nil { cloudChangedDuringCompaction = true }
        scheduleSave()
        return true
    }

    private func releaseTemporaryPages() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastAllocatorRelief >= 10_000_000_000 else { return }
        lastAllocatorRelief = now
        update.async { dm_release_allocator_cache() }
    }

    private func requestRecovery(_ invalid: [Int: UInt64]) -> Bool {
        guard !invalid.isEmpty else { return true }
        cloud?.setEnabled(false)
        do { try revokeCheckpoints(for: invalid.keys.map { identities[$0].root }) }
        catch { fail(error); return false }
        for (volume, received) in invalid {
            pendingRecovery[volume] = pendingRecovery[volume] ?? received
            deliveredHigh.removeValue(forKey: volume)
            needsReplay.remove(volume)
            scanBarriers.removeValue(forKey: volume)
            cursors[volume] = EventCursor(applied: nil)
        }
        lock.withLock {
            status.indexReconciling = true
            status.appliedEvents = positions()
        }
        if !recoveryInProgress, snapshotStatus().phase != "recovery-pending" {
            scheduleRecovery()
            note("recovery-pending")
        }
        return true
    }

    private func recoveryDeadlines() -> [Int: UInt64] {
        lock.withLock {
            pendingRecovery.reduce(into: [:]) { deadlines, entry in
                deadlines[entry.key] = (activity[entry.key] ?? EventActivity()).deadline(
                    since: entry.value, lastStart: lastRecoveryStart, timing: recoveryTiming)
            }
        }
    }

    private func scheduleRecovery() {
        guard !closed, snapshotStatus().error == nil, !recoveryInProgress, !paused,
              let deadline = recoveryDeadlines().values.min() else {
            recoveryTimer?.schedule(deadline: .distantFuture)
            return
        }

        let now = DispatchTime.now().uptimeNanoseconds
        let eta = Date().timeIntervalSince1970 + Double(deadline > now ? deadline - now : 0) / Double(ReplayLag.second)
        lock.withLock { status.nextRecoveryAt = eta }
        // The in-flight compactor will wake recovery after it releases its base.
        guard duringCompaction == nil else {
            recoveryTimer?.schedule(deadline: .distantFuture)
            return
        }

        if recoveryTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: update)
            timer.setEventHandler { [weak self] in self?.recoverWhenReady() }
            recoveryTimer = timer
            timer.activate()
        }
        recoveryTimer?.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline))
    }

    private func recoverWhenReady() {
        guard !closed, !detached, !paused, !recoveryInProgress, duringCompaction == nil,
              snapshotStatus().error == nil else { return }
        drain()
        guard snapshotStatus().error == nil else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let due = Set(recoveryDeadlines().filter { $0.value <= now }.keys)
        if !due.isEmpty {
            do { try recover(due, reason: "history-invalid") }
            catch { fail(error) }
        }
        scheduleRecovery()
    }

    private func recover(_ affected: Set<Int>, reason: String) throws {
        recoveryInProgress = true
        cloud?.setEnabled(false)
        defer {
            recoveryInProgress = false
            lock.withLock { receivingRecovery = false }
        }
        for i in affected {
            // Retire the old stream before scanning. Work it already delivered
            // is covered by this scan. Only the new stream can request another.
            pendingRecovery.removeValue(forKey: i)
            directories.discard(volumes: [i])
            fileContents.discard(volumes: [i])
            deliveredHigh.removeValue(forKey: i)
            identities[i] = try VolumeIdentity(root: identities[i].root)
            cursors[i] = newCursor(for: identities[i])
            needsReplay.remove(i)
            if external != nil || !identities[i].readOnly { try watch(i) }
        }
        let start = DispatchTime.now().uptimeNanoseconds
        lastRecoveryStart = start
        lock.withLock {
            receivingRecovery = true
            status.indexReconciling = true
            status.nextRecoveryAt = nil
            status.rebuilds += 1
            status.recoveries += 1
            status.appliedEvents = positions()
        }
        try rebuild(affected, initial: false, reason: reason)
        // The writer was occupied by scanning. Process already delivered loss
        // notices before reporting that recovery has finished.
        for i in affected { sources[i]?.flush() }
        let end = DispatchTime.now().uptimeNanoseconds
        lock.withLock {
            receivingRecovery = false
            status.lastRecoveryNanoseconds = end - start
        }
        drain()
        for i in affected where pendingRecovery[i] != nil { pendingRecovery[i] = end }
        recoveryInProgress = false
        scheduleRecovery()
        if !pendingRecovery.isEmpty, snapshotStatus().error == nil { note("recovery-pending") }
        finishReplayIfReady()
    }

    private func rebuild(_ affected: Set<Int>, initial: Bool, reason: String) throws {
        compactionToken += 1
        duringCompaction = nil
        lock.withLock {
            status.recovery = reason
            status.compacting = false
        }
        note("scan-start")
        var index: SearchIndex
        if !initial, root == "/", !affected.contains(0), current != nil {
            let sealed = sealedVolume(from: current!.base, excluding: scope.dataVolumeRoots)
            // The published view still owns the old rows. The writer can
            // release its directory lookup structures during enumeration.
            current = nil
            dm_release_allocator_cache()
            index = try SearchIndex.scanDataVolume(keeping: consume sealed, excluding: Set(excluded))
        } else {
            var lastPartial: Double = 0
            index = try SearchIndex.scanForTracking(scope: scope, workers: external == nil ? 4 : 1,
                                                    excluding: Set(excluded), cancelled: { self.detached }) {
                mark, partial in
                if initial && (mark.phase == "partial" || mark.phase == "local_complete" ||
                               mark.phase == "batch" && mark.seconds >= lastPartial + 0.5) {
                    lastPartial = mark.seconds
                    self.publish(LiveIndex(base: partial, root: self.root, linkChildren: false), changed: true)
                }
                if initial && mark.phase == "partial" { self.note("scan-partial") }
            }
        }
        dm_release_allocator_cache()
        if initial || root != "/" { index.tightenScannedStorage() }
        else { index.prepare() }
        dm_release_allocator_cache()
        let rebuilt = LiveIndex(base: index, root: root)
        if let cloud { cloud.replacePending(rebuilt.pendingCloudDirectories(in: scope.clouds)) }
        publish(rebuilt, changed: true)
        if external == nil { try markScanBoundary(for: affected) }
        needsBaseWrite = externalPersistence && !directoryEvents
        note(initial ? "ready" : "rebuilt")
        update.async { dm_release_allocator_cache() }
    }

    private var recoveryUnresolved: Bool { recoveryInProgress || !pendingRecovery.isEmpty }

    private func finishReplayIfReady() {
        guard !closed, !detached, snapshotStatus().error == nil, !paused, inboxEmpty else { return }
        needsReplay = needsReplay.filter { !cursors[$0].historyDelivered }
        guard needsReplay.isEmpty, scanBarriers.isEmpty, !recoveryUnresolved else { return }
        let reconciling = snapshotStatus().indexReconciling
        if needsBaseWrite || reconciling {
            guard directories.count == 0, fileContents.count == 0 else { return }
            do { try persistPendingBase() }
            catch { fail(error); return }
        }
        let caughtUp = lock.withLock {
            // A new invalidation can arrive while the base is being saved.
            guard invalidations.isEmpty, status.phase != "caught-up" else { return false }
            status.indexReconciling = false
            status.nextRecoveryAt = nil
            status.phase = "caught-up"
            return true
        }
        if caughtUp {
            cloud?.setEnabled(true)
            mounts?.start()
            releaseTemporaryPages()
            observer?("caught-up")
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
        var pending = pendingFloors()
        let snapshot = lock.withLock { (batches, invalidations) }
        for batch in snapshot.0 {
            for event in batch.events where !event.historyDone && event.id != .max {
                pending[batch.volume] = min(pending[batch.volume] ?? .max, event.id)
            }
        }
        let now = DispatchTime.now().uptimeNanoseconds
        return identities.enumerated().map { i, volume in
            let observed = detached ? cursors[i].applied : volume.observedBoundary()
            let eligible = external == nil ? !volume.readOnly : !directoryEvents
            let safe = eligible && snapshot.1[i] == nil
                ? cursors[i].lag.position(at: now, observed: observed, pending: pending[i])
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
            guard !self.paused, self.inboxEmpty, self.directories.count == 0, self.fileContents.count == 0 else {
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
        guard needsBaseWrite, needsReplay.isEmpty, scanBarriers.isEmpty, !recoveryUnresolved, inboxEmpty else { return }
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

    /// Keep the last durable rows, but make a restart recheck a volume whose
    /// history is no longer trustworthy, even if recovery is still waiting.
    private func revokeCheckpoints(for volumes: [String]) throws {
        guard let durableImage else { return }
        var positions = durableImage.positions
        for volume in volumes { positions.removeValue(forKey: volume) }
        guard positions != durableImage.positions else { return }
        let frame = JournalFrame(rows: [], masks: [], coverage: [], positions: positions)
        guard try appendJournal(frame) else { return }
        self.durableImage = JournalImage(rows: durableImage.rows, masks: durableImage.masks,
                                         coverage: durableImage.coverage, positions: positions)
        lock.withLock {
            status.durableEvents = positions
            status.journalLength = journal?.length ?? 0
        }
    }

    private func appendJournal(_ frame: JournalFrame) throws -> Bool {
        guard var openJournal = journal else { return false }
        let written = try openJournal.append(frame)
        journal = openJournal
        lock.withLock {
            status.journalFrames += 1
            status.journalWrittenBytes += UInt64(written)
        }
        return true
    }

    private func flushJournal() throws {
        guard externalPersistence, !needsBaseWrite, !recoveryUnresolved, lock.withLock({ invalidations.isEmpty }),
              let current, journal != nil, let durableImage else {
            saveScheduled = false
            return
        }
        let image = current.journalImage(at: durablePositions(checkpoints()))
        if let frame = image.delta(after: durableImage) { _ = try appendJournal(frame) }
        didSave(image)
        scheduleCompaction()
    }

    public func save() throws {
        try update.sync { try flushJournal() }
        for volume in mounts?.searchable() ?? [] { try volume.tracker.save() }
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
        guard !closed, !detached, externalPersistence, !needsBaseWrite, !recoveryUnresolved, duringCompaction == nil,
              let original = current,
              original.state.changes.count >= Self.compactionRows || (journal?.length ?? 0) >= Self.compactionBytes
        else { return }
        guard allowAutomaticWrite() else { return }
        let token = compactionToken
        let started = DispatchTime.now().uptimeNanoseconds
        duringCompaction = [:]
        cloudChangedDuringCompaction = false
        lock.withLock { status.compacting = true }
        compactor.async { [weak self] in
            let base = original.compacted()
            guard let self else { return }
            self.update.async {
                guard !self.closed, self.compactionToken == token, let work = self.duringCompaction else { return }
                self.duringCompaction = nil
                if self.cloudChangedDuringCompaction || self.recoveryUnresolved || !self.lock.withLock({ self.invalidations.isEmpty }) {
                    self.lock.withLock { self.status.compacting = false }
                    // Schedule after this closure releases its candidate base.
                    self.update.async {
                        self.drain()
                        self.scheduleRecovery()
                    }
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
        mounts?.synchronize()
    }

    /// The application can request a metadata-only reconciliation of a scope
    /// after its existing access changes. Indeterminate access remains restricted.
    public func recheckCoverage(at paths: [String]) {
        update.async {
            do { try self.applyCoverage(at: paths) }
            catch { self.fail(error) }
        }
    }

    private func applyCoverage(at paths: [String], recursive: Bool = false) throws {
        guard !closed, !detached, var updated = current else { return }
        let work = paths.reduce(into: [String: Bool]()) { $0[$1] = recursive }
        try reconcile(work, in: &updated)
        updated.prepareDelta()
        publish(updated, changed: true)
        recordDuringCompaction(work)
        scheduleSave()
        scheduleCompaction()
    }

    public func stop() throws {
        try mounts?.stop()
        try update.sync {
            cloud?.stop()
            for stream in sources.values {
                if !detached { stream.flush() }
                stream.stop()
            }
            sources.removeAll()
            drain(force: true)
            closed = true
            directoryTimer?.cancel()
            directoryTimer = nil
            recoveryTimer?.cancel()
            recoveryTimer = nil
            pollTimer?.cancel()
            pollTimer = nil
            if snapshotStatus().error == nil {
                if needsBaseWrite && !detached { try persistPendingBase(onExit: true) }
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
            let received = lock.withLock { batches }
            return received.lazy.flatMap { batch in
                batch.events.lazy.filter { self.logicalPath($0.path, volume: batch.volume) == path }.map(\.id)
            }.max()
        }
    }

    // These are deterministic injection points for the owned-directory harness.
    public func holdUpdates(_ hold: Bool) {
        update.sync {
            paused = hold
            if !hold { drain() }
            scheduleRecovery()
        }
    }

    public func simulateDroppedHistory() {
        guard let volume = injectionVolume else { return }
        let epoch = lock.withLock { epochs[volume.index] }
        let flags = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped)
        let event = VolumeEvent(path: "", id: 0, flags: flags)
        receive(EventBatch(volume: volume.index, epoch: epoch, events: [event]), root: volume.root)
    }

    func deliverForTesting(_ events: [VolumeEvent], writing: () throws -> Void = {},
                           check: () -> Void = {}) rethrows {
        try update.sync {
            guard let i = identities.firstIndex(where: { !$0.readOnly }) else { return }
            try writing()
            receive(EventBatch(volume: i, epoch: epochs[i], events: events), root: identities[i].root)
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
