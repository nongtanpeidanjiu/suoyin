import Darwin
import DarwinMetadata
import Foundation

func inside(_ path: String, _ root: String) -> Bool {
    root == "/" || path == root || path.hasPrefix(root + "/")
}

func parentPath(_ path: String) -> String {
    guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
    return String(path[..<slash])
}

func leafName(_ path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return path }
    return String(path[path.index(after: slash)...])
}

func joinedPath(_ parent: String, _ name: String) -> String {
    parent == "/" ? "/" + name : parent + "/" + name
}

enum DirectoryObservation {
    case readable(own: TrackedEntry, children: [String: TrackedEntry])
    case absent
    case restricted
}

struct DirectoryLinks {
    private let present: [UInt64]
    private let ranks: [UInt32]
    private let heads: [UInt32]
    let runs: [DMChildRun]
    let anchors: [String: UInt32]

    init(_ index: SearchIndex) {
        var first = [UInt32](repeating: .max, count: index.recordCount)
        var childRuns: [DMChildRun] = []
        var roots: [String: UInt32] = [:]
        var cursor = 0
        while cursor < index.recordCount {
            let parent = index.records[cursor].parent
            if parent == .max {
                roots[index.name(UInt32(cursor))] = UInt32(cursor)
                cursor += 1
                continue
            }
            let start = cursor
            repeat { cursor += 1 } while cursor < index.recordCount && index.records[cursor].parent == parent
            childRuns.append(DMChildRun(start: UInt32(start), end: UInt32(cursor), next: first[Int(parent)]))
            first[Int(parent)] = UInt32(childRuns.count - 1)
        }
        var bits = [UInt64](repeating: 0, count: (first.count + 63) / 64)
        var compact: [UInt32] = []
        for (i, head) in first.enumerated() where head != .max {
            bits[i >> 6] |= 1 << (i & 63)
            compact.append(head)
        }
        var rank: UInt32 = 0
        ranks = bits.map { word in
            defer { rank += UInt32(word.nonzeroBitCount) }
            return rank
        }
        present = bits
        heads = compact
        runs = childRuns
        anchors = roots
    }

    func head(_ parent: UInt32) -> UInt32 {
        let word = Int(parent >> 6)
        let bit = UInt64(1) << (parent & 63)
        guard present[word] & bit != 0 else { return .max }
        return heads[Int(ranks[word]) + (present[word] & (bit - 1)).nonzeroBitCount]
    }

    func forEachChild(_ parent: UInt32, _ body: (UInt32) -> Void) {
        var index = head(parent)
        while index != .max {
            let run = runs[Int(index)]
            for row in run.start..<run.end { body(row) }
            index = run.next
        }
    }

    var bytes: Int {
        present.capacity * 8 + (ranks.capacity + heads.capacity) * 4 + runs.capacity * MemoryLayout<DMChildRun>.stride
    }
}

/// Separately published immutable base/change views let queries proceed during enumeration.
struct LiveIndex {
    var base: SearchIndex
    private static let partitionCount = 8
    private var overlays = [SearchIndex](repeating: SearchIndex(), count: partitionCount)
    private var changedChildren: [String: Set<String>] = [:]
    private var dirtyPartitions: Set<Int> = []
    var state: TrackingState
    private var directories: [String: UInt32] = [:]
    private let links: DirectoryLinks?

    init(base: SearchIndex, root: String, linkChildren: Bool = true) {
        self.base = base
        state = base.tracking ?? TrackingState(root: root, changes: [:], restricted: [])
        self.base.tracking = nil
        if base.tracking != nil {
            for i in base.attributes.indices where base.attributes[i] & Kind.suppressed != 0 {
                self.base.attributes[i] &= ~Kind.suppressed
                self.base.setSuppressed(i, true)
            }
        }
        links = linkChildren ? DirectoryLinks(base) : nil
        for path in state.changes.keys {
            let parent = parentPath(path)
            changedChildren[parent, default: []].insert(path)
            dirtyPartitions.insert(Self.partition(parent))
        }
        prepareDelta()
    }

    private static func partition(_ path: String) -> Int {
        let hash = path.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        return Int(hash) & (partitionCount - 1)
    }

    private mutating func change(_ value: TrackedEntry?, at path: String) {
        guard state.changes[path] != value else { return }
        let parent = parentPath(path)
        state.changes[path] = value
        if value == nil {
            changedChildren[parent]?.remove(path)
            if changedChildren[parent]?.isEmpty == true { changedChildren.removeValue(forKey: parent) }
        } else {
            changedChildren[parent, default: []].insert(path)
        }
        dirtyPartitions.insert(Self.partition(parent))
    }

    mutating func prepareDelta() {
        guard !dirtyPartitions.isEmpty else { return }
        var groups: [Int: [String]] = [:]
        for parent in changedChildren.keys {
            let shard = Self.partition(parent)
            if dirtyPartitions.contains(shard) { groups[shard, default: []].append(parent) }
        }
        for shard in dirtyPartitions {
            var index = SearchIndex()
            for parent in (groups[shard] ?? []).sorted() {
                let id = index.append(parent, attribute: Kind.anchor)
                for path in changedChildren[parent]!.sorted() {
                    let item = state.changes[path]!
                    index.append(leafName(path), parent: id, size: item.size,
                                 modified: item.modified, attribute: item.attribute)
                }
            }
            index.prepare()
            overlays[shard] = index
        }
        dirtyPartitions.removeAll()
    }

    func archive() -> SearchIndex {
        var result = base
        result.tracking = state
        for (byte, bits) in base.suppressed.enumerated() where bits != 0 {
            var remaining = bits
            while remaining != 0 {
                let bit = remaining.trailingZeroBitCount
                result.attributes[byte * 8 + bit] |= Kind.suppressed
                remaining &= remaining - 1
            }
        }
        result.suppressed = []
        return result
    }

    func journalImage(at positions: [String: UInt64]) -> JournalImage {
        JournalImage(rows: state.changes, masks: base.suppressed, coverage: state.restricted,
                     positions: positions)
    }

    /// Rebuild row IDs without expanding every base row into a path string.
    /// A directory with updated metadata keeps its descendants attached.
    func compacted() -> SearchIndex {
        var result = SearchIndex()
        var edits = state.changes
        var remap = [UInt32](repeating: .max, count: base.recordCount)
        var parents: [String: UInt32] = [:]
        let wantedParents = Set(edits.keys.map(parentPath))
        let parentNames = Set(wantedParents.map(leafName))
        let editedDirectories = Set(edits.compactMap { $0.value.directory ? leafName($0.key) : nil })
        result.reserve(base.recordCount + edits.count, nameBytes: base.names.count)
        base.names.withUnsafeBufferPointer { pool in
            for (i, row) in base.records.enumerated() {
                let id = UInt32(i)
                let parent = row.parent == .max ? .max : remap[Int(row.parent)]
                if row.parent != .max && parent == .max { continue }
                let flag = base.attributes[i]
                let kind = flag & Kind.mask
                let size: Int64
                let modified: Int64
                let attributes: UInt8
                if base.isSuppressed(i) {
                    guard kind == Kind.directory, editedDirectories.contains(base.name(id)) else { continue }
                    let path = base.fullPath(id)
                    guard let edited = edits[path], edited.directory else { continue }
                    edits.removeValue(forKey: path)
                    size = edited.size
                    modified = edited.modified
                    attributes = edited.attribute
                } else {
                    size = row.size
                    modified = row.modified
                    attributes = flag
                }
                let start = Int(row.offset)
                let end = i + 1 < base.recordCount ? Int(base.records[i + 1].offset) : pool.count
                let raw = UnsafeBufferPointer(start: pool.baseAddress!.advanced(by: start), count: end - start - 1)
                let appended = result.append(bytes: raw, parent: parent, size: size,
                                             modified: modified, attribute: attributes)
                remap[i] = appended
                if kind == Kind.anchor || kind == Kind.directory && parentNames.contains(base.name(id)) {
                    let path = base.fullPath(id)
                    if wantedParents.contains(path) { parents[path] = appended }
                }
            }
        }
        for path in edits.keys.sorted() {
            let location = parentPath(path)
            let parent: UInt32
            if let found = parents[location] { parent = found }
            else {
                parent = result.append(location, attribute: Kind.anchor)
                parents[location] = parent
            }
            let row = edits[path]!
            let appended = result.append(leafName(path), parent: parent, size: row.size,
                                         modified: row.modified, attribute: row.attribute)
            if row.directory { parents[path] = appended }
        }
        result.tracking = TrackingState(root: state.root, changes: [:], restricted: state.restricted)
        result.prepare()
        return result
    }

    /// Apply the current access result before any cached rows can be published.
    mutating func verifyStartupCoverage(at paths: [String],
                                        observe: (String) -> DirectoryObservation?) -> [String] {
        var reopened: [String] = []
        for path in paths where inside(path, state.root) {
            switch observe(path) {
            case .readable:
                if state.restricted.contains(path) { reopened.append(path) }
            case .absent: _ = reconcile(path: path, observed: .absent)
            case .restricted, nil: _ = reconcile(path: path, observed: .restricted)
            }
        }
        prepareDelta()
        return reopened
    }

    mutating func directoryID(_ path: String) -> UInt32? {
        if let anchor = links?.anchors[path] { return anchor }
        if let id = directories[path] { return id == .max ? nil : id }
        let name = leafName(path)
        let found: UInt32?
        if let links {
            let parent = parentPath(path)
            if parent == path { return nil }
            let previous = directoryID(parent)
            found = previous.flatMap { child(named: name, of: $0, using: links, directoriesOnly: true) }
        } else {
            found = findDirectoryDirect(path, name: name)
        }
        if directories.count >= 1024 { directories.removeAll(keepingCapacity: true) }
        directories[path] = found ?? .max
        return found
    }

    private func findDirectoryDirect(_ path: String, name: String) -> UInt32? {
        base.records.withUnsafeBufferPointer { records in
            base.attributes.withUnsafeBufferPointer { attrs in
                base.names.withUnsafeBufferPointer { names in
                    var start: UInt32 = 0
                    while start < records.count {
                        let candidate = dm_directory_candidate(records.baseAddress, attrs.baseAddress,
                            names.baseAddress, records.count, start, name, path)
                        if candidate == .max { return nil as UInt32? }
                        if base.fullPath(candidate) == path { return candidate }
                        start = candidate + 1
                    }
                    return nil
                }
            }
        }
    }

    private func baseEntry(_ id: UInt32) -> TrackedEntry {
        let row = base.records[Int(id)]
        return TrackedEntry(size: row.size, modified: row.modified,
                            attribute: base.attributes[Int(id)] & ~Kind.suppressed)
    }

    private func child(named leaf: String, of parent: UInt32, using links: DirectoryLinks,
                       directoriesOnly: Bool) -> UInt32? {
        let candidate = links.runs.withUnsafeBufferPointer { runs in
            base.records.withUnsafeBufferPointer { records in
                base.attributes.withUnsafeBufferPointer { attributes in
                    base.names.withUnsafeBufferPointer { names in
                        dm_child_lookup(records.baseAddress, attributes.baseAddress, names.baseAddress,
                                        runs.baseAddress, links.head(parent), leaf, directoriesOnly)
                    }
                }
            }
        }
        return candidate == .max ? nil : candidate
    }

    private mutating func baseID(at path: String) -> UInt32? {
        let parent = parentPath(path)
        let leaf = leafName(path)
        if let links, let id = directoryID(parent) {
            return child(named: leaf, of: id, using: links, directoriesOnly: false)
        }
        if links != nil { return nil }
        return baseChildren(parent)[leaf]
    }

    private mutating func baseChildren(_ path: String) -> [String: UInt32] {
        guard let parent = directoryID(path) else { return [:] }
        var children: [String: UInt32] = [:]
        if let links {
            links.forEachChild(parent) { children[base.name($0)] = $0 }
        } else {
            for i in (Int(parent) + 1)..<base.recordCount where base.records[i].parent == parent {
                children[base.name(UInt32(i))] = UInt32(i)
            }
        }
        return children
    }

    mutating func entry(at path: String) -> TrackedEntry? {
        if let overlay = state.changes[path] { return overlay }
        guard let id = baseID(at: path),
              base.attributes[Int(id)] & Kind.excluded == 0, !base.isSuppressed(Int(id)) else { return nil }
        return baseEntry(id)
    }

    mutating func refreshFile(_ path: String,
                             observation: (UInt8) -> (file: TrackedEntry?, parent: TrackedEntry)?) -> Bool {
        guard !state.restricted.contains(where: { inside(path, $0) }) else { return false }
        let parent = parentPath(path)
        let folder = entry(at: parent)
        guard folder?.directory == true || parent == state.root,
              let observed = observation(folder?.attribute ?? Kind.directory) else { return false }
        let former = entry(at: path)
        if former?.directory == true || observed.file?.directory == true { return false }
        if observed.file != former { set(observed.file, path: path, original: baseID(at: path)) }
        if let folder, observed.parent != folder { set(observed.parent, path: parent, original: baseID(at: parent)) }
        return true
    }

    private mutating func set(_ value: TrackedEntry?, path: String, original: UInt32?) {
        guard let original else {
            change(value, at: path)
            return
        }
        if value == baseEntry(original) {
            base.setSuppressed(Int(original), false)
            change(nil, at: path)
        } else {
            base.setSuppressed(Int(original), true)
            change(value, at: path)
        }
    }

    mutating func removeSubtree(_ path: String, includingRoot: Bool) {
        if let root = directoryID(path) {
            if includingRoot { base.setSuppressed(Int(root), true) }
            if let links {
                var parents = [root]
                while let parent = parents.popLast() {
                    links.forEachChild(parent) { id in
                        base.setSuppressed(Int(id), true)
                        if links.head(id) != .max { parents.append(id) }
                    }
                }
            }
        }
        let removed = state.changes.keys.filter { (includingRoot || $0 != path) && inside($0, path) }
        for location in removed { change(nil, at: location) }
    }

    /// Return children requiring recursive enumeration because their subtree is new.
    mutating func reconcile(path: String, observed: DirectoryObservation) -> [String] {
        if state.restricted.contains(where: { $0 != path && inside(path, $0) }) { return [] }
        switch observed {
        case .restricted:
            removeSubtree(path, includingRoot: false)
            state.restricted.insert(path)
            return []
        case .absent:
            removeSubtree(path, includingRoot: true)
            if let id = baseID(at: path) {
                set(nil, path: path, original: id)
            }
            state.restricted = state.restricted.filter { !inside($0, path) }
            return []
        case let .readable(own, children):
            let needsRestore = state.restricted.remove(path) != nil
            if path != state.root, let existing = entry(at: path) {
                let owned = TrackedEntry(size: own.size, modified: own.modified,
                                         attribute: existing.attribute)
                let id = baseID(at: path)
                if owned != existing { set(owned, path: path, original: id) }
            }
            let originals = baseChildren(path)
            var addedDirectories: [String] = []
            for (name, id) in originals where base.attributes[Int(id)] & Kind.excluded == 0 && !base.isSuppressed(Int(id)) {
                let entry = baseEntry(id)
                guard children[name] == nil || entry.directory && children[name]?.directory == false else { continue }
                let location = joinedPath(path, name)
                if entry.directory { removeSubtree(location, includingRoot: true) }
                set(nil, path: location, original: id)
            }
            for location in changedChildren[path] ?? [] {
                let name = leafName(location)
                guard let entry = state.changes[location],
                      children[name] == nil || entry.directory && children[name]?.directory == false else { continue }
                if entry.directory { removeSubtree(location, includingRoot: true) }
                set(nil, path: location, original: originals[name])
            }
            for (name, entry) in children {
                let original = originals[name]
                let baseValue = original.flatMap { id in
                    base.attributes[Int(id)] & Kind.excluded == 0 && !base.isSuppressed(Int(id)) ? baseEntry(id) : nil
                }
                if !needsRestore, baseValue == entry { continue }
                let location = joinedPath(path, name)
                let prior = state.changes[location] ?? baseValue
                if prior != entry { set(entry, path: location, original: original) }
                if entry.directory && (needsRestore || prior?.directory != true) && entry.attribute & Kind.pending == 0 {
                    addedDirectories.append(location)
                }
            }
            return addedDirectories
        }
    }

    func readView() -> LiveSearchView {
        LiveSearchView(base: base, overlays: state.changes.isEmpty ? [] : overlays)
    }

    func memoryBreakdown() -> [String: Int] {
        var result = base.storageBreakdown()
        result["directoryLinks"] = links?.bytes ?? 0
        result["overlayRowPayload"] = state.changes.reduce(0) { $0 + $1.key.utf8.count + MemoryLayout<TrackedEntry>.stride }
        result["overlayChildPathPayload"] = changedChildren.reduce(0) { sum, group in
            sum + group.key.utf8.count + group.value.reduce(0) { $0 + $1.utf8.count }
        }
        result["overlaySearchTables"] = overlays.reduce(0) { sum, shard in
            sum + shard.storageBreakdown().values.reduce(0, +)
        }
        return result
    }

    func search(_ query: String, mode: QueryMode, column: SearchColumn, direction: SearchDirection,
                showAll: Bool, offset: Int, limit: Int) -> [SearchRow] {
        readView().search(query, mode: mode, column: column, direction: direction,
                          showAll: showAll, offset: offset, limit: limit)
    }
}

struct LiveSearchView {
    let base: SearchIndex
    let overlays: [SearchIndex]

    func search(_ query: String, mode: QueryMode, column: SearchColumn, direction: SearchDirection,
                showAll: Bool, offset: Int, limit: Int) -> [SearchRow] {
        guard offset >= 0, limit > 0, offset <= Int.max - limit else { return [] }
        if overlays.isEmpty {
            return base.search(query, mode: mode, column: column, direction: direction,
                               showAll: showAll, offset: offset, limit: limit)
        }
        let capacity = offset + limit
        var top = base.search(query, mode: mode, column: column, direction: direction,
                              showAll: showAll, limit: capacity)
        for (part, overlay) in overlays.enumerated() where !overlay.records.isEmpty {
            let mask = UInt32(1 << 31) | (UInt32(part) << 27)
            let changed = overlay.search(query, mode: mode, column: column, direction: direction,
                                         showAll: showAll, limit: capacity).map { item in
                SearchRow(id: item.id | mask, name: item.name, path: item.path,
                          size: item.size, modified: item.modified)
            }
            if changed.isEmpty { continue }
            var i = 0, j = 0
            var merged: [SearchRow] = []
            merged.reserveCapacity(min(capacity, top.count + changed.count))
            while merged.count < capacity && (i < top.count || j < changed.count) {
                let prior: Bool
                if j == changed.count { prior = true }
                else if i == top.count { prior = false }
                else {
                    let order = compareAcross(top[i], changed[j], column: column)
                    prior = direction == .ascending ? order < 0 : order > 0
                }
                if prior { merged.append(top[i]); i += 1 }
                else { merged.append(changed[j]); j += 1 }
            }
            top = merged
        }
        return Array(top.dropFirst(offset))
    }
}

private func compareAcross(_ lhs: SearchRow, _ rhs: SearchRow, column: SearchColumn) -> Int {
    func compare<T: Comparable>(_ x: T, _ y: T) -> Int { x == y ? 0 : x < y ? -1 : 1 }
    func bytes(_ x: [UInt8], _ y: [UInt8]) -> Int { x == y ? 0 : x.lexicographicallyPrecedes(y) ? -1 : 1 }
    let main: Int
    switch column {
    case .name: main = 0
    case .path: main = bytes(SearchIndex.key(parentPath(lhs.path)), SearchIndex.key(parentPath(rhs.path)))
    case .size: main = compare(lhs.size, rhs.size)
    case .modified: main = compare(lhs.modified, rhs.modified)
    }
    if main != 0 { return main }
    let normalized = bytes(SearchIndex.key(lhs.name), SearchIndex.key(rhs.name))
    if normalized != 0 { return normalized }
    let raw = bytes(Array(lhs.name.utf8), Array(rhs.name.utf8))
    return raw != 0 ? raw : compare(lhs.id, rhs.id)
}

extension SearchIndex {
    /// Includes committed changes when the file was saved by the tracker.
    public func restoredSearch(_ query: String, showAll: Bool) -> [SearchRow] {
        guard let tracking, !tracking.changes.isEmpty else { return search(query, showAll: showAll) }
        return LiveIndex(base: self, root: tracking.root, linkChildren: false).search(query, mode: .name, column: .name,
            direction: .ascending, showAll: showAll, offset: 0, limit: 50)
    }

    /// Inspection of a tracked snapshot includes its committed overlay.
    public func restoredRows() -> [SearchRow] {
        LiveIndex(base: self, root: tracking?.root ?? "/", linkChildren: false).search("", mode: .name,
            column: .name, direction: .ascending, showAll: true, offset: 0,
            limit: recordCount + (tracking?.changes.count ?? 0))
    }
}
