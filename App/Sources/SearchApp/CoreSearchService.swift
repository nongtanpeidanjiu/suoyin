import AppKit
import SearchCore

/// User-defaults key of the previous version, read once to move the choice
/// to the core.
enum LegacyVolumeKeys {
    static let includeNew = "includeNewExternalVolumes"
}

/// Bridges the interface protocol to the real search core running in-process.
///
/// The core keeps the choices about attached volumes itself (in
/// `external-volumes.json` in its data directory). Reading them waits on the
/// core's volume queue, which can be busy for a moment with a slow disk, so
/// this bridge keeps a copy for the interface, refreshes it off the main
/// thread and shows a change the user just made at once.
final class CoreSearchService: SearchService {
    private let engine: SearchEngine
    var onStatusChange: ((IndexStatus) -> Void)?
    var onIndexChange: (() -> Void)?
    var onExternalVolumesChange: (() -> Void)?

    private let volumeQueue = DispatchQueue(label: "ui.external-volumes", qos: .userInitiated)
    private let volumeLock = NSLock()
    private var volumes: [ExternalVolume] = []
    private var includesNew = false
    private var settingsError: ExternalVolumeSettingsError?
    /// Choices sent to the core and not yet reflected in what it reports.
    private var pendingChoices: [String: Bool] = [:]
    private var pendingIncludesNew: Bool?

    /// `dataDirectory` replaces the usual one; for tests only.
    init(dataDirectory: URL? = nil) throws {
        let directory: URL
        if let dataDirectory {
            directory = dataDirectory
        } else {
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
            directory = base.appendingPathComponent("dev.local.filesearch", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        engine = try SearchEngine(dataDirectory: directory)
        // A separate test directory leaves the user's own choice alone.
        if dataDirectory == nil { Self.moveLegacyChoice(to: engine) }
        readVolumes()
    }

    /// The previous version kept “add new volumes by themselves” in the user
    /// defaults, before the core could act on it. Hands a choice made there
    /// to the core once, before it registers any volume, then forgets it.
    private static func moveLegacyChoice(to engine: SearchEngine) {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: LegacyVolumeKeys.includeNew) != nil {
            engine.includesNewExternalVolumes = defaults.bool(forKey: LegacyVolumeKeys.includeNew)
            defaults.removeObject(forKey: LegacyVolumeKeys.includeNew)
        }
        // The per-volume keys (`externalVolumeChoices`, `knownExternalVolumes`)
        // were never acted on and are no longer read; they are left in place
        // only as a record of what the previous version had seen.
    }

    func start() {
        engine.onStatusChange = { [weak self] status in
            guard let self else { return }
            self.onStatusChange?(self.indexStatus(from: status))
            // Counts of the volumes move with the status.
            self.refreshVolumes()
        }
        engine.onIndexChange = { [weak self] in self?.onIndexChange?() }
        engine.onExternalVolumesChange = { [weak self] in self?.refreshVolumes() }
        engine.start()
        refreshVolumes()
    }

    func stop() { engine.stop() }

    func search(_ request: SearchRequest) -> SearchResponse {
        let column: SearchColumn
        switch request.sort {
        case .name: column = .name
        case .location: column = .path
        case .size: column = .size
        case .modified: column = .modified
        }
        let query = EngineQuery(text: request.text,
                                mode: request.scope == .name ? .name : .path,
                                column: column,
                                direction: request.order == .ascending ? .ascending : .descending,
                                showAll: request.includeSystemFiles,
                                kind: Self.convert(request.kind),
                                offset: request.offset, limit: request.limit)
        let result = engine.search(query)
        let hits = result.hits.map {
            SearchHit(id: $0.id, name: $0.name, path: $0.path, isDirectory: $0.isDirectory, size: $0.size,
                      modified: $0.modified, isCloudPlaceholder: $0.isCloudPlaceholder,
                      isOnExternalVolume: $0.volumeID != nil)
        }
        return SearchResponse(hits: hits, total: result.total, totalIsExact: result.totalIsExact)
    }

    var status: IndexStatus { indexStatus(from: engine.status) }
    func recheckAccess() { engine.recheckAccess() }
    func rebuild() { engine.rebuild() }

    // MARK: Attached volumes

    var includesNewExternalVolumes: Bool {
        get { volumeLock.withLock { pendingIncludesNew ?? includesNew } }
        set {
            volumeLock.withLock { pendingIncludesNew = newValue }
            onExternalVolumesChange?()
            volumeQueue.async { [weak self] in
                guard let self else { return }
                self.engine.includesNewExternalVolumes = newValue
                self.volumeLock.withLock { self.pendingIncludesNew = nil }
                self.readVolumes(notify: true)
            }
        }
    }

    var externalVolumes: [ExternalVolume] {
        volumeLock.withLock {
            volumes.map { volume in
                guard let included = pendingChoices[volume.id], included != volume.isIncluded else { return volume }
                var shown = volume
                shown.isIncluded = included
                if !included { shown.progress = .idle }
                return shown
            }
        }
    }

    var externalVolumeSettingsError: ExternalVolumeSettingsError? { volumeLock.withLock { settingsError } }

    /// Leaving a volume out takes its files out of the results as soon as
    /// the core returns; its data stays until deleted.
    func setExternalVolume(_ id: String, included: Bool) {
        volumeLock.withLock { pendingChoices[id] = included }
        onExternalVolumesChange?()
        volumeQueue.async { [weak self] in
            guard let self else { return }
            self.engine.setExternalVolume(id, included: included)
            self.volumeLock.withLock { _ = self.pendingChoices.removeValue(forKey: id) }
            self.readVolumes(notify: true)
            // Results shown already may hold the volume's files.
            self.onIndexChange?()
        }
    }

    func removeExternalVolumeData(_ id: String) {
        volumeLock.withLock { pendingChoices[id] = false }
        onExternalVolumesChange?()
        volumeQueue.async { [weak self] in
            guard let self else { return }
            self.engine.removeExternalVolumeData(id)
            self.volumeLock.withLock { _ = self.pendingChoices.removeValue(forKey: id) }
            self.readVolumes(notify: true)
            self.onIndexChange?()
        }
    }

    private func refreshVolumes() {
        volumeQueue.async { [weak self] in self?.readVolumes(notify: true) }
    }

    /// Reads the volumes from the core and tells the interface if anything
    /// it shows changed.
    private func readVolumes(notify: Bool = false) {
        let list = engine.externalVolumes.map(Self.convert)
        let addsNew = engine.includesNewExternalVolumes
        let error = engine.externalVolumeSettingsError.map(Self.convert)
        let changed = volumeLock.withLock { () -> Bool in
            defer { (volumes, includesNew, settingsError) = (list, addsNew, error) }
            return list != volumes || addsNew != includesNew || error != settingsError
        }
        if changed && notify { onExternalVolumesChange?() }
    }

    private static func convert(_ volume: EngineVolume) -> ExternalVolume {
        let progress: ExternalVolume.Progress
        switch volume.progress {
        case .idle: progress = .idle
        case .restoring: progress = .restoring
        case .scanning: progress = .scanning
        }
        return ExternalVolume(id: volume.id, name: volume.name, nameIsPlaceholder: volume.nameIsPlaceholder,
                              isOnline: volume.isOnline, isIncluded: volume.isIncluded, progress: progress,
                              indexedCount: volume.indexedCount, retainedCount: volume.retainedCount,
                              // `detail` carries only the file system now.
                              filesystem: volume.filesystem ?? volume.detail, capacityBytes: volume.capacityBytes)
    }

    private static func convert(_ error: EngineVolumeSettingsError) -> ExternalVolumeSettingsError {
        let category: ExternalVolumeSettingsError.Category
        switch error.category {
        case .readSettings: category = .readSettings
        case .invalidSettings: category = .invalidSettings
        case .backupSettings: category = .backupSettings
        case .writeSettings: category = .writeSettings
        case .inspectIndex: category = .inspectIndex
        case .verifyIdentity: category = .verifyIdentity
        case .removeIndex: category = .removeIndex
        }
        return ExternalVolumeSettingsError(category: category, underlyingMessage: error.underlyingMessage)
    }

    // MARK: Conversions

    private func indexStatus(from status: EngineStatus) -> IndexStatus {
        let phase: IndexPhase
        switch status.phase {
        case .starting: phase = .starting
        case .scanning(let indexed): phase = .scanning(indexed: indexed)
        case .ready: phase = .ready
        case .recovering: phase = .recovering
        case .supplementing(let name, let indexed):
            let source = status.sources.first { $0.name == name }
            phase = .supplementing(name: source.map(Self.displayName) ?? name, indexed: indexed,
                                   restoring: isRestoring(name, source))
        case .failed(let reason): phase = .degraded(reason: reason)
        }
        return IndexStatus(phase: phase, indexedCount: status.indexedCount,
                           rawInaccessiblePlaces: status.rawInaccessibleLocations.map(Self.convert),
                           inaccessiblePlaces: status.inaccessibleLocations.map(Self.convert),
                           pendingFullDiskAccessPaths: status.pendingFullDiskAccessPaths,
                           inaccessibleVerified: status.inaccessibleLocationsVerified,
                           indexBytesOnDisk: status.indexBytesOnDisk,
                           localIndexedCount: status.localIndexedCount,
                           sources: status.sources.map(Self.convert))
    }

    /// Whether the volume being supplemented is bringing back an earlier
    /// run's entries, as its scan or the volume list says.
    private func isRestoring(_ name: String, _ source: EngineSourceStatus?) -> Bool {
        guard let source, source.kind == .externalVolume else { return false }
        if source.scan?.restoring == true { return true }
        let listed = volumeLock.withLock { volumes.first { $0.id == source.id || ($0.name == name && $0.isOnline) } }
        return listed?.progress == .restoring
    }

    private static func convert(_ source: EngineSourceStatus) -> IndexSource {
        IndexSource(id: source.id, name: displayName(source),
                    kind: source.kind == .externalVolume ? .externalVolume : .cloudProvider,
                    indexed: source.indexed, isComplete: source.inaccessibleLocationsVerified,
                    failure: source.error)
    }

    /// iCloud Drive under the name the Finder gives it in Chinese; other
    /// providers keep the name of their folder.
    private static func displayName(_ source: EngineSourceStatus) -> String {
        source.cloudProviderKind == .iCloudDrive ? "iCloud 云盘" : source.name
    }

    private static func convert(_ kind: SearchKind) -> EngineKind {
        switch kind {
        case .any: return .any
        case .folder: return .folder
        case .document: return .document
        case .image: return .image
        case .audio: return .audio
        case .video: return .video
        case .archive: return .archive
        case .application: return .application
        }
    }

    private static func convert(_ location: InaccessibleLocation) -> InaccessiblePlace {
        let reason: AccessReason
        switch location.reason {
        case .likelyNeedsFullDiskAccess: reason = .needsFullDiskAccess
        case .filePermissions: reason = .filePermissions
        case .unknown: reason = .unknown
        }
        return InaccessiblePlace(path: location.path, count: location.count, reason: reason)
    }
}
