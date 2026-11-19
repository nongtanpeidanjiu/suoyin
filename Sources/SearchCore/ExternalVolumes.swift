import Darwin
import DiskArbitration
import Foundation

public struct ExternalVolumeStatus: Codable, Sendable {
    public let id: String
    public let volumeUUID: String?
    public let eventLogUUID: String?
    public let name: String
    public let mount: String
    public let online: Bool
    public let entries: Int
    public let caughtUp: Bool
    public let slow: Bool
    public let eventPosition: UInt64?
    public let recovery: String?
}

struct ExternalMount {
    let identity: VolumeIdentity
    let name: String
    let fileEvents: Bool
    var bsdName: String? = nil

    var volumeID: String? {
        identity.uuid.flatMap { UUID(uuidString: $0)?.uuidString }
    }

    var cacheKey: String? {
        guard fileEvents, let volumeID, let log = identity.log, let logID = UUID(uuidString: log) else { return nil }
        return volumeID + "-" + logID.uuidString
    }

    static func supportsFileEvents(on filesystem: String) -> Bool {
        filesystem == "apfs" || filesystem == "hfs"
    }

    func sameAttachment(as other: Self) -> Bool {
        identity.mount == other.identity.mount && identity.device == other.identity.device && bsdName == other.bsdName
    }

    func retainingKnownIdentity(from previous: Self) -> Self {
        guard sameAttachment(as: previous),
              volumeID == nil || previous.volumeID == nil || volumeID == previous.volumeID
        else { return self }
        let volume = VolumeIdentity(root: identity.root, mount: identity.mount, device: identity.device,
                                    uuid: identity.uuid ?? previous.identity.uuid,
                                    log: identity.log ?? previous.identity.log, readOnly: identity.readOnly)
        return ExternalMount(identity: volume, name: name, fileEvents: fileEvents, bsdName: bsdName)
    }

    func canKeepTracker(for current: Self) -> Bool {
        sameAttachment(as: current) && volumeID == current.volumeID && identity.log == current.identity.log &&
            identity.readOnly == current.identity.readOnly && fileEvents == current.fileEvents
    }
}

/// Disk Arbitration callbacks have their own queue so mount removal does not
/// wait for local index writes or for the old volume's filesystem work.
final class ExternalVolumes {
    struct Active {
        let mount: ExternalMount
        let key: String
        let slot: UInt32
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
    private var lastMounts: [ExternalMount] = []
    private var identityPoll: DispatchSourceTimer?
    private var identityPollScheduled = false
    private var unresolved: Set<String> = []
    private var probe = 0
    private static let probeDelays = [250, 500, 1_000, 2_000, 4_000, 8_000]
    private var closed = false
    private var nextSlot: UInt32 = 1
    var engineObserver: ((EngineChange) -> Void)?

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
                manager.unresolved.remove(volume.mount.identity.mount)
                manager.retire(volume)
            }
        }
        manager.refresh()
    }

    private func refresh(replacing path: String? = nil) {
        guard !closed else { return }
        if let session {
            let mounts = Self.mounted(using: session)
            reconcile(mounts, replacing: path)
            probeUnresolvedIdentities(in: mounts)
        } else {
            reconcile(lastMounts, replacing: path)
        }
    }

    private func probeUnresolvedIdentities(in mounts: [ExternalMount]) {
        let pending = Set(mounts.filter { $0.fileEvents && ($0.volumeID == nil || $0.identity.log == nil) }
            .map { $0.identity.mount })
        if pending != unresolved {
            unresolved = pending
            probe = 0
            identityPoll?.schedule(deadline: .distantFuture)
            identityPollScheduled = false
        }
        guard !pending.isEmpty, !identityPollScheduled, probe < Self.probeDelays.count else { return }
        if identityPoll == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.identityPollScheduled = false
                self.refresh()
            }
            identityPoll = timer
            timer.activate()
        }
        identityPoll?.schedule(deadline: .now() + .milliseconds(Self.probeDelays[probe]))
        identityPollScheduled = true
        probe += 1
    }

    /// Also serves as a seam for tests with owned directory fixtures.
    func updateMounts(_ mounts: [ExternalMount]) {
        queue.sync { reconcile(mounts) }
    }

    private func reconcile(_ observations: [ExternalMount], replacing path: String? = nil) {
        guard !closed else { return }
        lastMounts = observations
        let previous = lock.withLock { active }
        let mounts = observations.map { observed in
            guard observed.identity.mount != path, let active = previous[observed.identity.mount] else { return observed }
            return observed.retainingKnownIdentity(from: active.mount)
        }
        let byPath = Dictionary(uniqueKeysWithValues: mounts.map { ($0.identity.mount, $0) })
        for value in previous.values {
            let candidate = byPath[value.mount.identity.mount]
            if value.mount.identity.mount != path, let candidate,
               value.mount.canKeepTracker(for: candidate) { continue }
            let resolvedProvisional = candidate.map { value.mount.sameAttachment(as: $0) && value.mount.volumeID == nil }
                ?? false
            retire(value, recordOffline: !resolvedProvisional)
        }

        for mount in mounts {
            let path = mount.identity.mount
            guard lock.withLock({ active[path] == nil }) else { continue }
            let volumeID = mount.volumeID
            if let volumeID, retiring.contains(volumeID) { continue }
            let hasClone = volumeID.map { id in
                mounts.lazy.filter { $0.volumeID == id }.count > 1 ||
                self.lock.withLock { self.active.values.contains { $0.key == id } }
            } ?? false
            let key = hasClone ? UUID().uuidString : volumeID ?? UUID().uuidString
            let cache = hasClone ? nil : mount.cacheKey
            let base = joinedPath(directory, (cache ?? key) + ".snapshot")
            do {
                if cache != nil {
                    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                }
                let tracker = try ChangeTracker(root: mount.identity.root, snapshot: base,
                                                ownData: parentPath(directory),
                                                wallTime: { Date().timeIntervalSince1970 },
                                                external: mount, externalPersistence: cache != nil)
                let volume = Active(mount: mount, key: key, slot: nextSlot, tracker: tracker)
                nextSlot += 1
                if let engineObserver { tracker.observeEngineChanges(engineObserver) }
                lock.withLock {
                    offline = offline.filter { !$0.value.online || $0.value.mount != path }
                    offline.removeValue(forKey: key)
                    active[path] = volume
                }
                tracker.onExternalIdentityChange = { [weak self, weak tracker] in
                    guard let self, let tracker else { return }
                    self.queue.async {
                        guard self.lock.withLock({ self.active[path]?.tracker === tracker }) else { return }
                        self.refresh(replacing: path)
                    }
                }
                engineObserver?(.status)
                tracker.start()
            } catch {
                lock.withLock {
                    offline = offline.filter { !$0.value.online || $0.value.mount != path }
                    offline[key] = ExternalVolumeStatus(id: key, volumeUUID: volumeID, eventLogUUID: mount.identity.log,
                                                         name: mount.name, mount: path, online: true, entries: 0,
                                                         caughtUp: false, slow: true, eventPosition: nil,
                                                         recovery: "unavailable")
                }
            }
        }
    }

    private func retire(_ value: Active, recordOffline: Bool = true) {
        let hadRows = value.tracker.indexedEntryCount() != 0
        _ = lock.withLock { active.removeValue(forKey: value.mount.identity.mount) }
        let last = recordOffline ? volumeStatus(value, online: false) : nil
        value.tracker.cancelExternalWork()
        engineObserver?(hadRows ? .index : .status)
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
        return ExternalVolumeStatus(id: active.key, volumeUUID: active.mount.volumeID,
                                    eventLogUUID: active.mount.identity.log,
                                    name: active.mount.name, mount: active.mount.identity.mount, online: online, entries: status.baseRecords == 0 ? 0 : active.tracker.indexedEntryCount(),
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
            identityPoll?.cancel()
            identityPoll = nil
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
                  let identity = try? VolumeIdentity(root: path, preferFilesystemUUID: true), identity.mount == path else { return nil }
            let filesystem = withUnsafeBytes(of: info.f_fstypename) {
                String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            return ExternalMount(identity: identity,
                                 name: description[kDADiskDescriptionVolumeNameKey as String] as? String ?? leafName(path),
                                 fileEvents: ExternalMount.supportsFileEvents(on: filesystem),
                                 bsdName: DADiskGetBSDName(disk).map { String(cString: $0) })
        }
    }
}
