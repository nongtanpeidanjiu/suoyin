import Foundation

/// Stand-in for the real core while the interface is being built. It lists a
/// few system locations that need no privacy permission, so launching the
/// skeleton never triggers an access prompt.
final class DemoSearchService: SearchService {
    private struct Entry {
        let hit: SearchHit
        let foldedName: String
        let foldedPath: String
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
                                    foldedPath: hit.path.precomposedStringWithCanonicalMapping.lowercased()))
                if loaded.count % 500 == 0 { publish(loaded, phase: .scanning(indexed: loaded.count)) }
            }
        }
        loaded.sort { $0.foldedName == $1.foldedName ? $0.hit.path < $1.hit.path : $0.foldedName < $1.foldedName }
        publish(loaded, phase: .ready)
    }

    private func publish(_ loaded: [Entry], phase: IndexPhase) {
        var snapshot = IndexStatus(phase: phase, indexedCount: loaded.count, indexBytesOnDisk: 0)
        if case .ready = phase { Self.addSampleAccessState(to: &snapshot) }
        lock.withLock {
            entries = loaded
            current = snapshot
        }
        onStatusChange?(snapshot)
        onIndexChange?()
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
            guard terms.allSatisfy({ haystack.contains($0) }) else { continue }
            if total >= request.offset && hits.count < request.limit { hits.append(entry.hit) }
            total += 1
        }
        return SearchResponse(hits: hits, total: total, totalIsExact: true)
    }
}
