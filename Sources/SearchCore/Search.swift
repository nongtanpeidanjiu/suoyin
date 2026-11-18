import Darwin
import DarwinMetadata
import Foundation

struct PreparedSearch {
    var keyBytes: [UInt8] = []
    var keyOffsets: [UInt32]
    var changedRows: [UInt32] = []
    var nameOrder: [UInt32] = []
    var pathOrder: [UInt32] = []
    var sizeOrder: [UInt32] = []
    var modifiedOrder: [UInt32] = []

    init(keyOffsets: [UInt32]) { self.keyOffsets = keyOffsets }

    init(index: SearchIndex) {
        keyOffsets = [UInt32](repeating: .max, count: index.recordCount)
        index.names.withUnsafeBufferPointer { pool in
            for (i, record) in index.records.enumerated() {
                let offset = Int(record.offset)
                let end = i + 1 == index.recordCount ? pool.count : Int(index.records[i + 1].offset)
                let base = pool.baseAddress!.advanced(by: offset)
                let count = end - offset - 1
                let classification = dm_key_class(base, count)
                guard classification != 0 else { continue }
                let original = UnsafeBufferPointer(start: base, count: count)
                let folded = classification == 1
                    ? original.map { (65...90).contains($0) ? $0 + 32 : $0 }
                    : SearchIndex.key(String(decoding: original, as: UTF8.self))
                guard !folded.elementsEqual(original) else { continue }
                keyOffsets[i] = UInt32(keyBytes.count)
                changedRows.append(UInt32(i))
                keyBytes.append(contentsOf: folded)
                keyBytes.append(0)
            }
        }
    }

    func withView<T>(index: SearchIndex, _ body: (inout DMQueryView) -> T) -> T {
        index.records.withUnsafeBufferPointer { rows in
            index.attributes.withUnsafeBufferPointer { attributes in
                index.names.withUnsafeBufferPointer { names in
                    keyBytes.withUnsafeBufferPointer { folded in
                        keyOffsets.withUnsafeBufferPointer { offsets in
                            changedRows.withUnsafeBufferPointer { changed in
                                index.suppressed.withUnsafeBufferPointer { suppressed in
                                    var view = DMQueryView(rows: rows.baseAddress,
                                        attributes: attributes.baseAddress, names: names.baseAddress,
                                        folded_names: folded.baseAddress, fold_offsets: offsets.baseAddress,
                                        fold_rows: changed.baseAddress,
                                        suppressed_rows: suppressed.isEmpty ? nil : suppressed.baseAddress,
                                        row_count: rows.count, name_bytes: names.count,
                                        fold_bytes: folded.count, fold_count: changed.count)
                                    return body(&view)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func order(for column: SearchColumn) -> [UInt32] {
        switch column {
        case .name: return nameOrder
        case .path: return pathOrder
        case .size: return sizeOrder
        case .modified: return modifiedOrder
        }
    }
}

private extension Array {
    mutating func removeSpareCapacity() {
        guard capacity - count > 64 else { return }
        self = withUnsafeBufferPointer { Array($0) }
    }
}

extension SearchIndex {
    func storageBreakdown() -> [String: Int] {
        let keyBytes = prepared.map { $0.keyBytes.capacity + 4 * ($0.keyOffsets.capacity + $0.changedRows.capacity) } ?? 0
        let order = prepared.map {
            4 * ($0.nameOrder.capacity + $0.pathOrder.capacity + $0.sizeOrder.capacity + $0.modifiedOrder.capacity)
        } ?? 0
        return [
            "recordsAndAttributes": records.capacity * MemoryLayout<DMRecord>.stride + attributes.capacity,
            "names": names.capacity, "foldedKeys": keyBytes, "sortTables": order,
            "suppressedRows": suppressed.capacity,
        ]
    }

    mutating func tightenScannedStorage() {
        records.removeSpareCapacity()
        attributes.removeSpareCapacity()
        names.removeSpareCapacity()
        prepare()
        prepared?.keyBytes.removeSpareCapacity()
        prepared?.keyOffsets.removeSpareCapacity()
        prepared?.changedRows.removeSpareCapacity()
        prepared?.nameOrder.removeSpareCapacity()
        prepared?.pathOrder.removeSpareCapacity()
        prepared?.sizeOrder.removeSpareCapacity()
        prepared?.modifiedOrder.removeSpareCapacity()
    }

    /// Materialize shared folded keys and exact sort permutations for this index value.
    public mutating func prepare() {
        guard prepared == nil, !records.isEmpty else { return }
        var keys = PreparedSearch(index: self)
        let count = recordCount
        var names = [UInt32](repeating: 0, count: count)
        var paths = [UInt32](repeating: 0, count: count)
        var sizes = [UInt32](repeating: 0, count: count)
        var times = [UInt32](repeating: 0, count: count)
        let ok = keys.withView(index: self) { view in
            names.withUnsafeMutableBufferPointer { name in
                paths.withUnsafeMutableBufferPointer { path in
                    sizes.withUnsafeMutableBufferPointer { size in
                        times.withUnsafeMutableBufferPointer { time in
                            dm_order(&view, name.baseAddress, path.baseAddress, size.baseAddress, time.baseAddress)
                        }
                    }
                }
            }
        }
        guard ok else { return }
        keys.nameOrder = names
        keys.pathOrder = paths
        keys.sizeOrder = sizes
        keys.modifiedOrder = times
        prepared = keys
    }

    public func search(_ query: String, mode: QueryMode = .name, column: SearchColumn = .name,
                       direction: SearchDirection = .ascending, showAll: Bool = false,
                       offset: Int = 0, limit: Int = 50) -> [SearchRow] {
        guard let capacity = pageCapacity(offset: offset, limit: limit),
              !query.utf8.contains(0) else { return [] }
        guard let prepared else {
            return directSearch(query, mode: mode, column: column, direction: direction,
                                showAll: showAll, offset: offset, limit: limit)
        }
        var words: [UInt8] = []
        var offsets: [UInt32] = []
        for word in Self.queryWords(query) {
            offsets.append(UInt32(words.count))
            words.append(contentsOf: word)
            words.append(0)
        }
        let length = capacity - offset
        var ids = [UInt32](repeating: 0, count: length)
        let emitted = prepared.withView(index: self) { view in
            prepared.order(for: column).withUnsafeBufferPointer { order in
                words.withUnsafeBufferPointer { words in
                    offsets.withUnsafeBufferPointer { offsets in
                        ids.withUnsafeMutableBufferPointer { ids in
                            dm_query(&view, order.baseAddress, words.baseAddress, offsets.baseAddress,
                                     offsets.count, mode == .path, direction == .descending,
                                     showAll, offset, ids.count, ids.baseAddress)
                        }
                    }
                }
            }
        }
        guard emitted >= 0 && emitted <= length else {
            return directSearch(query, mode: mode, column: column, direction: direction,
                                showAll: showAll, offset: offset, limit: limit)
        }
        return ids.prefix(emitted).map { row($0) }
    }
}
