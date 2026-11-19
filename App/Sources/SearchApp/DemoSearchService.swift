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
    }

    func stop() {}
    func recheckAccess() {}
    func rebuild() { start() }

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
        publish(loaded, phase: .supplementing(name: Self.sampleVolume, indexed: 0))
        // A made-up attached volume being added, so the progress line and the
        // "checking" state of the access list can be looked at: the count
        // grows every half second, as the core reports it, then settles.
        for step in 1...24 {
            Thread.sleep(forTimeInterval: 0.5)
            publish(loaded, phase: .supplementing(name: Self.sampleVolume, indexed: step * 48_271), contentChanged: false)
        }
        publish(loaded, phase: .ready)
    }

    private static let sampleVolume = "演示外接盘"

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
