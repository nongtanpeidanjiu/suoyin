import Foundation

/// Copy only the sealed system rows and the bridge directories used by Data.
func sealedVolume(from source: SearchIndex, excluding targets: [String]) -> SearchIndex {
    var result = SearchIndex()
    result.reserve(source.recordCount / 4, nameBytes: source.names.count / 4)
    var navigator = LiveIndex(base: source, root: "/", linkChildren: false)
    let cuts = Set(targets.compactMap { navigator.directoryID($0) })
    var remap = [UInt32](repeating: .max, count: source.recordCount)
    source.names.withUnsafeBufferPointer { pool in
        for (i, row) in source.records.enumerated() {
            if cuts.contains(UInt32(i)) { continue }
            // Compaction can attach edits to a standalone parent anchor.
            // Its path still belongs to Data even without an indexed ancestor.
            if row.parent == .max {
                let path = source.name(UInt32(i))
                if targets.contains(where: { inside(path, $0) }) { continue }
            }
            let parent = row.parent == .max ? .max : remap[Int(row.parent)]
            if row.parent != .max && parent == .max { continue }
            let end = i + 1 < source.recordCount ? Int(source.records[i + 1].offset) : pool.count
            let raw = UnsafeBufferPointer(start: pool.baseAddress!.advanced(by: Int(row.offset)),
                                          count: end - Int(row.offset) - 1)
            remap[i] = result.append(bytes: raw, parent: parent, size: row.size,
                                     modified: row.modified, attribute: source.attributes[i])
        }
    }
    return result
}
