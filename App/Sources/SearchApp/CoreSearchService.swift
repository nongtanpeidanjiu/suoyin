import AppKit
import SearchCore

// MARK: - Waiting for the core: attached volumes
//
// The settings window and the setup guide already offer these choices. Until
// the core provides them, this bridge only remembers them in the user
// defaults (`ExternalVolumePreferences`) and `supportsExternalVolumeControl`
// is false, so the interface says under the controls that they take effect
// in the next version. To connect them, the core needs:
//
// 1. A list of every attached volume it knows, including ones not attached
//    right now whose entries it still keeps: a stable id (the volume UUID
//    where there is one), the name, whether it is attached, whether it is
//    included, whether it is being scanned or brought up to date, and its
//    entry count. `EngineStatus.sources` (kind `.externalVolume`) on the
//    main branch has the id, name and count; it lacks the attached,
//    included and scanning flags. It is read below by reflection only
//    because this branch's core does not have it yet: after merging, read
//    `status.sources` directly and delete `reportedSources`.
// 2. A setting for volumes attached for the first time: add them by
//    themselves, or leave them out until the user adds them. Today every
//    attached volume is scanned at once. Default: leave them out.
// 3. Including or leaving out one volume by id, kept across launches and
//    across detaching and attaching. Leaving one out stops its scan at once
//    and takes its entries out of search results (they may stay on disk).
//    Including one starts or resumes its scan.
// 4. Deleting what was indexed for one volume by id: its entries, scan log
//    and event-log position. Afterwards the volume counts as left out; a
//    volume that is not attached is forgotten.
// 5. A status update whenever any of the above changes, so the list stays
//    current; counts while scanning at the usual half-second pace.
//
// Then make `supportsExternalVolumeControl` true and pass the calls on.

/// Bridges the interface protocol to the real search core running in-process.
final class CoreSearchService: SearchService {
    private let engine: SearchEngine
    var onStatusChange: ((IndexStatus) -> Void)?
    var onIndexChange: (() -> Void)?
    var onExternalVolumesChange: (() -> Void)?
    private let volumeLock = NSLock()
    private var mounted: [MountedVolume] = []
    private var lastVolumes: [ExternalVolume] = []

    init() throws {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("dev.local.filesearch", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        engine = try SearchEngine(dataDirectory: directory)
    }

    func start() {
        engine.onStatusChange = { [weak self] status in
            guard let self else { return }
            self.onStatusChange?(Self.convert(status))
            self.noteVolumesMayHaveChanged()
        }
        engine.onIndexChange = { [weak self] in self?.onIndexChange?() }
        engine.start()
        refreshMounted()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.refreshMounted() }
        }
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

    /// See the list at the top of this file.
    var supportsExternalVolumeControl: Bool { false }

    var includesNewExternalVolumes: Bool {
        get { ExternalVolumePreferences.includeNew }
        set { ExternalVolumePreferences.includeNew = newValue }
    }

    var externalVolumes: [ExternalVolume] {
        let mounted = volumeLock.withLock { self.mounted }
        let status = engine.status
        let reported = Self.reportedSources(status)
        var scanning: String?
        var scanningCount = 0
        if case .supplementing(let name, let indexed) = status.phase { (scanning, scanningCount) = (name, indexed) }
        let choices = UserDefaults.standard.dictionary(forKey: ExternalVolumePreferences.choicesKey) as? [String: Bool] ?? [:]
        var known = Self.knownVolumes()

        var volumes: [ExternalVolume] = []
        var seen = Set<String>()
        func add(id: String, name: String, online: Bool, count: Int?, detail: String?) {
            guard seen.insert(id).inserted else { return }
            let isScanning = online && name == scanning
            // Without a choice of its own a volume is shown as the core
            // actually treats it today: included.
            volumes.append(ExternalVolume(id: id, name: name, isOnline: online, isIncluded: choices[id] ?? true,
                                          isScanning: isScanning,
                                          indexedCount: count ?? (isScanning ? scanningCount : 0), detail: detail))
        }
        for volume in mounted {
            let source = reported?.first { $0.id == volume.id }
            add(id: volume.id, name: volume.name, online: true, count: source?.indexed, detail: volume.detail)
            known[volume.id] = ["name": volume.name, "detail": volume.detail ?? ""]
        }
        for source in reported ?? [] {
            let detail = known[source.id]?["detail"].flatMap { $0.isEmpty ? nil : $0 }
            add(id: source.id, name: source.name, online: false, count: source.indexed, detail: detail)
        }
        for (id, record) in known.sorted(by: { $0.key < $1.key }) {
            let detail = record["detail"].flatMap { $0.isEmpty ? nil : $0 }
            add(id: id, name: record["name"] ?? id, online: false, count: nil, detail: detail)
        }
        if known != Self.knownVolumes() { UserDefaults.standard.set(known, forKey: ExternalVolumePreferences.knownKey) }
        return volumes
    }

    func setExternalVolume(_ id: String, included: Bool) {
        var choices = UserDefaults.standard.dictionary(forKey: ExternalVolumePreferences.choicesKey) as? [String: Bool] ?? [:]
        choices[id] = included
        UserDefaults.standard.set(choices, forKey: ExternalVolumePreferences.choicesKey)
        noteVolumesMayHaveChanged(force: true)
    }

    /// Not offered while `supportsExternalVolumeControl` is false: nothing
    /// can be deleted yet, so pretending would mislead.
    func removeExternalVolumeData(_ id: String) {}

    private static func knownVolumes() -> [String: [String: String]] {
        UserDefaults.standard.dictionary(forKey: ExternalVolumePreferences.knownKey) as? [String: [String: String]] ?? [:]
    }

    private func noteVolumesMayHaveChanged(force: Bool = false) {
        let current = externalVolumes
        let changed = volumeLock.withLock { () -> Bool in
            defer { lastVolumes = current }
            return current != lastVolumes
        }
        if changed || force { onExternalVolumesChange?() }
    }

    // MARK: Mounted volumes

    private struct MountedVolume {
        let id: String
        let name: String
        let detail: String?
    }

    /// Local, browsable volumes that are not part of this Mac, read from the
    /// volume properties only; nothing on them is opened.
    private func refreshMounted() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeLocalizedNameKey, .volumeIsInternalKey, .volumeIsLocalKey,
                                      .volumeIsBrowsableKey, .volumeUUIDStringKey, .volumeTotalCapacityKey,
                                      .volumeIsRootFileSystemKey, .volumeTypeNameKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        var found: [MountedVolume] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsRootFileSystem != true, values.volumeIsLocal == true,
                  values.volumeIsBrowsable != false, values.volumeIsInternal != true else { continue }
            let name = values.volumeLocalizedName ?? values.volumeName ?? url.lastPathComponent
            found.append(MountedVolume(id: values.volumeUUIDString ?? url.path, name: name,
                                       detail: Self.detail(type: values.volumeTypeName,
                                                           capacity: values.volumeTotalCapacity)))
        }
        volumeLock.withLock { mounted = found }
        noteVolumesMayHaveChanged()
    }

    /// “exFAT · 1 TB”.
    private static func detail(type: String?, capacity: Int?) -> String? {
        let names = ["apfs": "APFS", "hfs": "Mac OS 扩展", "exfat": "exFAT", "msdos": "FAT32", "ntfs": "NTFS"]
        var parts: [String] = []
        if let type { parts.append(names[type.lowercased()] ?? type) }
        if let capacity, capacity > 0 { parts.append(roundedCapacity(Double(capacity))) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The size printed on the box: “1 TB” rather than “999.96 GB”.
    private static func roundedCapacity(_ bytes: Double) -> String {
        func trimmed(_ value: Double) -> String {
            let rounded = (value * 10).rounded() / 10
            return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        }
        if bytes >= 995e9 { return trimmed(bytes / 1e12) + " TB" }
        if bytes >= 995e6 { return String(Int((bytes / 1e9).rounded())) + " GB" }
        return String(Int((bytes / 1e6).rounded())) + " MB"
    }

    /// The attached volumes the core reports in `EngineStatus.sources`, or
    /// nil when this core has no such list. Temporary; see the top of the file.
    private static func reportedSources(_ status: EngineStatus) -> [(id: String, name: String, indexed: Int)]? {
        guard let list = Mirror(reflecting: status).children.first(where: { $0.label == "sources" })?.value else {
            return nil
        }
        return Mirror(reflecting: list).children.compactMap { element in
            var fields: [String: Any] = [:]
            for child in Mirror(reflecting: element.value).children {
                if let label = child.label { fields[label] = child.value }
            }
            guard let id = fields["id"] as? String, let name = fields["name"] as? String,
                  fields["kind"].map({ "\($0)" }) == "externalVolume" else { return nil }
            return (id, name, fields["indexed"] as? Int ?? 0)
        }
    }

    // MARK: Conversions

    private static func convert(_ status: EngineStatus) -> IndexStatus {
        let phase: IndexPhase
        switch status.phase {
        case .starting: phase = .starting
        case .scanning(let indexed): phase = .scanning(indexed: indexed)
        case .ready: phase = .ready
        case .recovering: phase = .recovering
        case .supplementing(let name, let indexed): phase = .supplementing(name: name, indexed: indexed)
        case .failed(let reason): phase = .degraded(reason: reason)
        }
        return IndexStatus(phase: phase, indexedCount: status.indexedCount,
                           rawInaccessiblePlaces: status.rawInaccessibleLocations.map(convert),
                           inaccessiblePlaces: status.inaccessibleLocations.map(convert),
                           pendingFullDiskAccessPaths: status.pendingFullDiskAccessPaths,
                           inaccessibleVerified: status.inaccessibleLocationsVerified,
                           indexBytesOnDisk: status.indexBytesOnDisk)
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
