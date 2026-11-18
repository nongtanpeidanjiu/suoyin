import CoreServices
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import SearchCore

@Suite(.serialized)
struct TrackingTests {
    private let folder = TrackedEntry(size: 0, modified: 0, attribute: Kind.directory)
    private let file = TrackedEntry(size: 4, modified: 7, attribute: Kind.file)

    private func fixture() -> SearchIndex {
        var index = SearchIndex()
        let root = index.append("/fixture", attribute: Kind.anchor)
        let a = index.append("a", parent: root, attribute: Kind.directory)
        let b = index.append("b", parent: root, attribute: Kind.directory)
        index.append("report", parent: a, size: 4, modified: 7)
        let old = index.append("old", parent: b, attribute: Kind.directory)
        index.append("deep", parent: old)
        index.prepare()
        return index
    }

    private func filePaths(_ index: LiveIndex, query: String = "") -> [String] {
        index.search(query, mode: .path, column: .path, direction: .ascending,
                     showAll: true, offset: 0, limit: 30).map(\.path)
    }

    @Test func cursorAllowsGapsButCommitsOnlyAppliedEvents() {
        var cursor = EventCursor(applied: 100)
        let first = cursor.received(VolumeEvent(path: "a", id: 113, flags: 0))
        let second = cursor.received(VolumeEvent(path: "b", id: 129, flags: 0))
        #expect(first && second)
        #expect(cursor.applied == 100)
        cursor.acknowledge(113)
        #expect(cursor.applied == 113)
        let regressed = cursor.received(VolumeEvent(path: "c", id: 101, flags: 0))
        #expect(regressed && cursor.outOfOrderBatches == 1)
        #expect(cursor.lastSeen == 129 && cursor.maximumRegression == 28)
    }

    @Test func historyDoneDoesNotCommitAndDroppedInvalidates() {
        var cursor = EventCursor(applied: 31)
        let accepted = cursor.received(VolumeEvent(path: "", id: 400,
            flags: UInt32(kFSEventStreamEventFlagHistoryDone)))
        #expect(accepted)
        #expect(cursor.historyDelivered)
        #expect(cursor.applied == 31)
        for flag in [kFSEventStreamEventFlagKernelDropped, kFSEventStreamEventFlagUserDropped,
                     kFSEventStreamEventFlagEventIdsWrapped, kFSEventStreamEventFlagRootChanged] {
            let accepted = cursor.received(VolumeEvent(path: "", id: 0, flags: UInt32(flag)))
            #expect(!accepted)
        }
    }

    @Test func coalescedCallbackUsesItsMaximumNotPathOrder() {
        var cursor = EventCursor(applied: 100)
        let accepted = cursor.receivedBatch([
            VolumeEvent(path: "a", id: 150, flags: 0),
            VolumeEvent(path: "b", id: 110, flags: 0)
        ])
        #expect(accepted)
        #expect(cursor.lastSeen == 150)
        #expect(cursor.applied == 100)
    }

    @Test func coalescedScanBoundaryRequiresNewerAncestorEvent() {
        let boundary = ScanBoundary(marker: "/fixture/owned/marker", after: 10)
        let recursive = UInt32(kFSEventStreamEventFlagMustScanSubDirs)
        #expect(boundary.covered(by: VolumeEvent(path: "owned/marker", id: 11, flags: 0),
                                 at: "/fixture/owned/marker"))
        #expect(boundary.covered(by: VolumeEvent(path: "owned", id: 12, flags: recursive),
                                 at: "/fixture/owned"))
        #expect(!boundary.covered(by: VolumeEvent(path: "owned", id: 9, flags: recursive),
                                  at: "/fixture/owned"))
        #expect(!boundary.covered(by: VolumeEvent(path: "other", id: 12, flags: recursive),
                                  at: "/fixture/other"))
    }

    @Test func directoryMoveRemovesOldSubtreeAndIndexesNewSubtree() {
        var live = LiveIndex(base: fixture(), root: "/fixture")
        _ = live.reconcile(path: "/fixture/b", observed: .readable(own: folder, children: [:]))
        let next = live.reconcile(path: "/fixture/a", observed: .readable(own: folder,
            children: ["report": file, "moved": folder]))
        #expect(next == ["/fixture/a/moved"])
        _ = live.reconcile(path: next[0], observed: .readable(own: folder, children: ["deep": file]))
        live.prepareDelta()
        #expect(filePaths(live, query: "deep") == ["/fixture/a/moved/deep"])
        #expect(filePaths(live, query: "/old").isEmpty)
    }

    @Test func inaccessibleCoverageIsNotTreatedAsEmpty() {
        var live = LiveIndex(base: fixture(), root: "/fixture")
        _ = live.reconcile(path: "/fixture/b", observed: .restricted)
        live.prepareDelta()
        #expect(live.state.restricted == ["/fixture/b"])
        #expect(filePaths(live, query: "deep").isEmpty)
        _ = live.reconcile(path: "/fixture/b/old", observed: .readable(own: folder,
            children: ["deep": file]))
        live.prepareDelta()
        #expect(filePaths(live, query: "deep").isEmpty)
        let revisit = live.reconcile(path: "/fixture/b", observed: .readable(own: folder,
            children: ["old": folder]))
        #expect(revisit == ["/fixture/b/old"])
        _ = live.reconcile(path: revisit[0], observed: .readable(own: folder, children: ["deep": file]))
        live.prepareDelta()
        #expect(live.state.restricted.isEmpty)
        #expect(filePaths(live, query: "deep") == ["/fixture/b/old/deep"])
    }

    @Test func unchangedDirectoryDiffKeepsBaseTablesAndHasNoOverlay() {
        var live = LiveIndex(base: fixture(), root: "/fixture")
        _ = live.reconcile(path: "/fixture/a", observed: .readable(own: folder, children: ["report": file]))
        live.prepareDelta()
        #expect(live.state.changes.isEmpty)
        #expect(live.base.prepared != nil)
        #expect(filePaths(live, query: "report") == ["/fixture/a/report"])
    }

    @Test func cachedRowsFromUnverifiedScopeAreWithheldOnFirstQuery() {
        var cached = LiveIndex(base: fixture(), root: "/fixture")
        let reopened = cached.verifyStartupCoverage(at: ["/fixture/a", "/fixture/b"]) {
            $0.hasSuffix("/a") ? .readable(own: folder, children: [:]) : nil
        }
        #expect(reopened.isEmpty)
        #expect(cached.state.restricted == ["/fixture/b"])
        #expect(filePaths(cached, query: "deep").isEmpty)
        #expect(filePaths(cached, query: "report") == ["/fixture/a/report"])
    }

    @Test func directoryMetadataCannotHideAChangeInCoverage() {
        var index = LiveIndex(base: fixture(), root: "/fixture")
        #expect(!index.refreshDirectory("/fixture/b") { _ in .unverified })
        _ = index.reconcile(path: "/fixture/b", observed: .restricted)
        #expect(!index.refreshDirectory("/fixture/b") { _ in .entry(folder) })
        index.prepareDelta()
        #expect(filePaths(index, query: "deep").isEmpty)
    }

    @Test func restoredIndexRootRequiresReconciliation() {
        var index = LiveIndex(base: fixture(), root: "/fixture")
        #expect(index.refreshDirectory("/fixture") { _ in .entry(folder) })
        #expect(!index.refreshDirectory("/fixture") { _ in .unverified })
        _ = index.reconcile(path: "/fixture", observed: .restricted)
        index.prepareDelta()
        #expect(filePaths(index).isEmpty)
        #expect(!index.refreshDirectory("/fixture") { _ in .entry(folder) })
        let reopened = index.reconcile(path: "/fixture", observed: .readable(own: folder, children: ["b": folder]))
        #expect(reopened == ["/fixture/b"])
        #expect(index.state.restricted.isEmpty)
    }

    @Test func reopenedScopeIsReconciledBeforeRestoringCachedVisibility() throws {
        var older = LiveIndex(base: fixture(), root: "/fixture")
        _ = older.verifyStartupCoverage(at: ["/fixture/b"]) { _ in .restricted }
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("index").path
        try older.archive().savePrepared(to: path)
        var restarted = LiveIndex(base: try SearchIndex.load(from: path), root: "/fixture")
        let reopened = restarted.verifyStartupCoverage(at: ["/fixture/b"]) { _ in
            .readable(own: folder, children: ["restored": file])
        }
        #expect(reopened == ["/fixture/b"])
        #expect(filePaths(restarted, query: "deep").isEmpty)
        for path in reopened {
            _ = restarted.reconcile(path: path, observed: .readable(own: folder, children: ["restored": file]))
        }
        restarted.prepareDelta()
        #expect(restarted.state.restricted.isEmpty)
        #expect(filePaths(restarted, query: "restored") == ["/fixture/b/restored"])
        #expect(filePaths(restarted, query: "deep").isEmpty)
    }

    @Test func providerTrashIsNeverAnObservationTarget() throws {
        let scope = try WalkScope(root: "/")
        #expect(scope.insideProviderTrash("/Users/test/Library/CloudStorage/OneDrive-Test/.Trash/a/b"))
        #expect(scope.insideProviderTrash("/System/Volumes/Data/Users/test/Library/Mobile Documents/com~apple~CloudDocs/.Trash/x"))
        #expect(!scope.insideProviderTrash("/Users/test/Library/CloudStorage/OneDrive-Test/work/.Trash"))
        #expect(!scope.insideProviderTrash("/Users/test/.Trash"))
    }

    @Test func preparedDiskRoundTripAndChecksum() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("index")
        var live = LiveIndex(base: fixture(), root: "/fixture")
        _ = live.reconcile(path: "/fixture/a", observed: .readable(own: folder, children: ["new": file]))
        live.prepareDelta()
        try live.archive().savePrepared(to: path.path)
        let loaded = try SearchIndex.load(from: path.path)
        #expect(loaded.prepared != nil)
        #expect(loaded.restoredRows().map(\.path).contains("/fixture/a/new"))
        #expect(!loaded.restoredRows().map(\.path).contains("/fixture/a/report"))
        var resumed = LiveIndex(base: loaded, root: "/fixture")
        _ = resumed.reconcile(path: "/fixture/a", observed: .readable(own: folder, children: ["report": file]))
        resumed.prepareDelta()
        #expect(filePaths(resumed, query: "report") == ["/fixture/a/report"])
        var data = try Data(contentsOf: path)
        data[data.count - 1] ^= 1
        try data.write(to: path)
        #expect(throws: SnapshotError.invalid) { try SearchIndex.load(from: path.path) }
    }

    @Test func olderPreparedSnapshotRetainsNameOrderAndDropsSecondaryTables() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("legacy-index").path
        let original = fixture()
        try original.savePrepared(to: path)
        var data = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(data[28] == 2)
        let metadataCount = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt32.self) })
        let endOfOrders = data.count - metadataCount
        let nameOrder = Data(data[(endOfOrders - 4 * original.recordCount)..<endOfOrders])
        data.insert(contentsOf: nameOrder + nameOrder + nameOrder, at: endOfOrders)
        data[28] = 1
        var digest = SHA256()
        digest.update(data: data.prefix(32))
        digest.update(data: data.dropFirst(64))
        data.replaceSubrange(32..<64, with: Array(digest.finalize()))
        try data.write(to: URL(fileURLWithPath: path))
        let loaded = try SearchIndex.load(from: path)
        #expect(loaded.prepared?.columnOrders.bytes == 0)
        #expect(loaded.prepared?.nameOrder == original.prepared?.nameOrder)
        #expect(loaded.search("", column: .path) == original.directSearch("", column: .path))
    }

    @Test func privateTemporaryPathsUseTheSameSpellingAsEventPaths() throws {
        // The real system alias is read-only in this test. All file-writing
        // tracker tests stay in the project's own scratch tree.
        let tracker = try ChangeTracker(root: "/", snapshot: "/dev/null", ownData: "/tmp/")
        #expect(tracker.ownDirectory == "/private/tmp")
        #expect(tracker.excluded.contains("/private/tmp"))
        let marker = "/private/tmp/owned/.scan-boundary-fixture"
        let event = VolumeEvent(path: "private/tmp/owned/.scan-boundary-fixture", id: 20, flags: 0)
        let logical = try #require(tracker.logicalPath(event.path, volume: 1))
        #expect(logical == marker)
        #expect(tracker.excluded.contains { inside(logical, $0) })
        #expect(ScanBoundary(marker: marker, after: 19).covered(by: event, at: logical))
    }

    @Test func fileEventsUpdateRowsAndParentMetadataWithoutEnumerating() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let own = root.appendingPathComponent("owned")
        let dir = root.appendingPathComponent("fixture")
        for folder in [own, dir] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
        let old = dir.appendingPathComponent("old-marker")
        let gone = dir.appendingPathComponent("gone-marker")
        let new = dir.appendingPathComponent("new-marker")
        let renamed = dir.appendingPathComponent("renamed-marker")
        try Data([1]).write(to: old)
        try Data([1]).write(to: gone)
        let tracker = try ChangeTracker(root: root.path, snapshot: own.appendingPathComponent("base").path,
                                        ownData: own.path)
        tracker.start()
        defer { try? tracker.stop() }
        try awaitStatus(tracker) { $0.phase == "caught-up" }
        let before = tracker.snapshotStatus()
        let id = before.appliedEvents.values.max() ?? 1
        let file = kFSEventStreamEventFlagItemIsFile
        try tracker.deliverForTesting([
            VolumeEvent(path: old.path, id: id + 1, flags: UInt32(file | kFSEventStreamEventFlagItemRenamed)),
            VolumeEvent(path: renamed.path, id: id + 2, flags: UInt32(file | kFSEventStreamEventFlagItemRenamed)),
            VolumeEvent(path: gone.path, id: id + 3, flags: UInt32(file | kFSEventStreamEventFlagItemRemoved)),
            VolumeEvent(path: new.path, id: id + 4, flags: UInt32(file | kFSEventStreamEventFlagItemCreated)),
        ], writing: {
            try FileManager.default.moveItem(at: old, to: renamed)
            try FileManager.default.removeItem(at: gone)
            try Data([1, 2]).write(to: new)
        }, check: {
            let after = tracker.snapshotStatus()
            #expect(after.directFilesObserved - before.directFilesObserved == 4)
            #expect(after.directDirectoriesObserved - before.directDirectoriesObserved == 1)
            #expect(after.directoriesObserved == before.directoriesObserved)
            #expect(tracker.search("-marker").map(\.path) == [new.path, renamed.path])
            #expect(tracker.search("new-marker").first?.size == 2)
            var info = stat()
            #expect(lstat(dir.path, &info) == 0)
            let latest = tracker.search("fixture").first
            #expect(latest?.size == info.st_size)
            #expect(latest?.modified == Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec))
        })
    }

    @Test func onlyUnambiguousFileContentNotificationsAreCoalesced() {
        let file = kFSEventStreamEventFlagItemIsFile
        let modified = kFSEventStreamEventFlagItemModified
        let inode = kFSEventStreamEventFlagItemInodeMetaMod
        func isContent(_ flags: Int) -> Bool {
            VolumeEvent(path: "item", id: 1, flags: UInt32(flags)).contentOnly
        }
        #expect(isContent(file | modified))
        #expect(isContent(file | modified | inode))
        #expect(!isContent(file | inode))
        #expect(!isContent(file | modified | kFSEventStreamEventFlagItemRenamed))
        #expect(!isContent(file | modified | kFSEventStreamEventFlagItemXattrMod))
        #expect(!isContent(kFSEventStreamEventFlagItemIsDir | modified))
    }

    @Test func repeatedContentEventsDelayOnlyTheirOwnPathAndHoldTheCursor() {
        var content = FileContentSchedule()
        let second = ReplayLag.second
        content.enqueue("/a", event: 10, volume: 0, now: 100 * second)
        #expect(content.take(at: 100 * second, force: false) == ["/a"])
        content.enqueue("/a", event: 12, volume: 0, now: 101 * second)
        content.enqueue("/a", event: 11, volume: 0, now: 102 * second)
        content.enqueue("/b", event: 13, volume: 0, now: 102 * second)
        #expect(content.take(at: 102 * second, force: false) == ["/b"])
        #expect(content.floors() == [0: 11])
        #expect(content.next == 130 * second)
        #expect(content.take(at: 129 * second, force: false).isEmpty)
        #expect(content.take(at: 130 * second, force: false) == ["/a"])
        #expect(content.floors().isEmpty)
    }

    @Test func failureBeforeReplaceRetainsOlderGeneration() throws {
        enum Inject: Error { case stop }
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("index")
        let before = fixture()
        try before.savePrepared(to: path.path)
        var after = LiveIndex(base: before, root: "/fixture")
        _ = after.reconcile(path: "/fixture/a", observed: .readable(own: folder, children: ["new": file]))
        #expect(throws: Inject.stop) {
            try after.archive().savePrepared(to: path.path, beforeReplace: { throw Inject.stop })
        }
        let reopened = try SearchIndex.load(from: path.path)
        #expect(reopened.restoredRows().map(\.path).contains("/fixture/a/report"))
        #expect(reopened.tracking == nil)
    }

    @Test func dataRebuildPreservesSealedSibling() {
        var old = SearchIndex()
        let oldRoot = old.append("/", attribute: Kind.anchor)
        let oldUsers = old.append("Users", parent: oldRoot, attribute: Kind.directory)
        old.append("old.txt", parent: oldUsers)
        old.append("sealed", parent: oldRoot)
        var fresh = SearchIndex()
        let newRoot = fresh.append("/", attribute: Kind.anchor)
        let newUsers = fresh.append("Users", parent: newRoot, attribute: Kind.directory)
        fresh.append("new.txt", parent: newUsers)
        let result = mergeDataVolume(old: LiveIndex(base: old, root: "/"), new: fresh, targets: ["/Users"])
        #expect(Set(result.restoredRows().map(\.path)) == ["/sealed", "/Users", "/Users/new.txt"])
    }

    @Test func lagAgesAppliedPositionsAndCannotOvertakeDeferredWork() {
        let second = ReplayLag.second
        var cursor = EventCursor(applied: 100)
        cursor.acknowledge(130, at: 20 * second)
        cursor.acknowledge(150, at: 22 * second)
        #expect(cursor.lag.position(at: 29 * second, observed: 180, pending: nil) == 100)
        #expect(cursor.lag.position(at: 30 * second, observed: 180, pending: nil) == 130)
        #expect(cursor.lag.position(at: 32 * second, observed: 142, pending: nil) == 142)
        #expect(cursor.lag.position(at: 32 * second, observed: 180, pending: 128) == 127)
        #expect(cursor.lag.position(at: 32 * second, observed: nil, pending: nil) == nil)
    }

    @Test func delayedDirectoriesKeepEarliestEventAndSettleOnDeadline() {
        let second = ReplayLag.second
        var schedule = DirectorySchedule()
        func request(_ event: UInt64) -> DirectoryUpdate {
            DirectoryUpdate(recursive: true, pending: [0: event])
        }
        schedule.enqueue(request(100), at: "visible", hidden: false, now: 90 * second)
        #expect(schedule.take(at: 90 * second, force: false).count == 1)
        schedule.enqueue(request(150), at: "visible", hidden: false, now: 91 * second)
        schedule.enqueue(request(140), at: "visible", hidden: false, now: 92 * second)
        #expect(schedule.next == 95 * second)
        #expect(schedule.floors() == [0: 140])
        #expect(schedule.take(at: 94 * second, force: false).isEmpty)
        #expect(schedule.take(at: 95 * second, force: false).count == 1)
        schedule.enqueue(request(151), at: "visible", hidden: false, now: 96 * second)
        #expect(schedule.next == 105 * second)
        _ = schedule.take(at: 105 * second, force: false)
        schedule.enqueue(request(152), at: "visible", hidden: false, now: 106 * second)
        #expect(schedule.next == 125 * second)
        _ = schedule.take(at: 125 * second, force: false)
        schedule.enqueue(request(153), at: "visible", hidden: false, now: 126 * second)
        #expect(schedule.next == 155 * second)
        _ = schedule.take(at: 155 * second, force: false)
        schedule.enqueue(request(154), at: "visible", hidden: false, now: 216 * second)
        #expect(schedule.next == 216 * second)
        _ = schedule.take(at: 216 * second, force: false)
        schedule.enqueue(request(101), at: "hidden", hidden: true, now: 216 * second)
        _ = schedule.take(at: 216 * second, force: false)
        schedule.enqueue(request(102), at: "hidden", hidden: true, now: 217 * second)
        #expect(schedule.next == 246 * second)
        #expect(schedule.take(at: 218 * second, force: true).count == 1)
        #expect(schedule.floors().isEmpty)
    }

    @Test func writeBudgetSurvivesNewOwnerAndUsesRollingWindow() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("index").path
        var first = BaseWriteBudget(snapshot: path)
        #expect(try first.reserve(at: 100))
        #expect(try first.reserve(at: 200))
        var restarted = BaseWriteBudget(snapshot: path)
        #expect(restarted.count(at: 300) == 2)
        #expect(try !restarted.reserve(at: 300))
        #expect(restarted.next(at: 300) == 100 + BaseWriteBudget.window)
        #expect(try restarted.reserve(at: 100 + BaseWriteBudget.window))
        #expect(try !restarted.reserve(at: 150 + BaseWriteBudget.window))
        try Data("invalid".utf8).write(to: URL(fileURLWithPath: path + ".budget"))
        var corrupted = BaseWriteBudget(snapshot: path)
        #expect(try !corrupted.reserve(at: 1_000_000))
    }

    @Test func scannedStorageCompactsWithoutChangingSearchRows() {
        var index = SearchIndex()
        index.reserve(10_000, nameBytes: 100_000)
        let root = index.append("/fixture", attribute: Kind.anchor)
        index.append("Abc", parent: root, size: 4, modified: 9)
        let original = index.directSearch("abc")
        index.tightenScannedStorage()
        #expect(index.records.capacity < 100)
        #expect(index.attributes.capacity < 100)
        #expect(index.names.capacity < 100)
        #expect(index.search("abc") == original)
    }

    @Test func throttlingRespectsVisibleSystemAndCloudExceptions() throws {
        let disk = try WalkScope(root: "/")
        #expect(disk.backgroundDirectory("/usr/bin"))
        #expect(!disk.backgroundDirectory("/usr/local"))
        #expect(!disk.backgroundDirectory("/usr/local/share"))
        #expect(!disk.backgroundDirectory("/usr/local/bin"))
        #expect(!disk.backgroundDirectory("/usr/local/sbin"))
        #expect(!disk.backgroundDirectory("/System/Volumes/Data/usr/local/bin"))
        #expect(disk.backgroundDirectory("/usr/local/.hidden"))
        #expect(!disk.backgroundDirectory(disk.homeLibrary + "/CloudStorage/Documents"))
        #expect(disk.backgroundDirectory(disk.homeLibrary + "/Caches"))
        #expect(!disk.backgroundDirectory("/Applications/Example.app"))
        #expect(disk.backgroundDirectory("/Applications/Example.app/Contents"))
    }

    @Test func lateBatchAppliesAndOnlyDroppedEventsRebuildTheSubscription() throws {
        let fixture = try scratch()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let own = fixture.appendingPathComponent("owned")
        let local = fixture.appendingPathComponent("local")
        let sibling = fixture.appendingPathComponent("sibling")
        let recursive = fixture.appendingPathComponent("recursive")
        for dir in [own, local, sibling, recursive] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let path = own.appendingPathComponent("index.tmp").path
        let tracker = try ChangeTracker(root: fixture.path, snapshot: path, ownData: own.path)
        tracker.start()
        defer { try? tracker.stop() }
        try awaitStatus(tracker) { $0.phase == "caught-up" }

        let flag = UInt32(kFSEventStreamEventFlagMustScanSubDirs)
        let marker = local.appendingPathComponent("late-applied.tmp")
        let observed = tracker.snapshotStatus().appliedEvents.values.max() ?? 1
        let high = observed + 100_000_000
        let siblingFile = sibling.appendingPathComponent("unrelated.tmp")
        try tracker.deliverForTesting([VolumeEvent(path: siblingFile.path, id: high, flags: 0)])
        let prior = tracker.snapshotStatus().outOfOrderBatches
        #expect(tracker.search("late-applied").isEmpty)
        try tracker.deliverForTesting([VolumeEvent(path: marker.path, id: high - 1, flags: 0)],
            writing: { try Data([1, 2, 3]).write(to: marker) }, check: {
                let status = tracker.snapshotStatus()
                #expect(status.outOfOrderBatches == prior + 1)
                #expect(status.rebuilds == 0)
                #expect(tracker.search("late-applied").first?.size == 3)
            })

        let previous = tracker.snapshotStatus().recursiveDirectoriesObserved
        try tracker.deliverForTesting([VolumeEvent(path: recursive.path, id: high + 1, flags: flag)])
        #expect(tracker.snapshotStatus().recursiveDirectoriesObserved > previous)
        #expect(tracker.snapshotStatus().rebuilds == 0)

        let dropped = UInt32(kFSEventStreamEventFlagKernelDropped)
        try tracker.deliverForTesting([VolumeEvent(path: local.path, id: high + 2, flags: flag | dropped)])
        try awaitStatus(tracker) { $0.rebuilds == 1 && $0.phase == "caught-up" }
        #expect(tracker.search("late-applied").map(\.path) == [marker.path])
        let userDropped = UInt32(kFSEventStreamEventFlagUserDropped)
        try tracker.deliverForTesting([VolumeEvent(path: local.path, id: high + 3, flags: flag | userDropped)])
        #expect(tracker.snapshotStatus().phase == "degraded")
        #expect(tracker.snapshotStatus().rebuilds == 1)
    }

    private final class WallClock {
        private let lock = NSLock()
        private var value: TimeInterval = 300
        private var started: Date?

        func read() -> TimeInterval {
            lock.withLock { value + (started.map { Date().timeIntervalSince($0) } ?? 0) }
        }

        func set(_ time: TimeInterval, ticking: Bool = false) {
            lock.withLock {
                value = time
                started = ticking ? Date() : nil
            }
        }
    }

    @Test(arguments: ["frozen", "exit", "idle"])
    func exhaustedBudgetFreezesDiskButDoesNotFreezeTheRebuiltView(mode: String) throws {
        let fixture = try scratch()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let own = fixture.appendingPathComponent("owned")
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        let snapshot = own.appendingPathComponent("index.tmp")
        let journal = URL(fileURLWithPath: snapshot.path + ".changes")
        var budget = BaseWriteBudget(snapshot: snapshot.path)
        #expect(try budget.reserve(at: 100))
        #expect(try budget.reserve(at: 200))
        let clock = WallClock()
        let idle = mode == "idle"
        let second = try ChangeTracker(root: fixture.path, snapshot: snapshot.path,
                                       ownData: own.path, wallTime: { clock.read() })
        second.start()
        defer { try? second.stop() }
        try awaitStatus(second) { $0.phase == "caught-up" }
        let initialWrites = second.snapshotStatus().baseWrites
        let baseline = try Data(contentsOf: snapshot)
        let prefix = try Data(contentsOf: journal)
        if idle { clock.set(100 + BaseWriteBudget.window - 5, ticking: true) }
        second.holdUpdates(true)
        let changed = fixture.appendingPathComponent("changed-live.tmp")
        try Data([8]).write(to: changed)
        second.simulateDroppedHistory()
        second.holdUpdates(false)
        try awaitStatus(second) { $0.phase == "caught-up" && $0.baseWriteDeferred }
        #expect(second.search("changed-live").map(\.path) == [changed.path])
        try second.save()
        #expect(second.snapshotStatus().baseWrites == initialWrites)
        #expect(try Data(contentsOf: snapshot) == baseline)
        #expect(try Data(contentsOf: journal) == prefix)

        if mode == "exit" {
            second.holdUpdates(true)
            clock.set(100 + BaseWriteBudget.window)
        } else if idle {
            try awaitStatus(second) { $0.baseWrites == initialWrites + 1 && !$0.baseWriteDeferred }
        }
        try second.stop()
        let result = second.snapshotStatus()
        #expect(result.baseWrites == initialWrites + (mode == "frozen" ? 0 : 1))
        #expect(result.exitBaseWrites == (mode == "exit" ? 1 : 0))
        if mode != "frozen" {
            let persisted = try SearchIndex.load(from: snapshot.path)
            #expect(persisted.restoredRows().map(\.path).contains(changed.path))
            #expect(result.automaticBaseWritesInWindow == 2)
        }
    }

    private func awaitStatus(_ tracker: ChangeTracker,
                             _ ready: (TrackingStatus) -> Bool) throws {
        let end = Date().addingTimeInterval(9)
        while Date() < end {
            let status = tracker.snapshotStatus()
            if ready(status) { return }
            if status.error != nil { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let latest = tracker.snapshotStatus()
        Issue.record("Unexpected tracking phase: \(latest.phase) / \(latest.recovery) / \(latest.invalidEvidence ?? "-") / \(latest.error ?? "no error")")
        throw CocoaError(.fileReadUnknown)
    }

    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".m2-tmp/test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
