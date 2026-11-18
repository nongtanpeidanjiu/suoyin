import CoreServices
import Darwin
import Foundation

struct VolumeEvent {
    let path: String
    let id: UInt64
    let flags: UInt32

    var historyDone: Bool { flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 }
    var recursive: Bool { flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 }
    var isDirectory: Bool { flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 }
    var structural: Bool {
        flags & UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved |
                       kFSEventStreamEventFlagItemRenamed) != 0
    }
    var invalidatesHistory: Bool {
        flags & UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped |
                       kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged) != 0
    }
}

struct VolumeIdentity {
    let root: String
    let mount: String
    let device: Int32
    let uuid: String?
    let log: String?
    let readOnly: Bool

    init(root: String) throws {
        self.root = root
        var info = statfs()
        guard statfs(root, &info) == 0 else { throw ScanError.metadata(path: root, error: errno) }
        let length = MemoryLayout.size(ofValue: info.f_mntonname)
        mount = withUnsafePointer(to: &info.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: length) {
                String(cString: $0)
            }
        }
        device = info.f_fsid.val.0
        uuid = try URL(fileURLWithPath: root).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        log = FSEventsCopyUUIDForDevice(device).map { CFUUIDCreateString(nil, $0) as String }
        readOnly = info.f_flags & UInt32(MNT_RDONLY) != 0
    }

    func observedBoundary() -> UInt64? {
        let number = FSEventsGetLastEventIdForDeviceBeforeTime(device, Date().timeIntervalSince1970)
        return number == 0 || number == UInt64.max ? nil : number
    }

    func checkpoint(_ event: UInt64?) -> VolumeCheckpoint {
        VolumeCheckpoint(root: root, volumeUUID: uuid, eventLogUUID: log,
                         mountedDevice: device, readOnly: readOnly, appliedEvent: event)
    }

    func permitsReplay(_ checkpoint: VolumeCheckpoint?) -> Bool {
        guard let checkpoint, let applied = checkpoint.appliedEvent, let current = observedBoundary(),
              let uuid, let log, checkpoint.volumeUUID == uuid, checkpoint.eventLogUUID == log
        else { return false }
        return applied <= current
    }
}

final class VolumeEventStream {
    private let queue = DispatchQueue(label: "index.volume-events")
    private var stream: FSEventStreamRef?
    let volume: VolumeIdentity
    let deliver: ([VolumeEvent]) -> Void

    init(volume: VolumeIdentity, since: UInt64?, deliver: @escaping ([VolumeEvent]) -> Void) throws {
        self.volume = volume
        self.deliver = deliver
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents)
        guard let value = FSEventStreamCreateRelativeToDevice(
            nil, { _, info, count, paths, flags, ids in
                guard let info else { return }
                let source = Unmanaged<VolumeEventStream>.fromOpaque(info).takeUnretainedValue()
                let names = paths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
                var batch: [VolumeEvent] = []
                batch.reserveCapacity(count)
                for i in 0..<count {
                    let path = names[i].map { String(cString: $0) } ?? ""
                    batch.append(VolumeEvent(path: path, id: ids[i], flags: flags[i]))
                }
                source.deliver(batch)
            }, &context, volume.device, [""] as CFArray, since ?? UInt64.max, 0.12, flags)
        else { throw ScanError.listener(root: volume.root) }
        FSEventStreamSetDispatchQueue(value, queue)
        guard FSEventStreamStart(value) else {
            FSEventStreamInvalidate(value)
            FSEventStreamRelease(value)
            throw ScanError.listener(root: volume.root)
        }
        stream = value
    }

    func flush() {
        if let stream { FSEventStreamFlushSync(stream) }
    }

    func stop() {
        guard let value = stream else { return }
        stream = nil
        FSEventStreamStop(value)
        FSEventStreamInvalidate(value)
        FSEventStreamRelease(value)
        queue.sync {}
    }

    deinit { stop() }
}

struct EventCursor {
    var applied: UInt64?
    private(set) var lastSeen: UInt64?
    private(set) var historyDelivered = false
    private let replaying: Bool

    init(applied: UInt64?, replaying: Bool = false) {
        self.applied = applied
        lastSeen = applied
        self.replaying = replaying
    }

    /// A larger, nonconsecutive ID is normal. Regressions and invalidating
    /// flags require a new baseline. The caller acknowledges after applying.
    mutating func received(_ event: VolumeEvent) -> Bool {
        receivedBatch([event])
    }

    /// A callback may coalesce paths whose IDs aren't presented in order.
    /// Compare the callback boundary, as FSEventStreamGetLatestEventId does.
    mutating func receivedBatch(_ events: [VolumeEvent]) -> Bool {
        var boundary: UInt64?
        var done = false
        for event in events {
            if event.invalidatesHistory { return false }
            if event.historyDone { done = true; continue }
            if event.id == 0 || event.id == UInt64.max { return false }
            boundary = max(boundary ?? 0, event.id)
        }
        if let boundary {
            if lastSeen.map({ boundary < $0 }) == true && !(replaying && !historyDelivered) { return false }
            lastSeen = max(lastSeen ?? 0, boundary)
        }
        if done { historyDelivered = true }
        return true
    }

    mutating func acknowledge(_ id: UInt64?) {
        guard let id else { return }
        if applied.map({ id > $0 }) ?? true { applied = id }
    }
}
