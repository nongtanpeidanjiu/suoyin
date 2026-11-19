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
    private var unindexed: [UnindexedVolume] = []
    private var includesNew = false
    private var settingsError: ExternalVolumeSettingsError?
    /// Choices sent to the core and not yet reflected in what it reports.
    private var pendingChoices: [String: Bool] = [:]
    private var pendingIncludesNew: Bool?
    /// Volumes being taken off the list: shown as “正在移除…” until the
    /// core no longer lists them or the request failed.
    private var pendingForgets: Set<String> = []
    /// Why the last request to take a volume off the list failed; cleared by
    /// the next change the user makes to the volumes.
    private var forgetError: ExternalVolumeSettingsError?

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
        do {
            engine = try SearchEngine(dataDirectory: directory)
        } catch let failure as EngineFailure {
            // The interface explains the category in its own words.
            throw Self.convert(failure)
        }
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
                                offset: request.offset, limit: request.limit,
                                totalCountBudget: request.totalCountBudget)
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
    var indexDataDirectoryExclusion: String? { engine.indexDataDirectoryExclusion }

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
                if pendingForgets.contains(volume.id) {
                    var shown = volume
                    shown.isRemoving = true
                    shown.progress = .idle
                    return shown
                }
                guard let included = pendingChoices[volume.id], included != volume.isIncluded else { return volume }
                var shown = volume
                shown.isIncluded = included
                if !included { shown.progress = .idle }
                return shown
            }
        }
    }

    var externalVolumeSettingsError: ExternalVolumeSettingsError? {
        volumeLock.withLock { forgetError ?? settingsError }
    }

    var unindexedMountedVolumes: [UnindexedVolume] { volumeLock.withLock { unindexed } }

    /// Asks the core off the main thread (it waits on its volume queue) and
    /// answers on the main thread; the new state follows through
    /// `onExternalVolumesChange`.
    func retryExternalVolume(_ id: String, completion: @escaping (Bool) -> Void) {
        volumeLock.withLock { forgetError = nil }
        volumeQueue.async { [weak self] in
            guard let self else { return }
            let accepted = self.engine.retryExternalVolume(id)
            self.readVolumes(notify: true)
            DispatchQueue.main.async { completion(accepted) }
        }
    }

    /// Leaving a volume out takes its files out of the results as soon as
    /// the core returns; its data stays until deleted.
    func setExternalVolume(_ id: String, included: Bool) {
        volumeLock.withLock { pendingChoices[id] = included; forgetError = nil }
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
        volumeLock.withLock { pendingChoices[id] = false; forgetError = nil }
        onExternalVolumesChange?()
        volumeQueue.async { [weak self] in
            guard let self else { return }
            self.engine.removeExternalVolumeData(id)
            self.volumeLock.withLock { _ = self.pendingChoices.removeValue(forKey: id) }
            self.readVolumes(notify: true)
            self.onIndexChange?()
        }
    }

    /// The row reads “正在移除…” at once. The core either removes the volume
    /// now or finishes later and reports it through `onExternalVolumesChange`;
    /// until then the mark stays. A failure clears the mark and shows why.
    func forgetExternalVolume(_ id: String) {
        volumeLock.withLock { _ = pendingForgets.insert(id); forgetError = nil }
        onExternalVolumesChange?()
        volumeQueue.async { [weak self] in
            guard let self else { return }
            do {
                if try self.engine.forgetExternalVolume(id) == .removed {
                    self.volumeLock.withLock { _ = self.pendingForgets.remove(id) }
                }
            } catch {
                self.volumeLock.withLock {
                    self.pendingForgets.remove(id)
                    self.forgetError = Self.forgetFailure(error)
                }
            }
            // The mark or the error changed even when the list did not.
            self.readVolumes()
            self.onExternalVolumesChange?()
            self.onIndexChange?()
        }
    }

    private static func forgetFailure(_ error: Error) -> ExternalVolumeSettingsError {
        switch error as? EngineVolumeForgetError {
        case .online: return ExternalVolumeSettingsError(category: .forgetOnline, underlyingMessage: "")
        case .notFound: return ExternalVolumeSettingsError(category: .forgetNotFound, underlyingMessage: "")
        case .unavailable: return ExternalVolumeSettingsError(category: .forgetUnavailable, underlyingMessage: "")
        case .settings(let failure): return convert(failure)
        case nil:
            return ExternalVolumeSettingsError(category: .forgetUnavailable, underlyingMessage: String(describing: error))
        }
    }

    private func refreshVolumes() {
        volumeQueue.async { [weak self] in self?.readVolumes(notify: true) }
    }

    /// Reads the volumes from the core and tells the interface if anything
    /// it shows changed.
    private func readVolumes(notify: Bool = false) {
        let list = engine.externalVolumes.map(Self.convert)
        let others = engine.unindexedMountedVolumes.map(Self.convert)
        let addsNew = engine.includesNewExternalVolumes
        let error = engine.externalVolumeSettingsError.map(Self.convert)
        let changed = volumeLock.withLock { () -> Bool in
            // A volume the core no longer lists is gone: its mark goes too.
            pendingForgets.formIntersection(list.map(\.id))
            defer { (volumes, unindexed, includesNew, settingsError) = (list, others, addsNew, error) }
            return list != volumes || others != unindexed || addsNew != includesNew || error != settingsError
        }
        if changed && notify { onExternalVolumesChange?() }
    }

    private static func convert(_ volume: EngineVolume) -> ExternalVolume {
        let progress: ExternalVolume.Progress
        switch volume.progress {
        case .idle: progress = .idle
        case .restoring: progress = .restoring
        case .scanning: progress = .scanning
        case .failed: progress = .failed
        }
        return ExternalVolume(id: volume.id, name: volume.name, nameIsPlaceholder: volume.nameIsPlaceholder,
                              isOnline: volume.isOnline, isIncluded: volume.isIncluded, progress: progress,
                              indexedCount: volume.indexedCount, retainedCount: volume.retainedCount,
                              // `detail` carries only the file system now.
                              filesystem: volume.filesystem ?? volume.detail, capacityBytes: volume.capacityBytes,
                              canForget: volume.canForget, failure: volume.failure.map(Self.convert),
                              requiresManualInclusion: volume.requiresManualInclusion)
    }

    private static func convert(_ volume: EngineUnindexedVolume) -> UnindexedVolume {
        let kind: UnindexedVolume.Kind
        switch volume.kind {
        case .diskImage: kind = .diskImage
        case .network: kind = .network
        case .local: kind = .local
        }
        let reason: UnindexedVolume.Reason
        switch volume.reason {
        case .diskImagesDisabled: reason = .diskImagesDisabled
        case .networkUnsupported: reason = .networkUnsupported
        case .localVolumeUnsupported: reason = .localVolumeUnsupported
        }
        return UnindexedVolume(id: volume.id, name: volume.name, kind: kind, reason: reason)
    }

    private static func convert(_ failure: EngineFailure) -> IndexFailure {
        let category: IndexFailure.Category
        switch failure.category {
        case .dataDirectoryUnavailable: category = .dataDirectoryUnavailable
        case .diskRead: category = .diskRead
        case .indexCorrupt: category = .indexCorrupt
        case .indexLimitExceeded: category = .indexLimitExceeded
        case .other: category = .other
        }
        return IndexFailure(category: category, underlyingMessage: failure.underlyingMessage)
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
        case .failed(let failure): phase = .failed(Self.convert(failure))
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
                    failure: source.failure.map(Self.convert)
                        ?? source.error.map { IndexFailure(category: .other, underlyingMessage: $0) },
                    rawInaccessiblePlaces: source.rawInaccessibleLocations.map(Self.convert),
                    inaccessiblePlaces: source.inaccessibleLocations.map(Self.convert))
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
