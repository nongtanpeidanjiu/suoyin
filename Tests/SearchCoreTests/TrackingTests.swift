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

    @Test func removingSubtreeFindsOverlayRowsWithUnindexedParents() {
        var base = fixture()
        base.tracking = TrackingState(root: "/fixture", changes: [
            "/fixture/b": folder,
            "/fixture/b/orphan/deeper/extra": file,
            "/fixture/b/orphan/another": file,
            "/fixture/b-other/orphan/keep": file,
        ], restricted: [])
        var index = LiveIndex(base: base, root: "/fixture")
        _ = index.reconcile(path: "/fixture/b", observed: .denied(EACCES))
        index.prepareDelta()
        #expect(index.state.changes.keys.sorted() == ["/fixture/b", "/fixture/b-other/orphan/keep"])
        #expect(filePaths(index, query: "deep").isEmpty)

        _ = index.reconcile(path: "/fixture/b", observed: .readable(own: folder, children: ["orphan": folder]))
        _ = index.reconcile(path: "/fixture/b/orphan", observed: .readable(own: folder, children: ["restored": file]))
        index.prepareDelta()
        #expect(filePaths(index, query: "restored") == ["/fixture/b/orphan/restored"])

        _ = index.reconcile(path: "/fixture/b", observed: .absent)
        index.prepareDelta()
        #expect(index.state.changes.keys.sorted() == ["/fixture/b-other/orphan/keep"])
        #expect(filePaths(index, query: "restored").isEmpty)
        #expect(filePaths(index, query: "keep") == ["/fixture/b-other/orphan/keep"])
    }

    @Test func incrementalOverlayMatchesRebuiltPagesAndPreservesCapturedViews() throws {
        let paths = (0..<32).map { "/fixture/group-\($0)" }
        let partitions = Dictionary(grouping: paths) { path in
            path.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 } & 15
        }
        let pair = try #require(partitions.values.first { $0.count >= 2 }).prefix(2).sorted()
        let moved = pair[0] + "/item.txt"
        let retained = pair[1] + "/item.txt"
        let removed = pair[0] + "/item-removed.txt"
        let previous = TrackedEntry(size: 9, modified: 8, attribute: Kind.file)
        var base = SearchIndex()
        let anchor = base.append("/fixture", attribute: Kind.anchor)
        for path in pair { base.append(leafName(path), parent: anchor, attribute: Kind.directory) }
        base.tracking = TrackingState(root: "/fixture", changes: [moved: previous, retained: file, removed: file], restricted: [])
        base.prepare()
        var live = LiveIndex(base: base, root: "/fixture")
        let captured = live.readView()

        func comparePages(_ candidate: LiveIndex) {
            let rebuilt = LiveIndex(base: candidate.archive(), root: "/fixture").readView()
            let view = candidate.readView()
            #expect(view.entryCount == rebuilt.entryCount)
            for mode in [QueryMode.name, .path] {
                for column in SearchColumn.allCases {
                    for direction in SearchDirection.allCases {
                        for offset in [0, 1, 7] {
                            func page(_ source: LiveSearchView) -> [String] {
                                source.search("item", mode: mode, column: column, direction: direction,
                                              showAll: false, kind: .document, offset: offset, limit: 3)
                                    .map { "\($0.path) \($0.size) \($0.modified)" }
                            }
                            #expect(page(view) == page(rebuilt))
                        }
                    }
                }
            }
        }

        #expect(live.refreshFile(moved) { _ in .entry(file) })
        #expect(live.refreshFile(removed) { _ in .missing })
        live.prepareDelta()
        comparePages(live)
        #expect(live.readView().entryCount == captured.entryCount - 1)
        #expect(captured.search("item-removed", mode: .name, column: .name, direction: .ascending,
                                showAll: true, offset: 0, limit: 1).first?.path == removed)

        for i in 0..<135 {
            #expect(live.refreshFile(pair[0] + "/item-\(i).txt") { _ in .entry(file) })
        }
        live.prepareDelta()
        comparePages(live)
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
        // An older archive may contain stale denials below a denied parent.
        let nested = "/fixture/b/removed/missing"
        older.state.recordDenial(nested, error: EACCES)
        try older.archive().savePrepared(to: path)
        var restarted = LiveIndex(base: try SearchIndex.load(from: path), root: "/fixture")
        let reopened = restarted.verifyStartupCoverage(at: ["/fixture/b", nested]) { _ in
            .readable(own: folder, children: ["restored": file])
        }
        #expect(reopened == ["/fixture/b", nested])
        #expect(filePaths(restarted, query: "deep").isEmpty)
        for path in reopened {
            let observation: DirectoryObservation = path == nested
                ? .absent : .readable(own: folder, children: ["restored": file])
            _ = restarted.reconcile(path: path, observed: observation)
        }
        restarted.prepareDelta()
        #expect(restarted.state.restricted.isEmpty)
        #expect(filePaths(restarted, query: "restored") == ["/fixture/b/restored"])
        #expect(filePaths(restarted, query: "deep").isEmpty)
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
        var original = fixture()
        original.prepared = nil
        original.append("legacy-type.TXT", parent: 0)
        original.prepare()
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
        #expect(loaded.search("legacy-type", kind: .document).map(\.name) == ["legacy-type.TXT"])
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

    @Test func fileReplacementCaseRenameAndSubtreeMoveApplyFromEvents() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let own = root.appendingPathComponent("owned")
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        let fileChanges = root.appendingPathComponent("file-changes")
        let aliasChanges = root.appendingPathComponent("alias-changes")
        let replacement = root.appendingPathComponent("replacement")
        let caseTreeParent = root.appendingPathComponent("case-trees")
        let typeParent = root.appendingPathComponent("type-change")
        let oldTree = source.appendingPathComponent("moved-tree")
        let newTree = destination.appendingPathComponent("renamed-tree")
        let nested = oldTree.appendingPathComponent("nested")
        let oldCaseTree = caseTreeParent.appendingPathComponent("old-case-tree")
        let newCaseTree = caseTreeParent.appendingPathComponent("OLD-case-tree")
        let typeChange = typeParent.appendingPathComponent("directory-now-file")
        for path in [own, nested, destination, fileChanges, aliasChanges, replacement, oldCaseTree, typeChange] {
            try fm.createDirectory(at: path, withIntermediateDirectories: true)
        }
        try Data([1]).write(to: nested.appendingPathComponent("tree-marker"))
        try Data([1]).write(to: oldCaseTree.appendingPathComponent("case-child"))
        try Data([1]).write(to: typeChange.appendingPathComponent("former-child"))
        let oldName = fileChanges.appendingPathComponent("case-marker")
        let newName = fileChanges.appendingPathComponent("CASE-marker")
        let oldAlias = aliasChanges.appendingPathComponent("alias-marker")
        let newAlias = aliasChanges.appendingPathComponent("ALIAS-marker")
        let replaced = replacement.appendingPathComponent("replace-marker")
        let incoming = own.appendingPathComponent("replacement")
        try Data([1]).write(to: oldName)
        try Data([1]).write(to: oldAlias)
        try Data([1]).write(to: replaced)
        try Data([1, 2, 3]).write(to: incoming)
        var oldInfo = stat()
        try #require(lstat(replaced.path, &oldInfo) == 0)
        let tracker = try ChangeTracker(root: root.path, snapshot: own.appendingPathComponent("base").path,
                                        ownData: own.path)
        tracker.start()
        defer { try? tracker.stop() }
        try awaitStatus(tracker) { $0.phase == "caught-up" }
        let id = tracker.snapshotStatus().appliedEvents.values.max() ?? 1
        let renameFile = UInt32(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsFile)
        let renameDirectory = UInt32(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsDir)
        let removeDirectory = UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsDir)
        try tracker.deliverForTesting([
            // The new spelling alone must also discard the old indexed spelling.
            VolumeEvent(path: newName.path, id: id + 1, flags: renameFile),
            VolumeEvent(path: replaced.path, id: id + 2, flags: renameFile),
            VolumeEvent(path: oldTree.path, id: id + 3, flags: renameDirectory),
            VolumeEvent(path: newTree.path, id: id + 4, flags: renameDirectory),
            VolumeEvent(path: oldAlias.path, id: id + 5, flags: renameFile),
            VolumeEvent(path: oldCaseTree.path, id: id + 6, flags: renameDirectory),
            VolumeEvent(path: newCaseTree.path, id: id + 7, flags: renameDirectory),
            VolumeEvent(path: typeChange.path, id: id + 8, flags: removeDirectory),
        ], writing: {
            try #require(rename(oldName.path, newName.path) == 0)
            try #require(rename(oldAlias.path, newAlias.path) == 0)
            try #require(rename(incoming.path, replaced.path) == 0)
            try fm.moveItem(at: oldTree, to: newTree)
            try #require(rename(oldCaseTree.path, newCaseTree.path) == 0)
            try fm.removeItem(at: typeChange)
            try Data([1, 2]).write(to: typeChange)
        }, check: {
            var currentInfo = stat()
            #expect(lstat(replaced.path, &currentInfo) == 0)
            #expect(currentInfo.st_ino != oldInfo.st_ino)
            #expect(tracker.search("replace-marker").first?.size == 3)
            #expect(tracker.search("case-marker").map(\.path) == [newName.path])
            if fm.fileExists(atPath: oldAlias.path) {
                #expect(tracker.search("alias-marker").map(\.path) == [newAlias.path])
            }
            #expect(tracker.search("tree-marker").map(\.path) == [newTree.path + "/nested/tree-marker"])
            #expect(tracker.search("case-child").map(\.path) == [newCaseTree.path + "/case-child"])
            #expect(tracker.search("former-child").isEmpty)
            #expect(tracker.search("directory-now-file").first?.size == 2)
        })
    }

    @Test func explicitRecursiveReconciliationCannotBeCoveredByAParentListing() {
        var structural = DirectoryUpdate()
        structural.requestReconciliation(recursive: true, maySkipAfterParent: true)
        #expect(structural.maySkipAfterParent)
        var explicit = DirectoryUpdate()
        explicit.requestReconciliation(recursive: true, maySkipAfterParent: false)
        var combined = structural
        combined.requestReconciliation(recursive: true, maySkipAfterParent: false)
        #expect(combined.recursive == true && !combined.maySkipAfterParent)
        explicit.requestReconciliation(recursive: true, maySkipAfterParent: true)
        #expect(explicit.recursive == true && !explicit.maySkipAfterParent)
    }

    @Test func consecutiveStructuralBatchesAreImmediateInHiddenAndVisibleDirectories() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let own = root.appendingPathComponent("owned")
        let hidden = root.appendingPathComponent(".hidden")
        let visible = root.appendingPathComponent("visible")
        for folder in [own, hidden, visible] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        let tracker = try ChangeTracker(root: root.path, snapshot: own.appendingPathComponent("base").path,
                                        ownData: own.path)
        tracker.start()
        defer { try? tracker.stop() }
        try awaitStatus(tracker) { $0.phase == "caught-up" }
        var id = tracker.snapshotStatus().appliedEvents.values.max() ?? 1
        func event(_ url: URL, _ flags: Int) -> VolumeEvent {
            id += 1
            return VolumeEvent(path: url.path, id: id, flags: UInt32(flags))
        }
        let fileFlag = kFSEventStreamEventFlagItemIsFile
        let dirFlag = kFSEventStreamEventFlagItemIsDir
        let created = kFSEventStreamEventFlagItemCreated
        let removed = kFSEventStreamEventFlagItemRemoved
        let renamed = kFSEventStreamEventFlagItemRenamed
        for parent in [hidden, visible] {
            let before = parent.appendingPathComponent("structural-before")
            let after = parent.appendingPathComponent("structural-after")
            for type in [fileFlag, dirFlag] {
                try tracker.deliverForTesting([event(before, type | created)], writing: {
                    if type == dirFlag { try fm.createDirectory(at: before, withIntermediateDirectories: false) }
                    else { try Data([1]).write(to: before) }
                })
                #expect(tracker.search("structural-before", showAll: true).map(\.path) == [before.path])
                try tracker.deliverForTesting([event(before, type | renamed), event(after, type | renamed)],
                                              writing: { try fm.moveItem(at: before, to: after) })
                #expect(tracker.search("structural-before", showAll: true).isEmpty)
                #expect(tracker.search("structural-after", showAll: true).map(\.path) == [after.path])
                try tracker.deliverForTesting([event(after, type | removed)], writing: { try fm.removeItem(at: after) })
                #expect(tracker.search("structural-after", showAll: true).isEmpty)
            }
            try tracker.deliverForTesting([
                event(before, fileFlag | created), event(before, fileFlag | renamed), event(after, fileFlag | renamed),
            ], writing: {
                try Data([1]).write(to: before)
                try fm.moveItem(at: before, to: after)
            })
            #expect(tracker.search("structural-before", showAll: true).isEmpty)
            #expect(tracker.search("structural-after", showAll: true).contains { $0.path == after.path })
            try tracker.deliverForTesting([event(after, fileFlag | removed)], writing: { try fm.removeItem(at: after) })
        }
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
        let compactedParent = old.append("/Users/fixture/removed", attribute: Kind.anchor)
        old.append("removed-with-parent.txt", parent: compactedParent)
        let suppressed = old.append("previously-withheld", parent: oldRoot)
        old.setSuppressed(Int(suppressed), true)
        let coverage = TrackingState(root: "/", changes: [:], restricted: ["/Users/fixture", "/System/fixture"],
                                     denialErrors: ["/Users/fixture": EPERM, "/System/fixture": EACCES])
        let result = sealedVolume(from: old, excluding: ["/Users"], coverage: coverage)
        #expect(result.records.count == 3)
        #expect(result.restoredRows().map(\.path) == ["/sealed"])
        #expect(result.tracking?.restricted == ["/System/fixture"])
        #expect(result.tracking?.denialErrors == ["/System/fixture": EACCES])
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

    @Test func lateBatchAppliesAndOnlyDroppedEventsRebuildTheSubscription() throws {
        let fixture = try scratch()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let own = fixture.appendingPathComponent("owned")
        let local = fixture.appendingPathComponent("local")
        let sibling = fixture.appendingPathComponent("sibling")
        let recursive = fixture.appendingPathComponent("recursive")
        let untouched = fixture.appendingPathComponent("untouched")
        for dir in [own, local, sibling, recursive, untouched] {
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
        let pending = tracker.snapshotStatus()
        #expect(pending.phase == "recovery-pending")
        #expect(pending.indexReconciling && pending.nextRecoveryAt != nil)
        #expect(pending.recoveries == 0 && pending.droppedEvents == 1)
        #expect(tracker.search("late-applied").map(\.path) == [marker.path])
        let duringWait = untouched.appendingPathComponent("visible-while-pending.tmp")
        try tracker.deliverForTesting([VolumeEvent(path: duringWait.path, id: high + 3, flags: 0)],
                                     writing: { try Data([9]).write(to: duringWait) })
        #expect(tracker.search("visible-while-pending").map(\.path) == [duringWait.path])
        try awaitStatus(tracker) { $0.recoveries == 1 && $0.phase == "caught-up" }
        #expect(tracker.search("late-applied").map(\.path) == [marker.path])
        #expect(!tracker.snapshotStatus().indexReconciling)
    }

    @Test func recoveryKeepsSearchAvailableAndCoalescesLossUntilCooldownExpires() throws {
        let fixture = try scratch()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let own = fixture.appendingPathComponent("owned")
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        let existing = fixture.appendingPathComponent("stable.tmp")
        try Data([1]).write(to: existing)
        let added = fixture.appendingPathComponent("added-in-recovery.tmp")
        let timing = RecoveryTiming(quietWindow: 150_000_000, maximumWait: 800_000_000,
                                    minimumInterval: 2 * ReplayLag.second)
        let tracker = try ChangeTracker(root: fixture.path, snapshot: own.appendingPathComponent("index").path,
                                        ownData: own.path, wallTime: { Date().timeIntervalSince1970 },
                                        recoveryTiming: timing)
        tracker.start { phase in
            let status = tracker.snapshotStatus()
            guard phase == "scan-start", status.recoveries == 1 else { return }
            #expect(status.indexReconciling)
            #expect(tracker.search("stable").map(\.path) == [existing.path])
            #expect(throws: Never.self) { try Data([2, 3]).write(to: added) }
            tracker.simulateDroppedHistory()
            tracker.simulateDroppedHistory()
        }
        defer { try? tracker.stop() }
        try awaitStatus(tracker) { $0.phase == "caught-up" }
        tracker.simulateDroppedHistory()
        tracker.synchronize()
        #expect(tracker.snapshotStatus().recoveries == 0)
        #expect(tracker.search("stable").map(\.path) == [existing.path])
        try awaitStatus(tracker) { $0.recoveries == 1 && $0.phase == "recovery-pending" && $0.nextRecoveryAt != nil }
        let cooling = tracker.snapshotStatus()
        #expect(cooling.indexReconciling)
        #expect(cooling.droppedEvents == 3 && cooling.droppedDuringRecovery == 2)
        #expect(cooling.lastRecoveryNanoseconds.map { $0 > 0 } == true)
        #expect(cooling.nextRecoveryAt.map { $0 > Date().timeIntervalSince1970 + 0.5 } == true)
        #expect(tracker.search("stable").map(\.path) == [existing.path])

        // No sync, event injection or poll on the writer is needed to wake recovery.
        try awaitStatus(tracker) { $0.recoveries == 2 && $0.phase == "caught-up" }
        let expected = try FileManager.default.contentsOfDirectory(at: fixture, includingPropertiesForKeys: nil)
            .filter { $0.path != own.path }.map(\.path).sorted()
        #expect(tracker.search("", showAll: true).map(\.path).sorted() == expected)
        #expect(tracker.search("added-in-recovery").first?.size == 2)
        let settled = tracker.snapshotStatus()
        #expect(!settled.indexReconciling && settled.nextRecoveryAt == nil && settled.degradedVolumes.isEmpty)
        #expect(settled.droppedEvents == 3 && settled.recoveries == 2)
    }

    @Test func stoppingDuringRecoveryWaitRevokesTheSavedCheckpoint() throws {
        let fixture = try scratch()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let own = fixture.appendingPathComponent("owned")
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        let snapshot = own.appendingPathComponent("index").path
        let identity = try VolumeIdentity(root: fixture.path)
        let checkpoint = try #require(identity.observedBoundary())
        var base = try SearchIndex.scan(root: fixture.path, establishListener: false, excludedPaths: [own.path])
        base.volumes = [identity.checkpoint(checkpoint)]
        base.prepare()
        try base.savePrepared(to: snapshot)

        let first = try ChangeTracker(root: fixture.path, snapshot: snapshot, ownData: own.path)
        first.start()
        defer { try? first.stop() }
        try awaitStatus(first) { $0.phase == "caught-up" }
        #expect(first.snapshotStatus().durableEvents[fixture.path] == checkpoint)
        first.simulateDroppedHistory()
        try first.stop()
        #expect(first.snapshotStatus().recoveries == 0)
        #expect(first.snapshotStatus().durableEvents.isEmpty)

        let restarted = try ChangeTracker(root: fixture.path, snapshot: snapshot, ownData: own.path)
        restarted.start()
        defer { try? restarted.stop() }
        try awaitStatus(restarted) { $0.phase == "caught-up" }
        #expect(restarted.snapshotStatus().recovery == "invalid-checkpoint")
        #expect(restarted.snapshotStatus().startupRecoveryReason == "checkpoint-unusable")
        #expect(restarted.snapshotStatus().recoveries == 1)
    }

    @Test func exhaustedBudgetAllowsRecoveryAndLaterJournalWritesAcrossRestart() throws {
        let fixture = try scratch()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let own = fixture.appendingPathComponent("owned")
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        let snapshot = own.appendingPathComponent("index")
        var budget = BaseWriteBudget(snapshot: snapshot.path)
        #expect(try budget.reserve(at: 100))
        #expect(try budget.reserve(at: 200))

        func tracker() throws -> ChangeTracker {
            try ChangeTracker(root: fixture.path, snapshot: snapshot.path, ownData: own.path, wallTime: { 300 },
                              recoveryTiming: RecoveryTiming(quietWindow: 150_000_000))
        }

        let running = try tracker()
        running.start()
        defer { try? running.stop() }
        try awaitStatus(running) { $0.phase == "caught-up" && $0.baseWrites == 1 }
        let first = try SearchIndex.preparedIdentity(at: snapshot.path)
        let rebuilt = fixture.appendingPathComponent("recovered-fixture.tmp")
        try Data([1]).write(to: rebuilt)
        running.simulateDroppedHistory()
        try awaitStatus(running) { $0.phase == "caught-up" && $0.requiredBaseWrites == 2 }
        #expect(try SearchIndex.preparedIdentity(at: snapshot.path) != first)

        let incremental = fixture.appendingPathComponent("appended-fixture.tmp")
        try Data([2]).write(to: incremental)
        running.synchronize()
        try awaitStatus(running) { _ in running.search("appended-fixture").count == 1 }

        // This must reach disk during normal running, before stop is called.
        try awaitStatus(running, timeout: 22) { $0.journalLength > ChangeJournal.headerBytes }
        let persisted = running.snapshotStatus()
        #expect(persisted.journalFrames > 0 && persisted.baseWrites == 2 && persisted.automaticBaseWritesInWindow == 2)

        var disk = try SearchIndex.load(from: snapshot.path)
        var journal = ChangeJournal(snapshot: snapshot.path, identity: try SearchIndex.preparedIdentity(at: snapshot.path))
        try journal.restore(into: &disk, root: fixture.path, repairSuffix: false)
        #expect(Set(disk.restoredRows().map(\.path)).isSuperset(of: [rebuilt.path, incremental.path]))
        try running.stop()

        let reopened = try tracker()
        reopened.start()
        defer { try? reopened.stop() }
        try awaitStatus(reopened) { $0.phase == "caught-up" }
        #expect(reopened.snapshotStatus().rebuilds == 0)
        #expect(reopened.search("fixture.tmp").count == 2)
    }

    @Test func stoppingReturnsAtTheDeadlineWithAWriterStillBusy() throws {
        let fixture = try scratch()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let own = fixture.appendingPathComponent("owned")
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        let snapshot = own.appendingPathComponent("index")
        let running = try ChangeTracker(root: fixture.path, snapshot: snapshot.path, ownData: own.path)
        let arrived = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        running.start { phase in
            if phase == "scan-start" { arrived.signal(); _ = release.wait(timeout: .now() + .seconds(8)) }
        }
        defer { release.signal(); try? running.stop() }
        try #require(arrived.wait(timeout: .now() + .seconds(2)) == .success)
        let started = DispatchTime.now().uptimeNanoseconds
        #expect(throws: TrackerShutdownError.deadlineExceeded) {
            try running.stop(until: .now() + .milliseconds(100))
        }
        #expect(DispatchTime.now().uptimeNanoseconds - started < 1_000_000_000)
        release.signal()
        try running.stop()
        #expect(!FileManager.default.fileExists(atPath: snapshot.path))
    }

    private func awaitStatus(_ tracker: ChangeTracker, timeout: TimeInterval = 9,
                             _ ready: (TrackingStatus) -> Bool) throws {
        let end = Date().addingTimeInterval(timeout)
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
