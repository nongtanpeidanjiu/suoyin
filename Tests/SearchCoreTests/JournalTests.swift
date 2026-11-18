import CoreServices
import Foundation
import Testing
@testable import SearchCore

struct JournalTests {
    private let volume = VolumeCheckpoint(root: "/fixture", volumeUUID: "fixture",
        eventLogUUID: "test-log", mountedDevice: nil, readOnly: false, appliedEvent: 10)
    private let item = TrackedEntry(size: 17, modified: 23, attribute: Kind.file)

    private func base() -> SearchIndex {
        var index = SearchIndex()
        let root = index.append("/fixture", attribute: Kind.anchor)
        index.append("old", parent: root)
        index.volumes = [volume]
        index.tracking = TrackingState(root: "/fixture", changes: [:], restricted: [])
        index.prepare()
        return index
    }

    private func scratch() throws -> URL {
        let url = URL(fileURLWithPath: ".m2-tmp", isDirectory: true)
            .appendingPathComponent("journal-fixture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test(arguments: [true, false])
    func damagedFrameDiscardsThatFrameAndAllFollowingFrames(truncate: Bool) throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("index.tmp").path
        let digest = Data(repeating: 7, count: 32)
        var journal = ChangeJournal(snapshot: path, identity: digest)
        try journal.append(JournalFrame(rows: [.init(path: "/fixture/new", value: item)], masks: [(1, true)],
                                        coverage: [("/fixture/locked", true)], positions: ["/fixture": 20]))
        let validEnd = journal.length
        try journal.append(JournalFrame(rows: [.init(path: "/fixture/new", value: nil)], masks: [(1, false)],
                                        coverage: [("/fixture/locked", false)], positions: ["/fixture": 30]))
        if !truncate {
            try journal.append(JournalFrame(rows: [], masks: [], coverage: [], positions: ["/fixture": 40]))
        }
        let file = URL(fileURLWithPath: journal.path)
        var bytes = try Data(contentsOf: file)
        #expect(Array(bytes[8..<12]) == [1, 0, 0, 0])
        if truncate { bytes.removeLast() }
        else { bytes[validEnd + 6] ^= 1 }
        try bytes.write(to: file)

        var index = base()
        var reader = ChangeJournal(snapshot: path, identity: digest)
        try reader.restore(into: &index, root: "/fixture")
        #expect(reader.repair == "discarded-suffix")
        #expect(reader.length == validEnd)
        #expect(try Data(contentsOf: file).count == validEnd)
        #expect(index.volumes[0].appliedEvent == 20)
        #expect(index.tracking?.changes == ["/fixture/new": item])
        #expect(index.tracking?.restricted == ["/fixture/locked"])
        #expect(index.restoredRows().map(\.name) == ["new"])
    }

    @Test func journalCannotAdvanceADifferentBaseAndMissingJournalIsHarmless() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("index.tmp").path
        var index = base()
        var reader = ChangeJournal(snapshot: path, identity: Data(repeating: 1, count: 32))
        try reader.restore(into: &index, root: "/fixture")
        #expect(reader.repair == "missing")
        var old = ChangeJournal(snapshot: path, identity: Data(repeating: 2, count: 32))
        try old.append(JournalFrame(rows: [], masks: [(1, true)], coverage: [], positions: ["/fixture": 99]))
        try reader.restore(into: &index, root: "/fixture")
        #expect(reader.repair == "identity-or-version")
        #expect(index.volumes[0].appliedEvent == 10)
        #expect(index.restoredRows().map(\.name) == ["old"])
    }

    @Test func journalDeltaUsesFinalValuesAndOmitsUnchangedRows() {
        let old = JournalImage(rows: ["/fixture/old": item], masks: [4], coverage: [], positions: ["/fixture": 10])
        let current = JournalImage(rows: ["/fixture/new": item], masks: [2], coverage: ["/fixture/private"],
                                   positions: ["/fixture": 20])
        let frame = current.delta(after: old)
        #expect(frame?.rows.map(\.path) == ["/fixture/new", "/fixture/old"])
        #expect(frame?.masks.map(\.0) == [1, 2])
        #expect(frame?.positions["/fixture"] == 20)
        #expect(current.delta(after: current) == nil)
    }

    @Test func compactionPreservesMetadataAndNestedDirectoryEdits() {
        var index = base()
        let directory = index.append("folder", parent: 0, attribute: Kind.directory)
        index.append("descendant", parent: directory, size: 5, modified: 8)
        index.prepared = nil
        index.prepare()
        var live = LiveIndex(base: index, root: "/fixture")
        let folder = TrackedEntry(size: 4, modified: 9, attribute: Kind.directory)
        _ = live.reconcile(path: "/fixture", observed: .readable(own: folder,
            children: ["folder": folder, "addition": item]))
        live.prepareDelta()
        let before = live.archive().restoredRows().map { [$0.path, String($0.size), String($0.modified)] }
        let compacted = live.compacted()
        let after = compacted.restoredRows().map { [$0.path, String($0.size), String($0.modified)] }
        #expect(before == after)
        #expect(compacted.tracking?.changes.isEmpty == true)
        #expect(compacted.suppressed.isEmpty)
    }

    @Test func registeredPositionCannotMakeFirstDeliveryARegression() {
        var cursor = EventCursor(applied: 999)
        let first = cursor.received(VolumeEvent(path: "first", id: 90, flags: 0))
        #expect(first)
        #expect(cursor.lastSeen == 90)
        #expect(cursor.applied == 999)
        let second = cursor.received(VolumeEvent(path: "next", id: 89, flags: 0))
        #expect(!second)
    }

    @Test func rebuildCooldownIsPerVolume() {
        var rule = RebuildThrottle()
        let first = rule.allow(volume: 0, now: 100)
        let early = rule.allow(volume: 0, now: 101)
        let other = rule.allow(volume: 1, now: 101)
        let later = rule.allow(volume: 0, now: 100 + RebuildThrottle.interval)
        #expect(first && !early && other && later)
    }

    @Test func historicalBatchesCanArriveOutOfOrderWithoutSkippingUnappliedHistory() {
        let historyDone = UInt32(kFSEventStreamEventFlagHistoryDone)
        var cursor = EventCursor(applied: 10, replaying: true)
        let before = cursor.received(VolumeEvent(path: "recent-prefix", id: 99, flags: 0))
        cursor.acknowledge(99)
        let older = cursor.received(VolumeEvent(path: "earlier-prefix", id: 85, flags: 0))
        cursor.acknowledge(85)
        #expect(before && older && cursor.applied == 10)
        let end = cursor.received(VolumeEvent(path: "", id: 0, flags: historyDone))
        cursor.acknowledge(nil)
        #expect(end && cursor.applied == 99 && cursor.lastSeen == nil)
        let live = cursor.received(VolumeEvent(path: "live", id: 101, flags: 0))
        let backward = cursor.received(VolumeEvent(path: "backward", id: 100, flags: 0))
        #expect(live && !backward)
    }
}
