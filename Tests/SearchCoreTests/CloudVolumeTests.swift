import Foundation
import Testing
@testable import SearchCore

@Suite(.serialized)
struct CloudVolumeTests {
    private let folder = TrackedEntry(size: 0, modified: 0, attribute: Kind.directory)
    private let file = TrackedEntry(size: 6, modified: 7, attribute: Kind.file)

    private func until(seconds: TimeInterval = 4, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    private func scratch() throws -> URL {
        let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".m2-tmp/test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path.resolvingSymlinksInPath()
    }

    @Test func cloudQueueTimesOutWithoutReleasingTheSingleSlot() throws {
        let writer = DispatchQueue(label: "test.cloud-writer")
        let roots = CloudRoots(home: "/test")
        let provider = roots.storage! + "/Provider"
        let first = provider + "/a"
        let second = provider + "/b"
        let lock = NSLock()
        let release = DispatchSemaphore(value: 0)
        var calls: [(String, UInt64)] = []
        var completed: [String] = []
        var status = CloudCompletionStatus()
        let own = folder
        let queue = CloudCompletion(writer: writer, roots: roots,
                                    timing: .init(timeout: 45_000_000, spacing: 200_000_000,
                                                  firstRetry: 5_000_000_000, maximumRetry: 10_000_000_000),
                                    monitorNetwork: false) { path, _ in
            lock.withLock { calls.append((path, DispatchTime.now().uptimeNanoseconds)) }
            if path == first { _ = release.wait(timeout: .now() + .seconds(3)) }
            return .readable(own: own, children: [:])
        }
        defer { writer.sync { queue.stop() } }
        writer.sync {
            queue.changed = { status = $0 }
            queue.apply = { path, _ in completed.append(path); return true }
            queue.enqueue(first, inherited: Kind.pending)
            queue.enqueue(second, inherited: Kind.pending)
            queue.enqueue(provider + "/.Trash/old", inherited: Kind.pending)
            queue.setEnabled(true)
        }
        #expect(until { writer.sync { status.timedOut == 1 && status.inFlight && status.pending == 2 } })
        #expect(lock.withLock { calls.map { $0.0 } } == [first])
        let releaseTime = DispatchTime.now().uptimeNanoseconds
        release.signal()
        #expect(until { writer.sync { status.completed == 1 && !status.inFlight } })
        #expect(writer.sync { completed } == [second])
        let observed = lock.withLock { calls }
        #expect(observed.map { $0.0 } == [first, second])
        #expect(try #require(observed.last?.1) >= releaseTime + 200_000_000)
    }

    @Test func changedCloudDirectoryRejectsItsOldListing() throws {
        let writer = DispatchQueue(label: "test.cloud-invalidation")
        let roots = CloudRoots(home: "/test")
        let path = roots.storage! + "/Provider/dir"
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        let own = folder
        let item = file
        var calls = 0
        var published: [String] = []
        let queue = CloudCompletion(writer: writer, roots: roots,
                                    timing: .init(timeout: 2_000_000_000, spacing: 5_000_000),
                                    monitorNetwork: false) { _, _ in
            let first = lock.withLock { calls += 1; return calls == 1 }
            if first {
                entered.signal()
                _ = release.wait(timeout: .now() + .seconds(1))
            }
            return .readable(own: own, children: [first ? "old" : "new": item])
        }
        defer { writer.sync { queue.stop() } }
        writer.sync {
            queue.apply = { _, observation in
                guard case let .readable(_, children) = observation else { return false }
                published.append(contentsOf: children.keys)
                return true
            }
            queue.enqueue(path, inherited: Kind.directory | Kind.pending)
            queue.setEnabled(true)
        }
        #expect(entered.wait(timeout: .now() + .seconds(1)) == .success)
        writer.sync { queue.invalidateListing(at: path) }
        release.signal()
        #expect(until { writer.sync { published == ["new"] } })
        #expect(lock.withLock { calls } == 2)
    }

    @Test func cloudRetryWaitsForBackoffAndCanWakeOnNetworkOrRequest() {
        let writer = DispatchQueue(label: "test.cloud-retry")
        let roots = CloudRoots(home: "/test")
        let path = roots.storage! + "/AnyProvider/folder"
        let lock = NSLock()
        var calls: [UInt64] = []
        var status = CloudCompletionStatus()
        let queue = CloudCompletion(writer: writer, roots: roots,
                                    timing: .init(timeout: 1_000_000_000, spacing: 0,
                                                  firstRetry: 100_000_000, maximumRetry: 200_000_000),
                                    monitorNetwork: false) { _, _ in
            lock.withLock { calls.append(DispatchTime.now().uptimeNanoseconds) }
            throw CocoaError(.fileReadUnknown)
        }
        defer { writer.sync { queue.stop() } }
        writer.sync {
            queue.changed = { status = $0 }
            queue.enqueue(path, inherited: Kind.pending)
            queue.setEnabled(true)
        }
        #expect(until { writer.sync { status.totalFailures >= 3 } })
        let times = lock.withLock { calls }
        #expect(times.count >= 3)
        if times.count >= 3 {
            #expect(times[1] - times[0] >= 100_000_000)
            #expect(times[2] - times[1] >= 200_000_000)
        }
        writer.sync { queue.setNetworkAvailable(false); queue.retry() }
        let offline = writer.sync { status.totalFailures }
        Thread.sleep(forTimeInterval: 0.04)
        #expect(writer.sync { status.totalFailures } == offline)
        writer.sync { queue.setNetworkAvailable(true) }
        #expect(until(seconds: 0.15) { writer.sync { status.totalFailures > offline } })
        let recovered = writer.sync { status.totalFailures }
        writer.sync { queue.retry() }
        #expect(until(seconds: 0.15) { writer.sync { status.totalFailures > recovered } })
    }

    @Test func cloudCompletionPersistsSuccessAndRestartsOutstandingDirectories() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let own = root.appendingPathComponent("state")
        let roots = CloudRoots(home: root.path)
        let provider = URL(fileURLWithPath: roots.storage!).appendingPathComponent("ExampleProvider")
        let a = provider.appendingPathComponent("a")
        let b = provider.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        // Provider metadata below is injected. Keeping its simulated tree off
        // disk prevents the real event stream from observing fixture writes.
        let identity = try VolumeIdentity(root: root.path)
        let checkpoint = try #require(identity.observedBoundary())
        var base = SearchIndex()
        let baseRoot = base.append(root.path, attribute: Kind.anchor)
        let library = base.append("Library", parent: baseRoot, attribute: Kind.directory)
        let storage = base.append("CloudStorage", parent: library, attribute: Kind.directory)
        let rootID = base.append("ExampleProvider", parent: storage, attribute: Kind.directory)
        base.append("a", parent: rootID, attribute: Kind.directory | Kind.pending)
        base.append("b", parent: rootID, attribute: Kind.directory | Kind.pending)
        let deleted = base.append(".Trash", parent: rootID, attribute: Kind.directory | Kind.pending)
        base.append("stale-recycle.txt", parent: deleted)
        base.volumes = [identity.checkpoint(checkpoint)]
        base.prepare()
        let snapshot = own.appendingPathComponent("index").path
        try base.savePrepared(to: snapshot)
        let timing = CloudCompletion.Timing(timeout: 1_000_000_000, spacing: 10_000_000,
                                            firstRetry: 60_000_000_000, maximumRetry: 60_000_000_000)
        let first = try ChangeTracker(root: root.path, snapshot: snapshot, ownData: own.path,
                                      wallTime: { Date().timeIntervalSince1970 }, cloudRoots: roots, cloudTiming: timing,
                                      cloudReader: { path, _ in
            guard path == a.path else { throw CocoaError(.fileReadUnknown) }
            return .readable(own: folder, children: ["first-metadata.txt": file])
        })
        first.start()
        #expect(until {
            let status = first.snapshotStatus().cloud
            return status.completed == 1 && status.totalFailures >= 1 && status.pending == 1
        })
        #expect(first.snapshotStatus().cloud.pending == 1)
        #expect(first.search("first-metadata").count == 1)
        #expect(first.search("stale-recycle", showAll: true).isEmpty)
        try first.save()
        #expect(first.snapshotStatus().journalFrames > 0)
        try first.stop()

        let lock = NSLock()
        var calls: [String] = []
        let second = try ChangeTracker(root: root.path, snapshot: snapshot, ownData: own.path,
                                       wallTime: { Date().timeIntervalSince1970 }, cloudRoots: roots, cloudTiming: timing,
                                       cloudReader: { path, _ in
            lock.withLock { calls.append(path) }
            return .readable(own: folder, children: ["second-metadata.txt": file])
        })
        defer { try? second.stop() }
        second.start()
        #expect(until { second.snapshotStatus().cloud.completed == 1 })
        #expect(second.search("first-metadata").count == 1)
        #expect(second.search("second-metadata").count == 1)
        #expect(second.search("stale-recycle", showAll: true).isEmpty)
        #expect(lock.withLock { calls } == [b.path])
    }

    @Test func replayRequiresBothUUIDsAndRelocatesAnchorsAndEdits() throws {
        let prior = VolumeCheckpoint(root: "/Volumes/Old", volumeUUID: "disk", eventLogUUID: "log",
                                     mountedDevice: 1, readOnly: false, appliedEvent: 42)
        #expect(VolumeIdentity.permitsReplay(prior, uuid: "disk", log: "log", latest: 42))
        #expect(!VolumeIdentity.permitsReplay(prior, uuid: "other", log: "log", latest: 100))
        #expect(!VolumeIdentity.permitsReplay(prior, uuid: "disk", log: "other", latest: 100))
        #expect(!VolumeIdentity.permitsReplay(prior, uuid: nil, log: "log", latest: 100))
        #expect(!VolumeIdentity.permitsReplay(prior, uuid: "disk", log: "log", latest: 41))

        var old = SearchIndex()
        let root = old.append(prior.root, attribute: Kind.anchor)
        old.append("stale", parent: root, attribute: Kind.file | Kind.suppressed)
        let nested = old.append(prior.root + "/nested", attribute: Kind.anchor)
        old.append("untouched", parent: nested)
        old.tracking = TrackingState(root: prior.root, changes: [prior.root + "/added": file], restricted: [])
        let new = try old.movedVolume(from: prior.root, to: "/Volumes/Relocated")
        let live = LiveIndex(base: new, root: "/Volumes/Relocated")
        #expect(live.readView().entryCount == 2)
        #expect(live.search("", mode: .name, column: .name, direction: .ascending, showAll: true, offset: 0, limit: 5)
            .map(\.path) == ["/Volumes/Relocated/added", "/Volumes/Relocated/nested/untouched"])
    }

    @Test func externalWarmStartReplaysWhenItsMountPathChanges() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("previous")
        let mounted = root.appendingPathComponent("current")
        let state = root.appendingPathComponent("state")
        for folder in [mounted, state] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data().write(to: mounted.appendingPathComponent("cached-metadata"))
        let actual = try VolumeIdentity(root: mounted.path)
        let uuid = UUID().uuidString
        let log = try #require(actual.log)
        let checkpoint = try #require(actual.observedBoundary())
        let original = VolumeIdentity(root: old.path, mount: old.path, device: actual.device,
                                      uuid: uuid, log: log, readOnly: false)
        let active = VolumeIdentity(root: mounted.path, mount: mounted.path, device: actual.device,
                                    uuid: uuid, log: log, readOnly: false)
        let archive = state.appendingPathComponent("index").path
        var base = SearchIndex()
        let anchor = base.append(old.path, attribute: Kind.anchor)
        base.append("cached-metadata", parent: anchor)
        base.volumes = [original.checkpoint(checkpoint)]
        base.prepare()
        try base.savePrepared(to: archive)

        let tracker = try ChangeTracker(root: mounted.path, snapshot: archive, ownData: state.path,
                                        wallTime: { Date().timeIntervalSince1970 },
                                        external: ExternalMount(identity: active, name: "External", fileEvents: true))
        defer { try? tracker.stop() }
        tracker.start()
        #expect(until { tracker.snapshotStatus().phase == "caught-up" })
        #expect(tracker.snapshotStatus().recovery == "replay")
        #expect(tracker.snapshotStatus().rebuilds == 0)
        #expect(tracker.search("cached-metadata").map(\.path) == [mounted.path + "/cached-metadata"])
    }

    @Test func externalVolumeKeepsItsIdentityWithoutHistoricalEvents() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("mounted")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try Data().write(to: path.appendingPathComponent("fixture"))
        let actual = try VolumeIdentity(root: path.path)
        let volumeUUID = UUID().uuidString
        let oldLog = try #require(actual.log)
        let newLog = UUID().uuidString
        func observed(log: String?) -> ExternalMount {
            let identity = VolumeIdentity(root: path.path, mount: path.path, device: actual.device,
                                          uuid: volumeUUID, log: log, readOnly: false)
            return ExternalMount(identity: identity, name: "Fixture",
                                 fileEvents: ExternalMount.supportsFileEvents(on: "apfs"))
        }
        let formerlyMounted = observed(log: oldLog)
        let unavailableHistory = observed(log: nil)
        let replacedHistory = observed(log: newLog)
        #expect(unavailableHistory.cacheKey == nil)
        #expect(unavailableHistory.fileEvents)
        #expect(!ExternalMount.supportsFileEvents(on: "exfat"))
        #expect(formerlyMounted.cacheKey != replacedHistory.cacheKey)

        let mounts = ExternalVolumes(directory: root.path)
        defer { try? mounts.stop() }
        mounts.updateMounts([formerlyMounted])
        #expect(until { mounts.statuses().first?.caughtUp == true })
        let first = try #require(mounts.searchable().first)
        mounts.updateMounts([unavailableHistory])
        #expect(mounts.searchable().first?.tracker === first.tracker)

        mounts.updateMounts([])
        #expect(mounts.statuses().map(\.id) == [volumeUUID])
        #expect(mounts.statuses().first?.online == false)
        mounts.updateMounts([unavailableHistory])
        #expect(until {
            mounts.statuses().count == 1 && mounts.statuses().first?.caughtUp == true
        })
        let attached = try #require(mounts.statuses().first)
        #expect(attached.id == volumeUUID)
        #expect(attached.eventLogUUID == nil)
        #expect(!attached.slow)
        #expect(attached.recovery == "missing")

        mounts.updateMounts([replacedHistory])
        #expect(until {
            mounts.statuses().count == 1 && mounts.statuses().first?.caughtUp == true &&
                mounts.statuses().first?.eventLogUUID == newLog
        })
        let replaced = try #require(mounts.statuses().first)
        #expect(replaced.id == volumeUUID)
        #expect(replaced.recovery == "missing")
        #expect(!replaced.slow)
    }

    @Test func externalRecoveryHandsAChangedLogBackToTheMountManager() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let mount = root.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let actual = try VolumeIdentity(root: mount.path, preferFilesystemUUID: true)
        try #require(actual.log != nil)
        let old = VolumeIdentity(root: mount.path, mount: actual.mount, device: actual.device,
                                 uuid: actual.uuid, log: UUID().uuidString, readOnly: false)
        let tracker = try ChangeTracker(root: mount.path, snapshot: root.appendingPathComponent("index").path,
                                        ownData: root.path, wallTime: { Date().timeIntervalSince1970 },
                                        recoveryTiming: .init(quietWindow: 50_000_000, maximumWait: 100_000_000,
                                                              minimumInterval: 0),
                                        external: ExternalMount(identity: old, name: "Fixture", fileEvents: true),
                                        externalPersistence: false)
        defer { try? tracker.stop() }
        let delegated = DispatchSemaphore(value: 0)
        tracker.onExternalIdentityChange = { delegated.signal() }
        tracker.start()
        #expect(until { tracker.snapshotStatus().phase == "caught-up" })
        tracker.simulateDroppedHistory()
        #expect(delegated.wait(timeout: .now() + 3) == .success)
        #expect(tracker.snapshotStatus().indexReconciling)
        #expect(tracker.snapshotStatus().recoveries == 0)
    }

    @Test func sameNameExternalMountsAreIndependentAndDetachHidesImmediately() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = [root.appendingPathComponent("first"), root.appendingPathComponent("second")]
        for (i, path) in paths.enumerated() {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try Data().write(to: path.appendingPathComponent("unique-\(i)"))
        }
        let device = try WalkScope.device(root.path)
        let mounts = ExternalVolumes(directory: root.path)
        defer { try? mounts.stop() }
        let volumes = paths.map {
            ExternalMount(identity: VolumeIdentity(root: $0.path, mount: $0.path, device: device, uuid: nil,
                                                   log: nil, readOnly: false), name: "SameName", fileEvents: false)
        }
        mounts.updateMounts(volumes)
        #expect(until { mounts.statuses().filter(\.caughtUp).count == 2 })
        let active = mounts.searchable()
        #expect(active.count == 2)
        #expect(mounts.statuses().allSatisfy { $0.name == "SameName" && $0.slow && $0.entries == 1 })
        mounts.updateMounts([volumes[1]])
        #expect(mounts.searchable().map { $0.mount.identity.root } == [paths[1].path])
        #expect(mounts.statuses().filter { !$0.online }.count == 1)
        mounts.updateMounts(volumes)
        #expect(until { mounts.statuses().filter(\.caughtUp).count == 2 })
        let former = active.first { $0.mount.identity.root == paths[0].path }
        #expect(former.map { !mounts.isCurrent($0) } == true)
        let replacement = mounts.searchable().first { $0.mount.identity.root == paths[0].path }
        #expect(replacement?.key != former?.key)
        #expect(replacement?.tracker.snapshotStatus().recovery == "missing")
    }
}
