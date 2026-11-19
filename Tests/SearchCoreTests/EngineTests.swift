import CoreServices
import Darwin
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

    @Test func localDenialsAreVerifiedWhileAnExternalSourceIsStillScanning() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("state")
        let local = root.appendingPathComponent("local")
        let external = root.appendingPathComponent("external")
        let denied = local.appendingPathComponent("blocked")
        for folder in [data, local, external, denied] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        try Data().write(to: external.appendingPathComponent("external-fixture.txt"))
        try Data([1]).write(to: local.appendingPathComponent("order-fixture-a"))
        try Data([1, 2]).write(to: external.appendingPathComponent("order-fixture-b"))
        try Data([1, 2, 3]).write(to: local.appendingPathComponent("order-fixture-c"))
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let mounts = ExternalVolumes(directory: data.path, discoverAutomatically: false, onAccess: { path in
            if path == external.path {
                entered.signal()
                _ = release.wait(timeout: .now() + .seconds(4))
            }
        })
        let tracker = try ChangeTracker(root: local.path, snapshot: data.appendingPathComponent("index.snapshot").path,
                                        ownData: data.path, wallTime: { Date().timeIntervalSince1970 },
                                        externalVolumes: mounts)
        let engine = SearchEngine(dataDirectory: data, tracker: tracker)
        defer { engine.stop() }
        defer { release.signal() }
        engine.includesNewExternalVolumes = true
        engine.start()
        try #require(until { engine.status.inaccessibleLocationsVerified })
        tracker.injectPermissionObservation(denied.path, .denied(EACCES))
        try #require(until { engine.status.inaccessibleLocationCount == 1 })
        let identity = try VolumeIdentity(root: external.path)
        let volume = VolumeIdentity(root: external.path, mount: external.path, device: identity.device,
                                    uuid: UUID().uuidString, log: nil, readOnly: false)
        #expect(ExternalMount(identity: volume, name: "Test media", fileEvents: false).scanWorkers == 1)
        #expect(ExternalMount(identity: volume, name: "Test media", fileEvents: false,
                              medium: .solidState).scanWorkers == 3)
        mounts.updateMounts([ExternalMount(identity: volume, name: "Test media", fileEvents: false,
                                            filesystem: "exfat", medium: .rotational)])
        try #require(entered.wait(timeout: .now() + .seconds(2)) == .success)
        try #require(until { engine.status.sources.contains { $0.kind == .externalVolume } })
        let checking = engine.status
        #expect(checking.inaccessibleLocationsVerified && checking.inaccessibleLocationCount == 1)
        #expect(checking.sources.first?.inaccessibleLocationsVerified == false)
        #expect(checking.sources.first?.indexed == 0)
        release.signal()
        try #require(until { engine.status.sources.first?.inaccessibleLocationsVerified == true })
        let ready = engine.status
        #expect(ready.sources.first?.indexed == 2)
        #expect(ready.sources.first?.scan?.workers == 2)
        #expect(ready.indexedCount == ready.localIndexedCount + 2)
        #expect(engine.search(EngineQuery(text: "external-fixture")).total == 1)
        let ordered = ["order-fixture-a", "order-fixture-b", "order-fixture-c"]
        for column in [SearchColumn.name, .size] {
            let first = engine.search(EngineQuery(text: "order-fixture", column: column, limit: 2))
            #expect(first.hits.map(\.name) == Array(ordered.prefix(2)))
            #expect(first.total == 3 && !first.totalIsExact)
            let last = engine.search(EngineQuery(text: "order-fixture", column: column, offset: 2, limit: 2))
            #expect(last.hits.map(\.name) == [ordered[2]] && last.totalIsExact)
            let reverse = engine.search(EngineQuery(text: "order-fixture", column: column, direction: .descending))
            #expect(reverse.hits.map(\.name) == Array(ordered.reversed()))
        }
    }

    @Test func externalOptInPersistsAndRemovalClearsAnOfflineCheckpoint() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("state")
        let local = root.appendingPathComponent("local")
        let external = root.appendingPathComponent("external")
        let second = root.appendingPathComponent("second")
        for directory in [data, local, external, second] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        try Data().write(to: external.appendingPathComponent("mounted-fixture.txt"))
        try Data().write(to: second.appendingPathComponent("second-fixture.txt"))
        let descendant = external.appendingPathComponent("descendant")
        try FileManager.default.createDirectory(at: descendant, withIntermediateDirectories: false)
        try Data().write(to: descendant.appendingPathComponent("nested-fixture.txt"))
        let device = try WalkScope.device(external.path)
        let volumeID = UUID().uuidString
        let anotherID = UUID().uuidString
        func mount(_ url: URL, _ id: String) -> ExternalMount {
            ExternalMount(identity: VolumeIdentity(root: url.path, mount: url.path, device: device,
                                                    uuid: id, log: nil, readOnly: false),
                          name: url.lastPathComponent, fileEvents: false, filesystem: "exfat",
                          detail: "Fixture detail")
        }
        func engine(_ manager: ExternalVolumes) throws -> SearchEngine {
            let tracker = try ChangeTracker(root: local.path, snapshot: data.appendingPathComponent("index.snapshot").path,
                                            ownData: data.path, wallTime: { Date().timeIntervalSince1970 },
                                            externalVolumes: manager)
            return SearchEngine(dataDirectory: data, tracker: tracker)
        }
        let first = mount(external, volumeID), newcomer = mount(second, anotherID)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let readDescendant = DispatchSemaphore(value: 0)
        let noticed = DispatchSemaphore(value: 0)
        let manager = ExternalVolumes(directory: data.path, discoverAutomatically: false, onAccess: { path in
            if path == external.path {
                entered.signal()
                _ = release.wait(timeout: .now() + 4)
            }
            if path == descendant.path { readDescendant.signal() }
        })
        let running = try engine(manager)
        defer { running.stop() }
        defer { release.signal() }
        running.onExternalVolumesChange = { noticed.signal() }
        running.start()
        manager.updateMounts([first])
        #expect(noticed.wait(timeout: .now() + 2) == .success)
        #expect(!running.includesNewExternalVolumes)
        #expect(running.externalVolumes.first?.isOnline == true)
        #expect(running.externalVolumes.first?.detail == "Fixture detail")
        #expect(running.externalVolumes.first?.isIncluded == false)
        #expect(manager.searchable().isEmpty)
        #expect(entered.wait(timeout: .now() + .milliseconds(100)) == .timedOut)
        running.includesNewExternalVolumes = true
        manager.updateMounts([first, newcomer])
        #expect(running.externalVolumes.first(where: { $0.id == volumeID })?.isIncluded == false)
        #expect(running.externalVolumes.first(where: { $0.id == anotherID })?.isIncluded == true)
        running.includesNewExternalVolumes = false
        #expect(running.externalVolumes.first(where: { $0.id == anotherID })?.isIncluded == true)
        running.setExternalVolume(volumeID, included: true)
        try #require(entered.wait(timeout: .now() + 2) == .success)
        #expect(running.externalVolumes.first(where: { $0.id == volumeID })?.isScanning == true)
        running.setExternalVolume(volumeID, included: false)
        #expect(!manager.searchable().contains(where: { $0.key == volumeID }))
        #expect(running.search(EngineQuery(text: "mounted-fixture")).total == 0)
        release.signal()
        #expect(readDescendant.wait(timeout: .now() + .milliseconds(200)) == .timedOut)
        release.signal()
        running.setExternalVolume(volumeID, included: true)
        #expect(until {
            running.status.sources.first(where: { $0.id == volumeID })?.inaccessibleLocationsVerified == true &&
                running.search(EngineQuery(text: "mounted-fixture")).total == 1
        })
        running.setExternalVolume(volumeID, included: false)
        #expect(running.search(EngineQuery(text: "mounted-fixture")).total == 0)
        let checkpoint = data.appendingPathComponent("external-volumes/\(volumeID)-exfat.scanlog")
        #expect(FileManager.default.fileExists(atPath: checkpoint.path))
        running.stop()

        let reopenedManager = ExternalVolumes(directory: data.path, discoverAutomatically: false)
        let reopened = try engine(reopenedManager)
        defer { reopened.stop() }
        reopened.start()
        #expect(!reopened.includesNewExternalVolumes)
        #expect(reopened.externalVolumes.first(where: { $0.id == anotherID })?.isIncluded == true)
        #expect(reopened.externalVolumes.first(where: { $0.id == volumeID })?.isIncluded == false)
        reopenedManager.updateMounts([first])
        #expect(reopenedManager.searchable().isEmpty)
        reopened.setExternalVolume(volumeID, included: true)
        #expect(until {
            reopened.status.sources.first(where: { $0.id == volumeID })?.scan?.restoredEntries == 3 &&
                reopened.search(EngineQuery(text: "mounted-fixture")).total == 1
        })
        reopenedManager.updateMounts([])
        #expect(reopened.externalVolumes.first(where: { $0.id == volumeID })?.isOnline == false)
        reopened.removeExternalVolumeData(volumeID)
        #expect(until { !FileManager.default.fileExists(atPath: checkpoint.path) })
        #expect(reopened.externalVolumes.first(where: { $0.id == volumeID })?.isIncluded == false)
        reopened.stop()

        let lastManager = ExternalVolumes(directory: data.path, discoverAutomatically: false)
        defer { try? lastManager.stop() }
        lastManager.updateMounts([first])
        #expect(lastManager.searchable().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: checkpoint.path))
    }

    @Test func upgradingKeepsVolumesWithExistingIndexArtifactsIncluded() throws {
        let data = try scratch()
        defer { try? FileManager.default.removeItem(at: data) }
        let cache = data.appendingPathComponent("external-volumes")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
        let apfs = UUID().uuidString
        let exfat = UUID().uuidString
        let log = UUID().uuidString
        let base = cache.appendingPathComponent("\(apfs)-\(log).snapshot")
        var index = SearchIndex()
        index.append("/fixture", attribute: Kind.anchor)
        index.prepare()
        try index.savePrepared(to: base.path)
        let delta = cache.appendingPathComponent("\(apfs)-\(log).snapshot.changes")
        try Data().write(to: delta)
        let checkpoint = try ExternalScanLog(path: cache.appendingPathComponent("\(exfat)-exfat.scanlog").path)
        try checkpoint.flush()
        let manager = ExternalVolumes(directory: data.path, discoverAutomatically: false)
        defer { try? manager.stop() }
        #expect(!manager.includesNew)
        #expect(Set(manager.catalog().filter(\.isIncluded).map(\.id)) == Set([apfs, exfat]))
        #expect(manager.catalog().allSatisfy { !$0.isOnline })
        manager.removeData(apfs)
        #expect(!FileManager.default.fileExists(atPath: base.path))
        #expect(!FileManager.default.fileExists(atPath: delta.path))
        #expect(manager.catalog().first(where: { $0.id == exfat })?.isIncluded == true)
    }

    @Test func kindsComposeWithPagingOrderingAndPublishedEdits() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("state")
        let documents = ["sample.PDF", ".sample.TXT", "sample.pages"]
        let folders = ["sample-directory", "sample.APP", "sample.pages"]
        let files = documents.dropLast() + ["sample.HEIC", "sample.CR3", "sample.FLAC", "sample.MOV",
                                            "sample.tar.GZ", "sample.dmg", "sample-not-a-package.app"]
        for name in folders {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name),
                                                    withIntermediateDirectories: false)
        }
        for (size, name) in files.enumerated() {
            try Data(repeating: 0, count: size).write(to: root.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: false)
        let tracker = try ChangeTracker(root: root.path, snapshot: data.appendingPathComponent("index.snapshot").path,
                                        ownData: data.path)
        let engine = SearchEngine(dataDirectory: data, tracker: tracker)
        defer { engine.stop() }
        engine.start()
        try #require(until { engine.status.inaccessibleLocationsVerified })

        let expected: [EngineKind: [String]] = [
            .folder: folders, .document: documents, .image: ["sample.HEIC", "sample.CR3"],
            .audio: ["sample.FLAC"], .video: ["sample.MOV"],
            .archive: ["sample.tar.GZ", "sample.dmg"], .application: ["sample.APP"]
        ]
        for mode in [QueryMode.name, .path] {
            for column in [SearchColumn.name, .path, .size, .modified] {
                for direction in [SearchDirection.ascending, .descending] {
                    for showAll in [false, true] {
                        let text = mode == .name ? "sample" : root.path + "/ sample"
                        var query = EngineQuery(text: text, mode: mode, column: column,
                                                direction: direction, showAll: showAll)
                        let all = engine.search(query).hits.map(\.name)
                        for (kind, names) in expected {
                            query.kind = kind
                            let result = engine.search(query)
                            let matched = all.filter { names.contains($0) }
                            #expect(result.hits.map(\.name) == matched)
                            #expect(result.totalIsExact && result.total == matched.count)
                        }
                    }
                }
            }
        }
        let wrongKind = EngineQuery(text: root.path + "/sample.HEIC", mode: .path, kind: .video)
        #expect(engine.search(wrongKind).hits.isEmpty)
        var page = EngineQuery(text: "sample", kind: .image, limit: 1)
        let first = engine.search(page)
        #expect(first.hits.count == 1 && first.total == 2 && !first.totalIsExact)
        page.offset = 1
        let second = engine.search(page)
        #expect(second.hits.count == 1 && second.total == 2 && second.totalIsExact)
        page.text = " \t"
        #expect(engine.search(page).hits.isEmpty && engine.search(page).totalIsExact)

        try FileManager.default.moveItem(at: root.appendingPathComponent("sample.HEIC"),
                                         to: root.appendingPathComponent("sample.MP4"))
        tracker.recheckCoverage(at: [root.path])
        tracker.synchronize()
        #expect(engine.search(EngineQuery(text: "sample", kind: .image)).hits.map(\.name) == ["sample.CR3"])
        #expect(engine.search(EngineQuery(text: "sample", kind: .video)).hits.count == 2)
        engine.stop()

        let reopened = try SearchEngine(dataDirectory: data, root: root.path)
        defer { reopened.stop() }
        reopened.start()
        try #require(until { reopened.status.inaccessibleLocationsVerified })
        #expect(reopened.search(EngineQuery(text: "sample", kind: .application)).hits.map(\.name) == ["sample.APP"])
        #expect(reopened.search(EngineQuery(text: "sample", kind: .video)).hits.count == 2)
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
        #expect(engine.status.inaccessibleLocationCount == 1)
        #expect(engine.status.rawInaccessibleLocations == [
            InaccessibleLocation(path: folder.path, count: 1, reason: .unknown)
        ])
        tracker.injectPermissionObservation(folder.path, .denied(EACCES))
        try #require(until { events.status?.inaccessibleLocations.first?.reason == .filePermissions })
        #expect(engine.search(EngineQuery(text: "known-file")).hits.isEmpty)
        engine.recheckAccess()
        try #require(until { engine.status.inaccessibleLocationsVerified && engine.status.inaccessiblePaths.isEmpty })
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
    }

    @Test func denialReportWaitsForRevocationAndRevalidatesPersistedDenialsOnGrant() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("state")
        let documents = root.appendingPathComponent("Documents")
        let child = documents.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data().write(to: child.appendingPathComponent("protected-record.txt"))
        let trace = AccessTrace()
        trace.granted = true
        let access = ContainerAccess(home: root.path, probe: { trace.granted })
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        func makeEngine() throws -> (SearchEngine, ChangeTracker) {
            let tracker = try ChangeTracker(root: root.path, snapshot: data.appendingPathComponent("index.snapshot").path,
                                            ownData: data.path, wallTime: { Date().timeIntervalSince1970 },
                                            containerAccess: access, accessObservation: { path in
                guard path == documents.path else { return nil }
                entered.signal()
                _ = resume.wait(timeout: .now() + .seconds(5))
                return trace.granted ? nil : .denied(EPERM)
            })
            return (SearchEngine(dataDirectory: data, tracker: tracker), tracker)
        }
        let (engine, tracker) = try makeEngine()
        defer { engine.stop() }
        engine.start()
        try #require(until { engine.status.inaccessibleLocationsVerified })
        let query = EngineQuery(text: "protected-record")
        #expect(engine.search(query).total == 1)
        tracker.injectPermissionObservation(child.path, .denied(EACCES))
        try #require(until { engine.status.rawInaccessibleLocations.map(\.path) == [child.path] })

        trace.granted = false
        engine.recheckAccess()
        try #require(entered.wait(timeout: .now() + .seconds(3)) == .success)
        #expect(until { !engine.status.inaccessibleLocationsVerified && engine.status.inaccessibleLocationCount == 0 })
        resume.signal()
        try #require(until {
            engine.status.inaccessibleLocationsVerified && engine.status.rawInaccessibleLocations.map(\.path) == [documents.path]
        })
        #expect(engine.search(query).hits.isEmpty)
        try tracker.save()
        engine.stop()

        trace.granted = true
        let (reopened, reopenedTracker) = try makeEngine()
        defer { reopened.stop() }
        reopened.start()
        try #require(entered.wait(timeout: .now() + .seconds(3)) == .success)
        #expect(!reopened.status.inaccessibleLocationsVerified && reopened.status.inaccessibleLocationCount == 0)
        resume.signal()
        // The restored scope is observed again during reconciliation.
        resume.signal()
        try #require(until { reopened.status.inaccessibleLocationsVerified })
        #expect(reopened.status.inaccessibleLocationCount == 0)
        #expect(reopened.search(query).total == 1)
        #expect(reopenedTracker.snapshotStatus().coverageRestricted.isEmpty)
    }

    @Test func inaccessibleLocationsPreserveCountsAndReasonsAcrossTheDisk() {
        let raw: [InaccessibleLocation] = [
            .init(path: "/Library/Fixture", count: 1, reason: .filePermissions),
            .init(path: "/Library/Fixture/Child", count: 1, reason: .filePermissions),
            .init(path: "/Library/Other", count: 1, reason: .filePermissions),
            .init(path: "/Library/Fixture/Unknown", count: 1, reason: .unknown),
            .init(path: "/System/Fixture", count: 1, reason: .unknown),
            .init(path: "/private/var/Fixture", count: 1, reason: .filePermissions),
            .init(path: "/Users/fixture/Documents/A", count: 1, reason: .likelyNeedsFullDiskAccess),
            .init(path: "/Users/fixture/Documents/B", count: 1, reason: .likelyNeedsFullDiskAccess),
            .init(path: "/Volumes/Fixture disk/Folder", count: 1, reason: .filePermissions)
        ]
        let grouped = AccessDenials.summarize(raw)
        #expect(grouped == [
            .init(path: "/Library", count: 3, reason: .filePermissions),
            .init(path: "/Library/Fixture/Unknown", count: 1, reason: .unknown),
            .init(path: "/System/Fixture", count: 1, reason: .unknown),
            .init(path: "/Users/fixture/Documents", count: 2, reason: .likelyNeedsFullDiskAccess),
            .init(path: "/Volumes/Fixture disk/Folder", count: 1, reason: .filePermissions),
            .init(path: "/private/var/Fixture", count: 1, reason: .filePermissions)
        ])
        #expect(grouped.reduce(0) { $0 + $1.count } == raw.count)
        let branches = (0...220).map { InaccessibleLocation(path: "/Library/Branch-\($0)/Leaf", count: 1, reason: .unknown) }
        #expect(AccessDenials.summarize(branches) == branches.sorted { $0.path < $1.path })

        let observed = AccessDenials(home: "/Users/fixture")
        #expect(observed.reason(at: "/Users/fixture/Documents/A", error: EPERM, missingFullDiskAccess: true)
            == .likelyNeedsFullDiskAccess)
        #expect(observed.reason(at: dataRoot + "/Users/fixture/Documents/A", error: EPERM, missingFullDiskAccess: true)
            == .likelyNeedsFullDiskAccess)
        #expect(observed.reason(at: "/Users/fixture/Documents/A", error: EACCES, missingFullDiskAccess: true) == .filePermissions)
        #expect(observed.reason(at: "/Users/fixture/Documents/A", error: EPERM, missingFullDiskAccess: false) == .unknown)
        #expect(observed.reason(at: "/System/Fixture", error: EPERM, missingFullDiskAccess: true) == .unknown)
        #expect(observed.reason(at: "/Users/fixture/Documents2", error: EPERM, missingFullDiskAccess: true) == .unknown)
        #expect(observed.reason(at: "/Users/fixture/Library/Mail", error: nil, missingFullDiskAccess: true) == .unknown)
    }

    @Test func aDeniedEntryDoesNotHideItsReadableSiblings() {
        var base = SearchIndex()
        let parent = base.append("/fixture", attribute: Kind.anchor)
        base.append("denied", parent: parent, attribute: Kind.file)
        base.append("readable", parent: parent, attribute: Kind.file)
        base.prepare()
        let folder = TrackedEntry(size: 0, modified: 0, attribute: Kind.directory)
        let leaf = TrackedEntry(size: 0, modified: 0, attribute: Kind.file)
        var index = LiveIndex(base: base, root: "/fixture")
        _ = index.reconcile(path: "/fixture", observed: .readable(own: folder, children: ["readable": leaf],
                                                                  denied: ["denied": EACCES]))
        #expect(index.entry(at: "/fixture/denied") == nil)
        #expect(index.entry(at: "/fixture/readable") != nil)
        #expect(index.state.restricted == ["/fixture/denied"])
        #expect(index.state.denialErrors == ["/fixture/denied": EACCES])
        _ = index.reconcile(path: "/fixture", observed: .readable(own: folder,
                                                                  children: ["readable": leaf, "denied": leaf]))
        #expect(index.state.restricted.isEmpty)
        #expect(index.state.denialErrors?.isEmpty == true)
        #expect(index.entry(at: "/fixture/denied") != nil)
    }

    @Test func protectedContainersAreNeverProbedUntilAuthorized() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: false)
        let trace = AccessTrace()
        let access = ContainerAccess(home: root.path, probe: { trace.granted })
        for (i, path) in access.roots.enumerated() {
            let child = URL(fileURLWithPath: path).appendingPathComponent("app-data")
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            try Data().write(to: child.appendingPathComponent("private-fixture-\(i)"))
        }
        #expect(access.paths(includeDataAliases: true) == access.roots + access.roots.map { dataRoot + $0 })
        func start() throws -> (SearchEngine, ChangeTracker) {
            let tracker = try ChangeTracker(root: root.path, snapshot: data.appendingPathComponent("index.snapshot").path,
                                            ownData: data.path, wallTime: { Date().timeIntervalSince1970 },
                                            containerAccess: access, onAccess: { trace.record($0) })
            let engine = SearchEngine(dataDirectory: data, tracker: tracker)
            engine.start()
            return (engine, tracker)
        }
        let query = EngineQuery(text: "private-fixture", showAll: true)
        let (engine, tracker) = try start()
        defer { engine.stop() }
        try #require(until { engine.status.awaitingFullDiskAccess && engine.status.indexBytesOnDisk > 0 })
        #expect(engine.status.pendingFullDiskAccessPaths == access.roots)
        #expect(engine.status.pendingFullDiskAccessCount == 2)
        #expect(engine.status.inaccessibleLocationCount == 0)
        #expect(trace.paths(under: access.roots).isEmpty)
        trace.reset()
        let parent = parentPath(access.roots[0])
        let changed = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagItemIsDir)
        try tracker.deliverForTesting([
            VolumeEvent(path: parent, id: 900, flags: changed),
            VolumeEvent(path: access.roots[0], id: 901, flags: UInt32(kFSEventStreamEventFlagItemIsDir)),
            VolumeEvent(path: access.roots[1] + "/app-data/private-fixture-1", id: 902, flags: 0)
        ])
        tracker.recheckCoverage(at: access.roots)
        engine.recheckAccess()
        tracker.synchronize()
        #expect(trace.paths(under: [parent]).contains(parent))
        #expect(trace.paths(under: access.roots).isEmpty)
        engine.rebuild()
        try #require(until { tracker.snapshotStatus().recovery == "manual-rebuild" &&
            tracker.snapshotStatus().phase == "caught-up" })
        #expect(engine.search(query).hits.isEmpty)
        #expect(engine.status.inaccessiblePaths.isEmpty)
        #expect(trace.paths(under: access.roots).isEmpty)
        engine.stop()

        trace.granted = true
        let (reopened, reopenedTracker) = try start()
        defer { reopened.stop() }
        try #require(until { reopened.search(query).total == 2 })
        #expect(access.roots.allSatisfy { !trace.paths(under: [$0]).isEmpty })
        try #require(until { reopenedTracker.snapshotStatus().phase == "caught-up" })
        reopened.stop()

        trace.granted = false
        trace.reset()
        let (restricted, restrictedTracker) = try start()
        defer { restricted.stop() }
        try #require(until { restricted.status.awaitingFullDiskAccess && restricted.status.phase == .ready })
        #expect(restricted.search(query).hits.isEmpty)
        #expect(restricted.status.inaccessiblePaths.isEmpty)
        #expect(trace.paths(under: access.roots).isEmpty)

        trace.granted = true
        restricted.recheckAccess()
        try #require(until { !restricted.status.awaitingFullDiskAccess && restricted.search(query).total == 2 })
        #expect(restricted.status.pendingFullDiskAccessPaths.isEmpty)
        #expect(restricted.status.pendingFullDiskAccessCount == 0)
        trace.granted = false
        trace.reset()
        restricted.recheckAccess()
        restrictedTracker.synchronize()
        try #require(until { restricted.status.awaitingFullDiskAccess })
        #expect(restricted.search(query).hits.isEmpty)
        #expect(trace.paths(under: access.roots).isEmpty)
    }

    @Test func manualRebuildBypassesLossDelayAndKeepsOldView() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: false)
        try Data().write(to: root.appendingPathComponent("stable-fixture"))
        let timing = RecoveryTiming(quietWindow: 30 * ReplayLag.second)
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let trace = AccessTrace()
        let tracker = try ChangeTracker(root: root.path, snapshot: data.appendingPathComponent("index.snapshot").path,
                                        ownData: data.path, wallTime: { Date().timeIntervalSince1970 },
                                        recoveryTiming: timing, onAccess: { path in
            if path == root.path && trace.granted {
                entered.signal()
                _ = resume.wait(timeout: .now() + .seconds(5))
            }
        })
        let engine = SearchEngine(dataDirectory: data, tracker: tracker)
        engine.start()
        defer { engine.stop() }
        defer { resume.signal() }
        try #require(until { tracker.snapshotStatus().phase == "caught-up" })

        tracker.simulateDroppedHistory()
        tracker.synchronize()
        #expect(tracker.snapshotStatus().nextRecoveryAt ?? 0 > Date().timeIntervalSince1970 + 20)
        trace.granted = true
        engine.rebuild()
        try #require(entered.wait(timeout: .now() + .seconds(3)) == .success)
        try #require(until(seconds: 2) { engine.status.phase == .recovering })
        #expect(engine.search(EngineQuery(text: "stable-fixture")).total == 1)
        resume.signal()
        try #require(until { tracker.snapshotStatus().phase == "caught-up" })
        #expect(tracker.snapshotStatus().recovery == "manual-rebuild")

        tracker.simulateDroppedHistory()
        tracker.synchronize()
        let next = try #require(tracker.snapshotStatus().nextRecoveryAt)
        #expect(next < Date().timeIntervalSince1970 + 40)
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

    private final class AccessTrace: @unchecked Sendable {
        private let lock = NSLock()
        private var observations: [String] = []
        private var allowed = false

        var granted: Bool {
            get { lock.withLock { allowed } }
            set { lock.withLock { allowed = newValue } }
        }

        func record(_ path: String) { lock.withLock { observations.append(path) } }
        func reset() { lock.withLock { observations.removeAll() } }
        func paths(under roots: [String]) -> [String] {
            lock.withLock { observations.filter { path in roots.contains { inside(path, $0) } } }
        }
    }
}
