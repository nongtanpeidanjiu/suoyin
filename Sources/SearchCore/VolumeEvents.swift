import CoreServices
import Darwin
import DarwinMetadata
import Foundation

struct VolumeEvent {
    let path: String
    let id: UInt64
    let flags: UInt32

    var historyDone: Bool { flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 }
    var recursive: Bool { flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 }
    var isDirectory: Bool { flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 }
    var renamed: Bool { flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 }
    var structural: Bool {
        flags & UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved |
                       kFSEventStreamEventFlagItemRenamed) != 0
    }
    var contentOnly: Bool {
        let required = UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified)
        let allowed = required | UInt32(kFSEventStreamEventFlagItemInodeMetaMod |
                                       kFSEventStreamEventFlagItemIsHardlink | kFSEventStreamEventFlagItemIsLastHardlink)
        return flags & required == required && flags & ~allowed == 0
    }
    var invalidatesHistory: Bool {
        flags & UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped |
                       kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged) != 0
    }

    var dropped: Bool {
        flags & UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0
    }

    var invalidPosition: Bool { invalidatesHistory || !historyDone && (id == 0 || id == .max) }
}

struct ScanBoundary {
    let marker: String
    let after: UInt64

    func covered(by event: VolumeEvent, at path: String) -> Bool {
        path == marker || event.recursive && event.id > after && inside(marker, path)
    }
}

struct VolumeIdentity {
    let root: String
    let mount: String
    let device: Int32
    let uuid: String?
    let log: String?
    let readOnly: Bool

    init(root: String, preferFilesystemUUID: Bool = false) throws {
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
        let filesystemUUID = preferFilesystemUUID ? Self.filesystemUUID(at: root) : nil
        uuid = filesystemUUID ??
            (try? URL(fileURLWithPath: root).resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
        log = FSEventsCopyUUIDForDevice(device).map { CFUUIDCreateString(nil, $0) as String }
        readOnly = info.f_flags & UInt32(MNT_RDONLY) != 0
    }

    init(root: String, mount: String, device: Int32, uuid: String?, log: String?, readOnly: Bool) {
        self.root = root
        self.mount = mount
        self.device = device
        self.uuid = uuid
        self.log = log
        self.readOnly = readOnly
    }

    private static func filesystemUUID(at path: String) -> String? {
        var output = [CChar](repeating: 0, count: 37)
        return output.withUnsafeMutableBufferPointer { buffer in
            guard dm_volume_uuid(path, buffer.baseAddress) else { return nil }
            return String(cString: buffer.baseAddress!)
        }
    }

    func sharesVolumeAndLog(with other: Self) -> Bool {
        mount == other.mount && device == other.device && uuid == other.uuid && log == other.log
    }

    func observedBoundary(before time: TimeInterval = Date().timeIntervalSince1970) -> UInt64? {
        let number = FSEventsGetLastEventIdForDeviceBeforeTime(device, time)
        return number == 0 || number == UInt64.max ? nil : number
    }

    func scanReplayBaseline() -> UInt64? {
        observedBoundary(before: Date().timeIntervalSince1970 - 10)
    }

    func relativeScope(_ path: String) -> String {
        if path == mount { return "" }
        if mount != "/", path.hasPrefix(mount + "/") {
            return String(path.dropFirst(mount.count + 1))
        }
        return String(path.drop(while: { $0 == "/" }))
    }

    func checkpoint(_ event: UInt64?) -> VolumeCheckpoint {
        VolumeCheckpoint(root: root, volumeUUID: uuid, eventLogUUID: log,
                         mountedDevice: device, readOnly: readOnly, appliedEvent: event)
    }

    func permitsReplay(_ checkpoint: VolumeCheckpoint?) -> Bool {
        Self.permitsReplay(checkpoint, uuid: uuid, log: log, latest: observedBoundary())
    }

    static func permitsReplay(_ checkpoint: VolumeCheckpoint?, uuid: String?, log: String?,
                              latest: UInt64?) -> Bool {
        guard let checkpoint, let applied = checkpoint.appliedEvent, let latest,
              let uuid, let log, checkpoint.volumeUUID == uuid, checkpoint.eventLogUUID == log else { return false }
        return applied <= latest
    }
}

final class VolumeEventStream {
    private let queue = DispatchQueue(label: "index.volume-events")
    private let streamLock = NSLock()
    private var stream: FSEventStreamRef?
    let volume: VolumeIdentity
    let deliver: ([VolumeEvent]) -> Void

    init(volume: VolumeIdentity, since: UInt64?, scope: String, fileEvents: Bool = true, deliver: @escaping ([VolumeEvent]) -> Void) throws {
        self.volume = volume
        self.deliver = deliver
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagWatchRoot) | (fileEvents ? UInt32(kFSEventStreamCreateFlagFileEvents) : 0)
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
            }, &context, volume.device, [scope] as CFArray, since ?? UInt64.max, 0.12, flags)
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
        streamLock.withLock {
            if let stream { FSEventStreamFlushSync(stream) }
        }
    }

    func stop() {
        let detached = streamLock.withLock {
            let value = stream
            stream = nil
            return value
        }
        guard let value = detached else { return }
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
    private var pendingHistory: UInt64?
    private(set) var lag: ReplayLag
    private(set) var outOfOrderBatches: UInt64 = 0
    private(set) var maximumRegression: UInt64 = 0

    init(applied: UInt64?, replaying: Bool = false, scanBaseline: UInt64? = nil) {
        self.applied = applied
        self.replaying = replaying
        lag = ReplayLag(baseline: applied ?? scanBaseline)
    }

    /// Gaps and late deliveries are diagnostic. Only invalidation requires recovery.
    mutating func received(_ event: VolumeEvent) -> Bool {
        receivedBatch([event])
    }

    /// A callback may coalesce paths whose IDs aren't presented in order.
    /// Compare the callback boundary, as FSEventStreamGetLatestEventId does.
    mutating func receivedBatch(_ events: [VolumeEvent]) -> Bool {
        var boundary: UInt64?
        var done = historyDelivered
        for event in events {
            if event.invalidPosition { return false }
            if event.historyDone { done = true; continue }
            // Historical directory coalescing can deliver separate batches
            // out of ID order. HistoryDone delimits live stream comparisons.
            if replaying && !done { continue }
            boundary = max(boundary ?? 0, event.id)
        }
        if let boundary {
            if let lastSeen, boundary < lastSeen {
                outOfOrderBatches += 1
                maximumRegression = max(maximumRegression, lastSeen - boundary)
            }
            lastSeen = max(lastSeen ?? 0, boundary)
        }
        historyDelivered = done
        return true
    }

    mutating func acknowledge(_ id: UInt64?, at time: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        if let id { pendingHistory = max(pendingHistory ?? 0, id) }
        if replaying && !historyDelivered { return }
        if let safe = pendingHistory, applied.map({ safe > $0 }) ?? true {
            applied = safe
            lag.record(safe, at: time)
        }
        pendingHistory = nil
    }
}
