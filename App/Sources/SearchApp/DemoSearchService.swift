import Foundation

/// Stand-in for the real core while the interface is being built. It lists a
/// few system locations that need no privacy permission, so launching the
/// skeleton never triggers an access prompt.
final class DemoSearchService: SearchService {
    private struct Entry {
        let hit: SearchHit
        let foldedName: String
        let foldedPath: String
        let kind: SearchKind?
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var current = IndexStatus(phase: .starting, indexedCount: 0, indexBytesOnDisk: 0)

    var onStatusChange: ((IndexStatus) -> Void)?
    var onIndexChange: (() -> Void)?
    var status: IndexStatus { lock.withLock { current } }

    func start() {
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.load() }
        DispatchQueue.main.async { [weak self] in self?.runScans() }
    }

    func stop() {}
    func recheckAccess() {}
    func rebuild() { start() }

    // MARK: Attached volumes

    /// Made-up volumes, one for each state the list can show: being read,
    /// being restored from an earlier run, attached but left out with kept
    /// entries, detached with kept entries, and one known only from an
    /// earlier version's files. The choices act on these at once, the way
    /// the core acts on real ones, but nothing touches a real disk.
    private var volumes: [ExternalVolume] = [
        ExternalVolume(id: "demo-backup", name: "演示备份盘", isOnline: true, isIncluded: true, progress: .scanning,
                       indexedCount: 41_206, retainedCount: 41_206, filesystem: "exfat",
                       capacityBytes: 999_962_312_704),
        ExternalVolume(id: "demo-portable", name: "演示移动硬盘", isOnline: true, isIncluded: true, progress: .restoring,
                       indexedCount: 154_032, retainedCount: 154_032, filesystem: "hfs",
                       capacityBytes: 512_110_190_592),
        ExternalVolume(id: "demo-stick", name: "演示 U 盘", isOnline: true, isIncluded: false,
                       indexedCount: 0, retainedCount: 12_877, filesystem: "msdos", capacityBytes: 63_864_569_856),
        ExternalVolume(id: "demo-archive", name: "演示归档盘", isOnline: false, isIncluded: true,
                       indexedCount: 0, retainedCount: 230_118, filesystem: "apfs", capacityBytes: 2_000_398_934_016),
        ExternalVolume(id: "3F2A9C41-demo", name: "3F2A9C41", nameIsPlaceholder: true, isOnline: false, isIncluded: true,
                       indexedCount: 0, retainedCount: nil),
    ]
    /// How many entries each volume being read ends up with.
    private var scanTargets: [String: Int] = ["demo-backup": 386_540, "demo-portable": 171_500, "demo-stick": 19_340]
    /// Half-second steps a restore takes before reading new folders.
    private var restoreSteps: [String: Int] = [:]
    private var scanTimer: Timer?

    var onExternalVolumesChange: (() -> Void)?
    var externalVolumes: [ExternalVolume] { volumes }
    /// `--demo-volume-error [category]` shows how a settings error of the
    /// core looks; the category defaults to a failed save.
    let externalVolumeSettingsError: ExternalVolumeSettingsError? = {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--demo-volume-error") else { return nil }
        let categories: [String: ExternalVolumeSettingsError.Category] = [
            "readSettings": .readSettings, "invalidSettings": .invalidSettings, "backupSettings": .backupSettings,
            "writeSettings": .writeSettings, "inspectIndex": .inspectIndex, "verifyIdentity": .verifyIdentity,
            "removeIndex": .removeIndex,
        ]
        let named = arguments.indices.contains(flag + 1) ? categories[arguments[flag + 1]] : nil
        return ExternalVolumeSettingsError(
            category: named ?? .writeSettings,
            underlyingMessage: "Error Domain=NSCocoaErrorDomain Code=513 \"You don’t have permission to save the file.\"")
    }()

    /// Kept in memory only, so the demo never touches the real choice.
    var includesNewExternalVolumes = false {
        didSet { onExternalVolumesChange?() }
    }

    func setExternalVolume(_ id: String, included: Bool) {
        guard let index = volumes.firstIndex(where: { $0.id == id }), volumes[index].isIncluded != included else { return }
        var volume = volumes[index]
        volume.isIncluded = included
        if included && volume.isOnline {
            // Added back: what was kept comes back first, then the rest is read.
            let kept = volume.retainedCount ?? 0
            volume.progress = kept > 0 ? .restoring : .scanning
            volume.indexedCount = kept
        } else {
            // As the core reports it: nothing of it is searched any more, but
            // what was indexed is kept.
            volume.retainedCount = max(volume.retainedCount ?? 0, volume.indexedCount)
            volume.progress = .idle
            volume.indexedCount = 0
        }
        volumes[index] = volume
        changedVolumes()
    }

    func removeExternalVolumeData(_ id: String) {
        guard let index = volumes.firstIndex(where: { $0.id == id }) else { return }
        // As the core does: a detached volume is forgotten, an attached one
        // stays listed, left out, with nothing kept.
        if !volumes[index].isOnline {
            volumes.remove(at: index)
        } else {
            volumes[index].isIncluded = false
            volumes[index].progress = .idle
            volumes[index].indexedCount = 0
            volumes[index].retainedCount = 0
        }
        changedVolumes()
    }

    private func changedVolumes() {
        onExternalVolumesChange?()
        runScans()
    }

    /// Counts rise every half second, as the core reports them. A restore
    /// shows its whole count at once and turns into reading after a while.
    private func runScans() {
        guard scanTimer == nil, volumes.contains(where: \.isScanning) else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            for index in self.volumes.indices {
                let id = self.volumes[index].id
                switch self.volumes[index].progress {
                case .idle: continue
                case .restoring:
                    self.restoreSteps[id, default: 0] += 1
                    if self.restoreSteps[id, default: 0] >= 20 {
                        self.restoreSteps[id] = nil
                        self.volumes[index].progress = .scanning
                    }
                case .scanning:
                    let target = self.scanTargets[id] ?? 50_000
                    let next = min(self.volumes[index].indexedCount + max(target / 90, 137), target)
                    self.volumes[index].indexedCount = next
                    self.volumes[index].retainedCount = max(self.volumes[index].retainedCount ?? 0, next)
                    if next >= target { self.volumes[index].progress = .idle }
                }
            }
            if !self.volumes.contains(where: \.isScanning) {
                timer.invalidate()
                self.scanTimer = nil
            }
            self.onExternalVolumesChange?()
        }
        // Common modes: the counts keep moving while a list is being scrolled.
        RunLoop.main.add(timer, forMode: .common)
        scanTimer = timer
    }

    private func load() {
        let roots: [(String, Int)] = [
            ("/Applications", 2), ("/System/Applications", 2), ("/System/Library/Fonts", 2),
            ("/Library/Fonts", 1), ("/System/Library/Desktop Pictures", 1), ("/System/Library/Sounds", 1),
            ("/usr/share/man/man1", 1),
        ]
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        var loaded: [Entry] = []
        var nextID: UInt64 = 1
        for (root, depth) in roots {
            let base = URL(fileURLWithPath: root)
            guard let walker = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                if walker.level >= depth { walker.skipDescendants() }
                let values = try? url.resourceValues(forKeys: Set(keys))
                let hit = SearchHit(
                    id: nextID, name: url.lastPathComponent, path: url.path,
                    isDirectory: values?.isDirectory ?? false, size: Int64(values?.fileSize ?? 0),
                    modified: values?.contentModificationDate ?? .distantPast,
                    isCloudPlaceholder: false, isOnExternalVolume: false)
                nextID += 1
                loaded.append(Entry(hit: hit,
                                    foldedName: hit.name.precomposedStringWithCanonicalMapping.lowercased(),
                                    foldedPath: hit.path.precomposedStringWithCanonicalMapping.lowercased(),
                                    kind: Self.kind(name: hit.name, isDirectory: hit.isDirectory)))
                if loaded.count % 500 == 0 { publish(loaded, phase: .scanning(indexed: loaded.count)) }
            }
        }
        loaded.sort { $0.foldedName == $1.foldedName ? $0.hit.path < $1.hit.path : $0.foldedName < $1.foldedName }
        // Made-up attached volumes being added, so the progress lines and the
        // "checking" state of the access list can be looked at: first one
        // brings back what an earlier run indexed (its count is there at
        // once), then another is read, its count growing every half second
        // as the core reports it, then all settles.
        publish(loaded, phase: .supplementing(name: Self.restoredVolume, indexed: 0, restoring: true))
        for _ in 1...8 {
            Thread.sleep(forTimeInterval: 0.5)
            publish(loaded, phase: .supplementing(name: Self.restoredVolume, indexed: 154_032, restoring: true),
                    contentChanged: false)
        }
        for step in 1...24 {
            Thread.sleep(forTimeInterval: 0.5)
            publish(loaded, phase: .supplementing(name: Self.sampleVolume, indexed: step * 48_271, restoring: false),
                    contentChanged: false)
        }
        publish(loaded, phase: .ready)
    }

    private static let sampleVolume = "演示备份盘"
    private static let restoredVolume = "演示移动硬盘"

    private func publish(_ loaded: [Entry], phase: IndexPhase, contentChanged: Bool = true) {
        var snapshot = IndexStatus(phase: phase, indexedCount: loaded.count, indexBytesOnDisk: 0)
        if case .ready = phase { Self.addSampleAccessState(to: &snapshot) } else { snapshot.inaccessibleVerified = false }
        lock.withLock {
            entries = loaded
            current = snapshot
        }
        onStatusChange?(snapshot)
        if contentChanged { onIndexChange?() }
    }

    /// The same kinds the core recognises, by the directory flag and the last
    /// extension (docs/里程碑4-门面验收.md). Nil for other files.
    private static func kind(name: String, isDirectory: Bool) -> SearchKind? {
        let dot = name.dropFirst().lastIndex(of: ".")
        let ext = dot.map { name[name.index(after: $0)...].lowercased() } ?? ""
        if isDirectory { return ext == "app" ? .application : .folder }
        return extensions.first { $0.value.contains(ext) }?.key
    }

    private static let extensions: [SearchKind: Set<String>] = [
        .document: ["csv", "doc", "docm", "docx", "dps", "epub", "et", "key", "md", "numbers", "odp", "ods", "odt",
                    "pages", "pdf", "ppt", "pptm", "pptx", "rtf", "tsv", "txt", "wps", "xls", "xlsm", "xlsx"],
        .image: ["3fr", "arw", "avif", "bmp", "cr2", "cr3", "dng", "gif", "heic", "heif", "icns", "ico", "j2k", "jp2",
                 "jpeg", "jpg", "nef", "nrw", "orf", "pef", "png", "psd", "raf", "raw", "rw2", "srf", "svg", "tif",
                 "tiff", "webp"],
        .audio: ["aac", "aif", "aiff", "alac", "flac", "m4a", "mid", "midi", "mp3", "ogg", "opus", "wav", "wma"],
        .video: ["3gp", "avi", "flv", "m2ts", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "mts", "webm", "wmv"],
        .archive: ["7z", "bz2", "dmg", "gz", "iso", "rar", "tar", "tbz", "tbz2", "tgz", "txz", "xar", "xz", "zip", "zst"],
    ]

    private static func matches(_ entry: Entry, _ kind: SearchKind) -> Bool {
        switch kind {
        case .any: return true
        // An application is also a folder, as in the core.
        case .folder: return entry.hit.isDirectory
        default: return entry.kind == kind
        }
    }

    /// Made-up but typical access results, so the settings list can be
    /// looked at without the real core. Nothing here is read from disk.
    private static func addSampleAccessState(to status: inout IndexStatus) {
        let home = NSHomeDirectory()
        var raw: [InaccessiblePlace] = []
        func add(_ reason: AccessReason, _ paths: [String]) {
            raw += paths.map { InaccessiblePlace(path: $0, count: 1, reason: reason) }
        }
        add(.needsFullDiskAccess, ["\(home)/Library/Mail", "\(home)/Library/Messages", "\(home)/Library/Safari"])
        add(.filePermissions, (1...24).map { "/private/var/db/sample/item\($0)" }
            + ["/Library/Application Support/com.apple.TCC", "/private/var/audit"])
        add(.unknown, (1...12).map { "/System/Library/Sample/Protected\($0)" } + ["/private/var/folders/zz"])
        raw.sort { $0.path < $1.path }
        // Merged the way the core does it: siblings under their shared parent.
        let merged = Dictionary(grouping: raw) { place -> String in
            let parent = (place.path as NSString).deletingLastPathComponent
            return raw.filter { ($0.path as NSString).deletingLastPathComponent == parent && $0.reason == place.reason }
                .count > 1 ? parent : place.path
        }
        status.rawInaccessiblePlaces = raw
        status.inaccessiblePlaces = merged.map { path, places in
            InaccessiblePlace(path: path, count: places.count, reason: places[0].reason)
        }.sorted { $0.path < $1.path }
        status.pendingFullDiskAccessPaths = ["\(home)/Library/Containers", "\(home)/Library/Group Containers"]
    }

    func search(_ request: SearchRequest) -> SearchResponse {
        let terms = queryTerms(request.text)
        guard !terms.isEmpty else { return SearchResponse(hits: [], total: 0, totalIsExact: true) }
        let all = lock.withLock { entries }
        var hits: [SearchHit] = []
        var total = 0
        for entry in all {
            let haystack = request.scope == .name ? entry.foldedName : entry.foldedPath
            guard Self.matches(entry, request.kind), terms.allSatisfy({ haystack.contains($0) }) else { continue }
            if total >= request.offset && hits.count < request.limit { hits.append(entry.hit) }
            total += 1
        }
        return SearchResponse(hits: hits, total: total, totalIsExact: true)
    }
}
