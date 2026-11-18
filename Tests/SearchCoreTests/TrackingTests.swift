import CoreServices
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
        #expect(!regressed)
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

    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".m2-tmp/test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
