import Foundation

/// Keep sealed-volume rows while replacing Data's physical and firmlink roots.
func mergeDataVolume(old: LiveIndex, new: SearchIndex, targets: [String]) -> SearchIndex {
    var result = SearchIndex()
    result.reserve(new.recordCount + old.base.recordCount / 4,
                   nameBytes: new.names.count + old.base.names.count / 4)
    var bridgeIDs: [String: UInt32] = [:]
    let bridgePaths = Set(targets.flatMap { target -> [String] in
        var paths: [String] = []
        var current = parentPath(target)
        while true {
            paths.append(current)
            if current == "/" { return paths }
            current = parentPath(current)
        }
    })
    let bridgeNames = Set(bridgePaths.map(leafName))

    func copy(source: SearchIndex, dataOnly: Bool) {
        var navigator = LiveIndex(base: source, root: "/", linkChildren: false)
        let cuts = Set(targets.compactMap { navigator.directoryID($0) })
        var remap = [UInt32](repeating: .max, count: source.recordCount)
        var data = [UInt8](repeating: 0, count: source.recordCount)
        source.names.withUnsafeBufferPointer { pool in
            for (i, row) in source.records.enumerated() {
                let id = UInt32(i)
                let flag = source.attributes[i]
                let length = (i + 1 < source.recordCount ? Int(source.records[i + 1].offset) : pool.count)
                             - Int(row.offset) - 1
                let raw = UnsafeBufferPointer(start: pool.baseAddress!.advanced(by: Int(row.offset)), count: length)
                let isData = cuts.contains(id) || row.parent != .max && data[Int(row.parent)] != 0
                data[i] = isData ? 1 : 0
                var bridge: String?
                if !isData && flag & Kind.mask != Kind.file {
                    let name = String(decoding: raw, as: UTF8.self)
                    if name == "/" || bridgeNames.contains(name) {
                        let path = source.fullPath(id)
                        if bridgePaths.contains(path) { bridge = path }
                    }
                }
                if dataOnly && !isData {
                    if let bridge, let retained = bridgeIDs[bridge] { remap[i] = retained }
                    continue
                }
                if !dataOnly && isData { continue }
                let parent = row.parent == .max ? .max : remap[Int(row.parent)]
                if row.parent != .max && parent == .max { continue }
                let newID = result.append(bytes: raw, parent: parent, size: row.size,
                                          modified: row.modified, attribute: flag)
                remap[i] = newID
                if let bridge { bridgeIDs[bridge] = newID }
            }
        }
    }
    copy(source: old.base, dataOnly: false)
    copy(source: new, dataOnly: true)
    return result
}
