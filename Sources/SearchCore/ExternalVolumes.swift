import Darwin
import DiskArbitration
import Foundation

public struct ExternalVolumeStatus: Codable, Sendable {
    public let id: String
    public let name: String
    public let mount: String
    public let online: Bool
    public let entries: Int
    public let caughtUp: Bool
    public let slow: Bool
    public let eventPosition: UInt64?
    public let recovery: String?
}

struct ExternalMount: Equatable {
    let identity: VolumeIdentity
    let name: String
    let fileEvents: Bool
    var bsdName: String? = nil

    var cacheKey: String? {
        guard fileEvents, let uuid = identity.uuid, let log = identity.log,
              let volumeID = UUID(uuidString: uuid), let logID = UUID(uuidString: log)
        else { return nil }
        return volumeID.uuidString + "-" + logID.uuidString
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.identity.mount == rhs.identity.mount && lhs.identity.device == rhs.identity.device &&
        lhs.identity.uuid == rhs.identity.uuid && lhs.fileEvents == rhs.fileEvents &&
        (lhs.identity.log == nil || rhs.identity.log == nil || lhs.identity.log == rhs.identity.log)
    }
}

/// Disk Arbitration callbacks have their own queue so mount removal does not
/// wait for local index writes or for the old volume's filesystem work.
final class ExternalVolumes {
    struct Active {
        let mount: ExternalMount
        let key: String
        let tracker: ChangeTracker
    }

    private let queue = DispatchQueue(label: "index.mounts", qos: .utility)
    private let retirement = DispatchQueue(label: "index.detached-volumes", qos: .utility)
    private let lock = NSLock()
    private let directory: String
    private var session: DASession?
    private var active: [String: Active] = [:]
    private var offline: [String: ExternalVolumeStatus] = [:]
    private var retiring: Set<String> = []
    private var closed = false

    init(directory: String) {
        self.directory = joinedPath(directory, "external-volumes")
    }

    func start() {
        queue.async {
            guard !self.closed, self.session == nil, let session = DASessionCreate(nil) else { return }
            self.session = session
            let context = Unmanaged.passUnretained(self).toOpaque()
            DARegisterDiskAppearedCallback(session, nil, { _, context in
                ExternalVolumes.handle(context)
            }, context)
            DARegisterDiskDisappearedCallback(session, nil, { disk, context in
                ExternalVolumes.handleRemoval(disk, context)
            }, context)
            DARegisterDiskDescriptionChangedCallback(session, nil, [kDADiskDescriptionVolumePathKey] as CFArray,
                                                      { disk, _, context in
                let values = DADiskCopyDescription(disk) as? [String: Any]
                if values?[kDADiskDescriptionVolumePathKey as String] == nil {
                    ExternalVolumes.handleRemoval(disk, context)
                } else {
                    ExternalVolumes.handle(context)
                }
            }, context)
            DASessionSetDispatchQueue(session, self.queue)
            self.refresh()
        }
    }

    private static func handle(_ context: UnsafeMutableRawPointer?) {
        guard let context else { return }
        Unmanaged<ExternalVolumes>.fromOpaque(context).takeUnretainedValue().refresh()
    }

    private static func handleRemoval(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) {
        guard let context else { return }
        let manager = Unmanaged<ExternalVolumes>.fromOpaque(context).takeUnretainedValue()
        if let name = DADiskGetBSDName(disk).map({ String(cString: $0) }) {
            for volume in manager.searchable() where volume.mount.bsdName == name {
                manager.retire(volume)
            }
        }
        manager.refresh()
    }

    private func refresh() {
        guard !closed, let session else { return }
        reconcile(Self.mounted(using: session))
    }

    /// Also serves as a seam for tests with owned directory fixtures.
    func updateMounts(_ mounts: [ExternalMount]) {
        queue.sync { reconcile(mounts) }
    }

    private func reconcile(_ mounts: [ExternalMount]) {
        guard !closed else { return }
        let previous = lock.withLock { active }
        let detached = previous.values.filter { existing in !mounts.contains(existing.mount) }
        for value in detached { retire(value) }

        for mount in mounts {
            let path = mount.identity.mount
            guard lock.withLock({ active[path] == nil }) else { continue }
            let matching = mount.cacheKey
            if let matching, retiring.contains(matching) { continue }
            let hasClone = matching.map { key in
                mounts.lazy.filter { $0.cacheKey == key }.count > 1 ||
                self.lock.withLock { self.active.values.contains { $0.key == key } }
            } ?? false
            let key = hasClone ? UUID().uuidString : matching ?? UUID().uuidString
            let canPersist = matching != nil && !hasClone
            let base = joinedPath(directory, key + ".snapshot")
            do {
                if canPersist {
                    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                }
                let tracker = try ChangeTracker(root: mount.identity.root, snapshot: base,
                                                ownData: parentPath(directory),
                                                wallTime: { Date().timeIntervalSince1970 },
                                                external: mount, externalPersistence: canPersist)
                let volume = Active(mount: mount, key: key, tracker: tracker)
                lock.withLock {
                    offline = offline.filter { !$0.value.online || $0.value.mount != path }
                    offline.removeValue(forKey: key)
                    active[path] = volume
                }
                tracker.start()
            } catch {
                lock.withLock {
                    offline = offline.filter { !$0.value.online || $0.value.mount != path }
                    offline[key] = ExternalVolumeStatus(id: key, name: mount.name, mount: path, online: true,
                                                         entries: 0, caughtUp: false, slow: true,
                                                         eventPosition: nil, recovery: "unavailable")
                }
            }
        }
    }

    private func retire(_ value: Active) {
        _ = lock.withLock { active.removeValue(forKey: value.mount.identity.mount) }
        let last = volumeStatus(value, online: false)
        value.tracker.cancelExternalWork()
        lock.withLock { offline[value.key] = last }
        retiring.insert(value.key)
        retirement.async {
            try? value.tracker.stop()
            self.queue.async {
                self.retiring.remove(value.key)
                self.refresh()
            }
        }
    }

    func searchable() -> [Active] {
        lock.withLock { active.values.sorted { $0.key < $1.key } }
    }

    func isCurrent(_ volume: Active) -> Bool {
        lock.withLock { active[volume.mount.identity.mount]?.tracker === volume.tracker }
    }

    private func volumeStatus(_ active: Active, online: Bool) -> ExternalVolumeStatus {
        let status = active.tracker.snapshotStatus()
        return ExternalVolumeStatus(id: active.key, name: active.mount.name, mount: active.mount.identity.mount,
                                    online: online, entries: status.baseRecords == 0 ? 0 : active.tracker.indexedEntryCount(),
                                    caughtUp: online && status.phase == "caught-up" && !status.indexReconciling,
                                    slow: status.slowVolume || !active.mount.fileEvents,
                                    eventPosition: status.appliedEvents[active.mount.identity.root],
                                    recovery: status.recovery)
    }

    func statuses() -> [ExternalVolumeStatus] {
        let values = lock.withLock { (Array(active.values), Array(offline.values)) }
        return (values.0.map { volumeStatus($0, online: true) } + values.1).sorted { $0.id < $1.id }
    }

    func synchronize() {
        queue.sync { refresh() }
        for active in searchable() { active.tracker.synchronize() }
    }

    func stop() throws {
        let volumes = queue.sync {
            closed = true
            if let session { DASessionSetDispatchQueue(session, nil) }
            session = nil
            return lock.withLock {
                let values = Array(active.values)
                active.removeAll()
                return values
            }
        }
        retirement.sync {}
        var failure: Error?
        for volume in volumes {
            do { try volume.tracker.stop() }
            catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }

    private static func mounted(using session: DASession) -> [ExternalMount] {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else { return [] }
        let current = Array(UnsafeBufferPointer(start: mounts, count: Int(count)))
        return current.compactMap { info in
            guard info.f_flags & UInt32(MNT_LOCAL) != 0 else { return nil }
            let path = withUnsafeBytes(of: info.f_mntonname) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
            guard path != "/", !inside(path, "/System"), !inside(path, "/dev"),
                  access(path, R_OK | X_OK) == 0,
                  let disk = DADiskCreateFromVolumePath(nil, session, URL(fileURLWithPath: path) as CFURL),
                  let description = DADiskCopyDescription(disk) as? [String: Any],
                  let mountedURL = description[kDADiskDescriptionVolumePathKey as String] as? URL,
                  mountedURL.standardizedFileURL.path == path else { return nil }
            let model = description[kDADiskDescriptionDeviceModelKey as String] as? String
            let transport = description[kDADiskDescriptionDeviceProtocolKey as String] as? String
            let image = model?.contains("Disk Image") == true || transport == "Disk Image"
            let external = description[kDADiskDescriptionDeviceInternalKey as String] as? Bool == false
            guard image || (external && transport != "Virtual Interface"),
                  let identity = try? VolumeIdentity(root: path), identity.mount == path else { return nil }
            let filesystem = withUnsafeBytes(of: info.f_fstypename) {
                String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            return ExternalMount(identity: identity,
                                 name: description[kDADiskDescriptionVolumeNameKey as String] as? String ?? leafName(path),
                                 fileEvents: identity.log != nil && ["apfs", "hfs"].contains(filesystem),
                                 bsdName: DADiskGetBSDName(disk).map { String(cString: $0) })
        }
    }
}
