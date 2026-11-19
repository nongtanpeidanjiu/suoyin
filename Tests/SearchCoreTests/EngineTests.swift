import Foundation
import Testing
@testable import SearchCore

@Suite(.serialized)
struct EngineTests {
    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".m2-tmp/engine-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }

    private func until(seconds: TimeInterval = 8, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    @Test func lifecycleQueriesAndPersistence() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("engine-data")
        let folder = root.appendingPathComponent("item-directory")
        let file = folder.appendingPathComponent("item-file")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data([1, 2, 3]).write(to: file)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("item-link"), withDestinationURL: folder)
        try Data().write(to: root.appendingPathComponent(".item-hidden"))

        let engine = try SearchEngine(dataDirectory: data, root: root.path)
        defer { engine.stop() }
        #expect(engine.status.phase == .starting)
        #expect(engine.search(EngineQuery(text: "item")).hits.isEmpty)
        engine.start()
        engine.start()
        try #require(until { engine.status.phase == .ready && engine.status.indexBytesOnDisk > 0 })
        #expect(engine.status.indexedCount == 4)
        for empty in ["", "   ", "\t\n"] {
            let result = engine.search(EngineQuery(text: empty))
            #expect(result.hits.isEmpty && result.total == 0 && result.totalIsExact)
        }
        let first = engine.search(EngineQuery(text: "item", limit: 1))
        #expect(first.hits.map(\.name) == ["item-directory"])
        #expect(first.total == 2 && !first.totalIsExact)
        let second = engine.search(EngineQuery(text: "item", offset: 1, limit: 2))
        #expect(second.hits.map(\.name) == ["item-file", "item-link"])
        #expect(second.total == 3 && second.totalIsExact)
        let all = engine.search(EngineQuery(text: "item", showAll: true))
        #expect(all.total == 4 && all.totalIsExact)
        #expect(all.hits.filter(\.isDirectory).map(\.name) == ["item-directory"])
        #expect(all.hits.allSatisfy { !$0.isCloudPlaceholder && $0.volumeID == nil })
        #expect(Set(all.hits.map(\.id)).count == 4)
        #expect(engine.search(EngineQuery(text: first.hits[0].path, mode: .path)).hits.first?.id == first.hits[0].id)
        let miss = engine.search(EngineQuery(text: "item", offset: 9))
        #expect(miss.hits.isEmpty && miss.total == 0 && !miss.totalIsExact)
        let hit = try #require(second.hits.first)
        #expect(hit.path == file.path && hit.size == 3)
        let modified = try #require(file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        #expect(abs(hit.modified.timeIntervalSince(modified)) < 0.001)

        engine.stop()
        let reopened = try SearchEngine(dataDirectory: data, root: root.path)
        defer { reopened.stop() }
        reopened.start()
        try #require(until { reopened.search(EngineQuery(text: "item-file")).total == 1 })
        #expect(reopened.search(EngineQuery(text: "engine-data", showAll: true)).hits.isEmpty)
    }

    @Test func permissionsNotificationAndManualRebuild() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("state")
        let folder = root.appendingPathComponent("restore")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data().write(to: folder.appendingPathComponent("known-file"))
        let tracker = try ChangeTracker(root: root.path, snapshot: data.appendingPathComponent("index.snapshot").path,
                                        ownData: data.path)
        let engine = SearchEngine(dataDirectory: data, tracker: tracker)
        defer { engine.stop() }
        let events = Events()
        engine.onStatusChange = { events.record($0) }
        engine.onIndexChange = { events.recordIndex() }
        engine.start()
        try #require(until { engine.status.phase == .ready && engine.status.indexBytesOnDisk > 0 })

        tracker.injectPermissionObservation(folder.path, .restricted)
        try #require(until { events.status?.inaccessiblePaths == [folder.path] })
        #expect(engine.search(EngineQuery(text: "known-file")).hits.isEmpty)
        engine.recheckAccess()
        try #require(until { engine.status.inaccessiblePaths.isEmpty })
        #expect(engine.search(EngineQuery(text: "known-file")).total == 1)
        for _ in 0..<10 { tracker.injectPermissionObservation(folder.path, .restricted) }
        try #require(until { engine.status.inaccessiblePaths == [folder.path] })
        engine.rebuild()
        try #require(until { tracker.snapshotStatus().recovery == "manual-rebuild" &&
            engine.status.phase == .ready && engine.status.inaccessiblePaths.isEmpty })
        #expect(engine.search(EngineQuery(text: "known-file")).total == 1)
        let times = events.indexTimes
        #expect(times.count >= 2)
        #expect(zip(times, times.dropFirst()).allSatisfy { $1 - $0 >= 245_000_000 })
        #expect(SearchEngine.topLevel(["/a/b", "/a", "/a", "/ab", "/a/c"]) == ["/a", "/ab"])
        #expect(SearchEngine.topLevel((0...220).map { "/dir-\($0)" }).count == 200)
    }

    @Test func placeholderAndVolumeFlagsUseIndexedMetadata() throws {
        var base = SearchIndex()
        let parent = base.append("/fixture", attribute: Kind.anchor)
        base.append("cloud-file", parent: parent, attribute: Kind.file | Kind.pending)
        base.append("cloud-directory", parent: parent, attribute: Kind.directory | Kind.pending | Kind.dataless)
        base.append("queued-directory", parent: parent, attribute: Kind.directory | Kind.pending)
        base.prepare()
        var live = LiveIndex(base: base, root: "/fixture")
        _ = live.reconcile(path: "/fixture/cloud-directory", observed: .readable(
            own: TrackedEntry(size: 5, modified: 9, attribute: Kind.directory | Kind.dataless),
            children: [:]), completingCloud: true)
        live.prepareDelta()
        func hit(_ name: String) throws -> EngineHit {
            EngineHit(try #require(live.search(name, mode: .name, column: .name, direction: .ascending,
                                               showAll: false, offset: 0, limit: 1).first))
        }
        #expect(try hit("cloud-file").isCloudPlaceholder)
        #expect(try hit("cloud-directory").isCloudPlaceholder && hit("cloud-directory").isDirectory)
        #expect(try !hit("queued-directory").isCloudPlaceholder && hit("queued-directory").isDirectory)

        var external = SearchRow(id: 7, name: "item", path: "/fixture/item", size: 0, modified: 0,
                                 volumeID: "fixture-volume", attribute: Kind.directory)
        external.volumeSlot = 2
        let externalHit = EngineHit(external)
        #expect(externalHit.id == (2 << 32) + 7 && externalHit.volumeID == "fixture-volume")
    }

    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var lastStatus: EngineStatus?
        private var times: [UInt64] = []
        var indexTimes: [UInt64] { lock.withLock { times } }
        var status: EngineStatus? { lock.withLock { lastStatus } }
        func record(_ status: EngineStatus) { lock.withLock { lastStatus = status } }
        func recordIndex() { lock.withLock { times.append(DispatchTime.now().uptimeNanoseconds) } }
    }
}
