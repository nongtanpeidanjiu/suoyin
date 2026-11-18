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
    let head: [UInt32]
    let next: [UInt32]
    let anchors: [String: UInt32]

    init(_ index: SearchIndex) {
        var first = [UInt32](repeating: .max, count: index.recordCount)
        var following = first
        var roots: [String: UInt32] = [:]
        for i in index.records.indices.reversed() {
            let parent = index.records[i].parent
            if parent == .max {
                roots[index.name(UInt32(i))] = UInt32(i)
            } else {
                following[i] = first[Int(parent)]
                first[Int(parent)] = UInt32(i)
            }
        }
        head = first
        next = following
        anchors = roots
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

    mutating func directoryID(_ path: String) -> UInt32? {
        if let anchor = links?.anchors[path] { return anchor }
        if let id = directories[path] { return id == .max ? nil : id }
        let name = leafName(path)
        let found: UInt32?
        if let links {
            let parent = parentPath(path)
            if parent == path { return nil }
            let previous = directoryID(parent)
            found = previous.flatMap { id in
                let candidate = links.next.withUnsafeBufferPointer { next in
                    base.records.withUnsafeBufferPointer { records in
                        base.attributes.withUnsafeBufferPointer { attributes in
                            base.names.withUnsafeBufferPointer { names in
                                dm_child_directory(records.baseAddress, attributes.baseAddress,
                                    names.baseAddress, next.baseAddress, links.head[Int(id)], name)
                            }
                        }
                    }
                }
                return candidate == .max ? nil : candidate
            }
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

    private mutating func baseChildren(_ path: String) -> [String: UInt32] {
        guard let parent = directoryID(path) else { return [:] }
        var children: [String: UInt32] = [:]
        if let links {
            var id = links.head[Int(parent)]
            while id != .max {
                children[base.name(id)] = id
                id = links.next[Int(id)]
            }
        } else {
            for i in (Int(parent) + 1)..<base.recordCount where base.records[i].parent == parent {
                children[base.name(UInt32(i))] = UInt32(i)
            }
        }
        return children
    }

    mutating func entry(at path: String) -> TrackedEntry? {
        if let overlay = state.changes[path] { return overlay }
        guard let id = baseChildren(parentPath(path))[leafName(path)],
              base.attributes[Int(id)] & Kind.excluded == 0, !base.isSuppressed(Int(id)) else { return nil }
        return baseEntry(id)
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
                    var id = links.head[Int(parent)]
                    while id != .max {
                        base.setSuppressed(Int(id), true)
                        if links.head[Int(id)] != .max { parents.append(id) }
                        id = links.next[Int(id)]
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
            if let id = baseChildren(parentPath(path))[leafName(path)] {
                set(nil, path: path, original: id)
            }
            state.restricted = state.restricted.filter { !inside($0, path) }
            return []
        case let .readable(own, children):
            let needsRestore = state.restricted.remove(path) != nil
            if path != state.root, let existing = entry(at: path) {
                let owned = TrackedEntry(size: own.size, modified: own.modified,
                                         attribute: existing.attribute)
                let id = baseChildren(parentPath(path))[leafName(path)]
                if owned != existing { set(owned, path: path, original: id) }
            }
            let originals = baseChildren(path)
            var prior = [String: TrackedEntry]()
            prior.reserveCapacity(originals.count)
            for (name, id) in originals where base.attributes[Int(id)] & Kind.excluded == 0 && !base.isSuppressed(Int(id)) {
                prior[name] = baseEntry(id)
            }
            for location in changedChildren[path] ?? [] {
                prior[leafName(location)] = state.changes[location]
            }
            var addedDirectories: [String] = []
            for (name, entry) in prior where children[name] == nil || entry.directory && children[name]?.directory == false {
                let location = joinedPath(path, name)
                if entry.directory { removeSubtree(location, includingRoot: true) }
                set(nil, path: location, original: originals[name])
            }
            for (name, entry) in children {
                let location = joinedPath(path, name)
                if prior[name] != entry { set(entry, path: location, original: originals[name]) }
                if entry.directory && (needsRestore || prior[name]?.directory != true) && entry.attribute & Kind.pending == 0 {
                    addedDirectories.append(location)
                }
            }
            return addedDirectories
        }
    }

    func search(_ query: String, mode: QueryMode, column: SearchColumn, direction: SearchDirection,
                showAll: Bool, offset: Int, limit: Int) -> [SearchRow] {
        guard offset >= 0, limit > 0, offset <= Int.max - limit else { return [] }
        if state.changes.isEmpty {
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
