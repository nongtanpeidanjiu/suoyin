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
    private var settingsError: String?
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
            self.onStatusChange?(Self.convert(status))
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

    var status: IndexStatus { Self.convert(engine.status) }
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
                if !included { shown.isScanning = false }
                return shown
            }
        }
    }

    var externalVolumeSettingsError: String? { volumeLock.withLock { settingsError } }

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
        let error = engine.externalVolumeSettingsError
        let changed = volumeLock.withLock { () -> Bool in
            defer { (volumes, includesNew, settingsError) = (list, addsNew, error) }
            return list != volumes || addsNew != includesNew || error != settingsError
        }
        if changed && notify { onExternalVolumesChange?() }
    }

    private static func convert(_ volume: EngineVolume) -> ExternalVolume {
        ExternalVolume(id: volume.id,
                       // A volume known only from an earlier version's files
                       // has a stand-in name until it is attached again.
                       name: volume.name == "External disk" ? "外接磁盘" : volume.name,
                       isOnline: volume.isOnline, isIncluded: volume.isIncluded, isScanning: volume.isScanning,
                       indexedCount: volume.indexedCount, detail: volume.detail.map(readableDetail))
    }

    /// “exfat · 999.96 GB” as “exFAT · 1 TB”: the file system as Disk
    /// Utility names it, the size as printed on the box.
    private static func readableDetail(_ detail: String) -> String {
        let names = ["apfs": "APFS", "hfs": "Mac OS 扩展", "exfat": "exFAT", "msdos": "FAT", "ntfs": "NTFS"]
        var parts = detail.components(separatedBy: " · ")
        if let first = parts.first, let name = names[first.lowercased()] { parts[0] = name }
        if parts.count > 1, let size = boxSize(parts[1]) { parts[1] = size }
        return parts.joined(separator: " · ")
    }

    /// “999.96 GB” → “1 TB”, “63.9 GB” → “64 GB”; nil when not understood.
    private static func boxSize(_ text: String) -> String? {
        let pieces = text.split(separator: " ")
        let units: [String: Double] = ["KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12, "PB": 1e15]
        guard pieces.count == 2, let factor = units[String(pieces[1])],
              let value = Double(pieces[0].replacingOccurrences(of: ",", with: "")) else { return nil }
        let bytes = value * factor
        func trimmed(_ value: Double) -> String {
            let rounded = (value * 10).rounded() / 10
            return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        }
        if bytes >= 995e9 { return trimmed(bytes / 1e12) + " TB" }
        if bytes >= 995e6 { return String(Int((bytes / 1e9).rounded())) + " GB" }
        return String(Int((bytes / 1e6).rounded())) + " MB"
    }

    // MARK: Conversions

    private static func convert(_ status: EngineStatus) -> IndexStatus {
        let phase: IndexPhase
        switch status.phase {
        case .starting: phase = .starting
        case .scanning(let indexed): phase = .scanning(indexed: indexed)
        case .ready: phase = .ready
        case .recovering: phase = .recovering
        case .supplementing(let name, let indexed): phase = .supplementing(name: cloudName(name), indexed: indexed)
        case .failed(let reason): phase = .degraded(reason: reason)
        }
        return IndexStatus(phase: phase, indexedCount: status.indexedCount,
                           rawInaccessiblePlaces: status.rawInaccessibleLocations.map(convert),
                           inaccessiblePlaces: status.inaccessibleLocations.map(convert),
                           pendingFullDiskAccessPaths: status.pendingFullDiskAccessPaths,
                           inaccessibleVerified: status.inaccessibleLocationsVerified,
                           indexBytesOnDisk: status.indexBytesOnDisk,
                           localIndexedCount: status.localIndexedCount,
                           sources: status.sources.map(convert))
    }

    private static func convert(_ source: EngineSourceStatus) -> IndexSource {
        IndexSource(id: source.id, name: source.kind == .cloudProvider ? cloudName(source.name) : source.name,
                    kind: source.kind == .externalVolume ? .externalVolume : .cloudProvider,
                    indexed: source.indexed, isComplete: source.inaccessibleLocationsVerified,
                    failure: source.error)
    }

    /// The core names a cloud provider after its folder; iCloud Drive's
    /// folder name means nothing to a user.
    private static func cloudName(_ folder: String) -> String {
        if folder == "com~apple~CloudDocs" || folder == "Mobile Documents" { return "iCloud 云盘" }
        return folder
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
