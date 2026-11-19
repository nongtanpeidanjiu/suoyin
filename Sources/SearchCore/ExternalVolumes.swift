import Darwin
import DiskArbitration
import DarwinMetadata
import Foundation
import IOKit

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
    enum Medium: Int32 { case unknown, rotational, solidState }
    let identity: VolumeIdentity
    let name: String
    let fileEvents: Bool
    var bsdName: String? = nil
    var filesystem: String? = nil
    var medium: Medium = .unknown
    var detail: String? = nil
    var needsLiveIdentity = false
    var capacityBytes: Int64? = nil
    var isDiskImage = false

    var scanWorkers: Int {
        switch medium {
        case .unknown: return 1
        case .rotational: return 2
        case .solidState: return 3
        }
    }

    var scanLogKey: String? {
        guard filesystem == "exfat", let volumeID else { return nil }
        return volumeID + "-exfat.scanlog"
    }

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

    static func isDiskImage(model: String?, transport: String?) -> Bool {
        transport?.caseInsensitiveCompare("Disk Image") == .orderedSame ||
            model?.range(of: "Disk Image", options: .caseInsensitive) != nil
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
        return ExternalMount(identity: volume, name: name, fileEvents: fileEvents, bsdName: bsdName,
                             filesystem: filesystem, medium: medium == .unknown ? previous.medium : medium,
                             detail: detail, needsLiveIdentity: needsLiveIdentity,
                             capacityBytes: capacityBytes, isDiskImage: isDiskImage)
    }

    func canKeepTracker(for current: Self) -> Bool {
        sameAttachment(as: current) && volumeID == current.volumeID && identity.log == current.identity.log &&
            identity.readOnly == current.identity.readOnly && fileEvents == current.fileEvents &&
            filesystem == current.filesystem && medium == current.medium
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

    private struct Choice: Codable, Equatable {
        var name: String
        var included: Bool
        var detail: String?
        var removing = false
        var forgetting: Bool?
        var nameIsPlaceholder: Bool?
        var filesystem: String?
        var capacityBytes: Int64?
        var isDiskImage: Bool?
    }

    private struct Preferences: Codable, Equatable {
        var includesNew = false
        var volumes: [String: Choice] = [:]
    }

    private let queue = DispatchQueue(label: "index.mounts", qos: .utility)
    private let retirement = DispatchQueue(label: "index.detached-volumes", qos: .utility)
    private let lock = NSLock()
    private let directory: String
    private let preferencesURL: URL
    private let discoverAutomatically: Bool
    private let allowDiskImages: Bool
    private let onAccess: ((String) -> Void)?
    private var session: DASession?
    private var active: [String: Active] = [:]
    private var offline: [String: ExternalVolumeStatus] = [:]
    private var retiring: Set<String> = []
    private var lastMounts: [ExternalMount] = []
    private var attachmentIDs: [String: String] = [:]
    private var preferences = Preferences()
    private var preferenceFailure: EngineVolumeSettingsError?
    private var startupFailure: EngineVolumeSettingsError?
    private var preferencesWritable = true
    private var started = false
    private var indexingEnabled = true
    private var retained: [String: Int] = [:]
    private var retainedLoaded = false
    private var retentionInvalidated: Set<String> = []
    private var retainedUnavailable: Set<String> = []
    private var identityPoll: DispatchSourceTimer?
    private var identityPollScheduled = false
    private var unresolved: Set<String> = []
    private var probe = 0
    private static let probeDelays = [250, 500, 1_000, 2_000, 4_000, 8_000]
    private var closed = false
    private var nextSlot: UInt32 = 1
    var engineObserver: ((EngineChange) -> Void)?

    init(directory: String, discoverAutomatically: Bool = true, allowDiskImages: Bool? = nil,
         onAccess: ((String) -> Void)? = nil) {
        self.directory = joinedPath(directory, "external-volumes")
        preferencesURL = URL(fileURLWithPath: joinedPath(directory, "external-volumes.json"))
        self.discoverAutomatically = discoverAutomatically
        self.allowDiskImages = allowDiskImages ?? (ProcessInfo.processInfo.environment["FILE_SEARCH_INCLUDE_DISK_IMAGES"] == "1")
        self.onAccess = onAccess
        loadPreferences()
    }

    private func loadPreferences() {
        let bytes: Data
        do {
            bytes = try Data(contentsOf: preferencesURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile &&
            !FileManager.default.fileExists(atPath: preferencesURL.path) {
            var migrated = Preferences()
            do {
                for (file, id) in try Self.indexFiles(in: self.directory) where
                    file.hasSuffix(".snapshot") || file.hasSuffix(".scanlog") {
                    migrated.volumes[id] = Choice(name: String(id.prefix(8)), included: true, nameIsPlaceholder: true)
                }
                if !migrated.volumes.isEmpty { _ = save(migrated) }
            } catch {
                startupFailure = Self.issue(.inspectIndex, error)
            }
            return
        } catch {
            preferencesWritable = false
            startupFailure = Self.issue(.readSettings, error)
            return
        }
        do {
            preferences = try JSONDecoder().decode(Preferences.self, from: bytes)
        } catch {
            startupFailure = Self.issue(.invalidSettings, error)
            let backup = preferencesURL.deletingLastPathComponent()
                .appendingPathComponent("external-volumes.damaged-\(UUID().uuidString).json")
            do {
                try FileManager.default.moveItem(at: preferencesURL, to: backup)
                _ = save(Preferences())
            } catch {
                preferencesWritable = false
                preferenceFailure = Self.issue(.backupSettings, error)
            }
        }
    }

    private static func issue(_ category: EngineVolumeSettingsError.Category, _ error: Error) -> EngineVolumeSettingsError {
        EngineVolumeSettingsError(category: category, underlyingMessage: String(describing: error))
    }

    var includesNew: Bool { queue.sync { preferences.includesNew } }
    var settingsError: EngineVolumeSettingsError? { queue.sync { preferenceFailure ?? startupFailure } }

    func catalog() -> [EngineVolume] { catalogState().0 }

    func catalogState() -> ([EngineVolume], Bool, EngineVolumeSettingsError?) {
        queue.sync {
            let online = Set(attachmentIDs.values)
            let delegates = Dictionary(uniqueKeysWithValues: lock.withLock { active.values.map { ($0.key, $0.tracker) } })
            let rows = preferences.volumes.compactMap { id, choice -> EngineVolume? in
                guard allowDiskImages || choice.isDiskImage != true else { return nil }
                let current = delegates[id]?.engineState()
                let scanning = current.map {
                    $0.status.phase != "caught-up" && $0.status.error == nil
                } ?? false
                let placeholder = choice.nameIsPlaceholder ?? (choice.name == "External disk" && !online.contains(id))
                let durable = current?.status.externalRetainedEntries ?? retained[id] ??
                    (retainedLoaded && !retainedUnavailable.contains(id) ? 0 : nil)
                let restoring = current?.status.externalScan?.restoring ?? (current.map {
                    $0.status.recovery == "replay" || ($0.status.phase == "starting" && (durable ?? 0) > 0)
                } ?? false)
                return EngineVolume(id: id, name: placeholder ? String(id.prefix(8)) : choice.name,
                                    nameIsPlaceholder: placeholder, isOnline: online.contains(id),
                                    isIncluded: choice.included, isScanning: scanning, indexedCount: current?.indexed ?? 0,
                                    retainedCount: durable, progress: scanning ? (restoring ? .restoring : .scanning) : .idle,
                                    filesystem: choice.filesystem, capacityBytes: choice.capacityBytes,
                                    detail: choice.filesystem ?? choice.detail?.components(separatedBy: " · ").first)
            }
            return (rows.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name },
                    preferences.includesNew, preferenceFailure ?? startupFailure)
        }
    }

    func setIncludesNew(_ value: Bool) {
        queue.sync {
            guard !closed, preferences.includesNew != value else { return }
            var next = preferences
            next.includesNew = value
            _ = save(next)
            engineObserver?(.status)
        }
    }

    func setIncluded(_ id: String, included: Bool) {
        queue.sync {
            guard !closed, var choice = preferences.volumes[id], choice.forgetting != true,
                  choice.included != included else { return }
            var next = preferences
            choice.included = included
            next.volumes[id] = choice
            _ = save(next)
            if included {
                finishRemoval(id)
                refresh()
            } else if let mounted = searchable().first(where: { $0.key == id }) {
                retire(mounted)
            }
            engineObserver?(.status)
        }
    }

    func removeData(_ id: String) {
        queue.sync {
            guard !closed, let choice = preferences.volumes[id] else { return }
            if saveRemoval(id, choice: choice) {
                if let mounted = searchable().first(where: { $0.key == id }) { retire(mounted) }
                finishRemoval(id)
            }
            engineObserver?(.status)
        }
    }

    func forget(_ id: String) throws -> EngineVolumeForgetResult {
        try queue.sync {
            guard !closed else { throw EngineVolumeForgetError.unavailable }
            guard let choice = preferences.volumes[id] else { throw EngineVolumeForgetError.notFound }
            guard !attachmentIDs.values.contains(id) else { throw EngineVolumeForgetError.online }
            if choice.forgetting != true, !saveRemoval(id, choice: choice, forget: true) {
                engineObserver?(.status)
                throw EngineVolumeForgetError.settings(writeSettingsError)
            }
            if retiring.contains(id) {
                engineObserver?(.status)
                return .pending
            }
            guard finishRemoval(id) else {
                throw EngineVolumeForgetError.settings(preferenceFailure ?? writeSettingsError)
            }
            return .removed
        }
    }

    private func saveRemoval(_ id: String, choice: Choice, forget: Bool = false) -> Bool {
        var next = preferences
        var pending = choice
        pending.included = false
        pending.removing = true
        if forget { pending.forgetting = true }
        next.volumes[id] = pending
        return save(next, applyOnFailure: false)
    }

    private var writeSettingsError: EngineVolumeSettingsError {
        EngineVolumeSettingsError(category: .writeSettings,
                                  underlyingMessage: (preferenceFailure ?? startupFailure)?.underlyingMessage
                                      ?? "External volume settings could not be saved.")
    }

    @discardableResult
    private func save(_ next: Preferences, applyOnFailure: Bool = true) -> Bool {
        if applyOnFailure { preferences = next }
        guard preferencesWritable else { return false }
        do {
            try JSONEncoder().encode(next).write(to: preferencesURL, options: .atomic)
            preferences = next
            preferenceFailure = nil
            return true
        } catch {
            preferenceFailure = Self.issue(.writeSettings, error)
            return false
        }
    }

    private static func isMissing(_ error: CocoaError) -> Bool {
        error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
    }

    private static func indexFiles(in directory: String, owner: String? = nil) throws -> [(String, String)] {
        let fm = FileManager.default
        let files: [String]
        do { files = try fm.contentsOfDirectory(atPath: directory) }
        catch let error as CocoaError where isMissing(error) { return [] }
        return try files.compactMap { file in
            guard file.count > 36, let id = UUID(uuidString: String(file.prefix(36)))?.uuidString,
                  owner == nil || owner == id else { return nil }
            let path = joinedPath(directory, file)
            let suffix = String(file.dropFirst(36))
            let apfs = suffix.first == "-" && suffix.count > 37 &&
                UUID(uuidString: String(suffix.dropFirst().prefix(36))) != nil &&
                [".snapshot", ".snapshot.changes", ".snapshot.budget"].contains(String(suffix.dropFirst(37)))
            guard suffix == "-exfat.scanlog" || apfs else { return nil }
            do {
                let fields = try fm.attributesOfItem(atPath: path)
                return fields[.type] as? FileAttributeType == .typeRegular ? (file, id) : nil
            } catch let error as CocoaError where isMissing(error) { return nil }
        }
    }

    private func startRetentionLoad() {
        let directory = self.directory
        DispatchQueue.global(qos: .utility).async {
            var counts: [String: Int] = [:]
            var errors: [String: EngineVolumeSettingsError] = [:]
            var failed: EngineVolumeSettingsError?
            do {
                let files = try Self.indexFiles(in: directory).filter {
                    $0.0.hasSuffix(".snapshot") || $0.0.hasSuffix(".scanlog")
                }
                for (id, artifacts) in Dictionary(grouping: files, by: { $0.1 }) {
                    do {
                        let newest = try artifacts.map { file, _ -> (path: String, date: Date) in
                            let path = joinedPath(directory, file)
                            let fields = try FileManager.default.attributesOfItem(atPath: path)
                            return (path, fields[.modificationDate] as? Date ?? .distantPast)
                        }.max { $0.date < $1.date }
                        if let path = newest?.path {
                            counts[id] = try path.hasSuffix(".scanlog") ? ExternalScanLog.retainedEntries(at: path)
                                : SearchIndex.retainedEntries(at: path)
                        }
                    } catch {
                        errors[id] = Self.issue(.inspectIndex, error)
                    }
                }
            } catch { failed = Self.issue(.inspectIndex, error) }
            self.queue.async { [counts, errors, failed] in
                guard !self.closed else { return }
                for (id, count) in counts where !self.retentionInvalidated.contains(id) { self.retained[id] = count }
                let unavailable = Set(errors.keys).subtracting(self.retentionInvalidated)
                self.retainedUnavailable.formUnion(unavailable)
                self.retainedLoaded = true
                if self.preferenceFailure == nil {
                    self.preferenceFailure = failed ?? unavailable.min().flatMap { errors[$0] }
                }
                self.engineObserver?(.status)
            }
        }
    }

    @discardableResult
    private func finishRemoval(_ id: String) -> Bool {
        guard !retiring.contains(id), var choice = preferences.volumes[id], choice.removing else { return false }
        do {
            for (file, _) in try Self.indexFiles(in: directory, owner: id) {
                try FileManager.default.removeItem(atPath: joinedPath(directory, file))
            }
            var next = preferences
            retentionInvalidated.insert(id)
            retained[id] = 0
            retainedUnavailable.remove(id)
            let online = attachmentIDs.values.contains(id)
            let forget = choice.forgetting == true
            if online && !forget {
                choice.removing = false
                next.volumes[id] = choice
            } else {
                next.volumes.removeValue(forKey: id)
            }
            guard save(next, applyOnFailure: false) else {
                engineObserver?(.disk)
                return false
            }
            if next.volumes[id] == nil {
                lock.withLock { offline[id] = nil }
            }
            if forget && online { refresh() }
            engineObserver?(forget ? .volumeRemoved : .disk)
            return true
        } catch {
            preferenceFailure = Self.issue(.removeIndex, error)
            engineObserver?(.disk)
            return false
        }
    }

    func start(deferIndexing: Bool = false) {
        queue.async {
            guard !self.closed, !self.started else { return }
            self.started = true
            self.indexingEnabled = !deferIndexing
            self.startRetentionLoad()
            if self.discoverAutomatically, let session = DASessionCreate(nil) {
                self.beginDiscovery(session)
            }
            for id in self.preferences.volumes.keys.sorted() { self.finishRemoval(id) }
        }
    }

    func enableIndexing() {
        queue.async {
            guard !self.closed, !self.indexingEnabled else { return }
            self.indexingEnabled = true
            self.refresh()
        }
    }

    private func beginDiscovery(_ session: DASession) {
        self.session = session
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { _, context in
            ExternalVolumes.handle(context)
        }, context)
        DARegisterDiskDisappearedCallback(session, nil, { disk, context in
            ExternalVolumes.handleRemoval(disk, context)
        }, context)
        let identityKeys = [kDADiskDescriptionVolumePathKey, kDADiskDescriptionVolumeUUIDKey]
        DARegisterDiskDescriptionChangedCallback(session, nil, identityKeys as CFArray, { disk, _, context in
            let values = DADiskCopyDescription(disk) as? [String: Any]
            if values?[kDADiskDescriptionVolumePathKey as String] == nil {
                ExternalVolumes.handleRemoval(disk, context)
            } else {
                ExternalVolumes.handle(context)
            }
        }, context)
        DASessionSetDispatchQueue(session, queue)
        refresh()
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
            probeUnresolvedIdentities(in: searchable().map(\.mount))
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

    private func register(_ observations: [ExternalMount]) -> Bool {
        let previous = Dictionary(uniqueKeysWithValues: lastMounts.map { ($0.identity.mount, $0) })
        let previousIDs = attachmentIDs
        let duplicates = Dictionary(grouping: observations.compactMap(\.volumeID), by: { $0 })
        var assigned: [String: String] = [:]
        var next = preferences
        for mount in observations {
            let path = mount.identity.mount
            let stable = mount.volumeID
            let related = previous[path].flatMap { old in
                old.sameAttachment(as: mount) && (old.volumeID == stable || stable == nil)
                    ? previousIDs[path] : nil
            }
            let unique = stable.flatMap { duplicates[$0]?.count == 1 ? $0 : nil }
            let id = related ?? unique ?? UUID().uuidString
            assigned[path] = id
            if var choice = next.volumes[id] {
                choice.name = mount.name
                choice.nameIsPlaceholder = false
                choice.detail = mount.detail ?? choice.detail
                choice.filesystem = mount.filesystem ?? choice.filesystem
                choice.capacityBytes = mount.capacityBytes ?? choice.capacityBytes
                choice.isDiskImage = mount.isDiskImage
                next.volumes[id] = choice
            } else {
                let oldChoice = previous[path].flatMap { old in
                    old.volumeID == nil && old.sameAttachment(as: mount)
                        ? previousIDs[path].flatMap { next.volumes[$0] } : nil
                }
                next.volumes[id] = Choice(name: mount.name, included: oldChoice?.included ?? next.includesNew,
                                          detail: mount.detail, nameIsPlaceholder: false, filesystem: mount.filesystem,
                                          capacityBytes: mount.capacityBytes, isDiskImage: mount.isDiskImage)
            }
        }
        let changed = assigned != attachmentIDs || next != preferences
        lastMounts = observations
        attachmentIDs = assigned
        if next != preferences { _ = save(next) }
        return changed
    }

    private func reconcile(_ detected: [ExternalMount], replacing path: String? = nil) {
        guard !closed else { return }
        if !allowDiskImages {
            var next = preferences
            for mount in detected where mount.isDiskImage {
                if let id = mount.volumeID, next.volumes[id] != nil { next.volumes[id]?.isDiskImage = true }
            }
            if next != preferences { _ = save(next); engineObserver?(.status) }
        }
        let observations = detected.filter { allowDiskImages || !$0.isDiskImage }
        let changed = register(observations)
        if !indexingEnabled {
            if changed { engineObserver?(.status) }
            return
        }
        let previous = lock.withLock { active }
        let mounts = observations.compactMap { observed -> ExternalMount? in
            let mountPath = observed.identity.mount
            guard let id = attachmentIDs[mountPath], let choice = preferences.volumes[id],
                  choice.included, !choice.removing, !retiring.contains(id) else { return nil }
            do {
                let resolved = try resolvedIdentity(for: observed)
                guard mountPath != path, let active = previous[mountPath] else { return resolved }
                return resolved.retainingKnownIdentity(from: active.mount)
            } catch {
                preferenceFailure = Self.issue(.verifyIdentity, error)
                engineObserver?(.status)
                return nil
            }
        }
        let byPath = Dictionary(uniqueKeysWithValues: mounts.map { ($0.identity.mount, $0) })
        for value in previous.values {
            let candidate = byPath[value.mount.identity.mount]
            if value.mount.identity.mount != path, attachmentIDs[value.mount.identity.mount] == value.key, let candidate,
               value.mount.canKeepTracker(for: candidate) { continue }
            let resolvedProvisional = candidate.map { value.mount.sameAttachment(as: $0) && value.mount.volumeID == nil }
                ?? false
            retire(value, recordOffline: !resolvedProvisional)
        }

        for mount in mounts {
            let path = mount.identity.mount
            guard let key = attachmentIDs[path], !retiring.contains(key),
                  lock.withLock({ active[path] == nil }) else { continue }
            let volumeID = mount.volumeID
            let cache = key == volumeID ? mount.cacheKey : nil
            let scanLog = key == volumeID ? mount.scanLogKey.map { joinedPath(directory, $0) } : nil
            let base = joinedPath(directory, (cache ?? key) + ".snapshot")
            do {
                if cache != nil || scanLog != nil {
                    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                }
                let tracker = try ChangeTracker(root: mount.identity.root, snapshot: base,
                                                ownData: parentPath(directory),
                                                wallTime: { Date().timeIntervalSince1970 },
                                                external: mount, externalPersistence: cache != nil,
                                                externalScanLog: scanLog, onAccess: onAccess)
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
        if changed { engineObserver?(.status) }
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
                if let entries = value.tracker.snapshotStatus().externalRetainedEntries {
                    self.retained[value.key] = entries
                    self.retentionInvalidated.insert(value.key)
                    self.retainedUnavailable.remove(value.key)
                }
                self.retiring.remove(value.key)
                self.finishRemoval(value.key)
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
        for volume in volumes { volume.tracker.cancelUnfinishedExternalScan() }
        retirement.sync {}
        queue.sync {}
        var failure: Error?
        for volume in volumes {
            do { try volume.tracker.stop() }
            catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }

    private func resolvedIdentity(for observed: ExternalMount) throws -> ExternalMount {
        guard observed.needsLiveIdentity, let session else { return observed }
        let root = observed.identity.root
        let identity = try VolumeIdentity(root: root, preferFilesystemUUID: true)
        guard identity.mount == observed.identity.mount, identity.device == observed.identity.device,
              observed.volumeID == nil || identity.uuid.flatMap({ UUID(uuidString: $0)?.uuidString }) == observed.volumeID
        else { throw CocoaError(.fileReadUnknown) }
        var resolved = ExternalMount(identity: identity, name: observed.name, fileEvents: observed.fileEvents,
                                     bsdName: observed.bsdName, filesystem: observed.filesystem,
                                     detail: observed.detail, needsLiveIdentity: true,
                                     capacityBytes: observed.capacityBytes, isDiskImage: observed.isDiskImage)
        if let disk = DADiskCreateFromVolumePath(nil, session, URL(fileURLWithPath: root) as CFURL) {
            let media = DADiskCopyIOMedia(disk)
            resolved.medium = ExternalMount.Medium(rawValue: dm_media_kind(media)) ?? .unknown
            if media != 0 { IOObjectRelease(media) }
        }
        return resolved
    }

    private static func descriptionUUID(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let id = value as? UUID { return id.uuidString }
        let cf = value as CFTypeRef
        guard CFGetTypeID(cf) == CFUUIDGetTypeID() else { return nil }
        return CFUUIDCreateString(nil, unsafeBitCast(cf, to: CFUUID.self)) as String
    }

    private static func mounted(using session: DASession) -> [ExternalMount] {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else { return [] }
        let current = Array(UnsafeBufferPointer(start: mounts, count: Int(count)))
        return current.compactMap { info in
            guard info.f_flags & UInt32(MNT_LOCAL) != 0 else { return nil }
            let path = withUnsafeBytes(of: info.f_mntonname) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
            let device = withUnsafeBytes(of: info.f_mntfromname) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
            guard path != "/", !inside(path, "/System"), !inside(path, "/dev"),
                  device.hasPrefix("/dev/"),
                  let disk = device.withCString({ DADiskCreateFromBSDName(nil, session, $0) }),
                  let description = DADiskCopyDescription(disk) as? [String: Any],
                  let mountedURL = description[kDADiskDescriptionVolumePathKey as String] as? URL,
                  mountedURL.path == path else { return nil }
            let model = description[kDADiskDescriptionDeviceModelKey as String] as? String
            let transport = description[kDADiskDescriptionDeviceProtocolKey as String] as? String
            let image = ExternalMount.isDiskImage(model: model, transport: transport)
            let external = description[kDADiskDescriptionDeviceInternalKey as String] as? Bool == false
            guard image || (external && transport != "Virtual Interface") else { return nil }
            let uuid = descriptionUUID(description[kDADiskDescriptionVolumeUUIDKey as String])
            let identity = VolumeIdentity(root: path, mount: path, device: info.f_fsid.val.0,
                                          uuid: uuid, log: nil, readOnly: info.f_flags & UInt32(MNT_RDONLY) != 0)
            let filesystem = withUnsafeBytes(of: info.f_fstypename) {
                String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            let (capacity, overflow) = Int64(clamping: info.f_blocks).multipliedReportingOverflow(by: Int64(info.f_bsize))
            return ExternalMount(identity: identity,
                                 name: description[kDADiskDescriptionVolumeNameKey as String] as? String ?? leafName(path),
                                 fileEvents: ExternalMount.supportsFileEvents(on: filesystem),
                                 bsdName: DADiskGetBSDName(disk).map { String(cString: $0) },
                                 filesystem: filesystem, needsLiveIdentity: true,
                                 capacityBytes: !overflow && capacity > 0 ? capacity : nil, isDiskImage: image)
        }
    }
}
