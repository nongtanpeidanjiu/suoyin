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
    public var coverageRestricted: [String] = []
    public var overlayRows = 0
    public var baseRecords = 0
    public var applying = false
    public var lastApplyStart: UInt64 = 0
    public var lastApplyEnd: UInt64 = 0
    public var invalidEvidence: String?
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
    private var view: LiveIndex?
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
    private var dirtySince: UInt64?
    private var saveTicket: UInt64 = 0
    private var closed = false
    private var observer: ((String) -> Void)?
    private var needsReplay: Set<Int> = []
    private var scanBarriers: [Int: ScanBoundary] = [:]
    private var applyTrace: [ApplyInterval]?

    public init(root: String, snapshot: String, ownData: String) throws {
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
        lock.withLock {
            view = updated
            if changed { status.generation += 1 }
            status.appliedEvents = positions()
            status.overlayRows = updated.state.changes.count
            status.baseRecords = updated.base.recordCount
            status.coverageRestricted = updated.state.restricted.sorted()
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
            let value = try SearchIndex.load(from: path)
            let identityMatches = identities.allSatisfy { volume in
                value.volumes.contains { $0.root == volume.root && $0.volumeUUID == volume.uuid }
            }
            if identityMatches && (value.tracking?.root == root || value.tracking == nil && hasRoot(value)) {
                loaded = value
                reason = "replay"
            } else { reason = "scope-changed" }
        } catch SnapshotError.invalid { reason = "corrupt" }
        catch SnapshotError.unsupportedVersion { reason = "unsupported-version" }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {}
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
            return EventCursor(applied: volume.observedBoundary())
        }
        for i in identities.indices where !identities[i].readOnly {
            try watch(i)
        }
        if var loaded {
            loaded.prepare()
            var validated = LiveIndex(base: loaded, root: root)
            validated.verifyStartupCoverage(at: scope.protectedStartupRoots) { folder in
                try? scope.observe(folder, inherited: 0, excluding: excluded)
            }
            publish(validated, changed: true)
            lock.withLock { status.recovery = reset.isEmpty ? reason : "invalid-checkpoint" }
            note("ready")
        }
        let needsInitialScan = loaded == nil
        loaded = nil
        if needsInitialScan || !reset.isEmpty {
            try rebuild(reset, initial: needsInitialScan, reason: needsInitialScan ? reason : "invalid-checkpoint")
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
        sources[volume] = try VolumeEventStream(volume: identities[volume], since: since) {
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
        guard !closed, batch.epoch == epochs[batch.volume] else { return }
        if pendingEvents + batch.events.count > 50_000 {
            overflowed.insert(batch.volume)
        } else {
            pendingEvents += batch.events.count
            batches.append(batch)
        }
        lock.withLock { status.bufferedEvents = pendingEvents }
        if applyScheduled { return }
        applyScheduled = true
        update.asyncAfter(deadline: .now() + .milliseconds(80)) {
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

    private func dirtyPaths(from events: [EventBatch]) -> ([String: Bool], [Int: UInt64], Set<Int>, Set<Int>) {
        var work: [String: Bool] = [:]
        var high: [Int: UInt64] = [:]
        var reset = overflowed
        var crossed = Set<Int>()
        for batch in events where batch.epoch == epochs[batch.volume] {
            let volume = batch.volume
            let prior = cursors[volume].lastSeen
            if !cursors[volume].receivedBatch(batch.events) {
                reset.insert(volume)
                let invalid = batch.events.first(where: { $0.invalidatesHistory || !$0.historyDone && $0.id == 0 })
                let latest = batch.events.filter { !$0.historyDone }.map(\.id).max()
                lock.withLock {
                    status.invalidEvidence = "batch=\(latest ?? 0) flags=\(invalid?.flags ?? 0) prior=\(prior ?? 0)"
                }
                continue
            }
            for event in batch.events {
                if event.historyDone { continue }
                guard let path = logicalPath(event.path, volume: volume) else {
                    reset.insert(volume)
                    continue
                }
                if scanBarriers[volume]?.covered(by: event, at: path) == true { crossed.insert(volume) }
                if excluded.contains(where: { inside(path, $0) }) || scope.insideProviderTrash(path) { continue }
                guard inside(path, root) else {
                    if event.recursive && inside(root, path) { work[root] = true }
                    continue
                }
                high[volume] = max(high[volume] ?? 0, event.id)
                if event.recursive { work[path] = true; continue }
                let folder = event.isDirectory && !event.structural ? path : parentPath(path)
                let target = inside(folder, root) ? folder : root
                work[target] = work[target] ?? false
                if event.isDirectory && event.structural && path != root {
                    work[path] = true
                }
            }
        }
        return (work, high, reset, crossed)
    }

    private func drain() {
        guard !closed, !paused, current != nil, snapshotStatus().error == nil,
              !batches.isEmpty || !overflowed.isEmpty else { return }
        let submitted = batches
        batches.removeAll(keepingCapacity: true)
        pendingEvents = 0
        lock.withLock { status.bufferedEvents = 0 }
        let before = cursors
        let (work, high, reset, crossed) = dirtyPaths(from: submitted)
        overflowed.removeAll()
        if !reset.isEmpty {
            lock.withLock { status.receivedEvents += UInt64(submitted.reduce(0) { $0 + $1.events.count }) }
            do {
                for i in reset {
                    identities[i] = try VolumeIdentity(root: identities[i].root)
                    cursors[i] = EventCursor(applied: identities[i].observedBoundary())
                    needsReplay.remove(i)
                    if !identities[i].readOnly { try watch(i) }
                }
                try rebuild(reset, initial: false, reason: "history-invalid")
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
        if !work.isEmpty, var updated = current {
            let start = DispatchTime.now().uptimeNanoseconds
            lock.withLock { status.applying = true; status.lastApplyStart = start }
            do {
                try reconcile(work, in: &updated)
                updated.prepareDelta()
                for (i, top) in high { cursors[i].acknowledge(top) }
                publish(updated, changed: true)
                let end = DispatchTime.now().uptimeNanoseconds
                lock.withLock {
                    status.applying = false
                    status.lastApplyEnd = end
                    status.appliedBatches += 1
                }
                applyTrace?.append(ApplyInterval(start: start, end: end))
                scheduleSave()
            } catch {
                lock.withLock { status.applying = false }
                fail(error)
            }
        }
        for i in crossed { scanBarriers.removeValue(forKey: i) }
        finishReplayIfReady()
    }

    private func reconcile(_ initial: [String: Bool], in index: inout LiveIndex) throws {
        var work = initial
        var visited: Set<String> = []
        var ordered = work.keys.sorted { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }
        var position = 0
        while position < ordered.count {
            let folder = ordered[position]
            position += 1
            guard inside(folder, root), !excluded.contains(where: { inside(folder, $0) }),
                  visited.insert(folder).inserted else { continue }
            let inherited = index.entry(at: folder)?.attribute ?? 0
            let observed = try scope.observe(folder, inherited: inherited, excluding: excluded)
            var more = index.reconcile(path: folder, observed: observed)
            if work[folder] == true, case let .readable(_, contents) = observed {
                for (name, entry) in contents where entry.directory && entry.attribute & Kind.pending == 0 {
                    let child = joinedPath(folder, name)
                    work[child] = true
                    more.append(child)
                }
            }
            ordered.append(contentsOf: more)
        }
    }

    private func rebuild(_ affected: Set<Int>, initial: Bool, reason: String) throws {
        lock.withLock { status.recovery = reason }
        note("scan-start")
        var index: SearchIndex
        if !initial, root == "/", !affected.contains(0), current != nil {
            retainSealedVolume()
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
        index.prepare()
        publish(LiveIndex(base: index, root: root), changed: true)
        try markScanBoundary(for: affected)
        note(initial ? "ready" : "rebuilt")
        update.async { dm_release_allocator_cache() }
        scheduleSave()
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
        if needsReplay.isEmpty && scanBarriers.isEmpty && snapshotStatus().phase != "caught-up" { note("caught-up") }
    }

    private func scheduleSave() {
        let now = DispatchTime.now().uptimeNanoseconds
        if dirtySince == nil { dirtySince = now }
        let deadline = min(dirtySince! + 15_000_000_000, now + 2_000_000_000)
        saveTicket += 1
        let ticket = saveTicket
        update.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline)) {
            guard !self.closed, self.saveTicket == ticket, self.snapshotStatus().error == nil else { return }
            do { try self.persist() } catch { self.fail(error) }
        }
    }

    private func persist(beforeReplace: (() throws -> Void)? = nil) throws {
        guard let current else { return }
        var archive = current.archive()
        archive.volumes = zip(identities, cursors).map { volume, cursor in
            // The daemon may have delivered newer IDs than are presently in
            // its disk journal. Replay from the conservative processed prefix.
            let durable = cursor.applied.flatMap { applied in
                volume.observedBoundary().map { min($0, applied) }
            }
            return volume.checkpoint(durable)
        }
        try archive.savePrepared(to: path, beforeReplace: beforeReplace)
        let durable = Dictionary(uniqueKeysWithValues: archive.volumes.compactMap { volume in
            volume.appliedEvent.map { (volume.root, $0) }
        })
        lock.withLock {
            status.durableEvents = durable
            status.durableGeneration = status.generation
        }
        dirtySince = nil
        saveTicket += 1
    }

    public func save(beforeReplace: (() throws -> Void)? = nil) throws {
        try update.sync { try persist(beforeReplace: beforeReplace) }
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
            guard !self.closed, var updated = self.current else { return }
            let work = paths.reduce(into: [String: Bool]()) { $0[$1] = false }
            do {
                try self.reconcile(work, in: &updated)
                updated.prepareDelta()
                self.publish(updated, changed: true)
                self.scheduleSave()
            } catch { self.fail(error) }
        }
    }

    public func stop() throws {
        synchronize()
        try update.sync {
            for stream in sources.values { stream.stop() }
            sources.removeAll()
            closed = true
            if snapshotStatus().error == nil { try persist() }
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

    func injectPermissionObservation(_ path: String, _ observation: DirectoryObservation) {
        update.sync {
            guard var index = current else { return }
            _ = index.reconcile(path: path, observed: observation)
            index.prepareDelta()
            publish(index, changed: true)
        }
    }
}
